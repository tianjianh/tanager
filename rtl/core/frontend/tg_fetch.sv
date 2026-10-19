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
  input  logic [FTQW-1:0]   dred_ftq,   // TAGE_ON: dred's instruction's FTQ entry and last slot,
  input  logic [SLOT_W-1:0] dred_slot,
  input  logic [1:0]        dred_rop,   // ... its own stack operation and link (RAS_FE)
  input  logic [38:1]       dred_rlink,
  // TAGE (TAGE_ON) from commit, in slot order: the conditional branches it trains on (their outcome,
  // fetch-time direction, FTQ entry and slot), and the youngest retiring instruction's FTQ entry
  input  logic [COMMIT_WIDTH-1:0]             c_cbr,
  input  logic [COMMIT_WIDTH-1:0]             c_taken,
  input  logic [COMMIT_WIDTH-1:0]             c_pred,
  input  logic [COMMIT_WIDTH-1:0][FTQW-1:0]   c_ftq,
  input  logic [COMMIT_WIDTH-1:0][SLOT_W-1:0] c_slot,
  input  logic                                c_hv,
  input  logic [FTQW-1:0]                     c_hftq,
  // The return-address stack's speculative side (RAS_FE): its top, pointer and count; each delivered
  // block's exit's operation; the repair at decode's redirect (the pointer, count and top before the
  // redirecting block, from its FTQ entry)
  input  logic                ras_v,
  input  logic [38:1]         ras_top,
  input  logic [RAS_PW-1:0]   ras_tos,
  input  logic [RAS_PW:0]     ras_cnt,
  output logic                ras_push,
  output logic                ras_pop,
  output logic [38:1]         ras_link,
  output logic                ras_rv,
  output logic                ras_rwr,
  output logic [RAS_PW-1:0]   ras_rtos,
  output logic [RAS_PW:0]     ras_rcnt,
  output logic [38:1]         ras_rtop,
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
  input  dec_state_t  dst,            // decode's state, for the queue's decode bits
  input  priv_e       priv,
  input  pmp_d_t [PMP_ENTRIES-1:0] pmp_d,
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
    logic              tsrc;     // ... to the instruction's own target, F2's refetch (TAGE_ON), not `target`
    logic              uhit;     // the micro-BTB's prediction (its training): taken at `uslot`
    logic [SLOT_W-1:0] uslot;
    logic [FTQW-1:0]   ftq;      // the block's FTQ entry (TAGE_ON)
    logic              fault;
    logic              fpf;      // page fault (else access)
    logic              fhi;      // on the entry instruction's second half
  } meta_t;
  localparam int META_W = $bits(meta_t);
  localparam int IB_W   = (QUEUE_DECODE ? 3 : 0) + 32 + 1 + SLOT_W + 3 + META_W;   // tg_fetch_compact's entry

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
  logic [15:0] sp_q;              // ... that half (TAGE_ON: F2 predicts the straddler with the next block)
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
    .clk, .rst, .vpn(it_vpn), .vpn_e('0), .hit(it_hit), .pte(it_pte), .fill(it_fill),
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
  logic [WAYS-1:0]   f2_wh_q;                 // the ways that hit, compared in F1 (below)
  logic [WAY_W-1:0]  f2_hw_q;                 // ... the hit way's index: the data select
  // F2's action on its block, registered (ka_q): park on an I$ miss (k_miss_q) or an ITLB miss
  // (k_walk_q), stop after a fault block (k_stop_q), else refetch: at the PMP cut (k_cut_q, fp_q),
  // the next block after a dropped prediction (k_ovr_q), or the block itself (its line was
  // installed meanwhile). The blocks F2 and F1 hold in that cycle came after it: dropped.
  logic              ka_q, k_miss_q, k_walk_q, k_stop_q, k_cut_q, k_ovr_q;
  // TAGE_ON: the override refetches at the exit's target (kt_q): the block's address, the exit's
  // parcel (kp_q) and its offset (kimm_q), added in the action's cycle
  logic              kt_q;
  logic              kr_q;                // RAS_FE: ... at the stack's top, krt_q
  logic              ks_q;                // TAGE_ON: ... the exit is a straddler (PC: the block - 2)
  logic [63:0]       krt_q;
  logic [SLOT_W-1:0] kp_q;
  logic [20:0]       kimm_q;
  logic [63:0]       kt_tgt;
  logic [SLOT_W-1:0] fp_q;
  logic              f2v;                     // F2 holds a block it has not acted on
  assign f2v = f2_valid_q && !ka_q;

  logic [WAYS-1:0] way_hit;
  logic [127:0]    blk;
  // The block from the hit way's index: one multiplexer per bit on an encoded select (two LUT6
  // and a MUXF7 for 8 ways) rather than an AND-OR over the one-hot hits. At most one way hits
  // (asserted below); a block delivered without a hit is a fault block, whose parcels and
  // pre-decode results are not used, and a missed block is never delivered.
  // The tags are compared in F1 and the hits registered (timing: in F2 the compare, the select's
  // encoding and its fanout led the pre-decode and the prediction, one chain): F2's select is a
  // register. F1 compares what F2 did, the set's tags and valid bits as F1 reads them and fpc_q's
  // PA, so the hits are the same.
  assign way_hit = f2_wh_q;
  assign blk     = way_data[f2_hw_q];

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
  logic [NP-1:0] pd_start, pd_is32, pd_br, pd_jal, pd_jalr, pd_call, pd_ret, pd_pop;
  logic          pd_carry;
  assign parcel = blk;
  tg_predecode u_pd (
    .parcel, .entry_slot(f2_pc_q[SLOT_W:1]), .exit_slot(SLOT_W'(NP - 1)), .carry_in(carry_q),
    .start(pd_start), .is32(pd_is32), .is_br(pd_br), .is_jal(pd_jal), .is_jalr(pd_jalr),
    .is_call(pd_call), .is_ret(pd_ret), .is_pop(pd_pop), .carry_out(pd_carry));

`ifndef SYNTHESIS
  // The pre-decoder's boundaries (a parallel prefix) against the walk over the parcels
  always_ff @(posedge clk) begin
    if (!rst && f2v) begin
      logic sw;
      sw = 1'b0;
      for (int p = 0; p < NP; p++) begin
        if (SLOT_W'(p) == f2_pc_q[SLOT_W:1]) sw = !(carry_q && f2_pc_q[SLOT_W:1] == '0);
        else if (p > 0)                     sw = !(sw && parcel[p-1][1:0] == 2'b11);
        if (SLOT_W'(p) >= f2_pc_q[SLOT_W:1])
          assert (pd_start[p] == sw) else $error("tg_fetch: pre-decode's boundary at %0d differs from the walk's", p);
      end
    end
  end
`endif
  // Check the prediction: the predicted exit slot must be the last parcel of a branch or jump.
  // Where an instruction starts, it is 32-bit exactly when its parcel's low bits are 11 (wide),
  // so the terms read wide, not the pre-decoder's is32 (start && wide), and only the final AND
  // with the start waits for the start chain; likewise pq below.
  logic [NP-1:0] wide;
  for (genvar p = 0; p < NP; p++) begin : g_wide
    assign wide[p] = parcel[p][1:0] == 2'b11;
  end
  logic pred_ok;
  always_comb begin
    pred_ok = 1'b0;
    for (int p = 0; p < NP; p++) begin
      if (pd_start[p] && (pd_br[p] || pd_jal[p] || pd_jalr[p]) &&
          SLOT_W'(wide[p] ? p + 1 : p) == f2_slot_q && (!wide[p] || p + 1 < NP))
        pred_ok = 1'b1;
    end
  end
  // PMP inside the block: the first instruction from the entry, up to the predicted exit, that
  // touches a denied word. At the entry the block is a fault block; later, the block ends
  // before it and fetch resumes there (its own block then faults at the entry).
  // The decisions use the per-parcel vector pq, not that instruction's encoded slot: no
  // instruction starts before the entry (pd_start), so it is at the entry exactly when
  // pq[entry] is set, and the parcels before it are those with no pq at or below them (a
  // prefix OR). Only the refetch slot (fp_q) waits for the encoding.
  // They are formed for both outcomes of the prediction check (hp: the predicted exit stands,
  // which limits pq to the parcels up to it) and hp picks last, so the check runs beside them.
  // The fault decisions at the entry need no pick: a prediction stands only on a micro-BTB hit,
  // whose exit slot is at or after the entry (pred_hit), so pq is the same there either way.
  logic [SLOT_W-1:0] fp, f2_ent;
  logic              pmp_hi, pmp_cut, f2_chk, f2_carried, hp;
  logic [NP-1:0]     dslot;
  for (genvar p = 0; p < NP; p++) begin : g_ds
    assign dslot[p] = f2_pmpd_q[p / 2];
  end
  assign f2_ent     = f2_pc_q[SLOT_W:1];
  assign f2_chk     = f2v && !f2_tm_q && !f2_bfault && f2_cache_hit;
  assign f2_carried = carry_q && f2_ent == '0 && dslot[0];   // the carried instruction's second half
  assign hp         = f2_hit_q && pred_ok;

  logic              f2_taken;            // the block ends taken at its exit (fx_slot)
  logic [NP-1:0]      blk_start;
  logic [NP-1:0][2:0] blk_marks;
  logic               blk_carry;
  // The block's final prediction and what follows from it (both forms below):
  logic               f2_isf0;            // the entry's fault decision (the override waits for it)
  logic [SLOT_W-1:0]  fx_slot;            // the taken exit's last parcel
  logic               fx_tsrc;            // ... F2 refetches at the instruction's own target (TAGE_ON)
  logic               f2_ovr;             // the prediction differs from what F1 followed: refetch,
  logic               f2_ka;              // F2 acts on a delivered block: a cut, a fault or a refetch
  logic               ovr_tk;             // ... at the exit's target (the exit's first parcel ovr_p)
  logic [SLOT_W-1:0]  ovr_p;              //     or else at the next block
  logic               uok;                // the micro-BTB's prediction is a real exit
  logic [63:0]        fx_tgt;             // the exit's target in the queue (a JALR's)
  logic               ovr_ras;            // RAS_FE: ... the exit is a return to the stack's top
  logic               ovr_s;              // TAGE_ON: ... the exit is a straddler (its PC: the block - 2)
  logic [20:0]        ovr_imm;            // ... the exit's offset
  logic               f2_rpush, f2_rpop;  // RAS_FE: the exit's stack operation, and a push's link
  logic [38:1]        f2_rlink;
  assign uok = hp;
  logic [1:0]         gh_n, gh_b;         // TAGE_ON: the history bits the block adds (count, values)
  logic [NP-1:0]      gh_cm, gh_pk;       // ... its conditional branches' slots and directions
  logic [NP-1:0]      tdir;               // ... TAGE's direction per slot
  if (!TAGE_ON) begin : g_f2u
    // ---- The micro-BTB alone: the prediction stands or is dropped (the next block) ----
    logic [1:0][NP-1:0] pq_h, bs_h;
    logic [1:0]         pe_h, phi_h, pcut_h, isf_h, tk_h, bc_h;
    for (genvar h = 0; h < 2; h++) begin : g_hp
      always_comb begin
        logic          run;
        logic [NP-1:0] pq_run;                 // an instruction at or before p touches a denied word
        run = 1'b0;
        for (int p = 0; p < NP; p++) begin
          pq_h[h][p] = pd_start[p] && (h == 0 || SLOT_W'(p) <= f2_slot_q) &&
                       (dslot[p] || (wide[p] && p + 1 < NP && dslot[(p + 1) % NP]));
          run = run || pq_h[h][p];
          pq_run[p] = run;
        end
        pe_h[h]   = f2_chk && (f2_carried || pq_h[h][f2_ent]);
        phi_h[h]  = f2_chk && !f2_carried && pq_h[h][f2_ent] && !dslot[f2_ent];
        pcut_h[h] = f2_chk && !f2_carried && |pq_h[h] && !pq_h[h][f2_ent];
        isf_h[h]  = f2_bfault || pe_h[h];
        tk_h[h]   = h == 1 && !isf_h[h] && !pcut_h[h];
        // The block's instructions: those before a PMP cut, else up to a taken exit, else all of
        // them; a fault block is one pseudo-instruction at the entry slot
        for (int p = 0; p < NP; p++)
          bs_h[h][p] = pd_start[p] && (pcut_h[h] ? !pq_run[p] : (!tk_h[h] || SLOT_W'(p) <= f2_slot_q));
        bc_h[h] = pd_carry && !tk_h[h] && !pcut_h[h];
        if (isf_h[h]) begin
          bs_h[h] = '0;
          bs_h[h][f2_ent] = 1'b1;
          bc_h[h] = 1'b0;
        end
      end
    end
    assign pmp_hi     = phi_h[0];
    assign pmp_cut    = pcut_h[hp];
    assign f2_isfault = isf_h[0];
    assign f2_taken   = tk_h[hp];
    assign blk_start  = bs_h[hp];
    assign blk_carry  = bc_h[hp];
    // The refetch slot: pq's first parcel, encoded for both outcomes, hp picking last
    logic [1:0][SLOT_W-1:0] fp_h;
    always_comb begin
      for (int h = 0; h < 2; h++) begin
        fp_h[h] = '0;
        for (int p = NP - 1; p >= 0; p--) if (pq_h[h][p]) fp_h[h] = SLOT_W'(p);
      end
      fp = fp_h[hp];
      for (int p = 0; p < NP; p++) blk_marks[p] = {pd_br[p], pd_jal[p], pd_jalr[p]};
    end
  `ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (!rst && f2v && f2_hit_q)
        assert (f2_slot_q >= f2_ent) else $error("tg_fetch: a micro-BTB hit's exit slot before the entry");
      if (!rst && f2v && hp)
        assert (isf_h[1] == isf_h[0] && phi_h[1] == phi_h[0])
          else $error("tg_fetch: the entry's fault decision depends on the prediction");
    end
  `endif
    assign f2_isf0 = isf_h[0];
    assign fx_slot = f2_slot_q;
    assign fx_tsrc = 1'b0;
    assign f2_ovr  = f2_hit_q && !pred_ok;
    assign f2_ka   = pmp_cut || (f2_ovr && !f2_isf0) || f2_isfault;
    assign ovr_tk  = 1'b0;
    assign ovr_p   = '0;
    assign gh_n    = '0;
    assign gh_b    = '0;
    assign gh_cm   = '0;
    assign gh_pk   = '0;
    assign fx_tgt  = f2_tgt_q;
    assign ovr_ras = 1'b0;
    assign ovr_s   = 1'b0;
    assign ovr_imm = '0;
    logic unused_sp;
    assign unused_sp = ^sp_q;
    assign f2_rpush = 1'b0;
    assign f2_rpop  = 1'b0;
    assign f2_rlink = '0;
    logic unused_tdir;
    assign unused_tdir = ^{tdir, pd_pop};
  end else begin : g_f2t
    // ---- TAGE's decision (TAGE_ON) ----
    // Each instruction that starts at parcel p (at or after the entry) has its last parcel's slot
    // (lsl), the key of the micro-BTB and of TAGE. A 32-bit one at the last parcel straddles out
    // and is not predicted here (decode checks it, as before). Candidates for the exit: a JAL; a
    // JALR the micro-BTB predicts here (its target); a conditional branch TAGE predicts taken. The
    // exit is the first candidate, unless the block's third conditional branch comes first: the
    // block then ends before it (a cut, refetched there), so a block adds at most two history bits.
    // The decision is formed flat, as one-hot vectors (timing: a walk over the parcels chained the
    // pre-decode, the search, the PMP cut, the block's parcels and the history in one path, about
    // 40 levels in the full chip): per parcel, whether anything was decided before it (ns: a
    // candidate, or a third branch), from prefix ORs and counts; the exit (feh) or the cut (c3h)
    // where that first meets a candidate; and from those the block's limit (lim), its parcels and
    // its history bits. The entry's fault decisions do not wait for the exit: the denied
    // instruction at the entry is one whatever the exit (den_e). A simulation-only copy of the walk
    // (g_ref, below) checks every output against this form.
    logic [NP-1:0][SLOT_W-1:0] lsl;
    logic [NP-1:0]             outp, cbr, rp, tkn;
    // A return the stack predicts (RAS_FE: a pop while the stack is not empty) is a candidate too,
    // to the stack's top; a JALR otherwise only where the micro-BTB predicts it
    logic [63:0]   rtgt;
    assign rtgt = {{25{ras_top[38]}}, ras_top, 1'b0};
    // A 32-bit instruction that straddles in from the previous block (its first half in sp_q) is the
    // block's first instruction, its last parcel at slot 0: decoded here from its halves, it is a
    // candidate like the others (a branch with TAGE's slot 0), the exit fe_s
    logic        sv, fe_s;
    logic [31:0] sx;
    logic        sx_br, sx_jal, sx_jalr, sx_call, sx_pop, sx_tk;
    assign sv = carry_q && f2_ent == '0;
    assign sx = {parcel[0], sp_q};
    always_comb begin
      logic [4:0] rd, rs1;
      logic       rdl, rsl;
      rd  = sx[11:7];
      rs1 = sx[19:15];
      rdl = rd == 5'd1 || rd == 5'd5;
      rsl = rs1 == 5'd1 || rs1 == 5'd5;
      sx_br   = sv && sx[6:0] == 7'b1100011;
      sx_jal  = sv && sx[6:0] == 7'b1101111;
      sx_jalr = sv && sx[6:0] == 7'b1100111;
      sx_call = (sx_jal || sx_jalr) && rdl;
      sx_pop  = sx_jalr && rsl && !(rdl && rd == rs1);
      // (the micro-BTB never takes a straddler: no parcel of its block starts at slot 0, so its
      // prediction there is no real exit and uok is false; only the stack takes a straddling JALR.
      // It is never trained on one either: a hit at slot 0 here is another block's entry, through
      // the partial tag, and F1 followed its target: decode checks it, fx_tsrc below)
      sx_tk   = (sx_br && tdir[0]) || sx_jal || (sx_jalr && RAS_FE && sx_pop && ras_v);
    end
    assign fe_s = sx_tk;
    for (genvar p = 0; p < NP; p++) begin : g_cand
      assign outp[p] = wide[p] && p == NP - 1;
      assign lsl[p]  = SLOT_W'(wide[p] ? p + 1 : p);
      assign cbr[p]  = pd_start[p] && pd_br[p] && !outp[p];
      assign rp[p]   = RAS_FE && pd_pop[p] && ras_v;
      // A JALR at the micro-BTB's exit slot is a real exit by itself (pred_ok holds there), so the
      // candidate does not wait for uok, the whole block's check
      logic hs;
      assign hs = f2_hit_q && (wide[p] ? f2_slot_q == SLOT_W'(p + 1) : f2_slot_q == SLOT_W'(p));
      assign tkn[p]  = (pd_start[p] && !outp[p] && (pd_jal[p] || (pd_jalr[p] && (rp[p] || hs)))) ||
                       (cbr[p] && (wide[p] ? tdir[(p + 1) % NP] : tdir[p]));
    end
    // ns[p]: nothing decided before p: no candidate there (tb) and no third conditional branch (at
    // least three before p, the straddler counted); the cut at the third (c3h: two before it), else
    // the exit at the first candidate (feh). lim[p]: p is in the block, up to the exit's last
    // parcel or before the cut (a prefix of the parcels)
    logic [NP-1:0] ns, feh, c3h, lim;
    always_comb begin
      for (int p = 0; p < NP; p++) begin
        logic a1, a2, a3, t;
        a1 = sx_br;
        a2 = 1'b0;
        a3 = 1'b0;
        t  = 1'b0;
        for (int q = 0; q < p; q++) begin
          a3 = a3 || (a2 && cbr[q]);
          a2 = a2 || (a1 && cbr[q]);
          a1 = a1 || cbr[q];
          t  = t || tkn[q];
        end
        ns[p]  = !sx_tk && !t && !a3;
        c3h[p] = ns[p] && cbr[p] && a2;
        feh[p] = ns[p] && tkn[p] && !(cbr[p] && a2);
        lim[p] = (ns[p] && !c3h[p]) || (p > 0 && feh[(p + NP - 1) % NP] && wide[(p + NP - 1) % NP]);
      end
    end
    logic              fe_v, c3_v;
    logic [SLOT_W-1:0] fe_p, c3_p;
    assign fe_v = |feh;
    assign c3_v = |c3h;
    always_comb begin
      fe_p = '0;
      c3_p = '0;
      for (int p = 0; p < NP; p++) begin
        if (feh[p]) fe_p |= SLOT_W'(p);
        if (c3h[p]) c3_p |= SLOT_W'(p);
      end
    end
    // PMP inside the block: den[p], the instruction starting at p touches a denied word; dr[p], one
    // at or before p does. The walk's pq is lim & den. At the entry it is den_e whatever the exit
    // (the entry's instruction starts there unless it is a straddler's second half), so the entry's
    // decisions are early. A later one cuts the block when it lies within lim; then the block's
    // parcels are those before it (~dr), and the refetch is at it (fd_p)
    logic [NP-1:0]     den, dr, cutm;
    logic              den_e, pe, phi, pcut, ccut, isf, tk;
    logic [SLOT_W-1:0] fd_p;
    always_comb begin
      logic run;
      run  = 1'b0;
      fd_p = '0;
      for (int p = 0; p < NP; p++) begin
        den[p] = pd_start[p] && (dslot[p] || (wide[p] && p + 1 < NP && dslot[(p + 1) % NP]));
        run    = run || den[p];
        dr[p]  = run;
      end
      for (int p = NP - 1; p >= 0; p--) if (den[p]) fd_p = SLOT_W'(p);
    end
    assign den_e = !sv && (dslot[f2_ent] || (wide[f2_ent] && f2_ent != SLOT_W'(NP - 1) && dslot[f2_ent + 1'b1]));
    assign pe    = f2_chk && (f2_carried || den_e);
    assign phi   = f2_chk && !f2_carried && den_e && !dslot[f2_ent];
    assign pcut  = f2_chk && !f2_carried && !den_e && |(lim & den);
    assign ccut  = f2_chk && c3_v && !pe;
    assign isf   = f2_bfault || pe;
    assign tk    = (fe_s || fe_v) && !isf && !pcut;
    assign cutm  = (f2_chk && !f2_carried && !den_e) ? dr : '0;
    logic [NP-1:0] bs;
    logic          bc;
    always_comb begin
      for (int p = 0; p < NP; p++)
        bs[p] = isf ? SLOT_W'(p) == f2_ent : pd_start[p] && (lim[p] || (c3_v && !f2_chk)) && !cutm[p];
      bc = !isf && pd_carry && !fe_s && !fe_v && !(c3_v && f2_chk) && !cutm[NP-1];
    end
    assign pmp_hi     = phi;
    assign pmp_cut    = pcut || ccut;                // either cut refetches at fp
    assign f2_isfault = isf;
    assign f2_isf0    = isf;
    assign f2_taken   = tk;
    assign blk_start  = bs;
    assign blk_carry  = bc;
    always_comb begin
      fp = pcut ? fd_p : c3_p;
      for (int p = 0; p < NP; p++) blk_marks[p] = {pd_br[p], pd_jal[p], pd_jalr[p]};
    end
    // The exit's slot, kind and target (without an exit: the walk's default, the first parcel's)
    logic xjalr, xras, xcall, xpop, xcbr, sm;
    logic [3:0] xoff;                              // the exit's link, in halfwords from the block
    always_comb begin
      xjalr   = 1'b0;
      xras    = 1'b0;
      xcall   = 1'b0;
      xpop    = 1'b0;
      xcbr    = 1'b0;
      sm      = 1'b0;
      fx_slot = '0;
      xoff    = '0;
      for (int p = 0; p < NP; p++)
        if (feh[p]) begin
          xjalr   = xjalr || pd_jalr[p];
          xras    = xras  || rp[p];
          xcall   = xcall || pd_call[p];
          xpop    = xpop  || pd_pop[p];
          xcbr    = xcbr  || cbr[p];
          sm      = sm    || lsl[p] == f2_slot_q;
          fx_slot = fx_slot | lsl[p];
          xoff    = xoff  | (4'(p) + (wide[p] ? 4'd2 : 4'd1));
        end
      if (fe_s) begin
        xjalr   = sx_jalr;
        xras    = RAS_FE && sx_pop && ras_v;
        xcall   = sx_call;
        xpop    = sx_pop;
        xcbr    = sx_br;
        sm      = f2_slot_q == '0;
        fx_slot = '0;
        xoff    = 4'd1;
      end else if (!fe_v) begin
        fx_slot = lsl[0];
        xoff    = wide[0] ? 4'd2 : 4'd1;
      end
    end
    // F1 followed the micro-BTB (its target on f2_hit_q, else the next block). They differ when the
    // exit is at another slot than the micro-BTB's, or there is none against its hit; at the same slot
    // the micro-BTB's target is taken as right (decode checks it). Faults and cuts refetch on their own
    // (a return the stack predicts: also when the micro-BTB's target is not the stack's top).
    // A JAL or branch exit goes to its own target only through F2's refetch (fx_tsrc: decode need not
    // check it). At the micro-BTB's slot the next block is the micro-BTB's target, which the queue
    // carries for decode's check: an entry of another block (the partial tag aliases blocks 2 MiB
    // apart, a straddler's slot 0 included) or a JAL changed since it trained gives a wrong one.
    assign fx_tsrc = tk && !xjalr && !(f2_hit_q && sm);
    // f2_ka, F2's action without the delivery: its terms absorb f2_ovr's gates (timing)
    logic fe_ras, xovr;
    assign fe_ras  = tk && xras;
    assign xovr    = (fe_s || fe_v) ? !(f2_hit_q && sm && (!xras || f2_tgt_q == rtgt)) : f2_hit_q;
    assign f2_ovr  = !isf && !pcut && !ccut && xovr;
    assign f2_ka   = pcut || ccut || isf || xovr;
    assign ovr_tk  = tk;
    assign ovr_p   = fe_p;
    assign ovr_s   = fe_s;
    // the exit's offset, for the refetch at its target
    always_comb begin
      logic [NP-1:0][20:0] im;
      for (int p = 0; p < NP; p++) im[p] = br_imm({parcel[(p + 1) % NP], parcel[p]}, pd_jal[p]);
      ovr_imm = im[0];
      if (fe_v) begin
        ovr_imm = '0;
        for (int p = 0; p < NP; p++) if (feh[p]) ovr_imm = ovr_imm | im[p];
      end
      if (fe_s) ovr_imm = br_imm(sx, sx_jal);
    end
    assign ovr_ras = fe_ras;
    assign fx_tgt  = fe_ras ? rtgt : f2_tgt_q;
    // The stack's operation at the block's exit (made as the block is delivered, below): a call's
    // push of its link, a return's pop (the commit side does the same, ras_op)
    assign f2_rpush = RAS_FE && tk && xcall;
    assign f2_rpop  = RAS_FE && tk && xpop;
    // (the link: the block's halfword address plus xoff, 1 to 8; a straddler's: its PC, the block - 2, + 4)
    logic [38:4] pc_n;
    assign pc_n     = f2_pc_q[38:4] + 35'd1;
    assign f2_rlink = xoff[3] ? {pc_n, 3'b000} : {f2_pc_q[38:4], xoff[2:0]};
    // History: the block's conditional branches up to its exit or cut, as predicted (newest in bit 0).
    // Only the exit can be taken, and it is the last branch counted, so the older bit is never set
    always_comb begin
      logic [NP-1:0] bcb;
      logic          sb, n1, n2;
      sb  = !isf && sx_br;
      bcb = '0;
      for (int p = 0; p < NP; p++) bcb[p] = !isf && bs[p] && cbr[p];
      n1 = sb;
      n2 = 1'b0;
      for (int p = 0; p < NP; p++) begin
        n2 = n2 || (n1 && bcb[p]);
        n1 = n1 || bcb[p];
      end
      gh_n  = n2 ? 2'd2 : n1 ? 2'd1 : 2'd0;
      gh_b  = {1'b0, tk && xcbr};
      gh_cm = '0;
      gh_pk = '0;
      gh_cm[0] = sb;
      gh_pk[0] = sb && tk && fe_s;
      for (int p = 0; p < NP; p++)
        if (bcb[p]) begin
          gh_cm[lsl[p]] = 1'b1;
          if (tk && feh[p]) gh_pk[lsl[p]] = 1'b1;
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (!rst && f2v && f2_hit_q)
        assert (f2_slot_q >= f2_ent) else $error("tg_fetch: a micro-BTB hit's exit slot before the entry");
      if (!rst && f2v && fe_v)
        assert (fe_p >= f2_ent) else $error("tg_fetch: the exit before the entry");
      if (!rst && f2v)
        assert ($onehot0(feh | c3h)) else $error("tg_fetch: more than one exit or cut");
    end
    // ---- The walk over the parcels (the decision as first built), simulation only: every output of the
    // flat form above equals its result (the history's on a delivered block: elsewhere the walk can count
    // past two branches, on a block that is not delivered) ----
    if (1) begin : g_ref
      logic [NP-1:0]             r_cbr, r_tkn, r_rp;
      logic [SLOT_W-1:0]         r_fe_p, r_c3_p, r_fp, r_fx_slot;
      logic                      r_fe_v, r_c3_v;
      always_comb begin
        int   nb;
        logic seen;
        nb = sx_br ? 1 : 0;
        seen = sx_tk;
        r_fe_v = 1'b0; r_fe_p = '0; r_c3_v = 1'b0; r_c3_p = '0;
        for (int p = 0; p < NP; p++) begin
          logic o, ujx;
          o        = wide[p] && p == NP - 1;
          r_cbr[p] = pd_start[p] && pd_br[p] && !o;
          r_rp[p]  = RAS_FE && pd_pop[p] && ras_v;
          ujx      = pd_start[p] && !o && (pd_jal[p] || (pd_jalr[p] && (r_rp[p] || (uok && f2_slot_q == lsl[p]))));
          r_tkn[p] = ujx || (r_cbr[p] && tdir[lsl[p]]);
          if (!seen && r_cbr[p] && nb == 2) begin
            seen = 1'b1; r_c3_v = 1'b1; r_c3_p = SLOT_W'(p);
          end else if (!seen && r_tkn[p]) begin
            seen = 1'b1; r_fe_v = 1'b1; r_fe_p = SLOT_W'(p);
          end
          if (r_cbr[p]) nb++;
        end
      end
      logic [NP-1:0] r_pq, r_pq_run, r_bs;
      logic          r_pe, r_phi, r_pcut, r_ccut, r_isf, r_tk, r_bc;
      always_comb begin
        logic run;
        run = 1'b0;
        for (int p = 0; p < NP; p++) begin
          logic lm;
          lm = fe_s ? 1'b0 : r_fe_v ? SLOT_W'(p) <= lsl[r_fe_p] : r_c3_v ? SLOT_W'(p) < r_c3_p : 1'b1;
          r_pq[p] = pd_start[p] && lm && (dslot[p] || (wide[p] && p + 1 < NP && dslot[(p + 1) % NP]));
          run = run || r_pq[p];
          r_pq_run[p] = run;
        end
        r_pe   = f2_chk && (f2_carried || r_pq[f2_ent]);
        r_phi  = f2_chk && !f2_carried && r_pq[f2_ent] && !dslot[f2_ent];
        r_pcut = f2_chk && !f2_carried && |r_pq && !r_pq[f2_ent];
        r_ccut = f2_chk && r_c3_v && !r_pe;
        r_isf  = f2_bfault || r_pe;
        r_tk   = (fe_s || r_fe_v) && !r_isf && !r_pcut;
        for (int p = 0; p < NP; p++)
          r_bs[p] = pd_start[p] && !(r_tk && fe_s) &&
                    (r_pcut ? !r_pq_run[p] : r_ccut ? SLOT_W'(p) < r_c3_p : (!r_tk || SLOT_W'(p) <= lsl[r_fe_p]));
        r_bc = pd_carry && !r_tk && !r_pcut && !r_ccut;
        if (r_isf) begin
          r_bs = '0;
          r_bs[f2_ent] = 1'b1;
          r_bc = 1'b0;
        end
        r_fp = r_c3_p;
        if (r_pcut) begin
          r_fp = '0;
          for (int p = NP - 1; p >= 0; p--) if (r_pq[p]) r_fp = SLOT_W'(p);
        end
      end
      assign r_fx_slot = fe_s ? '0 : lsl[r_fe_p];
      logic        r_fx_tsrc, r_fe_ras, r_ovr, r_rpush, r_rpop;
      logic [20:0] r_imm;
      logic [38:1] r_rlink;
      logic [63:0] r_tgt;
      assign r_fe_ras  = r_tk && (fe_s ? RAS_FE && sx_pop && ras_v : r_rp[r_fe_p]);
      assign r_ovr     = !r_isf && !r_pcut && !r_ccut &&
                         (r_tk ? !(f2_hit_q && f2_slot_q == r_fx_slot && (!r_fe_ras || f2_tgt_q == rtgt)) : f2_hit_q);
      // the exit's own target only where F2 refetches there
      assign r_fx_tsrc = r_tk && (fe_s ? !sx_jalr : !pd_jalr[r_fe_p]) && r_ovr;
      always_comb begin
        logic [31:0] x;
        x = {parcel[(int'(r_fe_p) + 1) % NP], parcel[r_fe_p]};
        r_imm = fe_s ? br_imm(sx, sx_jal) : br_imm(x, pd_jal[r_fe_p]);
      end
      assign r_tgt   = r_fe_ras ? rtgt : f2_tgt_q;
      assign r_rpush = RAS_FE && r_tk && (fe_s ? sx_call : pd_call[r_fe_p]);
      assign r_rpop  = RAS_FE && r_tk && (fe_s ? sx_pop : pd_pop[r_fe_p]);
      assign r_rlink = fe_s ? {f2_pc_q[38:4], 3'b000} + 38'd1
                            : {f2_pc_q[38:4], 3'b000} + 38'(r_fe_p) + (wide[r_fe_p] ? 38'd2 : 38'd1);
      logic [1:0]    r_gh_n, r_gh_b;
      logic [NP-1:0] r_gh_cm, r_gh_pk;
      always_comb begin
        int k;
        k = 0;
        r_gh_b  = '0;
        r_gh_cm = '0;
        r_gh_pk = '0;
        if (!r_isf && sx_br) begin
          r_gh_b = {r_gh_b[0], r_tk && fe_s};
          r_gh_cm[0] = 1'b1;
          r_gh_pk[0] = r_tk && fe_s;
          k++;
        end
        for (int p = 0; p < NP; p++)
          if (!r_isf && r_bs[p] && r_cbr[p]) begin
            r_gh_b = {r_gh_b[0], r_tk && SLOT_W'(p) == r_fe_p};
            r_gh_cm[lsl[p]] = 1'b1;
            r_gh_pk[lsl[p]] = r_tk && SLOT_W'(p) == r_fe_p;
            k++;
          end
        r_gh_n = 2'(k);
      end
      logic r_seen_q;                              // the first reset has come
      initial r_seen_q = 1'b0;
      always @(posedge clk) if (rst) r_seen_q <= 1'b1;
      always_ff @(posedge clk) begin
        if (r_seen_q && !rst && f2v) begin
          assert (r_fe_v == fe_v && r_fe_p == fe_p && r_c3_v == c3_v && r_c3_p == c3_p && r_isf == isf &&
                  r_phi == phi && r_pcut == pcut && r_ccut == ccut && r_tk == tk && r_bs == bs && r_bc == bc &&
                  r_fp == fp && r_fx_slot == fx_slot && r_fx_tsrc == fx_tsrc && r_fe_ras == fe_ras &&
                  r_ovr == f2_ovr && r_imm == ovr_imm && r_tgt == fx_tgt && r_rpush == f2_rpush &&
                  r_rpop == f2_rpop && r_rlink == f2_rlink)
            else $error("tg_fetch: the flat decision differs from the walk's");
          assert (f2_ka == (r_pcut || r_ccut || r_isf || r_ovr) || !f2_deliver)
            else $error("tg_fetch: F2's action differs from the walk's");
          if (f2_deliver)
            assert (r_gh_n == gh_n && r_gh_b == gh_b && r_gh_cm == gh_cm && r_gh_pk == gh_pk)
              else $error("tg_fetch: the flat history bits differ from the walk's");
        end
      end
    end
`endif
  end

  // ---- F3: compaction ----
  logic                 f3_valid_q, f3_carry_q;
  logic [NP-1:0][15:0]  f3_parcel_q, f3_parcel;
  logic [NP-1:0]        f3_start_q;
  logic [NP-1:0][2:0]   f3_marks_q;
  meta_t                f3_meta_q;
  // A fault block's parcels go to the queue as zeros: zeroed here, from the registered fault bit,
  // so F2's late fault decision does not drive the parcel registers' resets
  assign f3_parcel = f3_meta_q.fault ? '0 : f3_parcel_q;
  logic                 blk_ready;
  logic                 f3_accept;
  assign f3_accept = !f3_valid_q || blk_ready;

  logic [DECODE_WIDTH-1:0]           cq_valid;
  logic [DECODE_WIDTH-1:0][IB_W-1:0] cq_insn;
  logic                              redirect;
  assign redirect = flush || dred;
  tg_fetch_compact #(.WR(4), .RD(DECODE_WIDTH), .DEPTH(IBUF_ENTRIES), .META_W(META_W)) u_cmp (
    .clk, .rst, .flush(redirect), .dst, .blk_valid(f3_valid_q), .parcel(f3_parcel),
    .start(f3_start_q), .marks(f3_marks_q), .carry_out(f3_carry_q), .meta(f3_meta_q),
    .blk_ready, .out_valid(cq_valid), .out_insn(cq_insn), .take(iq_take));

  // ---- Pipeline control ----
  // F2 delivers when it is valid, not missing, and F3 can take the block. It holds while F3
  // cannot, missing or not: its action is registered anyway.
  logic f2_deliver, f2_hold;
  logic ft_full;                          // TAGE_ON: no FTQ entry for another block
  assign f2_deliver = f2v && !f2_miss && !f2_wmiss && f3_accept && !ft_full;
  assign f2_hold    = f2v && (!f3_accept || ft_full);
  // F1 moves on when F2 is free (or delivers) and fetch is not parked, stopped or waiting for the
  // PMP descriptors, the valid-bit sweep or its own PMP check (f1_pwait).
  logic f1_base, f1_live, ivs_done;
  assign f1_base = f1_valid_q && !miss_q && !wk_q && !stop_q && ready && !pmp_busy && ivs_done;
  assign f1_live = f1_base && !f1_pwait;
  assign f2_go   = !f2_hold && !redirect;
  logic f2_override;                     // F2's prediction is not F1's: refetch (f2_ovr)
  // (f2_isf0, not f2_isfault: with the micro-BTB alone, when its prediction stands the term is zero
  // anyway, and otherwise f2_isfault is isf_h[0]; so the override does not wait for the pick by hp)
  assign f2_override = f2_deliver && f2_ovr && !f2_isf0;
  logic am_go, aw_go;                    // F2's miss or ITLB miss of last cycle parks fetch now
  assign am_go  = ka_q && k_miss_q;
  assign aw_go  = ka_q && k_walk_q;
  assign iw_req = (wk_q && !wk_sent_q) || aw_go;
  assign iw_va  = miss_pc_q;
  // The micro-BTB entry of a dropped prediction (its exit slot is no branch's or jump's) is
  // invalidated a cycle later
  logic        ainv_q, ainv_way_q;
  logic [38:4] ainv_pc_q;
  always_ff @(posedge clk) begin
    if (rst) ainv_q <= 1'b0;
    else     ainv_q <= f2_deliver && f2_hit_q && !pred_ok && !f2_isf0;
    ainv_pc_q  <= f2_pc_q[38:4];
    ainv_way_q <= f2_way_q;
  end
  assign f2_inval     = ainv_q;
  assign f2_inval_pc  = ainv_pc_q;
  assign f2_inval_way = ainv_way_q;

  // ---- TAGE, the histories and the FTQ (TAGE_ON) ----
  // The speculative history (gh_q) takes each delivered block's conditional branches as predicted;
  // commit's (cgh_q) takes each retiring one's outcome: the same branches in the same order on the
  // right path. A flush (every recovery is at commit) copies commit's into it; decode's redirect
  // rebuilds it from the redirecting instruction's block: its FTQ entry keeps the history before
  // the block and the block's branch slots and directions. The FTQ also keeps the indices and tags
  // each block read TAGE with, which commit's branches train it with.
  logic [FTQW-1:0] ft_tail;              // the FTQ entry a block delivered now takes
  if (TAGE_ON) begin : g_tage
    localparam int IXW = TAGE_IXW;
    logic [IXW-1:0]  tix;
    logic [GH_W-1:0] gh_q, cgh_q;
    // A delivered block's history bits go in a cycle later (timing: F2's decision ends at gp_*_q, not
    // at the history's shift): gh_e, the history with them, is what every reader takes, as gh_q was.
    // Only a block's last branch can be taken (its exit), so the bits are a count and one value
    logic [GH_W-1:0] gh_e;
    logic [1:0]      gp_n_q;
    logic            gp_b_q;
    assign gh_e = (gp_n_q == 2'd0) ? gh_q : (gp_n_q == 2'd1) ? {gh_q[GH_W-2:0], gp_b_q} : {gh_q[GH_W-3:0], 1'b0, gp_b_q};
    // FTQ pointers, with a wrap bit; a delivery takes the tail. TAGE's training queue names the
    // blocks of its requests (commit's, with their wrap bits), and its head's indices and tags are
    // read from here: no entry is freed while the queue names it (the head ft_eh: its oldest)
    logic [FTQW:0]        ft_t_q, ft_h_q, ft_eh;
    logic                 ft_we;
    logic                 tq_v;
    logic [FTQW:0]        tq_ftq;
    logic [COMMIT_WIDTH-1:0][FTQW:0] c_fp;
    logic [0:0][FTQW-1:0] fq_ra;
    logic [0:0][IXW-1:0]  fq_rd;
    always_comb
      for (int j = 0; j < COMMIT_WIDTH; j++) c_fp[j] = {(c_ftq[j] < ft_h_q[FTQW-1:0]) ^ ft_h_q[FTQW], c_ftq[j]};
    tg_tage #(.NP(NP), .CW(COMMIT_WIDTH), .NT(TAGE_NT), .LI(TAGE_LI), .TW(TAGE_TW), .BI(TAGE_BI), .HW(GH_W),
              .FW(FTQW + 1)) u_tage (
      .clk, .rst, .re(f2_go), .blk(fpc_q[38:4]), .gh(gh_e), .dir(tdir), .ix(tix),
      .t_v(c_cbr), .t_ftq(c_fp), .t_slot(c_slot), .t_taken(c_taken), .t_pred(c_pred),
      .q_v(tq_v), .q_ftq(tq_ftq), .q_ix(fq_rd[0]));
    assign ft_eh   = tq_v ? tq_ftq : ft_h_q;
    assign ft_full = ft_t_q[FTQW] != ft_eh[FTQW] && ft_t_q[FTQW-1:0] == ft_eh[FTQW-1:0];
    assign ft_tail = ft_t_q[FTQW-1:0];
    assign ft_we   = f2_deliver && !redirect;
    // (and the return-address stack's pointer, count and top before the block, RAS_FE)
    localparam int RW = GH_W + 2 * NP + RAS_PW + RAS_PW + 1 + 38;
    logic [0:0][FTQW-1:0] fr_ra;
    logic [0:0][RW-1:0]   fr_rd;
    assign fr_ra[0] = dred_ftq;
    tg_ram_lut #(.DEPTH(FTQ_ENTRIES), .WIDTH(RW), .NR(1)) u_fgh (
      .clk, .we(ft_we), .waddr(ft_tail), .wdata({gh_e, gh_cm, gh_pk, ras_tos, ras_cnt, ras_top}), .raddr(fr_ra),
      .rdata(fr_rd));
    // the stack's operation at a delivered block's exit, and its repair at decode's redirect
    assign ras_push = ft_we && !f2_isfault && f2_rpush;
    assign ras_pop  = ft_we && !f2_isfault && f2_rpop;
    assign ras_link = f2_rlink;
    assign ras_rv   = RAS_FE && dred && !flush;
    // the repair: the stack before the redirecting instruction's block (its exit's operation is the
    // instruction's own or comes after it), then the instruction's own operation (decode's): this
    // covers a call or return no block's exit carried, such as one that straddles into its block
    always_comb begin
      logic [RAS_PW-1:0] t;
      logic [RAS_PW:0]   c;
      logic [38:1]       v;
      {t, c, v} = fr_rd[0][RAS_PW + RAS_PW + 1 + 38 - 1:0];
      ras_rwr = 1'b1;
      if (dred_rop[0]) begin                         // a pop: the entry below stays as it is
        t = t - 1'b1;
        if (c != '0) c = c - 1'b1;
        ras_rwr = 1'b0;
      end
      if (dred_rop[1]) begin                         // a push: its link on top
        t = t + 1'b1;
        if (c != (RAS_PW + 1)'(RAS_ENTRIES)) c = c + 1'b1;
        v = dred_rlink;
        ras_rwr = 1'b1;
      end
      ras_rtos = t;
      ras_rcnt = c;
      ras_rtop = v;
    end
    assign fq_ra[0] = tq_ftq[FTQW-1:0];
    tg_ram_lut #(.DEPTH(FTQ_ENTRIES), .WIDTH(IXW), .NR(1)) u_fix (
      .clk, .we(ft_we), .waddr(ft_tail), .wdata(tix), .raddr(fq_ra), .rdata(fq_rd));
    // the history after decode's redirect at slot dred_slot of block dred_ftq: the block's branches up to
    // that slot (at most two, the cut's rule), shifted in after the history before the block. Found
    // first and shifted once, so the history takes a shift of 0, 1 or 2, not one per slot (area)
    logic [GH_W-1:0] r_gh;
    logic [NP-1:0]   r_cm;
    always_comb begin
      logic [GH_W-1:0] g;
      logic [NP-1:0]   pk;
      logic [1:0]      n, b;           // how many, and their directions (the later in bit 0)
      {g, r_cm, pk} = fr_rd[0][RW-1 -: GH_W + 2 * NP];
      n = '0;
      b = '0;
      for (int k = 0; k < NP; k++)
        if (r_cm[k] && SLOT_W'(k) <= dred_slot) begin
          b = {b[0], pk[k]};
          n = n + 1'b1;
        end
      r_gh = (n == 2'd0) ? g : (n == 2'd1) ? {g[GH_W-2:0], b[0]} : {g[GH_W-3:0], b};
    end
    always_ff @(posedge clk) begin
      if (rst) begin
        gh_q   <= '0;
        gp_n_q <= '0;
        cgh_q  <= '0;
        ft_t_q <= '0;
        ft_h_q <= '0;
      end else begin
        logic [GH_W-1:0] c;
        c = cgh_q;
        for (int j = 0; j < COMMIT_WIDTH; j++) if (c_cbr[j]) c = {c[GH_W-2:0], c_taken[j]};
        cgh_q <= c;
        if (flush) begin                   // (nothing retires in a flush's cycle)
          gh_q   <= cgh_q;
          gp_n_q <= '0;
          // every block goes; the training queue may still name the head's and earlier ones
          ft_t_q <= ft_h_q + 1'b1;
          ft_h_q <= ft_h_q + 1'b1;
        end else begin
          if (dred) begin
            gh_q   <= r_gh;
            gp_n_q <= '0;
          end else begin
            gh_q   <= gh_e;
            gp_n_q <= ft_we ? gh_n : 2'd0;
            gp_b_q <= gh_b[0];
          end
          // decode's redirect keeps its instruction's block and drops the later ones; commit frees
          // the blocks before the youngest retiring instruction's
          if (dred)       ft_t_q <= {(dred_ftq < ft_h_q[FTQW-1:0]) ^ ft_h_q[FTQW], dred_ftq} + 1'b1;
          else if (ft_we) ft_t_q <= ft_t_q + 1'b1;
          if (c_hv)       ft_h_q <= {(c_hftq < ft_h_q[FTQW-1:0]) ^ ft_h_q[FTQW], c_hftq};
        end
      end
    end
    assign kt_tgt = {miss_pc_q[63:4], 4'b0} + (ks_q ? 64'hFFFF_FFFF_FFFF_FFFE : 64'({kp_q, 1'b0})) +
                    {{43{kimm_q[20]}}, kimm_q};
`ifndef SYNTHESIS
    logic tq_rs_q;                          // the first reset has come
    initial tq_rs_q = 1'b0;
    always @(posedge clk) if (rst) tq_rs_q <= 1'b1;
    // the history as first built (updated with each delivered block): gh_e equals it
    logic [GH_W-1:0] gh_ref_q;
    always_ff @(posedge clk) begin
      if (rst)        gh_ref_q <= '0;
      else if (flush) gh_ref_q <= cgh_q;
      else if (dred)  gh_ref_q <= r_gh;
      else if (ft_we)
        gh_ref_q <= (gh_n == 2'd0) ? gh_ref_q : (gh_n == 2'd1) ? {gh_ref_q[GH_W-2:0], gh_b[0]} : {gh_ref_q[GH_W-3:0], gh_b};
      if (tq_rs_q && !rst) assert (gh_e == gh_ref_q) else $error("tg_fetch: the history with its pending bits differs from the history's");
    end
    always_ff @(posedge clk)
      if (tq_rs_q && !rst && dred && !flush)
        assert ($countones(r_cm) <= 2) else $error("tg_fetch: an FTQ entry with more than two conditional branches");
    always_ff @(posedge clk)
      if (tq_rs_q && !rst && ft_we && tq_v)
        assert (ft_tail != tq_ftq[FTQW-1:0]) else $error("tg_fetch: a block takes the FTQ entry TAGE's training queue names");
`endif
  end else begin : g_notage
    assign ft_full = 1'b0;
    assign ft_tail = '0;
    assign tdir    = '0;
    assign kt_tgt  = '0;
    assign ras_push = 1'b0;
    assign ras_pop  = 1'b0;
    assign ras_link = '0;
    assign ras_rv   = 1'b0;
    assign ras_rwr  = 1'b0;
    assign ras_rtos = '0;
    assign ras_rcnt = '0;
    assign ras_rtop = '0;
    logic unused_tage;
    assign unused_tage = ^{dred_ftq, dred_slot, dred_rop, dred_rlink, c_cbr, c_taken, c_pred, c_ftq, c_slot, c_hv, c_hftq, gh_n, gh_b,
                           gh_cm, gh_pk, kp_q, kimm_q, ras_v, ras_top, ras_tos, ras_cnt, f2_rpush, f2_rpop,
                           f2_rlink, krt_q, ks_q};
  end

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

  // Valid bits: a LUTRAM row per set (plan §8.3: no flip-flop arrays) of WAYS bits and the set's
  // 2-bit generation. Reads: the set F1 fetches, and the missed set (victim choice when the refill
  // starts; the refill's read-modify-write when it ends). After reset a sweep clears every set while
  // F1 waits.
  // FENCE.I by generation (area_recovery.md §6.11; it swept every set, 64 cycles of fetch, 5,410
  // times in the boot's first 20M cycles): a set holds valid lines only while its generation is the
  // current one (gen_q). FENCE.I bumps gen_q, so every older line misses from the next cycle, and
  // fetch does not wait. A background pass then rewrites each stale set as current and empty, in
  // cycles the refill leaves the second read port and the write port free; it skips a set the refill
  // has made current since. A completed pass leaves no stale set, so the generation may wrap: a
  // fourth FENCE.I before a pass completes falls back to the sweep.
  // The refill rewrites the victim's rows beat by beat and may outlive a redirect, so the
  // victim's valid bit is cleared when the refill starts: its old line misses from the next
  // cycle on (a read in the start cycle still gets the old data: no beat is written yet), and
  // F1 reads in the install cycle are refetched (rdone_d_q).
  localparam int IVW = WAYS + 2;             // a row: {generation, valid bits}
  logic [1:0][SET_W-1:0] iv_ra;
  logic [1:0][IVW-1:0]   iv_rd;
  logic [1:0][WAYS-1:0]  iv_v;              // each read's valid lines: none in a stale set
  logic                  iv_we;
  logic [SET_W-1:0]      iv_wa;
  logic [IVW-1:0]        iv_wd;
  logic [SET_W:0]        ivs_q;             // sweep: the next set to clear; done at SETS
  logic [1:0]            gen_q;             // the current generation
  logic [1:0]            gpend_q;           // FENCE.Is since the last completed pass (0 to 3)
  logic [SET_W:0]        gps_q;             // the pass: the next set to visit; done at SETS
  logic                  gp_go;             // the pass visits gps_q this cycle
  logic                  r_start;           // the refill of miss_pa_q's line starts
  assign ivs_done = ivs_q[SET_W];
  assign r_start  = rs_q == R_IDLE && (miss_q || am_go) && !rst;
  assign gp_go    = !gps_q[SET_W] && ivs_done && !r_start && !tag_we;
  assign iv_ra[0] = fpc_q[6 +: SET_W];
  assign iv_ra[1] = gp_go ? gps_q[SET_W-1:0] : (rs_q == R_IDLE) ? miss_pa_q[6 +: SET_W] : rline_q[6 +: SET_W];
  tg_ram_lut #(.DEPTH(SETS), .WIDTH(IVW), .NR(2)) u_ival (
    .clk, .we(iv_we), .waddr(iv_wa), .wdata(iv_wd), .raddr(iv_ra), .rdata(iv_rd));
  for (genvar k = 0; k < 2; k++) begin : g_ivv
    assign iv_v[k] = (iv_rd[k][IVW-1 -: 2] == gen_q) ? iv_rd[k][WAYS-1:0] : '0;
  end

  // F1's tag compare (for F2's way select, above): the set's valid bits and tags against fpc_q's PA
  logic [WAYS-1:0]  f1_wh;
  logic [WAY_W-1:0] f1_hw;
  for (genvar w = 0; w < WAYS; w++) begin : g_cmp
    assign f1_wh[w] = iv_v[0][w] && tag_rd[w] == f1_pa[12 +: TAG_W];
  end
  always_comb begin
    f1_hw = '0;
    for (int w = 0; w < WAYS; w++) if (f1_wh[w]) f1_hw |= WAY_W'(w);
  end

  // victim: first invalid way of the set, else round robin
  logic [WAY_W-1:0] victim;
  always_comb begin
    logic found;
    found = 1'b0;
    victim = rr_q;
    for (int w = 0; w < WAYS; w++) begin
      if (!found && !iv_v[1][w]) begin
        victim = WAY_W'(w);
        found = 1'b1;
      end
    end
  end

  always_comb begin
    iv_we = tag_we;
    iv_wa = tag_set;
    iv_wd = {gen_q, iv_v[1] | (WAYS'(1) << rway_q)};
    if (r_start) begin                      // (never with tag_we: that is the refill's end)
      iv_we = 1'b1;
      iv_wa = miss_pa_q[6 +: SET_W];
      iv_wd = {gen_q, iv_v[1] & ~(WAYS'(1) << victim)};
    end
    if (gp_go) begin                        // (never with either): a stale set, current and empty
      iv_we = iv_rd[1][IVW-1 -: 2] != gen_q;
      iv_wa = gps_q[SET_W-1:0];
      iv_wd = {gen_q, {WAYS{1'b0}}};
    end
    if (!ivs_done) begin
      iv_we = 1'b1;
      iv_wa = ivs_q[SET_W-1:0];
      iv_wd = {gen_q, {WAYS{1'b0}}};
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
    if (rst) begin
      ivs_q   <= '0;
      gen_q   <= '0;
      gpend_q <= '0;
      gps_q   <= (SET_W + 1)'(SETS);
    end else if (icinv) begin
      gen_q <= gen_q + 1'b1;
      if (gpend_q == 2'd3) begin             // the generation would wrap onto a stale set: sweep
        ivs_q   <= '0;
        gpend_q <= '0;
        gps_q   <= (SET_W + 1)'(SETS);
      end else begin
        gpend_q <= gpend_q + 1'b1;
        gps_q   <= '0;                       // (re)start the pass
      end
    end else begin
      if (!ivs_done) ivs_q <= ivs_q + 1'b1;
      if (gp_go) begin
        gps_q <= gps_q + 1'b1;
        if (gps_q[SET_W-1:0] == SET_W'(SETS - 1)) gpend_q <= '0;   // no stale set is left
      end
    end
    rdone_d_q <= tag_we && !rst;
    rline_d_q <= rline_q;
  end
`ifndef SYNTHESIS
  // The valid bits as the sweep kept them, every line of every set cleared at FENCE.I: the
  // generations must give F1 and the victim choice the same lines
  logic [SETS-1:0][WAYS-1:0] ivref_q;
  logic                      ivref_ok_q;            // a reset has come, and its sweep has run
  initial ivref_ok_q = 1'b0;
  always @(posedge clk) begin
    if (rst || icinv) ivref_q <= '0;
    else begin
      if (r_start) ivref_q[miss_pa_q[6 +: SET_W]][victim] <= 1'b0;
      if (tag_we)  ivref_q[tag_set][rway_q] <= 1'b1;
    end
    if (rst) ivref_ok_q <= 1'b0;
    else if (ivs_done) ivref_ok_q <= 1'b1;
  end
  always_ff @(posedge clk) begin
    if (ivref_ok_q && !rst && ivs_done) begin
      assert (iv_v[0] == ivref_q[iv_ra[0]]) else $error("tg_fetch: the I$ valid lines differ from the sweep's");
      if (r_start) assert (iv_v[1] == ivref_q[iv_ra[1]]) else $error("tg_fetch: the victim's set differs from the sweep's");
      assert (!(gp_go && (r_start || tag_we))) else $error("tg_fetch: the generation pass with a refill write");
    end
  end
`endif

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
        f3_parcel_q <= parcel;                      // a fault block's are zeroed after it
        f3_start_q  <= blk_start;
        f3_marks_q  <= f2_bfault ? '0 : blk_marks;
        f3_carry_q  <= blk_carry;
        f3_meta_q   <= '{base: f2_pc_q[63:4], hit: f2_taken, way: f2_way_q, slot: fx_slot,
                         target: fx_tgt, tsrc: fx_tsrc,
                         uhit: TAGE_ON ? uok && !f2_isfault : f2_taken, uslot: f2_slot_q, ftq: ft_tail,
                         fault: f2_isfault, fpf: f2_bfault && f2_fpf_q, fhi: !f2_bfault && pmp_hi};
      end
      if (f2_deliver) begin
        f3_valid_q  <= 1'b1;
        carry_q     <= blk_carry;
        sp_q        <= parcel[NP-1];
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
                      : k_ovr_q ? (kr_q ? krt_q : kt_q ? kt_tgt : {miss_pc_q[63:4] + 60'd1, 4'b0}) : miss_pc_q;
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
        f2_wh_q    <= f1_wh;
        f2_hw_q    <= f1_hw;
        if (f1_live) begin
          fpc_q <= (pred_hit && !f1_fault) ? pred_tgt : seq_pc;
          pw_q  <= 1'b0;
        end
      end
      // F2's action on this cycle's block, taken next cycle; miss_pc_q and miss_pa_q name the block
      ka_q     <= f2_miss || f2_wmiss || (f2_deliver && f2_ka);
      k_miss_q <= f2_miss && !((refill_done && f2_pa_q[PA_W-1:6] == rline_q) ||
                               (rdone_d_q && f2_pa_q[PA_W-1:6] == rline_d_q));
      k_walk_q <= f2_wmiss;
      k_stop_q <= f2_deliver && f2_isfault;
      k_cut_q  <= pmp_cut;
      k_ovr_q  <= f2_override;
      kt_q     <= ovr_tk;
      kp_q     <= ovr_p;
      kimm_q   <= ovr_imm;
      kr_q     <= ovr_ras;
      krt_q    <= fx_tgt;
      ks_q     <= ovr_s;
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
    logic              qill, qexc, qser;   // the queue's decode bits (QUEUE_DECODE; else none)
    if (QUEUE_DECODE) begin : g_qd
      assign {qill, qexc, qser, m, marks, slot, rvc, hi, lo} = cq_insn[j];
    end else begin : g_nqd
      assign {m, marks, slot, rvc, hi, lo} = cq_insn[j];
      assign {qill, qexc, qser} = '0;
    end
    logic              strad;
    logic [SLOT_W:0]   first, last;     // parcel range, straddler from -1 (encoded as first = 0, strad)
    assign strad = slot == SLOT_W'(NP - 1) && !rvc;
    logic [63:0] pc;
    // pc[3:0] needs no carry; only a straddler's block address is decremented
    assign pc   = strad ? {m.base - 1'b1, 4'hE} : {m.base, slot, 1'b0};
    assign first = (SLOT_W + 1)'(slot);
    assign last  = strad ? '0 : (rvc ? first : first + 1'b1);
    logic exit_here, u_here;
    assign exit_here = m.hit && (strad ? m.slot == '0
                                       : ((SLOT_W + 1)'(m.slot) >= first && (SLOT_W + 1)'(m.slot) <= last));
    assign u_here    = m.uhit && (strad ? m.uslot == '0
                                        : ((SLOT_W + 1)'(m.uslot) >= first && (SLOT_W + 1)'(m.uslot) <= last));
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
      iq_insn[j].ubtb_hit    = u_here;
      iq_insn[j].ubtb_way    = m.way;
      iq_insn[j].pred_tsrc   = m.tsrc && exit_here;
      iq_insn[j].ftq         = m.ftq;
      iq_insn[j].tid         = '0;
      iq_insn[j].marks       = marks;
      iq_insn[j].q_ill       = qill;
      iq_insn[j].q_exc       = qexc;
      iq_insn[j].q_ser       = qser;
    end
  end

  logic unused;
  assign unused = ^{upd_pc[63:39], upd_pc[3:0], upd_target[63:39], upd_target[0], pd_is32, pd_call, pd_ret, l1i_d_i.opcode, l1i_d_i.param, l1i_d_i.size,
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
    if (!rst && f2v && !f2_bfault) assert ($onehot0(way_hit)) else $error("tg_fetch: multiple way hits");
    if (!rst && (miss_q || am_go || wk_q)) assert (!f2v) else $error("tg_fetch: F2 holds a block while fetch is parked");
  end
`endif
endmodule
