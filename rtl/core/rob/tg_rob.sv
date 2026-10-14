// Reorder buffer and commit for M2 (docs/spec/core-pipeline.md §8, §9.3-9.4, §11).
//   Payload: ROB_BANKS-way interleaved LUTRAM, written at dispatch, read at the head.
//   Flags per entry in flip-flops: complete, exc, mispredict, replay, mmio, tlb (M3).
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
  input  logic [1:0]                   agr_valid,    // LSU AG reports (LD, STA): one index each
  input  robid_t [1:0]                 agr_rob,
  input  logic [1:0]                   agr_cmp,      // ... complete
  input  logic [1:0]                   agr_exc,      // ... complete with an exception
  input  logic [1:0]                   agr_tlb,      // ... a DTLB miss: replay + tlb
  input  logic [1:0][3:0]              agr_cause,
  input  logic [1:0][63:0]             agr_tval,
  input  logic                         st_cmp,       // a store's data captured after its address
  input  robid_t                       st_rob,
  input  logic [1:0]                   lx_valid,     // LSU exceptions after AG (M2, MMIO/atomic)
  input  robid_t [1:0]                 lx_rob,
  input  logic [1:0][3:0]              lx_cause,
  input  logic [1:0][63:0]             lx_tval,
  input  logic                         replay_valid,
  input  robid_t                       replay_rob,
  input  logic                         hd_retry,
  input  logic                         hd_fault,
  input  logic [3:0]                   hd_cause,
  input  logic [63:0]                  hd_tval,
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
  input  logic [63:0]                  mepc,
  input  logic [63:0]                  sepc,
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
  logic [ROB_ENTRIES-1:0] cmp_q, exc_q, misp_q, rpl_q, mmio_q, tlb_q;
  logic [ROB_ENTRIES-1:0][4:0] ff_q;              // FP exception flags (EXT_FD)

  logic          exr_v_q;
  robid_t        exr_rob_q;
  logic [3:0]    exr_cause_q;
  logic [63:0]   exr_tval_q;
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
  logic [RIW-1:0] i0;
  assign i0 = hid[0][RIW-1:0];
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
      end else if (rpl_q[i0]) begin
        if (!tlb_q[i0] || hd_retry) begin
          do_flush = 1'b1;
          nf_pc = hp[0].pc;
        end else if (hd_fault) begin
          do_trap  = 1'b1;
          do_flush = 1'b1;
          use_tt   = 1'b1;
          tlbx     = 1'b1;
          t_cause  = hd_cause;
          t_tval   = hd_tval;
        end
      end else if (cmp_q[i0] && exc_q[i0]) begin
        do_trap = 1'b1;
        do_flush = 1'b1;
        use_tt = 1'b1;
        if (hp[0].dexc) begin
          t_cause = hp[0].dexc_cause;
          unique case (hp[0].dexc_cause)
            EXC_ILLEGAL: t_tval = {32'b0, hp[0].insn};
            EXC_BREAK: t_tval = hp[0].pc;
            EXC_IACCESS, EXC_IPAGE: t_tval = hp[0].pc + (hp[0].dexc_hi ? 64'd2 : 64'd0);
            default: t_tval = '0;
          endcase
        end else begin
          t_cause = exr_cause_q;
          t_tval  = exr_tval_q;
        end
      end else if (cmp_q[i0] && hp[0].serial) begin
        if (go) begin
          ret[0]   = 1'b1;
          do_flush = 1'b1;
          do_icinv = hp[0].sys == SYS_FENCEI;
          do_csr   = hp[0].is_csr;
          do_mret  = hp[0].sys == SYS_MRET;
          do_sret  = hp[0].sys == SYS_SRET;
          do_sfence = hp[0].sys == SYS_SFENCE;
          nf_pc    = do_mret ? mepc : do_sret ? sepc : hp[0].pc + (hp[0].rvc ? 64'd2 : 64'd4);
        end
      end else begin
        stop = 1'b0;
        for (int j = 0; j < CW; j++) begin
          if (!stop) begin
            if (j < cnt && cmp_q[hid[j][RIW-1:0]] && !exc_q[hid[j][RIW-1:0]] && !hp[j].serial &&
                !rpl_q[hid[j][RIW-1:0]]) begin
              ret[j] = 1'b1;
              if (misp_q[hid[j][RIW-1:0]]) begin
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
      cm_fflags[j] = (EXT_FD && hp[j].is_fp) ? ff_q[hid[j][RIW-1:0]] : '0;
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
        rec[j].mmio_ld = hp[j].is_ld && mmio_q[hid[j][RIW-1:0]];
        rec[j].nondet  = hp[j].is_csr && hp[j].rd_en && csr_nondet(hp[j].insn[31:20]);
      end
    end
  end

  // Oldest exception after this cycle's reports
  logic        ex_v;
  robid_t      ex_r;
  logic [3:0]  ex_c;
  logic [63:0] ex_t;
  always_comb begin
    ex_v = exr_v_q; ex_r = exr_rob_q; ex_c = exr_cause_q; ex_t = exr_tval_q;
    if (oth_cmp && oth_exc && (!ex_v || rob_older(oth_rob, ex_r))) begin
      ex_v = 1'b1; ex_r = oth_rob; ex_c = EXC_ILLEGAL; ex_t = oth_tval;
    end
    if (br_valid && br_exc && (!ex_v || rob_older(br_rob, ex_r))) begin
      ex_v = 1'b1; ex_r = br_rob; ex_c = EXC_IMISALIGN; ex_t = br_tval;
    end
    if (agr_valid[0] && agr_exc[0] && (!ex_v || rob_older(agr_rob[0], ex_r))) begin
      ex_v = 1'b1; ex_r = agr_rob[0]; ex_c = agr_cause[0]; ex_t = agr_tval[0];
    end
    for (int i = 0; i < 2; i++) begin
      if (lx_valid[i] && (!ex_v || rob_older(lx_rob[i], ex_r))) begin
        ex_v = 1'b1; ex_r = lx_rob[i]; ex_c = lx_cause[i]; ex_t = lx_tval[i];
      end
    end
    if (agr_valid[1] && agr_exc[1] && (!ex_v || rob_older(agr_rob[1], ex_r))) begin
      ex_v = 1'b1; ex_r = agr_rob[1]; ex_c = agr_cause[1]; ex_t = agr_tval[1];
    end
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
      end else begin
        // Dispatch
        if (ds_fire) begin
          for (int k = 0; k < DISPATCH_WIDTH; k++) begin
            if (ds_valid[k]) begin
              cmp_q[ds_ren[k].rob[RIW-1:0]]  <= !ds_ren[k].has_q;
              exc_q[ds_ren[k].rob[RIW-1:0]]  <= ds_uop[k].d.exc;
              misp_q[ds_ren[k].rob[RIW-1:0]] <= 1'b0;
              rpl_q[ds_ren[k].rob[RIW-1:0]]  <= 1'b0;
              tlb_q[ds_ren[k].rob[RIW-1:0]]  <= 1'b0;
              mmio_q[ds_ren[k].rob[RIW-1:0]] <= 1'b0;
            end
          end
          tail_q <= rob_add(tail_q, $countones(ds_valid));
        end
        // Completions
        for (int i = 0; i < N_ALU; i++) if (alu_cmp[i]) cmp_q[alu_rob[i][RIW-1:0]] <= 1'b1;
        if (oth_cmp) begin
          cmp_q[oth_rob[RIW-1:0]] <= 1'b1;
          if (oth_exc) exc_q[oth_rob[RIW-1:0]] <= 1'b1;
          if (EXT_FD)  ff_q[oth_rob[RIW-1:0]]  <= oth_fflags;
        end
        if (EXT_FD && fp_cmp) begin
          cmp_q[fp_cmp_rob[RIW-1:0]] <= 1'b1;
          ff_q[fp_cmp_rob[RIW-1:0]]  <= fp_cmp_fflags;
        end
        if (br_valid) begin
          if (br_exc)       exc_q[br_rob[RIW-1:0]] <= 1'b1;
          else if (br_misp) misp_q[br_rob[RIW-1:0]] <= 1'b1;
        end
        if (ld_cmp) begin
          cmp_q[ld_rob[RIW-1:0]]  <= 1'b1;
          mmio_q[ld_rob[RIW-1:0]] <= ld_mmio;
        end
        if (st_cmp) cmp_q[st_rob[RIW-1:0]] <= 1'b1;
        for (int i = 0; i < 2; i++) begin
          if (lx_valid[i]) begin
            cmp_q[lx_rob[i][RIW-1:0]] <= 1'b1;
            exc_q[lx_rob[i][RIW-1:0]] <= 1'b1;
          end
        end
        for (int i = 0; i < 2; i++) begin
          if (agr_valid[i]) begin
            if (agr_cmp[i] || agr_exc[i]) cmp_q[agr_rob[i][RIW-1:0]] <= 1'b1;
            if (agr_exc[i])               exc_q[agr_rob[i][RIW-1:0]] <= 1'b1;
            if (agr_tlb[i]) begin
              rpl_q[agr_rob[i][RIW-1:0]] <= 1'b1;
              tlb_q[agr_rob[i][RIW-1:0]] <= 1'b1;
            end
          end
        end
        if (replay_valid) rpl_q[replay_rob[RIW-1:0]] <= 1'b1;

        // Oldest exception: the current register and this cycle's reports
        exr_v_q <= ex_v && !do_trap; exr_rob_q <= ex_r; exr_cause_q <= ex_c; exr_tval_q <= ex_t;
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

  logic unused;
  assign unused = ^{hp[0].tid, hp[0].is_br, hp[0].lq, hp[CW-1].tid, hp[CW-1].is_br, hp[CW-1].lq,
                    ld_rob[ROBW-1], replay_rob[ROBW-1], alu_rob, st_rob[ROBW-1], oth_rob[ROBW-1],
                    br_rob[ROBW-1], fp_cmp_rob[ROBW-1]};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && !flush) begin
      assert (cnt >= 0 && cnt <= ROB_ENTRIES) else $error("tg_rob: bad occupancy %0d", cnt);
      if (do_trap && !hp[0].dexc && !tlbx)
        assert (exr_v_q && exr_rob_q == hid[0]) else $error("tg_rob: exception register does not hold the head");
      for (int j = 0; j < CW; j++)
        if (ret[j] && misp_q[hid[j][RIW-1:0]])
          assert (mpr_v_q && mpr_rob_q == hid[j]) else $error("tg_rob: mispredict register does not hold the branch");
    end
  end
`endif
endmodule
