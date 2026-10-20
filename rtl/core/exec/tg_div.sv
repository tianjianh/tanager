// Iterative RV64 integer divider (core-pipeline.md §7.2, port P1): DIV, DIVU, REM, REMU and
// their W forms, with the RISC-V results for division by zero and overflow. Radix-2
// restoring division on magnitudes, one quotient bit per cycle. Requests are served in
// order from a DEPTH-entry input FIFO (one per thread, below); the result register holds
// until out_ready.
// One divide, from a FIFO head (the cycle after in_valid at the earliest):
//   LD  operands extended (W forms: from bit 31, signed or not as the op says), signs, and
//       the magnitudes |a|, |b|.
//   NM  n = msb(|a|) - msb(|b|) + 1 quotient bits are left to compute; n = 0 when b = 0 or
//       |a| has fewer significant bits than |b| (|a| = 0 included). The leading zero
//       quotient bits are skipped by aligning the divisor to the dividend's leading one:
//       d = |b| << (n - 1), r = |a|, q = 0.
//   IT  n cycles, one quotient bit each: r - d replaces r if >= 0, the bit enters q from the
//       right, and d shifts right.
//   FX  quotient or remainder, sign fix-up, division by zero, W sign extension, into the
//       result register (FX waits while it is full). The next request's LD overlaps FX.
// Latency from in_valid to out_valid with the unit idle: n + 4 cycles, so at most 68 for a
// 64-bit divide and 36 for a W divide (|a| <= 2^32 - 1, so n <= 32), and 4 when n = 0.
// Back-to-back divides take n + 2 cycles each.
// Overflow (-2^63 / -1, and -2^31 / -1 for the W forms) needs no special case: the
// magnitude quotient 2^63 (2^31) already is the wrapped result, and the remainder is 0.
// count = queued + in progress + result waiting; the caller keeps it at most DEPTH.
// Threads (M7, DR-175): each thread has its own input queue, a partition of one LUTRAM (a second
// partition costs no memory: the LUTRAM is 32 deep), so each thread's results come out in its
// order; when both queues hold requests the heads load in turn. flush kills the flushed thread's
// (flush_tid) requests: its queue, the request it presents in the flush cycle, its divide in
// progress and its waiting result. A result already in the result register is still presented in
// the flush cycle. With one thread this is the one queue and the flush that drops everything.
module tg_div
  import tg_pkg::*, tg_core_pkg::*;
