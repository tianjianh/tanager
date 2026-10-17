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
// The ready tables (one bit per physical register: written since allocated) are LUTRAM too
// (tg_rdytab): a set phase per bank, written by the bank's register-file port, and an allocation
// phase XOR-banked by rename slot. They read as the flip-flop vectors they replace did.
// MX (IQ_MX): a source whose producer is a 1-cycle op still holding its ALU-queue row is named
// by that row instead of its ID. DS records each 1-cycle op's row in a LUTRAM by ROB entry, one
// bank per rename slot (one write per bank per cycle); a consumer reads it in the bank of its
// producer's slot, and one compare of the row's destination (rowdst) against the source
// confirms the row still holds it. A producer in the same group is named by the row it is being
// written into. Otherwise the ID is used. rowdst is LUTRAM too, banked by DS slot and read by
// row: a row's value is the XOR of the banks.
// F and D (EXT_FD): a second map (tg_rmap) for the f registers, whose physical registers are
// {bank, index} in F0 (P4 results) or F1 (FP loads), with their own free lists and ready table.
// An FP op's integer source (FCVT.F.I, FMV.F.X) and an FP store's address are integer sources
// as usual; an FP op with an integer result writes bank B1. FMA and FMISC ops with an FP result
// take a wakeup tag; divides, square roots and FP->int ops an LLT. FP divides and FP->int ops
// are held to FDIV_INFLIGHT and FPI_INFLIGHT between rename and their return from P4: each
// count is the uops renamed but not yet issued (dropped by a flush) plus those issued and not
// yet returned (fdiv_done, fpi_pop: P4 returns every issued one, flushed or not).
module tg_rename
  import tg_pkg::*, tg_core_pkg::*;
