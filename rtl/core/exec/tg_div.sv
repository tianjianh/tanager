// Iterative RV64 integer divider (core-pipeline.md §7.2, port P1): DIV, DIVU, REM, REMU and
// their W forms, with the RISC-V results for division by zero and overflow. Radix-2
// restoring division on magnitudes, one quotient bit per cycle. Requests are served in
// order from a DEPTH-entry input FIFO; the result register holds until out_ready.
// One divide, from the FIFO head (the cycle after in_valid at the earliest):
//   LD  operands extended (W forms: from bit 31, signed or not as the op says), signs, and
//       the magnitudes |a|, |b|.
//   NM  n = msb(|a|) - msb(|b|) + 1 quotient bits are left to compute; n = 0 when b = 0 or
//       |a| has fewer significant bits than |b| (|a| = 0 included). The leading zero
//       quotient bits are skipped by starting from {r, q} = |a| << (64 - n).
//   IT  n cycles, one quotient bit each: {r, q} shifts left; r - |b| replaces r if >= 0.
//   FX  quotient or remainder, sign fix-up, division by zero, W sign extension, into the
//       result register (FX waits while it is full). The next request's LD overlaps FX.
// Latency from in_valid to out_valid with the unit idle: n + 4 cycles, so at most 68 for a
// 64-bit divide and 36 for a W divide (|a| <= 2^32 - 1, so n <= 32), and 4 when n = 0.
// Back-to-back divides take n + 2 cycles each.
// Overflow (-2^63 / -1, and -2^31 / -1 for the W forms) needs no special case: the
// magnitude quotient 2^63 (2^31) already is the wrapped result, and the remainder is 0.
// count = queued + in progress + result waiting; the caller keeps it at most DEPTH.
// flush drops everything, including a request presented in the flush cycle. A result
// already in the result register is still presented in the flush cycle.
module tg_div
  import tg_pkg::*, tg_core_pkg::*;
