// Tanager core: the port contract of docs/spec/interfaces.md §1–§5.
// M2 core alpha (docs/spec/core-pipeline.md, core-lsu.md): an out-of-order RV64IM pipeline,
// machine mode, one hart running (hart 0; SMT2 builds compile with tid carried everywhere).
//   tg_fetch -> tg_decode_stage -> tg_rename (RN, DS) -> tg_issue -> tg_exec / tg_lsu -> tg_rob
// with tg_csr beside commit. Every recovery is at commit: tg_rob registers flush and the
// redirect PC, and every unit clears its thread's state in that cycle.
module tg_core
  import tg_pkg::*, tg_tl_pkg::*, tg_trace_pkg::*, tg_core_pkg::*, tg_fpcore_pkg::*;
#(
  parameter int unsigned CORE_ID  = 0,     // used for mhartid and trace hart IDs
  parameter bit          DBG_WORD = 1'b0   // board debug: dbg_o and its logs (tanager_soc's DEBUG_CNT);
                                           // without it dbg_o is 0 and none of them is built
) (
  input  logic                         clk,
  input  logic                         clk2x = 1'b0, // URF (DR-174): twice clk, every clk rise a clk2x rise;
                                                      // unused (tied 0) without it
  input  logic                         rst,
  input  paddr_t                       boot_addr_i,   // reset PC of every hart of this core

  // Interrupts and time: one bit per hart of this core (index = TID)
  input  logic [NUM_THREADS-1:0]       irq_mei_i,     // machine external (PLIC M context)
  input  logic [NUM_THREADS-1:0]       irq_sei_i,     // supervisor external (PLIC S context)
  input  logic [NUM_THREADS-1:0]       irq_mti_i,     // ACLINT MTIMER
  input  logic [NUM_THREADS-1:0]       irq_msi_i,     // ACLINT MSWI
  input  logic [NUM_THREADS-1:0]       irq_ssi_i,     // ACLINT SSWI (may be tied 0)
  input  logic [63:0]                  mtime_i,       // ACLINT mtime, for `time` and Sstc
  input  logic [NUM_THREADS-1:0]       debug_req_i,   // debug module halt request (M9; tie 0)
  output logic [NUM_THREADS-1:0]       merr_o,        // bus error on an early-retired load (plan §4.5)

  // Instruction fetch: Get only (channels A, D)
  output tl_a_t                        l1i_a_o,
  output logic                         l1i_a_valid_o,
  input  logic                         l1i_a_ready_i,
  input  tl_d_t                        l1i_d_i,
  input  logic                         l1i_d_valid_i,
  output logic                         l1i_d_ready_o,

  // Cacheable data: TL-C (channels A, B, C, D, E)
  output tl_a_t                        l1d_a_o,
  output logic                         l1d_a_valid_o,
  input  logic                         l1d_a_ready_i,
  input  tl_b_t                        l1d_b_i,
  input  logic                         l1d_b_valid_i,
  output logic                         l1d_b_ready_o,
  output tl_c_t                        l1d_c_o,
  output logic                         l1d_c_valid_o,
  input  logic                         l1d_c_ready_i,
  input  tl_d_t                        l1d_d_i,
  input  logic                         l1d_d_valid_i,
  output logic                         l1d_d_ready_o,
  output tl_e_t                        l1d_e_o,
  output logic                         l1d_e_valid_o,
  input  logic                         l1d_e_ready_i,

  // Uncached device accesses: Get, PutFullData, PutPartialData (channels A, D)
  output tl_a_t                        mmio_a_o,
  output logic                         mmio_a_valid_o,
  input  logic                         mmio_a_ready_i,
  input  tl_d_t                        mmio_d_i,
  input  logic                         mmio_d_valid_i,
  output logic                         mmio_d_ready_o,

  // Commit trace (lockstep in simulation, trace streaming on the FPGA)
  output tr_rec_t [COMMIT_WIDTH-1:0]   trace_o,
  output logic    [COMMIT_WIDTH-1:0]   trace_valid_o,
  output tr_wb_t  [TRACE_WB_PORTS-1:0] trace_wb_o,
  output logic    [TRACE_WB_PORTS-1:0] trace_wb_valid_o,
  input  logic                         trace_stall_i,    // interfaces.md v1.3: hold commit
  // Board debug (tanager-host dbg; DR-150), a register: the word dbg_sel_i picks (0 without DBG_WORD).
  //   0: the status: bits [7:0] rename (slot 0 valid, serial, window empty, blocked after a serial
  //      uop, resources OK, fire, DS busy, ready && start); [13:8] the ROB's count; [16:14] the
  //      atomic (am_st, am_v); [21:17] the SQ head (valid, address, data, data ready, SQ non-empty);
  //      [29:22] the D$ (probe state, MSHR state, ready); [30] the trace stall; [31] a flush.
  //   1-15: the first 15 dispatch groups after reset; 16-31: the first 16 commit cycles that
  //      retire something. A word per group or cycle: per slot 15 bits {writes rd, rd is FP,
  //      rd[4:0], the physical register[7:0]}, slot 0 in [14:0] and slot 1 in [30:16]; for
  //      dispatch the register is the new destination, for commit the old one, which is freed.
  input  logic [4:0]                   dbg_sel_i,
  output logic [31:0]                  dbg_o
);
  // DR-120: pma_of's region tests are prefix matches only while every region in tg_map_pkg is a
  // naturally aligned power of two; an unaligned one falls back to the range test (~0.13K LUTs
  // per instance), so it is reported here rather than costing area silently
  if (!tg_map_pkg::map_prefix_only()) begin : g_map_unaligned
    $warning("tg_map_pkg: a region is not a naturally aligned power of two; pma_of uses the range test");
  end
  // SOLO_TID (M7's test mode) runs the core's one thread as tid 1: there is a tid 1 only with TID_W = 1
  if (SPLIT && TID_W == 0) begin : g_bad_split
    $error("tg_core: SPLIT needs an SMT2 configuration (TID_W = 1)");
  end
  if (SOLO_TID && TID_W == 0) begin : g_bad_solo
    $error("tg_core: SOLO_TID needs an SMT2 configuration (TID_W = 1)");
  end
  if (HART1_ON && TID_W == 0) begin : g_bad_hart1
    $error("tg_core: HART1_ON needs an SMT2 configuration (TID_W = 1)");
  end
  // Hart 1 runs (M7's step 5c): CSR reads by the executing thread, interrupts and the trace's mode by the commit
  // head's; without it every such select is the running thread's
  localparam bit MT = HART1_ON && NUM_THREADS > 1;
  localparam int CW  = COMMIT_WIDTH;
  localparam int NCW = idx_w(CW + 1);

  // ---- Reset sequence: zero x0..x31's initial registers (bank 0, indices 0..31) and f0..f31's (F0); with hart 1
  // (M7's step 5c) its homes too in the same 32 cycles: x1-x16 in bank 1 (tg_exec's port 1), x17-x31 in the load
  // bank and f0-f31 in F1 (the LSU's result register's ports) ----
  logic [5:0] init_q;
  logic       init_done;
  assign init_done = init_q[5];
  always_ff @(posedge clk) begin
    if (rst) init_q <= '0;
    else if (!init_done) init_q <= init_q + 1'b1;
  end

  // ---- Trace back-pressure (registered): while set, nothing retires, traps or takes an
  //      interrupt; deferred writebacks (none in M3) would continue ----
  logic trace_stall_q;
  always_ff @(posedge clk) trace_stall_q <= !rst && trace_stall_i;
  // Board debug (dbg_o, above; built with DBG_WORD, at the end)
  logic [7:0]  rn_dbg;
  logic [15:0] lsu_dbg;

  // ---- Flush and redirect from commit ----
  logic        flush, icinv;
  tid_t        flush_tid;
  logic [63:0] flush_pc;

  // ---- Mode, translation and PMP state (tg_csr) ----
  logic misa_m, misa_b, misa_c, misa_a, misa_f, misa_d;
  logic [1:0] fs;
  logic [2:0] frm;
  logic [NUM_THREADS-1:0][2:0] frm_h;                 // each hart's (tg_fcsr)
  dec_state_t [NUM_THREADS-1:0] dst_csr;               // each hart's decode state from tg_csr (its frm: frm_h)
  // fcsr (tg_fcsr, EXT_FD; instantiated with P4 below)
  logic [4:0] fc_fflags;                              // the CSR read's thread's flags and mode (tg_csr)
  logic [2:0] fc_frm;
  logic       fc_wvalid;
  logic [NUM_THREADS-1:0] fs_dirty;   // per hart
  logic [1:0] fc_waddr;
  logic [7:0] fc_wdata;
  priv_e priv;
  logic  tvm, tw, tsr, satp_sv39;
  logic [15:0] satp_asid;
  pmp_d_t [PMP_ENTRIES-1:0] pmp_d;
  // Each hart's, for the LSU and the walker (M7's step 4)
  priv_e  [NUM_THREADS-1:0]                  priv_h, priv_d_h;
  logic   [NUM_THREADS-1:0]                  sum_h, mxr_h, sv39_h;
  logic   [NUM_THREADS-1:0][43:0]            satp_ppn_h;
  pmp_d_t [NUM_THREADS-1:0][PMP_ENTRIES-1:0] pmp_d_h;
  logic   [NUM_THREADS-1:0][2:0]             pmp_al_h;
  logic   [NUM_THREADS-1:0][PMP_ENTRIES-1:0] pmp_p2m_h;
  logic        satp_wr, pmp_wr, pmp_busy, sfence, tlb_flush;
  tid_t        tlb_flush_tid;                // the hart whose TLB entries the flush clears (M7's step 4)
  logic        iw_req, iw_ack, iw_done, iw_ok, it_fill;
  logic [63:0] iw_va;
  tid_t        iw_tid;                   // fetch's walk's thread (M7's step 5b)
  logic [3:0]  iw_cause;
  logic [26:0] it_fill_vpn;
  logic [1:0]  it_fill_lvl;
  tlb_pte_t    it_fill_pte;
  tid_t        it_fill_tid;

  // ---- Front end ----
  logic        fe_ready, lsu_ready;
  logic        dred;
  logic [63:0] dred_pc;
  logic [FTQW-1:0]   dred_ftq;             // TAGE_ON: dred's instruction's block and slot
  logic [SLOT_W-1:0] dred_slot;
  logic [1:0]        dred_rop;             // ... its stack operation and link (RAS_FE)
  logic [38:1]       dred_rlink;
  // TAGE_ON, from commit: the retiring conditional branches TAGE trains on, and the FTQ's head
  logic [COMMIT_WIDTH-1:0]             cm_cbr, cm_ctaken, cm_cpred;
  logic [COMMIT_WIDTH-1:0][FTQW-1:0]   cm_cftq;
  logic [COMMIT_WIDTH-1:0][SLOT_W-1:0] cm_cslot;
  logic                                cm_hv;
  logic [FTQW-1:0]                     cm_hftq;
  // The return-address stack (RAS_ON): decode (RAS_DEC) or fetch (RAS_FE, with TAGE) reads its top
  // and moves it; commit keeps its committed copy; a flush restores it from that copy, and with
  // RAS_FE decode's redirect repairs it from fetch's FTQ
  logic                    ras_v, ras_push, ras_pop;          // decode's view: its thread's stack
  logic [38:1]             ras_top, ras_link;
  // The stacks, one per thread with hart 1 (M7's step 5b; else the one), as fetch sees them
  logic [NUM_THREADS-1:0]              ras_v_t;
  logic [NUM_THREADS-1:0][38:1]        ras_top_t;
  logic [NUM_THREADS-1:0][RAS_PW-1:0]  ras_tos_t;
  logic [NUM_THREADS-1:0][RAS_PW:0]    ras_cnt_t;
  tid_t                    fras_tid, fras_rtid;               // fetch's operation's thread, its repair's
  logic                    fras_push, fras_pop, fras_rv, fras_rwr;
  logic [38:1]             fras_link, fras_rtop;
  logic [RAS_PW-1:0]       fras_rtos;
  logic [RAS_PW:0]         fras_rcnt;
  logic [COMMIT_WIDTH-1:0] cm_ras_push, cm_ras_pop;
  logic [COMMIT_WIDTH-1:0][38:1] cm_ras_link;
  logic        upd_valid, upd_way, upd_inval;
  logic [63:0] upd_pc, upd_target;
  tid_t        upd_tid;                 // M7 step 5: the micro-BTB entry's tid (5b)
  logic [SLOT_W-1:0] upd_slot;
  logic [DECODE_WIDTH-1:0]   iq_valid;
  fe_insn_t [DECODE_WIDTH-1:0] iq_insn;
  logic [idx_w(DECODE_WIDTH + 1)-1:0] iq_take;
  // Fetch's own copy of the privilege and of whether it translates, a cycle behind tg_csr's: they
  // change only as a trap, an xRET or a serialising CSR write commits, and the flush that follows
  // is the next cycle, so fetch resumes after the copy has caught up (timing, DR-145: the CSR's
  // registers are far from F1's PMP select; any difference falls in a flush cycle, asserted)
  // (per hart, M7's step 5b: fetch takes its F1 block's hart's)
  priv_e [NUM_THREADS-1:0] priv_f_q;
  logic  [NUM_THREADS-1:0] xl_f_q;
  always_ff @(posedge clk)
    for (int t = 0; t < NUM_THREADS; t++) begin
      priv_f_q[t] <= rst ? PRIV_M : priv_h[t];
      xl_f_q[t]   <= !rst && EXT_SU && sv39_h[t] && priv_h[t] != PRIV_M;
    end
