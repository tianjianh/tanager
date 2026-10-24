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
  // Redirects, registered upstream: flush (commit) has priority over dred (decode); each of one thread (M7)
  input  logic        flush,
  input  tid_t        flush_tid,
  input  logic [63:0] flush_pc,
  input  logic        fl_slp,         // with hart 1 (step 6): the flush follows a WFI gone to sleep (tg_rob)
  input  logic        icinv,          // FENCE.I, together with flush
  input  logic        dred,
  input  tid_t        dred_tid,
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
  input  tid_t                                c_tid,     // ... their thread (M7)
  // The indirect-target table (ITT_ON) from commit, the same thread's: each retiring slot, its address's bits 17:2
  // (the path history's), a JALR that is not a return; a trap or interrupt taken and its epc's bits 17:2
  input  logic [COMMIT_WIDTH-1:0]             c_ret,
  input  logic [COMMIT_WIDTH-1:0][17:2]       c_pc,
  input  logic [COMMIT_WIDTH-1:0]             c_ijmp,
  input  logic                                c_trv,
  input  logic [17:2]                         c_trepc,
  // The return-address stack's speculative side (RAS_FE): its top, pointer and count; each delivered
  // block's exit's operation; the repair at decode's redirect (the pointer, count and top before the
  // redirecting block, from its FTQ entry)
  input  logic [NUM_THREADS-1:0]             ras_v_s,   // per stream (M7: a stack per thread with hart 1)
  input  logic [NUM_THREADS-1:0][38:1]       ras_top_s,
  input  logic [NUM_THREADS-1:0][RAS_PW-1:0] ras_tos_s,
  input  logic [NUM_THREADS-1:0][RAS_PW:0]   ras_cnt_s,
  output tid_t                ras_tid,        // the thread whose stack the operation below is (F2's stream's) ...
  output tid_t                ras_rtid,       // ... and the repair's (decode's redirect's; MT: they may differ)
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
  input  tid_t        upd_tid,        // ... the trained branch's thread (M7: fpu-2's, tg_exec)
  // Instruction queue to decode
  output logic [DECODE_WIDTH-1:0]   iq_valid,
  output fe_insn_t [DECODE_WIDTH-1:0] iq_insn,
  input  logic [TKW-1:0]            iq_take,
  input  logic [TKW-1:0]            iq_take_t,  // ... decode's take if rename takes its group, and if not
  input  logic [TKW-1:0]            iq_take_n,
  input  logic                      iq_tnz_t,   // ... whether each is nonzero (decode's, for the read thread's choice)
  input  logic                      iq_tnz_n,
  input  logic                      de_take,    // rename takes decode's group (iq_take is the choice)
  // Translation and PMP (M3)
  input  logic [NUM_THREADS-1:0] xl_h,   // per hart (F1's block's thread's is used): fetch translates: S or U, Sv39
  input  dec_state_t [NUM_THREADS-1:0] dst,   // each hart's decode state, for the queue's decode bits
  input  priv_e  [NUM_THREADS-1:0] priv_h,
  input  pmp_d_t [NUM_THREADS-1:0][PMP_ENTRIES-1:0] pmp_d_h,
  input  logic        pmp_busy,       // PMP descriptors being recomputed: F1 waits
  input  logic [NUM_THREADS-1:0] pmp_lk_h,   // DR-183: each hart's active locked entries
  // DR-183 (PMP_FILL): the LSU's shared checker, a registered request held until its tagged response: a page (its S/U
  // result, and whether a region boundary lies inside it at 4 KiB) or one 4-byte word
  output logic        pfc_req,
  output logic        pfc_page,
  output logic        pfc_tag,
  output tid_t        pfc_tid,
  output logic [PA_W-1:0] pfc_pa,
  output logic        pfc_m,          // a word under M's rules (M-mode with a locked entry)
  input  logic        pfc_rsp_v,
  input  logic        pfc_rsp_tag,
  input  logic        pfc_rsp_ok,
  input  logic        pfc_rsp_nh,
  input  logic        pfc_rsp_x,
  input  logic [NUM_THREADS-1:0] rn_block,   // MT: a thread behind a serial uop at rename until its flush (tg_rename)
  input  logic [NUM_THREADS-1:0] rn_acc,     // MT (step 5d): a thread's RN register takes a group next cycle (tg_rename)
  input  logic        tlb_flush,
  input  tid_t        tlb_flush_tid,  // ... the hart whose entries it clears
  input  logic        it_fill,
  input  logic [26:0] it_fill_vpn,
  input  logic [1:0]  it_fill_lvl,
  input  tlb_pte_t    it_fill_pte,
  input  tid_t        it_fill_tid,
  output logic        iw_req,         // a walk for iw_va, held until iw_ack
  output tid_t        iw_tid,         // ... of this thread's (M7)
  output logic [NUM_THREADS-1:0] hpm_imiss,  // M9's counters (TG_HPM): each thread's I$ misses, pulses (tg_core registers them)
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

  // ---- Fetch streams (M7's step 5b): one per thread with hart 1 (MT), else the running thread's alone ----
  // F1, F2, the registered action and F3 each hold one block and its stream. Per stream: its next block when F1
  // holds the other's (sv_s_q, spc_s_q), its park and stop state, its straddler and a parked block's PC and PA.
  // F1 takes the other stream's waiting block when its own moves on (round robin, D7), an empty or stopped F1 takes
  // any waiting block, and a redirect, an action or a restart of one stream leaves the other's blocks alone. Without
  // MT every stream index is 0 and no block ever waits: the front end before M7.
  localparam bit MT = HART1_ON && NUM_THREADS > 1;
  localparam int NS = MT ? 2 : 1;
  function automatic logic strm(input tid_t t);   // a thread's stream
    return MT && t[0];
  endfunction
  // ---- F1 state ----
  logic        f1_valid_q;        // fpc_q names a block to fetch
  logic [63:0] fpc_q;
  logic        ft_q;              // ... of this stream
  logic [NS-1:0]       sv_s_q;    // a stream's next block waits outside F1 ...
  logic [NS-1:0][63:0] spc_s_q;   // ... here
  logic [NS-1:0]       stop_s_q;  // after a fault block, until a redirect
  logic [NS-1:0]       carry_s_q; // the last block left half a 32-bit instruction for the next one
  logic [NS-1:0][15:0] sp_s_q;    // ... that half (TAGE_ON: F2 predicts the straddler with the next block)
  logic [NS-1:0]       wk_s_q, wk_sent_s_q;   // parked on an ITLB miss; the walk was taken
  logic [NS-1:0]       miss_s_q;  // parked on an I$ miss
  logic [NS-1:0][63:0] rpc_s_q;   // a parked stream's block: its PC (the restart) ...
  logic [NS-1:0][PA_W-1:0] rpa_s_q;   // ... and PA (the refill's line)
  logic [NS-1:0]       qw_s_q;    // MT (5e): parked at F2, its block not fitting its queue while the other stream waits
  logic [NS-1:0][4:0]  qn_s_q;    // ... that block's bound on the entries it writes
  logic        f2_s_q, k_s_q, f3_s_q;   // F2's block's stream, the action's, F3's
  // A blocked stream (MT): its thread waits at rename behind a serial uop, whose commit flushes it, so whatever it
  // fetches meanwhile would go: F1 treats it as stopped, F2 passes its blocks on without an FTQ entry, and the
  // queue takes them without writing them (tg_fetch_compact's drop_t), so it holds none of the shared stages
  logic [NS-1:0] blk_s;
  assign blk_s = MT ? NS'(rn_block) : '0;
  // The stream views the logic below reads: F1's stream's stop, F2's stream's straddler
  logic        stop_q, carry_q;
  logic [15:0] sp_q;
  assign stop_q  = stop_s_q[ft_q] || blk_s[ft_q];
  assign carry_q = carry_s_q[f2_s_q];
  assign sp_q    = sp_s_q[f2_s_q];
  tid_t f3_tid;                                   // F3's block's thread
  assign f3_tid = MT ? tid_t'(f3_s_q) : RUN_TID;
  // F1's block's hart: its translation, privilege and PMP descriptors (M7's step 5b)
  tid_t f1_tid;
  assign f1_tid = MT ? tid_t'(ft_q) : RUN_TID;
  logic   xl_i;
  priv_e  priv;
  pmp_d_t [PMP_ENTRIES-1:0] pmp_d;
  assign xl_i  = xl_h[f1_tid];
  assign priv  = priv_h[f1_tid];
  assign pmp_d = pmp_d_h[f1_tid];
  // F2's stream's return-address stack (its prediction and the FTQ's snapshot read it)
  logic                ras_v;
  logic [38:1]         ras_top;
  logic [RAS_PW-1:0]   ras_tos;
  logic [RAS_PW:0]     ras_cnt;
  assign ras_v   = ras_v_s[f2_s_q];
  assign ras_top = ras_top_s[f2_s_q];
  assign ras_tos = ras_tos_s[f2_s_q];
  assign ras_cnt = ras_cnt_s[f2_s_q];
  // the stacks of fetch's operation (a delivered block's exit) and repair (decode's redirect): with MT they may come
  // in one cycle, for different threads (a redirect stops its own stream's delivery); without MT never together
  assign ras_tid  = MT ? tid_t'(f2_s_q) : (dred ? dred_tid : RUN_TID);
  assign ras_rtid = MT ? dred_tid : (dred ? dred_tid : RUN_TID);

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
  // Entries carry their thread (M7: with hart 1, F1's lookup takes F1's stream's entries, training writes the trained
  // branch's thread; without it 0 for both, as before)
  tid_t ub_ltid, ub_wtid;
  assign ub_ltid = MT ? tid_t'(ft_q) : '0;
  assign ub_wtid = MT ? upd_tid : '0;
  tg_ubtb #(.FA(1'b0), .NE(UBTB_ENTRIES)) u_ubtb (
    .clk, .rst, .pc(fpc_q[38:4]), .tid(ub_ltid), .hit(ub_hit), .target(ub_tgt), .br_slot(ub_slot),
    .hit_way(ub_way), .upd_valid(u_valid), .upd_way(u_way), .upd_pc(u_pc), .upd_tid(ub_wtid),
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
    .clk, .rst, .vpn(it_vpn), .vpn_e('0), .lk_tid(f1_tid), .hit(it_hit), .pte(it_pte), .fill(it_fill),
    .fill_vpn(it_fill_vpn), .fill_lvl(it_fill_lvl),
    .fill_pte(it_fill_pte), .fill_tid(it_fill_tid), .flush(tlb_flush), .flush_tid(tlb_flush_tid));
  logic [PA_W-1:0] f1_pa;
  assign f1_pa = xl_i ? {it_pte[0].ppn, fpc_q[11:0]} : fpc_q[PA_W-1:0];
  // A walk for this page faulted: its blocks are fault blocks until a redirect (per stream)
  logic [NS-1:0]         xf_v_s_q, xf_pf_s_q;
  logic [NS-1:0][63:12]  xf_page_s_q;
  logic         xf_pf_q;                          // F1's stream's
  assign xf_pf_q = xf_pf_s_q[ft_q];
  logic f1_xf, f1_pf, f1_tm, f1_acc, f1_fault, f1_fpf;
  pma_e f1_pma;
  assign f1_xf    = xl_i && xf_v_s_q[ft_q] && fpc_q[63:12] == xf_page_s_q[ft_q];
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
  logic               f1_cwait;               // DR-183 (PMP_FILL): F1 waits for the shared checker
  logic               f1_base, f1_live, ivs_done;   // (F1's state, below)
  if (!PMP_FILL) begin : g_pmp
    assign f1_pwait = xl_i && it_hit[0] && !it_pte[0].ph && !pw_q;
    tg_pmp #(.S(2)) u_pmp (.pa(xl_i ? {pw_pa_q, 4'b0} : fpc_q[PA_W-1:0]), .dbl(1'b0), .acc(ACC_X),
                           .m_mode(priv == PRIV_M), .d(pmp_d), .ok(pmp_okw), .hit(pmp_hit_u),
                           .rwx(pmp_rwx_u));
    assign f1_pmpd  = (xl_i && it_pte[0].ph) ? {NW{!it_pte[0].px}} : ~pmp_okw;
    assign f1_cwait = 1'b0;
    assign pfc_req  = 1'b0;
    assign pfc_page = 1'b0;
    assign pfc_tag  = 1'b0;
    assign pfc_tid  = '0;
    assign pfc_pa   = '0;
    assign pfc_m    = 1'b0;
    logic unused_pfc;
    assign unused_pfc = ^{pmp_lk_h, pfc_rsp_v, pfc_rsp_tag, pfc_rsp_ok, pfc_rsp_nh, pfc_rsp_x};
  end else begin : g_pmpf
    // DR-183: no checker here. A block decides by one of:
    //   - a translated page that is PMP-homogeneous: the ITLB's cached x (ph), as before;
    //   - M-mode while its hart has no locked entry: no check (only locked entries bind M);
    //   - bare S/U: the hart's last-page entry, the S/U result of the page F1 last fetched from in bare mode, filled
    //     by a page request to the shared checker and kept until the hart's next TLB flush (PMP writes flush them);
    //   - else word checks: a page with a region boundary inside (translated, or the entry's), or M-mode with a
    //     locked entry. One word at a time from the block's first, stopping at the first denied word: the block ends
    //     before it, or is a fault block at its first instruction, as F2 takes f1_pmpd.
    // Each request goes out from flip-flops, held until its response comes back, tagged. The work keeps the block it
    // started for (rq_id_q): the hart, the PC's bits 38:2 (they fix the block's words' physical addresses, through the
    // ITLB or bare), M-mode or not, and translation, all registers. Work for a block that is not F1's (cur) is dropped
    // the cycle after, with any response on its way and its last-page fill, and so is all work at a TLB flush (a PMP,
    // satp or SFENCE.VMA write: no result of the old descriptors outlives the flush, and pmp_busy holds new work back
    // until they are recomputed). Timing: when F1's block changes is known late, from F3's redirects and the I$
    // refills (spikes-2's preview: the request registers' enables, then an epoch register, 27 levels from f3_s_q).
    typedef enum logic [1:0] { C_IDLE, C_PAGE, C_WORD } cst_e;
    cst_e                     cs_q;
    logic [NUM_THREADS-1:0]   lp_v_q, lp_nh_q, lp_x_q;
    logic [NUM_THREADS-1:0][PA_W-13:0] lp_pg_q;
    logic                     cr_v_q;          // the word checks' result holds for F1's block
    logic [NW-1:0]            cr_den_q;        // ... the denied words
    logic [1:0]               cw_q;            // the word in check
    logic                     rq_v_q, rq_page_q, rq_tag_q, rq_m_q;
    tid_t                     rq_tid_q;
    logic [PA_W-1:0]          rq_pa_q;
    localparam int IDW = $bits(tid_t) + 39;
    logic [IDW-1:0]           f1_id, rq_id_q;   // F1's block; the work's
    logic f1_m, f1_bare, lp_hit, c_page, c_word, rsp, w_last, cur, start;
    assign f1_m    = priv == PRIV_M;
    assign f1_bare = !xl_i && !f1_m;
    assign lp_hit  = lp_v_q[f1_tid] && lp_pg_q[f1_tid] == fpc_q[PA_W-1:12];
    assign c_page  = f1_bare && !lp_hit;
    assign c_word  = (xl_i && it_hit[0] && !it_pte[0].ph) || (f1_bare && lp_hit && lp_nh_q[f1_tid]) ||
                     (f1_m && pmp_lk_h[f1_tid]);
    assign f1_pwait = 1'b0;
    assign f1_id    = {f1_tid, fpc_q[38:2], f1_m, xl_i};
    assign cur      = rq_id_q == f1_id;
    assign f1_cwait = c_page || (c_word && !(cr_v_q && cur));
    assign f1_pmpd  = (xl_i && it_pte[0].ph)                    ? {NW{!it_pte[0].px}} :
                      (f1_m && !pmp_lk_h[f1_tid])               ? '0 :
                      (f1_bare && lp_hit && !lp_nh_q[f1_tid])   ? {NW{!lp_x_q[f1_tid]}} : cr_den_q;
    assign rsp     = pfc_rsp_v && pfc_rsp_tag == rq_tag_q && rq_v_q && cur;
    assign w_last  = cw_q == 2'd3;
    assign start   = (cs_q == C_IDLE || !cur) && f1_base && !pmp_busy && (c_page || (c_word && !(cr_v_q && cur)));
    always_ff @(posedge clk) begin
      if (rst || tlb_flush) begin
        cs_q   <= C_IDLE;
        rq_v_q <= 1'b0;
        cr_v_q <= 1'b0;
      end else begin
        if (start) begin
          rq_v_q    <= 1'b1;
          rq_id_q   <= f1_id;
          rq_tag_q  <= !rq_tag_q;
          rq_tid_q  <= f1_tid;
          rq_page_q <= c_page;
          rq_m_q    <= f1_m;
          rq_pa_q   <= c_page ? {f1_pa[PA_W-1:12], 12'b0} : {f1_pa[PA_W-1:4], fpc_q[3:2], 2'b00};
          cw_q      <= fpc_q[3:2];
          cr_v_q    <= 1'b0;
          cr_den_q  <= '0;
          cs_q      <= c_page ? C_PAGE : C_WORD;
        end else if (!cur) begin
          // another block's work, and its result: dropped
          rq_v_q <= 1'b0;
          cr_v_q <= 1'b0;
          cs_q   <= C_IDLE;
        end else unique case (cs_q)
          C_IDLE: ;
          C_PAGE: if (rsp) begin
            rq_v_q <= 1'b0;
            cs_q   <= C_IDLE;
          end
          C_WORD: if (rsp) begin
            if (!pfc_rsp_ok || w_last) begin
              rq_v_q <= 1'b0;
              cr_v_q <= 1'b1;
              cs_q   <= C_IDLE;
              if (!pfc_rsp_ok) for (int w = 0; w < NW; w++) if (w >= int'(cw_q)) cr_den_q[w] <= 1'b1;
            end else begin
              rq_tag_q <= !rq_tag_q;
              cw_q     <= cw_q + 2'd1;
              rq_pa_q  <= {rq_pa_q[PA_W-1:4], cw_q + 2'd1, 2'b00};
            end
          end
          default: cs_q <= C_IDLE;
        endcase
      end
      // The last-page entries: a page response fills its hart's (only while F1 holds the work's block: rsp takes cur);
      // a TLB flush of the hart (PMP writes, satp writes, SFENCE.VMA) empties it, after the fill in the same cycle
      if (rst) lp_v_q <= '0;
      else begin
        if (cs_q == C_PAGE && rsp) begin
          lp_v_q[rq_tid_q]  <= 1'b1;
          lp_pg_q[rq_tid_q] <= rq_pa_q[PA_W-1:12];
          lp_nh_q[rq_tid_q] <= pfc_rsp_nh;
          lp_x_q[rq_tid_q]  <= pfc_rsp_x;
        end
        if (tlb_flush) lp_v_q[tlb_flush_tid] <= 1'b0;
      end
    end
    assign pfc_req  = rq_v_q;
    assign pfc_page = rq_page_q;
    assign pfc_tag  = rq_tag_q;
    assign pfc_tid  = rq_tid_q;
    assign pfc_pa   = rq_pa_q;
    assign pfc_m    = rq_m_q;
    assign pmp_okw   = '1;
    assign pmp_hit_u = 1'b0;
    assign pmp_rwx_u = '0;
    logic unused_pw;
    assign unused_pw = ^{pw_pa_q, pw_q, pmp_okw, pmp_hit_u, pmp_rwx_u};
`ifndef SYNTHESIS
    // (DR-183) Shadow checks, simulation only, against a full check of F1's block as it moves on: the last-page
    // entry's x on every word, M-mode's skip under M's rules, and the word checks' result up to its first denied word
    logic [NW-1:0] shf_okw, shm_okw, cx_den;
    logic          shf_hit, shm_hit;
    logic [2:0]    shf_rwx, shm_rwx;
    tg_pmp #(.S(2)) u_pmp_shf (.pa(f1_pa), .dbl(1'b0), .acc(ACC_X), .m_mode(1'b0), .d(pmp_d), .ok(shf_okw),
                               .hit(shf_hit), .rwx(shf_rwx));
    tg_pmp #(.S(2)) u_pmp_shm (.pa(f1_pa), .dbl(1'b0), .acc(ACC_X), .m_mode(1'b1), .d(pmp_d), .ok(shm_okw),
                               .hit(shm_hit), .rwx(shm_rwx));
    logic unused_shf;
    assign unused_shf = ^{shf_hit, shf_rwx, shm_hit, shm_rwx};
    always_comb begin
      logic d;
      d = 1'b0;
      cx_den = '0;
      for (int w = 0; w < NW; w++)
        if (w >= int'(fpc_q[3:2])) begin
          d = d || !(f1_m ? shm_okw[w] : shf_okw[w]);
          cx_den[w] = d;
        end
    end
    always_ff @(posedge clk)
      if (!rst && f1_live) begin
        if (f1_bare && lp_hit && !lp_nh_q[f1_tid])
          assert (shf_okw == {NW{lp_x_q[f1_tid]}})
            else $error("tg_fetch: the last-page entry's x (%b) differs from the full check (%b) at PA %h", lp_x_q[f1_tid],
                        shf_okw, f1_pa);
        if (f1_m && !pmp_lk_h[f1_tid])
          assert (&shm_okw) else $error("tg_fetch: M-mode skipped PMP (no locked entry), but a full check denies %b at PA %h",
                                        ~shm_okw, f1_pa);
        if (c_word)
          assert (cr_den_q == cx_den)
            else $error("tg_fetch: the word checks' denials (%b) differ from the full check's (%b) at PA %h", cr_den_q, cx_den,
                        f1_pa);
      end
`endif
  end
`ifndef SYNTHESIS
  // (DR-182) Shadow PMP check, simulation only: a translated block that takes the ITLB's cached result (ph) is checked
  // in full on its own physical address too, every word, and the two must agree
  logic [NW-1:0] sh_okw;
  logic          sh_hit;
  logic [2:0]    sh_rwx;
  tg_pmp #(.S(2)) u_pmp_sh (.pa({it_pte[0].ppn, fpc_q[11:4], 4'b0}), .dbl(1'b0), .acc(ACC_X), .m_mode(1'b0),
                            .d(pmp_d), .ok(sh_okw), .hit(sh_hit), .rwx(sh_rwx));
  logic unused_sh;
  assign unused_sh = ^{sh_hit, sh_rwx};
  always_ff @(posedge clk)
    if (!rst && f1_live && xl_i && it_hit[0] && it_pte[0].ph)
      assert (sh_okw == {NW{it_pte[0].px}})
        else $error("tg_fetch: a block's cached PMP result (x %b) differs from the full check (%b) at PA %h",
                    it_pte[0].px, sh_okw, {it_pte[0].ppn, fpc_q[11:4], 4'b0});
`endif

  // ---- I$ arrays ----
  logic                rf_we;
  logic [WAY_W-1:0]    rf_way;
  logic [ROW_W-1:0]    rf_row;
  logic [127:0]        rf_data;
  logic                tag_we;
  logic [SET_W-1:0]    tag_set;
  logic [TAG_W-1:0]    tag_wd;
  // The arrays' writes: the demand refill's (rf_*, tag_*) or, with IPF_ON, the prefetch's beats (pf_we) and the
  // validation of a prefetched line (pv_go); one at a time (one D beat a cycle; a validation is a demand miss
  // that starts no refill)
  logic                dw_we, tw_we;
  logic [WAY_W-1:0]    dw_way, tw_way;
  logic [ROW_W-1:0]    dw_row;
  logic [SET_W-1:0]    tw_set;
  logic [TAG_W-1:0]    tw_wd;

  logic                f2_go;            // F1 may move into F2 this cycle
  logic                f2_ld;            // ... and does (not in a cycle of F2's action): the F2-side reads
  logic [WAYS-1:0][127:0] way_data;      // F2: data of the block read in F1
  logic [WAYS-1:0][TAG_W-1:0] tag_rd;    // F1
  for (genvar w = 0; w < WAYS; w++) begin : g_way
    tg_ram_sdp #(.DEPTH(ROWS), .WIDTH(128), .OUT_REG(1'b0), .PRIM("block")) u_data (
      .clk, .we(dw_we && dw_way == WAY_W'(w)), .waddr(dw_row), .wdata(rf_data),
      .re(f2_ld), .raddr(fpc_q[4 +: ROW_W]), .rdata(way_data[w]));
    logic [0:0][SET_W-1:0] ra;
    logic [0:0][TAG_W-1:0] rd;
    assign ra[0] = fpc_q[6 +: SET_W];
    tg_ram_lut #(.DEPTH(SETS), .WIDTH(TAG_W), .NR(1)) u_tag (
      .clk, .we(tw_we && tw_way == WAY_W'(w)), .waddr(tw_set), .wdata(tw_wd), .raddr(ra),
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
  logic              k_room_q;            // MT (5e): park on its queue's room (qw_s_q), the bound kn_q
  logic [4:0]        kn_q;
  // TAGE_ON: the override refetches at the exit's target (kt_q): the block's address, the exit's
  // parcel (kp_q) and its offset (kimm_q), added in the action's cycle
  logic              kt_q;
  logic              kr_q;                // RAS_FE: ... at the stack's top, krt_q (ITT_ON: or the table's target, kit_q)
  logic              ki_q;                // ITT_ON: ... kr_q's target is the table's (kit_q), not the stack's top
  logic              ks_q;                // TAGE_ON: ... the exit is a straddler (PC: the block - 2)
  logic [38:1]       krt_q;              // (A, spikes.md §7.1: the stack's top, which fx_tgt is under kr_q)
  logic [38:1]       kit_q;              // ITT_ON: the table's target, kept beside it and selected after the register
                                         // (as A: spikes-2's 10-24 run had the select's 21 levels from the I$ data)
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
  logic [63:0] miss_pc_q;          // F2's block, for its action (and a parking stream's PC and PA)
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
  logic               fx_tk, fx_nj, fx_nhs;   // ... its terms (E, spikes.md §7.1: ANDed after F3's register)
  logic               f2_ovr;             // the prediction differs from what F1 followed: refetch,
  logic               f2_ka;              // F2 acts on a delivered block: a cut, a fault or a refetch
  logic               ovr_tk;             // ... at the exit's target (the exit's first parcel ovr_p)
  logic [SLOT_W-1:0]  ovr_p;              //     or else at the next block
  logic               uok;                // the micro-BTB's prediction is a real exit
  logic [63:0]        fx_tgt;             // the exit's target in the queue (a JALR's)
  logic               ovr_ras;            // RAS_FE: ... the exit is a return to the stack's top
  logic               ovr_itt;            // ITT_ON: ... the exit is a JALR to the indirect-target table's target
  logic               f2_ijx;             // ITT_ON: F2's exit is a JALR that is not a return (the path history's)
  // ITT_ON: the indirect-target table's entry for F2's block (g_itt): a hit, its slot and its target
  logic               itt_hit;
  logic [SLOT_W-1:0]  itt_slot;
  logic [38:1]        itt_tgt;
  // ITT_ON: the entry's key checked at F1 (hit, slot), and the predicted JALR slot F2's exit search takes: the
  // table's where it hits, else the micro-BTB's, registered beside f2_hit_q and f2_slot_q (the decision's depth)
  logic               itt_hit1;
  logic [SLOT_W-1:0]  itt_slot1;
  logic               phit_q;
  logic [SLOT_W-1:0]  pslot_q;
  logic               ovr_s;              // TAGE_ON: ... the exit is a straddler (its PC: the block - 2)
  logic [20:0]        ovr_imm;            // ... the exit's offset
  logic               f2_rpush, f2_rpop;  // RAS_FE: the exit's stack operation, and a push's link
  logic [38:1]        f2_rlink;
  assign uok = hp;
  logic [1:0]         gh_n, gh_b;         // TAGE_ON: the history bits the block adds (count, values)
  logic [NP-1:0]      gh_cm, gh_pk;       // ... its conditional branches' slots and directions
  // ... F2's raw terms for them, registered in g_tage (spikes §8.18), by parcel unless noted:
  logic [NP-1:0]      gh_mb;              // the branches that count if within the block
  logic [NP-1:0]      gh_lm;              // the block's limit (lim)
  logic [NP-1:0]      gh_xm;              // the exit (feh)
  logic [NP-1:0]      gh_wd;              // the wide parcels
  logic               gh_c3;              // the third branch's cut without the PMP check (c3_v && !f2_chk)
  logic               gh_sb;              // the straddler's branch, counted
  logic               gh_sx;              // the straddler is the exit
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
    assign fx_tk   = 1'b0;
    assign fx_nj   = 1'b1;
    assign fx_nhs  = 1'b1;
    assign f2_ovr  = f2_hit_q && !pred_ok;
    assign f2_ka   = pmp_cut || (f2_ovr && !f2_isf0) || f2_isfault;
    assign ovr_tk  = 1'b0;
    assign ovr_p   = '0;
    assign gh_n    = '0;
    assign gh_b    = '0;
    assign gh_cm   = '0;
    assign gh_pk   = '0;
    assign gh_mb   = '0;
    assign gh_lm   = '0;
    assign gh_xm   = '0;
    assign gh_wd   = '0;
    assign gh_c3   = 1'b0;
    assign gh_sb   = 1'b0;
    assign gh_sx   = 1'b0;
    assign fx_tgt  = f2_tgt_q;
    assign ovr_ras = 1'b0;
    assign ovr_itt = 1'b0;
    assign f2_ijx  = 1'b0;
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
    // The indirect-target table's entry (ITT_ON), by its last parcel's slot. The exit search takes one predicted
    // JALR slot, as without the table: the table's where its key matched at F1, else the micro-BTB's, from registers
    // loaded with f2_hit_q and f2_slot_q (phit_q, pslot_q), so each slot's taken term has the table-off inputs and
    // timing. A hit inside the taken terms put fetch's decision 4-6 levels deeper from the I$ data (spikes-2's 10-24
    // runs of 1f5f9e18 and 188328af), and a slot chosen on the RAM's output still 2-4 (a6f51752). Where the exit is a
    // JALR at the entry's slot (the stack's top first), its target is the entry's; the exit's kind (xitt) is found
    // after the search, beside the stack's (xras). The micro-BTB's own check (sm, xovr) stays on its slot: F1
    // followed its target
    logic [NP-1:0]     ith;
    logic [63:0]       itgt;
    logic              phit;
    logic [SLOT_W-1:0] pslot;
    assign itgt  = {{25{itt_tgt[38]}}, itt_tgt, 1'b0};
    assign phit  = ITT_ON ? phit_q : f2_hit_q;
    assign pslot = ITT_ON ? pslot_q : f2_slot_q;
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
      // candidate does not wait for uok, the whole block's check (at the table's slot: its tag and privilege)
      logic hs;                                   // the predicted JALR slot (the table's, else the micro-BTB's)
      assign hs = phit && (wide[p] ? pslot == SLOT_W'(p + 1) : pslot == SLOT_W'(p));
      assign ith[p]  = ITT_ON && itt_hit && itt_slot == lsl[p];
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
    logic xjalr, xras, xcall, xpop, xcbr, xitt, sm;
    logic [3:0] xoff;                              // the exit's link, in halfwords from the block
    always_comb begin
      xjalr   = 1'b0;
      xras    = 1'b0;
      xitt    = 1'b0;
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
          xitt    = xitt  || (pd_jalr[p] && ith[p]);
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
        xitt    = 1'b0;                    // (only the stack takes a straddler)
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
    assign fx_tk   = tk;
    assign fx_nj   = !xjalr;
    assign fx_nhs  = !(f2_hit_q && sm);
    // f2_ka, F2's action without the delivery: its terms absorb f2_ovr's gates (timing)
    logic fe_ras, fe_itt, xovr;
    assign fe_ras  = tk && xras;
    assign fe_itt  = tk && xitt;
    // (at the micro-BTB's slot the table's target refetches when it is not the micro-BTB's, as the stack's top)
    assign xovr    = (fe_s || fe_v) ? !(f2_hit_q && sm && (!xras || f2_tgt_q == rtgt) && (!xitt || f2_tgt_q == itgt))
                                    : f2_hit_q;
    assign f2_ovr  = !isf && !pcut && !ccut && xovr;
    assign f2_ka   = pcut || ccut || isf || xovr;
    assign ovr_tk  = tk;
    assign ovr_p   = fe_p;
    assign ovr_s   = fe_s;
    // the exit's offset, for the refetch at its target
    always_comb begin
      logic [NP-1:0][20:0] im;
      for (int p = 0; p < NP; p++) im[p] = br_imm({parcel[(p + 1) % NP], parcel[p]}, pd_jal[p]);
      // (E, spikes.md §7.1: no default for a block without an exit: kimm_q is read only under kt_q, a taken exit)
      ovr_imm = '0;
      for (int p = 0; p < NP; p++) if (feh[p]) ovr_imm = ovr_imm | im[p];
      if (fe_s) ovr_imm = br_imm(sx, sx_jal);
    end
    assign ovr_ras = fe_ras;
    assign ovr_itt = fe_itt;
    assign f2_ijx  = tk && xjalr && !xpop;
    assign fx_tgt  = fe_ras ? rtgt : fe_itt ? itgt : f2_tgt_q;
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
    // The same, as raw terms registered at the delivery (g_tage forms the count, the bit and the slots from them a
    // cycle later): bcb[p] is gh_mb[p] && (gh_lm[p] || gh_c3), bs's terms for a branch (a branch starts its parcel).
    // No tk: a counted branch at the exit is the taken exit (counted means no fault and no PMP cut at or before it,
    // which is all tk adds to fe_v there), and a counted straddler at the exit likewise
    for (genvar p = 0; p < NP; p++) begin : g_ghr
      assign gh_mb[p] = !isf && cbr[p] && !cutm[p];
    end
    assign gh_lm = lim;
    assign gh_c3 = c3_v && !f2_chk;
    assign gh_xm = feh;
    assign gh_wd = wide;
    assign gh_sb = !isf && sx_br;
    assign gh_sx = fe_s;
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
          ujx      = pd_start[p] && !o && (pd_jal[p] || (pd_jalr[p] && (r_rp[p] ||
                     ((ITT_ON && itt_hit) ? itt_slot == lsl[p] : uok && f2_slot_q == lsl[p]))));
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
      logic        r_fx_tsrc, r_fe_ras, r_fe_itt, r_ovr, r_rpush, r_rpop;
      logic [20:0] r_imm;
      logic [38:1] r_rlink;
      logic [63:0] r_tgt;
      assign r_fe_ras  = r_tk && (fe_s ? RAS_FE && sx_pop && ras_v : r_rp[r_fe_p]);
      assign r_fe_itt  = r_tk && ITT_ON && itt_hit && !fe_s && pd_jalr[r_fe_p] && itt_slot == lsl[r_fe_p];
      assign r_ovr     = !r_isf && !r_pcut && !r_ccut &&
                         (r_tk ? !(f2_hit_q && f2_slot_q == r_fx_slot && (!r_fe_ras || f2_tgt_q == rtgt) &&
                                   (!r_fe_itt || f2_tgt_q == itgt)) : f2_hit_q);
      // the exit's own target only where F2 refetches there
      assign r_fx_tsrc = r_tk && (fe_s ? !sx_jalr : !pd_jalr[r_fe_p]) && r_ovr;
      always_comb begin
        logic [31:0] x;
        x = {parcel[(int'(r_fe_p) + 1) % NP], parcel[r_fe_p]};
        r_imm = fe_s ? br_imm(sx, sx_jal) : br_imm(x, pd_jal[r_fe_p]);
      end
      assign r_tgt   = r_fe_ras ? rtgt : r_fe_itt ? itgt : f2_tgt_q;
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
                  r_ovr == f2_ovr && (!r_tk || r_imm == ovr_imm) && r_tgt == fx_tgt && r_rpush == f2_rpush &&
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
  // B and E (spikes.md §7.1): the exit's target is selected, and tsrc ANDed, after F3's register: F3 keeps F2's
  // target, whether the exit returns to the stack's top, the top, and tsrc's three terms
  logic                 f3_ras_q, f3_tk_q, f3_nj_q, f3_nhs_q;
  logic [38:1]          f3_rtop_q;
  logic                 f3_itt_q;                  // ITT_ON: under f3_ras_q the table's target (f3_itgt_q), else the top
  logic [38:1]          f3_itgt_q;
  meta_t                f3_mq;                     // the block's metadata as the queue takes it
  always_comb begin
    f3_mq        = f3_meta_q;
    f3_mq.target = !f3_ras_q ? f3_meta_q.target
                 : f3_itt_q  ? {{25{f3_itgt_q[38]}}, f3_itgt_q, 1'b0} : {{25{f3_rtop_q[38]}}, f3_rtop_q, 1'b0};
    f3_mq.tsrc   = f3_tk_q && f3_nj_q && f3_nhs_q;
  end
`ifndef SYNTHESIS
  // the values F2 selected before B and E: the queue takes the same
  logic [63:0] f3_tgt_ref_q;
  logic        f3_tsrc_ref_q;
  always_ff @(posedge clk) begin
    if (f2v && f3_accept) begin
      f3_tgt_ref_q  <= fx_tgt;
      f3_tsrc_ref_q <= fx_tsrc;
    end
    if (!rst && f3_valid_q)
      assert (f3_mq.target == f3_tgt_ref_q && f3_mq.tsrc == f3_tsrc_ref_q)
        else $error("tg_fetch: F3's target or tsrc differs from F2's selection");
  end
`endif
  // A fault block's parcels go to the queue as zeros: zeroed here, from the registered fault bit,
  // so F2's late fault decision does not drive the parcel registers' resets
  assign f3_parcel = f3_meta_q.fault ? '0 : f3_parcel_q;
  logic                 blk_ready;
  logic                 f3_accept;
  assign f3_accept = !f3_valid_q || blk_ready;

  logic [DECODE_WIDTH-1:0]           cq_valid;
  logic [DECODE_WIDTH-1:0][IB_W-1:0] cq_insn;
  logic                              redirect;     // any stream's
  tid_t                              cq_tid;       // the thread whose queue decode reads
  assign redirect = flush || dred;
  // Redirects per stream (M7's step 5b): a flush (commit's) and decode's redirect may come in one cycle for different
  // threads, and each applies to its own stream; for one stream the flush wins, as before
  logic [NS-1:0]       fl_s, dr_s, red_s;
  logic [NS-1:0][63:0] red_pc_s;
  always_comb
    for (int t = 0; t < NS; t++) begin
      fl_s[t]     = flush && strm(flush_tid) == 1'(t);
      dr_s[t]     = dred && strm(dred_tid) == 1'(t) && !fl_s[t];
      red_s[t]    = fl_s[t] || dr_s[t];
      red_pc_s[t] = fl_s[t] ? flush_pc : dred_pc;
    end
  logic [NUM_THREADS-1:0] red_q;                    // the queues the redirects empty (by stream)
  assign red_q = NUM_THREADS'(red_s);
  logic [NUM_THREADS-1:0][idx_w(IBUF_ENTRIES):0] q_occ;   // MT (5e): each thread's queue entries (u_cmp)
  tg_fetch_compact #(.WR(4), .RD(DECODE_WIDTH), .DEPTH(IBUF_ENTRIES), .META_W(META_W)) u_cmp (
    .clk, .rst, .flush_q(red_q), .drop_t(MT ? rn_block : '0), .acc_t(MT ? rn_acc : '1), .dst,
    .blk_valid(f3_valid_q), .blk_tid(f3_tid), .parcel(f3_parcel), .start(f3_start_q), .marks(f3_marks_q),
    .carry_out(f3_carry_q), .meta(f3_mq),
    .blk_ready, .out_tid(cq_tid), .out_valid(cq_valid), .out_insn(cq_insn), .take(iq_take), .take_t(iq_take_t), .take_n(iq_take_n), .tk(de_take),
    .tz_t(iq_tnz_t), .tz_n(iq_tnz_n),
    .occ_o(q_occ));

  // ---- Pipeline control ----
  // F2 delivers when it is valid, not missing, and F3 can take the block. It holds while F3
  // cannot, missing or not: its action is registered anyway.
  logic f2_deliver, f2_hold;
  logic ft_full;                          // TAGE_ON: no FTQ entry for another block
  // MT (5e): F2 passes a block on only if it fits its thread's queue beside that thread's block in F3, each counted
  // at a bound from registers (the parcels from the block's entry, and a straddler's completion), while the other
  // stream waits for the pipe (its block in F1, or its next one waiting). Else the stream parks here as on an I$ miss,
  // the block undelivered (no FTQ entry, its later blocks dropped), and restarts at it once its queue has the room:
  // a queue that cannot take a block never holds F3, and with it the other thread's fetch (smt2_report §13.16: 7-14%
  // at step 7). Without a waiting stream it goes on and waits in F3 as before, so a lone thread fetches as before.
  // Only a thread whose queue decode has not read for QP_WAIT cycles while it held instructions parks (its RN register
  // holds a stalled group, so its queue does not drain): a thread whose queue drains waits in F3 a cycle or two as
  // before, which costs less than a park's refetch (compute pairs lost 0.01-0.05 when every such block parked)
  localparam int QP_WAIT = 2;
  logic [4:0] f2_need, f3_need_q;
  logic       f2_cont, f2_qfull;
  logic [NUM_THREADS-1:0][2:0] qs_q;        // cycles since decode last took from the thread's queue, while it held some
  always_ff @(posedge clk)
    for (int t = 0; t < NUM_THREADS; t++)
      if (rst || !MT || q_occ[t] == '0 || (cq_tid == tid_t'(t) && iq_take != '0)) qs_q[t] <= '0;
      else if (qs_q[t] != 3'd7)                                                  qs_q[t] <= qs_q[t] + 3'd1;
  assign f2_need  = 5'(NP) - 5'(f2_pc_q[SLOT_W:1]) + 5'(carry_q);
  assign f2_cont  = (f1_valid_q && ft_q != f2_s_q && !stop_s_q[ft_q] && !blk_s[ft_q]) ||
                    (sv_s_q[!f2_s_q] && !blk_s[!f2_s_q]);
  assign f2_qfull = MT && f2v && !f2_miss && !f2_wmiss && !blk_s[f2_s_q] && f2_cont &&
                    int'(qs_q[MT ? f2_s_q : 1'b0]) >= QP_WAIT &&
                    int'(q_occ[MT ? f2_s_q : 1'b0]) + int'(f2_need) +
                    ((f3_valid_q && f3_s_q == f2_s_q) ? int'(f3_need_q) : 0) > IBUF_ENTRIES;
  assign f2_deliver = f2v && !f2_miss && !f2_wmiss && f3_accept && !ft_full && !f2_qfull;
  assign f2_hold    = f2v && (!f3_accept || ft_full || f2_qfull);
  // F1 moves on when F2 is free (or delivers) and fetch is not parked, stopped or waiting for the
  // PMP descriptors, the valid-bit sweep or its own PMP check (f1_pwait).
  assign f1_base = f1_valid_q && !miss_s_q[ft_q] && !wk_s_q[ft_q] && !qw_s_q[ft_q] && !stop_q && ready && !pmp_busy &&
                   ivs_done;
  assign f1_live = f1_base && !f1_pwait && !f1_cwait;
  assign f2_go   = !f2_hold && !redirect;
  // (in F2's action's cycle F2 takes nothing from F1: with MT it may keep the other stream's block, whose I$ data and
  // TAGE reads must stay; without MT F2 holds nothing then, so the reads were unused)
  assign f2_ld   = f2_go && !ka_q;
  logic f2_override;                     // F2's prediction is not F1's: refetch (f2_ovr)
  // (f2_isf0, not f2_isfault: with the micro-BTB alone, when its prediction stands the term is zero
  // anyway, and otherwise f2_isfault is isf_h[0]; so the override does not wait for the pick by hp)
  assign f2_override = f2_deliver && f2_ovr && !f2_isf0;
  logic am_go, aw_go;                    // F2's miss or ITLB miss of last cycle parks its stream (k_s_q) now
  assign am_go  = ka_q && k_miss_q;
  assign aw_go  = ka_q && k_walk_q;
  // The fetch walk, one at a time: a parked stream whose walk was not taken (stream 0 first: it waited longer than one
  // parking now), else the stream parking now; a parking stream's PC is miss_pc_q in its cycle, rpc_s_q after
  logic [NS-1:0] wreq, wout;             // a stream's walk waits to be taken; is out
  logic          ws, wo;                 // the stream whose request is presented; whose walk is out
  always_comb
    for (int t = 0; t < NS; t++) begin
      wreq[t] = wk_s_q[t] && !wk_sent_s_q[t];
      wout[t] = wk_s_q[t] && wk_sent_s_q[t];
    end
  assign ws     = (MT && |wreq) ? !wreq[0] : aw_go ? k_s_q : 1'b0;
  assign wo     = MT && !wout[0];
  assign iw_req = !(|wout) && (aw_go || |wreq);
  assign iw_va  = (aw_go && ws == k_s_q && !(MT && |wreq)) ? miss_pc_q : rpc_s_q[ws];
  assign iw_tid = MT ? tid_t'(ws) : RUN_TID;
  // The miss the refill engine serves: a stream already parked (stream 0 first: it waited longer), else the stream
  // parking now (am_go, miss_pa_q). With MT a refill's end restarts the streams parked on its line, and the others
  // stay parked for the engine (no starvation by the other stream's misses); with one stream any refill's end
  // restarts it, as before
  logic            ms;                   // its stream
  logic [PA_W-1:0] mpa;                  // its block's PA
  logic            miss_any;
  assign miss_any = |miss_s_q;
  assign ms  = (MT && miss_any) ? !miss_s_q[0] : am_go ? k_s_q : 1'b0;
  assign mpa = (am_go && ms == k_s_q && !(MT && miss_any)) ? miss_pa_q : rpa_s_q[ms];
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
    localparam int SB  = MT ? 1 : 0;      // the stream's bit in the FTQ's addresses and TAGE's queue (M7)
    logic [IXW-1:0]  tix;
    // Per stream (M7): the speculative history, its pending bits, commit's history, the FTQ's pointers. A delivered
    // block's history bits go in a cycle later: gh_e, the history with them, is what every reader takes, as gh_q was.
    // Only a block's last branch can be taken (its exit), so the bits are a count and one value. Timing (spikes
    // §8.18): F2's decision ends at its raw terms (hr_*_q); the count, the bit and the block's branch slots and
    // directions (u_fbr's data) are formed from them in the next cycle, in front of gh_e's shift
    logic [NS-1:0][GH_W-1:0] gh_s_q, cgh_s_q, gh_e_s;
    logic [NS-1:0]           gw_s_q;                  // the stream's block was delivered last cycle: its bits pend
    logic [NP-1:0]           hr_mb_q, hr_lm_q, hr_xm_q, hr_wd_q;   // F2's raw terms (gh_*)
    logic                    hr_c3_q, hr_sb_q, hr_sx_q;
    logic [NP-1:0]           hr_bm;                   // the counted branches by parcel (F2's bcb)
    logic [NP-1:0]           hr_cm, hr_pk;            // the block's branch slots and directions (F2's gh_cm, gh_pk)
    logic [1:0]              hr_n;                    // the count (F2's gh_n): at most two, a third branch cuts
    logic                    hr_b;                    // the newest bit (gh_b[0]): the exit is a taken branch
    always_ff @(posedge clk) begin
      hr_mb_q <= gh_mb;
      hr_lm_q <= gh_lm;
      hr_xm_q <= gh_xm;
      hr_wd_q <= gh_wd;
      hr_c3_q <= gh_c3;
      hr_sb_q <= gh_sb;
      hr_sx_q <= gh_sx;
    end
    assign hr_bm = hr_mb_q & (hr_lm_q | {NP{hr_c3_q}});
    always_comb begin
      logic n1, n2;
      hr_cm    = '0;
      hr_pk    = '0;
      hr_cm[0] = hr_sb_q;
      hr_pk[0] = hr_sb_q && hr_sx_q;
      for (int p = 0; p < NP; p++)
        if (hr_bm[p]) begin
          hr_cm[SLOT_W'(hr_wd_q[p] ? p + 1 : p)] = 1'b1;
          if (hr_xm_q[p]) hr_pk[SLOT_W'(hr_wd_q[p] ? p + 1 : p)] = 1'b1;
        end
      n1 = hr_sb_q;
      n2 = 1'b0;
      for (int p = 0; p < NP; p++) begin
        n2 = n2 || (n1 && hr_bm[p]);
        n1 = n1 || hr_bm[p];
      end
      hr_n = n2 ? 2'd2 : n1 ? 2'd1 : 2'd0;
      hr_b = (hr_sb_q && hr_sx_q) || |(hr_bm & hr_xm_q);
    end
    always_comb
      for (int t = 0; t < NS; t++)
        gh_e_s[t] = (!gw_s_q[t] || hr_n == 2'd0) ? gh_s_q[t]
                  : (hr_n == 2'd1) ? {gh_s_q[t][GH_W-2:0], hr_b} : {gh_s_q[t][GH_W-3:0], 1'b0, hr_b};
`ifndef SYNTHESIS
    // (spikes §8.18's retiming) the count, the bit and the slots formed a cycle later equal F2's own on every
    // delivered block (the bit where the count is not zero)
    logic          ck_v_q, ck_b_q;
    logic [1:0]    ck_n_q;
    logic [NP-1:0] ck_cm_q, ck_pk_q;
    always_ff @(posedge clk) begin
      ck_v_q  <= !rst && ft_we;
      ck_n_q  <= gh_n;
      ck_b_q  <= gh_b[0];
      ck_cm_q <= gh_cm;
      ck_pk_q <= gh_pk;
      if (ck_v_q && !rst)
        assert (hr_n == ck_n_q && hr_cm == ck_cm_q && hr_pk == ck_pk_q && (ck_n_q == 2'd0 || hr_b == ck_b_q))
          else $error("tg_fetch: the history's terms formed a cycle later differ from F2's");
    end
`endif
    // FTQ pointers, with a wrap bit, per stream; a delivery takes its stream's tail. TAGE's training queue names the
    // blocks of its requests (commit's, with their wrap bits and streams), and its head's indices and tags are read
    // from here: no entry is freed while the queue names it (each stream's oldest in the queue, ft_eh_s)
    logic [NS-1:0][FTQW:0] ft_t_s_q, ft_h_s_q, ft_eh_s;
    function automatic logic [SB+FTQW:0] fqp(input logic st, input logic [FTQW:0] p);   // {stream, wrap, index}
      return MT ? (SB + FTQW + 1)'({st, p}) : (SB + FTQW + 1)'(p);
    endfunction
    function automatic logic [SB+FTQW-1:0] fqa(input logic st, input logic [FTQW-1:0] i);   // {stream, index}
      return MT ? (SB + FTQW)'({st, i}) : (SB + FTQW)'(i);
    endfunction
    logic                         cs;      // commit's stream
    assign cs = strm(c_tid);
    logic                         ft_we;
    logic                         tq_v;
    logic [SB+FTQW:0]             tq_ftq;
    logic [3:0][SB+FTQW:0]        tq_all;
    logic [2:0]                   tq_n;
    logic [COMMIT_WIDTH-1:0][SB+FTQW:0] c_fp;
    logic [0:0][SB+FTQW-1:0]      fq_ra;
    logic [0:0][IXW-1:0]          fq_rd;
    always_comb
      for (int j = 0; j < COMMIT_WIDTH; j++)
        c_fp[j] = fqp(cs, {(c_ftq[j] < ft_h_s_q[cs][FTQW-1:0]) ^ ft_h_s_q[cs][FTQW], c_ftq[j]});
    // TAGE reads with F1's stream's history; its index and tag hashes take the stream as the block address's top
    // bit (two threads' blocks at one address use different entries; without MT the address as it is)
    logic [38:4] tblk;
    assign tblk = fpc_q[38:4] ^ {MT && ft_q, 34'b0};
    tg_tage #(.NP(NP), .CW(COMMIT_WIDTH), .NT(TAGE_NT), .LI(TAGE_LI), .TW(TAGE_TW), .BI(TAGE_BI), .HW(GH_W),
              .FW(SB + FTQW + 1)) u_tage (
      .clk, .rst, .re(f2_ld), .blk(tblk), .gh(gh_e_s[ft_q]), .dir(tdir), .ix(tix),
      .t_v(c_cbr), .t_ftq(c_fp), .t_slot(c_slot), .t_taken(c_taken), .t_pred(c_pred),
      .q_v(tq_v), .q_ftq(tq_ftq), .q_ix(fq_rd[0]), .q_all(tq_all), .q_n(tq_n));
    always_comb
      for (int t = 0; t < NS; t++) begin
        logic found;
        found      = 1'b0;
        ft_eh_s[t] = ft_h_s_q[t];
        for (int k = 0; k < 4; k++)
          if (!found && 3'(k) < tq_n && (!MT || tq_all[k][SB+FTQW] == 1'(t))) begin
            ft_eh_s[t] = tq_all[k][FTQW:0];
            found      = 1'b1;
          end
      end
    // (a blocked stream's block takes no entry: its FTQ may be full of the older instructions' blocks)
    assign ft_full = ft_t_s_q[f2_s_q][FTQW] != ft_eh_s[f2_s_q][FTQW] &&
                     ft_t_s_q[f2_s_q][FTQW-1:0] == ft_eh_s[f2_s_q][FTQW-1:0] && !blk_s[f2_s_q];
    assign ft_tail = ft_t_s_q[f2_s_q][FTQW-1:0];
    // (MT: in another stream's redirect cycle F2's block goes on to F3, so it takes its entry: only its own
    // stream's redirect stops it; without MT the one redirect)
    assign ft_we   = f2_deliver && !red_s[f2_s_q] && !blk_s[f2_s_q];
    // (and the return-address stack's pointer, count and top before the block, RAS_FE)
    localparam int RW  = GH_W + 2 * NP + RAS_PW + RAS_PW + 1 + 38;
    localparam int RWA = GH_W + RAS_PW + RAS_PW + 1 + 38;     // written on time: the history, the stack's state
    logic [0:0][SB+FTQW-1:0] fr_ra;
    logic [0:0][RW-1:0]   fr_rd;
    logic [0:0][RWA-1:0]  fra_rd;
    logic [0:0][2*NP-1:0] frb_rd;
    assign fr_ra[0] = fqa(strm(dred_tid), dred_ftq);
    tg_ram_lut #(.DEPTH(FTQ_ENTRIES << SB), .WIDTH(RWA), .NR(1)) u_fgh (
      .clk, .we(ft_we), .waddr(fqa(f2_s_q, ft_tail)), .wdata({gh_e_s[f2_s_q], ras_tos, ras_cnt, ras_top}),
      .raddr(fr_ra), .rdata(fra_rd));
    // D (spikes.md §7.1): the block's branch slots and directions (gh_cm, gh_pk) go into their own LUTRAM a cycle
    // later, off F2's decision, formed from its raw terms (hr_cm, hr_pk, above): decode's redirect reads a block's
    // entry three cycles after its delivery at the earliest (F3 writes the queue, decode decodes, its redirect is
    // registered)
    logic                 fb_we_q;
    logic [SB+FTQW-1:0]   fb_wa_q;
    always_ff @(posedge clk) begin
      fb_we_q <= !rst && ft_we;
      fb_wa_q <= fqa(f2_s_q, ft_tail);
    end
    tg_ram_lut #(.DEPTH(FTQ_ENTRIES << SB), .WIDTH(2 * NP), .NR(1)) u_fbr (
      .clk, .we(fb_we_q), .waddr(fb_wa_q), .wdata({hr_cm, hr_pk}), .raddr(fr_ra), .rdata(frb_rd));
    assign fr_rd[0] = {fra_rd[0][RWA-1 -: GH_W], frb_rd[0], fra_rd[0][RWA-GH_W-1:0]};
    // the stack's operation at a delivered block's exit, and its repair at decode's redirect
    assign ras_push = ft_we && !f2_isfault && f2_rpush;
    assign ras_pop  = ft_we && !f2_isfault && f2_rpop;
    assign ras_link = f2_rlink;
    assign ras_rv   = RAS_FE && |dr_s;          // (decode's redirect, unless its stream is flushed too)
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
    assign fq_ra[0] = fqa(MT && tq_ftq[SB+FTQW], tq_ftq[FTQW-1:0]);
    tg_ram_lut #(.DEPTH(FTQ_ENTRIES << SB), .WIDTH(IXW), .NR(1)) u_fix (
      .clk, .we(ft_we), .waddr(fqa(f2_s_q, ft_tail)), .wdata(tix), .raddr(fq_ra), .rdata(fq_rd));
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
        gh_s_q   <= '0;
        gw_s_q   <= '0;
        cgh_s_q  <= '0;
        ft_t_s_q <= '0;
        ft_h_s_q <= '0;
      end else begin
        for (int t = 0; t < NS; t++) begin
          logic [GH_W-1:0] c;
          c = cgh_s_q[t];
          if (cs == 1'(t)) for (int j = 0; j < COMMIT_WIDTH; j++) if (c_cbr[j]) c = {c[GH_W-2:0], c_taken[j]};
          cgh_s_q[t] <= c;
          if (fl_s[t]) begin                  // (nothing of the stream retires in its flush's cycle)
            gh_s_q[t]   <= cgh_s_q[t];
            gw_s_q[t]   <= 1'b0;
            // every block goes; the training queue may still name the head's and earlier ones
            ft_t_s_q[t] <= ft_h_s_q[t] + 1'b1;
            ft_h_s_q[t] <= ft_h_s_q[t] + 1'b1;
          end else begin
            if (dr_s[t]) begin
              gh_s_q[t]   <= r_gh;
              gw_s_q[t]   <= 1'b0;
            end else begin
              gh_s_q[t]   <= gh_e_s[t];
              gw_s_q[t]   <= ft_we && f2_s_q == 1'(t);
            end
            // decode's redirect keeps its instruction's block and drops the later ones; commit frees
            // the blocks before the youngest retiring instruction's
            if (dr_s[t])
              ft_t_s_q[t] <= {(dred_ftq < ft_h_s_q[t][FTQW-1:0]) ^ ft_h_s_q[t][FTQW], dred_ftq} + 1'b1;
            else if (ft_we && f2_s_q == 1'(t))
              ft_t_s_q[t] <= ft_t_s_q[t] + 1'b1;
            if (c_hv && cs == 1'(t))
              ft_h_s_q[t] <= {(c_hftq < ft_h_s_q[t][FTQW-1:0]) ^ ft_h_s_q[t][FTQW], c_hftq};
          end
        end
      end
    end
    // ---- The indirect-target table (ITT_ON; core-pipeline.md §3.2) ----
    // Per stream: the speculative path history (ph_s_q; a delivered block's JALR exit goes in a cycle later, ph_e_s the
    // history with it, as gh_e_s) and commit's (cph_s_q). A flush copies commit's into it; decode's redirect restores
    // the history the redirecting block's lookup used, which the FTQ keeps (u_fil) and training writes with, so lookup
    // and training agree (a block fetched right behind a JALR's block is looked up without that JALR).
    if (ITT_ON) begin : g_itt
      localparam int PW = ITT_PHW;
      localparam int IRW = (ITT_MODE == 2 ? 2 * 7 : 8) + 8;   // the table's coordinates (tg_itt's RIW)
      localparam int JW = idx_w(COMMIT_WIDTH);
      // the history after a JALR: shifted left by 4 (h, the bits that stay), its target's bits 17:2 in (the model's)
      function automatic logic [PW-1:0] padd(input logic [PW-5:0] h, input logic [15:0] t);
        return {h, 4'b0} ^ t;
      endfunction
      logic [NS-1:0][PW-1:0] ph_s_q, ph_e_s, cph_s_q, cph_n;
      logic                  ipw_q;               // a JALR exit delivered last cycle: it pends ...
      logic                  ips_q;               // ... in this stream,
      logic                  ipi_q;               // ... to the table's target, else the micro-BTB's: their bits 17:2,
      logic [15:0]           ipt_q, ipx_q;        // registered apart and selected after (timing: as kit_q)
      logic [PW-1:0]         ilk_q;               // the history F2's block's lookup used
      logic [IRW-1:0]         iri;                 // ... and the coordinates it read (tg_itt's, registered with it)
      // the table's write (registered): the coordinates the jump's block read, its slot, its privilege, its target
      logic                  iw_q, iwu_q;
      logic [IRW-1:0]         iwr_q;
      logic [SLOT_W-1:0]     iws_q;
      logic [38:1]           iwt_q;
      always_comb
        for (int t = 0; t < NS; t++)
          ph_e_s[t] = (ipw_q && ips_q == 1'(t)) ? padd(ph_s_q[t][PW-5:0], ipi_q ? ipx_q : ipt_q) : ph_s_q[t];
      tg_itt #(.MODE(ITT_MODE), .NP(NP), .HW(PW)) u_itt (
        .clk, .re(f2_ld), .blk(tblk), .ph(ph_e_s[ft_q]), .pu(priv == PRIV_U),
        .hit1(itt_hit1), .slot1(itt_slot1), .hit(itt_hit), .slot(itt_slot), .tgt(itt_tgt), .ri(iri),
        .we(iw_q), .w_ri(iwr_q), .w_pu(iwu_q), .w_slot(iws_q), .w_tgt(iwt_q));
      always_ff @(posedge clk) begin
        ipw_q <= !rst && ft_we && f2_ijx;
        ips_q <= f2_s_q;
        ipi_q <= ovr_itt;                         // (a JALR exit that is not a return: never the stack's top)
        ipt_q <= f2_tgt_q[17:2];
        ipx_q <= itt_tgt[17:2];
        if (f2_ld) ilk_q <= ph_e_s[ft_q];
      end
      // The FTQ keeps each block's lookup: its history (u_fil; decode's redirect restores it) and the coordinates it
      // read (u_fri; training writes there), the latter read for the group's last retiring instruction (jp), the one
      // that can pend
      logic [JW-1:0] jp;
      logic [PW-1:0] fl_rd;
      logic [IRW-1:0] ir_rd;
      always_comb begin
        jp = '0;
        for (int j = 0; j < COMMIT_WIDTH; j++) if (c_ret[j]) jp = JW'(j);
      end
      tg_ram_lut #(.DEPTH(FTQ_ENTRIES << SB), .WIDTH(PW), .NR(1)) u_fil (
        .clk, .we(ft_we), .waddr(fqa(f2_s_q, ft_tail)), .wdata(ilk_q), .raddr(fr_ra[0]), .rdata(fl_rd));
      tg_ram_lut #(.DEPTH(FTQ_ENTRIES << SB), .WIDTH(IRW), .NR(1)) u_fri (
        .clk, .we(ft_we), .waddr(fqa(f2_s_q, ft_tail)), .wdata(iri), .raddr(fqa(cs, c_ftq[jp])), .rdata(ir_rd));
      // Commit: a retiring JALR that is not a return, the last instruction of its group, pends until its thread's next
      // instruction. A flush of the thread before that one retires comes from it, the instruction at the jump's target
      // (its own mispredict's correction, or a replay: core-2's review), so the table learns the flush's address, at the
      // coordinates the jump's block read. When the next instruction retires, or traps, the jump went where fetch sent
      // it (the table's entry or the micro-BTB's), and nothing is written: commit needs no target but a flush's (the
      // coordinator's trim, 10-24). Commit's history moves with every such jump's target: a later instruction of its
      // group, the next group's first, a trap's or interrupt's epc, or the flush's address, of which bits 17:2 suffice
      logic [NS-1:0]             pj_v_q, pj_u_q;     // pending; it ran in U
      logic [NS-1:0][IRW-1:0]     pj_r_q;             // the coordinates its block read
      logic [NS-1:0][SLOT_W-1:0] pj_s_q;             // its last parcel's slot
      logic [NS-1:0]             pjn_v, pjn_u;
      logic [NS-1:0][IRW-1:0]     pjn_r;
      logic [NS-1:0][SLOT_W-1:0] pjn_s;
      logic                      wr, wu;
      logic [IRW-1:0]             wri;
      logic [SLOT_W-1:0]         wsl;
      logic [COMMIT_WIDTH:0]       rr;               // the retiring slots and their addresses' bits 17:2, one more
      logic [COMMIT_WIDTH:0][17:2] rp;               // slot (none) past the group
      assign rr = {1'b0, c_ret};
      assign rp = {16'b0, c_pc};
      always_comb begin
        logic cu;
        cu  = priv_h[c_tid] == PRIV_U;
        wr  = 1'b0;
        wu  = 1'b0;
        wri = '0;
        wsl  = '0;
        cph_n = cph_s_q;
        pjn_v = pj_v_q; pjn_u = pj_u_q; pjn_r = pj_r_q; pjn_s = pj_s_q;
        for (int t = 0; t < NS; t++)
          if (fl_s[t]) begin                       // (nothing of the stream retires in its flush's cycle)
            if (pj_v_q[t]) begin
              cph_n[t] = padd(cph_n[t][PW-5:0], flush_pc[17:2]);
              if (!wr) begin wr = 1'b1; wri = pj_r_q[t]; wsl = pj_s_q[t]; wu = pj_u_q[t]; end
            end
            pjn_v[t] = 1'b0;
          end else if (cs == 1'(t)) begin
            // the pending jump's target: the group's first retiring address, else a trap's or interrupt's epc
            if (pj_v_q[t] && (rr[0] || c_trv)) begin
              cph_n[t] = padd(cph_n[t][PW-5:0], rr[0] ? rp[0] : c_trepc);
              pjn_v[t] = 1'b0;
            end
            for (int j = 0; j < COMMIT_WIDTH; j++)
              if (c_ijmp[j]) begin
                if (rr[j + 1])                     // its target retires in the group
                  cph_n[t] = padd(cph_n[t][PW-5:0], rp[j + 1]);
                else begin                         // the group's last retiring instruction (jp): it pends
                  pjn_v[t] = 1'b1;
                  pjn_u[t] = cu;
                  pjn_r[t] = ir_rd;
                  pjn_s[t] = c_slot[j];
                end
              end
          end
      end
      always_ff @(posedge clk) begin
        if (rst) begin
          ph_s_q  <= '0;
          cph_s_q <= '0;
          pj_v_q  <= '0;
        end else begin
          cph_s_q <= cph_n;
          pj_v_q  <= pjn_v;
          for (int t = 0; t < NS; t++)
            if (fl_s[t])      ph_s_q[t] <= cph_n[t];      // a flush: commit's, with its own jump's target
            else if (dr_s[t]) ph_s_q[t] <= fl_rd;         // decode's redirect: its block's lookup history
            else              ph_s_q[t] <= ph_e_s[t];
        end
        pj_u_q <= pjn_u;
        pj_r_q <= pjn_r;
        pj_s_q <= pjn_s;
        iw_q   <= !rst && wr;
        iwr_q  <= wri;
        iws_q  <= wsl;
        iwu_q  <= wu;
        iwt_q  <= flush_pc[38:1];
      end
`ifndef SYNTHESIS
      logic it_rs_q;                                // the first reset has come
      initial it_rs_q = 1'b0;
      always @(posedge clk) if (rst) it_rs_q <= 1'b1;
      // +itt_stats: lookups, delivered exits the table predicted and those that refetched, the table's writes, the
      // retiring jumps, and those a flush resolved (mostly their own mispredicts: each is a write but where two streams
      // flush in one cycle)
      longint n_lk, n_ex, n_rf, n_wr, n_ij, n_im;
      initial begin n_lk = 0; n_ex = 0; n_rf = 0; n_wr = 0; n_ij = 0; n_im = 0; end
      always @(posedge clk)
        if (it_rs_q && !rst) begin
          n_lk <= n_lk + longint'(f2_ld);
          n_ex <= n_ex + longint'(ft_we && ovr_itt);
          n_rf <= n_rf + longint'(ft_we && ovr_itt && f2_ovr);
          n_wr <= n_wr + longint'(iw_q);
          n_ij <= n_ij + longint'($countones(c_ijmp));
          n_im <= n_im + longint'($countones(pj_v_q & fl_s));
        end
      final if ($test$plusargs("itt_stats"))
        $fwrite(32'h8000_0002, "TG-ITT %m: %0d lookups, %0d exits predicted (%0d refetched), %0d writes, %0d jumps retired, %0d flushed\n",
                n_lk, n_ex, n_rf, n_wr, n_ij, n_im);
`endif
    end else begin : g_noitt
      assign itt_hit  = 1'b0;
      assign itt_slot = '0;
      assign itt_tgt  = '0;
      assign itt_hit1  = 1'b0;
      assign itt_slot1 = '0;
      logic unused_itt;
      assign unused_itt = ^{c_ret, c_pc, c_ijmp, c_trv, c_trepc, f2_ijx};
    end
    assign kt_tgt = {miss_pc_q[63:4], 4'b0} + (ks_q ? 64'hFFFF_FFFF_FFFF_FFFE : 64'({kp_q, 1'b0})) +
                    {{43{kimm_q[20]}}, kimm_q};
`ifndef SYNTHESIS
    logic tq_rs_q;                          // the first reset has come
    initial tq_rs_q = 1'b0;
    always @(posedge clk) if (rst) tq_rs_q <= 1'b1;
    // each stream's history as first built (updated with each delivered block): gh_e equals it
    logic [NS-1:0][GH_W-1:0] gh_ref_q;
    always_ff @(posedge clk) begin
      for (int t = 0; t < NS; t++) begin
        if (rst)                                gh_ref_q[t] <= '0;
        else if (fl_s[t])                       gh_ref_q[t] <= cgh_s_q[t];
        else if (dr_s[t])                       gh_ref_q[t] <= r_gh;
        else if (ft_we && f2_s_q == 1'(t))
          gh_ref_q[t] <= (gh_n == 2'd0) ? gh_ref_q[t] : (gh_n == 2'd1) ? {gh_ref_q[t][GH_W-2:0], gh_b[0]}
                                                                       : {gh_ref_q[t][GH_W-3:0], gh_b};
        if (tq_rs_q && !rst) assert (gh_e_s[t] == gh_ref_q[t])
          else $error("tg_fetch: stream %0d's history with its pending bits differs from the history's", t);
      end
    end
    always_ff @(posedge clk)
      if (tq_rs_q && !rst && dred && !flush)
        assert ($countones(r_cm) <= 2) else $error("tg_fetch: an FTQ entry with more than two conditional branches");
    always_ff @(posedge clk)
      if (tq_rs_q && !rst) assert (tq_v == (tq_n != '0) && (!tq_v || tq_ftq == tq_all[0]))
        else $error("tg_fetch: TAGE's queue head differs from its first entry");
    always_ff @(posedge clk)
      if (tq_rs_q && !rst && ft_we)
        for (int k = 0; k < 4; k++)
          if (3'(k) < tq_n && (!MT || tq_all[k][SB+FTQW] == f2_s_q))
            assert (ft_tail != tq_all[k][FTQW-1:0]) else $error("tg_fetch: a block takes an FTQ entry TAGE's training queue names");
    // Every instruction the queue hands decode names an FTQ entry its stream holds, from the head to the tail (a
    // block that went on to F3 without its entry would not: with MT, one delivered in the other stream's redirect)
    always_ff @(posedge clk)
      if (tq_rs_q && !rst)
        for (int j = 0; j < DECODE_WIDTH; j++)
          if (iq_valid[j]) begin
            logic           qs;
            logic [FTQW:0]  occ;
            logic [FTQW-1:0] pos;
            qs  = strm(cq_tid);
            occ = ft_t_s_q[qs] - ft_h_s_q[qs];
            pos = iq_insn[j].ftq - ft_h_s_q[qs][FTQW-1:0];
            assert ((FTQW + 1)'(pos) < occ)
              else $error("tg_fetch: an instruction of stream %0d names FTQ entry %0d outside its head %0h and tail %0h",
                          qs, iq_insn[j].ftq, ft_h_s_q[qs], ft_t_s_q[qs]);
          end
`endif
  end else begin : g_notage
    assign ft_full = 1'b0;
    assign itt_hit  = 1'b0;
    assign itt_slot = '0;
    assign itt_tgt  = '0;
    assign itt_hit1  = 1'b0;
    assign itt_slot1 = '0;
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
                           gh_cm, gh_pk, gh_mb, gh_lm, gh_xm, gh_wd, gh_c3, gh_sb, gh_sx, kp_q, kimm_q, ras_v, ras_top, ras_tos, ras_cnt, f2_rpush, f2_rpop,
                           f2_rlink, krt_q, ks_q, c_ret, c_pc, c_ijmp, c_trv, c_trepc, f2_ijx};
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
  logic                  r_start;           // the refill of mpa's line starts
  // ---- I$ next-line prefetch (IPF_ON; area_recovery.md §6.11-6.12) ----
  // A demand miss of line L (a refill, or a validation, below) also fetches L+1 when it lies in the same page: the
  // prefetch takes a victim way in L+1's set (P_INV: its valid bit cleared, as a refill's), sends its own Get
  // (source 1; the demand's has the A channel first) and writes the beats into that way's rows (P_DATA), where the
  // line waits invalid (P_HELD). The demand miss of exactly that line then validates it, its tag and valid bit in one
  // cycle with no refill (pv_go), and the next line's prefetch starts: sequential code streams. The line is never
  // valid before its own miss, so no other copy can be valid at once. A miss of the line still in flight waits for
  // it (pf_wait). Neither engine's victim is the other's way in the same set; FENCE.I drops a held line and poisons
  // one in flight. A useless prefetch costs the line its victim held.
  typedef enum logic [2:0] { P_IDLE, P_INV, P_REQ, P_DATA, P_HELD } pstate_e;
  pstate_e               ps_q;
  logic [PA_W-1:6]       pline_q;           // the prefetched line
  logic [WAY_W-1:0]      pway_q;            // ... its way (invalid until its validation)
  logic [1:0]            pbeat_q;
  logic                  pbad_q;            // denied, or poisoned by a FENCE.I in flight
  logic                  pv_go, pf_wait, p_inv_go, pf_we, tr_go;
  logic                  a_pf, apf_q;       // the A channel carries the prefetch's Get
  logic [WAY_W-1:0]      pvictim;
  logic [PA_W-1:6]       mline, mnext;      // the missed line and the next one
  assign mline    = mpa[PA_W-1:6];
  assign mnext    = {mline[PA_W-1:12], mline[11:6] + 6'd1};
  assign pf_wait  = IPF_ON && (ps_q == P_INV || ps_q == P_REQ || ps_q == P_DATA) && pline_q == mline && !pbad_q;
  assign pv_go    = IPF_ON && rs_q == R_IDLE && (miss_any || am_go) && ps_q == P_HELD && pline_q == mline && !pbad_q &&
                    !rst;
  assign ivs_done = ivs_q[SET_W];
  // MT: a stream's tags are compared in F1, a cycle and more before F2's action parks it, so a refill or a held
  // line's validation that ended in between leaves it parking on a line now valid (the other stream's miss of the
  // same line): it restarts at once (am_rd; its refetch hits, or misses again after a FENCE.I) and the engine does
  // not fetch the line a second time into another way. A record for each way a line becomes valid, the refill's
  // and the held line's validation: one record let a validation right after a refill hide the refilled line, and a
  // stream's late miss of it fetched it into a second way (verif-2's two-hart random programs, 10-21)
  logic [PA_W-1:6] rdl_q, vdl_q;             // the lines the last refill and the last validation made valid ...
  logic [1:0]      rda_q, vda_q;             // ... cycles since (3: too long ago)
  logic            am_rd;
  assign am_rd    = MT && am_go && ((rda_q != 2'd3 && miss_pa_q[PA_W-1:6] == rdl_q) ||
                                    (vda_q != 2'd3 && miss_pa_q[PA_W-1:6] == vdl_q));
  // (no refill starts during a sweep, nor in the cycle a fourth FENCE.I starts one: the sweep owns the valid RAM's
  // write port, so a refill's writes would be lost, and with hart 1 the other stream's miss can come then; a refill
  // already running is poisoned by the FENCE.I)
  assign r_start  = rs_q == R_IDLE && (miss_any || am_go) && !rst && !pf_wait && !pv_go && !(am_rd && !miss_any) &&
                    ivs_done && !(icinv && gpend_q == 2'd3);
  assign tr_go    = IPF_ON && (r_start || pv_go) && mline[11:6] != 6'h3F && (ps_q == P_IDLE || ps_q == P_HELD);
  assign p_inv_go = IPF_ON && ps_q == P_INV && ivs_done && !r_start && !tag_we && !pv_go;
  assign gp_go    = !gps_q[SET_W] && ivs_done && !r_start && !tag_we && !pv_go && !p_inv_go;
  assign iv_ra[0] = fpc_q[6 +: SET_W];
  assign iv_ra[1] = gp_go ? gps_q[SET_W-1:0] : p_inv_go ? pline_q[6 +: SET_W] :
                    (rs_q == R_IDLE) ? mpa[6 +: SET_W] : rline_q[6 +: SET_W];
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

  // victim: first invalid way of the set, else round robin; with IPF_ON never the other engine's way in its set
  logic [WAY_W-1:0] victim;
  logic [WAYS-1:0]  pmask, rmask;
  assign pmask = (IPF_ON && (ps_q == P_REQ || ps_q == P_DATA || ps_q == P_HELD) &&
                  pline_q[6 +: SET_W] == mpa[6 +: SET_W]) ? WAYS'(1) << pway_q : '0;
  assign rmask = (IPF_ON && rs_q != R_IDLE && rline_q[6 +: SET_W] == pline_q[6 +: SET_W]) ? WAYS'(1) << rway_q : '0;
  always_comb begin
    logic found;
    found = 1'b0;
    victim = pmask[rr_q] ? rr_q + 1'b1 : rr_q;
    for (int w = 0; w < WAYS; w++) begin
      if (!found && !iv_v[1][w] && !pmask[w]) begin
        victim = WAY_W'(w);
        found = 1'b1;
      end
    end
  end
  always_comb begin
    logic found;
    found = 1'b0;
    pvictim = rmask[rr_q] ? rr_q + 1'b1 : rr_q;
    for (int w = 0; w < WAYS; w++) begin
      if (!found && !iv_v[1][w] && !rmask[w]) begin
        pvictim = WAY_W'(w);
        found = 1'b1;
      end
    end
  end

  always_comb begin
    iv_we = tag_we;
    iv_wa = tag_set;
    iv_wd = {gen_q, iv_v[1] | (WAYS'(1) << rway_q)};
    if (pv_go) begin                        // (no refill runs): the held line is valid
      iv_we = 1'b1;
      iv_wa = mpa[6 +: SET_W];
      iv_wd = {gen_q, iv_v[1] | (WAYS'(1) << pway_q)};
    end
    if (p_inv_go) begin                     // (never with the others): the prefetch's victim
      iv_we = 1'b1;
      iv_wa = pline_q[6 +: SET_W];
      iv_wd = {gen_q, iv_v[1] & ~(WAYS'(1) << pvictim)};
    end
    if (r_start) begin                      // (never with tag_we: that is the refill's end)
      iv_we = 1'b1;
      iv_wa = mpa[6 +: SET_W];
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
    l1i_a_o.source  = a_pf ? TL_SRC_W'(1) : '0;
    l1i_a_o.address = {a_pf ? pline_q : rline_q, 6'b0};
    l1i_a_o.mask    = '1;
    l1i_a_valid_o   = rs_q == R_REQ || a_pf;
    l1i_d_ready_o   = 1'b1;
  end
  // The A channel: the demand's Get first, but a prefetch Get once offered stays until it is taken (its message may
  // not change under valid)
  assign a_pf = IPF_ON && ps_q == P_REQ && (rs_q != R_REQ || apf_q);
  always_ff @(posedge clk) apf_q <= !rst && a_pf && !l1i_a_ready_i;
  // A D beat is the prefetch's when its source is 1 (the beats of one message come together)
  logic d_pf;
  assign d_pf    = IPF_ON && l1i_d_i.source[0];
  assign rf_we   = rs_q == R_DATA && l1i_d_valid_i && !d_pf;
  assign pf_we   = IPF_ON && ps_q == P_DATA && l1i_d_valid_i && d_pf;
  assign dw_we   = rf_we || pf_we;
  assign dw_way  = pf_we ? pway_q : rf_way;
  assign dw_row  = pf_we ? {pline_q[6 +: SET_W], pbeat_q} : rf_row;
  assign tw_we   = tag_we || pv_go;
  assign tw_way  = pv_go ? pway_q : rf_way;
  assign tw_set  = pv_go ? mpa[6 +: SET_W] : tag_set;
  assign tw_wd   = pv_go ? mpa[PA_W-1:12] : tag_wd;
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
    if (rst || !MT) begin
      rda_q <= 2'd3;
      vda_q <= 2'd3;
    end else begin
      if (refill_done)        begin rdl_q <= rline_q; rda_q <= '0; end
      else if (rda_q != 2'd3) rda_q <= rda_q + 1'b1;
      if (pv_go)              begin vdl_q <= mline;   vda_q <= '0; end
      else if (vda_q != 2'd3) vda_q <= vda_q + 1'b1;
    end
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      rs_q      <= R_IDLE;
      rr_q      <= '0;
      fline_v_q <= 1'b0;
    end else begin
      unique case (rs_q)
        R_IDLE: if (r_start) begin            // (IPF_ON: not a validation, nor a wait for the prefetch)
          rs_q      <= R_REQ;
          rline_q   <= mpa[PA_W-1:6];
          rway_q    <= victim;
          rr_q      <= rr_q + 1'b1;
          rbeat_q   <= '0;
          rden_q    <= 1'b0;
          rpoison_q <= 1'b0;
        end
        R_REQ: if (l1i_a_ready_i && !a_pf) rs_q <= R_DATA;
        R_DATA: if (l1i_d_valid_i && !d_pf) begin
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
    if (rst || !IPF_ON) begin
      ps_q   <= P_IDLE;
      pbad_q <= 1'b0;
    end else begin
      unique case (ps_q)
        P_INV:  if (p_inv_go) begin
          ps_q   <= P_REQ;
          pway_q <= pvictim;
        end
        P_REQ:  if (l1i_a_ready_i && a_pf) ps_q <= P_DATA;
        P_DATA: if (pf_we) begin
          pbeat_q <= pbeat_q + 1'b1;
          if (l1i_d_i.denied || l1i_d_i.corrupt) pbad_q <= 1'b1;
          if (pbeat_q == 2'd3) ps_q <= P_HELD;
        end
        P_HELD: if (pbad_q || pv_go) ps_q <= P_IDLE;
        default: ;
      endcase
      if (tr_go) begin                         // a demand miss: its next line (a held line is dropped)
        ps_q    <= P_INV;
        pline_q <= mnext;
        pbeat_q <= '0;
        pbad_q  <= 1'b0;
      end
      if (icinv) begin
        if (ps_q == P_REQ || ps_q == P_DATA) pbad_q <= 1'b1;     // its beats still come
        else ps_q <= P_IDLE;
      end
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
    rdone_d_q <= (tag_we || pv_go) && !rst;
    rline_d_q <= pv_go ? mline : rline_q;
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
      if (r_start) ivref_q[mpa[6 +: SET_W]][victim] <= 1'b0;
      if (tag_we)  ivref_q[tag_set][rway_q] <= 1'b1;
      if (p_inv_go) ivref_q[pline_q[6 +: SET_W]][pvictim] <= 1'b0;
      if (pv_go)    ivref_q[mpa[6 +: SET_W]][pway_q] <= 1'b1;
    end
    if (rst) ivref_ok_q <= 1'b0;
    else if (ivs_done) ivref_ok_q <= 1'b1;
  end
  always_ff @(posedge clk) begin
    if (ivref_ok_q && !rst && ivs_done) begin
      assert (iv_v[0] == ivref_q[iv_ra[0]]) else $error("tg_fetch: the I$ valid lines differ from the sweep's");
      if (r_start || p_inv_go || pv_go)
        assert (iv_v[1] == ivref_q[iv_ra[1]]) else $error("tg_fetch: the victim's set differs from the sweep's");
      assert (!(gp_go && (r_start || tag_we || pv_go || p_inv_go))) else $error("tg_fetch: the generation pass with a refill write");
      assert ($onehot0({r_start, tag_we, pv_go, p_inv_go})) else $error("tg_fetch: two valid-RAM writers in a cycle");
      if (IPF_ON && pv_go) assert (!iv_v[1][pway_q]) else $error("tg_fetch: the held line's way is valid at its validation");
    end
    // a FENCE.I's sweep owns the valid RAM's write port: no other write comes then, as it would be lost
    if (ivref_ok_q && !rst && !ivs_done)
      assert (!(r_start || tag_we || pv_go || p_inv_go)) else $error("tg_fetch: a valid-RAM write during the sweep");
  end
`endif

  // ---- Sequential: F1, F2, F3 ----
  // A refetch's PC (F2's action); each stream's restart (its refill's or walk's end) and the PC it restarts at
  logic [63:0]   kref_pc;
  logic [NS-1:0] rs_ref, rs_walk;        // restarts: after a refill, after a walk
  logic [NS-1:0] rs_room;                // MT (5e): ... once its queue has room for its parked block
  logic [NS-1:0][63:0] rs_pc;
  logic [NS-1:0][PA_W-1:6] sline;        // MT: the line each parked (or parking) stream waits for
  always_comb
    for (int t = 0; t < NS; t++)
      sline[t] = (am_go && k_s_q == 1'(t)) ? miss_pa_q[PA_W-1:6] : rpa_s_q[t][PA_W-1:6];
  assign kref_pc = k_cut_q ? {miss_pc_q[63:4], fp_q, 1'b0}
                 : k_ovr_q ? (kr_q ? (ki_q ? {{25{kit_q[38]}}, kit_q, 1'b0} : {{25{krt_q[38]}}, krt_q, 1'b0})
                              : kt_q ? kt_tgt : {miss_pc_q[63:4] + 60'd1, 4'b0})
                 : miss_pc_q;
  always_comb
    for (int t = 0; t < NS; t++) begin
      rs_ref[t]  = ((miss_s_q[t] || (am_go && k_s_q == 1'(t))) &&
                    (!MT ? (refill_done || pv_go)
                         : ((refill_done && rline_q == sline[t]) || (pv_go && mline == sline[t])))) ||
                   (am_rd && k_s_q == 1'(t));
      rs_walk[t] = wout[t] && iw_done;
      rs_room[t] = MT && qw_s_q[t] && int'(q_occ[MT ? t : 0]) + int'(qn_s_q[t]) +
                   ((f3_valid_q && f3_s_q == 1'(t)) ? int'(f3_need_q) : 0) <= IBUF_ENTRIES;
      rs_pc[t]   = ((am_go || aw_go) && k_s_q == 1'(t)) ? miss_pc_q : rpc_s_q[t];
    end
  // F1's next block and the streams' waiting blocks: the events in the priority they had with one stream (F2's
  // action or F1's move, then the restarts, then the redirect, last); a stream's next block goes into F1 when F1 is
  // free for it (without MT always), else it waits
  logic          f1v_n, ft_n, pw_n;
  logic [63:0]   fpc_n;
  logic [NS-1:0] sv_n;
  logic [NS-1:0][63:0] spc_n;
  logic          f1_mv;                  // F1's block moves into F2
  assign f1_mv = !ka_q && f2_go && f1_live;
  always_comb begin
    logic o, f1r;
    o     = 1'b0;
    f1r   = 1'b0;
    f1v_n = f1_valid_q; ft_n = ft_q; fpc_n = fpc_q; pw_n = pw_q;
    sv_n  = sv_s_q;     spc_n = spc_s_q;
    // F1 waits a cycle for its PMP check; any change of fpc_q below ends the wait
    if (f1_base && f1_pwait) pw_n = 1'b1;
    if (ka_q) begin
      if (k_miss_q || k_walk_q || k_room_q) begin     // stream k parks: its later blocks go
        if (ft_q == k_s_q) f1v_n = 1'b0;
        sv_n[k_s_q] = 1'b0;
      end else if (!k_stop_q) begin                   // refetch stream k (its later blocks go)
        if (!MT || !f1_valid_q || ft_q == k_s_q) begin
          f1v_n = 1'b1; fpc_n = kref_pc; ft_n = k_s_q; pw_n = 1'b0;
          sv_n[k_s_q] = 1'b0;
        end else begin
          sv_n[k_s_q] = 1'b1; spc_n[k_s_q] = kref_pc;
        end
      end
    end else if (f1_mv) begin                         // F1's block moves on: the other stream's waiting block, or
      o = MT && !ft_q;                                // its own next
      if (MT && sv_s_q[o] && !blk_s[o]) begin
        fpc_n = spc_s_q[o]; ft_n = o; sv_n[o] = 1'b0;
        sv_n[ft_q] = 1'b1; spc_n[ft_q] = pred_hit ? pred_tgt : seq_pc;
      end else begin
        // (G, spikes.md §7.1: f1_fault leaves the select; a faulting block becomes F2's fault block, which stops
        // its stream and drops the block behind it, so the next block's address is never used)
        fpc_n = pred_hit ? pred_tgt : seq_pc;
      end
      pw_n = 1'b0;
    end
    // Restarts after a refill or a walk
    for (int t = 0; t < NS; t++) begin
      if (rs_ref[t] || rs_walk[t] || rs_room[t]) begin
        if (!MT || !f1v_n) begin
          f1v_n = 1'b1; fpc_n = rs_pc[t]; ft_n = 1'(t); pw_n = 1'b0;
        end else begin
          sv_n[t] = 1'b1; spc_n[t] = rs_pc[t];
        end
      end
    end
    // MT: an empty F1, or one holding a stopped stream's block, takes a waiting block
    if (MT && (!f1v_n || stop_s_q[ft_n] || blk_s[ft_n])) begin
      o = !ft_n;
      if (sv_n[o] && !blk_s[o]) begin
        f1v_n = 1'b1; fpc_n = spc_n[o]; ft_n = o; sv_n[o] = 1'b0; pw_n = 1'b0;
      end else if (!f1v_n && sv_n[ft_n] && !blk_s[ft_n]) begin
        f1v_n = 1'b1; fpc_n = spc_n[ft_n]; sv_n[ft_n] = 1'b0; pw_n = 1'b0;
      end
    end
    // The redirects: each redirected stream's next block is its redirect's PC (its blocks in F1, F2 and F3 go,
    // below). F1 takes it when F1 is empty or holds the stream's own block, a stopped stream's or another redirected
    // stream's old one, and no other redirect of this cycle took F1 already; else it waits
    f1r = 1'b0;
    for (int t = 0; t < NS; t++) begin
      if (red_s[t]) begin
        if (!(MT && fl_slp && fl_s[t]) &&
            (!MT || !f1v_n || (!f1r && (ft_n == 1'(t) || stop_s_q[ft_n] || blk_s[ft_n] || red_s[ft_n])))) begin
          f1v_n = 1'b1; fpc_n = red_pc_s[t]; ft_n = 1'(t); pw_n = 1'b0; f1r = 1'b1;
          sv_n[t] = 1'b0;
        end else begin
          // (step 6) a sleep's redirect always waits here, in its stream's slot, which a blocked stream never leaves,
          // so the thread resumes there when it wakes; its old block in F1 goes
          if (MT && fl_slp && fl_s[t] && f1v_n && ft_n == 1'(t)) f1v_n = 1'b0;
          sv_n[t] = 1'b1; spc_n[t] = red_pc_s[t];
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      f1_valid_q  <= 1'b1;
      fpc_q       <= boot_pc;
      ft_q        <= strm(RUN_TID);              // (the running hart's stream: 1 with SOLO_TID)
      pw_q        <= 1'b0;
      sv_s_q      <= '0;
      if (MT) begin                              // hart 1 fetches from reset too (M7's step 5c): the other
        sv_s_q[strm(~RUN_TID)]  <= 1'b1;         // stream's first block waits at the boot PC
        spc_s_q[strm(~RUN_TID)] <= boot_pc;
      end
      stop_s_q    <= '0;
      miss_s_q    <= '0;
      wk_s_q      <= '0;
      wk_sent_s_q <= '0;
      qw_s_q      <= '0;
      xf_v_s_q    <= '0;
      carry_s_q   <= '0;
      f2_valid_q  <= 1'b0;
      f2_s_q      <= 1'b0;
      f3_valid_q  <= 1'b0;
      f3_s_q      <= 1'b0;
      ka_q        <= 1'b0;
      k_s_q       <= 1'b0;
    end else begin
      f1_valid_q <= f1v_n;
      fpc_q      <= fpc_n;
      ft_q       <= ft_n;
      pw_q       <= pw_n;
      sv_s_q     <= sv_n;
      spc_s_q    <= spc_n;
      if (f1_base && f1_pwait) pw_pa_q <= f1_pa[PA_W-1:4];
      // F3: the data registers take whatever block F2 offers; only the valid bit waits for its hit
      if (f3_accept) f3_valid_q <= 1'b0;
      if (f2v && f3_accept) begin
        f3_parcel_q <= parcel;                      // a fault block's are zeroed after it
        f3_start_q  <= blk_start;
        f3_marks_q  <= f2_bfault ? '0 : blk_marks;
        f3_carry_q  <= blk_carry;
        f3_meta_q   <= '{base: f2_pc_q[63:4], hit: f2_taken, way: f2_way_q, slot: fx_slot,
                         target: f2_tgt_q, tsrc: 1'b0,
                         uhit: TAGE_ON ? uok && !f2_isfault : f2_taken, uslot: f2_slot_q, ftq: ft_tail,
                         fault: f2_isfault, fpf: f2_bfault && f2_fpf_q, fhi: !f2_bfault && pmp_hi};
        f3_s_q      <= f2_s_q;
        f3_ras_q    <= ovr_ras || ovr_itt;               // (the queue's target: the stack's or the table's)
        f3_itt_q    <= ITT_ON && !ovr_ras;               // (the stack's top first, as fx_tgt)
        f3_rtop_q   <= ras_top;
        f3_itgt_q   <= itt_tgt;
        f3_tk_q     <= fx_tk;
        f3_nj_q     <= fx_nj;
        f3_nhs_q    <= fx_nhs;
      end
      if (f2_deliver) begin
        f3_valid_q          <= 1'b1;
        carry_s_q[f2_s_q]   <= blk_carry;
        sp_s_q[f2_s_q]      <= parcel[NP-1];
        if (f2_isfault) stop_s_q[f2_s_q] <= 1'b1;
      end
      // F2 <- F1, unless F2 acted last cycle (MT: the other stream's block in F2 waits a cycle then)
      if (ka_q) begin
        if (k_s_q == f2_s_q) f2_valid_q <= 1'b0;
        if (k_miss_q) begin
          // Park on the missed block; the refill restarts fetch there (its carry is kept).
          miss_s_q[k_s_q] <= 1'b1;
          rpc_s_q[k_s_q]  <= miss_pc_q;
          rpa_s_q[k_s_q]  <= miss_pa_q;
        end else if (k_walk_q) begin
          // ITLB miss: park and walk; the walk's end restarts fetch here
          wk_s_q[k_s_q]      <= 1'b1;
          wk_sent_s_q[k_s_q] <= 1'b0;
          rpc_s_q[k_s_q]     <= miss_pc_q;
          rpa_s_q[k_s_q]     <= miss_pa_q;
        end else if (k_room_q) begin
          // MT (5e): its queue has no room for the block: park; the room restarts fetch here
          qw_s_q[k_s_q]  <= 1'b1;
          qn_s_q[k_s_q]  <= kn_q;
          rpc_s_q[k_s_q] <= miss_pc_q;
          rpa_s_q[k_s_q] <= miss_pa_q;
        end
        // (a refetch: F1 and the waiting blocks above)
      end else if (f2_go) begin
        f2_valid_q <= f1_live;
        f2_s_q     <= ft_q;
        f2_pc_q    <= fpc_q;
        f2_pa_q    <= f1_pa;
        f2_fault_q <= f1_fault;
        f2_fpf_q   <= f1_fpf;
        f2_tm_q    <= f1_tm;
        f2_pmpd_q  <= f1_pmpd;
        f2_hit_q   <= pred_hit;
        f2_way_q   <= ub_way;
        f2_slot_q  <= ub_slot;
        phit_q     <= pred_hit || (ITT_ON && itt_hit1);       // (the table's read is with this load: f2_ld)
        pslot_q    <= (ITT_ON && itt_hit1) ? itt_slot1 : ub_slot;
        f2_tgt_q   <= pred_tgt;
        f2_wh_q    <= f1_wh;
        f2_hw_q    <= f1_hw;
      end else if (f2_deliver) begin
        f2_valid_q <= 1'b0;                         // (a redirect's cycle: the other stream's block went on)
      end
      // F2's action on this cycle's block, taken next cycle; miss_pc_q and miss_pa_q name the block
      ka_q     <= f2_miss || f2_wmiss || f2_qfull || (f2_deliver && f2_ka);
      k_room_q <= f2_qfull;
      kn_q     <= f2_need;
      if (f2_deliver) f3_need_q <= f2_need;
      k_s_q    <= f2_s_q;
      k_miss_q <= f2_miss && !((refill_done && f2_pa_q[PA_W-1:6] == rline_q) || (pv_go && f2_pa_q[PA_W-1:6] == mline) ||
                               (rdone_d_q && f2_pa_q[PA_W-1:6] == rline_d_q));
      k_walk_q <= f2_wmiss;
      k_stop_q <= f2_deliver && f2_isfault;
      k_cut_q  <= pmp_cut;
      k_ovr_q  <= f2_override;
      kt_q     <= ovr_tk;
      kp_q     <= ovr_p;
      kimm_q   <= ovr_imm;
      kr_q     <= ovr_ras || ovr_itt;
      ki_q     <= ITT_ON && !ovr_ras;
      krt_q    <= ras_top;
      kit_q    <= itt_tgt;
      ks_q     <= ovr_s;
      fp_q     <= fp;
      if (f2v) begin
        miss_pc_q <= f2_pc_q;
        miss_pa_q <= f2_pa_q;
      end
      // Restart after the refill (F2 holds nothing of the stream then; a registered miss parks in this cycle)
      for (int t = 0; t < NS; t++) if (rs_ref[t]) miss_s_q[t] <= 1'b0;
      for (int t = 0; t < NS; t++) if (rs_room[t]) qw_s_q[t] <= 1'b0;
      // Restart after the walk (a fault: the page's blocks fault until a redirect)
      if ((wk_s_q[ws] || aw_go) && iw_ack) wk_sent_s_q[ws] <= 1'b1;
      if (rs_walk[wo]) begin
        wk_s_q[wo] <= 1'b0;
        if (!iw_ok) begin
          xf_v_s_q[wo]    <= 1'b1;
          xf_pf_s_q[wo]   <= iw_cause == EXC_IPAGE;
          xf_page_s_q[wo] <= rs_pc[wo][63:12];
        end
      end
      // A redirect: its stream's blocks in F2 and F3 and its action go, and its state is reset (its next block above)
      if (redirect) begin
        if (red_s[f2_s_q]) f2_valid_q <= 1'b0;
        if (red_s[f2_deliver ? f2_s_q : f3_s_q]) f3_valid_q <= 1'b0;
        if (red_s[f2_s_q]) ka_q <= 1'b0;
        for (int t = 0; t < NS; t++)
          if (red_s[t]) begin
            stop_s_q[t]    <= 1'b0;
            miss_s_q[t]    <= 1'b0;
            wk_s_q[t]      <= 1'b0;
            qw_s_q[t]      <= 1'b0;
            wk_sent_s_q[t] <= 1'b0;
            xf_v_s_q[t]    <= 1'b0;
            carry_s_q[t]   <= 1'b0;
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
      iq_insn[j].tid         = cq_tid;               // the queue's thread (M7)
      iq_insn[j].marks       = marks;
      iq_insn[j].q_ill       = qill;
      iq_insn[j].q_exc       = qexc;
      iq_insn[j].q_ser       = qser;
    end
  end

  logic unused;
  assign unused = ^{upd_pc[63:39], upd_pc[3:0], upd_target[63:39], upd_target[0], pd_is32, pd_call, pd_ret, l1i_d_i.opcode, l1i_d_i.param, l1i_d_i.size,
                    l1i_d_i.source, l1i_d_i.sink, rf_we && 1'b0, mpa[5:0], pmp_hit_u, pmp_rwx_u};

`ifndef SYNTHESIS
  // No F2 hit on the way being refilled from a row the refill had already rewritten when F1
  // read it (the old line's tag over the new line's bytes; soc track's report, 2026-10-14)
  logic            stale_q;
  logic [WAY_W-1:0] stale_way_q;
  always_ff @(posedge clk) begin
    if (f2_ld) begin
      stale_q     <= rs_q == R_DATA && fpc_q[6 +: SET_W] == rline_q[6 +: SET_W] &&
                     (fpc_q[5:4] < rbeat_q || (fpc_q[5:4] == rbeat_q && rf_we));
      stale_way_q <= rway_q;
    end
    if (!rst && f2v && stale_q)
      assert (!way_hit[stale_way_q]) else $error("tg_fetch: I$ hit on a row the refill rewrote");
  end
  always_ff @(posedge clk) begin
    if (!rst && f2v && !f2_bfault) assert ($onehot0(way_hit)) else $error("tg_fetch: multiple way hits");
    if (!rst && f2v) assert (!(miss_s_q[f2_s_q] || wk_s_q[f2_s_q] || ((am_go || aw_go) && k_s_q == f2_s_q)))
      else $error("tg_fetch: F2 holds a block of a parked stream");
    // a stream's next block is in one place: F1 or waiting, never both
    if (!rst && MT) for (int t = 0; t < NS; t++)
      assert (!(sv_s_q[t] && f1_valid_q && ft_q == 1'(t))) else $error("tg_fetch: stream %0d's next block in F1 and waiting", t);
  end
`endif
`ifndef SYNTHESIS
  // The shared stall the coordinator asked to measure (M7's step 5): cycles F2 holds (F3 or the FTQ full) while
  // another stream than F2's has a block in F1 or waiting, which the hold stalls too; on stderr at the end with hart 1
  longint unsigned n_f2hold2;
  always_ff @(posedge clk)
    if (rst) n_f2hold2 <= 0;
    else if (MT && f2_hold && ((f1_valid_q && ft_q != f2_s_q && !blk_s[ft_q]) || (sv_s_q[!f2_s_q] && !blk_s[!f2_s_q])))
      n_f2hold2 <= n_f2hold2 + 1;                   // (a blocked stream's block waits for its flush, not for F2)
  // Sharper (the throughput it may cost): the other stream is not stopped, parked or blocked and its queue has room
  // for a whole block, so it could have gone on but for the hold
  longint unsigned n_f2hold2b;
  always_ff @(posedge clk)
    if (rst) n_f2hold2b <= 0;
    else if (MT && f2_hold) begin
      logic y;
      y = !f2_s_q;
      if (((f1_valid_q && ft_q == y) || sv_s_q[y]) && !blk_s[y] && !stop_s_q[y] && !miss_s_q[y] && !wk_s_q[y] &&
          int'(u_cmp.occ_t_q[y]) <= IBUF_ENTRIES - FETCH_BYTES / 2)
        n_f2hold2b <= n_f2hold2b + 1;
    end
  final if (MT) $fwrite(32'h8000_0002, "TG-STALL2 %m: F2 holds another stream's fetch %0d cycles (%0d with that stream ready and room in its queue)\n",
                        n_f2hold2, n_f2hold2b);
  // (5e) the parks on a queue's room, and the cycles streams spent parked so
  longint unsigned n_qpark, n_qparkc;
  always_ff @(posedge clk)
    if (rst) begin
      n_qpark  <= 0;
      n_qparkc <= 0;
    end else if (MT) begin
      if (f2_qfull) n_qpark <= n_qpark + 1;
      n_qparkc <= n_qparkc + longint'($countones(qw_s_q));
    end
  final if (MT) $fwrite(32'h8000_0002, "TG-FQPARK %m: F2 parked a stream on its queue's room %0d times (%0d stream-cycles parked)\n",
                        n_qpark, n_qparkc);
`endif
  // M9's counters (TG_HPM): an I$ miss as F2's action parks its stream on one (once a miss: a line that became valid
  // meanwhile is no miss), counted for the stream's thread
  always_comb
    for (int t = 0; t < NUM_THREADS; t++)
      hpm_imiss[t] = ka_q && k_miss_q && (MT ? k_s_q == 1'(t) : tid_t'(t) == RUN_TID);
endmodule
