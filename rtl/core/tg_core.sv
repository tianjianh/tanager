// Tanager core: the port contract of docs/spec/interfaces.md §1–§5.
// M2 core alpha (docs/spec/core-pipeline.md, core-lsu.md): an out-of-order RV64IM pipeline,
// machine mode, one hart running (hart 0; SMT2 builds compile with tid carried everywhere).
//   tg_fetch -> tg_decode_stage -> tg_rename (RN, DS) -> tg_issue -> tg_exec / tg_lsu -> tg_rob
// with tg_csr beside commit. Every recovery is at commit: tg_rob registers flush and the
// redirect PC, and every unit clears its thread's state in that cycle.
module tg_core
  import tg_pkg::*, tg_tl_pkg::*, tg_trace_pkg::*, tg_core_pkg::*;
#(
  parameter int unsigned CORE_ID = 0  // used for mhartid and trace hart IDs
) (
  input  logic                         clk,
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
  input  logic                         trace_stall_i     // interfaces.md v1.3: hold commit
);
  localparam int NPR = INT_BANKS * INT_PREGS_PER_BANK;
  localparam int CW  = COMMIT_WIDTH;
  localparam int NCW = idx_w(CW + 1);

  // ---- Reset sequence: zero x0..x31's initial registers (bank 0, indices 0..31) ----
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

  // ---- Flush and redirect from commit ----
  logic        flush, icinv;
  tid_t        flush_tid;
  logic [63:0] flush_pc;

  // ---- Mode, translation and PMP state (tg_csr) ----
  logic misa_m, misa_b, misa_c, misa_a;
  priv_e priv, priv_d;
  logic  tvm, tw, tsr, sum, mxr, satp_sv39;
  logic [15:0] satp_asid;
  logic [43:0] satp_ppn;
  pmp_d_t [15:0]     pmp_d;
  logic [2:0]        pmp_al;
  logic        satp_wr, pmp_wr, sfence, tlb_flush;
  // Translation (M3): the TLBs flush with the flush after SFENCE.VMA, a satp change or a PMP
  // write (the TLBs cache PMP results)
  always_ff @(posedge clk) tlb_flush <= !rst && (sfence || satp_wr || pmp_wr);
  logic        iw_req, iw_ack, iw_done, iw_ok, it_fill;
  logic [63:0] iw_va;
  logic [3:0]  iw_cause;
  logic [26:0] it_fill_vpn;
  logic [15:0] it_fill_asid;
  logic [1:0]  it_fill_lvl;
  tlb_pte_t    it_fill_pte;

  // ---- Front end ----
  logic        fe_ready, lsu_ready;
  logic        dred;
  logic [63:0] dred_pc;
  logic        upd_valid, upd_way, upd_inval;
  logic [63:0] upd_pc, upd_target;
  logic [SLOT_W-1:0] upd_slot;
  logic [DECODE_WIDTH-1:0]   iq_valid;
  fe_insn_t [DECODE_WIDTH-1:0] iq_insn;
  logic [idx_w(DECODE_WIDTH + 1)-1:0] iq_take;
  tg_fetch u_fetch (
    .clk, .rst, .boot_pc(64'(boot_addr_i)), .ready(fe_ready),
    .flush, .flush_pc, .icinv, .dred, .dred_pc,
    .upd_valid, .upd_way, .upd_pc, .upd_slot, .upd_target, .upd_inval,
    .iq_valid, .iq_insn, .iq_take,
    .xl_i(EXT_SU && satp_sv39 && priv != PRIV_M), .priv, .asid(satp_asid), .pmp_d, .tlb_flush,
    .it_fill, .it_fill_vpn, .it_fill_asid, .it_fill_lvl, .it_fill_pte,
    .iw_req, .iw_va, .iw_ack, .iw_done, .iw_ok, .iw_cause,
    .l1i_a_o, .l1i_a_valid_o, .l1i_a_ready_i, .l1i_d_i, .l1i_d_valid_i, .l1i_d_ready_o);

  // ---- Decode ----
  logic [DECODE_WIDTH-1:0] de_valid;
  uop_t [DECODE_WIDTH-1:0] de_uop;
  logic                    de_take;
  tg_decode_stage u_de (
    .clk, .rst, .flush, .misa_m, .misa_b, .misa_c, .misa_a, .priv, .tvm, .tw, .tsr, .iq_valid, .iq_insn, .iq_take, .de_valid, .de_uop, .de_take,
    .dred, .dred_pc);

  // ---- Rename and dispatch ----
  robid_t rob_head, rob_tail;
  lqid_t  lq_head;
  sqid_t  sq_head, sq_cmt;
  logic [N_IQ-1:0][DISPATCH_WIDTH-1:0] iq_bank_free;
  logic [NCOL-1:0] w_vec, iq_busy;
  logic [INT_BANKS-1:0]             rf_we;
  logic [INT_BANKS-1:0][PIDX_W-1:0] rf_widx;
  logic [LLT_ENTRIES-1:0]           llt_rel, llt_done_x, llt_done_l;
  logic                             div_done;
  logic [CW-1:0]                    cm_valid, cm_rd_en;
  logic [CW-1:0][4:0]               cm_rd;
  preg_t [CW-1:0]                   cm_dst, cm_old;
  logic                             ds_fire;
  logic [DISPATCH_WIDTH-1:0]        ds_valid;
  uop_t [DISPATCH_WIDTH-1:0]        ds_uop;
  ren_t [DISPATCH_WIDTH-1:0]        ds_ren;
  logic [N_IQ-1:0][DISPATCH_WIDTH-1:0] iq_we;
  logic [DISPATCH_WIDTH-1:0][NCOL-1:0] iq_dep, iq_wake;
  iq_pl_t [DISPATCH_WIDTH-1:0]      iq_pl;
  logic [DISPATCH_WIDTH-1:0][RA-1:0] iq_mdep;
  logic [RA-1:0]                    mx_hold;
  logic [N_ALU-1:0][DISPATCH_WIDTH-1:0][RA-1:0] mx_alloc;
  logic [NCOL-1:0]                  wid_alloc;
  logic [NPR-1:0]                   ready_vec;
  logic                             rn_ready;
  tg_rename u_rn (
    .clk, .rst, .ready(rn_ready), .start(init_done && fe_ready && lsu_ready), .flush,
    .de_valid, .de_uop, .de_take,
    .rob_head, .lq_head, .sq_head, .sq_cmt, .iq_bank_free, .w_vec, .busy(iq_busy),
    .rf_we, .rf_widx, .llt_rel, .div_done,
    .cm_valid, .cm_rd_en, .cm_rd, .cm_dst, .cm_old,
    .ds_fire, .ds_valid, .ds_uop, .ds_ren, .iq_we, .iq_dep, .iq_wake, .iq_pl, .iq_mdep, .mx_hold,
    .mx_alloc, .wid_alloc,
    .ready_vec, .rob_tail);

  // ---- Issue ----
  logic [NCOL-1:0] wake_reg, wake_x, wake_l, col_clr, col_rob;
  logic            a1_block, ld_block;
  logic [N_IQ-1:0] iss_valid;
  iq_pl_t [N_IQ-1:0] iss_pl;
  assign wake_reg = wake_x | wake_l;
  always_comb begin
    col_clr = col_rob;
    for (int t = 0; t < LLT_ENTRIES; t++) if (llt_rel[t]) col_clr[ROB_ENTRIES + t] = 1'b1;
  end
  tg_issue u_is (
    .clk, .rst, .flush, .flush_tid, .disp_we(iq_we), .disp_dep(iq_dep), .disp_wake(iq_wake),
    .disp_pl(iq_pl), .disp_mdep(iq_mdep), .bank_free(iq_bank_free), .mx_hold, .mx_alloc, .alloc(wid_alloc), .wake_reg, .col_clr,
    .w(w_vec), .busy(iq_busy), .a1_block, .ld_block, .iss_valid, .iss_pl);

  // LLTs are released the cycle after their register is written
  always_ff @(posedge clk) begin
    if (rst) llt_rel <= '0;
    else     llt_rel <= llt_done_x | llt_done_l;
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
  logic [CW-1:0][63:0] tr_data;
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
    .clk, .rst, .flush, .misa_c, .init_we(!init_done), .init_idx(PIDX_W'(init_q[4:0])),
    .iss_valid, .iss_pl, .a1_block,
    .ld_m2_will, .ld_m2_dst, .ld_res_valid, .ld_res_dst, .ld_res_data,
    .ld_ag_valid, .ld_ag_pl, .ld_ag_addr, .sta_ag_valid, .sta_ag_pl, .sta_ag_addr,
    .sd_tag, .sd_data, .tr_tag, .tr_data, .rf_we_o(rf_we), .rf_widx_o(rf_widx),
    .cmp_valid(alu_cmp), .cmp_rob(alu_rob), .oth_valid(oth_cmp), .oth_rob, .oth_exc, .oth_tval,
    .br_valid, .br_rob, .br_mispredict(br_misp), .br_npc, .br_exc, .br_tval,
    .upd_valid, .upd_way, .upd_inval, .upd_pc, .upd_slot, .upd_target,
    .wake_reg(wake_x), .llt_done(llt_done_x), .div_done,
    .csr_ex_valid, .csr_ex_pl, .csr_ex_src, .csr_ex_rdata, .csr_ex_ill);

  // ---- Load/store unit ----
  logic             ld_cmp, ld_cmp_mmio, replay_valid, sq_drained, mmio_busy, st_dropped;
  robid_t           ld_cmp_rob, replay_rob;
  logic [1:0]       st_cmp;
  robid_t [1:0]     st_cmp_rob;
  logic [3:0]       lx_valid;
  robid_t [3:0]     lx_rob;
  logic [3:0][3:0]  lx_cause;
  logic [3:0][63:0] lx_tval;
  logic [NCW-1:0]   cm_nld, cm_nst;
  sqid_t [CW-1:0]   tr_sq;
  logic [CW-1:0][63:0] tr_st_va, tr_st_data;
  logic [CW-1:0][1:0]  tr_st_size;
  logic [CW-1:0]       tr_st_wr;
  logic                rsv_clr;           // trap or xRET: the LR reservation ends
  logic [1:0]          tlbm_valid;
  robid_t [1:0]        tlbm_rob;
  logic                hd_retry, hd_fault;
  logic [3:0]          hd_cause;
  logic [63:0]         hd_tval;
  tg_lsu u_lsu (
    .clk, .rst, .ready(lsu_ready), .flush, .ds_fire, .ds_valid, .ds_uop, .ds_ren,
    .lq_head_o(lq_head), .sq_head_o(sq_head), .sq_cmt_o(sq_cmt),
    .ld_ag_valid, .ld_ag_pl, .ld_ag_addr, .sta_ag_valid, .sta_ag_pl, .sta_ag_addr, .ld_block,
    .ld_m2_will, .ld_m2_dst, .ld_res_valid, .ld_res_dst, .ld_res_data,
    .wake_ld(wake_l), .llt_done(llt_done_l), .sd_tag, .sd_data, .ready_vec,
    .ld_cmp_valid(ld_cmp), .ld_cmp_rob, .ld_cmp_mmio, .st_cmp_valid(st_cmp), .st_cmp_rob,
    .exc_valid(lx_valid), .exc_rob(lx_rob), .exc_cause(lx_cause), .exc_tval(lx_tval),
    .replay_valid, .replay_rob, .rob_head, .cm_nld, .cm_nst, .tr_sq, .tr_st_wr, .tr_st_va, .tr_st_data,
    .tr_st_size, .sq_drained, .mmio_busy, .rsv_clr, .st_dropped,
    .priv, .priv_d, .sum, .mxr, .satp_sv39, .satp_asid, .satp_ppn, .pmp_d, .pmp_al, .tlb_flush,
    .tlbm_valid, .tlbm_rob, .hd_retry, .hd_fault, .hd_cause, .hd_tval,
    .iw_req, .iw_va, .iw_ack, .iw_done, .iw_ok, .iw_cause,
    .it_fill, .it_fill_vpn, .it_fill_asid, .it_fill_lvl, .it_fill_pte,
    .l1d_a_o, .l1d_a_valid_o, .l1d_a_ready_i, .l1d_b_i, .l1d_b_valid_i, .l1d_b_ready_o,
    .l1d_c_o, .l1d_c_valid_o, .l1d_c_ready_i, .l1d_d_i, .l1d_d_valid_i, .l1d_d_ready_o,
    .l1d_e_o, .l1d_e_valid_o, .l1d_e_ready_i,
    .mmio_a_o, .mmio_a_valid_o, .mmio_a_ready_i, .mmio_d_i, .mmio_d_valid_i, .mmio_d_ready_o);

  // ---- CSRs ----
  logic             cm_csr, tr_valid, tr_irq, mret, sret, irq_take, wfi_wake;
  logic [NCW-1:0]   cm_n;
  logic [5:0]       tr_code, irq_code;
  logic [63:0]      tr_epc, tr_tval, trap_target, mepc, sepc;
  assign rsv_clr = tr_valid || mret || sret;
  tg_csr #(.CORE_ID(CORE_ID)) u_csr (
    .clk, .rst, .flush, .ex_valid(csr_ex_valid), .ex_pl(csr_ex_pl), .ex_src(csr_ex_src),
    .ex_rdata(csr_ex_rdata), .ex_ill(csr_ex_ill),
    .cm_csr, .cm_n, .tr_valid, .tr_irq, .tr_code, .tr_epc, .tr_tval, .mret, .sret,
    .trap_target, .mepc_o(mepc), .sepc_o(sepc), .irq_take, .irq_code, .wfi_wake, .misa_m, .misa_b,
    .misa_c, .misa_a, .cm_pc(tr_epc), .priv, .priv_d, .tvm, .tw, .tsr, .sum, .mxr, .satp_sv39,
    .satp_asid, .satp_ppn, .satp_wr, .pmp_d, .pmp_al, .pmp_wr,
    .irq_mei(irq_mei_i[0]), .irq_mti(irq_mti_i[0]), .irq_msi(irq_msi_i[0]), .irq_sei(irq_sei_i[0]),
    .irq_ssi(irq_ssi_i[0]), .mtime(mtime_i));

  // ---- ROB and commit ----
  tg_rob #(.CORE_ID(CORE_ID)) u_rob (
    .clk, .rst, .ready(init_done && rn_ready && !trace_stall_q), .ds_fire, .ds_valid, .ds_uop, .ds_ren, .head_o(rob_head),
    .alu_cmp, .alu_rob, .oth_cmp, .oth_rob, .oth_exc, .oth_tval,
    .br_valid, .br_rob, .br_misp, .br_npc, .br_exc, .br_tval,
    .ld_cmp, .ld_rob(ld_cmp_rob), .ld_mmio(ld_cmp_mmio), .st_cmp, .st_rob(st_cmp_rob),
    .lx_valid, .lx_rob, .lx_cause, .lx_tval, .replay_valid, .replay_rob,
    .tlbm_valid, .tlbm_rob, .hd_retry, .hd_fault, .hd_cause, .hd_tval,
    .sq_drained, .mmio_busy,
    .cm_valid, .cm_rd_en, .cm_rd, .cm_dst, .cm_old, .cm_nld, .cm_nst, .tr_sq, .tr_st_wr, .tr_st_va,
    .tr_st_data, .tr_st_size, .tr_tag, .tr_data, .col_clr(col_rob),
    .cm_csr, .cm_n, .tr_valid, .tr_irq, .tr_code, .tr_epc, .tr_tval, .mret, .sret, .sfence,
    .trap_target, .mepc, .sepc, .priv, .irq_take, .irq_code, .wfi_wake,
    .flush, .flush_tid, .flush_pc, .icinv, .trace_o, .trace_valid_o);

  // ---- Unused in M2 ----
  assign merr_o           = '0;
  assign trace_wb_o       = '0;
  assign trace_wb_valid_o = '0;

  logic unused;
  assign unused = ^{irq_sei_i, irq_ssi_i, debug_req_i, irq_mei_i, irq_mti_i, irq_msi_i, rob_tail,
                    st_dropped};
endmodule
