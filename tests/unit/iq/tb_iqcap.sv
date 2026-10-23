// Unit test of tg_iq's per-thread caps flags (M7 step 7; rtl/core/issue/tg_iq.sv): room_ge_q,
// bank_nfree_q (with bank_free_q and bank_free2_q), occ_q and, with BANK_CAP, bank_left_q.
// Two threads dispatch random groups (slot k writes bank k) into rows with no dependencies; the
// queue issues them oldest first under random select blocks, and random flushes kill a thread's
// rows. A reference count, kept here from valid_o and the thread each dispatch writes (the row
// alloc_oh_o names), checks every flag each cycle against the cap_on of the cycle before.
// The bench plays rename: in most phases it dispatches only within room_ge_q, and then checks
// that no thread passes its cap (a thread above it, from a phase with the caps off, only drains).
// The drain phase is the WFI case (the coordinator, 10-21): with the caps off one thread fills
// the queue past its cap; then the caps come back and the other thread must get a row within a
// bound while the first drains.
//   Vtb_iqcap +seed=<n> +n=<cycles>
module tb_iqcap;
  import tg_pkg::*;
  parameter int ROWS     = 10;
  parameter int DW       = 2;
  parameter int CAP_PCT  = 50;
  parameter bit BANK_CAP = 1'b1;
  localparam int CAP  = (ROWS * CAP_PCT) / 100;
  localparam int RMAX = 2 * DW;
  localparam int OCW  = idx_w(ROWS + 1);
  localparam int NT   = 2;
  localparam int PW   = 8;
  localparam int ROBW = 8;
  localparam int NCOL = 8;
  localparam int DRAIN_MAX = 8 * ROWS + 40;    // the woken thread's first row, at the latest

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;
  int seed = 1, n = 50000, errors = 0, cyc = 0;

  // ---- Unit under test ----
  logic [DW-1:0]                 disp_valid;
  tid_t [DW-1:0]                 disp_tid;
  logic [DW-1:0][ROBW-1:0]       disp_rob;
  logic [DW-1:0][PW-1:0]         disp_payload;
  logic [DW-1:0]                 bank_free_q, bank_free2_q;
  logic [DW-1:0][1:0]            bank_nfree_q;
  logic                          cap_on;
  logic [NT-1:0][RMAX-1:0]       room_ge_q;
  logic [NT-1:0][OCW-1:0]        occ_q;
  logic [NT-1:0][DW-1:0][1:0]    bank_left_q;
  logic                          sel_block, flush_valid;
  tid_t                          flush_tid;
  logic [ROWS-1:0]               valid_o;
  logic [DW-1:0][ROWS-1:0]       alloc_oh_o;
  logic                          iss_valid_q;
  logic [PW-1:0]                 iss_payload;
  tg_iq #(.ROWS(ROWS), .DW(DW), .NCOL(NCOL), .PAYLOAD_W(PW), .CAP(CAP), .STALE(0), .WAKE_NOW(1'b0),
          .WAKE_ENC(1), .ROBW(ROBW), .EARLY_W(PW), .MX(1'b0), .RA(1), .PRE_RDY(1'b0), .CBLK(1'b0),
          .BANK_CAP(BANK_CAP)) u_iq (
    .clk, .rst, .disp_valid, .disp_tid, .disp_dep('0), .disp_dep_ph('0), .disp_wake_oh('0), .disp_rob,
    .disp_payload, .bank_free_q, .bank_free2_q, .bank_nfree_q, .cap_on, .room_ge_q, .occ_q, .bank_left_q,
    .w('0), .w_next('0), .w1('0), .col_clr('0), .cancel(1'b0), .sel_block, .disp_cblk('0), .cls_block(1'b0),
    .wake_now(), .busy(), .disp_mdep('0), .mx_issued('0), .mx_free('0), .issued_o(), .free_o(), .valid_o,
    .alloc_oh_o, .flush_valid, .flush_tid, .flush_all(1'b1), .flush_rob('0), .iss_valid_q, .iss_payload,
    .iss_early_n());

  // ---- Reference ----
  tid_t [ROWS-1:0] mtid;                // the thread each row was last written by
  int              pend_row [DW];       // rows written at the next edge (-1: none)
  tid_t            pend_tid [DW];
  logic            cap_prev;            // cap_on in the cycle the flags were computed
  int              cnt_prev [NT];       // each thread's rows before the last dispatch
  logic [NT-1:0]   obeyed;              // the last dispatch, per thread, kept within room_ge_q

  function automatic int bank_rows(input int k);
    return (ROWS - k + DW - 1) / DW;
  endfunction
  function automatic int onehot_idx(input logic [ROWS-1:0] v);
    for (int r = 0; r < ROWS; r++) if (v[r]) return r;
    return -1;
  endfunction

  task automatic check();
    int cnt [NT];
    int cntb [NT][DW];
    int fr [DW];
    for (int t = 0; t < NT; t++) begin
      cnt[t] = 0;
      for (int k = 0; k < DW; k++) cntb[t][k] = 0;
    end
    for (int k = 0; k < DW; k++) fr[k] = 0;
    for (int r = 0; r < ROWS; r++) begin
      if (valid_o[r]) begin
        cnt[int'(mtid[r])]++;
        cntb[int'(mtid[r])][r % DW]++;
      end else begin
        fr[r % DW]++;
      end
    end
    for (int k = 0; k < DW; k++) begin
      if (int'(bank_nfree_q[k]) != ((fr[k] > 3) ? 3 : fr[k]) || bank_free_q[k] != (fr[k] >= 1) ||
          bank_free2_q[k] != (fr[k] >= 2)) begin
        errors++;
        if (errors < 20) $display("cycle %0d: bank %0d has %0d free rows: nfree %0d free %b free2 %b", cyc, k, fr[k],
                                  bank_nfree_q[k], bank_free_q[k], bank_free2_q[k]);
      end
    end
    for (int t = 0; t < NT; t++) begin
      if (int'(occ_q[t]) != cnt[t]) begin
        errors++;
        if (errors < 20) $display("cycle %0d: thread %0d holds %0d rows, occ_q %0d", cyc, t, cnt[t], occ_q[t]);
      end
      for (int m = 1; m <= RMAX; m++) begin
        if (room_ge_q[t][m-1] != (!cap_prev || CAP >= ROWS || cnt[t] + m <= CAP)) begin   // (no cap at 100%)
          errors++;
          if (errors < 20) $display("cycle %0d: thread %0d, %0d rows, cap %0d, caps %b: room_ge[%0d] %b", cyc, t,
                                    cnt[t], CAP, cap_prev, m, room_ge_q[t][m-1]);
        end
      end
      for (int k = 0; k < DW; k++)
        for (int j = 1; j <= 2; j++)
          if (bank_left_q[t][k][j-1] != (!BANK_CAP || !cap_prev || cntb[t][k] + j <= bank_rows(k) - 1)) begin
            errors++;
            if (errors < 20) $display("cycle %0d: thread %0d, %0d of bank %0d's %0d rows: bank_left[%0d] %b", cyc, t,
                                      cntb[t][k], k, bank_rows(k), j, bank_left_q[t][k][j-1]);
          end
      // The bound rename keeps: a dispatch within room_ge_q never takes a thread past its cap
      if (obeyed[t] && cnt[t] > CAP && cnt[t] > cnt_prev[t]) begin
        errors++;
        if (errors < 20) $display("cycle %0d: thread %0d grew from %0d to %0d rows past its cap %0d", cyc, t,
                                  cnt_prev[t], cnt[t], CAP);
      end
      cnt_prev[t] = cnt[t];
    end
  endtask

  // ---- Stimulus ----
  // Phases (each 300-1500 cycles): 0 both threads, within the caps; 1 thread 0 only, caps off (a sibling in
  // WFI), not obeying; 2 the drain: caps back on, both threads, within the caps, thread 1 timed to its first
  // row; 3 both threads, ignoring the caps (rows past the cap, the flags at 0); 4 one thread at random rates
  int   phase = 0, phase_left = 0, drain_wait = -1, drains = 0, max_wait = 0;
  int   p_disp [NT];
  int   p_block, p_flush;
  logic obey;
  logic t1_got;

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("n=%d", n));
    void'($urandom(seed));
    disp_valid = '0; disp_tid = '0; disp_rob = '0; disp_payload = '0;
    sel_block = 1'b0; flush_valid = 1'b0; flush_tid = '0; cap_on = 1'b1;
    for (int k = 0; k < DW; k++) pend_row[k] = -1;
    for (int t = 0; t < NT; t++) cnt_prev[t] = 0;
    obeyed = '0; cap_prev = 1'b1; mtid = '0;
    repeat (4) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    while (cyc < n) begin
      cyc++;
      // The rows written at the last edge
      for (int k = 0; k < DW; k++)
        if (pend_row[k] >= 0) begin
          if (!valid_o[pend_row[k]]) begin
            errors++;
            if (errors < 20) $display("cycle %0d: row %0d written at the last edge is not valid", cyc, pend_row[k]);
          end
          mtid[pend_row[k]] = pend_tid[k];
          pend_row[k] = -1;
        end
      check();
      // The drain's progress (phase 2): thread 1's first row since the caps came back
      if (drain_wait >= 0) begin
        if (t1_got) begin
          if (drain_wait > max_wait) max_wait = drain_wait;
          drains++;
          drain_wait = -1;
        end else if (++drain_wait > DRAIN_MAX) begin
          errors++;
          $display("cycle %0d: thread 1 has had no row for %0d cycles since the caps came back", cyc, drain_wait);
          drain_wait = -1;
        end
      end
      // Next phase
      if (phase_left == 0) begin
        phase = (phase + 1) % 5;
        phase_left = 300 + int'($urandom_range(1200));
        unique case (phase)
          0: begin p_disp = '{70, 70}; obey = 1'b1; cap_on = 1'b1; end
          1: begin p_disp = '{90, 0};  obey = 1'b0; cap_on = 1'b0; end
          2: begin p_disp = '{90, 60}; obey = 1'b1; cap_on = 1'b1; drain_wait = 0; end
          3: begin p_disp = '{80, 80}; obey = 1'b0; cap_on = int'($urandom_range(1)) == 1; end
          default: begin
            p_disp[0] = int'($urandom_range(100)); p_disp[1] = int'($urandom_range(100));
            obey = int'($urandom_range(3)) != 0; cap_on = int'($urandom_range(3)) != 0;
          end
        endcase
        p_block = int'($urandom_range(60));
        p_flush = int'($urandom_range(3));
      end
      phase_left--;
      // A flush (no dispatch in its cycle, as DS)
      flush_valid = int'($urandom_range(999)) < p_flush * 10 && phase != 2;
      flush_tid   = tid_t'($urandom_range(1));
      sel_block   = int'($urandom_range(99)) < p_block;
      // A group of one thread: a random subset of the slots, each to its bank
      disp_valid = '0;
      obeyed = '0;
      t1_got = 1'b0;
      if (!flush_valid) begin
        int t, want;
        logic [DW-1:0] s;
        t = int'($urandom_range(1));
        if (int'($urandom_range(99)) >= p_disp[t]) t = 1 - t;
        if (int'($urandom_range(99)) < p_disp[t]) begin
          s = DW'($urandom_range((1 << DW) - 1));
          want = $countones(s);
          // As rename: a free row in each slot's bank, and within the thread's room when obeying
          for (int k = 0; k < DW; k++) if (s[k] && !bank_free_q[k]) s[k] = 1'b0;
          if (obey && want > 0 && $countones(s) > 0 && !room_ge_q[t][$countones(s) - 1]) s = '0;
          for (int k = 0; k < DW; k++) begin
            disp_valid[k]   = s[k];
            disp_tid[k]     = tid_t'(t);
            disp_rob[k]     = ROBW'($urandom);
            disp_payload[k] = PW'($urandom);
            if (s[k]) begin
              pend_row[k] = onehot_idx(alloc_oh_o[k]);
              pend_tid[k] = tid_t'(t);
            end
          end
          if (|s) begin
            obeyed[t] = obey && cap_prev;   // the flags it read were computed with cap_prev
            t1_got = t == 1;
          end
        end
      end
      cap_prev = cap_on;                    // the flags at the next edge see this cycle's cap_on
      @(negedge clk);
    end
    if (errors == 0)
      $display("PASS tb_iqcap ROWS=%0d DW=%0d CAP=%0d BANK_CAP=%0d (%0d cycles, %0d drains, longest %0d cycles)",
               ROWS, DW, CAP, BANK_CAP, cyc, drains, max_wait);
    else
      $display("FAIL tb_iqcap ROWS=%0d DW=%0d CAP=%0d: %0d errors", ROWS, DW, CAP, errors);
    $finish;
  end
endmodule