`ifndef SYNTHESIS
  logic rs_fq;
  initial rs_fq = 1'b0;
  always @(posedge clk) begin
    if (rst) rs_fq <= 1'b1;
    if (rs_fq && !rst)
      for (int t = 0; t < NUM_THREADS; t++)
        assert (flush || (priv_f_q[t] == priv_h[t] && xl_f_q[t] == (EXT_SU && sv39_h[t] && priv_h[t] != PRIV_M)))
          else $error("tg_core: fetch's privilege copy of hart %0d differs outside a flush", t);
    // the running hart's is the one fetch took before M7's step 5b
    if (rs_fq && !rst)
      assert (priv_h[RUN_TID] == priv && sv39_h[RUN_TID] == satp_sv39 && pmp_d_h[RUN_TID] == pmp_d)
        else $error("tg_core: the running hart's translation state differs from tg_csr's scalars");
  end
`endif
  // The LSU's own copy of the privilege, the data privilege, SUM, MXR and satp, a cycle behind
  // tg_csr's, as fetch's: they change only as a trap, an xRET or a serialising CSR write commits,
  // and the flush that follows the next cycle squashes the LSU's new accesses (the walker, S2, the
  // head's check and the walk prefetch are flush-gated), which resume with the copy caught up
  // (timing, DR-145: G6's tg_csr priv -> the LSU's translation mode -> the store's PMP checker ->
  // the ROB, -1.53 ns, 70% wire; any difference falls in a flush cycle, asserted). One copy per hart
  // (M7's step 4)
  priv_e [NUM_THREADS-1:0]       priv_l_q, priv_dl_q;
  logic  [NUM_THREADS-1:0]       sum_l_q, mxr_l_q, sv39_l_q;
  logic  [NUM_THREADS-1:0][43:0] satp_ppn_l_q;
  always_ff @(posedge clk)
    for (int t = 0; t < NUM_THREADS; t++) begin
      priv_l_q[t]     <= rst ? PRIV_M : priv_h[t];
      priv_dl_q[t]    <= rst ? PRIV_M : priv_d_h[t];
      sum_l_q[t]      <= !rst && sum_h[t];
      mxr_l_q[t]      <= !rst && mxr_h[t];
      sv39_l_q[t]     <= !rst && sv39_h[t];
      satp_ppn_l_q[t] <= satp_ppn_h[t];
    end
