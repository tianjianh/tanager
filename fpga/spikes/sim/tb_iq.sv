// Random test of the S2 scheduler pieces, tg_iq with tg_wake, against a reference model.
//   Vtb_iq +seed=<n> +cycles=<n> ; parameters STALE (0 guard, 1 phase, 2 clear), WAKE_ENC
// The TB plays dispatch, the ID allocator (ROB entries and LLTs as one pool), long-latency
// completions, shadow cancels and thread flushes. It checks:
//   - at most one grant, and it is the oldest ready row (allocation order kept by the TB);
//   - every source of a selected op was available by its select cycle (end to end);
//   - an op is selected once, unless a cancel returned it; killed ops are never selected;
//   - per-thread occupancy stays within CAP; every op drains at the end (no deadlock,
//     including rows that waited on a producer whose ID was reused).
module tb_iq
  import tg_pkg::*;
#(
  parameter int STALE    = 0,
  parameter int WAKE_ENC = 0
);
  localparam int ROWS  = 10;
  localparam int DW    = DISPATCH_WIDTH;
  localparam int NCOL  = 24;
  localparam int CAP   = (ROWS * IQ_CAP_PCT) / 100;
  localparam int PW    = 32;
  localparam int ROBW  = 7;
  localparam int RMW   = idx_w(DW + 1);
  localparam int MAXOP = 1 << 17;
  localparam int BANK_ROWS = (ROWS + DW - 1) / DW;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;

  // DUT
  logic [DW-1:0]           disp_valid;
  tid_t [DW-1:0]           disp_tid;
  logic [DW-1:0][NCOL-1:0] disp_dep, disp_dep_ph, disp_wake_oh;
  logic [DW-1:0][ROBW-1:0] disp_rob;
  logic [DW-1:0][PW-1:0]   disp_payload;
  logic [DW-1:0]           bank_free_q;
  logic [NUM_THREADS-1:0][RMW-1:0] room_q;
  logic [NCOL-1:0] w_q, w1_q, phase_q, wake_now, busy, wake_reg, alloc, col_clr, cancel_ids;
  logic cancel, flush_valid, flush_all;
  tid_t flush_tid;
  logic [ROBW-1:0] flush_rob;
  logic iss_valid_q;
  logic [PW-1:0] iss_payload_q;

  tg_iq #(.ROWS(ROWS), .DW(DW), .NCOL(NCOL), .PAYLOAD_W(PW), .CAP(CAP), .STALE(STALE),
          .WAKE_NOW(1'b1), .WAKE_ENC(WAKE_ENC), .ROBW(ROBW)) u_iq (
    .clk, .rst, .disp_valid, .disp_tid, .disp_dep, .disp_dep_ph, .disp_wake_oh, .disp_rob,
    .disp_payload, .bank_free_q, .room_q, .w(w_q), .w1(w1_q), .col_clr, .cancel, .wake_now,
    .busy, .flush_valid, .flush_tid, .flush_all, .flush_rob, .iss_valid_q, .iss_payload_q);
  tg_wake #(.NCOL(NCOL), .NNOW(1), .STALE(STALE)) u_wake (
    .clk, .rst, .wake_now, .wake_reg, .alloc, .cancel, .cancel_ids, .w_q, .w1_q, .phase_q);

  // Reference state
  typedef struct {
    int  dest;           // wakeup ID
    bit  lat1;           // wakes at select; else completes later through wake_reg
    int  src [2];        // producer op numbers, -1 if none
    int  tid;
    int  rob;            // per-thread sequence (age for flushes)
    int  sel_cycle;      // last select cycle
    int  avail;          // first cycle a consumer may be selected, -1 if not yet known
    bit  issued, killed, done;
    int  done_at;        // completion cycle scheduled for long ops, -1 if none
  } op_t;
  op_t ops [MAXOP];
  int nops = 0;
  int id_owner [NCOL];     // op holding each ID, -1 if free
  int id_freed_at [NCOL];  // cycle the ID was last freed
  int row_op [ROWS];       // op in each row, -1 if empty
  int row_seq [ROWS];      // allocation order of each row's op
  int disp_op [DW];        // op dispatched by each port this cycle
  int disp_seq [DW];
  int seq = 0, cyc = 0, errors = 0, nsel = 0, ncancel = 0, nflush = 0, nreuse = 0;
  int seed = 1, cycles = 20000;
  int rob_next [NUM_THREADS];
  bit draining = 1'b0;

  function automatic void fail(input string msg);
    errors++;
    if (errors <= 10) $display("ERROR cycle %0d: %s", cyc, msg);
  endfunction

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    void'($urandom(seed));
    $display("tb_iq: STALE %0d WAKE_ENC %0d DW %0d CAP %0d seed %0d cycles %0d",
             STALE, WAKE_ENC, DW, CAP, seed, cycles);
    for (int c = 0; c < NCOL; c++) begin
      id_owner[c] = -1;
      id_freed_at[c] = -10;
    end
    for (int r = 0; r < ROWS; r++) row_op[r] = -1;
    for (int t = 0; t < NUM_THREADS; t++) rob_next[t] = 0;
  end

  // Drive inputs at the falling edge from the state after the last rising edge.
  always @(negedge clk) begin
    automatic int nthis;
    automatic int used [NUM_THREADS];
    disp_valid = '0; disp_dep = '0; disp_dep_ph = '0; disp_wake_oh = '0;
    disp_tid = '0; disp_rob = '0; disp_payload = '0;
    wake_reg = '0; alloc = '0; col_clr = '0; cancel_ids = '0;
    cancel = 1'b0; flush_valid = 1'b0; flush_all = 1'b0; flush_tid = '0; flush_rob = '0;
    for (int t = 0; t < NUM_THREADS; t++) used[t] = 0;
    if (!rst) begin
      // Long-op completions due now
      for (int i = 0; i < nops; i++) begin
        if (!ops[i].lat1 && ops[i].issued && !ops[i].killed && !ops[i].done
            && ops[i].done_at == cyc) begin
          wake_reg[ops[i].dest] = 1'b1;
          ops[i].done = 1'b1;
          ops[i].avail = cyc + 1;
        end
      end
      // Free IDs whose producer has been available a while (retire, LLT release) or was
      // killed. The guard variant may not reuse an ID while a row still depends on it.
      for (int c = 0; c < NCOL; c++) begin
        automatic int o = id_owner[c];
        if (o >= 0 && (ops[o].killed || (ops[o].avail >= 0 && ops[o].avail + 3 <= cyc))
            && ($urandom % 4) == 0 && !(STALE == 0 && busy[c])) begin
          id_owner[c] = -1;
          id_freed_at[c] = cyc;
          if (STALE == 2) col_clr[c] = 1'b1;
        end
      end
      // Shadow cancel (rare)
      if (!draining && ($urandom % 97) == 0) begin
        cancel = 1'b1;
        ncancel++;
      end
      // Thread flush (rare): one thread's ops younger than a point, or all of them
      if (!draining && !cancel && ($urandom % 211) == 0) begin
        automatic int t = $urandom % NUM_THREADS;
        automatic int back = $urandom % 6;
        flush_valid = 1'b1;
        flush_tid = tid_t'(t);
        flush_all = ($urandom % 4) == 0;
        flush_rob = ROBW'(rob_next[t] - 1 - back);
        nflush++;
      end
      // Dispatch
      nthis = draining ? 0 : $urandom % (DW + 1);
      for (int k = 0; k < nthis; k++) begin
        automatic int t = $urandom % NUM_THREADS;
        automatic int free_ids [$];
        automatic int o, d;
        if (!bank_free_q[k] || used[t] >= int'(room_q[t]) || nops >= MAXOP - 1) continue;
        if (flush_valid && flush_tid == tid_t'(t)) continue;   // the flushed thread stalls
        for (int c = 0; c < NCOL; c++)
          if (id_owner[c] < 0 && id_freed_at[c] < cyc) free_ids.push_back(c);
        if (free_ids.size() == 0) continue;
        o = nops++;
        d = free_ids[$urandom % free_ids.size()];
        ops[o].dest = d;
        ops[o].lat1 = ($urandom % 3) != 0;
        ops[o].tid = t;
        ops[o].rob = rob_next[t]++;
        ops[o].sel_cycle = -100;
        ops[o].avail = -1;
        ops[o].issued = 1'b0; ops[o].killed = 1'b0; ops[o].done = 1'b0; ops[o].done_at = -1;
        for (int s = 0; s < 2; s++) begin
          automatic int c = $urandom % NCOL;
          automatic int p = id_owner[c];
          ops[o].src[s] = -1;
          if (($urandom % 3) == 0 || p < 0 || c == d) continue;
          if (ops[p].killed || ops[p].tid != t) continue;
          // a pending producer is always a dependency; an available one sometimes
          if (ops[p].avail < 0 || ops[p].avail > cyc || ($urandom % 2) == 0) begin
            ops[o].src[s] = p;
            disp_dep[k][c] = 1'b1;
            disp_dep_ph[k][c] = phase_q[c] ^ alloc[c];   // after this cycle's allocations
          end
        end
        if (id_freed_at[d] >= 0) nreuse++;
        id_owner[d] = o;
        alloc[d] = 1'b1;
        used[t]++;
        disp_valid[k] = 1'b1;
        disp_tid[k] = tid_t'(t);
        disp_rob[k] = ROBW'(ops[o].rob);
        disp_payload[k] = PW'(o);
        if (ops[o].lat1) disp_wake_oh[k][d] = 1'b1;
        disp_op[k] = o;
        disp_seq[k] = seq++;
      end
    end
  end

  // Check and update at the rising edge, from the values the DUT sees.
  always @(posedge clk) begin
    if (!rst) begin
      if (!$onehot0(u_iq.grant)) fail("more than one grant");
      for (int r = 0; r < ROWS; r++) begin
        if (u_iq.grant[r]) begin
          automatic int o = row_op[r];
          for (int j = 0; j < ROWS; j++)
            if (j != r && u_iq.ready[j] && row_seq[j] < row_seq[r])
              fail($sformatf("row %0d granted but older row %0d is ready", r, j));
          if (o < 0) fail($sformatf("grant of empty row %0d", r));
          else if (!cancel) begin
            for (int s = 0; s < 2; s++) begin
              automatic int p = ops[o].src[s];
              if (p >= 0 && (ops[p].avail < 0 || ops[p].avail > cyc))
                fail($sformatf("op %0d selected before its source op %0d was available", o, p));
            end
            if (ops[o].issued) fail($sformatf("op %0d selected twice", o));
            if (ops[o].killed) fail($sformatf("killed op %0d selected", o));
            ops[o].sel_cycle = cyc;
            ops[o].issued = 1'b1;
            nsel++;
            if (ops[o].lat1) ops[o].avail = cyc + 1;
            else ops[o].done_at = cyc + 3 + ($urandom % 12);
          end
        end
      end
      // Cancel: ops selected in the two cycles before return to waiting (this cycle's
      // grant was not counted above)
      if (cancel) begin
        for (int i = 0; i < nops; i++) begin
          if (ops[i].issued && !ops[i].killed && ops[i].sel_cycle >= cyc - 2) begin
            ops[i].issued = 1'b0;
            ops[i].avail = -1;
            ops[i].done_at = -1;
            nsel--;
          end
        end
      end
      // Flush: kill the thread's ops younger than the point (selected ones are discarded
      // downstream)
      if (flush_valid) begin
        for (int i = 0; i < nops; i++) begin
          if (ops[i].tid == int'(flush_tid) && !ops[i].killed) begin
            automatic logic [ROBW-1:0] a = ROBW'(ops[i].rob);
            automatic logic [ROBW-1:0] b = flush_rob;
            automatic bit younger = (a[ROBW-1] == b[ROBW-1]) ? (a[ROBW-2:0] > b[ROBW-2:0])
                                                             : (a[ROBW-2:0] < b[ROBW-2:0]);
            if (flush_all || younger) ops[i].killed = 1'b1;
          end
        end
      end
      // Rows written this cycle
      for (int r = 0; r < ROWS; r++) begin
        if (u_iq.we[r]) begin
          row_op[r] = disp_op[r / BANK_ROWS];
          row_seq[r] = disp_seq[r / BANK_ROWS];
        end
      end
      // Occupancy caps (state after the previous edge)
      for (int t = 0; t < NUM_THREADS; t++) begin
        automatic int n = 0;
        for (int r = 0; r < ROWS; r++) if (u_iq.valid_q[r] && int'(u_iq.tid_q[r]) == t) n++;
        if (n > CAP) fail($sformatf("thread %0d holds %0d rows, cap %0d", t, n, CAP));
      end
      if (iss_valid_q && int'(iss_payload_q) >= nops) fail("issue of an unknown op");
      cyc++;
    end
  end

  initial begin
    automatic int left = 0;
    repeat (5) @(posedge clk);
    @(negedge clk) rst = 1'b0;
    repeat (cycles) @(posedge clk);
    draining = 1'b1;
    repeat (600) @(posedge clk);
    for (int i = 0; i < nops; i++) begin
      if (!ops[i].killed && !ops[i].issued) begin
        left++;
        if (left <= 5) $display("  op %0d never selected (dest %0d, sources %0d %0d)", i,
                                ops[i].dest, ops[i].src[0], ops[i].src[1]);
      end
    end
    if (left > 0) fail($sformatf("%0d ops never selected (deadlock)", left));
    $display("tb_iq: ops %0d selected %0d cancels %0d flushes %0d ID reuses %0d",
             nops, nsel, ncancel, nflush, nreuse);
    if (errors == 0) $display("PASS tb_iq");
    else $display("FAIL tb_iq: %0d errors", errors);
    $finish;
  end
endmodule