#(
  localparam int W   = RENAME_WIDTH,
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
  // F and D (EXT_FD): FP register-file writes (F0: P4, F1: FP loads), P4 issue and returns
  input  logic [1:0]                       fp_we,
  input  logic [1:0][FPIDX_W-1:0]          fp_widx,
  input  logic                             fdiv_iss,    // IQ-FP issued a divide / sqrt
  input  logic                             fpi_iss,     // ... an FP->int op
  input  logic                             fdiv_done,   // P4 returned a divide
  input  logic                             fpi_pop,     // ... an FP->int op
  // Commit
  input  logic [COMMIT_WIDTH-1:0]          cm_valid,
  input  logic [COMMIT_WIDTH-1:0]          cm_rd_en,
  input  logic [COMMIT_WIDTH-1:0][4:0]     cm_rd,
  input  preg_t [COMMIT_WIDTH-1:0]         cm_dst,
  input  preg_t [COMMIT_WIDTH-1:0]         cm_old,
  input  logic [COMMIT_WIDTH-1:0]          cm_rd_fp,    // ... rd is an f register
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
  typedef struct packed {
    pid_t           id;                    // producer's column, or its ROB index if l1
    logic           cv;                    // ... has a wakeup column
    logic           l1;                    // ... is a 1-cycle op
    logic [KSW-1:0] ks;                    // ... renamed in this slot of its group
  } rprod_t;
  function automatic logic is_lat1(input uclass_e c);       // a 1-cycle op in an ALU queue
    return c == C_ALU || c == C_BR;
  endfunction
  logic [LLT_ENTRIES-1:0] llt_busy_q;
  logic [IQ_TAGS-1:0]    tag_busy_q;
  robid_t                rtail_q;
  lqid_t                 ltail_q;
  sqid_t                 stail_q;
  logic [idx_w(DIV_INFLIGHT + 1)-1:0] div_cnt_q;
  // FP divides and FP->int ops: renamed, not yet issued (a flush drops them) / issued, not
  // yet returned by P4
  logic [idx_w(FDIV_INFLIGHT + 1)-1:0] fdiv_pre_q, fdiv_post_q;
  logic [idx_w(FPI_INFLIGHT + 1)-1:0]  fpi_pre_q, fpi_post_q;
  logic                  block_q;          // after a serialising uop, until the flush

  logic [W-1:0]          rn_valid_q;
  uop_t [W-1:0]          rn_uop_q;
  logic [W-1:0]          ds_valid_q;
  uop_t [W-1:0]          ds_uop_q;
  ren_t [W-1:0]          ds_ren_q;

  logic [3*W-1:0] irdy;                  // integer ready table reads: RN sources, DS rs2
  logic [4*W-1:0] frdy;                  // FP: RN sources (3 per slot), DS rs2
  for (genvar k = 0; k < W; k++) begin : g_s2r
    assign ds_src2_rdy[k] = (EXT_FD && ds_uop_q[k].d.rs2_fp) ? frdy[3*W + k] : irdy[2*W + k];
  end
  assign rob_tail  = rtail_q;

  // Rename's fire, declared ahead of the free lists that take it: inside their generate blocks a
  // not-yet-declared name becomes a new implicit net in synthesis (Vivado: Synth 8-11241), which
  // left `pop` undriven, so no free list's head ever moved and every allocation of a bank got the
  // same register (the board's register corruption; simulation resolves the name to this one)
  logic         rn_fire;

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
      .pop_n(fl_pop_n[b]), .pop(rn_fire), .push_v(fl_push_v[b]), .push_idx(fl_push_idx[b]),
      .commit_n(fl_cmt_n[b]), .flush);
  end

  // ---- FP free lists (EXT_FD): F0 starts with indices 32-63 (f0-f31 map to F0 0-31), F1 0-63
  logic [1:0]                         ffl_ready;
  logic [1:0][FPIDX_W:0]              ffl_count;
  logic [1:0][W-1:0][FPIDX_W-1:0]     ffl_pop;
  logic [1:0][idx_w(W+1)-1:0]         ffl_pop_n;
  logic [1:0][COMMIT_WIDTH-1:0]       ffl_push_v;
  logic [1:0][COMMIT_WIDTH-1:0][FPIDX_W-1:0] ffl_push_idx;
  logic [1:0][idx_w(COMMIT_WIDTH+1)-1:0] ffl_cmt_n;
  logic [1:0][idx_w(W+1)-1:0]         fpops;
  if (EXT_FD) begin : g_ffl
    for (genvar b = 0; b < 2; b++) begin : g_b
      tg_freelist #(.DEPTH(FP_PREGS_PER_BANK), .NB(FL_BANKS), .NPOP(W), .NPUSH(COMMIT_WIDTH),
                    .FIRST(b == FPB_F0 ? 32 : 0)) u_fl (
        .clk, .rst, .ready(ffl_ready[b]), .count(ffl_count[b]), .pop_idx(ffl_pop[b]),
        .pop_n(ffl_pop_n[b]), .pop(rn_fire), .push_v(ffl_push_v[b]), .push_idx(ffl_push_idx[b]),
        .commit_n(ffl_cmt_n[b]), .flush);
    end
  end else begin : g_noffl
    assign ffl_ready = '1;
    assign ffl_count = '0;
    assign ffl_pop   = '0;
    logic unused;
    assign unused = ^{ffl_pop_n, ffl_push_v, ffl_push_idx, ffl_cmt_n};
  end

  // ---- Rename maps (LUTRAM) ----
  // Read ports: rs1 and rs2 of slot k at 2k and 2k + 1, rd (the old mapping) at 2W + k; the
  // producer fields are read for the sources only.
  localparam int NMR = 3 * W;
  localparam int PRW = $bits(preg_t);
  localparam int PDW = $bits(rprod_t);
  logic [NMR-1:0][4:0]                  map_ra;
  preg_t  [NMR-1:0]                     map_p;    // mapping per read port
  rprod_t [2*W-1:0]                     map_pd;   // producer per source port (a committed
                                                  // mapping's producer is done: not read)
  for (genvar k = 0; k < W; k++) begin : g_mra
    assign map_ra[2*k]     = rn_uop_q[k].d.rs1;
    assign map_ra[2*k+1]   = rn_uop_q[k].d.rs2;
    assign map_ra[2*W + k] = rn_uop_q[k].d.rd;
  end
  ren_t [W-1:0] ren;
  logic [W-1:0]                im_we;
  logic [W-1:0][4:0]           im_wa;
  logic [W-1:0][PRW-1:0]       im_wdp;
  logic [W-1:0][PDW-1:0]       im_wdd;
  logic [COMMIT_WIDTH-1:0]     icm_we;
  logic [NMR-1:0][PRW-1:0]     im_rdp;
  logic [2*W-1:0][PDW-1:0]     im_rdd;
  logic                        imap_ready;
  for (genvar k = 0; k < W; k++) begin : g_imw
    assign im_we[k]  = rn_fire && rn_valid_q[k] && rn_uop_q[k].d.rd_en && !rn_uop_q[k].d.rd_fp;
    assign fm_we[k]  = EXT_FD && rn_fire && rn_valid_q[k] && rn_uop_q[k].d.rd_en && rn_uop_q[k].d.rd_fp;
    assign im_wa[k]  = rn_uop_q[k].d.rd;
    assign im_wdp[k] = ren[k].dst;
    assign im_wdd[k] = rprod_t'{id: is_lat1(rn_uop_q[k].d.cls) ? pid_t'(ren[k].rob[ROBW-2:0])
                                                               : pid_t'(ren[k].wid),
                                cv: ren[k].use_tag || ren[k].use_llt,
                                l1: is_lat1(rn_uop_q[k].d.cls), ks: KSW'(k)};
  end
  for (genvar j = 0; j < COMMIT_WIDTH; j++) begin : g_icm
    assign icm_we[j] = cm_valid[j] && cm_rd_en[j] && !cm_rd_fp[j];
  end
  tg_rmap #(.W(W), .CW(COMMIT_WIDTH), .PW(PRW), .DW(PDW), .NR(NMR), .NRD(2 * W)) u_imap (
    .clk, .rst, .flush, .ready(imap_ready), .ra(map_ra), .rd_p(im_rdp), .rd_d(im_rdd),
    .we(im_we), .wa(im_wa), .wd_p(im_wdp), .wd_d(im_wdd), .cwe(icm_we), .cwa(cm_rd),
    .cwd(cm_dst));
  for (genvar i = 0; i < NMR; i++) begin : g_imr
    assign map_p[i] = preg_t'(im_rdp[i]);
  end
  for (genvar i = 0; i < 2 * W; i++) begin : g_imd
    assign map_pd[i] = rprod_t'(im_rdd[i]);
  end

  // FP map (EXT_FD): rs1, rs2, rs3 of slot k at 3k .. 3k + 2, rd at 3W + k; the producer
  // fields (its wakeup column: an FP result always has one) for the sources
  localparam int FNMR = 4 * W;
  localparam int FRW  = FPIDX_W + 1;
  logic [FNMR-1:0][4:0]        fmap_ra;
  logic [FNMR-1:0][FRW-1:0]    fmap_p;
  logic [3*W-1:0][COL_W-1:0]   fmap_w;
  logic                        fmap_ready;
  logic [W-1:0]                fm_we;
  logic [COMMIT_WIDTH-1:0]     fcm_we;
  logic [COMMIT_WIDTH-1:0][FRW-1:0] fcm_wd;
  for (genvar k = 0; k < W; k++) begin : g_fmra
    assign fmap_ra[3*k]     = rn_uop_q[k].d.rs1;
    assign fmap_ra[3*k+1]   = rn_uop_q[k].d.rs2;
    assign fmap_ra[3*k+2]   = rn_uop_q[k].d.rs3;
    assign fmap_ra[3*W + k] = rn_uop_q[k].d.rd;
  end
  for (genvar j = 0; j < COMMIT_WIDTH; j++) begin : g_fcm
    assign fcm_we[j] = EXT_FD && cm_valid[j] && cm_rd_en[j] && cm_rd_fp[j];
    assign fcm_wd[j] = FRW'(cm_dst[j]);
  end
  if (EXT_FD) begin : g_fmap
    logic [W-1:0][4:0]       fm_wa;
    logic [W-1:0][FRW-1:0]   fm_wdp;
    logic [W-1:0][COL_W-1:0] fm_wdd;
    for (genvar k = 0; k < W; k++) begin : g_w
      assign fm_wa[k]  = rn_uop_q[k].d.rd;
      assign fm_wdp[k] = FRW'(ren[k].dst);
      assign fm_wdd[k] = ren[k].wid;
    end
    tg_rmap #(.W(W), .CW(COMMIT_WIDTH), .PW(FRW), .DW(COL_W), .NR(FNMR), .NRD(3 * W)) u_fmap (
      .clk, .rst, .flush, .ready(fmap_ready), .ra(fmap_ra), .rd_p(fmap_p), .rd_d(fmap_w),
      .we(fm_we), .wa(fm_wa), .wd_p(fm_wdp), .wd_d(fm_wdd), .cwe(fcm_we), .cwa(cm_rd),
      .cwd(fcm_wd));
  end else begin : g_nofmap
    assign fmap_ready = 1'b1;
    assign fmap_p     = '0;
    assign fmap_w     = '0;
    logic unused;
    assign unused = ^{fmap_ra, fm_we, fcm_we, fcm_wd};
  end
  // ---- Ready tables (LUTRAM): set by register-file writes, cleared by allocation at RN ----
  // Read ports: the RN sources (integer rs1, rs2 of slot k at 2k, 2k + 1; FP rs1-rs3 at 3k ..
  // 3k + 2), then rs2 of each DS slot (store data).
  // Clears: every cycle, each free list's next W registers (those it holds), rename or not
  logic irdy_ready, frdy_ready;
  logic [INT_BANKS-1:0][W-1:0] icv;
  logic [1:0][W-1:0]           fcv;
  logic [3*W-1:0][BANK_W-1:0] ir_b;
  logic [3*W-1:0][PIDX_W-1:0] ir_i;
  always_comb begin
    for (int b = 0; b < INT_BANKS; b++)
      for (int c = 0; c < W; c++) icv[b][c] = int'(fl_count[b]) > c;
    for (int b = 0; b < 2; b++)
      for (int c = 0; c < W; c++) fcv[b][c] = int'(ffl_count[b]) > c;
  end
  for (genvar i = 0; i < 2 * W; i++) begin : g_irs
    assign ir_b[i] = preg_bank(map_p[i]);
    assign ir_i[i] = preg_idx(map_p[i]);
  end
  for (genvar k = 0; k < W; k++) begin : g_ird
    assign ir_b[2*W + k] = preg_bank(ds_ren_q[k].src2);
    assign ir_i[2*W + k] = preg_idx(ds_ren_q[k].src2);
  end
  tg_rdytab #(.NB(INT_BANKS), .DEPTH(INT_PREGS_PER_BANK), .W(W), .NR(3 * W)) u_irdy (
    .clk, .rst, .ready(irdy_ready), .set_v(rf_we), .set_i(rf_widx), .cand_v(icv), .cand_i(fl_pop),
    .rd_b(ir_b), .rd_i(ir_i), .rdy(irdy));
  if (EXT_FD) begin : g_frdy
    logic [4*W-1:0]              fr_b;
    logic [4*W-1:0][FPIDX_W-1:0] fr_i;
    for (genvar i = 0; i < 3 * W; i++) begin : g_frs
      assign fr_b[i] = fmap_p[i][FPIDX_W];
      assign fr_i[i] = fmap_p[i][FPIDX_W-1:0];
    end
    for (genvar k = 0; k < W; k++) begin : g_frd
      assign fr_b[3*W + k] = fpreg_bank(ds_ren_q[k].src2);
      assign fr_i[3*W + k] = fpreg_idx(ds_ren_q[k].src2);
    end
    tg_rdytab #(.NB(2), .DEPTH(FP_PREGS_PER_BANK), .W(W), .NR(4 * W)) u_frdy (
      .clk, .rst, .ready(frdy_ready), .set_v(fp_we), .set_i(fp_widx), .cand_v(fcv), .cand_i(ffl_pop),
      .rd_b(fr_b), .rd_i(fr_i), .rdy(frdy));
  end else begin : g_nofrdy
    assign frdy_ready = 1'b1;
    assign frdy       = '1;
    logic unused;
    assign unused = ^{fcv, ffl_pop};
  end

  // `ready` (decode may hand over a group) does not wait for the ready tables' sweep: it takes
  // 64 cycles after reset, as the D$'s does, so only rn_fire waits for it, and no earlier than
  // `start` did
  assign ready = &fl_ready && imap_ready && &ffl_ready && fmap_ready;

  // ---- RN ----
  // Wakeup columns: an LLT for loads, atomics and divides with a destination, a tag for MUL and
  // the bit counts (P1's MUL slot), none for 1-cycle and serialised ops. The slot after c users
  // takes the (c+1)-th free one from the bottom, all slots at once: one-hot picks from the free
  // vector with its lowest c bits cleared (timing: no slot waits for the one before)
  logic [W-1:0]                  u_llt, u_tag;
  logic [W-1:0][LLT_ENTRIES-1:0] llt_oh;
  logic [W-1:0][IQ_TAGS-1:0]     tag_oh;
  logic                          llt_short, tag_short;
  always_comb begin
    for (int k = 0; k < W; k++) begin
      u_llt[k] = rn_uop_q[k].d.rd_en && rn_valid_q[k] &&
                 (rn_uop_q[k].d.cls == C_LD || rn_uop_q[k].d.cls == C_DIV || rn_uop_q[k].d.amo ||
                  (rn_uop_q[k].d.cls == C_FP && (rn_uop_q[k].d.fp_div || rn_uop_q[k].d.fp_int)));
      u_tag[k] = rn_uop_q[k].d.rd_en && rn_valid_q[k] &&
                 (rn_uop_q[k].d.cls == C_MUL ||
                  (rn_uop_q[k].d.cls == C_FP && !rn_uop_q[k].d.fp_div && !rn_uop_q[k].d.fp_int));
    end
  end
  always_comb begin
    logic [W-1:0][LLT_ENTRIES-1:0] lf;   // the free vectors less their lowest c bits
    logic [W-1:0][IQ_TAGS-1:0]     tf;
    logic [LLT_ENTRIES-1:0]        l;
    logic [IQ_TAGS-1:0]            t;
    int cl, ct;
    l = ~llt_busy_q & ~busy[IQ_TAGS +: LLT_ENTRIES];
    t = ~tag_busy_q;
    for (int c = 0; c < W; c++) begin
      lf[c] = l;
      tf[c] = t;
      l = l & (l - 1'b1);
      t = t & (t - 1'b1);
    end
    llt_short = 1'b0;
    tag_short = 1'b0;
    cl = 0;
    ct = 0;
    for (int k = 0; k < W; k++) begin
      llt_oh[k] = '0;
      tag_oh[k] = '0;
      if (u_llt[k]) begin
        llt_oh[k] = lf[cl] & (~lf[cl] + 1'b1);
        if (lf[cl] == '0) llt_short = 1'b1;
        cl++;
      end
      if (u_tag[k]) begin
        tag_oh[k] = tf[ct] & (~tf[ct] + 1'b1);
        if (tf[ct] == '0) tag_short = 1'b1;
        ct++;
      end
    end
  end
  function automatic int oh_enc(input logic [NCOL-1:0] x);   // the set bit's index (0 if none)
    int r;
    r = 0;
    for (int t = 0; t < NCOL; t++) if (x[t]) r |= t;
    return r;
  endfunction

  // Room for n more of each counted resource, n = 0..W, from registers, so the group's needs pick
  // one at the end; the free lists' are icv / fcv (timing: no compare after the steering)
  logic [W:0] rob_room, lq_room, sq_room, div_room, fdiv_room, fpi_room;
  always_comb begin
    for (int n = 0; n <= W; n++) begin
      rob_room[n]  = rob_cnt(rtail_q, rob_head) + n <= ROB_ENTRIES;
      lq_room[n]   = lq_cnt(ltail_q, lq_head) + n <= LQ_ENTRIES;
      sq_room[n]   = sq_cnt(stail_q, sq_head) + n <= SQ_ENTRIES;
      div_room[n]  = int'(div_cnt_q) + n <= DIV_INFLIGHT;
      fdiv_room[n] = int'(fdiv_pre_q) + int'(fdiv_post_q) + n <= FDIV_INFLIGHT;
      fpi_room[n]  = int'(fpi_pre_q) + int'(fpi_post_q) + n <= FPI_INFLIGHT;
    end
  end
`ifndef SYNTHESIS
  logic          rn_ok_ref;         // the compares the flags replace (checked below)
`endif

  logic          rn_ok;             // resources available for the whole group
  logic [INT_BANKS-1:0][idx_w(W+1)-1:0] pops;
  always_comb begin
    int nrob, nld, nst, ndiv, nfdiv, nfpi, port, pref, p, b, fb;
    logic found;
    pops = '0;
    fpops = '0;
    nld = 0; nst = 0; ndiv = 0; nfdiv = 0; nfpi = 0; nrob = 0;
    port = 0; pref = 0; p = 0; b = 0; fb = 0;
    found = 1'b0;
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
            if (!found && iq_bank_free[p][k] && icv[p][idx_w(W)'(pops[p])]) begin   // fl_count[p] > pops[p]
              port = p;
              found = 1'b1;
            end
          end
        end
        C_FP:  port = EXT_FD ? Q_FP : 0;
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
        if (rn_uop_q[k].d.cls == C_FP && rn_uop_q[k].d.fp_div) nfdiv++;
        if (rn_uop_q[k].d.cls == C_FP && rn_uop_q[k].d.fp_int) nfpi++;
        nrob = k + 1;
      end
      // Sources: the maps, or the closest earlier slot that writes the register
      ren[k].src1 = rn_uop_q[k].d.rs1_en ? map_p[2*k] : '0;
      ren[k].src2 = rn_uop_q[k].d.rs2_en ? map_p[2*k+1] : '0;
      ren[k].p1   = rn_uop_q[k].d.rs1_en && !irdy[2*k];
      ren[k].p2   = rn_uop_q[k].d.rs2_en && !irdy[2*k+1];
      ren[k].w1   = map_pd[2*k].id;
      ren[k].w2   = map_pd[2*k+1].id;
      ren[k].c1   = map_pd[2*k].cv;
      ren[k].c2   = map_pd[2*k+1].cv;
      ren[k].l1   = map_pd[2*k].l1;
      ren[k].l2   = map_pd[2*k+1].l1;
      ren[k].ks1  = map_pd[2*k].ks;
      ren[k].ks2  = map_pd[2*k+1].ks;
      ren[k].old  = map_p[2*W + k];
      if (EXT_FD) begin
        // f-register sources: always a wakeup column, never MX
        if (rn_uop_q[k].d.rs1_fp) begin
          ren[k].src1 = preg_t'(fmap_p[3*k]);
          ren[k].p1   = rn_uop_q[k].d.rs1_en && !frdy[3*k];
          ren[k].w1   = pid_t'(fmap_w[3*k]);
          ren[k].c1   = 1'b1;
          ren[k].l1   = 1'b0;
        end
        if (rn_uop_q[k].d.rs2_fp) begin
          ren[k].src2 = preg_t'(fmap_p[3*k+1]);
          ren[k].p2   = rn_uop_q[k].d.rs2_en && !frdy[3*k+1];
          ren[k].w2   = pid_t'(fmap_w[3*k+1]);
          ren[k].c2   = 1'b1;
          ren[k].l2   = 1'b0;
        end
        ren[k].src3 = rn_uop_q[k].d.rs3_en ? preg_t'(fmap_p[3*k+2]) : '0;
        ren[k].p3   = rn_uop_q[k].d.rs3_en && !frdy[3*k+2];
        ren[k].w3   = pid_t'(fmap_w[3*k+2]);
        ren[k].c3   = 1'b1;
        if (rn_uop_q[k].d.rd_fp) ren[k].old = preg_t'(fmap_p[3*W + k]);
      end
      for (int i = 0; i < k; i++) begin
        if (rn_uop_q[i].d.rd_en) begin
          if (rn_uop_q[k].d.rs1_en && rn_uop_q[i].d.rd == rn_uop_q[k].d.rs1 &&
              rn_uop_q[i].d.rd_fp == rn_uop_q[k].d.rs1_fp) begin
            ren[k].src1 = ren[i].dst; ren[k].p1 = 1'b1;
            ren[k].w1 = is_lat1(rn_uop_q[i].d.cls) ? pid_t'(ren[i].rob[ROBW-2:0]) : pid_t'(ren[i].wid);
            ren[k].c1 = ren[i].use_tag || ren[i].use_llt;
            ren[k].l1 = is_lat1(rn_uop_q[i].d.cls); ren[k].ks1 = KSW'(i);
          end
          if (rn_uop_q[k].d.rs2_en && rn_uop_q[i].d.rd == rn_uop_q[k].d.rs2 &&
              rn_uop_q[i].d.rd_fp == rn_uop_q[k].d.rs2_fp) begin
            ren[k].src2 = ren[i].dst; ren[k].p2 = 1'b1;
            ren[k].w2 = is_lat1(rn_uop_q[i].d.cls) ? pid_t'(ren[i].rob[ROBW-2:0]) : pid_t'(ren[i].wid);
            ren[k].c2 = ren[i].use_tag || ren[i].use_llt;
            ren[k].l2 = is_lat1(rn_uop_q[i].d.cls); ren[k].ks2 = KSW'(i);
          end
          if (EXT_FD && rn_uop_q[k].d.rs3_en && rn_uop_q[i].d.rd_fp && rn_uop_q[i].d.rd == rn_uop_q[k].d.rs3) begin
            ren[k].src3 = ren[i].dst; ren[k].p3 = 1'b1; ren[k].w3 = pid_t'(ren[i].wid); ren[k].c3 = 1'b1;
          end
          if (rn_uop_q[i].d.rd == rn_uop_q[k].d.rd && rn_uop_q[i].d.rd_fp == rn_uop_q[k].d.rd_fp)
            ren[k].old = ren[i].dst;
        end
      end
      // Wakeup column (the picks above)
      ren[k].use_llt = u_llt[k];
      ren[k].use_tag = u_tag[k];
      ren[k].wid = '0;
      if (ren[k].use_llt) begin
        ren[k].llt = llt_t'(oh_enc(NCOL'(llt_oh[k])));
        ren[k].wid = llt_col(int'(ren[k].llt));
      end else if (rn_uop_q[k].d.cls == C_FP && (rn_uop_q[k].d.fp_div || rn_uop_q[k].d.fp_int)) begin
        ren[k].wid = llt_col(0);          // rd = x0: no LLT, but P4 expects an LLT column
      end
      if (ren[k].use_tag) ren[k].wid = wid_t'(oh_enc(NCOL'(tag_oh[k])));
      // Destination from the port's bank (atomics: the load bank, written by the LSU; FP->int
      // results: bank 1); an f register from F0 (P4) or F1 (FP loads)
      if (rn_uop_q[k].d.rd_en && rn_valid_q[k]) begin
        if (EXT_FD && rn_uop_q[k].d.rd_fp) begin
          fb = (rn_uop_q[k].d.cls == C_LD) ? FPB_F1 : FPB_F0;
          ren[k].dst = mk_fpreg(fb, ffl_pop[fb][fpops[fb]]);
          fpops[fb] = fpops[fb] + 1'b1;
        end else begin
          b = (port == Q_LD || rn_uop_q[k].d.amo) ? LD_BANK : (rn_uop_q[k].d.cls == C_FP) ? 1 : port;
          ren[k].dst = mk_preg(b, fl_pop[b][pops[b]]);
          pops[b] = pops[b] + 1'b1;
        end
      end
    end
    // Resources: the room flags above, picked by the group's needs
    rn_ok = 1'b1;
    if (!rob_room[nrob] || !lq_room[nld] || !sq_room[nst]) rn_ok = 1'b0;
    if (llt_short || tag_short) rn_ok = 1'b0;
    if (!div_room[ndiv] || !fdiv_room[nfdiv] || !fpi_room[nfpi]) rn_ok = 1'b0;
    for (int i = 0; i < 2; i++) begin
      if (fpops[i] != '0 && !fcv[i][idx_w(W)'(fpops[i] - 1'b1)]) rn_ok = 1'b0;     // fpops > ffl_count
    end
    for (int i = 0; i < INT_BANKS; i++) begin
      if (pops[i] != '0 && !icv[i][idx_w(W)'(pops[i] - 1'b1)]) rn_ok = 1'b0;       // pops > fl_count
    end
`ifndef SYNTHESIS
    rn_ok_ref = !(rob_cnt(rtail_q, rob_head) + nrob > ROB_ENTRIES || lq_cnt(ltail_q, lq_head) + nld > LQ_ENTRIES ||
                  sq_cnt(stail_q, sq_head) + nst > SQ_ENTRIES || llt_short || tag_short ||
                  int'(div_cnt_q) + ndiv > DIV_INFLIGHT || int'(fdiv_pre_q) + int'(fdiv_post_q) + nfdiv > FDIV_INFLIGHT ||
                  int'(fpi_pre_q) + int'(fpi_post_q) + nfpi > FPI_INFLIGHT);
    for (int i = 0; i < 2; i++) if (int'(fpops[i]) > int'(ffl_count[i])) rn_ok_ref = 1'b0;
    for (int i = 0; i < INT_BANKS; i++) if (int'(pops[i]) > int'(fl_count[i])) rn_ok_ref = 1'b0;
`endif
  end

  // Serialising and exception uops: alone, into an empty window; then block until the flush.
  logic rn_serial, window_empty;
  assign rn_serial    = rn_valid_q[0] && (rn_uop_q[0].d.serial || rn_uop_q[0].d.exc);
  assign window_empty = rtail_q == rob_head && !(|ds_valid_q);

  logic ds_free;
  assign rn_fire = (|rn_valid_q) && rn_ok && ds_free && !block_q && !flush && ready && start &&
                   irdy_ready && frdy_ready && (!rn_serial || window_empty);
  assign de_take = !flush && ready && (!(|rn_valid_q) || rn_fire);

  // The pops each free list takes when rename fires (the free list applies rn_fire last)
  assign ffl_pop_n[0] = fpops[0];
  assign ffl_pop_n[1] = fpops[1];
  for (genvar b = 0; b < INT_BANKS; b++) begin : g_pops
    assign fl_pop_n[b] = pops[b];
  end

  always_comb begin                  // the picks' columns (each slot's vectors are 0 unless it uses one)
    wid_alloc = '0;
    if (rn_fire) begin
      for (int k = 0; k < W; k++) begin
        wid_alloc[0 +: IQ_TAGS]           |= tag_oh[k];
        wid_alloc[IQ_TAGS +: LLT_ENTRIES] |= llt_oh[k];
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
  logic [W-1:0][RA_W-1:0]          row1, row2;   // the rows of each slot's rs1 and rs2 producers
  logic [W-1:0]                    rw_we;        // slot k's op takes its row ...
  logic [W-1:0][RA_W-1:0]          rw_a;         // ... this one
  // rowdst, the destination of the op each ALU-queue row holds: bank b is written only by slot b,
  // at its row, with its value XOR the other banks' there. Reads: every slot's source rows, then
  // the other slots' write rows (for that XOR).
  localparam int RDN = 3 * W - 1;
  logic [W-1:0][RDN-1:0][PRW-1:0]  rdst_rd;
  logic [W-1:0][PRW-1:0]           rdst1, rdst2; // rowdst at row1, row2
  for (genvar k = 0; k < W; k++) begin : g_rowa
    assign rowra[2*k]   = ds_ren_q[k].w1[ROBIW-1:0];
    assign rowra[2*k+1] = ds_ren_q[k].w2[ROBIW-1:0];
    assign row1[k]      = rowrd[ds_ren_q[k].ks1][2*k];
    assign row2[k]      = rowrd[ds_ren_q[k].ks2][2*k+1];
  end
  for (genvar b = 0; b < W; b++) begin : g_rowtab
    always_comb begin
      rw_a[b] = '0;
      for (int r = 0; r < RA; r++) if (myrow[b][r]) rw_a[b] = RA_W'(r);
    end
    assign rw_we[b] = IQ_MX && ds_fire && ds_valid_q[b] && ds_uop_q[b].d.rd_en &&
                      is_lat1(ds_uop_q[b].d.cls) && myrow[b] != '0;
    tg_ram_lut #(.DEPTH(ROB_ENTRIES), .WIDTH(RA_W), .NR(2 * W)) u_row (
      .clk, .we(rw_we[b]), .waddr(ds_ren_q[b].rob[ROBIW-1:0]), .wdata(rw_a[b]), .raddr(rowra),
      .rdata(rowrd[b]));
    logic [RDN-1:0][RA_W-1:0] dra;
    for (genvar k = 0; k < W; k++) begin : g_dra
      assign dra[2*k]   = row1[k];
      assign dra[2*k+1] = row2[k];
    end
    for (genvar o = 0; o < W; o++) begin : g_dro
      if (o != b) begin : g_o
        assign dra[2*W + (o < b ? o : o - 1)] = rw_a[o];
      end
    end
    logic [PRW-1:0] dwd;
    always_comb begin
      dwd = ds_ren_q[b].dst;
      for (int o = 0; o < W; o++)
        if (o != b) dwd ^= rdst_rd[o][2*W + (b < o ? b : b - 1)];
    end
    tg_ram_lut #(.DEPTH(RA), .WIDTH(PRW), .NR(RDN)) u_rdst (
      .clk, .we(rw_we[b]), .waddr(rw_a[b]), .wdata(dwd), .raddr(dra), .rdata(rdst_rd[b]));
  end
  always_comb begin
    for (int k = 0; k < W; k++) begin
      rdst1[k] = '0;
      rdst2[k] = '0;
      for (int b = 0; b < W; b++) begin
        rdst1[k] ^= rdst_rd[b][2*k];
        rdst2[k] ^= rdst_rd[b][2*k+1];
      end
    end
  end
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
        if (ds_ren_q[k].p1 && ds_ren_q[k].l1 && int'(row1[k]) < RA && mx_hold[row1[k]] &&
            rdst1[k] == ds_ren_q[k].src1)
          mrow1[k][row1[k]] = 1'b1;
        if (ds_ren_q[k].p2 && ds_ren_q[k].l2 && int'(row2[k]) < RA && mx_hold[row2[k]] &&
            rdst2[k] == ds_ren_q[k].src2)
          mrow2[k][row2[k]] = 1'b1;
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
      if (EXT_FD && ds_ren_q[k].p3 && ds_ren_q[k].c3) iq_dep[k][wid_t'(ds_ren_q[k].w3)] = 1'b1;
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
      iq_pl[k].src3      = ds_ren_q[k].src3;
      iq_pl[k].src1_fp   = ds_uop_q[k].d.rs1_fp;
      iq_pl[k].dst_fp    = ds_uop_q[k].d.rd_fp;
      iq_pl[k].fop       = ds_uop_q[k].d.fop;
      iq_pl[k].fmt       = ds_uop_q[k].d.fmt;
      iq_pl[k].src_fmt   = ds_uop_q[k].d.src_fmt;
      iq_pl[k].ifmt      = ds_uop_q[k].d.ifmt;
      iq_pl[k].rm        = ds_uop_q[k].d.rm;
      iq_pl[k].fp_int    = ds_uop_q[k].d.fp_int;
      iq_pl[k].fp_div    = ds_uop_q[k].d.fp_div;
    end
  end

  // ---- Commit: committed map, free-list pushes and commit heads ----
  always_comb begin
    fl_push_v = '0;
    fl_push_idx = '0;
    fl_cmt_n = '0;
    ffl_push_v = '0;
    ffl_push_idx = '0;
    ffl_cmt_n = '0;
    for (int j = 0; j < COMMIT_WIDTH; j++) begin
      if (cm_valid[j] && cm_rd_en[j] && !(EXT_FD && cm_rd_fp[j])) begin
        fl_push_v[preg_bank(cm_old[j])][j]   = 1'b1;
        fl_push_idx[preg_bank(cm_old[j])][j] = preg_idx(cm_old[j]);
        fl_cmt_n[preg_bank(cm_dst[j])]       = fl_cmt_n[preg_bank(cm_dst[j])] + 1'b1;
      end
      if (EXT_FD && cm_valid[j] && cm_rd_en[j] && cm_rd_fp[j]) begin
        ffl_push_v[fpreg_bank(cm_old[j])][j]   = 1'b1;
        ffl_push_idx[fpreg_bank(cm_old[j])][j] = fpreg_idx(cm_old[j]);
        ffl_cmt_n[fpreg_bank(cm_dst[j])]       = ffl_cmt_n[fpreg_bank(cm_dst[j])] + 1'b1;
      end
    end
  end

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    if (rst) begin
      fdiv_pre_q <= '0;
      fdiv_post_q <= '0;
      fpi_pre_q  <= '0;
      fpi_post_q <= '0;
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
      llt_busy_q <= llt_busy_q & ~llt_rel;
      fdiv_post_q <= fdiv_post_q + (idx_w(FDIV_INFLIGHT + 1))'(fdiv_iss) - (idx_w(FDIV_INFLIGHT + 1))'(fdiv_done);
      fpi_post_q  <= fpi_post_q + (idx_w(FPI_INFLIGHT + 1))'(fpi_iss) - (idx_w(FPI_INFLIGHT + 1))'(fpi_pop);
      tag_busy_q <= tag_busy_q & ~tag_free;
      if (div_done && div_cnt_q != '0) div_cnt_q <= div_cnt_q - 1'b1;

      if (flush) begin
        llt_busy_q <= '0;
        tag_busy_q <= '0;               // every tagged producer in flight is squashed
        rtail_q    <= rob_head;
        ltail_q    <= lq_head;
        stail_q    <= sq_cmt;
        div_cnt_q  <= '0;
        fdiv_pre_q <= '0;                // not yet issued: gone with the flush
        fpi_pre_q  <= '0;
        block_q    <= 1'b0;
        rn_valid_q <= '0;
        ds_valid_q <= '0;
      end else begin
        // FP divides and FP->int ops renamed this cycle, and those issued
        fdiv_pre_q <= fdiv_pre_q + (idx_w(FDIV_INFLIGHT + 1))'(rn_fire ? ren_nfp(rn_uop_q, rn_valid_q, 1'b1) : 0)
                      - (idx_w(FDIV_INFLIGHT + 1))'(fdiv_iss);
        fpi_pre_q  <= fpi_pre_q + (idx_w(FPI_INFLIGHT + 1))'(rn_fire ? ren_nfp(rn_uop_q, rn_valid_q, 1'b0) : 0)
                      - (idx_w(FPI_INFLIGHT + 1))'(fpi_iss);
        // DS
        if (ds_fire) ds_valid_q <= '0;
        // RN -> DS
        if (rn_fire) begin
          ds_valid_q <= rn_valid_q;
          rn_valid_q <= '0;
          for (int k = 0; k < W; k++) begin
            if (rn_valid_q[k]) begin
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

  // The DS payload takes RN's group whenever DS is free, so its enable does not wait for
  // rn_fire (a load of every DS flip-flop); ds_valid_q says whether RN fired, and nothing reads
  // the payload of an invalid slot
  always_ff @(posedge clk) begin
    if (ds_free) begin
      ds_uop_q <= rn_uop_q;
      ds_ren_q <= ren;
    end
  end

  function automatic int ren_nld(input uop_t [W-1:0] u, input logic [W-1:0] v);
    int n;
    n = 0;
    for (int k = 0; k < W; k++) if (v[k] && u[k].d.cls == C_LD) n++;
    return n;
  endfunction
  // FP divides (dv = 1) or FP->int ops (dv = 0) in a group
  function automatic int ren_nfp(input uop_t [W-1:0] u, input logic [W-1:0] v, input logic dv);
    int n;
    n = 0;
    for (int k = 0; k < W; k++)
      if (v[k] && u[k].d.cls == C_FP && (dv ? u[k].d.fp_div : u[k].d.fp_int)) n++;
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
  // A group is a prefix of valid slots. Only allocated LLTs are released (a flush frees them
  // all, and a release registered from that cycle may follow).
  logic flush_d;
  always_ff @(posedge clk) flush_d <= flush;
  always_ff @(posedge clk) begin
    if (!rst) begin
      assert ((llt_rel & ~llt_busy_q) == '0 || flush || flush_d)
        else $error("tg_rename: an LLT released while free");
      for (int k = 1; k < W; k++)
        assert (!rn_valid_q[k] || rn_valid_q[k-1]) else $error("tg_rename: group is not a prefix");
      assert ((tag_free & ~tag_busy_q) == '0 || flush) else $error("tg_rename: a free tag returned");
    end
  end
  // The resource check's flags give what the compares gave
  always_ff @(posedge clk) begin
    if (!rst) assert (rn_ok == rn_ok_ref) else $error("tg_rename: the resource flags differ from the compares");
  end
  // The parallel picks give what the in-order loop gave: each slot the first free column left
  // by the slots before it
  always_ff @(posedge clk) begin
    logic [LLT_ENTRIES-1:0] lfr;
    logic [IQ_TAGS-1:0]     tfr;
    logic                   ls, ts, got;
    int                     li, ti;
    if (!rst) begin
      lfr = ~llt_busy_q & ~busy[IQ_TAGS +: LLT_ENTRIES];
      tfr = ~tag_busy_q;
      ls = 1'b0;
      ts = 1'b0;
      for (int k = 0; k < W; k++) begin
        if (u_llt[k]) begin
          got = 1'b0; li = 0;
          for (int t = 0; t < LLT_ENTRIES; t++)
            if (!got && lfr[t]) begin got = 1'b1; lfr[t] = 1'b0; li = t; end
          if (!got) ls = 1'b1;
          assert (llt_oh[k] == (got ? LLT_ENTRIES'(1) << li : '0)) else $error("tg_rename: slot %0d's LLT pick", k);
        end
        if (u_tag[k]) begin
          got = 1'b0; ti = 0;
          for (int t = 0; t < IQ_TAGS; t++)
            if (!got && tfr[t]) begin got = 1'b1; tfr[t] = 1'b0; ti = t; end
          if (!got) ts = 1'b1;
          assert (tag_oh[k] == (got ? IQ_TAGS'(1) << ti : '0)) else $error("tg_rename: slot %0d's tag pick", k);
        end
      end
      assert (ls == llt_short && ts == tag_short) else $error("tg_rename: the picks' shortage flags");
    end
  end
`endif
endmodule
