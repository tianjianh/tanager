// Rename (RN) and dispatch (DS) stages (docs/spec/core-pipeline.md §5).
//
// RN (group in rn_q): sources from the RAT or an earlier slot of the group; steering to an
// issue port, whose bank supplies the destination; free-list pops; ROB, LQ, SQ and LLT
// allocation; RAT, ready and producer tables updated when the group moves on. All or nothing.
// A serialising or exception uop is renamed alone, into an empty window, after which RN takes
// nothing until the next flush.
// DS (group in ds_q): dependency vectors (pending producers' IDs AND NOT W), issue-queue rows,
// and the ROB / LQ / SQ entry writes (done by those units from ds_*). DS waits until every uop
// finds a free row in its queue's bank.
// The RAT entry of each architectural register holds its mapping and its producer: its wakeup
// column (a tag or an LLT), or for a 1-cycle op its ROB index (MX), and the rename slot it had.
// Sources need no table indexed by physical register (a pending source's producer is still in
// flight, so its column is current; a written one is ready and its column unused).
// Wakeup tags (plan §4.6, AR-1): MUL and the P1 bit counts take one of IQ_TAGS tags at RN; a
// tag returns 2 cycles after its producer's register write (tag_free, from tg_exec), when no
// group still in RN or DS can see the register as unwritten, and its column is then cleared in
// every queue row. 1-cycle ops take no column: a consumer names its row (MX) while the row is
// held, and needs nothing once it is freed. A flush returns every tag.
// The maps are LUTRAM (plan §8.5 R3): the speculative map has one bank per rename slot and the
// committed map one per commit slot, so each write port is a LUTRAM's; live-value tables in
// flip-flops name the bank holding each register's latest entry. A flush clears the per-register
// "renamed since the flush" bits, after which the committed map answers: recovery is immediate,
// with no copy. A reset sweep writes the identity into the committed map.
// MX (IQ_MX): a source whose producer is a 1-cycle op still holding its ALU-queue row is named
// by that row instead of its ID. DS records each 1-cycle op's row in a LUTRAM by ROB entry, one
// bank per rename slot (one write per bank per cycle); a consumer reads it in the bank of its
// producer's slot, and one compare of the row's destination (rowdst_q) against the source
// confirms the row still holds it. A producer in the same group is named by the row it is being
// written into. Otherwise the ID is used.
module tg_rename
  import tg_pkg::*, tg_core_pkg::*;
