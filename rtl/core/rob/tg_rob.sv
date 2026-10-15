// Reorder buffer and commit for M2 (docs/spec/core-pipeline.md §8, §9.3-9.4, §11).
//   Payload: ROB_BANKS-way interleaved LUTRAM, written at dispatch, read at the head.
//   Flags per entry: complete, exc, mispredict and mmio as toggle tables in LUTRAM, one per
//   reporting port (below); replay in flip-flops (an entry may be marked more than once).
// A replay marked tlb (a DTLB miss) waits at the head for the LSU: hd_retry (the DTLB now
// translates it: flush and refetch) or hd_fault (the deciding walk faulted: trap).
//   Oldest-exception and oldest-mispredict registers hold the cause/tval and the redirect
//   target of the oldest entry that reported one.
// Commit retires up to COMMIT_WIDTH complete entries in order. Exceptions, serialising
// instructions and replays are handled at the head alone; a mispredicted branch retires and
// ends the group. Every recovery is a flush plus redirect, registered (flush, flush_pc).
module tg_rob
  import tg_pkg::*, tg_trace_pkg::*, tg_core_pkg::*;
#(
  parameter int unsigned CORE_ID = 0,
  localparam int NB   = ROB_BANKS,
  localparam int ROWS = ROB_ENTRIES / ROB_BANKS,
  localparam int RIW  = ROBW - 1,
  localparam int CW   = COMMIT_WIDTH,
  localparam int NCW  = idx_w(CW + 1)
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         ready,
  // Dispatch
  input  logic                         ds_fire,
  input  logic [DISPATCH_WIDTH-1:0]    ds_valid,
  input  uop_t [DISPATCH_WIDTH-1:0]    ds_uop,
  input  ren_t [DISPATCH_WIDTH-1:0]    ds_ren,
  output robid_t                       head_o,
  // Completion
  input  logic [N_ALU-1:0]             alu_cmp,
  input  robid_t [N_ALU-1:0]           alu_rob,
  input  logic                         oth_cmp,
  input  robid_t                       oth_rob,
  input  logic                         oth_exc,
  input  logic [4:0]                   oth_fflags,   // FP->int results (EXT_FD)
  input  logic [63:0]                  oth_tval,
  input  logic                         br_valid,
  input  robid_t                       br_rob,
  input  logic                         br_misp,
  input  logic [63:0]                  br_npc,
  input  logic                         br_exc,
  input  logic [63:0]                  br_tval,
  input  logic                         fp_cmp,       // P4's F0 results (EXT_FD)
  input  robid_t                       fp_cmp_rob,
  input  logic [4:0]                   fp_cmp_fflags,
  input  logic                         ld_cmp,
  input  robid_t                       ld_rob,
  input  logic                         ld_mmio,
  input  logic [1:0]                   st_cmp,
  input  robid_t [1:0]                 st_rob,
  input  logic [3:0]                   lx_valid,
  input  robid_t [3:0]                 lx_rob,
  input  logic [3:0][3:0]              lx_cause,
  input  logic                         replay_valid,
  input  robid_t                       replay_rob,
  input  logic [1:0]                   tlbm_valid,   // DTLB misses (LD and STA ports): replay
  input  robid_t [1:0]                 tlbm_rob,
  input  logic                         hd_tlb,       // the head is a load or store that missed the DTLB
  input  logic                         hd_retry,
  input  logic                         hd_fault,
  input  logic [3:0]                   hd_cause,
  input  logic [63:0]                  hd_lva,       // the head load's VA, or the head store's:
  input  logic [63:0]                  hd_sva,       // tval of an LSU exception (taken at the head)
  // LSU state
  input  logic                         sq_drained,
  input  logic                         mmio_busy,
  // To rename
  output logic [CW-1:0]                cm_valid,
  output logic [CW-1:0]                cm_rd_en,
  output logic [CW-1:0]                cm_rd_fp,     // rd is an f register (EXT_FD)
  output logic [CW-1:0][4:0]           cm_fflags,    // the retiring FP op's exception flags
  output logic [CW-1:0][4:0]           cm_rd,
  output preg_t [CW-1:0]               cm_dst,
  output preg_t [CW-1:0]               cm_old,
  // To the LSU
  output logic [NCW-1:0]               cm_nld,
  output logic [NCW-1:0]               cm_nst,
  output sqid_t [CW-1:0]               tr_sq,
  input  logic [CW-1:0]                tr_st_wr,
  input  logic [CW-1:0][63:0]          tr_st_va,
  input  logic [CW-1:0][63:0]          tr_st_data,
  input  logic [CW-1:0][1:0]           tr_st_size,
  // Trace register reads
  output preg_t [CW-1:0]               tr_tag,
  input  logic [CW-1:0][63:0]          tr_data,
  // CSR file
  output logic                         cm_csr,
  output logic [NCW-1:0]               cm_n,
  output logic                         tr_valid,
  output logic                         tr_irq,
  output logic [5:0]                   tr_code,
  output logic [63:0]                  tr_epc,
  output logic [63:0]                  tr_tval,
  output logic                         mret,
  output logic                         sret,
  output logic                         sfence,       // SFENCE.VMA retires: flush the TLBs
  input  logic [63:0]                  trap_target,
  output logic                         xret_v,       // an MRET or SRET is in flight (registered) ...
  output logic                         xret_s,       // ... and it is SRET: tg_csr reads its xepc
  input  logic [63:0]                  xepc,
  input  priv_e                        priv,
  input  logic                         irq_take,
  input  logic [5:0]                   irq_code,
  input  logic                         wfi_wake,
  // Flush and redirect (registered)
  output logic                         flush,
  output tid_t                         flush_tid,
  output logic [63:0]                  flush_pc,
  output logic                         icinv,
  // Commit trace
  output tr_rec_t [CW-1:0]             trace_o,
  output logic [CW-1:0]                trace_valid_o
);
  if (NB < DISPATCH_WIDTH || NB < CW || (ROB_ENTRIES % NB) != 0) begin : g_bad
    $error("tg_rob: ROB_BANKS must cover the widths and divide ROB_ENTRIES");
  end

  robid_t head_q, tail_q;
  assign head_o = head_q;
  logic                   xr_v_q, xr_s_q;  // an MRET or SRET in flight; SRET

  logic          exr_v_q;
  robid_t        exr_rob_q;
  logic [3:0]    exr_cause_q;
  logic [63:0]   exr_tval_q;
  logic          exr_mem_q;      // an LSU exception: tval is the head's VA (hd_lva / hd_sva)
  logic          mpr_v_q;
  robid_t        mpr_rob_q;
  logic [63:0]   mpr_npc_q;

  // ---- Payload LUTRAM ----
  function automatic int bank_of(input logic [RIW-1:0] i);
    return int'(i) % NB;
  endfunction
  function automatic int row_of(input logic [RIW-1:0] i);
    return int'(i) / NB;
  endfunction
  rob_pl_t [DISPATCH_WIDTH-1:0] dpl;
  logic [DISPATCH_WIDTH-1:0]    fp_cmp_d, fp_exc_d, fp_misp_d, fp_mmio_d;   // flag parities at dispatch
  for (genvar k = 0; k < DISPATCH_WIDTH; k++) begin : g_dpl
    always_comb begin
      dpl[k]            = '0;
      dpl[k].pc         = ds_uop[k].pc;
      dpl[k].insn       = ds_uop[k].insn;
      dpl[k].rvc        = ds_uop[k].rvc;
      dpl[k].tid        = ds_uop[k].tid;
      dpl[k].rd_en      = ds_uop[k].d.rd_en;
      dpl[k].rd         = ds_uop[k].d.rd;
      dpl[k].rd_fp      = EXT_FD && ds_uop[k].d.rd_fp;
      dpl[k].is_fp      = EXT_FD && ds_uop[k].d.cls == C_FP;
      dpl[k].dst        = ds_ren[k].dst;
      dpl[k].old        = ds_ren[k].old;
      dpl[k].is_ld      = ds_uop[k].d.cls == C_LD;
      dpl[k].is_st      = ds_uop[k].d.cls == C_ST;
      dpl[k].is_br      = ds_uop[k].d.cls == C_BR;
      dpl[k].is_csr     = ds_uop[k].d.cls == C_CSR;
      dpl[k].sys        = ds_uop[k].d.sys;
      dpl[k].serial     = ds_uop[k].d.serial;
      dpl[k].dexc       = ds_uop[k].d.exc;
      dpl[k].dexc_cause = ds_uop[k].d.exc_cause;
      dpl[k].dexc_hi    = ds_uop[k].d.exc_hi;
      dpl[k].lq         = ds_ren[k].lq;
      dpl[k].sq         = ds_ren[k].sq;
      dpl[k].f_cmp      = fp_cmp_d[k] ^ !ds_ren[k].has_q;   // complete at once without a queue
      dpl[k].f_exc      = fp_exc_d[k] ^ ds_uop[k].d.exc;
      dpl[k].f_misp     = fp_misp_d[k];
      dpl[k].f_mmio     = fp_mmio_d[k];
    end
  end
  logic [NB-1:0]                      pw_we;
  logic [NB-1:0][idx_w(ROWS)-1:0]     pw_a;
  logic [NB-1:0][ROB_PL_W-1:0]        pw_d;
  always_comb begin
    pw_we = '0; pw_a = '0; pw_d = '0;
    for (int k = 0; k < DISPATCH_WIDTH; k++) begin
      if (ds_fire && ds_valid[k]) begin
        pw_we[bank_of(ds_ren[k].rob[RIW-1:0])] = 1'b1;
        pw_a[bank_of(ds_ren[k].rob[RIW-1:0])]  = idx_w(ROWS)'(row_of(ds_ren[k].rob[RIW-1:0]));
        pw_d[bank_of(ds_ren[k].rob[RIW-1:0])]  = dpl[k];
      end
    end
  end
  robid_t [CW-1:0]  hid;              // head + j
  rob_pl_t [CW-1:0] hp;
  logic [NB-1:0][idx_w(ROWS)-1:0] pr_a;
  logic [NB-1:0][ROB_PL_W-1:0]    pr_d;
  for (genvar j = 0; j < CW; j++) begin : g_hid
    assign hid[j] = rob_add(head_q, j);
    assign hp[j]  = rob_pl_t'(pr_d[bank_of(hid[j][RIW-1:0])]);
  end
  always_comb begin
    pr_a = '0;
    for (int j = 0; j < CW; j++) pr_a[bank_of(hid[j][RIW-1:0])] = idx_w(ROWS)'(row_of(hid[j][RIW-1:0]));
  end
  for (genvar b = 0; b < NB; b++) begin : g_pl
    logic [0:0][idx_w(ROWS)-1:0] ra;
    logic [0:0][ROB_PL_W-1:0]    rd;
    assign ra[0] = pr_a[b];
    tg_ram_lut #(.DEPTH(ROWS), .WIDTH(ROB_PL_W), .NR(1)) u_pl (
      .clk, .we(pw_we[b]), .waddr(pw_a[b]), .wdata(pw_d[b]), .raddr(ra), .rdata(rd));
    assign pr_d[b] = rd[0];
  end

  // ---- FP exception flags (EXT_FD), by ROB entry, in LUTRAM ----
  // P4's F0 completions write one table and FP->int completions (bank 1) the other, so each
  // table has one write port; at commit an FP op's result file (rd_fp) says which it wrote.
  // Entries are read only once complete, and every completion writes its flags.
  logic [CW-1:0][RIW-1:0] ffr_a;
  logic [CW-1:0][4:0]     ffp_rd, ffi_rd;
  for (genvar j = 0; j < CW; j++) begin : g_ffa
    assign ffr_a[j] = hid[j][RIW-1:0];
  end
  if (EXT_FD) begin : g_ff
    tg_ram_lut #(.DEPTH(ROB_ENTRIES), .WIDTH(5), .NR(CW)) u_ffp (
      .clk, .we(fp_cmp), .waddr(fp_cmp_rob[RIW-1:0]), .wdata(fp_cmp_fflags), .raddr(ffr_a),
      .rdata(ffp_rd));
    tg_ram_lut #(.DEPTH(ROB_ENTRIES), .WIDTH(5), .NR(CW)) u_ffi (
      .clk, .we(oth_cmp), .waddr(oth_rob[RIW-1:0]), .wdata(oth_fflags), .raddr(ffr_a),
      .rdata(ffi_rd));
  end else begin : g_noff
    assign ffp_rd = '0;
    assign ffi_rd = '0;
  end

  // ---- Complete, exception, mispredict and MMIO flags (FPGA-friendly T2) ----
  // Each reporting port toggles its own one-bit LUTRAM table at the entry it reports, so every
  // table has one writer. A flag is the parity of its ports' tables XOR the bit the payload took
  // at dispatch (that parity then, XOR the flag's initial value), so dispatch writes none of the
  // tables, and their contents need no reset. This holds while every live entry gets at most
  // one report per flag per lap and none as it is dispatched (asserted); reports in a flush
  // cycle are dropped, as the flip-flop flags dropped them, and later ones for squashed entries
  // come before those entries are dispatched again.
  // Read ports per table: the commit slots' entries, the dispatched entries, and its own write
  // entry (the toggle).
  localparam int NCP = N_ALU + 9;                // completion ports
  localparam int NXP = 6;                        // exception ports
  localparam int NFT = NCP + NXP + 2;            // tables: completions, exceptions, mispredict, MMIO
  localparam int NFR = CW + DISPATCH_WIDTH + 1;
  logic [NFT-1:0]          ft_v;
  robid_t [NFT-1:0]        ft_e;
  always_comb begin
    // completions: tables 0 .. NCP-1
    for (int i = 0; i < N_ALU; i++) begin
      ft_v[i] = alu_cmp[i];
      ft_e[i] = alu_rob[i];
    end
    ft_v[N_ALU]     = oth_cmp;            ft_e[N_ALU]     = oth_rob;
    ft_v[N_ALU + 1] = EXT_FD && fp_cmp;   ft_e[N_ALU + 1] = fp_cmp_rob;
    ft_v[N_ALU + 2] = ld_cmp;             ft_e[N_ALU + 2] = ld_rob;
    for (int i = 0; i < 2; i++) begin
      ft_v[N_ALU + 3 + i] = st_cmp[i];
      ft_e[N_ALU + 3 + i] = st_rob[i];
    end
    for (int i = 0; i < 4; i++) begin
      ft_v[N_ALU + 5 + i] = lx_valid[i];
      ft_e[N_ALU + 5 + i] = lx_rob[i];
      // exceptions: tables NCP .. NCP+NXP-1
      ft_v[NCP + 2 + i]   = lx_valid[i];
      ft_e[NCP + 2 + i]   = lx_rob[i];
    end
    ft_v[NCP]     = oth_cmp && oth_exc;    ft_e[NCP]     = oth_rob;
    ft_v[NCP + 1] = br_valid && br_exc;    ft_e[NCP + 1] = br_rob;
    // mispredict and MMIO load
    ft_v[NFT - 2] = br_valid && !br_exc && br_misp;  ft_e[NFT - 2] = br_rob;
    ft_v[NFT - 1] = ld_cmp && ld_mmio;               ft_e[NFT - 1] = ld_rob;
  end
  logic [NFT-1:0][NFR-1:0] ft_rd;
  for (genvar t = 0; t < NFT; t++) begin : g_ft
    logic [NFR-1:0][RIW-1:0] ra;
    for (genvar j = 0; j < CW; j++) begin : g_rh
      assign ra[j] = hid[j][RIW-1:0];
    end
    for (genvar k = 0; k < DISPATCH_WIDTH; k++) begin : g_rd
      assign ra[CW + k] = ds_ren[k].rob[RIW-1:0];
    end
    assign ra[NFR-1] = ft_e[t][RIW-1:0];
    tg_ram_lut #(.DEPTH(ROB_ENTRIES), .WIDTH(1), .NR(NFR)) u_ft (
      .clk, .we(ft_v[t] && !flush && !rst), .waddr(ft_e[t][RIW-1:0]), .wdata(!ft_rd[t][NFR-1]),
      .raddr(ra), .rdata(ft_rd[t]));
  end
  // The completion and exception parities at each read port
  logic [NFR-1:0] par_c, par_x;
  always_comb begin
    for (int p = 0; p < NFR; p++) begin
      par_c[p] = 1'b0;
      par_x[p] = 1'b0;
      for (int t = 0; t < NCP; t++)         par_c[p] ^= ft_rd[t][p];
      for (int t = NCP; t < NCP + NXP; t++) par_x[p] ^= ft_rd[t][p];
    end
  end
  logic [CW-1:0] cmp_h, exc_h, misp_h, mmio_h;   // the flags of the commit slots' entries
  for (genvar j = 0; j < CW; j++) begin : g_fh
    assign cmp_h[j]  = par_c[j] ^ hp[j].f_cmp;
    assign exc_h[j]  = par_x[j] ^ hp[j].f_exc;
    assign misp_h[j] = ft_rd[NFT-2][j] ^ hp[j].f_misp;
    assign mmio_h[j] = ft_rd[NFT-1][j] ^ hp[j].f_mmio;
  end
  for (genvar k = 0; k < DISPATCH_WIDTH; k++) begin : g_fd
    assign fp_cmp_d[k]  = par_c[CW + k];
    assign fp_exc_d[k]  = par_x[CW + k];
    assign fp_misp_d[k] = ft_rd[NFT-2][CW + k];
    assign fp_mmio_d[k] = ft_rd[NFT-1][CW + k];
  end

  // ---- Replay flag: XOR-banked LUTRAM (FPGA-friendly T2) ----
  // Cleared at dispatch; set by the LSU's replay report and its two TLB-miss reports, possibly
  // more than once a lap (so not a toggle table). One table per writer, and the flag is the XOR
  // of the tables: a writer stores its value XOR the other tables at its entry, read in the same
  // cycle. Two writers at one entry in a cycle would cancel; none do (asserted): a setter's entry
  // is live, so never one being dispatched; a TLB miss is a new access at AG, never a load the
  // ordering search finds (it has a value); the LD and STA ports carry different instructions.
  localparam int NRW = DISPATCH_WIDTH + 3;       // dispatch slots, then replay, TLB miss LD, STA
  localparam int NRR = NRW - 1 + CW;             // read ports: the other writers', then the head's
  logic [NRW-1:0]           rw_v;
  logic [NRW-1:0][RIW-1:0]  rw_a;
  logic [NRW-1:0]           rw_d;
  logic [NRW-1:0][NRR-1:0]  rw_rd;
  always_comb begin
    rw_v[DISPATCH_WIDTH +: 3] = {tlbm_valid[1], tlbm_valid[0], replay_valid};
    rw_a[DISPATCH_WIDTH +: 3] = {tlbm_rob[1][RIW-1:0], tlbm_rob[0][RIW-1:0], replay_rob[RIW-1:0]};
    rw_d[DISPATCH_WIDTH +: 3] = '1;
    for (int k = 0; k < DISPATCH_WIDTH; k++) begin
      rw_v[k] = ds_fire && ds_valid[k];
      rw_a[k] = ds_ren[k].rob[RIW-1:0];
      rw_d[k] = 1'b0;
    end
  end
  for (genvar b = 0; b < NRW; b++) begin : g_rw
    logic [NRR-1:0][RIW-1:0] ra;
    for (genvar p = 0; p < NRW - 1; p++) begin : g_ro
      assign ra[p] = rw_a[(p < b) ? p : p + 1];
    end
    for (genvar j = 0; j < CW; j++) begin : g_rh
      assign ra[NRW - 1 + j] = hid[j][RIW-1:0];
    end
    logic wd;
    always_comb begin
      wd = rw_d[b];
      for (int w = 0; w < NRW; w++) if (w != b) wd ^= rw_rd[w][(b < w) ? b : b - 1];
    end
    tg_ram_lut #(.DEPTH(ROB_ENTRIES), .WIDTH(1), .NR(NRR)) u_rw (
      .clk, .we(rw_v[b] && !flush && !rst), .waddr(rw_a[b]), .wdata(wd), .raddr(ra), .rdata(rw_rd[b]));
  end
  logic [CW-1:0] rpl_h;                          // the flag of each commit slot's entry
  always_comb begin
    for (int j = 0; j < CW; j++) begin
      rpl_h[j] = 1'b0;
      for (int b = 0; b < NRW; b++) rpl_h[j] ^= rw_rd[b][NRW - 1 + j];
    end
  end

  // ---- Commit decision ----
  int cnt;
  assign cnt = rob_cnt(tail_q, head_q);
  logic [CW-1:0] ret;               // retiring slots
  logic          do_flush, do_trap, do_irq, do_icinv, do_csr, do_mret, do_sret, do_sfence, use_tt, tlbx;
  logic [63:0]   nf_pc;
  logic [3:0]    t_cause;
  logic [63:0]   t_tval;
  logic          stop;
  // WFI retires when a locally enabled interrupt is pending, or after WFI_MAX cycles (the ISA
  // lets WFI complete at any time; Spike treats it as a no-op), so it never hangs the hart.
  localparam int WFI_MAX = 4096;
  logic [idx_w(WFI_MAX + 1)-1:0] wfi_cnt_q;
  logic go;
  always_comb begin
    unique case (hp[0].sys)
      SYS_FENCE, SYS_FENCEI, SYS_SFENCE: go = sq_drained;    // later walks see the stores
      SYS_WFI:               go = wfi_wake || int'(wfi_cnt_q) == WFI_MAX;
      default:               go = !(hp[0].is_csr && hp[0].insn[31:20] == 12'h180) || sq_drained;  // satp
    endcase
  end
  always_ff @(posedge clk) begin
    if (rst || flush || cnt == 0 || hp[0].sys != SYS_WFI) wfi_cnt_q <= '0;
    else if (int'(wfi_cnt_q) != WFI_MAX) wfi_cnt_q <= wfi_cnt_q + 1'b1;
  end
  // One adder on the head's PC: a serial instruction's next PC (+2 or +4), or a fetch fault's
  // tval (+2 when only the second half of a 32-bit instruction faults). The second is a decode
  // exception, which traps, so one instruction never needs both.
  logic [63:0] hd_pc_inc;
  assign hd_pc_inc = hp[0].pc + (hp[0].dexc ? {62'b0, hp[0].dexc_hi, 1'b0} : (hp[0].rvc ? 64'd2 : 64'd4));
  always_comb begin
    ret = '0;
    do_flush = 1'b0; do_trap = 1'b0; do_irq = 1'b0; do_icinv = 1'b0; do_csr = 1'b0; do_mret = 1'b0;
    do_sret = 1'b0; do_sfence = 1'b0;
    use_tt = 1'b0;
    tlbx = 1'b0;
    nf_pc = '0;
    t_cause = '0;
    t_tval = '0;
    stop = 1'b0;
    if (!flush && ready && cnt > 0) begin
      if (irq_take && hp[0].sys != SYS_WFI && !mmio_busy) begin
        do_irq = 1'b1;
        do_flush = 1'b1;
        use_tt = 1'b1;
      end else if (rpl_h[0]) begin
        if (!hd_tlb || hd_retry) begin
          do_flush = 1'b1;
          nf_pc = hp[0].pc;
        end else if (hd_fault) begin
          do_trap  = 1'b1;
          do_flush = 1'b1;
          use_tt   = 1'b1;
          tlbx     = 1'b1;
          t_cause  = hd_cause;
          t_tval   = hp[0].is_ld ? hd_lva : hd_sva;
        end
      end else if (cmp_h[0] && exc_h[0]) begin
        do_trap = 1'b1;
        do_flush = 1'b1;
        use_tt = 1'b1;
        if (hp[0].dexc) begin
          t_cause = hp[0].dexc_cause;
          unique case (hp[0].dexc_cause)
            EXC_ILLEGAL: t_tval = {32'b0, hp[0].insn};
            EXC_BREAK: t_tval = hp[0].pc;
            EXC_IACCESS, EXC_IPAGE: t_tval = hd_pc_inc;
            default: t_tval = '0;
          endcase
        end else begin
          t_cause = exr_cause_q;
          t_tval  = exr_mem_q ? (hp[0].is_ld ? hd_lva : hd_sva) : exr_tval_q;
        end
      end else if (cmp_h[0] && hp[0].serial) begin
        if (go) begin
          ret[0]   = 1'b1;
          do_flush = 1'b1;
          do_icinv = hp[0].sys == SYS_FENCEI;
          do_csr   = hp[0].is_csr;
          do_mret  = hp[0].sys == SYS_MRET;
          do_sret  = hp[0].sys == SYS_SRET;
          do_sfence = hp[0].sys == SYS_SFENCE;
          nf_pc    = (do_mret || do_sret) ? xepc : hd_pc_inc;
        end
      end else begin
        stop = 1'b0;
        for (int j = 0; j < CW; j++) begin
          if (!stop) begin
            if (j < cnt && cmp_h[j] && !exc_h[j] && !hp[j].serial && !rpl_h[j]) begin
              ret[j] = 1'b1;
              if (misp_h[j]) begin
                do_flush = 1'b1;
                nf_pc = mpr_npc_q;
                stop = 1'b1;
              end
            end else begin
              stop = 1'b1;
            end
          end
        end
      end
    end
  end

  // ---- Outputs to rename, LSU, CSR ----
  always_comb begin
    int nl, ns, n;
    nl = 0; ns = 0; n = 0;
    for (int j = 0; j < CW; j++) begin
      cm_valid[j] = ret[j];
      cm_rd_en[j] = ret[j] && hp[j].rd_en;
      cm_rd_fp[j] = hp[j].rd_fp;
      cm_fflags[j] = (EXT_FD && hp[j].is_fp) ? (hp[j].rd_fp ? ffp_rd[j] : ffi_rd[j]) : '0;
      cm_rd[j]    = hp[j].rd;
      cm_dst[j]   = hp[j].dst;
      cm_old[j]   = hp[j].old;
      tr_sq[j]    = hp[j].sq;
      tr_tag[j]   = hp[j].dst;
      if (ret[j]) begin
        n++;
        if (hp[j].is_ld) nl++;
        if (hp[j].is_st) ns++;
      end
    end
    cm_nld = NCW'(nl);
    cm_nst = NCW'(ns);
    cm_n   = NCW'(n);
  end
  assign cm_csr   = do_csr;
  assign mret     = do_mret;
  assign sret     = do_sret;
  assign sfence   = do_sfence;
  assign tr_valid = do_trap || do_irq;
  assign tr_irq   = do_irq;
  assign tr_code  = do_irq ? irq_code : {2'b0, t_cause};
  assign tr_epc   = hp[0].pc;
  assign tr_tval  = t_tval;

  // ---- Trace records ----
  localparam hart_t HART0 = hart_t'(CORE_ID * NUM_THREADS);
  tr_rec_t [CW-1:0] rec;
  always_comb begin
    for (int j = 0; j < CW; j++) begin
      rec[j] = '0;
      rec[j].hart = HART0;
      rec[j].priv = priv;
      rec[j].pc   = hp[j].pc;
      rec[j].insn = hp[j].insn;
      rec[j].rvc  = hp[j].rvc;
      if (j == 0 && do_irq) begin
        rec[j].kind  = TR_IRQ;
        rec[j].insn  = '0;
        rec[j].rvc   = 1'b0;
        rec[j].cause = {1'b1, 57'b0, irq_code};
      end else if (j == 0 && do_trap) begin
        rec[j].kind  = TR_TRAP;
        rec[j].cause = {60'b0, t_cause};
        rec[j].tval  = t_tval;
      end else begin
        rec[j].kind     = TR_RETIRE;
        rec[j].rd_we    = hp[j].rd_en;
        rec[j].rd_fp    = hp[j].rd_fp;
        rec[j].rd       = hp[j].rd;
        rec[j].rd_value = hp[j].rd_en ? tr_data[j] : '0;
        rec[j].mem_st   = hp[j].is_st && tr_st_wr[j];     // not LR or a failed SC
        if (rec[j].mem_st) begin
          rec[j].mem_vaddr = tr_st_va[j];
          rec[j].mem_size  = tr_st_size[j];
          unique case (tr_st_size[j])
            2'd0: rec[j].mem_wdata = {56'b0, tr_st_data[j][7:0]};
            2'd1: rec[j].mem_wdata = {48'b0, tr_st_data[j][15:0]};
            2'd2: rec[j].mem_wdata = {32'b0, tr_st_data[j][31:0]};
            default: rec[j].mem_wdata = tr_st_data[j];
          endcase
        end
        rec[j].mmio_ld = hp[j].is_ld && mmio_h[j];
        rec[j].nondet  = hp[j].is_csr && hp[j].rd_en && csr_nondet(hp[j].insn[31:20]);
      end
    end
  end

  // Oldest exception after this cycle's reports. Candidates, in priority order: the register,
  // CSR (oth), branch, then the LSU's four ports. The oldest valid one wins, the first in that
  // order on a tie. Computed in parallel rather than as a chain: every pair's age compare uses
  // only ROB indices, which arrive early (the LSU's AG ports send their payload's index whether
  // or not they fault), and the late valid bits only gate a one-hot select. tval: an LSU winner
  // takes the head's VA at the trap (ex_m), so ex_t is the best of the first three alone, as
  // the chain left it.
  localparam int NEX = 7;
  logic        ex_v;
  robid_t      ex_r;
  logic [3:0]  ex_c;
  logic [63:0] ex_t;
  logic        ex_m;
  logic [NEX-1:0]             xc_v, xc_win;
  robid_t [NEX-1:0]           xc_r;
  logic [NEX-1:0][3:0]        xc_c;
  logic [NEX-1:0][NEX-1:0]    xc_o;     // xc_o[i][j]: candidate i is strictly older than j
  always_comb begin
    xc_v = {lx_valid, br_valid && br_exc, oth_cmp && oth_exc, exr_v_q};
    xc_r = {lx_rob, br_rob, oth_rob, exr_rob_q};
    xc_c = {lx_cause, 4'(EXC_IMISALIGN), 4'(EXC_ILLEGAL), exr_cause_q};
    for (int i = 0; i < NEX; i++)
      for (int j = 0; j < NEX; j++) xc_o[i][j] = rob_older(xc_r[i], xc_r[j]);
    for (int i = 0; i < NEX; i++) begin
      xc_win[i] = xc_v[i];
      for (int j = 0; j < NEX; j++) begin
        if (j < i && xc_v[j] && !xc_o[i][j]) xc_win[i] = 1'b0;    // an earlier one as old
        if (j > i && xc_v[j] && xc_o[j][i])  xc_win[i] = 1'b0;    // a later one older
      end
    end
    ex_v = |xc_v;
    ex_r = '0;
    ex_c = '0;
    for (int i = 0; i < NEX; i++) begin
      ex_r |= {$bits(robid_t){xc_win[i]}} & xc_r[i];
      ex_c |= {4{xc_win[i]}} & xc_c[i];
    end
    ex_m = |xc_win[NEX-1:3] || (xc_win[0] && exr_mem_q);
    // tval of the best of the register, CSR and branch candidates
    ex_t = exr_tval_q;
    if (xc_v[1] && (!xc_v[0] || xc_o[1][0])) ex_t = oth_tval;
    if (xc_v[2] && (!xc_v[0] || xc_o[2][0]) && (!xc_v[1] || xc_o[2][1])) ex_t = br_tval;
  end

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    // Trace leaves one cycle after commit
    trace_o <= rec;
    if (rst) begin
      trace_valid_o <= '0;
      head_q   <= '0;
      tail_q   <= '0;
      flush    <= 1'b0;
      icinv    <= 1'b0;
      exr_v_q  <= 1'b0;
      mpr_v_q  <= 1'b0;
      xr_v_q   <= 1'b0;
    end else begin
      for (int j = 0; j < CW; j++) trace_valid_o[j] <= ret[j] || (j == 0 && (do_trap || do_irq));
      flush     <= do_flush;
      flush_pc  <= use_tt ? trap_target : nf_pc;
      icinv     <= do_icinv;
      head_q    <= rob_add(head_q, int'(cm_n));

      if (flush) begin
        tail_q  <= head_q;
        exr_v_q <= 1'b0;
        mpr_v_q <= 1'b0;
        xr_v_q  <= 1'b0;
      end else begin
        // Dispatch
        if (ds_fire) begin
          // MRET and SRET are serial: dispatched alone, with nothing after them until their
          // flush, so this holds until they commit
          xr_v_q <= 1'b0;
          xr_s_q <= 1'b0;
          for (int k = 0; k < DISPATCH_WIDTH; k++) begin
            if (ds_valid[k] && (ds_uop[k].d.sys == SYS_MRET || ds_uop[k].d.sys == SYS_SRET)) xr_v_q <= 1'b1;
            if (ds_valid[k] && ds_uop[k].d.sys == SYS_SRET) xr_s_q <= 1'b1;
          end
          tail_q <= rob_add(tail_q, $countones(ds_valid));
        end
        // Completions, exceptions, mispredicts and MMIO loads: the toggle tables; replay: the
        // XOR-banked tables (above)

        // Oldest exception: the current register and this cycle's reports
        exr_v_q <= ex_v && !do_trap; exr_rob_q <= ex_r; exr_cause_q <= ex_c; exr_tval_q <= ex_t;
        exr_mem_q <= ex_m;
        // Oldest mispredict
        if (br_valid && br_misp && !br_exc && (!mpr_v_q || rob_older(br_rob, mpr_rob_q))) begin
          mpr_v_q   <= 1'b1;
          mpr_rob_q <= br_rob;
          mpr_npc_q <= br_npc;
        end
      end
    end
  end
  assign flush_tid = '0;
  assign xret_v    = xr_v_q;
  assign xret_s    = xr_s_q;
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && (do_mret || do_sret))
      assert (xr_v_q && xr_s_q == do_sret) else $error("tg_rob: an xRET commits that xret_v/xret_s do not name");
    if (!rst && ret[0] && hp[0].serial)
      assert (!hp[0].dexc) else $error("tg_rob: a serial instruction with a decode exception retires");
  end
`endif

  logic unused;
  assign unused = ^{hp[0].tid, hp[0].is_br, hp[0].lq, hp[CW-1].tid, hp[CW-1].is_br, hp[CW-1].lq,
                    ld_rob[ROBW-1], replay_rob[ROBW-1], alu_rob, st_rob, oth_rob[ROBW-1], tlbm_rob,
                    br_rob[ROBW-1], lx_rob, fp_cmp_rob[ROBW-1]};

`ifndef SYNTHESIS
  // Shadow flags as flip-flops (the form the toggle tables replace): the head's flags must
  // match them, and the tables' condition must hold (no second report for a live entry, none
  // for an entry as it is dispatched).
  logic [ROB_ENTRIES-1:0] cmp_s, exc_s, misp_s, mmio_s, rpl_s;
  function automatic logic live(input robid_t e);
    return rob_cnt(e, head_q) < rob_cnt(tail_q, head_q);
  endfunction
  always_ff @(posedge clk) begin
    if (!rst && !flush) begin
      if (ds_fire) begin
        for (int k = 0; k < DISPATCH_WIDTH; k++) begin
          if (ds_valid[k]) begin
            cmp_s[ds_ren[k].rob[RIW-1:0]]  <= !ds_ren[k].has_q;
            exc_s[ds_ren[k].rob[RIW-1:0]]  <= ds_uop[k].d.exc;
            misp_s[ds_ren[k].rob[RIW-1:0]] <= 1'b0;
            mmio_s[ds_ren[k].rob[RIW-1:0]] <= 1'b0;
            rpl_s[ds_ren[k].rob[RIW-1:0]]  <= 1'b0;
          end
        end
      end
      if (replay_valid) rpl_s[replay_rob[RIW-1:0]] <= 1'b1;
      for (int i = 0; i < 2; i++) if (tlbm_valid[i]) rpl_s[tlbm_rob[i][RIW-1:0]] <= 1'b1;
      for (int a = 0; a < NRW; a++)
        for (int b = a + 1; b < NRW; b++)
          assert (!(rw_v[a] && rw_v[b] && rw_a[a] == rw_a[b]))
            else $error("tg_rob: two replay-table writers at entry %0d", rw_a[a]);
      for (int t = 0; t < NFT; t++) begin
        if (ft_v[t]) begin
          if (t < NCP)            cmp_s[ft_e[t][RIW-1:0]]  <= 1'b1;
          else if (t < NCP + NXP) exc_s[ft_e[t][RIW-1:0]]  <= 1'b1;
          else if (t == NFT - 2)  misp_s[ft_e[t][RIW-1:0]] <= 1'b1;
          else                    mmio_s[ft_e[t][RIW-1:0]] <= 1'b1;
          if (live(ft_e[t])) begin
            if (t < NCP)
              assert (!cmp_s[ft_e[t][RIW-1:0]]) else $error("tg_rob: a second completion of %0d", ft_e[t]);
            else if (t < NCP + NXP)
              assert (!exc_s[ft_e[t][RIW-1:0]]) else $error("tg_rob: a second exception of %0d", ft_e[t]);
            else if (t == NFT - 2)
              assert (!misp_s[ft_e[t][RIW-1:0]]) else $error("tg_rob: a second mispredict of %0d", ft_e[t]);
            else
              assert (!mmio_s[ft_e[t][RIW-1:0]]) else $error("tg_rob: a second MMIO mark of %0d", ft_e[t]);
          end
          for (int u = t + 1; u < NFT; u++) begin
            if ((t < NCP) == (u < NCP) && (t < NCP + NXP) == (u < NCP + NXP) && (t < NFT - 2) == (u < NFT - 2) &&
                (t < NFT - 1) == (u < NFT - 1) && live(ft_e[t]))
              assert (!(ft_v[u] && ft_e[u] == ft_e[t])) else $error("tg_rob: two reports of one flag for %0d", ft_e[t]);
          end
          if (ds_fire)
            for (int k = 0; k < DISPATCH_WIDTH; k++)
              assert (!(ds_valid[k] && ds_ren[k].rob[RIW-1:0] == ft_e[t][RIW-1:0]))
                else $error("tg_rob: a report for entry %0d as it is dispatched", ft_e[t]);
        end
      end
      for (int j = 0; j < CW; j++) begin
        if (j < cnt) begin
          assert (cmp_h[j] == cmp_s[hid[j][RIW-1:0]] && exc_h[j] == exc_s[hid[j][RIW-1:0]] &&
                  misp_h[j] == misp_s[hid[j][RIW-1:0]] && mmio_h[j] == mmio_s[hid[j][RIW-1:0]])
            else $error("tg_rob: the toggle-table flags of %0d differ from the shadow flags", hid[j]);
          assert (rpl_h[j] == rpl_s[hid[j][RIW-1:0]])
            else $error("tg_rob: the replay tables' flag of %0d differs from the shadow flag", hid[j]);
        end
      end
    end
  end
  // The oldest-exception chain the parallel select replaces: same winner, cause, tval and kind
  logic        sx_v, sx_m;
  robid_t      sx_r;
  logic [3:0]  sx_c;
  logic [63:0] sx_t;
  always_comb begin
    sx_v = exr_v_q; sx_r = exr_rob_q; sx_c = exr_cause_q; sx_t = exr_tval_q; sx_m = exr_mem_q;
    if (oth_cmp && oth_exc && (!sx_v || rob_older(oth_rob, sx_r))) begin
      sx_v = 1'b1; sx_r = oth_rob; sx_c = EXC_ILLEGAL; sx_t = oth_tval; sx_m = 1'b0;
    end
    if (br_valid && br_exc && (!sx_v || rob_older(br_rob, sx_r))) begin
      sx_v = 1'b1; sx_r = br_rob; sx_c = EXC_IMISALIGN; sx_t = br_tval; sx_m = 1'b0;
    end
    for (int i = 0; i < 4; i++) begin
      if (lx_valid[i] && (!sx_v || rob_older(lx_rob[i], sx_r))) begin
        sx_v = 1'b1; sx_r = lx_rob[i]; sx_c = lx_cause[i]; sx_m = 1'b1;
      end
    end
  end
  always_ff @(posedge clk) begin
    if (!rst && !flush) begin
      assert (ex_v == sx_v && (!sx_v || (ex_r == sx_r && ex_c == sx_c && ex_m == sx_m && (sx_m || ex_t == sx_t))))
        else $error("tg_rob: the parallel oldest-exception select differs from the chain");
      assert ($onehot0(xc_win)) else $error("tg_rob: more than one oldest exception");
    end
  end
  always_ff @(posedge clk) begin
    if (!rst && !flush) begin
      assert (cnt >= 0 && cnt <= ROB_ENTRIES) else $error("tg_rob: bad occupancy %0d", cnt);
      if (do_trap && !hp[0].dexc && !tlbx)
        assert (exr_v_q && exr_rob_q == hid[0]) else $error("tg_rob: exception register does not hold the head");
      for (int j = 0; j < CW; j++)
        if (ret[j] && misp_h[j])
          assert (mpr_v_q && mpr_rob_q == hid[j]) else $error("tg_rob: mispredict register does not hold the branch");
    end
  end
`endif
endmodule
