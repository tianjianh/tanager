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
// MX (IQ_MX): a source whose producer is a 1-cycle op still holding its ALU-queue row is named
// by that row instead of its ID. The row is found through rowof_q (physical register -> the row
// its producer was written into) and confirmed with one compare of the row's destination
// (rowdst_q) against the source; a producer in the same group is named by the row it is
// being written into. Otherwise the ID is used.
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
  output logic [DISPATCH_WIDTH-1:0][NCOL-1:0] iq_wake,
  output iq_pl_t [DISPATCH_WIDTH-1:0]      iq_pl,
  output logic [DISPATCH_WIDTH-1:0][RA-1:0] iq_mdep,     // MX: sources named by ALU-queue row
  input  logic [RA-1:0]                    mx_hold,     // ALU-queue rows holding an op
  input  logic [N_ALU-1:0][DISPATCH_WIDTH-1:0][RA-1:0] mx_alloc,  // rows written next
  output logic [NCOL-1:0]                  wid_alloc,   // IDs given out at RN (clear W)
  output logic [NPR-1:0]                   ready_vec,
  output robid_t                           rob_tail     // next ROB entry RN gives out
);
  if (W != DISPATCH_WIDTH) begin : g_bad
    $error("tg_rename: RENAME_WIDTH must equal DISPATCH_WIDTH");
  end

  // ---- State ----
  preg_t [31:0]          rat_q, crat_q;
  logic [NPR-1:0]        ready_q;
  wid_t [NPR-1:0]        prod_q;
  logic [LLT_ENTRIES-1:0] llt_busy_q;
  robid_t                rtail_q;
  lqid_t                 ltail_q;
  sqid_t                 stail_q;
  logic [idx_w(DIV_INFLIGHT + 1)-1:0] div_cnt_q;
  logic                  block_q;          // after a serialising uop, until the flush
  // MX naming state
  logic [NPR-1:0]        lat1_q;           // the register's producer wakes at select
  logic [NPR-1:0][RA_W-1:0] rowof_q;       // ALU-queue row its producer was written into
  preg_t [RA-1:0]        rowdst_q;         // destination of the op each ALU-queue row holds

  logic [W-1:0]          rn_valid_q;
  uop_t [W-1:0]          rn_uop_q;
  logic [W-1:0]          ds_valid_q;
  uop_t [W-1:0]          ds_uop_q;
  ren_t [W-1:0]          ds_ren_q;

  assign ready_vec = ready_q;
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
  assign ready = &fl_ready;

  // ---- RN ----
  ren_t [W-1:0]  ren;
  logic          rn_ok;             // resources available for the whole group
  logic [INT_BANKS-1:0][idx_w(W+1)-1:0] pops;
  always_comb begin
    int nrob, nld, nst, ndiv, port, pref, p, b;
    logic [LLT_ENTRIES-1:0] lfree;
    logic llt_short, found, got, rob_busy;
    pops = '0;
    nld = 0; nst = 0; ndiv = 0; nrob = 0;
    port = 0; pref = 0; p = 0; b = 0;
    lfree = ~llt_busy_q & ~busy[ROB_ENTRIES +: LLT_ENTRIES];
    llt_short = 1'b0;
    rob_busy = 1'b0;
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
      if (rn_valid_q[k] && busy[ren[k].rob[ROBW-2:0]]) rob_busy = 1'b1;
      ren[k].lq  = lq_add(ltail_q, nld);
      ren[k].sq  = sq_add(stail_q, nst);
      if (rn_valid_q[k]) begin
        if (rn_uop_q[k].d.cls == C_LD) nld++;
        if (rn_uop_q[k].d.cls == C_ST) nst++;
        if (rn_uop_q[k].d.cls == C_DIV) ndiv++;
        nrob = k + 1;
      end
      // Sources: RAT, or the closest earlier slot that writes the register
      ren[k].src1 = rn_uop_q[k].d.rs1_en ? rat_q[rn_uop_q[k].d.rs1] : '0;
      ren[k].src2 = rn_uop_q[k].d.rs2_en ? rat_q[rn_uop_q[k].d.rs2] : '0;
      ren[k].p1   = rn_uop_q[k].d.rs1_en && !ready_q[ren[k].src1];
      ren[k].p2   = rn_uop_q[k].d.rs2_en && !ready_q[ren[k].src2];
      ren[k].w1   = prod_q[ren[k].src1];
      ren[k].w2   = prod_q[ren[k].src2];
      ren[k].old  = rat_q[rn_uop_q[k].d.rd];
      for (int i = 0; i < k; i++) begin
        if (rn_uop_q[i].d.rd_en) begin
          if (rn_uop_q[k].d.rs1_en && rn_uop_q[i].d.rd == rn_uop_q[k].d.rs1) begin
            ren[k].src1 = ren[i].dst; ren[k].p1 = 1'b1; ren[k].w1 = ren[i].wid;
          end
          if (rn_uop_q[k].d.rs2_en && rn_uop_q[i].d.rd == rn_uop_q[k].d.rs2) begin
            ren[k].src2 = ren[i].dst; ren[k].p2 = 1'b1; ren[k].w2 = ren[i].wid;
          end
          if (rn_uop_q[i].d.rd == rn_uop_q[k].d.rd) ren[k].old = ren[i].dst;
        end
      end
      // Wakeup ID: an LLT for loads and divides with a destination, else the ROB entry
      ren[k].use_llt = rn_uop_q[k].d.rd_en && rn_valid_q[k] &&
                       (rn_uop_q[k].d.cls == C_LD || rn_uop_q[k].d.cls == C_DIV);
      ren[k].wid = wid_t'(ren[k].rob[ROBW-2:0]);
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
        ren[k].wid = wid_t'(ROB_ENTRIES + int'(ren[k].llt));
      end
      // Destination from the port's bank
      if (rn_uop_q[k].d.rd_en && rn_valid_q[k]) begin
        b = (port == Q_LD) ? LD_BANK : port;
        ren[k].dst = mk_preg(b, fl_pop[b][pops[b]]);
        pops[b] = pops[b] + 1'b1;
      end
    end
    // Resources
    rn_ok = 1'b1;
    if (rob_cnt(rtail_q, rob_head) + nrob > ROB_ENTRIES) rn_ok = 1'b0;
    if (lq_cnt(ltail_q, lq_head) + nld > LQ_ENTRIES) rn_ok = 1'b0;
    if (sq_cnt(stail_q, sq_head) + nst > SQ_ENTRIES) rn_ok = 1'b0;
    if (llt_short || rob_busy) rn_ok = 1'b0;
    if (int'(div_cnt_q) + ndiv > DIV_INFLIGHT) rn_ok = 1'b0;
    for (int i = 0; i < INT_BANKS; i++) begin
      if (int'(pops[i]) > int'(fl_count[i])) rn_ok = 1'b0;
    end
  end

  // Serialising and exception uops: alone, into an empty window; then block until the flush.
  logic rn_serial, window_empty;
  assign rn_serial    = rn_valid_q[0] && (rn_uop_q[0].d.serial || rn_uop_q[0].d.exc);
  assign window_empty = rtail_q == rob_head && !(|ds_valid_q);

  logic ds_free, rn_fire;
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
        if (rn_valid_q[k]) wid_alloc[ren[k].wid] = 1'b1;
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
  function automatic logic is_lat1(input uclass_e c);
    return c == C_ALU || c == C_BR;
  endfunction
  logic [W-1:0][RA-1:0] mrow1, mrow2;     // one-hot row, or 0 (use the ID)
  logic [W-1:0][RA-1:0] myrow;            // the row slot k is written into (ALU-queue 1-cycle ops)
  for (genvar k = 0; k < W; k++) begin : g_mx
    always_comb begin
      myrow[k] = '0;
      if (ds_ren_q[k].has_q && int'(ds_ren_q[k].q) < N_ALU)
        myrow[k] = mx_alloc[ds_ren_q[k].q][k];
    end
    always_comb begin
      mrow1[k] = '0;
      mrow2[k] = '0;
      if (IQ_MX) begin
        if (ds_ren_q[k].p1 && lat1_q[ds_ren_q[k].src1] && int'(rowof_q[ds_ren_q[k].src1]) < RA &&
            mx_hold[rowof_q[ds_ren_q[k].src1]] && rowdst_q[rowof_q[ds_ren_q[k].src1]] == ds_ren_q[k].src1)
          mrow1[k][rowof_q[ds_ren_q[k].src1]] = 1'b1;
        if (ds_ren_q[k].p2 && lat1_q[ds_ren_q[k].src2] && int'(rowof_q[ds_ren_q[k].src2]) < RA &&
            mx_hold[rowof_q[ds_ren_q[k].src2]] && rowdst_q[rowof_q[ds_ren_q[k].src2]] == ds_ren_q[k].src2)
          mrow2[k][rowof_q[ds_ren_q[k].src2]] = 1'b1;
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
      iq_dep[k] = '0;
      if (ds_ren_q[k].p1 && mrow1[k] == '0) iq_dep[k][ds_ren_q[k].w1] = 1'b1;
      if (ds_ren_q[k].p2 && mrow2[k] == '0) iq_dep[k][ds_ren_q[k].w2] = 1'b1;
      iq_dep[k] &= ~w_vec;
      iq_mdep[k] = mrow1[k] | mrow2[k];
      iq_wake[k] = '0;
      if (ds_uop_q[k].d.cls == C_ALU || ds_uop_q[k].d.cls == C_BR) iq_wake[k][ds_ren_q[k].wid] = 1'b1;
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
      for (int r = 0; r < 32; r++) begin
        rat_q[r]  <= mk_preg(0, PIDX_W'(r));
        crat_q[r] <= mk_preg(0, PIDX_W'(r));
      end
      ready_q    <= '1;
      llt_busy_q <= '0;
      rtail_q    <= '0;
      ltail_q    <= '0;
      stail_q    <= '0;
      div_cnt_q  <= '0;
      block_q    <= 1'b0;
      rn_valid_q <= '0;
      ds_valid_q <= '0;
    end else begin
      // Committed map
      for (int j = 0; j < COMMIT_WIDTH; j++) begin
        if (cm_valid[j] && cm_rd_en[j]) crat_q[cm_rd[j]] <= cm_dst[j];
      end
      // Ready bits: set by register-file writes, cleared by allocation (below)
      for (int b = 0; b < INT_BANKS; b++) begin
        if (rf_we[b]) ready_q[mk_preg(b, rf_widx[b])] <= 1'b1;
      end
      llt_busy_q <= llt_busy_q & ~llt_rel;
      if (div_done && div_cnt_q != '0) div_cnt_q <= div_cnt_q - 1'b1;

      if (flush) begin
        for (int r = 0; r < 32; r++) rat_q[r] <= crat_q[r];
        for (int j = 0; j < COMMIT_WIDTH; j++) begin
          if (cm_valid[j] && cm_rd_en[j]) rat_q[cm_rd[j]] <= cm_dst[j];
        end
        llt_busy_q <= '0;
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
                if (myrow[k][r]) begin
                  rowof_q[ds_ren_q[k].dst] <= RA_W'(r);
                  rowdst_q[r] <= ds_ren_q[k].dst;
                end
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
                rat_q[rn_uop_q[k].d.rd] <= ren[k].dst;
                ready_q[ren[k].dst] <= 1'b0;
                prod_q[ren[k].dst] <= ren[k].wid;
                lat1_q[ren[k].dst] <= is_lat1(rn_uop_q[k].d.cls);
              end
              if (ren[k].use_llt) llt_busy_q[ren[k].llt] <= 1'b1;
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

`ifndef SYNTHESIS
  // A group is a prefix of valid slots.
  always_ff @(posedge clk) begin
    if (!rst) begin
      for (int k = 1; k < W; k++)
        assert (!rn_valid_q[k] || rn_valid_q[k-1]) else $error("tg_rename: group is not a prefix");
    end
  end
`endif
endmodule