#(
  localparam int W   = RENAME_WIDTH,
  localparam int NPR = INT_BANKS * INT_PREGS_PER_BANK,
  localparam int FPW = PIDX_W + 1
) (
  input  logic clk,
  input  logic rst,
  output logic ready,          // free lists initialised
  input  logic start,          // the core's reset sequence is done
  input  logic flush,
  // From decode
  input  logic [W-1:0]   de_valid,
  input  uop_t [W-1:0]   de_uop,
  output logic           de_take,
  // Window state
  input  robid_t         rob_head,
  input  lqid_t          lq_head,
  input  sqid_t          sq_head,
  input  sqid_t          sq_cmt,      // first uncommitted SQ entry
  // Issue state
  input  logic [N_IQ-1:0][DISPATCH_WIDTH-1:0] iq_bank_free,
  input  logic [NCOL-1:0] w_vec,
  input  logic [NCOL-1:0] busy,         // IDs a queued row still depends on: not reallocated
  // Register-file writes (ready bits), LLT releases, divides leaving the divider
  input  logic [INT_BANKS-1:0]             rf_we,
  input  logic [INT_BANKS-1:0][PIDX_W-1:0] rf_widx,
  input  logic [LLT_ENTRIES-1:0]           llt_rel,
  input  logic [IQ_TAGS-1:0]               tag_free,    // tags returned (registered)
  input  logic                             div_done,
  // Commit
  input  logic [COMMIT_WIDTH-1:0]          cm_valid,
  input  logic [COMMIT_WIDTH-1:0]          cm_rd_en,
  input  logic [COMMIT_WIDTH-1:0][4:0]     cm_rd,
  input  preg_t [COMMIT_WIDTH-1:0]         cm_dst,
  input  preg_t [COMMIT_WIDTH-1:0]         cm_old,
  // DS
  output logic                             ds_fire,
  output logic [DISPATCH_WIDTH-1:0]        ds_valid,
  output uop_t [DISPATCH_WIDTH-1:0]        ds_uop,
  output ren_t [DISPATCH_WIDTH-1:0]        ds_ren,
  output logic [N_IQ-1:0][DISPATCH_WIDTH-1:0] iq_we,
  output logic [DISPATCH_WIDTH-1:0][NCOL-1:0] iq_dep,
  output iq_pl_t [DISPATCH_WIDTH-1:0]      iq_pl,
  output logic [DISPATCH_WIDTH-1:0][RA-1:0] iq_mdep,     // MX: sources named by ALU-queue row
  input  logic [RA-1:0]                    mx_hold,     // ALU-queue rows holding an op
  input  logic [N_ALU-1:0][DISPATCH_WIDTH-1:0][RA-1:0] mx_alloc,  // rows written next
  output logic [NCOL-1:0]                  wid_alloc,   // IDs given out at RN (clear W)
  output logic [DISPATCH_WIDTH-1:0]        ds_src2_rdy,  // DS: rs2's register is written
  output robid_t                           rob_tail     // next ROB entry RN gives out
);
  if (W != DISPATCH_WIDTH) begin : g_bad
    $error("tg_rename: RENAME_WIDTH must equal DISPATCH_WIDTH");
  end

  // ---- State ----
  localparam int KSW = idx_w(W);
  localparam int CSW = idx_w(COMMIT_WIDTH);
  typedef struct packed {
    pid_t           id;                    // producer's column, or its ROB index if l1
    logic           cv;                    // ... has a wakeup column
    logic           l1;                    // ... is a 1-cycle op
    logic [KSW-1:0] ks;                    // ... renamed in this slot of its group
  } rprod_t;
  function automatic logic is_lat1(input uclass_e c);       // a 1-cycle op in an ALU queue
    return c == C_ALU || c == C_BR;
  endfunction
  logic [NPR-1:0]        ready_q;
  logic [LLT_ENTRIES-1:0] llt_busy_q;
  logic [IQ_TAGS-1:0]    tag_busy_q;
  robid_t                rtail_q;
  lqid_t                 ltail_q;
  sqid_t                 stail_q;
  logic [idx_w(DIV_INFLIGHT + 1)-1:0] div_cnt_q;
  logic                  block_q;          // after a serialising uop, until the flush
  // MX naming state
  preg_t [RA-1:0]        rowdst_q;         // destination of the op each ALU-queue row holds

  logic [W-1:0]          rn_valid_q;
  uop_t [W-1:0]          rn_uop_q;
  logic [W-1:0]          ds_valid_q;
  uop_t [W-1:0]          ds_uop_q;
  ren_t [W-1:0]          ds_ren_q;

  for (genvar k = 0; k < W; k++) begin : g_s2r
    assign ds_src2_rdy[k] = ready_q[ds_ren_q[k].src2];
  end
  assign rob_tail  = rtail_q;

  // ---- Free lists, one per bank (bank 0 keeps preg 0 as the zero register, and x1..x31) ----
  logic [INT_BANKS-1:0]                 fl_ready;
  logic [INT_BANKS-1:0][FPW-1:0]        fl_count;
  logic [INT_BANKS-1:0][W-1:0][PIDX_W-1:0] fl_pop;
  logic [INT_BANKS-1:0][idx_w(W+1)-1:0] fl_pop_n;
  logic [INT_BANKS-1:0][COMMIT_WIDTH-1:0] fl_push_v;
  logic [INT_BANKS-1:0][COMMIT_WIDTH-1:0][PIDX_W-1:0] fl_push_idx;
  logic [INT_BANKS-1:0][idx_w(COMMIT_WIDTH+1)-1:0] fl_cmt_n;
  for (genvar b = 0; b < INT_BANKS; b++) begin : g_fl
    tg_freelist #(.DEPTH(INT_PREGS_PER_BANK), .NB(FL_BANKS), .NPOP(W), .NPUSH(COMMIT_WIDTH),
                  .FIRST(b == 0 ? 32 : 0)) u_fl (
      .clk, .rst, .ready(fl_ready[b]), .count(fl_count[b]), .pop_idx(fl_pop[b]),
      .pop_n(fl_pop_n[b]), .push_v(fl_push_v[b]), .push_idx(fl_push_idx[b]),
      .commit_n(fl_cmt_n[b]), .flush);
  end

  // ---- Rename maps (LUTRAM) ----
  // Read ports: rs1 and rs2 of slot k at 2k and 2k + 1, rd (the old mapping) at 2W + k; the
  // producer fields are read for the sources only.
  localparam int NMR = 3 * W;
  localparam int PRW = $bits(preg_t);
  localparam int PDW = $bits(rprod_t);
  logic [31:0]                          sv_q;     // renamed since the last flush
  logic [31:0][KSW-1:0]                 lvt_q;    // speculative bank with the latest entry
  logic [31:0][CSW-1:0]                 lvtc_q;   // committed bank with the latest entry
  logic [5:0]                           cinit_q;  // reset sweep: identity into committed bank 0
  logic [NMR-1:0][4:0]                  map_ra;
  logic [W-1:0][NMR-1:0][PRW-1:0]       ms_rd;
  logic [W-1:0][2*W-1:0][PDW-1:0]       mp_rd;
  logic [COMMIT_WIDTH-1:0][NMR-1:0][PRW-1:0] mc_rd;
  preg_t  [NMR-1:0]                     map_p;    // mapping per read port
  rprod_t [2*W-1:0]                     map_pd;   // producer per source port
  for (genvar k = 0; k < W; k++) begin : g_mra
    assign map_ra[2*k]     = rn_uop_q[k].d.rs1;
    assign map_ra[2*k+1]   = rn_uop_q[k].d.rs2;
    assign map_ra[2*W + k] = rn_uop_q[k].d.rd;
  end
  ren_t [W-1:0] ren;
  logic         rn_fire;
  for (genvar k = 0; k < W; k++) begin : g_ms
    logic we;
    assign we = rn_fire && rn_valid_q[k] && rn_uop_q[k].d.rd_en;
    tg_ram_lut #(.DEPTH(32), .WIDTH(PRW), .NR(NMR)) u_map (
      .clk, .we, .waddr(rn_uop_q[k].d.rd), .wdata(ren[k].dst), .raddr(map_ra), .rdata(ms_rd[k]));
    tg_ram_lut #(.DEPTH(32), .WIDTH(PDW), .NR(2 * W)) u_prod (
      .clk, .we, .waddr(rn_uop_q[k].d.rd),
      .wdata(rprod_t'{id: is_lat1(rn_uop_q[k].d.cls) ? pid_t'(ren[k].rob[ROBW-2:0]) : pid_t'(ren[k].wid),
                      cv: ren[k].use_tag || ren[k].use_llt, l1: is_lat1(rn_uop_q[k].d.cls),
                      ks: KSW'(k)}),
      .raddr(map_ra[2*W-1:0]), .rdata(mp_rd[k]));
  end
  for (genvar j = 0; j < COMMIT_WIDTH; j++) begin : g_mc
    logic we;
    logic [4:0] wa;
    preg_t wd;
    always_comb begin
      we = cm_valid[j] && cm_rd_en[j];
      wa = cm_rd[j];
      wd = cm_dst[j];
      if (j == 0 && !cinit_q[5]) begin
        we = 1'b1;
        wa = cinit_q[4:0];
        wd = mk_preg(0, PIDX_W'(cinit_q[4:0]));
      end
    end
    tg_ram_lut #(.DEPTH(32), .WIDTH(PRW), .NR(NMR)) u_cmap (
      .clk, .we, .waddr(wa), .wdata(wd), .raddr(map_ra), .rdata(mc_rd[j]));
  end
  for (genvar i = 0; i < NMR; i++) begin : g_mrd
    always_comb begin
      logic [4:0] r;
      r = map_ra[i];
      map_p[i] = sv_q[r] ? ms_rd[lvt_q[r]][i] : mc_rd[lvtc_q[r]][i];
    end
    if (i < 2 * W) begin : g_pd
      // a committed mapping's producer is done: the source is ready and these are not read
      assign map_pd[i] = rprod_t'(mp_rd[lvt_q[map_ra[i]]][i]);
    end
  end

  assign ready = &fl_ready && cinit_q[5];

  // ---- RN ----
  logic          rn_ok;             // resources available for the whole group
  logic [INT_BANKS-1:0][idx_w(W+1)-1:0] pops;
  always_comb begin
    int nrob, nld, nst, ndiv, port, pref, p, b;
    logic [LLT_ENTRIES-1:0] lfree;
    logic [IQ_TAGS-1:0]     tfree;
    logic llt_short, tag_short, found, got;
    pops = '0;
    nld = 0; nst = 0; ndiv = 0; nrob = 0;
    port = 0; pref = 0; p = 0; b = 0;
    lfree = ~llt_busy_q & ~busy[IQ_TAGS +: LLT_ENTRIES];
    tfree = ~tag_busy_q;
    llt_short = 1'b0;
    tag_short = 1'b0;
    found = 1'b0;
    got = 1'b0;
    for (int k = 0; k < W; k++) begin
      ren[k] = '0;
      // Steering
      port = 0;
      ren[k].has_q = 1'b1;
      unique case (rn_uop_q[k].d.cls)
        C_BR:  port = 0;
        C_MUL, C_DIV, C_CSR: port = 1;
        C_LD:  port = Q_LD;
        C_ST:  port = Q_STA;
        C_ALU: begin
          pref = k % N_ALU;
          port = pref;
          found = 1'b0;
          for (int j = 0; j < N_ALU; j++) begin
            p = (pref + j) % N_ALU;
            if (!found && iq_bank_free[p][k] && int'(fl_count[p]) > int'(pops[p])) begin
              port = p;
              found = 1'b1;
            end
          end
        end
        default: begin port = 0; ren[k].has_q = 1'b0; end
      endcase
      ren[k].q = QW'(port);
      // Window entries
      ren[k].rob = rob_add(rtail_q, k);
      ren[k].lq  = lq_add(ltail_q, nld);
      ren[k].sq  = sq_add(stail_q, nst);
      if (rn_valid_q[k]) begin
        if (rn_uop_q[k].d.cls == C_LD) nld++;
        if (rn_uop_q[k].d.cls == C_ST) nst++;
        if (rn_uop_q[k].d.cls == C_DIV) ndiv++;
        nrob = k + 1;
      end
      // Sources: RAT, or the closest earlier slot that writes the register
      ren[k].src1 = rn_uop_q[k].d.rs1_en ? map_p[2*k] : '0;
      ren[k].src2 = rn_uop_q[k].d.rs2_en ? map_p[2*k+1] : '0;
      ren[k].p1   = rn_uop_q[k].d.rs1_en && !ready_q[ren[k].src1];
      ren[k].p2   = rn_uop_q[k].d.rs2_en && !ready_q[ren[k].src2];
      ren[k].w1   = map_pd[2*k].id;
      ren[k].w2   = map_pd[2*k+1].id;
      ren[k].c1   = map_pd[2*k].cv;
      ren[k].c2   = map_pd[2*k+1].cv;
      ren[k].l1   = map_pd[2*k].l1;
      ren[k].l2   = map_pd[2*k+1].l1;
      ren[k].ks1  = map_pd[2*k].ks;
      ren[k].ks2  = map_pd[2*k+1].ks;
      ren[k].old  = map_p[2*W + k];
      for (int i = 0; i < k; i++) begin
        if (rn_uop_q[i].d.rd_en) begin
          if (rn_uop_q[k].d.rs1_en && rn_uop_q[i].d.rd == rn_uop_q[k].d.rs1) begin
            ren[k].src1 = ren[i].dst; ren[k].p1 = 1'b1;
            ren[k].w1 = is_lat1(rn_uop_q[i].d.cls) ? pid_t'(ren[i].rob[ROBW-2:0]) : pid_t'(ren[i].wid);
            ren[k].c1 = ren[i].use_tag || ren[i].use_llt;
            ren[k].l1 = is_lat1(rn_uop_q[i].d.cls); ren[k].ks1 = KSW'(i);
          end
          if (rn_uop_q[k].d.rs2_en && rn_uop_q[i].d.rd == rn_uop_q[k].d.rs2) begin
            ren[k].src2 = ren[i].dst; ren[k].p2 = 1'b1;
            ren[k].w2 = is_lat1(rn_uop_q[i].d.cls) ? pid_t'(ren[i].rob[ROBW-2:0]) : pid_t'(ren[i].wid);
            ren[k].c2 = ren[i].use_tag || ren[i].use_llt;
            ren[k].l2 = is_lat1(rn_uop_q[i].d.cls); ren[k].ks2 = KSW'(i);
          end
          if (rn_uop_q[i].d.rd == rn_uop_q[k].d.rd) ren[k].old = ren[i].dst;
        end
      end
      // Wakeup column: an LLT for loads, atomics and divides with a destination, a tag for MUL
      // and the bit counts (P1's MUL slot), none for 1-cycle and serialised ops
      ren[k].use_llt = rn_uop_q[k].d.rd_en && rn_valid_q[k] &&
                       (rn_uop_q[k].d.cls == C_LD || rn_uop_q[k].d.cls == C_DIV || rn_uop_q[k].d.amo);
      ren[k].use_tag = rn_uop_q[k].d.rd_en && rn_valid_q[k] && rn_uop_q[k].d.cls == C_MUL;
      ren[k].wid = '0;
      if (ren[k].use_llt) begin
        got = 1'b0;
        for (int t = 0; t < LLT_ENTRIES; t++) begin
          if (!got && lfree[t]) begin
            got = 1'b1;
            lfree[t] = 1'b0;
            ren[k].llt = llt_t'(t);
          end
        end
        if (!got) llt_short = 1'b1;
        ren[k].wid = llt_col(int'(ren[k].llt));
      end
      if (ren[k].use_tag) begin
        got = 1'b0;
        for (int t = 0; t < IQ_TAGS; t++) begin
          if (!got && tfree[t]) begin
            got = 1'b1;
            tfree[t] = 1'b0;
            ren[k].wid = wid_t'(t);
          end
        end
        if (!got) tag_short = 1'b1;
      end
      // Destination from the port's bank (atomics: the load bank, written by the LSU)
      if (rn_uop_q[k].d.rd_en && rn_valid_q[k]) begin
        b = (port == Q_LD || rn_uop_q[k].d.amo) ? LD_BANK : port;
        ren[k].dst = mk_preg(b, fl_pop[b][pops[b]]);
        pops[b] = pops[b] + 1'b1;
      end
    end
    // Resources
    rn_ok = 1'b1;
    if (rob_cnt(rtail_q, rob_head) + nrob > ROB_ENTRIES) rn_ok = 1'b0;
    if (lq_cnt(ltail_q, lq_head) + nld > LQ_ENTRIES) rn_ok = 1'b0;
    if (sq_cnt(stail_q, sq_head) + nst > SQ_ENTRIES) rn_ok = 1'b0;
    if (llt_short || tag_short) rn_ok = 1'b0;
    if (int'(div_cnt_q) + ndiv > DIV_INFLIGHT) rn_ok = 1'b0;
    for (int i = 0; i < INT_BANKS; i++) begin
      if (int'(pops[i]) > int'(fl_count[i])) rn_ok = 1'b0;
    end
  end

  // Serialising and exception uops: alone, into an empty window; then block until the flush.
  logic rn_serial, window_empty;
  assign rn_serial    = rn_valid_q[0] && (rn_uop_q[0].d.serial || rn_uop_q[0].d.exc);
  assign window_empty = rtail_q == rob_head && !(|ds_valid_q);

  logic ds_free;
  assign rn_fire = (|rn_valid_q) && rn_ok && ds_free && !block_q && !flush && ready && start &&
                   (!rn_serial || window_empty);
  assign de_take = !flush && ready && (!(|rn_valid_q) || rn_fire);

  for (genvar b = 0; b < INT_BANKS; b++) begin : g_pops
    assign fl_pop_n[b] = rn_fire ? pops[b] : '0;
  end

  always_comb begin
    wid_alloc = '0;
    if (rn_fire) begin
      for (int k = 0; k < W; k++) begin
        if (ren[k].use_tag || ren[k].use_llt) wid_alloc[ren[k].wid] = 1'b1;
      end
    end
  end

  // ---- DS ----
  logic ds_ok;
  always_comb begin
    ds_ok = 1'b1;
    for (int k = 0; k < W; k++) begin
      if (ds_valid_q[k] && ds_ren_q[k].has_q && !iq_bank_free[ds_ren_q[k].q][k]) ds_ok = 1'b0;
    end
  end
  assign ds_fire  = (|ds_valid_q) && ds_ok && !flush;
  assign ds_free  = !(|ds_valid_q) || ds_fire;
  assign ds_valid = ds_valid_q;
  assign ds_uop   = ds_uop_q;
  assign ds_ren   = ds_ren_q;

  // MX: name a pending source by the ALU-queue row that holds its 1-cycle producer
  logic [W-1:0][RA-1:0] mrow1, mrow2;     // one-hot row, or 0 (use the ID)
  logic [W-1:0][RA-1:0] myrow;            // the row slot k is written into (ALU-queue 1-cycle ops)
  // The row of each 1-cycle op by ROB entry, one bank per rename slot. Reads: both sources of
  // every slot, in every bank; the source's producer slot picks the bank.
  localparam int ROBIW = ROBW - 1;
  logic [W-1:0][2*W-1:0][RA_W-1:0] rowrd;
  logic [2*W-1:0][ROBIW-1:0]       rowra;
  for (genvar k = 0; k < W; k++) begin : g_rowa
    assign rowra[2*k]   = ds_ren_q[k].w1[ROBIW-1:0];
    assign rowra[2*k+1] = ds_ren_q[k].w2[ROBIW-1:0];
  end
  for (genvar b = 0; b < W; b++) begin : g_rowtab
    logic            we;
    logic [RA_W-1:0] wd;
    always_comb begin
      wd = '0;
      for (int r = 0; r < RA; r++) if (myrow[b][r]) wd = RA_W'(r);
    end
    assign we = IQ_MX && ds_fire && ds_valid_q[b] && ds_uop_q[b].d.rd_en && is_lat1(ds_uop_q[b].d.cls) &&
                myrow[b] != '0;
    tg_ram_lut #(.DEPTH(ROB_ENTRIES), .WIDTH(RA_W), .NR(2 * W)) u_row (
      .clk, .we, .waddr(ds_ren_q[b].rob[ROBIW-1:0]), .wdata(wd), .raddr(rowra), .rdata(rowrd[b]));
  end
  for (genvar k = 0; k < W; k++) begin : g_mx
    always_comb begin
      myrow[k] = '0;
      if (ds_ren_q[k].has_q && int'(ds_ren_q[k].q) < N_ALU)
        myrow[k] = mx_alloc[ds_ren_q[k].q][k];
    end
    logic [RA_W-1:0] row1, row2;
    assign row1 = rowrd[ds_ren_q[k].ks1][2*k];
    assign row2 = rowrd[ds_ren_q[k].ks2][2*k+1];
    always_comb begin
      mrow1[k] = '0;
      mrow2[k] = '0;
      if (IQ_MX) begin
        if (ds_ren_q[k].p1 && ds_ren_q[k].l1 && int'(row1) < RA && mx_hold[row1] &&
            rowdst_q[row1] == ds_ren_q[k].src1)
          mrow1[k][row1] = 1'b1;
        if (ds_ren_q[k].p2 && ds_ren_q[k].l2 && int'(row2) < RA && mx_hold[row2] &&
            rowdst_q[row2] == ds_ren_q[k].src2)
          mrow2[k][row2] = 1'b1;
        // a producer in the same group: the row it is being written into
        for (int i = 0; i < k; i++) begin
          if (ds_valid_q[i] && ds_uop_q[i].d.rd_en && is_lat1(ds_uop_q[i].d.cls) && myrow[i] != '0) begin
            if (ds_ren_q[k].p1 && ds_ren_q[i].dst == ds_ren_q[k].src1) mrow1[k] = myrow[i];
            if (ds_ren_q[k].p2 && ds_ren_q[i].dst == ds_ren_q[k].src2) mrow2[k] = myrow[i];
          end
        end
      end
    end
  end

  always_comb begin
    iq_we = '0;
    for (int k = 0; k < W; k++) begin
      if (ds_fire && ds_valid_q[k] && ds_ren_q[k].has_q) iq_we[ds_ren_q[k].q][k] = 1'b1;
      // A pending source waits on its producer's column, or on its row (MX); a 1-cycle
      // producer whose row has been freed needs nothing
      iq_dep[k] = '0;
      if (ds_ren_q[k].p1 && ds_ren_q[k].c1) iq_dep[k][wid_t'(ds_ren_q[k].w1)] = 1'b1;
      if (ds_ren_q[k].p2 && ds_ren_q[k].c2) iq_dep[k][wid_t'(ds_ren_q[k].w2)] = 1'b1;
      iq_dep[k] &= ~w_vec;
      iq_mdep[k] = mrow1[k] | mrow2[k];
      iq_pl[k] = '0;
      iq_pl[k].rob       = ds_ren_q[k].rob;
      iq_pl[k].tid       = ds_uop_q[k].tid;
      iq_pl[k].cls       = ds_uop_q[k].d.cls;
      iq_pl[k].alu       = ds_uop_q[k].d.alu;
      iq_pl[k].b_imm     = ds_uop_q[k].d.b_imm;
      iq_pl[k].imm       = ds_uop_q[k].d.imm;
      iq_pl[k].src1      = ds_ren_q[k].src1;
      iq_pl[k].src2      = ds_ren_q[k].src2;
      iq_pl[k].dst_en    = ds_uop_q[k].d.rd_en;
      iq_pl[k].dst       = ds_ren_q[k].dst;
      iq_pl[k].wid       = ds_ren_q[k].wid;
      iq_pl[k].llt       = ds_ren_q[k].llt;
      iq_pl[k].pc        = ds_uop_q[k].pc;
      iq_pl[k].br_kind   = ds_uop_q[k].d.br_kind;
      iq_pl[k].br_f3     = ds_uop_q[k].d.br_f3;
      iq_pl[k].br_target = ds_uop_q[k].d.br_target;
      iq_pl[k].jalr_off  = ds_uop_q[k].d.jalr_off;
      iq_pl[k].pred_npc  = ds_uop_q[k].pred_npc;
      iq_pl[k].ubtb_hit  = ds_uop_q[k].ubtb_hit;
      iq_pl[k].ubtb_way  = ds_uop_q[k].ubtb_way;
      iq_pl[k].dfix      = ds_uop_q[k].dfix;
      iq_pl[k].rvc       = ds_uop_q[k].rvc;
      iq_pl[k].mul_op    = ds_uop_q[k].d.mul_op;
      iq_pl[k].div_op    = ds_uop_q[k].d.div_op;
      iq_pl[k].word      = ds_uop_q[k].d.word;
      iq_pl[k].bcnt      = ds_uop_q[k].d.bcnt;
      iq_pl[k].csr_op    = ds_uop_q[k].d.csr_op;
      iq_pl[k].csr_imm   = ds_uop_q[k].d.csr_imm;
      iq_pl[k].csr_wr    = ds_uop_q[k].d.csr_wr;
      iq_pl[k].csr_addr  = ds_uop_q[k].insn[31:20];
      iq_pl[k].csr_zimm  = ds_uop_q[k].insn[19:15];
      iq_pl[k].insn      = ds_uop_q[k].insn;
      iq_pl[k].lq        = ds_ren_q[k].lq;
      iq_pl[k].sq        = ds_ren_q[k].sq;
      iq_pl[k].mem_size  = ds_uop_q[k].d.mem_size;
      iq_pl[k].mem_uns   = ds_uop_q[k].d.mem_uns;
    end
  end

  // ---- Commit: committed map, free-list pushes and commit heads ----
  always_comb begin
    fl_push_v = '0;
    fl_push_idx = '0;
    fl_cmt_n = '0;
    for (int j = 0; j < COMMIT_WIDTH; j++) begin
      if (cm_valid[j] && cm_rd_en[j]) begin
        fl_push_v[preg_bank(cm_old[j])][j]   = 1'b1;
        fl_push_idx[preg_bank(cm_old[j])][j] = preg_idx(cm_old[j]);
        fl_cmt_n[preg_bank(cm_dst[j])]       = fl_cmt_n[preg_bank(cm_dst[j])] + 1'b1;
      end
    end
  end

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    if (rst) begin
      sv_q       <= '0;
      lvtc_q     <= '0;
      cinit_q    <= '0;
      ready_q    <= '1;
      llt_busy_q <= '0;
      tag_busy_q <= '0;
      rtail_q    <= '0;
      ltail_q    <= '0;
      stail_q    <= '0;
      div_cnt_q  <= '0;
      block_q    <= 1'b0;
      rn_valid_q <= '0;
      ds_valid_q <= '0;
    end else begin
      // Committed map: the bank written last
      if (!cinit_q[5]) cinit_q <= cinit_q + 1'b1;
      for (int j = 0; j < COMMIT_WIDTH; j++) begin
        if (cm_valid[j] && cm_rd_en[j]) lvtc_q[cm_rd[j]] <= CSW'(j);
      end
      // Ready bits: set by register-file writes, cleared by allocation (below)
      for (int b = 0; b < INT_BANKS; b++) begin
        if (rf_we[b]) ready_q[mk_preg(b, rf_widx[b])] <= 1'b1;
      end
      llt_busy_q <= llt_busy_q & ~llt_rel;
      tag_busy_q <= tag_busy_q & ~tag_free;
      if (div_done && div_cnt_q != '0) div_cnt_q <= div_cnt_q - 1'b1;

      if (flush) begin
        sv_q       <= '0;               // the committed map (with this cycle's commits) answers
        llt_busy_q <= '0;
        tag_busy_q <= '0;               // every tagged producer in flight is squashed
        rtail_q    <= rob_head;
        ltail_q    <= lq_head;
        stail_q    <= sq_cmt;
        div_cnt_q  <= '0;
        block_q    <= 1'b0;
        rn_valid_q <= '0;
        ds_valid_q <= '0;
      end else begin
        // DS
        if (ds_fire) ds_valid_q <= '0;
        if (ds_fire && IQ_MX) begin
          for (int k = 0; k < W; k++) begin
            if (ds_valid_q[k] && ds_uop_q[k].d.rd_en && is_lat1(ds_uop_q[k].d.cls)) begin
              for (int r = 0; r < RA; r++) begin
                if (myrow[k][r]) rowdst_q[r] <= ds_ren_q[k].dst;
              end
            end
          end
        end
        // RN -> DS
        if (rn_fire) begin
          ds_valid_q <= rn_valid_q;
          ds_uop_q   <= rn_uop_q;
          ds_ren_q   <= ren;
          rn_valid_q <= '0;
          for (int k = 0; k < W; k++) begin
            if (rn_valid_q[k]) begin
              if (rn_uop_q[k].d.rd_en) begin
                sv_q[rn_uop_q[k].d.rd]  <= 1'b1;
                lvt_q[rn_uop_q[k].d.rd] <= KSW'(k);
                ready_q[ren[k].dst]     <= 1'b0;
              end
              if (ren[k].use_llt) llt_busy_q[ren[k].llt] <= 1'b1;
              if (ren[k].use_tag) tag_busy_q[ren[k].wid[WTAG_W-1:0]] <= 1'b1;
            end
          end
          rtail_q <= rob_add(rtail_q, $countones(rn_valid_q));
          ltail_q <= lq_add(ltail_q, ren_nld(rn_uop_q, rn_valid_q));
          stail_q <= sq_add(stail_q, ren_nst(rn_uop_q, rn_valid_q));
          div_cnt_q <= div_cnt_q + (idx_w(DIV_INFLIGHT + 1))'(ren_ndiv(rn_uop_q, rn_valid_q))
                       - (idx_w(DIV_INFLIGHT + 1))'(div_done && div_cnt_q != '0);
          if (rn_serial) block_q <= 1'b1;
        end
        // DE -> RN
        if (de_take) begin
          rn_valid_q <= de_valid;
          rn_uop_q   <= de_uop;
        end
      end
    end
  end

  function automatic int ren_nld(input uop_t [W-1:0] u, input logic [W-1:0] v);
    int n;
    n = 0;
    for (int k = 0; k < W; k++) if (v[k] && u[k].d.cls == C_LD) n++;
    return n;
  endfunction
  function automatic int ren_ndiv(input uop_t [W-1:0] u, input logic [W-1:0] v);
    int n;
    n = 0;
    for (int k = 0; k < W; k++) if (v[k] && u[k].d.cls == C_DIV) n++;
    return n;
  endfunction
  function automatic int ren_nst(input uop_t [W-1:0] u, input logic [W-1:0] v);
    int n;
    n = 0;
    for (int k = 0; k < W; k++) if (v[k] && u[k].d.cls == C_ST) n++;
    return n;
  endfunction

  logic unused;
  assign unused = ^{busy[IQ_TAGS-1:0]};   // tag columns are cleared when a tag returns, not guarded

`ifndef SYNTHESIS
  // A group is a prefix of valid slots.
  always_ff @(posedge clk) begin
    if (!rst) begin
      for (int k = 1; k < W; k++)
        assert (!rn_valid_q[k] || rn_valid_q[k-1]) else $error("tg_rename: group is not a prefix");
      assert ((tag_free & ~tag_busy_q) == '0 || flush) else $error("tg_rename: a free tag returned");
    end
  end
`endif
endmodule