#(parameter int TAG_W = 8, parameter int DEPTH = DIV_INFLIGHT)
(
  input  logic             clk,
  input  logic             rst,
  input  logic             flush,      // drops every request (queued, in progress, waiting result)
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
  output logic [idx_w(DEPTH+1)-1:0] count   // requests in the unit: queued + in progress + result waiting
);
  localparam int CW     = idx_w(DEPTH + 1);
  localparam int FDEPTH = 1 << idx_w(DEPTH);   // tg_fifo needs a power of two

  // ---- Input FIFO ----
  typedef struct packed {
    div_op_e          op;
    logic             word;
    logic [63:0]      a, b;
    logic [TAG_W-1:0] tag;
  } req_t;
  req_t                   in_req, hd;
  logic                   hd_valid, q_ready, load;
  logic [idx_w(FDEPTH):0] q_count;
  assign in_req = '{op: in_op, word: in_word, a: in_a, b: in_b, tag: in_tag};
  tg_fifo #(.T(req_t), .DEPTH(FDEPTH)) u_q (
    .clk, .rst(rst || flush), .in_valid(in_valid && !flush), .in_ready(q_ready), .in_data(in_req),
    .out_valid(hd_valid), .out_ready(load), .out_data(hd), .count(q_count));

  // ---- Divider state ----
  typedef enum logic [1:0] { S_IDLE, S_NM, S_IT, S_FX } state_e;
  state_e           st_q;
  logic [63:0]      d_q;        // |b|
  logic [63:0]      r_q;        // partial remainder (< |b| from NM on)
  logic [63:0]      q_q;        // |a| after LD; then dividend bits not yet used, quotient bits below
  logic [6:0]       n_q;        // quotient bits left to compute
  logic             rem_q, word_q, neg_q;
  logic [TAG_W-1:0] tag_q;
  logic             out_valid_q;
  logic [63:0]      out_res_q;
  logic [TAG_W-1:0] out_tag_q;

  logic fx_go;   // the result register takes the finished divide
  assign fx_go = st_q == S_FX && (!out_valid_q || out_ready);
  assign load  = hd_valid && (st_q == S_IDLE || fx_go);

  // ---- LD: the FIFO head's operands ----
  logic        sgn, an, bn, h_rem;
  logic [63:0] ea, eb;
  assign sgn   = hd.op == DIV_S || hd.op == REM_S;
  assign h_rem = hd.op == REM_S || hd.op == REM_U;
  assign ea    = hd.word ? {{32{sgn && hd.a[31]}}, hd.a[31:0]} : hd.a;
  assign eb    = hd.word ? {{32{sgn && hd.b[31]}}, hd.b[31:0]} : hd.b;
  assign an    = sgn && ea[63];
  assign bn    = sgn && eb[63];

  // ---- NM: quotient bits to compute (|a| is in q_q) ----
  function automatic logic [6:0] lzc64(input logic [63:0] x);   // leading zeros, 64 for 0
    lzc64 = 7'd64;
    for (int i = 0; i < 64; i++) if (x[i]) lzc64 = 7'(63 - i);
  endfunction
  logic         dz;
  logic [6:0]   lza, lzd, nq;
  logic [127:0] rq0;
  assign dz  = d_q == '0;
  assign lza = lzc64(q_q);
  assign lzd = lzc64(d_q);
  assign nq  = (dz || lzd < lza) ? 7'd0 : lzd - lza + 7'd1;
  assign rq0 = {64'b0, q_q} << (7'd64 - nq);   // r = |a| >> n is below |b|

  // ---- IT: one restoring step ----
  logic [64:0] r2, diff;
  logic        borrow;
  assign r2 = {r_q, q_q[63]};
  assign {borrow, diff} = {1'b0, r2} - {2'b0, d_q};
  logic unused;
  assign unused = diff[64];   // r2 - |b| < |b| when there is no borrow

  // ---- FX: result and sign fix-up ----
  logic [63:0] mag, fx;
  assign mag = rem_q ? r_q : q_q;
  always_comb begin
    fx = neg_q ? -mag : mag;
    if (dz && !rem_q) fx = '1;                   // x / 0 = -1; x % 0 = x falls out of r
    if (word_q)       fx = {{32{fx[31]}}, fx[31:0]};
  end

  always_ff @(posedge clk) begin
    if (rst || flush) st_q <= S_IDLE;
    else begin
      unique case (st_q)
        S_IDLE: if (load) st_q <= S_NM;
        S_NM:   st_q <= (nq == 7'd0) ? S_FX : S_IT;
        S_IT:   if (n_q == 7'd1) st_q <= S_FX;
        S_FX:   if (fx_go) st_q <= load ? S_NM : S_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (load) begin
      q_q    <= an ? -ea : ea;
      d_q    <= bn ? -eb : eb;
      rem_q  <= h_rem;
      word_q <= hd.word;
      neg_q  <= h_rem ? an : an ^ bn;    // the remainder takes the dividend's sign
      tag_q  <= hd.tag;
    end else if (st_q == S_NM) begin
      {r_q, q_q} <= rq0;
      n_q        <= nq;
    end else if (st_q == S_IT) begin
      r_q <= borrow ? r2[63:0] : diff[63:0];
      q_q <= {q_q[62:0], !borrow};
      n_q <= n_q - 7'd1;
    end
  end

  // ---- Result register ----
  always_ff @(posedge clk) begin
    if (rst || flush)   out_valid_q <= 1'b0;
    else if (fx_go)     out_valid_q <= 1'b1;
    else if (out_ready) out_valid_q <= 1'b0;
  end
  always_ff @(posedge clk) begin
    if (fx_go) begin
      out_res_q <= fx;
      out_tag_q <= tag_q;
    end
  end

  assign out_valid = out_valid_q;
  assign out_res   = out_res_q;
  assign out_tag   = out_tag_q;
  assign count     = CW'(q_count) + CW'(st_q != S_IDLE) + CW'(out_valid_q);

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && !flush && in_valid)
      assert (q_ready && (int'(count) < DEPTH || (out_valid_q && out_ready)))
        else $error("tg_div: request beyond DEPTH");
  end
`endif
endmodule
