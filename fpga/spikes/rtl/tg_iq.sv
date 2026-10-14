// Issue queue: dependency-vector wakeup and oldest-first select (plan §4.6). Spike S2,
// written to production intent for the core track to adopt.
//
// Rows. ROWS entries, banked by dispatch port (plan §4.15): port k writes only rows of
// bank k (rows r with r mod DW = k, interleaved so every port has rows even when ROWS is
// small), so a row has one write source and the age matrix one writer per bank.
//
// Readiness. A row waits on wakeup IDs: NCOL columns, the ROB entries then the long-
// latency tags (LLTs). Its dependency vector is written once, at dispatch. With the shared
// woken vector W (tg_wake) a row is ready when
//     valid & not issued & NOR over c of (dep[c] & ~W[c])
// an AND-OR with no tag compare.
//
// Select. Oldest ready first through an allocation-order age matrix (older[i][j]: row i was
// allocated before row j), stored as its upper triangle; at most one grant per cycle.
//
// Wakeup at select. A 1-cycle op (dispatched with lat1) sets its wakeup ID's W bit in the
// cycle it is selected (wake_now), so a dependant issues back to back. Other ops wake
// through the issue output (delay lines and LLT completions, outside the queue).
//
// Speculative-wakeup shadow (plan §4.6). A row stays allocated for 2 cycles after issue.
// cancel (registered, from the load pipe) returns rows issued in the current cycle and the
// two before it to "not issued"; tg_wake clears the W bits they set.
//
// Stale dependencies. Dependency bits are never rewritten after dispatch, so an ID must not
// look pending again to a row that waited on its previous producer. STALE selects:
//   0 guard:  busy[c] = some row still has dep[c] set; the ID allocator must not reuse c
//             while busy[c] (dependency bits are cleared when a row is freed)
//   1 phase:  every ID has a phase bit that flips on allocation; a row records the phase
//             of each producer and W has one vector per phase (w1). Unsafe for pooled IDs:
//             an LLT can be reallocated twice while a row still waits on its first
//             instance, the phase wraps and the row waits forever (tb_iq finds it). Safe
//             only for IDs reused in allocation order (ROB entries).
//   2 clear:  col_clr[c] (registered, when the producer holding c is freed: retire or LLT
//             release) clears column c in every row; the producer is complete by then
//
// Timing options (spike S2):
//   DUP_SEL = 1: the select is computed twice; one copy drives only the wakeup broadcast,
//                so the grant net on the protected loop has a small fanout.
//   EARLY_W < PAYLOAD_W: only payload bits [EARLY_W-1:0] (the source tags the RF stage needs
//                first) sit in flip-flops and leave through the grant's AND-OR mux; the rest
//                is in one LUTRAM per bank, read in the next cycle with the registered grant.
//   Either way iss_payload is valid in the cycle after the select (the RF stage).
//   MX = 1:      matrix wakeup for 1-cycle producers. The RA rows of the ALU queues are
//                numbered across the queues; a row records which of them produce its sources
//                (disp_mdep, set by dispatch while the producer still holds its row) and is
//                ready only when all of those rows are selected (mx_issued: selected and
//                held). The wakeup ID's W bit is then set a cycle later (the grant is
//                registered before the encode), so the loop is grant -> issued register ->
//                readiness -> select,
//                with no ID encode or decode. A freed row's column is cleared everywhere
//                (mx_free); its producer has completed by then.
//                Dispatch names a source by row only while that row still holds the
//                producer: it compares the source's physical register with the row's
//                destination (one compare per source, no CAM), else it uses the ID.
//                tg_wake's cancel history must then be 1 cycle (HIST = 1), not 2.
//   PRE_RDY = 1 (with MX, STALE 0 or 2): each row's ID readiness is computed a cycle
//                early from W's next state (w_next) and registered, so the select cycle
//                starts from one flip-flop per row instead of an NCOL-wide AND-OR. Rows
//                written this cycle take theirs from their dispatch port's dependencies.
//
// SMT2: per-thread caps. room_q[t] is how many more rows thread t may allocate next cycle,
// at most DW: the per-thread cap CAP (75% of ROWS in SMT2 builds, plan §6.5) minus its rows.
// Kill: flush_valid with flush_tid kills that thread's rows younger than flush_rob (index
// plus wrap bit), or all its rows with flush_all.
module tg_iq
  import tg_pkg::*;
