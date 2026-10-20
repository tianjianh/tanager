// Unit test of tg_mul and tg_div (rtl/core/exec). Random operands biased towards the RISC-V
// corner cases (0, 1, -1, INT64_MIN/MAX, small values, INT32_MIN and -1 in the low word,
// powers of two, random lengths, multiples of the divisor), every op and W form, random
// back-to-back issue, random out_ready stalls and flush pulses, in phases with different
// rates. Results are checked against references computed here (128-bit products; division
// case by case from the M extension's table).
// Threads (M7, DR-175; smt2 configurations): each request has a thread, in phases of thread 0
// only, thread 1 only or both, and each flush a thread; a flush kills only its thread's requests.
// Multiplier: the result due in each cycle (exactly 3 after issue), with its thread, and nothing else.
// Dividers (DEPTH = DIV_INFLIGHT and DEPTH = 1): each thread's results and tags in its order, with
// their thread, held while out_ready is low, count, no progress stall, flushed requests never come out.
// A directed prologue measures the divider's latency into an idle unit. A failing RTL
// assertion stops the run (Verilator's default) with a non-zero exit and no PASS line.
//   Vtb_muldiv +seed=<n> +n=<requests issued per unit>
module tb_muldiv;
  import tg_pkg::*, tg_core_pkg::*;

  localparam int TW = 8;                                // tag width
  localparam int ND = 2;                                // dividers under test
  localparam int DDEPTH [ND] = '{DIV_INFLIGHT, 1};
  localparam int NT = NUM_THREADS;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  tid_t fl_tid = '0;                                    // the flushed thread
  always #5 clk = ~clk;
  int seed = 1, n = 20000, errors = 0, cyc = 0;

  // ---- Units under test ----
  logic          m_valid, m_word, m_out_valid;
  mul_op_e       m_op;
  logic [63:0]   m_a, m_b, m_out_res;
  logic [TW-1:0] m_tag, m_out_tag;
  tid_t          m_tid, m_out_tid;
  tg_mul #(.TAG_W(TW)) u_mul (
    .clk, .rst, .flush, .flush_tid(fl_tid), .in_tid(m_tid), .out_tid(m_out_tid),
    .in_valid(m_valid), .in_op(m_op), .in_word(m_word), .in_a(m_a),
    .in_b(m_b), .in_tag(m_tag), .out_valid(m_out_valid), .out_res(m_out_res), .out_tag(m_out_tag));

  logic          d_valid [ND], d_word [ND], d_ready [ND], d_out_valid [ND];
  div_op_e       d_op [ND];
  logic [63:0]   d_a [ND], d_b [ND], d_out_res [ND];
  logic [TW-1:0] d_tag [ND], d_out_tag [ND];
  tid_t          d_tid [ND], d_out_tid [ND];
  int            d_count [ND];
  for (genvar i = 0; i < ND; i++) begin : g_div
    logic [idx_w(DDEPTH[i] + 1)-1:0] count;
    tg_div #(.TAG_W(TW), .DEPTH(DDEPTH[i])) u_div (
      .clk, .rst, .flush, .flush_tid(fl_tid), .in_tid(d_tid[i]), .out_tid(d_out_tid[i]),
      .in_valid(d_valid[i]), .in_op(d_op[i]), .in_word(d_word[i]),
      .in_a(d_a[i]), .in_b(d_b[i]), .in_tag(d_tag[i]), .out_valid(d_out_valid[i]),
      .out_ready(d_ready[i]), .out_res(d_out_res[i]), .out_tag(d_out_tag[i]), .count);
    assign d_count[i] = int'(count);
  end

  // ---- References ----
  function automatic logic [63:0] mul_ref(mul_op_e op, logic word, logic [63:0] a, b);
    logic [127:0] xa, xb, p;
    xa = (op == MUL_H || op == MUL_HSU) ? {{64{a[63]}}, a} : {64'b0, a};
    xb = (op == MUL_H) ? {{64{b[63]}}, b} : {64'b0, b};
    p  = xa * xb;
    if (word) return {{32{p[31]}}, p[31:0]};
    return (op == MUL_LO) ? p[63:0] : p[127:64];
  endfunction

  function automatic logic [63:0] div_ref(div_op_e op, logic word, logic [63:0] a, b);
    logic signed [63:0] sa, sb, sr;
    logic signed [31:0] wa, wb, wr;
    sa = a;
    sb = b;
    wa = a[31:0];
    wb = b[31:0];
    if (word) begin
      case (op)
        DIV_S: if (wb == 0) wr = -1; else if (wa == 32'sh8000_0000 && wb == -1) wr = wa; else wr = wa / wb;
        DIV_U: if (wb == 0) wr = -1; else wr = a[31:0] / b[31:0];
        REM_S: if (wb == 0) wr = wa; else if (wa == 32'sh8000_0000 && wb == -1) wr = 0; else wr = wa % wb;
        default: if (wb == 0) wr = wa; else wr = a[31:0] % b[31:0];
      endcase
      return {{32{wr[31]}}, wr};
    end
    case (op)
      DIV_S: if (sb == 0) sr = -1; else if (sa == 64'sh8000_0000_0000_0000 && sb == -1) sr = sa; else sr = sa / sb;
      DIV_U: if (sb == 0) sr = -1; else sr = a / b;
      REM_S: if (sb == 0) sr = sa; else if (sa == 64'sh8000_0000_0000_0000 && sb == -1) sr = 0; else sr = sa % sb;
      default: if (sb == 0) sr = sa; else sr = a % b;
    endcase
    return sr;
  endfunction

  // ---- Stimulus ----
  typedef struct {
    logic [1:0]    op;      // mul_op_e or div_op_e
    logic          word;
    logic [63:0]   a, b, res;
    logic [TW-1:0] tag;
    tid_t          tid;
  } req_t;

  function automatic logic [63:0] rnd_opnd();
    logic [63:0] r;
    int unsigned k;
    r = {$urandom, $urandom};
    k = $urandom % 64;
    case ($urandom % 20)
      0:  return 64'd0;
      1:  return 64'd1;
      2:  return '1;                                     // -1
      3:  return 64'h8000_0000_0000_0000;                // INT64_MIN
      4:  return 64'h7fff_ffff_ffff_ffff;                // INT64_MAX
      5:  return 64'($urandom % 16);                     // small
      6:  return -64'($urandom % 16);                    // small negative
      7:  return {r[63:32], 32'h8000_0000};              // INT32_MIN in the low word
      8:  return {r[63:32], 32'hffff_ffff};              // -1 in the low word
      9:  return {r[63:32], 32'h0000_0000};              // zero low word: W divide by zero
      10: return {r[63:32], 32'h0000_0001};
      11: return {r[63:32], 32'h7fff_ffff};
      12: return {r[63:32], r[31:0] >> (k % 32)};        // short low word
      13: return 64'd1 << k;                             // powers of two
      14: return -(64'd1 << k);
      15: return r >> k;                                 // random length
      16: return ~(r >> k);                              // negative, random length
      default: return r;
    endcase
  endfunction

  int p_t1;                         // per cent of requests (and flushes) on thread 1 (NT > 1)
  function automatic tid_t rnd_tid();
    return (NT > 1 && $urandom % 100 < p_t1) ? tid_t'(1) : tid_t'(0);
  endfunction

  function automatic req_t mul_req();
    req_t q;
    q.op   = 2'($urandom % 4);
    q.word = q.op == MUL_LO && $urandom % 3 == 0;
    q.a    = rnd_opnd();
    q.b    = rnd_opnd();
    q.tag  = TW'($urandom);
    q.tid  = rnd_tid();
    q.res  = mul_ref(mul_op_e'(q.op), q.word, q.a, q.b);
    return q;
  endfunction

  function automatic req_t div_req();
    req_t q;
    q.op   = 2'($urandom % 4);
    q.word = 1'($urandom % 2);
    q.a    = rnd_opnd();
    q.b    = rnd_opnd();
    if ($urandom % 8 == 0) q.a = q.b * 64'($urandom % 9) + 64'($urandom % 2);  // (near) multiples
    q.tag  = TW'($urandom);
    q.tid  = rnd_tid();
    q.res  = div_ref(div_op_e'(q.op), q.word, q.a, q.b);
    return q;
  endfunction

  function automatic string req_str(input string unit, input req_t q);
    return $sformatf("%s op %0d%s a %h b %h tag %h thread %0d", unit, q.op, q.word ? "w" : "", q.a, q.b, q.tag, q.tid);
  endfunction

  task automatic err(input string msg);
    errors++;
    if (errors <= 10) $display("ERROR cycle %0d: %s", cyc, msg);
  endtask

  // ---- Per-cycle model and checks ----
  req_t mslot [4];                  // multiplier: the request due in cycle c is in slot c % 4
  bit   mslot_v [4];
  req_t dq [ND][NT][$];             // divider i: thread t's requests in the unit, oldest first
  bit   d_hold [ND];                // divider i presented a result that was not taken
  logic [63:0]   hold_res [ND];
  logic [TW-1:0] hold_tag [ND];
  int   d_wait [ND];                // cycles with requests in the unit but no result shown
  int   m_issued, m_done, m_killed, d_issued [ND], d_done [ND], d_killed [ND];
  int   m_kept, d_kept [ND], d_done_t [ND][NT];   // requests a flush of the other thread left alone
  int   mcov [5], dcov [8], n_dz, n_ovf;
  bit   m_go, d_go [ND], fl_go, drain;
  int   p_mul, p_div, p_rdy, p_flush;   // issue and out_ready per cent; flush per mille

  function automatic int d_size(input int i);   // divider i's requests, every thread
    d_size = 0;
    for (int t = 0; t < NT; t++) d_size += dq[i][t].size();
  endfunction

  function automatic bit pending();   // requests still expected from any unit
    pending = mslot_v.or();
    for (int i = 0; i < ND; i++) if (d_size(i) != 0) pending = 1'b1;
  endfunction

  task automatic new_phase();
    p_mul   = ($urandom % 4 == 0) ? 100 : $urandom % 101;
    p_div   = ($urandom % 4 == 0) ? 100 : $urandom % 101;
    p_rdy   = ($urandom % 4 == 0) ? 100 : 5 + $urandom % 96;
    p_flush = ($urandom % 3 == 0) ? 0 : $urandom % 30;
    case ($urandom % 4)
      0:       p_t1 = 0;
      1:       p_t1 = 100;
      default: p_t1 = 10 + $urandom % 81;
    endcase
  endtask

  // One cycle, from the falling edge: check this cycle's outputs, then drive the inputs
  // the next rising edge samples. Inputs that are not valid carry random data.
  task automatic step();
    req_t q;
    bit   room;
    @(negedge clk);
    cyc++;
    if (cyc % 500 == 0) new_phase();

    // Multiplier: exactly the request issued 3 cycles ago
    if (mslot_v[cyc % 4]) begin
      q = mslot[cyc % 4];
      mslot_v[cyc % 4] = 1'b0;
      if (!m_out_valid) err({"missing result: ", req_str("mul", q)});
      else if (m_out_res !== q.res || m_out_tag !== q.tag || m_out_tid !== q.tid)
        err($sformatf("%s: got %h tag %h thread %0d, want %h", req_str("mul", q), m_out_res, m_out_tag,
                      m_out_tid, q.res));
      else begin
        m_done++;
        mcov[q.word ? 4 : q.op]++;
      end
    end else if (m_out_valid) err($sformatf("mul: unexpected result %h tag %h", m_out_res, m_out_tag));

    flush  = fl_go && $urandom % 1000 < p_flush;
    fl_tid = rnd_tid();

    for (int i = 0; i < ND; i++) begin
      if (d_hold[i] && !(d_out_valid[i] && d_out_res[i] === hold_res[i] && d_out_tag[i] === hold_tag[i]))
        err($sformatf("div%0d: result %h tag %h not held", i, hold_res[i], hold_tag[i]));
      if (d_count[i] != d_size(i))
        err($sformatf("div%0d: count %0d, want %0d", i, d_count[i], d_size(i)));
      if (d_out_valid[i] && dq[i][d_out_tid[i]].size() == 0)
        err($sformatf("div%0d: unexpected result %h tag %h thread %0d", i, d_out_res[i], d_out_tag[i], d_out_tid[i]));
      d_wait[i] = (d_size(i) != 0 && !d_out_valid[i]) ? d_wait[i] + 1 : 0;
      if (d_wait[i] == 100) err($sformatf("div%0d: no result for 100 cycles", i));
      // Result handshake (it counts in a flush cycle too: the result was presented)
      d_ready[i] = drain || $urandom % 100 < p_rdy;
      if (d_out_valid[i] && d_ready[i] && dq[i][d_out_tid[i]].size() != 0) begin
        q = dq[i][d_out_tid[i]].pop_front();
        if (d_out_res[i] !== q.res || d_out_tag[i] !== q.tag)
          err($sformatf("%s: got %h tag %h, want %h", req_str($sformatf("div%0d", i), q),
                        d_out_res[i], d_out_tag[i], q.res));
        else begin
          d_done[i]++;
          d_done_t[i][q.tid]++;
          dcov[{q.word, q.op}]++;
          if (q.word ? q.b[31:0] == 0 : q.b == 0) n_dz++;
          if (q.op inside {DIV_S, REM_S} && (q.word ? q.b[31:0] == '1 && q.a[31:0] == 32'h8000_0000
                                                    : q.b == '1 && q.a == 64'h8000_0000_0000_0000)) n_ovf++;
        end
      end
      d_hold[i]   = d_out_valid[i] && !d_ready[i] && !(flush && d_out_tid[i] == fl_tid);
      hold_res[i] = d_out_res[i];
      hold_tag[i] = d_out_tag[i];
      // New request: the unit never holds more than DEPTH, every thread together
      room = d_size(i) < DDEPTH[i];
      if (flush) begin
        // (a flush that kills the divide in progress restarts the wait: the sibling's comes next)
        if (dq[i][fl_tid].size() != 0) d_wait[i] = 0;
        d_killed[i] += dq[i][fl_tid].size();
        dq[i][fl_tid].delete();
        d_kept[i] += d_size(i);
      end
      q = div_req();
      d_valid[i] = d_go[i] && room && $urandom % 100 < p_div;
      d_op[i]    = div_op_e'(q.op);
      d_word[i]  = q.word;
      d_a[i]     = q.a;
      d_b[i]     = q.b;
      d_tag[i]   = q.tag;
      d_tid[i]   = q.tid;
      if (d_valid[i]) begin
        d_issued[i]++;
        if (flush && q.tid == fl_tid) d_killed[i]++;
        else dq[i][q.tid].push_back(q);
      end
    end

    if (flush) begin
      for (int s = 0; s < 4; s++)
        if (mslot_v[s] && mslot[s].tid == fl_tid) begin
          m_killed++;
          mslot_v[s] = 1'b0;
        end else if (mslot_v[s]) m_kept++;
    end
    q = mul_req();
    m_valid = m_go && $urandom % 100 < p_mul;
    m_op    = mul_op_e'(q.op);
    m_word  = m_valid ? q.word : 1'($urandom);    // in_word only with MUL_LO when valid
    m_a     = q.a;
    m_b     = q.b;
    m_tag   = q.tag;
    m_tid   = q.tid;
    if (m_valid) begin
      m_issued++;
      if (flush && q.tid == fl_tid) m_killed++;
      else begin
        mslot[(cyc + 3) % 4]   = q;
        mslot_v[(cyc + 3) % 4] = 1'b1;
      end
    end
  endtask

  // ---- Directed: one divide into the idle divider 0, out_ready high; returns the cycles
  // from in_valid to out_valid ----
  task automatic div_latency(input div_op_e op, input logic word, input logic [63:0] a, b,
                             output int lat);
    logic [63:0] want;
    want = div_ref(op, word, a, b);
    d_ready[0] = 1'b1;
    d_valid[0] = 1'b1;
    d_op[0]    = op;
    {d_word[0], d_a[0], d_b[0], d_tag[0], d_tid[0]} = {word, a, b, TW'(8'h5a), tid_t'(0)};
    lat = 0;
    do begin
      @(negedge clk);
      d_valid[0] = 1'b0;
      lat++;
    end while (!d_out_valid[0] && lat < 200);
    if (d_out_res[0] !== want || d_out_tag[0] !== TW'(8'h5a))
      err($sformatf("div latency case op %0d%s a %h b %h: got %h, want %h", op, word ? "w" : "",
                    a, b, d_out_res[0], want));
    @(negedge clk);                 // the result left at the last rising edge
    if (d_out_valid[0] || d_count[0] != 0) err("div latency case: unit not idle after the result");
  endtask

  int lat64, lat64ovf, latw, latw_min, lat_dz, lat_small, lat_1000;
  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("n=%d", n));
    $display("tb_muldiv: seed %0d n %0d (requests per unit), divider DEPTH %0d and %0d",
             seed, n, DDEPTH[0], DDEPTH[1]);
    void'($urandom(seed));
    {m_valid, m_word, m_a, m_b, m_tag, m_tid} = '0;
    m_op = MUL_LO;
    for (int i = 0; i < ND; i++) begin
      {d_valid[i], d_word[i], d_ready[i], d_a[i], d_b[i], d_tag[i], d_tid[i]} = '0;
      d_op[i] = DIV_S;
    end
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    div_latency(DIV_U, 1'b0, '1, 64'd1, lat64);                         // 64 quotient bits
    div_latency(DIV_S, 1'b0, 64'h8000_0000_0000_0000, '1, lat64ovf);   // overflow, 64 bits
    div_latency(DIV_U, 1'b1, 64'hffff_ffff, 64'd1, latw);               // 32 quotient bits
    div_latency(DIV_S, 1'b1, 64'h8000_0000, '1, latw_min);              // W overflow, 32 bits
    div_latency(REM_S, 1'b0, 64'd5, 64'd0, lat_dz);                     // b = 0
    div_latency(DIV_U, 1'b0, 64'd3, 64'd7, lat_small);                  // fewer bits than b
    div_latency(DIV_U, 1'b0, 64'd1000, 64'd7, lat_1000);                // 8 quotient bits
    $display("div latency, in_valid to out_valid, idle unit: 64-bit %0d (overflow %0d), W %0d (overflow %0d), b=0 %0d, 3/7 %0d, 1000/7 %0d",
             lat64, lat64ovf, latw, latw_min, lat_dz, lat_small, lat_1000);

    new_phase();
    fl_go = 1'b1;
    do begin
      m_go = m_issued < n;
      for (int i = 0; i < ND; i++) d_go[i] = d_issued[i] < n;
      step();
    end while (m_go || d_go.or());
    // Drain: no new requests or flushes, results always taken; then nothing more may come out
    {m_go, fl_go, drain} = 3'b001;
    d_go = '{default: 1'b0};
    for (int k = 0; k < 1000 && pending(); k++) step();
    repeat (8) step();
    if (pending()) err("requests still pending after the drain");
    for (int i = 0; i < ND; i++)
      if (d_issued[i] != d_done[i] + d_killed[i]) err($sformatf("div%0d: requests lost", i));
    if (m_issued != m_done + m_killed) err("mul: requests lost");

    $display("mul:  %0d issued, %0d checked (MUL %0d MULH %0d MULHSU %0d MULHU %0d MULW %0d), %0d flushed, %0d kept by flushes of the other thread",
             m_issued, m_done, mcov[0], mcov[1], mcov[2], mcov[3], mcov[4], m_killed, m_kept);
    for (int i = 0; i < ND; i++)
      $display("div%0d: DEPTH %0d, %0d issued, %0d checked (thread 0 %0d, thread 1 %0d), %0d flushed, %0d kept by flushes of the other thread",
               i, DDEPTH[i], d_issued[i], d_done[i], d_done_t[i][0], (NT > 1) ? d_done_t[i][NT-1] : 0, d_killed[i], d_kept[i]);
    $display("div ops checked: DIV %0d DIVU %0d REM %0d REMU %0d DIVW %0d DIVUW %0d REMW %0d REMUW %0d; b=0 %0d, overflow %0d",
             dcov[0], dcov[1], dcov[2], dcov[3], dcov[4], dcov[5], dcov[6], dcov[7], n_dz, n_ovf);
    if (errors == 0) $display("PASS tb_muldiv (%0d cycles)", cyc);
    else begin
      $display("FAIL tb_muldiv: %0d errors", errors);
      $fatal(1, "tb_muldiv failed");
    end
    $finish;
  end
endmodule
