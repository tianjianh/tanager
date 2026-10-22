// Register read, bypass and execute for the integer ports (docs/spec/core-pipeline.md §7;
// spike S3 structure): IS (s) -> RF (s+1: read, bypass select) -> EX (s+2: operand mux, ALU,
// branch unit, address generation) -> WB (s+3: result in res_q, register file written at the
// end of the cycle). res_q is the EX bypass level, its copy wbq_q (s+4) the WB level.
//
// Ports: ALU 0 .. N_ALU-1 (P0 adds the branch unit; P1 adds MUL, DIV and CSR, whose results
// reach bank 1 through a write mux), LD and STA (base operand bypassed, address to the LSU),
// the shared store-data read port, and COMMIT_WIDTH trace read ports.
// Bank 1 write slots: ALU1 and CSR write at s+3, MUL at s+5, a finished DIV in the fourth cycle
// after it claims a slot. A MUL in RF (cycle r) and a DIV claim (cycle r) both take slot r+4, the
// slot an A1 select in cycle r+1 would use, so that select is blocked (a1_block, registered).
// A DIV does not claim in a cycle where a MUL is in RF.
// F and D (EXT_FD): an FP->int result from P4 (fpi_*) claims a bank 1 slot like a finished
// divide, after any MUL in RF and any divide claim that cycle; it is written (fpi_ready) and
// wakes its LLT a cycle earlier. P4's integer source takes the shared read port first
// (isrc_*; the LSU's store-data capture waits that cycle).
module tg_exec
  import tg_pkg::*, tg_alu_pkg::*, tg_core_pkg::*;
