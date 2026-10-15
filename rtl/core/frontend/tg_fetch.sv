// Front end for M2 (docs/spec/core-pipeline.md §3): fetch PC and micro-BTB (F1), I$ data,
// tags and pre-decode (F2), compaction into the instruction queue (F3), and the l1i refill.
//
// F1: fpc_q is the block being fetched. The micro-BTB (tg_ubtb) predicts the next block; the
//     I$ tags are read (LUTRAM) and the data arrays are addressed with fpc_q.
// F2: tag compare, way select, pre-decode (tg_predecode over the whole block). The micro-BTB
//     prediction is checked against the pre-decode marks: an exit slot that is not the last
//     parcel of a branch or jump is dropped (the block continues sequentially, the next block
//     is refetched, and the entry is invalidated). A miss parks fetch; the refill restarts it.
//     F2's actions on F1 (park on a miss, refetch, stop after a fault block) are registered: they
//     take effect a cycle later and drop the blocks F1 and F2 took meanwhile. A miss's refill and
//     an ITLB miss's walk start from the registered decision, as early as before.
// F3: tg_fetch_compact (spike S5) writes whole instructions into the queue.
// One l1i Get is outstanding at a time (the plan's 4 MSHRs and prefetch are M6). A fetch from
// a PC above PA_W or outside PMA_MEM/PMA_ROM, or a denied refill, produces a one-instruction
// fault block; fetch then stops until a redirect.
// M3 (core-mmu.md): in S and U with satp.MODE = Sv39, F1 translates fpc_q through the ITLB
// (the I$ is indexed by page-offset bits and tagged with the PA). An ITLB miss parks fetch in
// F2 and asks the walker; its end restarts fetch, and a walk fault turns the page's blocks
// into fault blocks (cause 12, or 1 for a PTE access fault). PMP is checked per 4-byte word:
// an instruction touching a denied word is a fault block at the entry, else the block ends
// before it and fetch resumes there.
module tg_fetch
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_core_pkg::*;
#(
  localparam int WAYS  = L1_WAYS,
  localparam int SETS  = (L1I_KIB * 1024) / (WAYS * 64),
  localparam int SET_W = idx_w(SETS),
  localparam int WAY_W = idx_w(WAYS),
  localparam int TAG_W = PA_W - 12,
  localparam int ROWS  = SETS * 4,                  // 16-byte rows per way
  localparam int ROW_W = idx_w(ROWS),
  localparam int TKW   = idx_w(DECODE_WIDTH + 1)
) (
  input  logic        clk,
  input  logic        rst,
  input  logic [63:0] boot_pc,
  output logic        ready,          // reset sequence done
  // Redirects, registered upstream: flush (commit) has priority over dred (decode)
  input  logic        flush,
  input  logic [63:0] flush_pc,
  input  logic        icinv,          // FENCE.I, together with flush
  input  logic        dred,
  input  logic [63:0] dred_pc,
  // Micro-BTB training from execute
  input  logic        upd_valid,
  input  logic        upd_way,
  input  logic [63:0] upd_pc,
  input  logic [SLOT_W-1:0] upd_slot,
  input  logic [63:0] upd_target,
  input  logic        upd_inval,
  // Instruction queue to decode
  output logic [DECODE_WIDTH-1:0]   iq_valid,
  output fe_insn_t [DECODE_WIDTH-1:0] iq_insn,
  input  logic [TKW-1:0]            iq_take,
  // Translation and PMP (M3)
  input  logic        xl_i,           // fetch translates: S or U, satp.MODE = Sv39
  input  priv_e       priv,
  input  pmp_d_t [15:0]     pmp_d,
  input  logic        pmp_busy,       // PMP descriptors being recomputed: F1 waits
  input  logic        tlb_flush,
  input  logic        it_fill,
  input  logic [26:0] it_fill_vpn,
  input  logic [1:0]  it_fill_lvl,
  input  tlb_pte_t    it_fill_pte,
  output logic        iw_req,         // a walk for iw_va, held until iw_ack
  output logic [63:0] iw_va,
  input  logic        iw_ack,
  input  logic        iw_done,        // a fetch walk ended
  input  logic        iw_ok,
  input  logic [3:0]  iw_cause,
  // l1i
  output tl_a_t       l1i_a_o,
  output logic        l1i_a_valid_o,
  input  logic        l1i_a_ready_i,
  input  tl_d_t       l1i_d_i,
  input  logic        l1i_d_valid_i,
  output logic        l1i_d_ready_o
);
  // ---- Block metadata carried through the instruction queue ----
  typedef struct packed {
    logic [63:4]       base;     // block address
    logic              hit;      // predicted taken at slot `slot`
    logic              way;
    logic [SLOT_W-1:0] slot;
    logic [63:0]       target;
    logic              fault;
    logic              fpf;      // page fault (else access)
    logic              fhi;      // on the entry instruction's second half
  } meta_t;
  localparam int META_W = $bits(meta_t);
  localparam int IB_W   = 32 + 1 + SLOT_W + 3 + META_W;

  // ---- Reset sequence: invalidate the micro-BTB (2 ways x its sets) ----
  localparam int UB_SETS = UBTB_ENTRIES / 2;
  localparam int INIT_N  = 2 * UB_SETS;
  logic [idx_w(INIT_N + 1)-1:0] init_q;
  assign ready = init_q == (idx_w(INIT_N + 1))'(INIT_N);
  always_ff @(posedge clk) begin
    if (rst) init_q <= '0;
    else if (!ready) init_q <= init_q + 1'b1;
  end

  localparam int NW = NP / 2;     // 4-byte words per block (PMP granules)

  // ---- F1 state ----
  logic        f1_valid_q;        // fpc_q names a block to fetch
  logic [63:0] fpc_q;
  logic        stop_q;            // after a fault block, until a redirect
  logic        carry_q;           // the last block left half a 32-bit instruction for the next one
  logic        wk_q, wk_sent_q;   // parked on an ITLB miss; the walk was taken

  // Micro-BTB
  logic              ub_hit, ub_way;
  logic [38:1]       ub_tgt;
  logic [SLOT_W-1:0] ub_slot;
  logic              u_valid, u_way, u_inval;
  logic [38:4]       u_pc;
  logic [38:1]       u_tgt;
  logic [SLOT_W-1:0] u_slot;
  logic              f2_inval;        // F2 drops a bogus prediction
  logic [38:4]       f2_inval_pc;
  logic              f2_inval_way;
  always_comb begin
    u_valid = 1'b0; u_way = 1'b0; u_inval = 1'b0; u_pc = '0; u_tgt = '0; u_slot = '0;
    if (!ready) begin
      u_valid = 1'b1; u_inval = 1'b1; u_way = init_q[0];
      u_pc = 35'(init_q[idx_w(INIT_N + 1)-1:1]);
    end else if (upd_valid) begin
      u_valid = 1'b1; u_way = upd_way; u_inval = upd_inval; u_pc = upd_pc[38:4];
      u_tgt = upd_target[38:1]; u_slot = upd_slot;
    end else if (f2_inval) begin
      u_valid = 1'b1; u_way = f2_inval_way; u_inval = 1'b1; u_pc = f2_inval_pc;
    end
  end
  tg_ubtb #(.FA(1'b0), .NE(UBTB_ENTRIES)) u_ubtb (
    .clk, .rst, .pc(fpc_q[38:4]), .tid('0), .hit(ub_hit), .target(ub_tgt), .br_slot(ub_slot),
    .hit_way(ub_way), .upd_valid(u_valid), .upd_way(u_way), .upd_pc(u_pc), .upd_tid('0),
    .upd_target(u_tgt), .upd_slot(u_slot), .upd_inval(u_inval));

  // A prediction whose slot lies before the entry point cannot apply to this fetch.
  logic pred_hit;
  assign pred_hit = ub_hit && ub_slot >= fpc_q[SLOT_W:1];
  logic [63:0] pred_tgt, seq_pc;
  assign pred_tgt = {{25{ub_tgt[38]}}, ub_tgt, 1'b0};
  assign seq_pc   = {fpc_q[63:4] + 60'd1, 4'b0};

  // ---- Translation and fetchability of fpc_q ----
  logic [0:0][26:0] it_vpn;
  logic [0:0]       it_hit;
  tlb_pte_t [0:0]   it_pte;
  assign it_vpn[0] = fpc_q[38:12];
  tg_tlb #(.NE(ITLB_ENTRIES), .NR(1)) u_itlb (
    .clk, .rst, .vpn(it_vpn), .hit(it_hit), .pte(it_pte), .fill(it_fill),
    .fill_vpn(it_fill_vpn), .fill_lvl(it_fill_lvl),
    .fill_pte(it_fill_pte), .flush(tlb_flush));
  logic [PA_W-1:0] f1_pa;
  assign f1_pa = xl_i ? {it_pte[0].ppn, fpc_q[11:0]} : fpc_q[PA_W-1:0];
  // A walk for this page faulted: its blocks are fault blocks until a redirect
  logic         xf_v_q, xf_pf_q;
  logic [63:12] xf_page_q;
  logic f1_xf, f1_pf, f1_tm, f1_acc, f1_fault, f1_fpf;
  pma_e f1_pma;
  assign f1_xf    = xl_i && xf_v_q && fpc_q[63:12] == xf_page_q;
  assign f1_pf    = xl_i && !va_canon(fpc_q);
  assign f1_tm    = xl_i && !f1_pf && !f1_xf && !(it_hit[0] && pte_ok(it_pte[0], ACC_X, priv, 1'b0, 1'b0));
  assign f1_pma   = pma_of(f1_pa);
  assign f1_acc   = (xl_i ? it_pte[0].big : fpc_q[63:PA_W] != '0) ||
                    (f1_pma != PMA_MEM && f1_pma != PMA_ROM);
  assign f1_fault = f1_pf || f1_xf || (!f1_tm && f1_acc);     // the whole block
  assign f1_fpf   = f1_pf || (f1_xf && xf_pf_q);
  // PMP per word (used in F2, where instruction boundaries are known)
  // A translated page that is PMP-homogeneous uses the ITLB's cached result (plan §4.10);
  // otherwise one block checker: in bare mode on fpc_q itself, and on a translated page with a
  // region boundary inside on the address the ITLB gave a cycle earlier: F1 waits that cycle
  // (pw_q), so the ITLB and the checker are never in one cycle.
  logic [NW-1:0]      f1_pmpd, pmp_okw;
  logic               pmp_hit_u;
  logic [2:0]         pmp_rwx_u;
  logic               pw_q, f1_pwait;
  logic [PA_W-1:4]    pw_pa_q;                // fpc_q's translated block address, while pw_q
  assign f1_pwait = xl_i && it_hit[0] && !it_pte[0].ph && !pw_q;
  tg_pmp #(.S(2)) u_pmp (.pa(xl_i ? {pw_pa_q, 4'b0} : fpc_q[PA_W-1:0]), .dbl(1'b0), .acc(ACC_X),
                         .m_mode(priv == PRIV_M), .d(pmp_d), .ok(pmp_okw), .hit(pmp_hit_u),
                         .rwx(pmp_rwx_u));
  assign f1_pmpd = (xl_i && it_pte[0].ph) ? {NW{!it_pte[0].px}} : ~pmp_okw;

  // ---- I$ arrays ----
  logic                rf_we;
  logic [WAY_W-1:0]    rf_way;
  logic [ROW_W-1:0]    rf_row;
  logic [127:0]        rf_data;
  logic                tag_we;
  logic [SET_W-1:0]    tag_set;
  logic [TAG_W-1:0]    tag_wd;

  logic                f2_go;            // F1 moves into F2 this cycle
  logic [WAYS-1:0][127:0] way_data;      // F2: data of the block read in F1
  logic [WAYS-1:0][TAG_W-1:0] tag_rd;    // F1
  for (genvar w = 0; w < WAYS; w++) begin : g_way
    tg_ram_sdp #(.DEPTH(ROWS), .WIDTH(128), .OUT_REG(1'b0), .PRIM("block")) u_data (
      .clk, .we(rf_we && rf_way == WAY_W'(w)), .waddr(rf_row), .wdata(rf_data),
      .re(f2_go), .raddr(fpc_q[4 +: ROW_W]), .rdata(way_data[w]));
    logic [0:0][SET_W-1:0] ra;
    logic [0:0][TAG_W-1:0] rd;
    assign ra[0] = fpc_q[6 +: SET_W];
    tg_ram_lut #(.DEPTH(SETS), .WIDTH(TAG_W), .NR(1)) u_tag (
      .clk, .we(tag_we && rf_way == WAY_W'(w)), .waddr(tag_set), .wdata(tag_wd), .raddr(ra),
      .rdata(rd));
    assign tag_rd[w] = rd[0];
  end

  // ---- F2 state ----
  logic              f2_valid_q, f2_fault_q, f2_hit_q, f2_way_q, f2_fpf_q, f2_tm_q;
  logic [63:0]       f2_pc_q, f2_tgt_q;
  logic [PA_W-1:0]   f2_pa_q;
  logic [NW-1:0]     f2_pmpd_q;
  logic [SLOT_W-1:0] f2_slot_q;
  logic [WAYS-1:0]   f2_wv_q;                 // valid bits of the set, read in F1
  logic [WAYS-1:0][TAG_W-1:0] f2_tag_q;
  // F2's action on its block, registered (ka_q): park on an I$ miss (k_miss_q) or an ITLB miss
  // (k_walk_q), stop after a fault block (k_stop_q), else refetch: at the PMP cut (k_cut_q, fp_q),
  // the next block after a dropped prediction (k_ovr_q), or the block itself (its line was
  // installed meanwhile). The blocks F2 and F1 hold in that cycle came after it: dropped.
  logic              ka_q, k_miss_q, k_walk_q, k_stop_q, k_cut_q, k_ovr_q;
  logic [SLOT_W-1:0] fp_q;
  logic              f2v;                     // F2 holds a block it has not acted on
  assign f2v = f2_valid_q && !ka_q;

  logic [WAYS-1:0] way_hit;
  logic [127:0]    blk;
  for (genvar w = 0; w < WAYS; w++) begin : g_cmp
    assign way_hit[w] = f2_wv_q[w] && f2_tag_q[w] == f2_pa_q[12 +: TAG_W];
  end
  always_comb begin
    blk = '0;
    for (int w = 0; w < WAYS; w++) blk |= {128{way_hit[w]}} & way_data[w];
  end

  // Refill / fault state
  logic        miss_q;             // fetch is parked on miss_pc_q (I$ miss)
  logic [63:0] miss_pc_q;
  logic [PA_W-1:0] miss_pa_q;
  logic        fline_v_q;          // the last refill of this line was denied
  logic [PA_W-1:6] fline_q;
  logic        f2_cache_hit, f2_bfault, f2_isfault, f2_miss, f2_wmiss;
  assign f2_bfault    = f2_fault_q || (!f2_tm_q && fline_v_q && f2_pa_q[PA_W-1:6] == fline_q);
  assign f2_cache_hit = |way_hit;
  assign f2_wmiss     = f2v && f2_tm_q && !f2_bfault;
  assign f2_miss      = f2v && !f2_tm_q && !f2_bfault && !f2_cache_hit;

  // Pre-decode over the whole block, from the entry point. It reads the block as fetched: for a
  // fault block (f2_bfault) every result below is overridden or unused (the block is one
  // pseudo-instruction, its parcels and marks registered as zero), so the fault check, which
  // compares the whole line address, does not wait in front of it.
  logic [NP-1:0][15:0] parcel;
  logic [NP-1:0] pd_start, pd_is32, pd_br, pd_jal, pd_jalr, pd_call, pd_ret;
  logic          pd_carry;
  assign parcel = blk;
  tg_predecode u_pd (
    .parcel, .entry_slot(f2_pc_q[SLOT_W:1]), .exit_slot(SLOT_W'(NP - 1)), .carry_in(carry_q),
    .start(pd_start), .is32(pd_is32), .is_br(pd_br), .is_jal(pd_jal), .is_jalr(pd_jalr),
    .is_call(pd_call), .is_ret(pd_ret), .carry_out(pd_carry));

  // Check the prediction: the predicted exit slot must be the last parcel of a branch or jump
  logic pred_ok;
  always_comb begin
    pred_ok = 1'b0;
    for (int p = 0; p < NP; p++) begin
      if (pd_start[p] && (pd_br[p] || pd_jal[p] || pd_jalr[p]) &&
          SLOT_W'(pd_is32[p] ? p + 1 : p) == f2_slot_q && (!pd_is32[p] || p + 1 < NP))
        pred_ok = 1'b1;
    end
  end
  // PMP inside the block: the first instruction from the entry, up to the predicted exit, that
  // touches a denied word. At the entry the block is a fault block; later, the block ends
  // before it and fetch resumes there (its own block then faults at the entry).
  logic [SLOT_W-1:0] pexit, fp;
  logic              pmp_e, pmp_hi, pmp_cut, fp_v;
  logic [NP-1:0]     dslot;
  for (genvar p = 0; p < NP; p++) begin : g_ds
    assign dslot[p] = f2_pmpd_q[p / 2];
  end
  assign pexit = (f2_hit_q && pred_ok) ? f2_slot_q : SLOT_W'(NP - 1);
  always_comb begin
    fp_v = 1'b0;
    fp = '0;
    for (int p = NP - 1; p >= 0; p--) begin
      if (pd_start[p] && SLOT_W'(p) <= pexit &&
          (dslot[p] || (pd_is32[p] && p + 1 < NP && dslot[(p + 1) % NP]))) begin
        fp_v = 1'b1;
        fp = SLOT_W'(p);
      end
    end
    pmp_e = 1'b0;
    pmp_hi = 1'b0;
    pmp_cut = 1'b0;
    if (f2v && !f2_tm_q && !f2_bfault && f2_cache_hit) begin
      if (carry_q && f2_pc_q[SLOT_W:1] == '0 && dslot[0]) begin
        pmp_e = 1'b1;                              // the carried instruction's second half
      end else if (fp_v) begin
        if (fp == f2_pc_q[SLOT_W:1]) begin
          pmp_e  = 1'b1;
          pmp_hi = !dslot[fp];
        end else begin
          pmp_cut = 1'b1;
        end
      end
    end
  end
  assign f2_isfault = f2_bfault || pmp_e;

  logic              f2_taken;            // the block ends at f2_slot_q and fetch went to f2_tgt_q
  logic [SLOT_W-1:0] f2_exit;
  assign f2_taken = f2_hit_q && pred_ok && !f2_isfault && !pmp_cut;
  assign f2_exit  = pmp_cut ? fp - 1'b1 : f2_taken ? f2_slot_q : SLOT_W'(NP - 1);

  logic [NP-1:0]      blk_start;
  logic [NP-1:0][2:0] blk_marks;
  logic               blk_carry;
  always_comb begin
    for (int p = 0; p < NP; p++) begin
      blk_start[p] = pd_start[p] && SLOT_W'(p) <= f2_exit;
      blk_marks[p] = {pd_br[p], pd_jal[p], pd_jalr[p]};
    end
    blk_carry = pd_carry && !f2_taken && !pmp_cut;
    if (f2_isfault) begin                          // one pseudo-instruction at the entry slot
      blk_start = '0;
      blk_start[f2_pc_q[SLOT_W:1]] = 1'b1;
      blk_carry = 1'b0;
    end
  end

  // ---- F3: compaction ----
  logic                 f3_valid_q, f3_carry_q;
  logic [NP-1:0][15:0]  f3_parcel_q;
  logic [NP-1:0]        f3_start_q;
  logic [NP-1:0][2:0]   f3_marks_q;
  meta_t                f3_meta_q;
  logic                 blk_ready;
  logic                 f3_accept;
  assign f3_accept = !f3_valid_q || blk_ready;

  logic [DECODE_WIDTH-1:0]           cq_valid;
  logic [DECODE_WIDTH-1:0][IB_W-1:0] cq_insn;
  logic                              redirect;
  assign redirect = flush || dred;
  tg_fetch_compact #(.WR(4), .RD(DECODE_WIDTH), .DEPTH(IBUF_ENTRIES), .META_W(META_W)) u_cmp (
    .clk, .rst, .flush(redirect), .blk_valid(f3_valid_q), .parcel(f3_parcel_q),
    .start(f3_start_q), .marks(f3_marks_q), .carry_out(f3_carry_q), .meta(f3_meta_q),
    .blk_ready, .out_valid(cq_valid), .out_insn(cq_insn), .take(iq_take));

  // ---- Pipeline control ----
  // F2 delivers when it is valid, not missing, and F3 can take the block. It holds while F3
  // cannot, missing or not: its action is registered anyway.
  logic f2_deliver, f2_hold;
  assign f2_deliver = f2v && !f2_miss && !f2_wmiss && f3_accept;
  assign f2_hold    = f2v && !f3_accept;
  // F1 moves on when F2 is free (or delivers) and fetch is not parked, stopped or waiting for the
  // PMP descriptors, the valid-bit sweep or its own PMP check (f1_pwait).
  logic f1_base, f1_live, ivs_done;
  assign f1_base = f1_valid_q && !miss_q && !wk_q && !stop_q && ready && !pmp_busy && ivs_done;
  assign f1_live = f1_base && !f1_pwait;
  assign f2_go   = !f2_hold && !redirect;
  logic f2_override;                     // F2 drops the prediction: refetch the next block
  assign f2_override = f2_deliver && f2_hit_q && !pred_ok && !f2_isfault;
  logic am_go, aw_go;                    // F2's miss or ITLB miss of last cycle parks fetch now
  assign am_go  = ka_q && k_miss_q;
  assign aw_go  = ka_q && k_walk_q;
  assign iw_req = (wk_q && !wk_sent_q) || aw_go;
  assign iw_va  = miss_pc_q;
  // The micro-BTB entry of a dropped prediction is invalidated a cycle later
  logic        ainv_q, ainv_way_q;
  logic [38:4] ainv_pc_q;
  always_ff @(posedge clk) begin
    if (rst) ainv_q <= 1'b0;
    else     ainv_q <= f2_override;
    ainv_pc_q  <= f2_pc_q[38:4];
    ainv_way_q <= f2_way_q;
  end
  assign f2_inval     = ainv_q;
  assign f2_inval_pc  = ainv_pc_q;
  assign f2_inval_way = ainv_way_q;

  // ---- Refill engine (one Get at a time) ----
  typedef enum logic [1:0] { R_IDLE, R_REQ, R_DATA } rstate_e;
  rstate_e          rs_q;
  logic [PA_W-1:6]  rline_q;
  logic [1:0]       rbeat_q;
  logic             rden_q, rpoison_q;
  logic [WAY_W-1:0] rway_q;
  logic [WAY_W-1:0] rr_q;               // round-robin victim pointer
  logic             refill_done;        // last beat accepted this cycle
  logic             rdone_d_q;          // ... in the previous cycle
  logic [PA_W-1:6]  rline_d_q;

  // Valid bits: a LUTRAM row of WAYS bits per set (plan §8.3: no flip-flop arrays). Reads: the
  // set F1 fetches, and the missed set (victim choice when the refill starts; the refill's
  // read-modify-write when it ends). After reset and FENCE.I a sweep clears every set while
  // F1 waits.
  // The refill rewrites the victim's rows beat by beat and may outlive a redirect, so the
  // victim's valid bit is cleared when the refill starts: its old line misses from the next
  // cycle on (a read in the start cycle still gets the old data: no beat is written yet), and
  // F1 reads in the install cycle are refetched (rdone_d_q).
  logic [1:0][SET_W-1:0] iv_ra;
  logic [1:0][WAYS-1:0]  iv_rd;
  logic                  iv_we;
  logic [SET_W-1:0]      iv_wa;
  logic [WAYS-1:0]       iv_wd;
  logic [SET_W:0]        ivs_q;             // sweep: the next set to clear; done at SETS
  logic                  r_start;           // the refill of miss_pa_q's line starts
  assign ivs_done = ivs_q[SET_W];
  assign r_start  = rs_q == R_IDLE && (miss_q || am_go) && !rst;
  assign iv_ra[0] = fpc_q[6 +: SET_W];
  assign iv_ra[1] = (rs_q == R_IDLE) ? miss_pa_q[6 +: SET_W] : rline_q[6 +: SET_W];
  tg_ram_lut #(.DEPTH(SETS), .WIDTH(WAYS), .NR(2)) u_ival (
    .clk, .we(iv_we), .waddr(iv_wa), .wdata(iv_wd), .raddr(iv_ra), .rdata(iv_rd));

  // victim: first invalid way of the set, else round robin
  logic [WAY_W-1:0] victim;
  always_comb begin
    logic found;
    found = 1'b0;
    victim = rr_q;
    for (int w = 0; w < WAYS; w++) begin
      if (!found && !iv_rd[1][w]) begin
        victim = WAY_W'(w);
        found = 1'b1;
      end
    end
  end

  always_comb begin
    iv_we = tag_we;
    iv_wa = tag_set;
    iv_wd = iv_rd[1] | (WAYS'(1) << rway_q);
    if (r_start) begin                      // (never with tag_we: that is the refill's end)
      iv_we = 1'b1;
      iv_wa = miss_pa_q[6 +: SET_W];
      iv_wd = iv_rd[1] & ~(WAYS'(1) << victim);
    end
    if (!ivs_done) begin
      iv_we = 1'b1;
      iv_wa = ivs_q[SET_W-1:0];
      iv_wd = '0;
    end
  end

  always_comb begin
    l1i_a_o = '0;
    l1i_a_o.opcode  = A_GET;
    l1i_a_o.size    = 3'd6;
    l1i_a_o.source  = '0;
    l1i_a_o.address = {rline_q, 6'b0};
    l1i_a_o.mask    = '1;
    l1i_a_valid_o   = rs_q == R_REQ;
    l1i_d_ready_o   = 1'b1;
  end
  assign rf_we   = rs_q == R_DATA && l1i_d_valid_i;
  assign rf_way  = rway_q;
  assign rf_row  = {rline_q[6 +: SET_W], rbeat_q};
  assign rf_data = l1i_d_i.data;
  assign refill_done = rf_we && rbeat_q == 2'd3;
  logic rf_bad;
  assign rf_bad  = rden_q || l1i_d_i.denied || l1i_d_i.corrupt;
  assign tag_we  = refill_done && !rf_bad && !rpoison_q && !icinv;
  assign tag_set = rline_q[6 +: SET_W];
  assign tag_wd  = rline_q[PA_W-1:12];

  always_ff @(posedge clk) begin
    if (rst) begin
      rs_q      <= R_IDLE;
      rr_q      <= '0;
      fline_v_q <= 1'b0;
    end else begin
      unique case (rs_q)
        R_IDLE: if (miss_q || am_go) begin
          rs_q      <= R_REQ;
          rline_q   <= miss_pa_q[PA_W-1:6];
          rway_q    <= victim;
          rr_q      <= rr_q + 1'b1;
          rbeat_q   <= '0;
          rden_q    <= 1'b0;
          rpoison_q <= 1'b0;
        end
        R_REQ: if (l1i_a_ready_i) rs_q <= R_DATA;
        R_DATA: if (l1i_d_valid_i) begin
          rbeat_q <= rbeat_q + 1'b1;
          if (l1i_d_i.denied || l1i_d_i.corrupt) rden_q <= 1'b1;
          if (rbeat_q == 2'd3) begin
            rs_q <= R_IDLE;
            if (rf_bad) begin
              fline_v_q <= 1'b1;
              fline_q   <= rline_q;
            end else if (fline_v_q && fline_q == rline_q) begin
              fline_v_q <= 1'b0;
            end
          end
        end
        default: rs_q <= R_IDLE;
      endcase
      if (icinv && rs_q != R_IDLE) rpoison_q <= 1'b1;
      if (flush) fline_v_q <= 1'b0;   // a later fetch of the line tries again
    end
  end

  always_ff @(posedge clk) begin
    if (rst || icinv)  ivs_q <= '0;
    else if (!ivs_done) ivs_q <= ivs_q + 1'b1;
    rdone_d_q <= tag_we && !rst;
    rline_d_q <= rline_q;
  end

  // ---- Sequential: F1, F2, F3 ----
  always_ff @(posedge clk) begin
    if (rst) begin
      f1_valid_q <= 1'b1;
      fpc_q      <= boot_pc;
      pw_q       <= 1'b0;
      stop_q     <= 1'b0;
      miss_q     <= 1'b0;
      wk_q       <= 1'b0;
      wk_sent_q  <= 1'b0;
      xf_v_q     <= 1'b0;
      carry_q    <= 1'b0;
      f2_valid_q <= 1'b0;
      f3_valid_q <= 1'b0;
      ka_q       <= 1'b0;
    end else if (redirect) begin
      f1_valid_q <= 1'b1;
      fpc_q      <= flush ? flush_pc : dred_pc;
      pw_q       <= 1'b0;
      stop_q     <= 1'b0;
      miss_q     <= 1'b0;
      wk_q       <= 1'b0;
      wk_sent_q  <= 1'b0;
      xf_v_q     <= 1'b0;
      carry_q    <= 1'b0;
      f2_valid_q <= 1'b0;
      f3_valid_q <= 1'b0;
      ka_q       <= 1'b0;
    end else begin
      // F1 waits a cycle for its PMP check; any change of fpc_q below ends the wait
      if (f1_base && f1_pwait) begin
        pw_q    <= 1'b1;
        pw_pa_q <= f1_pa[PA_W-1:4];
      end
      // F3: the data registers take whatever block F2 offers; only the valid bit waits for its hit
      if (f3_accept) f3_valid_q <= 1'b0;
      if (f2v && f3_accept) begin
        f3_parcel_q <= f2_isfault ? '0 : parcel;
        f3_start_q  <= blk_start;
        f3_marks_q  <= f2_bfault ? '0 : blk_marks;
        f3_carry_q  <= blk_carry;
        f3_meta_q   <= '{base: f2_pc_q[63:4], hit: f2_taken, way: f2_way_q, slot: f2_slot_q,
                         target: f2_tgt_q, fault: f2_isfault, fpf: f2_bfault && f2_fpf_q,
                         fhi: !f2_bfault && pmp_hi};
      end
      if (f2_deliver) begin
        f3_valid_q  <= 1'b1;
        carry_q     <= blk_carry;
        if (f2_isfault) stop_q <= 1'b1;
      end
      // F2 <- F1, unless F2 acted last cycle
      if (ka_q) begin
        f2_valid_q <= 1'b0;
        if (k_miss_q) begin
          // Park on the missed block; the refill restarts fetch there (carry_q is kept).
          miss_q     <= 1'b1;
          f1_valid_q <= 1'b0;
        end else if (k_walk_q) begin
          // ITLB miss: park and walk; the walk's end restarts fetch here
          wk_q       <= 1'b1;
          wk_sent_q  <= 1'b0;
          f1_valid_q <= 1'b0;
        end else if (!k_stop_q) begin
          // Refetch: a later instruction touches a PMP-denied word (fetched as its own block); the
          // prediction was dropped (the next block); or the line was installed while F2 missed it
          // (the block again, rather than refilling it twice)
          f1_valid_q <= 1'b1;
          fpc_q      <= k_cut_q ? {miss_pc_q[63:4], fp_q, 1'b0}
                      : k_ovr_q ? {miss_pc_q[63:4] + 60'd1, 4'b0} : miss_pc_q;
          pw_q       <= 1'b0;
        end
      end else if (f2_go) begin
        f2_valid_q <= f1_live;
        f2_pc_q    <= fpc_q;
        f2_pa_q    <= f1_pa;
        f2_fault_q <= f1_fault;
        f2_fpf_q   <= f1_fpf;
        f2_tm_q    <= f1_tm;
        f2_pmpd_q  <= f1_pmpd;
        f2_hit_q   <= pred_hit;
        f2_way_q   <= ub_way;
        f2_slot_q  <= ub_slot;
        f2_tgt_q   <= pred_tgt;
        f2_tag_q   <= tag_rd;
        f2_wv_q    <= iv_rd[0];
        if (f1_live) begin
          fpc_q <= (pred_hit && !f1_fault) ? pred_tgt : seq_pc;
          pw_q  <= 1'b0;
        end
      end
      // F2's action on this cycle's block, taken next cycle; miss_pc_q and miss_pa_q name the block
      ka_q     <= f2_miss || f2_wmiss || (f2_deliver && (pmp_cut || f2_override || f2_isfault));
      k_miss_q <= f2_miss && !((refill_done && f2_pa_q[PA_W-1:6] == rline_q) ||
                               (rdone_d_q && f2_pa_q[PA_W-1:6] == rline_d_q));
      k_walk_q <= f2_wmiss;
      k_stop_q <= f2_deliver && f2_isfault;
      k_cut_q  <= pmp_cut;
      k_ovr_q  <= f2_override;
      fp_q     <= fp;
      if (f2v) begin
        miss_pc_q <= f2_pc_q;
        miss_pa_q <= f2_pa_q;
      end
      // Restart after the refill (F2 holds nothing then; a registered miss parks in this cycle)
      if ((miss_q || am_go) && refill_done) begin
        miss_q     <= 1'b0;
        f1_valid_q <= 1'b1;
        fpc_q      <= miss_pc_q;
        pw_q       <= 1'b0;
      end
      // Restart after the walk (a fault: the page's blocks fault until a redirect)
      if ((wk_q || aw_go) && iw_ack) wk_sent_q <= 1'b1;
      if (wk_q && wk_sent_q && iw_done) begin
        wk_q       <= 1'b0;
        f1_valid_q <= 1'b1;
        fpc_q      <= miss_pc_q;
        pw_q       <= 1'b0;
        if (!iw_ok) begin
          xf_v_q    <= 1'b1;
          xf_pf_q   <= iw_cause == EXC_IPAGE;
          xf_page_q <= miss_pc_q[63:12];
        end
      end
    end
  end

  // ---- Instruction queue output ----
  for (genvar j = 0; j < DECODE_WIDTH; j++) begin : g_out
    logic [15:0]       lo, hi;
    logic              rvc;
    logic [SLOT_W-1:0] slot;
    logic [2:0]        marks;
    meta_t             m;
    assign {m, marks, slot, rvc, hi, lo} = cq_insn[j];
    logic              strad;
    logic [SLOT_W:0]   first, last;     // parcel range, straddler from -1 (encoded as first = 0, strad)
    assign strad = slot == SLOT_W'(NP - 1) && !rvc;
    logic [63:0] pc;
    // pc[3:0] needs no carry; only a straddler's block address is decremented
    assign pc   = strad ? {m.base - 1'b1, 4'hE} : {m.base, slot, 1'b0};
    assign first = (SLOT_W + 1)'(slot);
    assign last  = strad ? '0 : (rvc ? first : first + 1'b1);
    logic exit_here;
    assign exit_here = m.hit && (strad ? m.slot == '0
                                       : ((SLOT_W + 1)'(m.slot) >= first && (SLOT_W + 1)'(m.slot) <= last));
    assign iq_valid[j] = cq_valid[j];
    always_comb begin
      iq_insn[j]             = '0;
      iq_insn[j].pc          = pc;
      iq_insn[j].blk         = m.base;
      iq_insn[j].strad       = strad;
      iq_insn[j].insn        = rvc ? {16'b0, lo} : {hi, lo};
      iq_insn[j].rvc         = rvc;
      iq_insn[j].fault       = m.fault;
      iq_insn[j].fault_pf    = m.fpf;
      iq_insn[j].fault_hi    = m.fault && (strad || m.fhi);
      iq_insn[j].pred_taken  = exit_here;
      iq_insn[j].pred_target = m.target;
      iq_insn[j].pred_bogus  = 1'b0;
      iq_insn[j].ubtb_hit    = exit_here;
      iq_insn[j].ubtb_way    = m.way;
      iq_insn[j].tid         = '0;
      iq_insn[j].marks       = marks;
    end
  end

  logic unused;
  assign unused = ^{upd_pc[63:39], upd_pc[3:0], upd_target[63:39], upd_target[0], pd_call, pd_ret, l1i_d_i.opcode, l1i_d_i.param, l1i_d_i.size,
                    l1i_d_i.source, l1i_d_i.sink, rf_we && 1'b0, miss_pa_q[5:0], pmp_hit_u, pmp_rwx_u};

`ifndef SYNTHESIS
  // No F2 hit on the way being refilled from a row the refill had already rewritten when F1
  // read it (the old line's tag over the new line's bytes; soc track's report, 2026-10-14)
  logic            stale_q;
  logic [WAY_W-1:0] stale_way_q;
  always_ff @(posedge clk) begin
    if (f2_go) begin
      stale_q     <= rs_q == R_DATA && fpc_q[6 +: SET_W] == rline_q[6 +: SET_W] &&
                     (fpc_q[5:4] < rbeat_q || (fpc_q[5:4] == rbeat_q && rf_we));
      stale_way_q <= rway_q;
    end
    if (!rst && f2v && stale_q)
      assert (!way_hit[stale_way_q]) else $error("tg_fetch: I$ hit on a row the refill rewrote");
  end
  always_ff @(posedge clk) begin
    if (!rst && f2v && !f2_isfault) assert ($onehot0(way_hit)) else $error("tg_fetch: multiple way hits");
    if (!rst && (miss_q || am_go || wk_q)) assert (!f2v) else $error("tg_fetch: F2 holds a block while fetch is parked");
  end
`endif
endmodule