`ifndef SYNTHESIS
  always @(posedge clk)
    if (rs_fq && !rst)
      for (int t = 0; t < NUM_THREADS; t++)
        assert (flush || (priv_l_q[t] == priv_h[t] && priv_dl_q[t] == priv_d_h[t] && sum_l_q[t] == sum_h[t] &&
                          mxr_l_q[t] == mxr_h[t] && sv39_l_q[t] == sv39_h[t] && satp_ppn_l_q[t] == satp_ppn_h[t]))
          else $error("tg_core: the LSU's privilege copy of hart %0d differs outside a flush", t);
`endif
  // The decoders' state per hart, as decode gets it (its group's hart's), for the instruction queue's decode bits too
  // (declared ahead of u_fetch, which takes it: a name a port uses before its declaration is a new, undriven
  // implicit net in Vivado, Synth 8-11241, while Verilator resolves it)
  dec_state_t [NUM_THREADS-1:0] de_state_h;
  logic [NUM_THREADS-1:0]        rn_blk;      // (MT) the threads behind a serial uop at rename (tg_rename's, for fetch)
  logic [NUM_THREADS-1:0]        rn_acc;      // (MT, step 5d) the threads whose RN register takes a group next cycle
  always_comb
    for (int t = 0; t < NUM_THREADS; t++) begin
      de_state_h[t]     = dst_csr[t];
      de_state_h[t].frm = frm_h[t];
    end