#(
  localparam int NRP   = 2 * N_ALU + 3 + COMMIT_WIDTH,
  localparam int P_LD  = 2 * N_ALU,
  localparam int P_STA = 2 * N_ALU + 1,
  localparam int P_SH  = 2 * N_ALU + 2,
  localparam int P_TR  = 2 * N_ALU + 3,
  localparam int NSRC  = 2 * (N_ALU + 1) + 2,
  localparam int SW    = idx_w(NSRC),
  localparam int S_RF  = 0,
  localparam int S_EX  = 1,               // + i: ALU i's res_q; + N_ALU: load result
  localparam int S_WB  = N_ALU + 2,       // + i: ALU i's wbq_q; + N_ALU: load result copy
  localparam int S_IMM = NSRC - 1,
  localparam int TAG_W = PIDX_W + ROBW + COL_W + 1   // {dst_en, dst index, rob, wakeup column}
) (
  input  logic                         clk,
  input  logic                         clk2x,       // URF (DR-174): twice clk, for the register file
  input  logic                         rst,
  input  logic                         flush,
  input  tid_t                         flush_tid,   // M7 (DR-175): a flush kills only this thread's ops
  input  logic                         spec_cancel, // speculative wakeup's shadow cancel (SPEC_WAKE; tg_issue)
  input  logic                         misa_c,      // C: jump targets need only 2-byte alignment
  // Reset sequence: zero writes into bank 0
  input  logic                         init_we,
  input  logic [PIDX_W-1:0]            init_idx,
  // Issue (RF stage)
  input  logic [N_XQ-1:0]              iss_valid,
  input  iq_pl_t [N_XQ-1:0]            iss_pl,
  input  preg_t [N_XQ-1:0][1:0]        iss_src_n,   // URF: next cycle's {src2, src1} (tg_issue)
  output logic                         a1_block,
  // Load pipe (LSU): the M2 load that writes next cycle; the load result register
  input  logic                         ld_m2_will,
  input  logic [PIDX_W-1:0]            ld_m2_dst,
  input  logic                         ld_res_valid,
  input  logic [PIDX_W-1:0]            ld_res_dst,
  input  logic [63:0]                  ld_res_data,
  // Address generation (EX) to the LSU
  output logic                         ld_ag_valid,
  output iq_pl_t                       ld_ag_pl,
  output logic [63:0]                  ld_ag_addr,
  output logic                         sta_ag_valid,
  output iq_pl_t                       sta_ag_pl,
  output logic [63:0]                  sta_ag_addr,
  // Shared store-data read port and trace read ports (combinational)
  input  preg_t                        sd_tag,
  output logic [63:0]                  sd_data,
  // P4 (EXT_FD): its integer source through the shared port; FP->int results for bank 1
  input  logic                         isrc_valid,
  input  preg_t                        isrc_tag,
  output logic [63:0]                  isrc_data,
  input  logic                         fpi_valid,
  input  logic                         fpi_kill,       // the head was flushed: pop it, no write
  output logic                         fpi_ready,      // written (or, if killed, popped) this cycle
  input  robid_t                       fpi_rob,
  input  llt_t                         fpi_llt,
  input  logic                         fpi_dst_en,
  input  preg_t                        fpi_dst,
  input  logic [63:0]                  fpi_data,
  input  logic [4:0]                   fpi_fflags,
  input  tid_t                         fpi_tid,     // the head's thread
  input  preg_t [COMMIT_WIDTH-1:0]     tr_tag,
  output logic [COMMIT_WIDTH-1:0][63:0] tr_data,
  // Register-file writes (for the ready table)
  output logic [INT_BANKS-1:0]         rf_we_o,
  output logic [INT_BANKS-1:0][PIDX_W-1:0] rf_widx_o,
  // Completion
  output logic [N_ALU-1:0]             cmp_valid,
  output robid_t [N_ALU-1:0]           cmp_rob,
  output logic                         oth_valid,      // bank 1 mux: MUL, DIV, CSR
  output robid_t                       oth_rob,
  output logic                         oth_exc,        // CSR: illegal instruction
  output logic [4:0]                   oth_fflags,     // FP->int results
  output logic [63:0]                  oth_tval,
  // Branch resolution (P0, WB)
  output logic                         br_valid,
  output robid_t                       br_rob,
  output logic                         br_mispredict,
  output logic [63:0]                  br_npc,
  output logic                         br_exc,
  output logic [63:0]                  br_tval,
  // Micro-BTB training
  output logic                         upd_valid,
  output logic                         upd_way,
  output logic                         upd_inval,
  output logic [63:0]                  upd_pc,
  output logic [SLOT_W-1:0]            upd_slot,
  output logic [63:0]                  upd_target,
  output tid_t                         upd_tid,        // the branch's thread (M7 step 5: the entry's tid)
  // Wakeups (W set at the end of this cycle) and LLT results written
  output logic [NCOL-1:0]              wake_reg,
  output logic [LLT_ENTRIES-1:0]       llt_done,
  output logic [IQ_TAGS-1:0]           tag_free,       // MUL tags, 2 cycles after the write
  output logic                         div_done,
  output tid_t                         div_done_tid,   // the divide's thread (M7 step 5: rename's count per thread)
  // CSR execute (P1 EX)
  output logic                         csr_ex_valid,
  output iq_pl_t                       csr_ex_pl,
  output logic [63:0]                  csr_ex_src,
  input  logic [63:0]                  csr_ex_rdata,
  input  logic                         csr_ex_ill
);
  if (N_ALU < 2) begin : g_bad
    $error("tg_exec: needs N_ALU >= 2 (P1 hosts MUL, DIV and CSR)");
  end

  // ---- Register file ----
  logic [INT_BANKS-1:0]                 rf_we;
  logic [INT_BANKS-1:0][PIDX_W-1:0]     rf_wa;
  logic [INT_BANKS-1:0][63:0]           rf_wd;
  logic [NRP-1:0][BANK_W-1:0]           rd_bank;
  logic [NRP-1:0][PIDX_W-1:0]           rd_idx;
  logic [NRP-1:0][63:0]                 rd_data;
  // URF (DR-174): the issue-time ports (ALU operands, then the LD and STA bases, whose select after
  // the read makes them the early ports) in UltraRAM; their next addresses come from the selects
  logic [P_SH-1:0][BANK_W-1:0]          rd_bank_n;
  logic [P_SH-1:0][PIDX_W-1:0]          rd_idx_n;
  tg_irf #(.NB(INT_BANKS), .DEPTH(INT_PREGS_PER_BANK), .NR(NRP), .URF(URF), .NI(P_SH)) u_irf (
    .clk, .clk2x, .we(rf_we), .waddr(rf_wa), .wdata(rf_wd), .rbank(rd_bank), .ridx(rd_idx),
    .rbank_n(rd_bank_n), .ridx_n(rd_idx_n), .rdata(rd_data));
  for (genvar i = 0; i < N_ALU; i++) begin : g_rdn
    assign rd_bank_n[2*i]   = preg_bank(iss_src_n[i][0]);
    assign rd_idx_n[2*i]    = preg_idx(iss_src_n[i][0]);
    assign rd_bank_n[2*i+1] = preg_bank(iss_src_n[i][1]);
    assign rd_idx_n[2*i+1]  = preg_idx(iss_src_n[i][1]);
  end
  assign rd_bank_n[P_LD]  = preg_bank(iss_src_n[Q_LD][0]);
  assign rd_idx_n[P_LD]   = preg_idx(iss_src_n[Q_LD][0]);
  assign rd_bank_n[P_STA] = preg_bank(iss_src_n[Q_STA][0]);
  assign rd_idx_n[P_STA]  = preg_idx(iss_src_n[Q_STA][0]);
  logic unused_srcn;                    // LD and STA have no second source
  assign unused_srcn = ^{iss_src_n[Q_LD][1], iss_src_n[Q_STA][1]};

  // Read addresses: ALU operands, LD and STA bases (RF stage), store data, trace
  for (genvar i = 0; i < N_ALU; i++) begin : g_rda
    assign rd_bank[2*i]   = preg_bank(iss_pl[i].src1);
    assign rd_idx[2*i]    = preg_idx(iss_pl[i].src1);
    assign rd_bank[2*i+1] = preg_bank(iss_pl[i].src2);
    assign rd_idx[2*i+1]  = preg_idx(iss_pl[i].src2);
  end
  assign rd_bank[P_LD]  = preg_bank(iss_pl[Q_LD].src1);
  assign rd_idx[P_LD]   = preg_idx(iss_pl[Q_LD].src1);
  assign rd_bank[P_STA] = preg_bank(iss_pl[Q_STA].src1);
  assign rd_idx[P_STA]  = preg_idx(iss_pl[Q_STA].src1);
  assign rd_bank[P_SH]  = preg_bank((EXT_FD && isrc_valid) ? isrc_tag : sd_tag);
  assign rd_idx[P_SH]   = preg_idx((EXT_FD && isrc_valid) ? isrc_tag : sd_tag);
  assign sd_data        = rd_data[P_SH];
  assign isrc_data      = rd_data[P_SH];
  for (genvar j = 0; j < COMMIT_WIDTH; j++) begin : g_tr
    assign rd_bank[P_TR+j] = preg_bank(tr_tag[j]);
    assign rd_idx[P_TR+j]  = preg_idx(tr_tag[j]);
    assign tr_data[j]      = rd_data[P_TR+j];
  end

  // ---- Pipeline state per port (ALU ports, then LD and STA) ----
  logic [N_XQ-1:0]              ex_v_q;
  // SPEC_WAKE: a shadow cancel (tg_issue, registered) returns what the integer queues issued in
  // this cycle and the two before it, so the RF and EX stages of every port die here: nothing in
  // EX acts (write-back, branch, MUL, DIV, CSR, AG), and nothing in RF moves on
  logic                         sc;
  logic [N_XQ-1:0]              ex_lv;               // the EX stage's live ops
  assign sc    = SPEC_WAKE && spec_cancel;
  assign ex_lv = ex_v_q & {N_XQ{!sc}};
  // M7 step 1 (DR-175): a flush kills only the flushed thread's ops; every stage keeps its op's tid
  function automatic logic fk(input tid_t t);
    return flush && t == flush_tid;
  endfunction
  iq_pl_t [N_XQ-1:0]            ex_pl_q;
  logic [N_XQ-1:0][63:0]        ex_a_q, ex_b_q;      // register-file values
  logic [N_XQ-1:0][SW-1:0]      ex_sa_q, ex_sb_q;    // operand selects
  logic [N_ALU-1:0]             wb_v_q;              // res_q holds an ALU result
  logic [N_ALU-1:0]             wb_dv_q;             // ... with a destination
  logic [N_ALU-1:0][PIDX_W-1:0] wb_dst_q;
  robid_t [N_ALU-1:0]           wb_rob_q;
  logic [N_ALU-1:0]             wb_cmp_q;            // completes at WB (ALU-class)
  logic [N_ALU-1:0][63:0]       res_q, wbq_q;
  logic [63:0]                  ld_wbq_q;

  // An op whose result goes through res_q (bypassable): ALU ops, and branches on P0
  function automatic logic alu_class(input int i, input uclass_e c);
    return c == C_ALU || (i == 0 && c == C_BR);
  endfunction

  // ---- RF stage: bypass selects ----
  function automatic logic [SW-1:0] bsel(input preg_t t, input logic [N_XQ-1:0] exv,
                                         input iq_pl_t [N_XQ-1:0] expl, input logic [N_ALU-1:0] wbdv,
                                         input logic [N_ALU-1:0][PIDX_W-1:0] wbdst,
                                         input logic m2w, input logic [PIDX_W-1:0] m2d,
                                         input logic lrv, input logic [PIDX_W-1:0] lrd);
    int b;
    b = int'(preg_bank(t));
    if (b == LD_BANK) begin
      if (m2w && m2d == preg_idx(t)) return SW'(S_EX + N_ALU);
      if (lrv && lrd == preg_idx(t)) return SW'(S_WB + N_ALU);
      return SW'(S_RF);
    end
    for (int i = 0; i < N_ALU; i++) begin
      if (i == b) begin
        if (exv[i] && alu_class(i, expl[i].cls) && expl[i].dst_en && preg_idx(expl[i].dst) == preg_idx(t))
          return SW'(S_EX + i);
        if (wbdv[i] && wbdst[i] == preg_idx(t)) return SW'(S_WB + i);
      end
    end
    return SW'(S_RF);
  endfunction

  // The LD and STA bases take their write-back-level bypass here: res_q and the load result are now
  // what wbq_q and ld_wbq_q hold in EX. Each base then has two small encoded selects, rbs here
  // (the register value, or ALU i's or the load's write-back-level value) and ex_bs_q in EX (the
  // register, or ALU i's or the load's EX-level value): one LUT level in front of the address adder
  // (cycle-identical).
  localparam int BSW = idx_w(N_ALU + 2);
  logic [N_XQ-1:0][SW-1:0]  sa, sb;
  logic [N_XQ-1:0][63:0]    ra, rb;
  // LD (0) and STA (1): RF-stage and EX-stage selects, kept as nets so each data bit takes the
  // decoded select (one LUT6) rather than re-decoding the bypass code
  (* keep = "true" *) logic [1:0][BSW-1:0] rbs, ebs;
  logic [1:0][BSW-1:0]      ex_bs_q;
  for (genvar q = 0; q < N_XQ; q++) begin : g_sel
    localparam int BK = (q >= N_ALU) ? q - N_ALU : 0;   // LD (0) or STA (1); in range elsewhere
    always_comb begin
      sa[q] = bsel(iss_pl[q].src1, ex_lv, ex_pl_q, wb_dv_q, wb_dst_q, ld_m2_will, ld_m2_dst,
                   ld_res_valid, ld_res_dst);
      sb[q] = iss_pl[q].b_imm ? SW'(S_IMM)
            : bsel(iss_pl[q].src2, ex_lv, ex_pl_q, wb_dv_q, wb_dst_q, ld_m2_will, ld_m2_dst,
                   ld_res_valid, ld_res_dst);
    end
    always_comb begin
      if (q < N_ALU) begin
        ra[q] = rd_data[2*q];
        rb[q] = rd_data[2*q+1];
      end else begin
        rb[q] = '0;
        unique case (int'(rbs[BK]))
          0:         ra[q] = rd_data[(q == Q_LD) ? P_LD : P_STA];
          N_ALU + 1: ra[q] = ld_res_data;
          default:   ra[q] = res_q[(int'(rbs[BK]) - 1) % N_ALU];
        endcase
      end
    end
  end
  for (genvar k = 0; k < 2; k++) begin : g_bs
    always_comb begin
      int s;
      s = int'(sa[N_ALU + k]);
      rbs[k] = '0;
      ebs[k] = '0;
      if (s >= S_WB && s <= S_WB + N_ALU)      rbs[k] = BSW'(s - S_WB + 1);  // write-back level
      else if (s >= S_EX && s <= S_EX + N_ALU) ebs[k] = BSW'(s - S_EX + 1);  // EX level
    end
  end

  // ---- EX stage: operand muxes ----
  logic [NSRC-1:0][63:0] src_common;
  always_comb begin
    src_common = '0;
    for (int i = 0; i < N_ALU; i++) begin
      src_common[S_EX + i] = res_q[i];
      src_common[S_WB + i] = wbq_q[i];
    end
    src_common[S_EX + N_ALU] = ld_res_data;
    src_common[S_WB + N_ALU] = ld_wbq_q;
  end
  function automatic logic [63:0] opmux(input logic [NSRC-1:0][63:0] s, input logic [SW-1:0] sel);
    logic [63:0] o;
    o = '0;
    for (int k = 0; k < NSRC; k++) if (sel == SW'(k)) o = s[k];
    return o;
  endfunction

  logic [N_XQ-1:0][63:0] opa, opb;
  for (genvar q = 0; q < N_XQ; q++) begin : g_op
    localparam int BK = (q >= N_ALU) ? q - N_ALU : 0;
    always_comb begin
      logic [NSRC-1:0][63:0] s1, s2;
      s1 = src_common;
      s2 = src_common;
      s1[S_RF]  = ex_a_q[q];
      s2[S_RF]  = ex_b_q[q];
      s1[S_IMM] = '0;
      s2[S_IMM] = ex_pl_q[q].imm;
      opa[q] = opmux(s1, ex_sa_q[q]);
      opb[q] = opmux(s2, ex_sb_q[q]);
      if (q >= N_ALU) begin                // LD, STA: the register value or an EX-level source
        unique case (int'(ex_bs_q[BK]))
          0:         opa[q] = ex_a_q[q];
          N_ALU + 1: opa[q] = ld_res_data;
          default:   opa[q] = res_q[(int'(ex_bs_q[BK]) - 1) % N_ALU];
        endcase
      end
    end
  end

  // ---- ALUs ----
  logic [N_ALU-1:0][63:0] alu_res;
  logic [N_ALU-1:0]       f_eq, f_lt, f_ltu;
  for (genvar i = 0; i < N_ALU; i++) begin : g_alu
    tg_alu #(.MINMAX(1'b0), .SIMPLE(ALU_SIMPLE[i])) u_alu (.ctl(ex_pl_q[i].alu), .a(opa[i]), .b(opb[i]), .res(alu_res[i]),
                  .eq(f_eq[i]), .lt(f_lt[i]), .ltu(f_ltu[i]));
  end

  // ---- Branch unit (P0, EX) ----
  iq_pl_t      bp;
  logic        bt_taken;
  logic [63:0] bt_target, bt_npc, bt_seq;
  assign bp = ex_pl_q[0];
  // bt_seq = bp.pc + 2 or 4, in DSPs that hold their own copy of the RF -> EX register (T6)
  tg_fpu_dsp_add #(.W(64)) u_seq (
    .clk, .ce(1'b1), .a(iss_pl[0].pc), .b(iss_pl[0].rvc ? 64'd2 : 64'd4), .ci(1'b0), .s(bt_seq));
  always_comb begin
    unique case (bp.br_f3)
      3'd0: bt_taken = f_eq[0];
      3'd1: bt_taken = !f_eq[0];
      3'd4: bt_taken = f_lt[0];
      3'd5: bt_taken = !f_lt[0];
      3'd6: bt_taken = f_ltu[0];
      default: bt_taken = !f_ltu[0];
    endcase
    if (bp.br_kind != BR_COND) bt_taken = 1'b1;
    // One adder: JALR adds rs1 and its offset, the others zero to the decoded target (whose bit 0
    // is zero), so the target select sits in the adder's LUTs (fpga_friendly.md T7)
    bt_target = ((bp.br_kind == BR_JALR ? opa[0] : bp.br_target)
               + (bp.br_kind == BR_JALR ? {{52{bp.jalr_off[11]}}, bp.jalr_off} : 64'd0)) & ~64'd1;
    bt_npc = bt_taken ? bt_target : bt_seq;
  end
  // The misprediction test bt_npc != pred_npc as (taken ? target != pred : seq != pred): the
  // taken flag (the end of ALU0's carry chain for conditional branches) then selects between two
  // compares instead of going through the next-PC multiplexer and a compare (timing; one more
  // 64-bit compare).
  logic tgt_ne, seq_ne;
  assign tgt_ne = bt_target != bp.pred_npc;
  assign seq_ne = bt_seq != bp.pred_npc;
  logic ex_br;
  assign ex_br = ex_lv[0] && bp.cls == C_BR;

  // Direction counters (read in EX, written in WB). M7 step 5 (DR-175): the hart (tid ^ RUN_TID, so SOLO_TID's
  // tid 1 indexes as hart 0: cycle for cycle the same) flips the index's top bit, so the harts' branches at one PC
  // train apart; a branch's write stays through the other thread's flush (bht_we_q, below)
  localparam int BHT_W = idx_w(BHT_ENTRIES);
  function automatic logic [BHT_W-1:0] bht_ix(input logic [BHT_W-1:0] pcb, input tid_t t);   // pcb: pc[2 +: BHT_W]
    logic [BHT_W-1:0] ix;
    ix          = pcb;
    ix[BHT_W-1] = ix[BHT_W-1] ^ ((t ^ RUN_TID) != '0);
    return ix;
  endfunction
  logic [0:0][BHT_W-1:0] bht_ra;
  logic [0:0][1:0]       bht_rd;
  logic                  bht_we_q;
  logic [BHT_W-1:0]      bht_wa_q;
  logic [1:0]            bht_wd_q;
  assign bht_ra[0] = bht_ix(bp.pc[2 +: BHT_W], bp.tid);
  tg_ram_lut #(.DEPTH(BHT_ENTRIES), .WIDTH(2), .NR(1)) u_bht (
    .clk, .we(bht_we_q), .waddr(bht_wa_q), .wdata(bht_wd_q), .raddr(bht_ra), .rdata(bht_rd));
  logic [1:0] ctr_new;
  always_comb begin
    ctr_new = bht_rd[0];
    if (bt_taken && ctr_new != 2'd3) ctr_new = ctr_new + 2'd1;
    if (!bt_taken && ctr_new != 2'd0) ctr_new = ctr_new - 2'd1;
  end

  // WB-stage branch state
  logic        bw_v_q, bw_taken_q, bw_exc_q, bw_misp_q, bw_strong_q, bw_hit_q, bw_way_q, bw_dfix_q;
  logic        bw_rvc_q;
  tid_t        bw_tid_q;
  robid_t      bw_rob_q;
  logic [63:0] bw_npc_q, bw_pc_q, bw_tgt_q, bw_pred_q;
  logic [7:0]  lfsr_q;

  assign br_valid      = bw_v_q;
  assign br_rob        = bw_rob_q;
  assign br_exc        = bw_exc_q;
  assign br_tval       = bw_tgt_q;
  assign br_mispredict = bw_misp_q;
  assign br_npc        = bw_npc_q;

  // Training: rewrite the entry when the branch should be predicted taken and the micro-BTB did
  // not predict this target here; invalidate it when it should not be predicted taken.
  always_comb begin
    upd_valid  = 1'b0;
    upd_inval  = 1'b0;
    upd_way    = bw_hit_q ? bw_way_q : lfsr_q[0];
    upd_pc     = bw_pc_q;
    upd_target = bw_tgt_q;
    upd_tid    = bw_tid_q;
    upd_slot   = bw_pc_q[SLOT_W:1] + SLOT_W'(!bw_rvc_q);
    if (bw_v_q && !bw_exc_q && !(bw_pc_q[SLOT_W:1] == SLOT_W'(NP - 1) && !bw_rvc_q)) begin
      if (bw_strong_q) begin
        if (!bw_hit_q || bw_dfix_q || bw_pred_q != bw_tgt_q) upd_valid = 1'b1;
      end else if (bw_hit_q) begin
        upd_valid = 1'b1;
        upd_inval = 1'b1;
      end
    end
  end

  // ---- P1: MUL, DIV, CSR ----
  iq_pl_t p1;
  assign p1 = ex_pl_q[1];
  logic ex_mul, ex_div, ex_csr;
  assign ex_mul = ex_lv[1] && p1.cls == C_MUL;
  assign ex_div = ex_lv[1] && p1.cls == C_DIV;
  assign ex_csr = ex_lv[1] && p1.cls == C_CSR;
  assign csr_ex_valid = ex_csr;
  assign csr_ex_pl    = p1;
  assign csr_ex_src   = opa[1];

  logic [TAG_W-1:0] p1_tag;
  assign p1_tag = {p1.dst_en, preg_idx(p1.dst), p1.rob, p1.wid};
  logic              mul_ov;
  logic [63:0]       mul_res;              // unused: the bank 1 write multiplexer selects from
  logic [127:0]      mul_prod;             // the product itself (one LUT level less)
  logic              mul_hi, mul_word;
  logic [TAG_W-1:0]  mul_tag;
  tid_t              mul_tid;              // the thread of the MUL in M3
  tg_mul #(.TAG_W(TAG_W)) u_mul (
    .clk, .rst, .flush, .flush_tid, .in_tid(p1.tid), .out_tid(mul_tid),
    .in_valid(ex_mul), .in_op(p1.mul_op), .in_word(p1.word && !p1.bcnt), .in_a(opa[1]),
    .in_b(opb[1]), .in_tag(p1_tag), .out_valid(mul_ov), .out_res(mul_res), .out_tag(mul_tag),
    .out_prod(mul_prod), .out_hi(mul_hi), .out_word(mul_word));

  // clz, ctz, cpop and min/max (Zbb) ride the MUL slot: their operands and ALU1's compare flag
  // are registered at the end of EX and the result is computed in the next cycle, then delayed to
  // the MUL's write cycle (spike S3: min/max out of the 1-cycle ALU loop, tg_alu MINMAX = 0; the
  // count needs no bypass, so it may start a cycle late: this takes the load bypass, the count
  // and the flag out of one cycle)
  // - clz and ctz share one leading-zero count (tg_fpu_lzc), ctz(x) = clz(x bit-reversed). The W
  //   forms put ones beside the low word (below it for clz, above it for ctz), so the count stops
  //   at 32. cpop adds 3-bit counts of 6-bit groups in a tree.
  // - min/max take ALU1's compare flags (its adder subtracts for them: sub is set in RF, below).
  logic [63:0]       bc_res;
  logic [2:0]        bc_v_q;
  tid_t [1:0]        bc_t_q;
  logic [2:1][63:0]  bc_q;
  logic [63:0]       bca_q, bcb_q;             // the operands, registered at the end of EX
  mul_op_e           bcop_q;
  logic              bcw_q, bclt_q, bcmax_q;
  logic [63:0]       bcx, bcy, bcw;
  logic [6:0]        bc_lz, bc_pc;
  always_comb begin
    bcx = bcw_q ? {32'b0, bca_q[31:0]} : bca_q;
    bcw = bcw_q ? {32'hFFFF_FFFF, bca_q[31:0]} : bca_q;
    bcy = bcw_q ? {bca_q[31:0], 32'hFFFF_FFFF} : bca_q;
    if (bcop_q == MUL_H) for (int i = 0; i < 64; i++) bcy[i] = bcw[63 - i];  // ctz
  end
  tg_fpu_lzc #(.W(64)) u_bclz (.x(bcy), .cnt(bc_lz));                      // clz, ctz
  // cpop: 3-bit counts of 6-bit groups, then a tree of adders
  always_comb begin
    logic [10:0][2:0] g3;
    logic [5:0][3:0]  s4;
    logic [2:0][4:0]  s5;
    for (int g = 0; g < 11; g++) begin
      g3[g] = '0;
      for (int k = 0; k < 6; k++) if (6 * g + k < 64) g3[g] += 3'(bcx[6 * g + k]);
    end
    for (int j = 0; j < 5; j++) s4[j] = 4'(g3[2 * j]) + 4'(g3[2 * j + 1]);
    s4[5] = 4'(g3[10]);
    for (int j = 0; j < 3; j++) s5[j] = 5'(s4[2 * j]) + 5'(s4[2 * j + 1]);
    bc_pc = 7'(6'(s5[0]) + 6'(s5[1])) + 7'(s5[2]);
  end
  always_comb begin
    bc_res = 64'(bcop_q == MUL_HSU ? bc_pc : bc_lz);
    if (bcop_q == MUL_HU) bc_res = (bclt_q ^ bcmax_q) ? bca_q : bcb_q;       // MIN(U), MAX(U)
  end

  logic              div_ov, div_ordy;
  logic [63:0]       div_res;
  logic [TAG_W-1:0]  div_tag;
  tid_t              div_tid;              // the thread of the divider's result
  logic [idx_w(DIV_INFLIGHT + 1)-1:0] div_cnt;
  tg_div #(.TAG_W(TAG_W), .DEPTH(DIV_INFLIGHT)) u_div (
    .clk, .rst, .flush, .flush_tid, .in_tid(p1.tid), .out_tid(div_tid),
    .in_valid(ex_div), .in_op(p1.div_op), .in_word(p1.word), .in_a(opa[1]),
    .in_b(opb[1]), .in_tag(p1_tag), .out_valid(div_ov), .out_ready(div_ordy), .out_res(div_res),
    .out_tag(div_tag), .count(div_cnt));

  // Bank 1 write slots
  logic       a1_block_q;
  logic       rf_mul;                      // a MUL in RF claims slot +4
  assign rf_mul = iss_valid[1] && iss_pl[1].cls == C_MUL && !sc;
  logic       div_claim;                   // the finished divide claims slot +4
  logic [2:0] div_wait_q;                  // cycles to its slot (0: none)
  assign div_claim = div_ov && div_wait_q == '0 && !rf_mul && !fk(div_tid);
  logic       fpi_claim;                   // the FP->int result at P4's queue head claims slot +4
  logic [2:0] fpi_wait_q;
  logic       fpi_wr;                      // the claimed head is written this cycle
  assign fpi_claim = EXT_FD && fpi_valid && !fpi_kill && fpi_wait_q == '0 && !rf_mul && !div_claim &&
                     !fk(fpi_tid);
  assign fpi_wr    = fpi_wait_q == 3'd1 && !fk(fpi_tid);
  assign fpi_ready = fpi_wr || (EXT_FD && fpi_valid && fpi_kill && fpi_wait_q == '0);
  assign a1_block  = a1_block_q;
  assign div_ordy  = div_wait_q == 3'd1;
  assign div_done  = div_ov && div_ordy;
  assign div_done_tid = div_tid;

  // CSR result, registered at the end of EX (written at s+3, like an ALU result)
  logic        csr_v_q, csr_ill_q, csr_dv_q;
  logic [PIDX_W-1:0] csr_dst_q;
  robid_t      csr_rob_q;
  logic [63:0] csr_res_q, csr_tval_q;

  // MUL wakeup delay line: RF (r) -> W set at the end of r + 3
  logic [2:0]       mwk_v_q;
  tid_t [2:0]       mwk_t_q;              // each stage's thread
  wid_t [2:0]       mwk_id_q;
  // MUL tags return 2 cycles after the result's register write (rename's RN can no longer see
  // it unwritten; tg_issue clears the tag's column)
  logic [1:0]                    tf_v_q;
  tid_t [1:0]                    tf_t_q;
  logic [1:0][WTAG_W-1:0]        tf_id_q;
  always_comb begin
    tag_free = '0;
    if (tf_v_q[1] && !fk(tf_t_q[1])) tag_free[tf_id_q[1]] = 1'b1;   // (a flush returns its thread's tags)
  end

  // ---- Bank 1 write mux and completions ----
  // The data is an encoded 8:1 select over ALU1, CSR, bit counts, the product's three forms,
  // DIV and FP->int: the MUL's own M3 select folds in here (at most one writer is valid; see
  // the assertion below).
  typedef enum logic [2:0] { W1_ALU, W1_CSR, W1_BC, W1_MLO, W1_MHI, W1_MW, W1_DIV, W1_FPI } w1_e;
  logic        oth_we;
  logic [PIDX_W-1:0] oth_wa;
  w1_e         w1s;
  always_comb begin
    oth_we = 1'b0; oth_wa = '0; w1s = W1_ALU;
    oth_valid = 1'b0; oth_rob = '0; oth_exc = 1'b0; oth_tval = '0; oth_fflags = '0;
    if (csr_v_q) begin
      oth_valid = 1'b1; oth_rob = csr_rob_q; oth_exc = csr_ill_q; oth_tval = csr_tval_q;
      oth_we = csr_dv_q && !csr_ill_q; oth_wa = csr_dst_q; w1s = W1_CSR;
    end else if (mul_ov) begin
      oth_valid = 1'b1; oth_rob = mul_tag[COL_W +: ROBW];
      oth_we = mul_tag[TAG_W-1]; oth_wa = mul_tag[COL_W + ROBW +: PIDX_W];
      w1s = bc_v_q[2] ? W1_BC : mul_word ? W1_MW : mul_hi ? W1_MHI : W1_MLO;
    end else if (div_ov && div_ordy) begin
      oth_valid = 1'b1; oth_rob = div_tag[COL_W +: ROBW];
      oth_we = div_tag[TAG_W-1]; oth_wa = div_tag[COL_W + ROBW +: PIDX_W]; w1s = W1_DIV;
    end else if (fpi_wr) begin
      oth_valid = 1'b1; oth_rob = fpi_rob; oth_fflags = fpi_fflags;
      oth_we = fpi_dst_en; oth_wa = preg_idx(fpi_dst); w1s = W1_FPI;
    end
    if (!oth_we) w1s = W1_ALU;
  end
  logic [63:0] wd1;                        // bank 1 write data
  always_comb begin
    for (int i = 0; i < 64; i++) begin
      unique case (w1s)
        W1_ALU:  wd1[i] = res_q[1][i];
        W1_CSR:  wd1[i] = csr_res_q[i];
        W1_BC:   wd1[i] = bc_q[2][i];
        W1_MLO:  wd1[i] = mul_prod[i];
        W1_MHI:  wd1[i] = mul_prod[64 + i];
        W1_MW:   wd1[i] = mul_prod[i < 32 ? i : 31];
        W1_DIV:  wd1[i] = div_res[i];
        default: wd1[i] = fpi_data[i];
      endcase
    end
  end

  always_comb begin
    for (int i = 0; i < N_ALU; i++) begin
      rf_we[i] = wb_dv_q[i];
      rf_wa[i] = wb_dst_q[i];
      rf_wd[i] = res_q[i];
      cmp_valid[i] = wb_cmp_q[i];
      cmp_rob[i]   = wb_rob_q[i];
    end
    rf_wd[1] = wd1;
    if (oth_we) begin
      rf_we[1] = 1'b1;
      rf_wa[1] = oth_wa;
    end
    if (init_we) begin                     // the data is res_q[0], zero then (below)
      rf_we[0] = 1'b1;
      rf_wa[0] = init_idx;
      if (HART1_ON && N_ALU > 1 && init_idx < PIDX_W'(16)) begin   // hart 1's x1-x16 (M7's step 5c): res_q[1]
        rf_we[1] = 1'b1;                   // (nothing else writes bank 1 then: w1s is W1_ALU)
        rf_wa[1] = init_idx;
      end
    end
    rf_we[LD_BANK] = ld_res_valid;
    rf_wa[LD_BANK] = ld_res_dst;
    rf_wd[LD_BANK] = ld_res_data;
  end
  assign rf_we_o   = rf_we;
  assign rf_widx_o = rf_wa;

  // Wakeups: MUL delay line; a claimed divide one cycle before its write. None for an op whose
  // thread is flushed in this cycle, and no LLT or tag returned for it (the flush returns its
  // thread's), so the sibling thread can take them at once (M7, DR-175; P4 does the same)
  always_comb begin
    wake_reg = '0;
    if (mwk_v_q[2] && !fk(mwk_t_q[2])) wake_reg[mwk_id_q[2]] = 1'b1;
    if (div_wait_q == 3'd2 && div_tag[TAG_W-1] && !fk(div_tid)) wake_reg[div_tag[COL_W-1:0]] = 1'b1;  // its LLT
    if (fpi_wait_q == 3'd2 && fpi_dst_en && !fk(fpi_tid)) wake_reg[llt_col(int'(fpi_llt))] = 1'b1;
    llt_done = '0;
    if (div_ov && div_ordy && div_tag[TAG_W-1] && !fk(div_tid))
      llt_done[LLT_IDX_W'(int'(div_tag[COL_W-1:0]) - IQ_TAGS)] = 1'b1;
    if (fpi_wr && fpi_dst_en) llt_done[fpi_llt] = 1'b1;
  end

  // ---- Address generation (EX) ----
  assign ld_ag_valid  = ex_lv[Q_LD];
  assign ld_ag_pl     = ex_pl_q[Q_LD];
  assign ld_ag_addr   = opa[Q_LD] + ex_pl_q[Q_LD].imm;
  assign sta_ag_valid = ex_lv[Q_STA];
  assign sta_ag_pl    = ex_pl_q[Q_STA];
  assign sta_ag_addr  = opa[Q_STA] + ex_pl_q[Q_STA].imm;

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    // RF -> EX
    ex_pl_q <= iss_pl;
    // min/max on P1's 2-cycle path read ALU1's compare flags, so its adder subtracts for them
    if (iss_pl[1].cls == C_MUL && iss_pl[1].bcnt && iss_pl[1].mul_op == MUL_HU)
      ex_pl_q[1].alu.sub <= 1'b1;
    ex_sa_q <= sa;
    ex_sb_q <= sb;
    ex_bs_q <= ebs;
    for (int q = 0; q < N_XQ; q++) begin
      ex_a_q[q] <= ra[q];
      ex_b_q[q] <= rb[q];
    end
    // EX -> WB
    for (int i = 0; i < N_ALU; i++) begin
      res_q[i]    <= alu_res[i];
      wb_dst_q[i] <= preg_idx(ex_pl_q[i].dst);
      wb_rob_q[i] <= ex_pl_q[i].rob;
    end
    // res_q[0] is zero through the reset sequence (rst, then init_we, while nothing issues), so
    // bank 0's zero writes take it as their data: no multiplexer in front of the bank (T7)
    if (rst || init_we) res_q[0] <= '0;
    if (HART1_ON && (rst || init_we)) res_q[1] <= '0;   // (hart 1's homes in bank 1, M7's step 5c)
    wbq_q    <= res_q;
    ld_wbq_q <= ld_res_data;
    // Branch WB state
    bw_rob_q    <= bp.rob;
    bw_taken_q  <= bt_taken;
    bw_npc_q    <= bt_npc;
    bw_pc_q     <= bp.pc;
    bw_tgt_q    <= bt_target;
    bw_pred_q   <= bp.pred_npc;
    bw_rvc_q    <= bp.rvc;
    bw_exc_q    <= bt_taken && bt_target[1] && !misa_c;   // 4-byte alignment without C
    bw_misp_q   <= bt_taken ? tgt_ne : seq_ne;    // bt_npc != bp.pred_npc
    bw_strong_q <= bp.br_kind != BR_COND || ctr_new[1];
    bw_hit_q    <= bp.ubtb_hit;
    bw_way_q    <= bp.ubtb_way;
    bw_dfix_q   <= bp.dfix;
    bw_tid_q    <= bp.tid;
    bht_wa_q    <= bht_ix(bp.pc[2 +: BHT_W], bp.tid);
    bht_wd_q    <= ctr_new;
    // CSR
    csr_dst_q  <= preg_idx(p1.dst);
    csr_rob_q  <= p1.rob;
    csr_res_q  <= csr_ex_rdata;
    csr_tval_q <= {32'b0, p1.insn};
    csr_ill_q  <= csr_ex_ill;
    csr_dv_q   <= p1.dst_en;
    // Bit counts alongside the MUL pipeline
    bc_q[1] <= bc_res;
    bc_q[2] <= bc_q[1];
    bca_q   <= opa[1];
    bcb_q   <= opb[1];
    bcop_q  <= p1.mul_op;
    bcw_q   <= p1.word;
    bclt_q  <= p1.alu.cmp_unsigned ? f_ltu[1] : f_lt[1];
    bcmax_q <= p1.alu.cmp_max;
    // MUL wakeup ids
    mwk_id_q[0] <= iss_pl[1].wid;
    mwk_id_q[1] <= mwk_id_q[0];
    mwk_id_q[2] <= mwk_id_q[1];
    tf_id_q     <= {tf_id_q[0], mul_tag[WTAG_W-1:0]};
    lfsr_q <= {lfsr_q[6:0], lfsr_q[7] ^ lfsr_q[5] ^ lfsr_q[4] ^ lfsr_q[3]};

    // A flush clears what belongs to the flushed thread (fk); with one thread (hart 1 off) that is
    // everything, as before (M7 step 1, DR-175)
    if (rst) begin
      ex_v_q     <= '0;
      wb_v_q     <= '0;
      wb_dv_q    <= '0;
      wb_cmp_q   <= '0;
      bw_v_q     <= 1'b0;
      bht_we_q   <= 1'b0;
      csr_v_q    <= 1'b0;
      mwk_v_q    <= '0;
      tf_v_q     <= '0;
      bc_v_q     <= '0;
      a1_block_q <= 1'b0;
      div_wait_q <= '0;
      fpi_wait_q <= '0;
      lfsr_q     <= 8'h5a;
    end else begin
      for (int q = 0; q < N_XQ; q++) ex_v_q[q] <= iss_valid[q] && !sc && !fk(iss_pl[q].tid);
      for (int i = 0; i < N_ALU; i++) begin
        wb_v_q[i]   <= ex_lv[i] && alu_class(i, ex_pl_q[i].cls) && !fk(ex_pl_q[i].tid);
        wb_dv_q[i]  <= ex_lv[i] && alu_class(i, ex_pl_q[i].cls) && ex_pl_q[i].dst_en && !fk(ex_pl_q[i].tid);
        wb_cmp_q[i] <= ex_lv[i] && alu_class(i, ex_pl_q[i].cls) && !fk(ex_pl_q[i].tid);
      end
      bw_v_q   <= ex_br && !fk(bp.tid);
      bht_we_q <= ex_br && bp.br_kind == BR_COND && !fk(bp.tid);
      csr_v_q  <= ex_csr && !fk(p1.tid);
      mwk_v_q  <= sc ? {mwk_v_q[1] && !fk(mwk_t_q[1]), 2'b00}
                     : {mwk_v_q[1] && !fk(mwk_t_q[1]), mwk_v_q[0] && !fk(mwk_t_q[0]),
                        rf_mul && iss_pl[1].dst_en && !fk(iss_pl[1].tid)};
      tf_v_q   <= {tf_v_q[0] && !fk(tf_t_q[0]),
                   !csr_v_q && mul_ov && mul_tag[TAG_W-1] && !fk(mul_tid)};   // the MUL write slot
      bc_v_q   <= {bc_v_q[1] && !fk(bc_t_q[1]), bc_v_q[0] && !fk(bc_t_q[0]), ex_mul && p1.bcnt && !fk(p1.tid)};
      // A MUL in RF or a divide claim takes slot +4: block A1's select next cycle
      a1_block_q <= (rf_mul && !fk(iss_pl[1].tid)) || div_claim || fpi_claim;
      if (fk(div_tid))             div_wait_q <= '0;
      else if (div_claim)          div_wait_q <= 3'd4;
      else if (div_wait_q != '0)   div_wait_q <= div_wait_q - 1'b1;
      if (fk(fpi_tid))             fpi_wait_q <= '0;
      else if (fpi_claim)          fpi_wait_q <= 3'd4;
      else if (fpi_wait_q != '0)   fpi_wait_q <= fpi_wait_q - 1'b1;
    end
    mwk_t_q <= {mwk_t_q[1:0], iss_pl[1].tid};
    tf_t_q  <= {tf_t_q[0], mul_tid};
    bc_t_q  <= {bc_t_q[0], p1.tid};
  end

  logic unused;
  assign unused = ^{wb_v_q, bw_taken_q, div_cnt, mul_tag[COL_W-1:WTAG_W], csr_ex_pl, opb[Q_LD], mul_res,
                    opb[Q_STA], f_eq, f_lt, f_ltu, bp};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      assert ($onehot0({csr_v_q, mul_ov, div_ov && div_ordy, fpi_wr}))
        else $error("tg_exec: two bank-1 results in one slot");
      assert (!(oth_we && wb_dv_q[1])) else $error("tg_exec: bank 1 write conflict");
      // (M7's step 5c: hart 1's homes take bank 1's port during the reset sequence, with nothing else on it)
      if (HART1_ON && init_we) assert (!wb_dv_q[1] && !oth_we) else $error("tg_exec: bank 1 written during the reset sequence");
    end
  end
`endif
endmodule