#(parameter int TAG_W = 8, parameter int DEPTH = DIV_INFLIGHT)
(
  input  logic             clk,
  input  logic             rst,
  input  logic             flush,      // drops the flushed thread's requests (queued, in progress, waiting result)
  input  tid_t             flush_tid,
  input  tid_t             in_tid,     // the request's thread
  // Requests: the caller guarantees room (it never has more than DEPTH requests in the unit)
  input  logic             in_valid,
  input  div_op_e          in_op,
  input  logic             in_word,    // DIVW/DIVUW/REMW/REMUW
  input  logic [63:0]      in_a,
  input  logic [63:0]      in_b,
  input  logic [TAG_W-1:0] in_tag,
  // Result: held until accepted
  output logic             out_valid,
  input  logic             out_ready,
  output logic [63:0]      out_res,
  output logic [TAG_W-1:0] out_tag,
  output logic [idx_w(DEPTH+1)-1:0] count,  // requests in the unit: queued + in progress + result waiting
  output tid_t             out_tid     // the result's thread
);
  localparam int CW     = idx_w(DEPTH + 1);
  localparam int NT     = NUM_THREADS;
  localparam int FDEPTH = 1 << idx_w(DEPTH);   // a thread's queue: a power of two, at least DEPTH
  localparam int AW     = idx_w(FDEPTH);
  localparam int MAW    = idx_w(NT * FDEPTH);  // the queue memory's address: {thread, slot}

  // ---- Input queues, one per thread (tg_fifo's pointer form, on one memory) ----
  typedef struct packed {
    div_op_e          op;
    logic             word;
    logic [63:0]      a, b;
    logic [TAG_W-1:0] tag;
  } req_t;
  req_t                req_wd, hd;
  logic [NT-1:0][AW:0] wr_q, rd_q;     // each thread's pointers (count = wr - rd)
  logic [NT-1:0]       kill_t;         // the flush takes thread t's requests
  logic [CW-1:0]       q_all;          // requests queued, every thread
  logic                push, hd_valid, ld_raw, k_hd;
  tid_t                sel, rr_q;      // the thread whose head loads next; the thread served last
  logic [MAW-1:0]      waddr;
  logic [0:0][MAW-1:0] raddr;
  logic [0:0][$bits(req_t)-1:0] rdata;
  assign push   = in_valid && !(flush && in_tid == flush_tid);
  assign req_wd = '{op: in_op, word: in_word, a: in_a, b: in_b, tag: in_tag};
  // The other thread's head when it has one, else this one's: from registers only (no flush), so
  // the memory read and the operand path stay off the flush's timing
  always_comb begin
    sel   = rr_q;
    q_all = '0;
    for (int t = 0; t < NT; t++) begin
      q_all = q_all + CW'(wr_q[t] - rd_q[t]);
      if (wr_q[t] != rd_q[t] && tid_t'(t) != rr_q) sel = tid_t'(t);
    end
  end
  assign hd_valid = wr_q[sel] != rd_q[sel];
  assign k_hd     = flush && sel == flush_tid;          // the head's thread is flushed: it does not start
  assign waddr    = MAW'({in_tid, wr_q[in_tid][AW-1:0]});
  assign raddr[0] = MAW'({sel, rd_q[sel][AW-1:0]});
  tg_ram_lut #(.DEPTH(1 << MAW), .WIDTH($bits(req_t)), .NR(1)) u_q (
    .clk, .we(push), .waddr, .wdata($bits(req_t)'(req_wd)), .raddr, .rdata);
  assign hd = req_t'(rdata[0]);
  for (genvar t = 0; t < NT; t++) begin : g_q
    assign kill_t[t] = flush && flush_tid == tid_t'(t);
    always_ff @(posedge clk) begin
      if (rst || kill_t[t]) begin
        wr_q[t] <= '0;
        rd_q[t] <= '0;
      end else begin
        if (push && in_tid == tid_t'(t))  wr_q[t] <= wr_q[t] + 1'b1;
        if (ld_raw && sel == tid_t'(t))   rd_q[t] <= rd_q[t] + 1'b1;
      end
    end
  end

  // ---- Divider state ----
  typedef enum logic [1:0] { S_IDLE, S_NM, S_IT, S_FX } state_e;
  state_e           st_q;
  logic [63:0]      d_q;        // |b|; from NM on |b| << (quotient bits left - 1)
  logic [63:0]      r_q;        // |a|, then the partial remainder
  logic [63:0]      q_q;        // quotient bits so far
  logic [6:0]       n_q;        // quotient bits left to compute
  logic             rem_q, word_q, neg_q;
  logic [TAG_W-1:0] tag_q;
  tid_t             cur_t_q;    // the divide's thread
  logic             out_valid_q;
  logic [63:0]      out_res_q;
  logic [TAG_W-1:0] out_tag_q;
  tid_t             out_t_q;    // the result's thread
  logic             k_cur, k_res;   // the flush takes the divide in progress; the waiting result
  assign k_cur = flush && cur_t_q == flush_tid;
  assign k_res = flush && out_t_q == flush_tid;

  // fx_raw: the result register can take the finished divide (it does unless the divide's thread
  // is flushed: fx_go). ld_raw: the head's operands load (the divide starts unless its thread is
  // flushed). Neither looks at the flush, so it stays off the data registers' enables
  logic fx_raw, fx_go;
  assign fx_raw = st_q == S_FX && (!out_valid_q || out_ready);
  assign fx_go  = fx_raw && !k_cur;
  assign ld_raw = hd_valid && (st_q == S_IDLE || fx_raw);

  // ---- LD: the selected head's operands ----
  logic        sgn, an, bn, h_rem;
  logic [63:0] ea, eb;
  assign sgn   = hd.op == DIV_S || hd.op == REM_S;
  assign h_rem = hd.op == REM_S || hd.op == REM_U;
  assign ea    = hd.word ? {{32{sgn && hd.a[31]}}, hd.a[31:0]} : hd.a;
  assign eb    = hd.word ? {{32{sgn && hd.b[31]}}, hd.b[31:0]} : hd.b;
  assign an    = sgn && ea[63];
  assign bn    = sgn && eb[63];

  // ---- NM: quotient bits to compute (|a| is in r_q) ----
  // One left shift of the divisor by n - 1 = lzd - lza (one 64-bit shifter; a shift of the
  // dividend by 64 - n into {r, q} took two). When n = 0 the shifted divisor is not used.
  logic         dz, nz;
  logic [6:0]   lza, lzd, nq;     // leading zeros of |a| and |b|, 64 for 0
  logic [5:0]   s1;
  assign dz  = d_q == '0;
  tg_fpu_lzc #(.W(64)) u_lza (.x(r_q), .cnt(lza));
  tg_fpu_lzc #(.W(64)) u_lzd (.x(d_q), .cnt(lzd));
  assign nz  = dz || lzd < lza;
  assign nq  = nz ? 7'd0 : lzd - lza + 7'd1;
  assign s1  = 6'(lzd - lza);                  // n - 1 when !nz (lzd <= 63 then)

  // ---- IT: one restoring step ----
  // d = |b| << k with k from n - 1 down to 0, so r < 2d at each step, and d's leading one is
  // where |a|'s is: r - d fits 64 bits.
  logic [63:0] diff;
  logic        borrow;
  assign {borrow, diff} = {1'b0, r_q} - {1'b0, d_q};

  // ---- FX: result and sign fix-up ----
  // x / 0 = -1 comes from NM (q all ones, no negation); x % 0 = x falls out of r.
  logic [63:0] mag, fx;
  assign mag = rem_q ? r_q : q_q;
  always_comb begin
    fx = neg_q ? -mag : mag;
    if (word_q) fx = {{32{fx[31]}}, fx[31:0]};
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      st_q <= S_IDLE;
      rr_q <= '0;
    end else begin
      unique case (st_q)
        S_IDLE: if (ld_raw && !k_hd) st_q <= S_NM;
        S_NM:   st_q <= k_cur ? S_IDLE : (nq == 7'd0) ? S_FX : S_IT;
        S_IT:   if (k_cur) st_q <= S_IDLE; else if (n_q == 7'd1) st_q <= S_FX;
        S_FX:   if (fx_raw || k_cur) st_q <= (ld_raw && !k_hd) ? S_NM : S_IDLE;
      endcase
      if (ld_raw) rr_q <= sel;
    end
  end

  always_ff @(posedge clk) begin
    if (ld_raw) begin
      r_q     <= an ? -ea : ea;
      d_q     <= bn ? -eb : eb;
      rem_q   <= h_rem;
      word_q  <= hd.word;
      neg_q   <= h_rem ? an : an ^ bn;   // the remainder takes the dividend's sign
      tag_q   <= hd.tag;
      cur_t_q <= sel;
    end else if (st_q == S_NM) begin
      d_q <= d_q << s1;
      q_q <= {64{dz}};                       // x / 0: all ones
      n_q <= nq;
      if (dz && !rem_q) neg_q <= 1'b0;
    end else if (st_q == S_IT) begin
      if (!borrow) r_q <= diff;
      q_q <= {q_q[62:0], !borrow};
      d_q <= {1'b0, d_q[63:1]};
      n_q <= n_q - 7'd1;
    end
  end

  // ---- Result register ----
  always_ff @(posedge clk) begin
    if (rst)                     out_valid_q <= 1'b0;
    else if (fx_go)              out_valid_q <= 1'b1;
    else if (out_ready || k_res) out_valid_q <= 1'b0;
  end
  always_ff @(posedge clk) begin
    if (fx_raw) begin
      out_res_q <= fx;
      out_tag_q <= tag_q;
      out_t_q   <= cur_t_q;
    end
  end

  assign out_valid = out_valid_q;
  assign out_res   = out_res_q;
  assign out_tag   = out_tag_q;
  assign out_tid   = out_t_q;
  assign count     = q_all + CW'(st_q != S_IDLE) + CW'(out_valid_q);

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && push)
      assert (wr_q[in_tid] - rd_q[in_tid] != (AW + 1)'(FDEPTH) &&
              (int'(count) < DEPTH || (out_valid_q && out_ready)))
        else $error("tg_div: request beyond DEPTH");
  end
`endif
endmodule