`ifndef SYNTHESIS
  // the running hart's is the one decode read before M7's step 5b
  always_ff @(posedge clk)
    if (!rst) assert (de_state_h[RUN_TID] == '{misa_m: misa_m, misa_b: misa_b, misa_c: misa_c, misa_a: misa_a,
                                               misa_f: misa_f, misa_d: misa_d, fs: fs, frm: frm, priv: priv, tvm: tvm,
                                               tw: tw, tsr: tsr})
      else $error("tg_core: the running hart's decode state differs from tg_csr's");
`endif
  tid_t dred_tid;
  tid_t [CW-1:0] cm_tid;                              // the retiring instructions' threads (fetch's predictors take it)
  tg_fetch u_fetch (
    .clk, .rst, .boot_pc(64'(boot_addr_i)), .ready(fe_ready),
    .flush, .flush_tid, .flush_pc, .icinv, .dred, .dred_tid, .dred_pc, .dred_ftq, .dred_slot, .dred_rop, .dred_rlink,
    .c_cbr(cm_cbr), .c_taken(cm_ctaken), .c_pred(cm_cpred), .c_ftq(cm_cftq), .c_slot(cm_cslot),
    .c_hv(cm_hv), .c_hftq(cm_hftq), .c_tid(cm_tid[0]),
    .ras_v_s(ras_v_t), .ras_top_s(ras_top_t), .ras_tos_s(ras_tos_t), .ras_cnt_s(ras_cnt_t), .ras_tid(fras_tid),
    .ras_rtid(fras_rtid),
    .ras_push(fras_push), .ras_pop(fras_pop), .ras_link(fras_link),
    .ras_rv(fras_rv), .ras_rwr(fras_rwr), .ras_rtos(fras_rtos), .ras_rcnt(fras_rcnt), .ras_rtop(fras_rtop),
    .upd_valid, .upd_way, .upd_pc, .upd_slot, .upd_target, .upd_inval, .upd_tid,
    .iq_valid, .iq_insn, .iq_take,
    .xl_h(xl_f_q), .dst(de_state_h), .priv_h(priv_f_q), .pmp_d_h, .pmp_busy, .rn_block(rn_blk), .rn_acc,
    .tlb_flush, .tlb_flush_tid,
    .it_fill, .it_fill_vpn, .it_fill_lvl, .it_fill_pte, .it_fill_tid,
    .iw_req, .iw_va, .iw_tid, .iw_ack, .iw_done, .iw_ok, .iw_cause,
    .l1i_a_o, .l1i_a_valid_o, .l1i_a_ready_i, .l1i_d_i, .l1i_d_valid_i, .l1i_d_ready_o);

  // ---- Decode ----
  logic [DECODE_WIDTH-1:0] de_valid;
  uop_t [DECODE_WIDTH-1:0] de_uop;
  logic                    de_take;
  tg_decode_stage u_de (
    .clk, .rst, .flush, .dst_h(de_state_h),
    .iq_valid, .iq_insn, .iq_take, .de_valid, .de_uop, .de_take,
    .dred, .dred_tid, .dred_pc, .dred_ftq, .dred_slot, .dred_rop, .dred_rlink, .ras_v, .ras_top, .ras_push, .ras_pop,
    .ras_link);
  if (RAS_ON) begin : g_ras
    // A stack per thread with hart 1 (u_ras thread 0's, g_t1's thread 1's); each takes its thread's operations,
    // repairs, commits and flush. Without hart 1 the one stack, every operation the running thread's
    localparam bit RMT = HART1_ON && NUM_THREADS > 1;
    localparam int RNS = RMT ? 2 : 1;
    logic [RNS-1:0]              rv;
    logic [RNS-1:0][38:1]        rt;
    logic [RNS-1:0][RAS_PW-1:0]  rtos;
    logic [RNS-1:0][RAS_PW:0]    rcnt;
    logic de_s, fr_s, rr_s, cm_s, fl_s;   // decode's, fetch's operation's and repair's, commit's, the flush's stack
    assign de_s = RMT && (RAS_FE ? iq_insn[0].tid[0] : de_uop[0].tid[0]);
    assign fr_s = RMT && fras_tid[0];
    assign rr_s = RMT && fras_rtid[0];
    assign cm_s = RMT && cm_tid[0][0];
    assign fl_s = RMT && flush_tid[0];
    logic dr_s;                                                    // decode's operations' stack (RAS_DEC)
    assign dr_s = RMT && de_uop[0].tid[0];
    for (genvar s = 0; s < RNS; s++) begin : g_s
      logic       sf, sp, sq, sr;
      assign sf = flush && fl_s == 1'(s);
      assign sp = RAS_FE ? fr_s == 1'(s) : dr_s == 1'(s);
      assign sr = RAS_FE && fras_rv && rr_s == 1'(s);
      assign sq = cm_s == 1'(s);
      if (s == 0) begin : g_t0
        tg_ras #(.NE(RAS_ENTRIES), .CW(COMMIT_WIDTH), .LATE(RAS_FE)) u_ras (
          .clk, .rst, .flush(sf), .top_v(rv[s]), .top(rt[s]), .s_tos(rtos[s]), .s_cnt(rcnt[s]),
          .d_push(sp && (RAS_FE ? fras_push : ras_push)), .d_pop(sp && (RAS_FE ? fras_pop : ras_pop)),
          .d_link(RAS_FE ? fras_link : ras_link),
          .r_v(sr), .r_wr(fras_rwr), .r_tos(fras_rtos), .r_cnt(fras_rcnt), .r_top(fras_rtop),
          .c_push(cm_ras_push & {COMMIT_WIDTH{sq}}), .c_pop(cm_ras_pop & {COMMIT_WIDTH{sq}}), .c_link(cm_ras_link));
      end else begin : g_t1
        tg_ras #(.NE(RAS_ENTRIES), .CW(COMMIT_WIDTH), .LATE(RAS_FE)) u_ras (
          .clk, .rst, .flush(sf), .top_v(rv[s]), .top(rt[s]), .s_tos(rtos[s]), .s_cnt(rcnt[s]),
          .d_push(sp && (RAS_FE ? fras_push : ras_push)), .d_pop(sp && (RAS_FE ? fras_pop : ras_pop)),
          .d_link(RAS_FE ? fras_link : ras_link),
          .r_v(sr), .r_wr(fras_rwr), .r_tos(fras_rtos), .r_cnt(fras_rcnt), .r_top(fras_rtop),
          .c_push(cm_ras_push & {COMMIT_WIDTH{sq}}), .c_pop(cm_ras_pop & {COMMIT_WIDTH{sq}}), .c_link(cm_ras_link));
      end
    end
    // fetch's view, by stream (index 0 without hart 1); decode's, its thread's
    for (genvar t = 0; t < NUM_THREADS; t++) begin : g_fv
      assign ras_v_t[t]   = rv[RMT ? t : 0];
      assign ras_top_t[t] = rt[RMT ? t : 0];
      assign ras_tos_t[t] = rtos[RMT ? t : 0];
      assign ras_cnt_t[t] = rcnt[RMT ? t : 0];
    end
    assign ras_v   = rv[de_s];
    assign ras_top = rt[de_s];
  end else begin : g_noras
    assign ras_v     = 1'b0;
    assign ras_top   = '0;
    assign ras_v_t   = '0;
    assign ras_top_t = '0;
    assign ras_tos_t = '0;
    assign ras_cnt_t = '0;
    logic unused_ras;                   // no operation is ever decoded or committed without it
    assign unused_ras = ^{ras_push, ras_pop, ras_link, cm_ras_push, cm_ras_pop, cm_ras_link, fras_push, fras_pop,
                          fras_link, fras_rv, fras_rwr, fras_rtos, fras_rcnt, fras_rtop, fras_tid, fras_rtid};
  end

  // ---- Rename and dispatch ----
  // Per thread (M7's step 3): the ROB's heads, the LSU's LQ and SQ pointers and rename's tails. The LSU's head checks
  // follow the ROB's commit thread (rob_hd_tid, step 4)
  robid_t [NUM_THREADS-1:0] rob_tail_t, rob_head_t;
  tid_t                     rob_hd_tid;
  lqid_t  [NUM_THREADS-1:0] lq_head_t;
  sqid_t  [NUM_THREADS-1:0] sq_head_t, sq_cmt_t;
  logic [N_IQ-1:0][DISPATCH_WIDTH-1:0] iq_bank_free, iq_bank_free2;
  logic [NCOL-1:0] w_vec, iq_busy;
  logic [INT_BANKS-1:0]             rf_we;
  logic [INT_BANKS-1:0][PIDX_W-1:0] rf_widx;
  logic [LLT_ENTRIES-1:0]           llt_rel, llt_done_x, llt_done_l;
  logic [IQ_TAGS-1:0]               tag_free;
  logic                             div_done;
  tid_t                             div_done_tid;   // its thread (rename's per-thread shares, hart 1)
  logic [CW-1:0]                    cm_valid, cm_rd_en;
  logic [CW-1:0][4:0]               cm_rd;
  preg_t [CW-1:0]                   cm_dst, cm_old;
  logic [CW-1:0]                    cm_rd_fp;
  // F and D (EXT_FD): the FP back end's register-file writes (F0: P4, F1: FP loads), issue
  // and returns (P4 below)
  logic [1:0]                       fp_we;
  logic [1:0][FPIDX_W-1:0]          fp_widx;
  logic                             fdiv_iss, fpi_iss, fdiv_done, fpi_pop;
  tid_t                             fp_iss_tid;     // the FP issue's thread (rename's per-thread shares, hart 1)
  logic                             fp_misc_block;
  // FP loads and FP store data between the LSU and P4
  logic                             fld_m2_will, fld_valid, sd_busy;
  logic [FPIDX_W-1:0]               fld_m2_idx, fld_idx;
  logic [63:0]                      fld_data;
  logic [1:0][63:0]                 fsd_data;   // both FP banks (P4): the LSU picks by fsd_tag's bank
  preg_t                            fsd_tag;
  // P4's integer source and FP->int results (driven by P4 with the FP back end)
  logic                             isrc_valid, fpi_valid, fpi_kill, fpi_ready, fpi_dst_en;
  preg_t                            isrc_tag, fpi_dst;
  logic [63:0]                      isrc_data, fpi_data;
  robid_t                           fpi_rob;
  tid_t                             fpi_tid;    // the FP->int head's thread (M7, DR-175: exec's kill)
  llt_t                             fpi_llt;
  logic [4:0]                       fpi_fflags, oth_fflags;
  assign sd_busy    = EXT_FD && isrc_valid;
  // P4's F0 completions (with the FP back end)
  logic                             fp_cmp;
  robid_t                           fp_cmp_rob;
  logic [4:0]                       fp_cmp_fflags;
  logic [CW-1:0][4:0]               cm_fflags;
  // Translation (M3): the TLBs flush with the flush after SFENCE.VMA, a satp change or a PMP
  // write (the TLBs cache PMP results). Each retires alone in slot 0: the flush clears that hart's
  // entries (M7's step 4)
  always_ff @(posedge clk) begin
    tlb_flush     <= !rst && (sfence || satp_wr || pmp_wr);
    tlb_flush_tid <= cm_tid[0];
  end
  logic [NCOL-1:0]                  wake_p4;
  logic [LLT_ENTRIES-1:0]           llt_done_p4;
  logic [IQ_TAGS-1:0]               tag_free_x, tag_free_p4;
  logic                             ds_fire;
  logic [DISPATCH_WIDTH-1:0]        ds_valid;
  uop_t [DISPATCH_WIDTH-1:0]        ds_uop;
  ren_t [DISPATCH_WIDTH-1:0]        ds_ren;
  logic [N_IQ-1:0][DISPATCH_WIDTH-1:0] iq_we;
  logic [DISPATCH_WIDTH-1:0][NCOL-1:0] iq_dep;
  iq_pl_t [DISPATCH_WIDTH-1:0]      iq_pl;
  logic [DISPATCH_WIDTH-1:0][RA-1:0] iq_mdep;
  logic [RA-1:0]                    mx_hold;
  logic [N_ALU-1:0][DISPATCH_WIDTH-1:0][RA-1:0] mx_alloc;
  logic [NCOL-1:0]                  wid_alloc;
  logic [DISPATCH_WIDTH-1:0]        ds_src2_rdy;
  logic                             rn_ready;
  tg_rename u_rn (
    .clk, .rst, .ready(rn_ready), .start(init_done && fe_ready && lsu_ready), .flush, .flush_tid,
    .de_valid, .de_uop, .de_take, .blk_o(rn_blk), .acc_o(rn_acc),
    .rob_head(rob_head_t), .lq_head(lq_head_t), .sq_head(sq_head_t), .sq_cmt(sq_cmt_t), .iq_bank_free,
    .iq_bank_free2, .w_vec, .busy(iq_busy),
    .rf_we, .rf_widx, .llt_rel, .tag_free, .div_done, .div_done_tid,
    .fp_we, .fp_widx, .fdiv_iss, .fpi_iss, .fp_iss_tid, .fdiv_done, .fpi_pop,
    .cm_tid(cm_tid[0]), .cm_valid, .cm_rd_en, .cm_rd, .cm_dst, .cm_old, .cm_rd_fp,
    .ds_fire, .ds_valid, .ds_uop, .ds_ren, .iq_we, .iq_dep, .iq_pl, .iq_mdep, .mx_hold,
    .mx_alloc, .wid_alloc,
    .ds_src2_rdy, .rob_tail(rob_tail_t), .dbg_o(rn_dbg));

  // ---- Issue ----
  logic [NCOL-1:0] wake_reg, wake_x, wake_l, col_clr;
  logic            a1_block, ld_block;
  logic [N_IQ-1:0] iss_valid;
  iq_pl_t [N_IQ-1:0] iss_pl;
  preg_t [N_XQ-1:0][1:0] iss_src_n;     // URF: the RF stage's next source tags
  logic             spec_cancel;                // speculative wakeup's shadow cancel (SPEC_WAKE)
  assign wake_reg = wake_x | wake_l | wake_p4;
  assign tag_free = tag_free_x | tag_free_p4;
  // Returned wakeup tags clear their column in every row (the LLT columns keep the guard)
  always_comb begin
    col_clr = '0;
    col_clr[IQ_TAGS-1:0] = tag_free;
  end
  tg_issue u_is (
    .clk, .rst, .flush, .flush_tid, .disp_we(iq_we), .disp_dep(iq_dep),
    .disp_pl(iq_pl), .disp_mdep(iq_mdep), .bank_free(iq_bank_free), .bank_free2(iq_bank_free2), .mx_hold, .mx_alloc, .alloc(wid_alloc), .wake_reg, .col_clr,
    .w(w_vec), .busy(iq_busy), .a1_block, .ld_block, .fp_misc_block, .iss_valid, .iss_pl, .iss_src_n, .spec_cancel);

  // LLTs are released the cycle after their register is written
  always_ff @(posedge clk) begin
    if (rst) llt_rel <= '0;
    else     llt_rel <= llt_done_x | llt_done_l | llt_done_p4;
  end

  // ---- Execute ----
  logic             ld_m2_will, ld_res_valid;
  logic [PIDX_W-1:0] ld_m2_dst, ld_res_dst;
  logic [63:0]      ld_res_data;
  logic             ld_ag_valid, sta_ag_valid;
  iq_pl_t           ld_ag_pl, sta_ag_pl;
  logic [63:0]      ld_ag_addr, sta_ag_addr;
  preg_t            sd_tag;
  logic [63:0]      sd_data;
  preg_t [CW-1:0]   tr_tag;
  logic [CW-1:0][63:0] tr_data, tr_data_x;
  logic [1:0][CW-1:0][63:0] tr_data_p4;          // both FP banks (P4): the bank select folds in here
  for (genvar j = 0; j < CW; j++) begin : g_trd
    assign tr_data[j] = !(EXT_FD && cm_rd_fp[j]) ? tr_data_x[j] : tr_data_p4[fpreg_bank(tr_tag[j])][j];
  end
  logic [N_ALU-1:0] alu_cmp;
  robid_t [N_ALU-1:0] alu_rob;
  logic             oth_cmp, oth_exc;
  robid_t           oth_rob;
  logic [63:0]      oth_tval;
  logic             br_valid, br_misp, br_exc;
  robid_t           br_rob;
  logic [63:0]      br_npc, br_tval;
  logic             csr_ex_valid, csr_ex_ill;
  iq_pl_t           csr_ex_pl;
  logic [63:0]      csr_ex_src, csr_ex_rdata;
  tg_exec u_ex (
    .clk, .clk2x, .rst, .flush, .spec_cancel, .misa_c, .init_we(!init_done), .init_idx(PIDX_W'(init_q[4:0])),
    .iss_valid(iss_valid[N_XQ-1:0]), .iss_pl(iss_pl[N_XQ-1:0]), .iss_src_n, .a1_block,
    .ld_m2_will, .ld_m2_dst, .ld_res_valid, .ld_res_dst, .ld_res_data,
    .ld_ag_valid, .ld_ag_pl, .ld_ag_addr, .sta_ag_valid, .sta_ag_pl, .sta_ag_addr,
    .sd_tag, .sd_data, .isrc_valid, .isrc_tag, .isrc_data, .fpi_valid, .fpi_kill, .fpi_ready, .fpi_rob, .fpi_llt,
    .fpi_dst_en, .fpi_dst, .fpi_data, .fpi_fflags, .fpi_tid, .flush_tid,
    .tr_tag, .tr_data(tr_data_x), .rf_we_o(rf_we), .rf_widx_o(rf_widx),
    .cmp_valid(alu_cmp), .cmp_rob(alu_rob), .oth_valid(oth_cmp), .oth_rob, .oth_exc, .oth_tval,
    .oth_fflags,
    .br_valid, .br_rob, .br_mispredict(br_misp), .br_npc, .br_exc, .br_tval,
    .upd_valid, .upd_way, .upd_inval, .upd_pc, .upd_slot, .upd_target, .upd_tid,
    .wake_reg(wake_x), .llt_done(llt_done_x), .tag_free(tag_free_x), .div_done, .div_done_tid,
    .csr_ex_valid, .csr_ex_pl, .csr_ex_src, .csr_ex_rdata, .csr_ex_ill);

  // ---- Load/store unit ----
  logic             ld_cmp, ld_cmp_mmio, replay_valid, sq_drained, mmio_busy, st_dropped;
  robid_t           ld_cmp_rob, replay_rob;
  logic [1:0]       st_cmp;
  robid_t [1:0]     st_cmp_rob;
  // The store reports as the ROB takes them: with ROB_STORE_REPORT_LATE (DR-140 #2) a cycle later,
  // together with the ordering replay mark, so a replayed load never commits first. Timing: the
  // store address's TLB and PMP decision leave the ROB's tables.
  // The ordering replay mark comes from the LSU a cycle after the store's search in either case
  // (registered there: the LQ's search leaves the ROB's replay tables). Without #2, for that cycle
  // the ROB holds commit at the replayed load, where the mark would have stopped it: cycle-
  // identical (the load cannot reach the head sooner, as the store that found it completes in the
  // cycle of its search at the earliest).
  // A flush drops the reports registered in its cycle that are its thread's: with hart 1 the other thread's stay
  // (as the ROB's own drop, rdrop), or that thread's entry never completes (M7 step 5c).
  function automatic logic rpt_drop(robid_t e);
    return flush && (!MT || rob_tid(e) == flush_tid);
  endfunction
  logic [1:0]       st_cmp_r;
  robid_t [1:0]     st_cmp_rob_r;
  if (ROB_STORE_REPORT_LATE) begin : g_store_late
    always_ff @(posedge clk) begin
      for (int i = 0; i < 2; i++) st_cmp_r[i] <= !rst && st_cmp[i] && !rpt_drop(st_cmp_rob[i]);
      st_cmp_rob_r <= st_cmp_rob;
    end
  end else begin : g_store_now
    assign st_cmp_r     = st_cmp;
    assign st_cmp_rob_r = st_cmp_rob;
  end
  logic             spx_valid;            // a store's PMP denial after it decided (exception only) ...
  robid_t           spx_rob;
  logic [1:0]       sth_v;                // ... and the stores commit stops before meanwhile
  robid_t [1:0]     sth_rob;
  logic [2:0]       cmh_v;                // commit holds: those stores, and the replayed load while
  robid_t [2:0]     cmh_rob;              // its mark is on its way (a harmless hold with #2)
  assign cmh_v   = {replay_valid, sth_v};
  assign cmh_rob = {replay_rob, sth_rob};
  logic [3:0]       lx_valid, lx_valid_q;
  robid_t [3:0]     lx_rob, lx_rob_q;
  logic [3:0][3:0]  lx_cause, lx_cause_q;
  // The LSU's fault reports reach the ROB a cycle later (DR-140 #1). Timing: the address stage's
  // fault decision leaves the ROB's exception register. A fault is taken only at the head, so the
  // cycle costs about nothing (random +0.03%).
  always_ff @(posedge clk) begin
    for (int i = 0; i < 4; i++) lx_valid_q[i] <= !rst && lx_valid[i] && !rpt_drop(lx_rob[i]);
    lx_rob_q   <= lx_rob;
    lx_cause_q <= lx_cause;
  end
  logic [NCW-1:0]   cm_nld, cm_nst;
  sqid_t [CW-1:0]   tr_sq;
  logic [CW-1:0][63:0] tr_st_va, tr_st_data;
  logic [CW-1:0][1:0]  tr_st_size;
  logic [CW-1:0]       tr_st_wr;
  lqid_t [CW-1:0]      tr_lq;
  logic [CW-1:0][63:0] tr_ld_va;
  logic [CW-1:0][1:0]  tr_ld_size;
  logic                rsv_clr;           // trap or xRET: the LR reservation ends
  logic                tr_irq;            // the ROB takes an interrupt this cycle (the LSU's MMIO issue waits for none)
  logic [1:0]          tlbm_valid;
  robid_t [1:0]        tlbm_rob;
  logic                hd_tlb, hd_retry, hd_fault;
  logic [3:0]          hd_cause;
  logic [63:0]         hd_lva, hd_sva;
  // The LSU's flush: the ROB's. In simulation +xflush=PCT (split builds) adds phantom flushes of the thread that
  // does not run, in cycles with no flush: in PCT% of them and in every one in which the running thread's MMIO read
  // is out (tg_lsu's x_out). The LSU and its walker hold nothing of that thread, so the run must be the same but for
  // its cycles (lockstep, tg_vsim's one bus read per MMIO load, tg_lsu's checks): step 4's per-thread kills tested
  // before a second thread runs. Not with hart 1 (HART1_ON), which runs from step 5c. The counts go to stderr at
  // the end.
  logic lsu_flush;
  tid_t lsu_flush_tid;
`ifdef SYNTHESIS
  assign lsu_flush     = flush;
  assign lsu_flush_tid = flush_tid;
`else
  bit              xf_on;
  int unsigned     xf_pct;
  logic [31:0]     xf_r_q;          // xorshift32: the phantom flushes' own sequence (the testbench's $urandom stays)
  logic            xf_inj;
  longint unsigned xf_n, xf_nx;
  function automatic logic [31:0] xs32(input logic [31:0] x);
    logic [31:0] y;
    y = x ^ (x << 13);
    y = y ^ (y >> 17);
    return y ^ (y << 5);
  endfunction
  initial begin
    xf_on = $value$plusargs("xflush=%d", xf_pct);
    if (xf_on && !SPLIT) $fatal(1, "tg_core: +xflush needs a split build (SPLIT=1)");
    if (xf_on && MT) $fatal(1, "tg_core: +xflush flushes the thread that does not run: not with hart 1 (HART1_ON)");
  end
  assign xf_inj        = xf_on && !rst && !flush && (xf_r_q % 100 < xf_pct || u_lsu.x_out);
  assign lsu_flush     = flush || xf_inj;
  assign lsu_flush_tid = xf_inj ? ~RUN_TID : flush_tid;
  always_ff @(posedge clk) begin
    xf_r_q <= rst ? 32'h2545_f491 : xs32(xf_r_q);
    if (rst) begin
      xf_n  <= 0;
      xf_nx <= 0;
    end else if (xf_inj) begin
      xf_n  <= xf_n + 1;
      if (u_lsu.x_out) xf_nx <= xf_nx + 1;
    end
  end
  final if (xf_on)
    $fwrite(32'h8000_0002, "TG-XFLUSH %m: %0d phantom flushes of thread %0d, %0d with an MMIO read out\n", xf_n,
            ~RUN_TID, xf_nx);
`endif
  tg_lsu u_lsu (
    .clk, .rst, .ready(lsu_ready), .init_we(!init_done), .init_idx(init_q[4:0]), .flush(lsu_flush),
    .flush_tid(lsu_flush_tid), .ds_fire, .ds_valid, .ds_uop,
    .ds_ren,
    .lq_head_o(lq_head_t), .sq_head_o(sq_head_t), .sq_cmt_o(sq_cmt_t),
    .ld_ag_valid, .ld_ag_pl, .ld_ag_addr, .sta_ag_valid, .sta_ag_pl, .sta_ag_addr, .ld_block,
    .ld_m2_will, .ld_m2_dst, .ld_res_valid, .ld_res_dst, .ld_res_data,
    .wake_ld(wake_l), .llt_done(llt_done_l), .fld_m2_will, .fld_m2_idx, .fld_valid, .fld_idx,
    .fld_data, .sd_tag, .sd_data, .sd_busy, .fsd_tag, .fsd_data, .fp_we, .fp_widx,
    .ds_src2_rdy, .rf_we, .rf_widx,
    .ld_cmp_valid(ld_cmp), .ld_cmp_rob, .ld_cmp_mmio, .st_cmp_valid(st_cmp), .st_cmp_rob,
    .exc_valid(lx_valid), .exc_rob(lx_rob), .exc_cause(lx_cause), .spx_valid, .spx_rob, .sth_v, .sth_rob,
    .replay_valid, .replay_rob, .rob_head(rob_head_t), .hd_tid(rob_hd_tid), .cm_tid(cm_tid[0]), .cm_nld, .cm_nst,
    .tr_sq, .tr_st_wr, .tr_st_va,
    .tr_st_data,
    .tr_st_size, .tr_lq, .tr_ld_va, .tr_ld_size, .sq_drained, .mmio_busy, .irq_go(tr_irq), .rsv_clr, .st_dropped,
    .priv(priv_l_q), .priv_d(priv_dl_q), .sum(sum_l_q), .mxr(mxr_l_q), .satp_sv39(sv39_l_q),
    .satp_ppn(satp_ppn_l_q), .pmp_d(pmp_d_h), .pmp_al(pmp_al_h), .pmp_p2m(pmp_p2m_h), .tlb_flush, .tlb_flush_tid,
    .tlbm_valid, .tlbm_rob, .hd_tlb, .hd_retry, .hd_fault, .hd_cause, .hd_lva, .hd_sva,
    .iw_req, .iw_va, .iw_tid, .iw_ack, .iw_done, .iw_ok, .iw_cause,
    .it_fill, .it_fill_vpn, .it_fill_lvl, .it_fill_pte, .it_fill_tid,
    .l1d_a_o, .l1d_a_valid_o, .l1d_a_ready_i, .l1d_b_i, .l1d_b_valid_i, .l1d_b_ready_o,
    .l1d_c_o, .l1d_c_valid_o, .l1d_c_ready_i, .l1d_d_i, .l1d_d_valid_i, .l1d_d_ready_o,
    .l1d_e_o, .l1d_e_valid_o, .l1d_e_ready_i,
    .mmio_a_o, .mmio_a_valid_o, .mmio_a_ready_i, .mmio_d_i, .mmio_d_valid_i, .mmio_d_ready_o,
    .dbg_o(lsu_dbg));

  // ---- CSRs ----
  logic             cm_csr, tr_valid, mret, sret, irq_take, wfi_wake, csr_cold_busy;
  logic [NUM_THREADS-1:0] wfi_wake_h;           // each hart's WFI wake (the ROB's turns with hart 1)
  priv_e            priv_cm;                    // the commit head's thread's mode (the trace's records)
  logic [NCW-1:0]   cm_n;
  logic [5:0]       tr_code, irq_code;
  logic [63:0]      tr_epc, tr_tval, trap_target, irq_target, xepc;
  logic             xret_v, xret_s;
  assign rsv_clr = tr_valid || mret || sret;
  assign priv_cm = MT ? priv_h[rob_hd_tid] : priv;
  tg_csr #(.CORE_ID(CORE_ID)) u_csr (
    .clk, .rst, .flush, .flush_tid, .ex_valid(csr_ex_valid), .ex_pl(csr_ex_pl), .ex_src(csr_ex_src),
    .ex_rdata(csr_ex_rdata), .ex_ill(csr_ex_ill),
    .cm_tid0(cm_tid[0]), .hd_tid(rob_hd_tid), .cm_csr, .cm_n, .tr_valid, .tr_irq, .tr_code, .tr_epc, .tr_tval, .mret,
    .sret,
    .trap_target, .irq_target, .xret_v, .xret_s, .xepc_o(xepc), .irq_take, .irq_code, .wfi_wake, .wfi_wake_h,
    .misa_m, .misa_b,
    .misa_c, .misa_a, .misa_f, .misa_d, .fs, .fc_fflags, .fc_frm, .fc_wvalid, .fc_waddr,
    .fc_wdata, .fs_dirty, .cm_pc(tr_epc), .priv, .tvm, .tw, .tsr, .satp_sv39,
    .satp_asid, .satp_wr, .pmp_d, .pmp_wr, .pmp_busy, .cold_busy(csr_cold_busy), .dst_h(dst_csr), .priv_h, .priv_d_h, .sum_h, .mxr_h, .sv39_h, .satp_ppn_h,
    .pmp_d_h, .pmp_al_h, .pmp_p2m_h,
    .irq_mei(irq_mei_i), .irq_mti(irq_mti_i), .irq_msi(irq_msi_i), .irq_sei(irq_sei_i),
    .irq_ssi(irq_ssi_i), .mtime(mtime_i));

  // ---- ROB and commit ----
  // The ROB's commit gate needs neither rename's ready nor the init flag: both are one-time
  // initialisation flags, and the ROB holds an entry only after rename fired, which needed them
  // (timing, DR-145: G6's FP free list's init flag -> rename's ready -> commit -> the free-list
  // count and the CSR file, -1.40 and -1.01 ns; asserted below)
`ifndef SYNTHESIS
  always @(posedge clk)
    if (rs_fq && !rst && (|cm_valid || flush))
      assert (init_done && rn_ready) else $error("tg_core: the ROB commits before rename is ready");
`endif
  tg_rob #(.CORE_ID(CORE_ID)) u_rob (
    .clk, .rst, .ready(!trace_stall_q), .ds_fire, .ds_valid, .ds_uop, .ds_ren, .head_o(rob_head_t), .hd_tid_o(rob_hd_tid),
    .alu_cmp, .alu_rob, .oth_cmp, .oth_rob, .oth_exc, .oth_tval, .oth_fflags,
    .fp_cmp, .fp_cmp_rob, .fp_cmp_fflags, .cm_fflags, .cm_tid,
    .br_valid, .br_rob, .br_misp, .br_npc, .br_exc, .br_tval,
    .ld_cmp, .ld_rob(ld_cmp_rob), .ld_mmio(ld_cmp_mmio), .st_cmp(st_cmp_r), .st_rob(st_cmp_rob_r),
    .lx_valid(lx_valid_q), .lx_rob(lx_rob_q), .lx_cause(lx_cause_q), .spx_valid, .spx_rob,
    .cmh_v, .cmh_rob,
    .replay_valid,
    .replay_rob,
    .tlbm_valid, .tlbm_rob, .hd_tlb, .hd_retry, .hd_fault, .hd_cause, .hd_lva, .hd_sva,
    .sq_drained, .mmio_busy,
    .cm_valid, .cm_rd_en, .cm_rd_fp, .cm_rd, .cm_dst, .cm_old, .cm_ras_push, .cm_ras_pop, .cm_ras_link,
    .cm_cbr, .cm_ctaken, .cm_cpred, .cm_cftq, .cm_cslot, .cm_hv, .cm_hftq,
    .cm_nld, .cm_nst, .tr_sq, .tr_st_wr, .tr_st_va,
    .tr_st_data, .tr_st_size, .tr_lq, .tr_ld_va, .tr_ld_size, .tr_tag, .tr_data,
    .cm_csr, .cm_n, .tr_valid, .tr_irq, .tr_code, .tr_epc, .tr_tval, .mret, .sret, .sfence,
    .trap_target, .irq_target, .xret_v, .xret_s, .xepc, .priv(priv_cm), .irq_take, .irq_code, .wfi_wake, .wfi_wake_h,
    .csr_hold(csr_cold_busy), .flush, .flush_tid, .flush_pc, .icinv, .trace_o, .trace_valid_o);

  // ---- Unused in M2 ----
  assign merr_o           = '0;
  assign trace_wb_o       = '0;
  assign trace_wb_valid_o = '0;

  // ---- F and D (EXT_FD): P4 (tg_fp_exec, docs/spec/fpu.md) and fcsr (tg_fcsr) ----
  if (EXT_FD) begin : g_p4
    fp_iss_t p4_pl;
    fpi_t    p4_fpi;
    logic    p4_cmp;
    wid_t    p4_cmp_wid;
    assign p4_pl = '{tid: iss_pl[Q_FP].tid, rob: iss_pl[Q_FP].rob, wid: iss_pl[Q_FP].wid,
                     llt: iss_pl[Q_FP].llt, dst_en: iss_pl[Q_FP].dst_en, dst: iss_pl[Q_FP].dst,
                     src1: iss_pl[Q_FP].src1, src2: iss_pl[Q_FP].src2, src3: iss_pl[Q_FP].src3,
                     src1_fp: iss_pl[Q_FP].src1_fp, fop: iss_pl[Q_FP].fop, fmt: iss_pl[Q_FP].fmt,
                     src_fmt: iss_pl[Q_FP].src_fmt, ifmt: iss_pl[Q_FP].ifmt, rm: iss_pl[Q_FP].rm,
                     fp_int: iss_pl[Q_FP].fp_int, fp_div: iss_pl[Q_FP].fp_div};
    assign fdiv_iss = iss_valid[Q_FP] && iss_pl[Q_FP].fp_div;
    assign fpi_iss  = iss_valid[Q_FP] && iss_pl[Q_FP].fp_int;
    assign fp_iss_tid = iss_pl[Q_FP].tid;
    logic f0_we;
    logic [FPIDX_W-1:0] f0_widx;
    tid_t       p4_cmp_tid, p4_er_tid;
    logic       p4_er_v;
    logic [4:0] p4_er_ff;
    logic [2:0] fc_frm_rd;
    tg_fp_exec #(.FDIV_Q(FDIV_INFLIGHT), .FPI_Q(FPI_INFLIGHT)) u_p4 (
      .clk, .rst, .flush, .flush_tid,
      .init_we(!init_done), .init_bank(1'b0), .init_idx(FPIDX_W'(init_q[4:0])),
      .iss_valid(iss_valid[Q_FP]), .iss_pl(p4_pl), .fmisc_block(fp_misc_block),
      .isrc_valid, .isrc_tag, .isrc_data,
      .fld_m2_will, .fld_m2_idx, .fld_valid, .fld_idx, .fld_data,
      .fsd_tag, .fsd_data, .tr_tag, .tr_data(tr_data_p4),
      .f0_we_o(f0_we), .f0_widx_o(f0_widx),
      .wake_reg(wake_p4), .llt_done(llt_done_p4),
      .cmp_valid(p4_cmp), .cmp_tid(p4_cmp_tid), .cmp_rob(fp_cmp_rob), .cmp_wid(p4_cmp_wid),
      .cmp_fflags(fp_cmp_fflags),
      .fpi_valid, .fpi_ready, .fpi_o(p4_fpi), .fpi_kill, .fpi_pop,
      .fdiv_done, .fdiv_ret_valid(1'b0), .fdiv_ret_tid('0), .fdiv_ret_llt('0),
      .er_valid(p4_er_v), .er_tid(p4_er_tid), .er_fflags(p4_er_ff));
    assign fp_cmp     = p4_cmp;
    assign fp_we      = {fld_valid, f0_we};
    assign fp_widx    = {fld_idx, f0_widx};
    assign fpi_rob    = p4_fpi.rob;
    assign fpi_tid    = p4_fpi.tid;
    assign fpi_llt    = p4_fpi.llt;
    assign fpi_dst_en = p4_fpi.dst_en;
    assign fpi_dst    = p4_fpi.dst;
    assign fpi_data   = p4_fpi.data;
    assign fpi_fflags = p4_fpi.fflags;
    // An F0 result's wakeup tag returns 2 cycles after its write, as a MUL's (tg_exec). A flush drops its thread's
    // returns in flight (rename's flush returns that thread's tags); with hart 1 the other thread's go on, else a
    // sibling's flush lost them and the tags ran out (a hart parked in WFI flushes at each timeout)
    logic [1:0]              ptf_v_q;
    logic [1:0][WTAG_W-1:0]  ptf_id_q;
    tid_t                    ptf_t_q;          // the first stage's thread (the second's frees this cycle)
    always_ff @(posedge clk) begin
      if (rst || (flush && !MT)) ptf_v_q <= '0;
      else ptf_v_q <= {ptf_v_q[0] && !(flush && ptf_t_q == flush_tid),
                       p4_cmp && int'(p4_cmp_wid) < IQ_TAGS && !(flush && p4_cmp_tid == flush_tid)};
      ptf_id_q <= {ptf_id_q[0], p4_cmp_wid[WTAG_W-1:0]};
      ptf_t_q  <= p4_cmp_tid;
    end
    always_comb begin
      tag_free_p4 = '0;
      if (ptf_v_q[1]) tag_free_p4[ptf_id_q[1]] = 1'b1;
    end
    // fcsr: per hart (tg_fcsr). The flags of each retiring FP op go to its thread; a CSR instruction
    // reads at execute (the executing thread's with hart 1, else the running thread's) and writes at
    // commit, alone at the head (slot 0); frm is the running thread's, frm_h each hart's (decode);
    // FS-dirty goes to each hart's mstatus (tg_csr).
    logic [CW-1:0] cm_fpr;
    for (genvar j = 0; j < CW; j++) begin : g_cf
      assign cm_fpr[j] = cm_valid[j] && cm_rd_en[j] && cm_rd_fp[j];
    end
    logic [NUM_THREADS-1:0][2:0] frm_t;
    logic [NUM_THREADS-1:0]      fs_dirty_t, er_busy_t;
    tg_fcsr u_fcsr (
      .clk, .rst, .frm_o(frm_t), .csr_rtid(MT ? csr_ex_pl.tid : RUN_TID), .csr_fflags(fc_fflags), .csr_frm(fc_frm_rd),
      .csr_wvalid(fc_wvalid), .csr_wtid(cm_tid[0]), .csr_waddr(fc_waddr), .csr_wdata(fc_wdata),
      .cm_valid, .cm_tid, .cm_fflags, .cm_fpr,
      .er_ret_valid(1'b0), .er_ret_tid('0), .er_valid(1'b0), .er_tid('0), .er_fflags('0),
      .er_busy(er_busy_t), .fs_dirty(fs_dirty_t));
    assign frm      = frm_t[RUN_TID];
    assign fc_frm   = MT ? fc_frm_rd : frm_t[RUN_TID];   // (tg_fcsr's read: the executing thread's with hart 1)
    assign frm_h    = frm_t;
    assign fs_dirty = fs_dirty_t;
    logic unused;
    assign unused = ^{er_busy_t, frm_t, p4_fpi.wid, p4_cmp_tid, p4_er_tid,
                      p4_er_v, p4_er_ff, fc_frm_rd};
  end else begin : g_nop4
    assign fdiv_iss      = 1'b0;
    assign fpi_iss       = 1'b0;
    assign fp_iss_tid    = '0;
    assign fp_misc_block = 1'b0;
    assign isrc_valid    = 1'b0;
    assign isrc_tag      = '0;
    assign fsd_data      = '0;
    assign tr_data_p4    = '0;
    assign wake_p4       = '0;
    assign llt_done_p4   = '0;
    assign fp_cmp        = 1'b0;
    assign fp_cmp_rob    = '0;
    assign fp_cmp_fflags = '0;
    assign fpi_valid     = 1'b0;
    assign fpi_kill      = 1'b0;
    assign fpi_pop       = 1'b0;
    assign fdiv_done     = 1'b0;
    assign fp_we         = '0;
    assign fp_widx       = '0;
    assign fpi_rob       = '0;
    assign fpi_tid       = '0;
    assign fpi_llt       = '0;
    assign fpi_dst_en    = 1'b0;
    assign fpi_dst       = '0;
    assign fpi_data      = '0;
    assign fpi_fflags    = '0;
    assign tag_free_p4   = '0;
    assign frm           = '0;
    assign frm_h         = '0;
    assign fc_fflags     = '0;
    assign fc_frm        = '0;
    assign fs_dirty      = '0;
    logic unused;
    assign unused = ^{fld_m2_will, fld_m2_idx, fld_valid, fld_idx, fld_data, fsd_tag,
                      isrc_data, fpi_ready, cm_fflags, fc_wvalid, fc_waddr, fc_wdata};
  end

  logic unused;
  assign unused = ^{debug_req_i, rob_tail_t,
                    st_dropped, satp_asid};       // the TLBs flush on satp changes: no ASID tags
  // Board debug (DBG_WORD): the status word, the allocation logs and the select, a register
  if (DBG_WORD) begin : g_dbg
    logic [31:0] dbg_q;
    always_ff @(posedge clk)
      dbg_q <= {flush, trace_stall_q, lsu_dbg, 6'(rob_cnt_t(rob_tail_t[RUN_TID], rob_head_t[RUN_TID])), rn_dbg};
    // The allocation log (words 1-31): slots 0 and 1 of the first dispatch groups and commit cycles
    function automatic logic [14:0] dslot(input logic v, input logic fp, input logic [4:0] rd,
                                          input preg_t p);
      return {v, fp, rd, 8'(p)};
    endfunction
    logic [15:0][31:0] dlog_q;                      // (word 0 is the status: entry 0 unused)
    logic [15:0][31:0] clog_q;
    logic [3:0]        dn_q;                          // the next dispatch word, 0: full
    logic [4:0]        cn_q;                          // the next commit word, 16: full
    logic [31:0]       dbg_w, dbg_o_q;
    logic [1:0][14:0]  ds_e, cm_e;
    always_comb begin
      ds_e = '0;
      cm_e = '0;
      for (int k = 0; k < 2 && k < DISPATCH_WIDTH; k++)
        ds_e[k] = dslot(ds_valid[k] && ds_uop[k].d.rd_en, ds_uop[k].d.rd_fp, ds_uop[k].d.rd, ds_ren[k].dst);
      for (int j = 0; j < 2 && j < CW; j++)
        cm_e[j] = dslot(cm_valid[j] && cm_rd_en[j], cm_rd_fp[j], cm_rd[j], cm_old[j]);
    end
    always_ff @(posedge clk) begin
      if (rst) begin
        dn_q <= 4'd1;
        cn_q <= '0;
      end else begin
        if (ds_fire && |ds_valid && dn_q != '0) begin
          dlog_q[dn_q] <= {1'b0, ds_e[1], 1'b0, ds_e[0]};
          dn_q <= dn_q + 1'b1;                        // 15 -> 0: full
        end
        if (|cm_valid && !cn_q[4]) begin
          clog_q[cn_q[3:0]] <= {1'b0, cm_e[1], 1'b0, cm_e[0]};
          cn_q <= cn_q + 1'b1;
        end
      end
    end
    always_comb begin
      if (dbg_sel_i == '0)    dbg_w = dbg_q;
      else if (!dbg_sel_i[4]) dbg_w = dlog_q[dbg_sel_i[3:0]];
      else                    dbg_w = clog_q[dbg_sel_i[3:0]];
    end
    always_ff @(posedge clk) dbg_o_q <= dbg_w;
    assign dbg_o = dbg_o_q;
  end else begin : g_nodbg
    assign dbg_o = '0;
    logic unused_dbg;
    assign unused_dbg = ^{dbg_sel_i, rn_dbg, lsu_dbg};
  end
endmodule