#(
  parameter int ROWS      = 10,
  parameter int DW        = 2,      // dispatch ports (write banks)
  parameter int NCOL      = 64,     // wakeup IDs: ROB entries, then LLTs
  parameter int PAYLOAD_W = 64,
  parameter int CAP       = ROWS,   // rows per thread
  parameter int STALE     = 0,      // 0 guard, 1 phase, 2 clear (see above)
  parameter bit WAKE_NOW  = 1'b1,   // queue has 1-cycle ops that wake at select
  parameter int WAKE_ENC  = 0,      // 0: one-hot wakeup ID per row; 1: predecoded {hi, lo}
  parameter int ROBW      = ROB_IDX_W + 1,   // ROB index plus wrap bit
  parameter bit DUP_SEL   = 1'b0,
  parameter int EARLY_W   = PAYLOAD_W,
  parameter bit MX        = 1'b0,
  parameter int RA        = 1,      // MX: ALU-queue rows, all queues
  parameter bit PRE_RDY   = 1'b0,   // registered ID readiness (needs MX, STALE 0/2)
  localparam int NHI      = (NCOL + 7) / 8,
  localparam int RMW      = idx_w(DW + 1)
) (
  input  logic                          clk,
  input  logic                          rst,
  // Dispatch (port k writes a free row of bank k; it must check bank_free_q and room_q)
  input  logic [DW-1:0]                 disp_valid,
  input  tid_t [DW-1:0]                 disp_tid,
  input  logic [DW-1:0][NCOL-1:0]       disp_dep,      // pending producers, one bit per ID
  input  logic [DW-1:0][NCOL-1:0]       disp_dep_ph,   // their phases (STALE = 1)
  input  logic [DW-1:0][NCOL-1:0]       disp_wake_oh,  // own wakeup ID, one-hot; 0 if no wake at select
  input  logic [DW-1:0][ROBW-1:0]       disp_rob,
  input  logic [DW-1:0][PAYLOAD_W-1:0]  disp_payload,
  output logic [DW-1:0]                 bank_free_q,
  output logic [NUM_THREADS-1:0][RMW-1:0] room_q,
  // Wakeup state
  input  logic [NCOL-1:0]               w,             // woken vector (phase 0 if STALE = 1)
  input  logic [NCOL-1:0]               w_next,        // its next state (PRE_RDY)
  input  logic [NCOL-1:0]               w1,            // phase-1 vector (STALE = 1)
  input  logic [NCOL-1:0]               col_clr,       // STALE = 2
  input  logic                          cancel,
  output logic [NCOL-1:0]               wake_now,      // IDs woken by this cycle's select
  output logic [NCOL-1:0]               busy,          // STALE = 0
  // Matrix wakeup (MX = 1)
  input  logic [DW-1:0][RA-1:0]         disp_mdep,     // sources made by 1-cycle ops in these rows
  input  logic [RA-1:0]                 mx_issued,     // ALU-queue rows selected and still held
  input  logic [RA-1:0]                 mx_free,       // ALU-queue rows freed this cycle
  output logic [ROWS-1:0]               issued_o,      // this queue's rows selected and held
  output logic [ROWS-1:0]               free_o,        // this queue's rows freed this cycle
  // Kill
  input  logic                          flush_valid,
  input  tid_t                          flush_tid,
  input  logic                          flush_all,
  input  logic [ROBW-1:0]               flush_rob,
  // Issue, in the cycle after the select
  output logic                          iss_valid_q,
  output logic [PAYLOAD_W-1:0]          iss_payload
);
  localparam int BANK_ROWS = (ROWS + DW - 1) / DW;   // rows of the fullest bank

  function automatic int bank_of(input int r);
    return r % DW;
  endfunction

  // ---- Row state ----
  logic [ROWS-1:0]            valid_q;
  logic [ROWS-1:0][1:0]       age_q;      // 0 waiting, 1/2 cycles since issue
  tid_t [ROWS-1:0]            tid_q;
  logic [ROWS-1:0][ROBW-1:0]  rob_q;
  logic [ROWS-1:0][EARLY_W-1:0] payload_q;
  logic [ROWS-1:0][NCOL-1:0]  dep_q;      // STALE 0/2: dep; STALE 1: waits on phase 0
  logic [ROWS-1:0][NCOL-1:0]  dep1_q;     // STALE 1: waits on phase 1
  logic [ROWS-1:0][RA-1:0]    mdep_q;     // MX: waits on these ALU-queue rows

  // Allocation: the row each bank writes next (one-hot within the queue)
  logic [DW-1:0][ROWS-1:0]    alloc_oh_q;
  logic [ROWS-1:0]            we;
  for (genvar r = 0; r < ROWS; r++) begin : g_we
    assign we[r] = disp_valid[bank_of(r)] && alloc_oh_q[bank_of(r)][r];
  end

  // ---- Readiness ----
  logic [ROWS-1:0] ready;
  logic [ROWS-1:0] rdyw_q;   // PRE_RDY: every ID dependency satisfied in this cycle's W
  if (PRE_RDY) begin : g_rdyw
    logic [DW-1:0] slot_rdy;
    for (genvar k = 0; k < DW; k++) begin : g_slot
      assign slot_rdy[k] = !(|(disp_dep[k] & ~w_next));
    end
    always_ff @(posedge clk) begin
      for (int r = 0; r < ROWS; r++) begin
        if (we[r]) rdyw_q[r] <= slot_rdy[bank_of(r)];
        else if (STALE == 2) rdyw_q[r] <= !(|(dep_q[r] & ~col_clr & ~w_next));
        else       rdyw_q[r] <= !(|(dep_q[r] & ~w_next));
      end
    end
    if (!MX || STALE == 1) begin : g_bad_pre
      $error("tg_iq: PRE_RDY needs MX = 1 and STALE 0 or 2");
    end
  end else begin : g_nordyw
    assign rdyw_q = '1;
  end
  for (genvar r = 0; r < ROWS; r++) begin : g_ready
    logic pend;
    if (PRE_RDY) begin : g_pre
      assign pend = !rdyw_q[r];
    end else if (STALE == 1) begin : g_ph
      assign pend = |((dep_q[r] & ~w) | (dep1_q[r] & ~w1));
    end else begin : g_one
      assign pend = |(dep_q[r] & ~w);
    end
    logic mpend;
    if (MX) begin : g_mx
      assign mpend = |(mdep_q[r] & ~mx_issued);
    end else begin : g_nomx
      assign mpend = 1'b0;
    end
    assign ready[r] = valid_q[r] && age_q[r] == 2'd0 && !pend && !mpend;
  end

  // ---- Age matrix (upper triangle: older_q[i][j], i < j: row i allocated before row j) ----
  /* verilator lint_off UNUSEDSIGNAL */  // only the upper triangle is stored
  logic [ROWS-1:0][ROWS-1:0] older_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [ROWS-1:0][ROWS-1:0] older;   // full matrix view
  for (genvar i = 0; i < ROWS; i++) begin : g_old_i
    for (genvar j = 0; j < ROWS; j++) begin : g_old_j
      if (i < j) begin : g_up
        assign older[i][j] = older_q[i][j];
      end else if (i > j) begin : g_lo
        assign older[i][j] = !older_q[j][i];
      end else begin : g_diag
        assign older[i][j] = 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    for (int i = 0; i < ROWS; i++) begin
      for (int j = i + 1; j < ROWS; j++) begin
        if (we[i] && we[j]) older_q[i][j] <= bank_of(i) < bank_of(j);
        else if (we[i])     older_q[i][j] <= 1'b0;   // i is the newest
        else if (we[j])     older_q[i][j] <= 1'b1;   // j is the newest
      end
    end
  end

  // ---- Select: oldest ready ----
  logic [ROWS-1:0] grant;
  for (genvar r = 0; r < ROWS; r++) begin : g_sel
    logic [ROWS-1:0] older_ready;
    for (genvar j = 0; j < ROWS; j++) begin : g_j
      assign older_ready[j] = ready[j] && older[j][r];
    end
    assign grant[r] = ready[r] && !(|older_ready);
  end

  // The wakeup broadcast's own copy of the select
  logic [ROWS-1:0] grant_w;
  if (DUP_SEL) begin : g_dup
    for (genvar r = 0; r < ROWS; r++) begin : g_r
      logic [ROWS-1:0] older_ready;
      for (genvar j = 0; j < ROWS; j++) begin : g_j
        assign older_ready[j] = ready[j] && older[j][r];
      end
      (* dont_touch = "true" *) logic gw;
      assign gw = ready[r] && !(|older_ready);
      assign grant_w[r] = gw;
    end
  end else begin : g_nodup
    assign grant_w = grant;
  end

  // MX: the wakeup encode works on the registered grant; W follows a cycle later anyway, and
  // the encode leaves the select cycle.
  logic [ROWS-1:0] grant_e;
  if (MX) begin : g_grant_reg
    logic [ROWS-1:0] grant_wq;
    always_ff @(posedge clk) grant_wq <= rst ? '0 : grant_w & {ROWS{!cancel}};
    assign grant_e = grant_wq;
  end else begin : g_grant_now
    assign grant_e = grant_w;
  end

  // ---- Issue output: one-hot AND-OR mux of the early payload, LUTRAM for the rest ----
  logic [EARLY_W-1:0] payload_sel, early_q;
  always_comb begin
    payload_sel = '0;
    for (int r = 0; r < ROWS; r++) payload_sel |= {EARLY_W{grant[r]}} & payload_q[r];
  end
  always_ff @(posedge clk) begin
    if (rst) iss_valid_q <= 1'b0;
    else     iss_valid_q <= (|grant) && !cancel;
    early_q <= payload_sel;
  end
  assign iss_payload[EARLY_W-1:0] = early_q;

  if (EARLY_W < PAYLOAD_W) begin : g_late
    localparam int LW = PAYLOAD_W - EARLY_W;
    localparam int BRW = idx_w(BANK_ROWS);
    logic [ROWS-1:0] grant_q;
    always_ff @(posedge clk) grant_q <= grant;
    logic [DW-1:0][LW-1:0] brd;
    logic [DW-1:0]         bsel;
    for (genvar k = 0; k < DW; k++) begin : g_bank
      localparam int NRK = (ROWS - k + DW - 1) / DW;   // rows k, k + DW, ...
      logic [BRW-1:0] wa;
      logic [0:0][BRW-1:0] ra;
      logic [0:0][LW-1:0] rd;
      always_comb begin
        wa = '0;
        ra[0] = '0;
        for (int i = 0; i < NRK; i++) begin
          if (alloc_oh_q[k][k + i * DW]) wa = BRW'(i);
          if (grant_q[k + i * DW])       ra[0] = BRW'(i);
        end
      end
      always_comb begin
        bsel[k] = 1'b0;
        for (int i = 0; i < NRK; i++) bsel[k] |= grant_q[k + i * DW];
      end
      tg_ram_lut #(.DEPTH(BANK_ROWS), .WIDTH(LW), .NR(1)) u_ram (
        .clk, .we(disp_valid[k] && |alloc_oh_q[k]), .waddr(wa),
        .wdata(disp_payload[k][PAYLOAD_W-1:EARLY_W]), .raddr(ra), .rdata(rd));
      assign brd[k] = rd[0];
    end
    always_comb begin
      iss_payload[PAYLOAD_W-1:EARLY_W] = '0;
      for (int k = 0; k < DW; k++) if (bsel[k]) iss_payload[PAYLOAD_W-1:EARLY_W] = brd[k];
    end
  end

  // ---- Wakeup at select ----
  logic [NCOL-1:0] wake_c;
  if (!WAKE_NOW) begin : g_nowake
    assign wake_c = '0;
    logic unused_gw;
    assign unused_gw = ^{grant_w, grant_e};
  end else if (WAKE_ENC == 0) begin : g_wake_oh
    logic [ROWS-1:0][NCOL-1:0] wid_q;   // one-hot wakeup ID, zero if the op does not wake at select
    always_ff @(posedge clk) begin
      for (int r = 0; r < ROWS; r++) if (we[r]) wid_q[r] <= disp_wake_oh[bank_of(r)];
    end
    always_comb begin
      wake_c = '0;
      for (int r = 0; r < ROWS; r++) wake_c |= {NCOL{grant_e[r]}} & wid_q[r];
    end
  end else begin : g_wake_hl
    // Predecoded ID: hi = ID / 8 one-hot, lo = ID % 8 one-hot (21 bits per row at 104 IDs)
    logic [ROWS-1:0][NHI-1:0] hi_q;
    logic [ROWS-1:0][7:0]     lo_q;
    logic [DW-1:0][NHI-1:0]   d_hi;
    logic [DW-1:0][7:0]       d_lo;
    for (genvar k = 0; k < DW; k++) begin : g_pre
      always_comb begin
        d_hi[k] = '0;
        d_lo[k] = '0;
        for (int c = 0; c < NCOL; c++) begin
          d_hi[k][c / 8] |= disp_wake_oh[k][c];
          d_lo[k][c % 8] |= disp_wake_oh[k][c];
        end
      end
    end
    always_ff @(posedge clk) begin
      for (int r = 0; r < ROWS; r++) begin
        if (we[r]) begin
          hi_q[r] <= d_hi[bank_of(r)];
          lo_q[r] <= d_lo[bank_of(r)];
        end
      end
    end
    logic [NHI-1:0] sel_hi;
    logic [7:0]     sel_lo;
    always_comb begin
      sel_hi = '0;
      sel_lo = '0;
      for (int r = 0; r < ROWS; r++) begin
        sel_hi |= {NHI{grant_e[r]}} & hi_q[r];
        sel_lo |= {8{grant_e[r]}} & lo_q[r];
      end
      for (int c = 0; c < NCOL; c++) wake_c[c] = sel_hi[c / 8] && sel_lo[c % 8];
    end
  end
  assign wake_now = wake_c;

  // ---- Row lifetime ----
  logic [ROWS-1:0] kill, free_now;
  for (genvar r = 0; r < ROWS; r++) begin : g_life
    logic younger;
    // Index plus wrap bit: same wrap, larger index is younger; different wrap, smaller is.
    assign younger = (rob_q[r][ROBW-1] == flush_rob[ROBW-1])
                   ? (rob_q[r][ROBW-2:0] > flush_rob[ROBW-2:0])
                   : (rob_q[r][ROBW-2:0] < flush_rob[ROBW-2:0]);
    assign kill[r] = flush_valid && tid_q[r] == flush_tid && (flush_all || younger);
    assign free_now[r] = (age_q[r] == 2'd2 && !cancel) || kill[r];
  end

  for (genvar r = 0; r < ROWS; r++) begin : g_mxo
    assign issued_o[r] = valid_q[r] && age_q[r] != 2'd0;
    assign free_o[r]   = valid_q[r] && free_now[r];
  end

  // Matrix dependencies: written at dispatch, a column cleared when its row is freed
  if (MX) begin : g_mdep
    always_ff @(posedge clk) begin
      for (int r = 0; r < ROWS; r++)
        mdep_q[r] <= (we[r] ? disp_mdep[bank_of(r)] : mdep_q[r]) & ~mx_free;
    end
  end else begin : g_nomdep
    assign mdep_q = '0;
  end

  logic [ROWS-1:0] valid_d;
  tid_t [ROWS-1:0] tid_d;
  always_comb begin
    for (int r = 0; r < ROWS; r++) begin
      valid_d[r] = we[r] || (valid_q[r] && !free_now[r]);
      tid_d[r]   = we[r] ? disp_tid[bank_of(r)] : tid_q[r];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      valid_q <= '0;
      age_q   <= '0;
    end else begin
      valid_q <= valid_d;
      for (int r = 0; r < ROWS; r++) begin
        if (we[r] || cancel)            age_q[r] <= 2'd0;
        else if (grant[r])              age_q[r] <= 2'd1;
        else if (age_q[r] == 2'd1)      age_q[r] <= 2'd2;
      end
    end
  end

  always_ff @(posedge clk) begin
    for (int r = 0; r < ROWS; r++) begin
      if (we[r]) begin
        tid_q[r]     <= disp_tid[bank_of(r)];
        rob_q[r]     <= disp_rob[bank_of(r)];
        payload_q[r] <= disp_payload[bank_of(r)][EARLY_W-1:0];
      end
    end
  end

  // ---- Dependency vectors ----
  if (STALE == 0) begin : g_guard
    // Cleared when the row is freed, so busy reflects live rows only.
    always_ff @(posedge clk) begin
      for (int r = 0; r < ROWS; r++) begin
        if (rst || (valid_q[r] && free_now[r])) dep_q[r] <= '0;
        else if (we[r])                         dep_q[r] <= disp_dep[bank_of(r)];
      end
    end
    always_comb begin
      busy = '0;
      for (int r = 0; r < ROWS; r++) busy |= dep_q[r];
    end
    assign dep1_q = '0;
  end else if (STALE == 1) begin : g_phase
    always_ff @(posedge clk) begin
      for (int r = 0; r < ROWS; r++) begin
        if (we[r]) begin
          dep_q[r]  <= disp_dep[bank_of(r)] & ~disp_dep_ph[bank_of(r)];
          dep1_q[r] <= disp_dep[bank_of(r)] &  disp_dep_ph[bank_of(r)];
        end
      end
    end
    assign busy = '0;
  end else begin : g_clear
    always_ff @(posedge clk) begin
      for (int r = 0; r < ROWS; r++) begin
        for (int c = 0; c < NCOL; c++) begin
          if (col_clr[c])  dep_q[r][c] <= 1'b0;
          else if (we[r])  dep_q[r][c] <= disp_dep[bank_of(r)][c];
        end
      end
    end
    assign busy = '0;
    assign dep1_q = '0;
  end

  // ---- Allocation for the next cycle, caps (off the select loop) ----
  always_ff @(posedge clk) begin
    for (int k = 0; k < DW; k++) begin
      logic found;
      found = 1'b0;
      alloc_oh_q[k] <= '0;
      for (int r = 0; r < ROWS; r++) begin
        if (bank_of(r) == k && !valid_d[r] && !found) begin
          alloc_oh_q[k][r] <= 1'b1;
          found = 1'b1;
        end
      end
      bank_free_q[k] <= found && !rst;
    end
  end

  for (genvar t = 0; t < NUM_THREADS; t++) begin : g_room
    int cnt;
    always_comb begin
      cnt = 0;
      for (int r = 0; r < ROWS; r++) cnt += int'(valid_d[r] && tid_d[r] == tid_t'(t));
    end
    always_ff @(posedge clk) begin
      if (rst)                  room_q[t] <= RMW'(DW);
      else if (cnt >= CAP)      room_q[t] <= '0;
      else if (CAP - cnt >= DW) room_q[t] <= RMW'(DW);
      else                      room_q[t] <= RMW'(CAP - cnt);
    end
  end

  // Inputs a variant does not use
  logic unused;
  assign unused = ^{(STALE == 1) ? '0 : {disp_dep_ph, w1}, (STALE == 2) ? '0 : col_clr,
                    WAKE_NOW ? '0 : disp_wake_oh, (STALE == 1) ? '0 : dep1_q,
                    MX ? '0 : {disp_mdep, mx_issued, mx_free}, mdep_q,
                    PRE_RDY ? '0 : w_next, rdyw_q};

`ifndef SYNTHESIS
  // A port writes only when its bank has a free row.
  always_ff @(posedge clk) begin
    for (int k = 0; k < DW; k++)
      if (!rst && disp_valid[k]) assert (bank_free_q[k]) else $error("tg_iq: write to a full bank");
  end
  // Oldest-first select grants at most one row.
  always_ff @(posedge clk) begin
    if (!rst) assert ($onehot0(grant)) else $error("tg_iq: more than one grant");
  end
`endif
endmodule
