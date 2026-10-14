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
  localparam int TAG_W = PIDX_W + ROBW + LLT_IDX_W + 1   // {dst_en, dst index, rob, llt}
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         flush,
  input  logic                         misa_c,      // C: jump targets need only 2-byte alignment
  // Reset sequence: zero writes into bank 0
  input  logic                         init_we,
  input  logic [PIDX_W-1:0]            init_idx,
  // Issue (RF stage)
  input  logic [N_IQ-1:0]              iss_valid,
  input  iq_pl_t [N_IQ-1:0]            iss_pl,
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
  // Wakeups (W set at the end of this cycle) and LLT results written
  output logic [NCOL-1:0]              wake_reg,
  output logic [LLT_ENTRIES-1:0]       llt_done,
  output logic                         div_done,
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
  tg_irf #(.NB(INT_BANKS), .DEPTH(INT_PREGS_PER_BANK), .NR(NRP)) u_irf (
    .clk, .we(rf_we), .waddr(rf_wa), .wdata(rf_wd), .rbank(rd_bank), .ridx(rd_idx),
    .rdata(rd_data));

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
  assign rd_bank[P_SH]  = preg_bank(sd_tag);
  assign rd_idx[P_SH]   = preg_idx(sd_tag);
  assign sd_data        = rd_data[P_SH];
  for (genvar j = 0; j < COMMIT_WIDTH; j++) begin : g_tr
    assign rd_bank[P_TR+j] = preg_bank(tr_tag[j]);
    assign rd_idx[P_TR+j]  = preg_idx(tr_tag[j]);
    assign tr_data[j]      = rd_data[P_TR+j];
  end

  // ---- Pipeline state per port (ALU ports, then LD and STA) ----
  logic [N_IQ-1:0]              ex_v_q;
  iq_pl_t [N_IQ-1:0]            ex_pl_q;
  logic [N_IQ-1:0][63:0]        ex_a_q, ex_b_q;      // register-file values
  logic [N_IQ-1:0][SW-1:0]      ex_sa_q, ex_sb_q;    // operand selects
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
  function automatic logic [SW-1:0] bsel(input preg_t t, input logic [N_IQ-1:0] exv,
                                         input iq_pl_t [N_IQ-1:0] expl, input logic [N_ALU-1:0] wbdv,
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

  logic [N_IQ-1:0][SW-1:0] sa, sb;
  logic [N_IQ-1:0][63:0]   ra, rb;
  for (genvar q = 0; q < N_IQ; q++) begin : g_sel
    always_comb begin
      sa[q] = bsel(iss_pl[q].src1, ex_v_q, ex_pl_q, wb_dv_q, wb_dst_q, ld_m2_will, ld_m2_dst,
                   ld_res_valid, ld_res_dst);
      sb[q] = iss_pl[q].b_imm ? SW'(S_IMM)
            : bsel(iss_pl[q].src2, ex_v_q, ex_pl_q, wb_dv_q, wb_dst_q, ld_m2_will, ld_m2_dst,
                   ld_res_valid, ld_res_dst);
      if (q < N_ALU) begin
        ra[q] = rd_data[2*q];
        rb[q] = rd_data[2*q+1];
      end else if (q == Q_LD) begin
        ra[q] = rd_data[P_LD];
        rb[q] = '0;
      end else begin
        ra[q] = rd_data[P_STA];
        rb[q] = '0;
      end
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

  logic [N_IQ-1:0][63:0] opa, opb;
  for (genvar q = 0; q < N_IQ; q++) begin : g_op
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
    end
  end

  // ---- ALUs ----
  logic [N_ALU-1:0][63:0] alu_res;
  logic [N_ALU-1:0]       f_eq, f_lt, f_ltu;
  for (genvar i = 0; i < N_ALU; i++) begin : g_alu
    tg_alu u_alu (.ctl(ex_pl_q[i].alu), .a(opa[i]), .b(opb[i]), .res(alu_res[i]),
                  .eq(f_eq[i]), .lt(f_lt[i]), .ltu(f_ltu[i]));
  end

  // ---- Branch unit (P0, EX) ----
  iq_pl_t      bp;
  logic        bt_taken;
  logic [63:0] bt_target, bt_npc, bt_seq;
  assign bp = ex_pl_q[0];
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
    bt_target = (bp.br_kind == BR_JALR) ? ((opa[0] + {{52{bp.jalr_off[11]}}, bp.jalr_off}) & ~64'd1)
                                        : bp.br_target;
    bt_seq = bp.pc + (bp.rvc ? 64'd2 : 64'd4);
    bt_npc = bt_taken ? bt_target : bt_seq;
  end
  logic ex_br;
  assign ex_br = ex_v_q[0] && bp.cls == C_BR;

  // Direction counters (read in EX, written in WB)
  localparam int BHT_W = idx_w(BHT_ENTRIES);
  logic [0:0][BHT_W-1:0] bht_ra;
  logic [0:0][1:0]       bht_rd;
  logic                  bht_we_q;
  logic [BHT_W-1:0]      bht_wa_q;
  logic [1:0]            bht_wd_q;
  assign bht_ra[0] = bp.pc[2 +: BHT_W];
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
  assign ex_mul = ex_v_q[1] && p1.cls == C_MUL;
  assign ex_div = ex_v_q[1] && p1.cls == C_DIV;
  assign ex_csr = ex_v_q[1] && p1.cls == C_CSR;
  assign csr_ex_valid = ex_csr;
  assign csr_ex_pl    = p1;
  assign csr_ex_src   = opa[1];

  logic [TAG_W-1:0] p1_tag;
  assign p1_tag = {p1.dst_en, preg_idx(p1.dst), p1.rob, p1.llt};
  logic              mul_ov;
  logic [63:0]       mul_res;
  logic [TAG_W-1:0]  mul_tag;
  tg_mul #(.TAG_W(TAG_W)) u_mul (
    .clk, .rst, .flush, .in_valid(ex_mul), .in_op(p1.mul_op), .in_word(p1.word && !p1.bcnt), .in_a(opa[1]),
    .in_b(opb[1]), .in_tag(p1_tag), .out_valid(mul_ov), .out_res(mul_res), .out_tag(mul_tag));

  // clz, ctz, cpop (Zbb) ride the MUL slot: computed in EX, delayed to the MUL's write cycle
  logic [63:0]       bc_res;
  logic [2:0]        bc_v_q;
  logic [2:0][63:0]  bc_q;
  always_comb begin
    logic [63:0] x;
    int n;
    x = p1.word ? {32'b0, opa[1][31:0]} : opa[1];
    n = 0;
    unique case (p1.mul_op)
      MUL_LO: begin                                  // clz
        n = p1.word ? 32 : 64;
        for (int i = 0; i < 64; i++) if (x[i] && (!p1.word || i < 32)) n = (p1.word ? 31 : 63) - i;
      end
      MUL_H: begin                                   // ctz
        n = p1.word ? 32 : 64;
        for (int i = 63; i >= 0; i--) if (x[i]) n = i;
      end
      default: for (int i = 0; i < 64; i++) n += int'(x[i]);   // cpop
    endcase
    bc_res = 64'(n);
  end

  logic              div_ov, div_ordy;
  logic [63:0]       div_res;
  logic [TAG_W-1:0]  div_tag;
  logic [idx_w(DIV_INFLIGHT + 1)-1:0] div_cnt;
  tg_div #(.TAG_W(TAG_W), .DEPTH(DIV_INFLIGHT)) u_div (
    .clk, .rst, .flush, .in_valid(ex_div), .in_op(p1.div_op), .in_word(p1.word), .in_a(opa[1]),
    .in_b(opb[1]), .in_tag(p1_tag), .out_valid(div_ov), .out_ready(div_ordy), .out_res(div_res),
    .out_tag(div_tag), .count(div_cnt));

  // Bank 1 write slots
  logic       a1_block_q;
  logic       rf_mul;                      // a MUL in RF claims slot +4
  assign rf_mul = iss_valid[1] && iss_pl[1].cls == C_MUL;
  logic       div_claim;                   // the finished divide claims slot +4
  logic [2:0] div_wait_q;                  // cycles to its slot (0: none)
  assign div_claim = div_ov && div_wait_q == '0 && !rf_mul && !flush;
  assign a1_block  = a1_block_q;
  assign div_ordy  = div_wait_q == 3'd1;
  assign div_done  = div_ov && div_ordy;

  // CSR result, registered at the end of EX (written at s+3, like an ALU result)
  logic        csr_v_q, csr_ill_q, csr_dv_q;
  logic [PIDX_W-1:0] csr_dst_q;
  robid_t      csr_rob_q;
  logic [63:0] csr_res_q, csr_tval_q;

  // MUL wakeup delay line: RF (r) -> W set at the end of r + 3
  logic [2:0]       mwk_v_q;
  wid_t [2:0]       mwk_id_q;

  // ---- Bank 1 write mux and completions ----
  logic        oth_we;
  logic [PIDX_W-1:0] oth_wa;
  logic [63:0] oth_wd;
  always_comb begin
    oth_we = 1'b0; oth_wa = '0; oth_wd = '0;
    oth_valid = 1'b0; oth_rob = '0; oth_exc = 1'b0; oth_tval = '0;
    if (csr_v_q) begin
      oth_valid = 1'b1; oth_rob = csr_rob_q; oth_exc = csr_ill_q; oth_tval = csr_tval_q;
      oth_we = csr_dv_q && !csr_ill_q; oth_wa = csr_dst_q; oth_wd = csr_res_q;
    end else if (mul_ov) begin
      oth_valid = 1'b1; oth_rob = mul_tag[LLT_IDX_W +: ROBW];
      oth_we = mul_tag[TAG_W-1]; oth_wa = mul_tag[LLT_IDX_W + ROBW +: PIDX_W];
      oth_wd = bc_v_q[2] ? bc_q[2] : mul_res;
    end else if (div_ov && div_ordy) begin
      oth_valid = 1'b1; oth_rob = div_tag[LLT_IDX_W +: ROBW];
      oth_we = div_tag[TAG_W-1]; oth_wa = div_tag[LLT_IDX_W + ROBW +: PIDX_W]; oth_wd = div_res;
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
    if (oth_we) begin
      rf_we[1] = 1'b1;
      rf_wa[1] = oth_wa;
      rf_wd[1] = oth_wd;
    end
    if (init_we) begin
      rf_we[0] = 1'b1;
      rf_wa[0] = init_idx;
      rf_wd[0] = '0;
    end
    rf_we[LD_BANK] = ld_res_valid;
    rf_wa[LD_BANK] = ld_res_dst;
    rf_wd[LD_BANK] = ld_res_data;
  end
  assign rf_we_o   = rf_we;
  assign rf_widx_o = rf_wa;

  // Wakeups: MUL delay line; a claimed divide one cycle before its write
  always_comb begin
    wake_reg = '0;
    if (mwk_v_q[2]) wake_reg[mwk_id_q[2]] = 1'b1;
    if (div_wait_q == 3'd2 && div_tag[TAG_W-1])
      wake_reg[ROB_ENTRIES + int'(div_tag[LLT_IDX_W-1:0])] = 1'b1;
    llt_done = '0;
    if (div_ov && div_ordy && div_tag[TAG_W-1]) llt_done[div_tag[LLT_IDX_W-1:0]] = 1'b1;
  end

  // ---- Address generation (EX) ----
  assign ld_ag_valid  = ex_v_q[Q_LD];
  assign ld_ag_pl     = ex_pl_q[Q_LD];
  assign ld_ag_addr   = opa[Q_LD] + ex_pl_q[Q_LD].imm;
  assign sta_ag_valid = ex_v_q[Q_STA];
  assign sta_ag_pl    = ex_pl_q[Q_STA];
  assign sta_ag_addr  = opa[Q_STA] + ex_pl_q[Q_STA].imm;

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    // RF -> EX
    ex_pl_q <= iss_pl;
    ex_sa_q <= sa;
    ex_sb_q <= sb;
    for (int q = 0; q < N_IQ; q++) begin
      ex_a_q[q] <= ra[q];
      ex_b_q[q] <= rb[q];
    end
    // EX -> WB
    for (int i = 0; i < N_ALU; i++) begin
      res_q[i]    <= alu_res[i];
      wb_dst_q[i] <= preg_idx(ex_pl_q[i].dst);
      wb_rob_q[i] <= ex_pl_q[i].rob;
    end
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
    bw_misp_q   <= bt_npc != bp.pred_npc;
    bw_strong_q <= bp.br_kind != BR_COND || ctr_new[1];
    bw_hit_q    <= bp.ubtb_hit;
    bw_way_q    <= bp.ubtb_way;
    bw_dfix_q   <= bp.dfix;
    bht_wa_q    <= bp.pc[2 +: BHT_W];
    bht_wd_q    <= ctr_new;
    // CSR
    csr_dst_q  <= preg_idx(p1.dst);
    csr_rob_q  <= p1.rob;
    csr_res_q  <= csr_ex_rdata;
    csr_tval_q <= {32'b0, p1.insn};
    csr_ill_q  <= csr_ex_ill;
    csr_dv_q   <= p1.dst_en;
    // Bit counts alongside the MUL pipeline
    bc_q <= {bc_q[1:0], bc_res};
    // MUL wakeup ids
    mwk_id_q[0] <= iss_pl[1].wid;
    mwk_id_q[1] <= mwk_id_q[0];
    mwk_id_q[2] <= mwk_id_q[1];
    lfsr_q <= {lfsr_q[6:0], lfsr_q[7] ^ lfsr_q[5] ^ lfsr_q[4] ^ lfsr_q[3]};

    if (rst || flush) begin
      ex_v_q     <= '0;
      wb_v_q     <= '0;
      wb_dv_q    <= '0;
      wb_cmp_q   <= '0;
      bw_v_q     <= 1'b0;
      bht_we_q   <= 1'b0;
      csr_v_q    <= 1'b0;
      mwk_v_q    <= '0;
      bc_v_q     <= '0;
      a1_block_q <= 1'b0;
      div_wait_q <= '0;
      if (rst) lfsr_q <= 8'h5a;
    end else begin
      ex_v_q <= iss_valid;
      for (int i = 0; i < N_ALU; i++) begin
        wb_v_q[i]   <= ex_v_q[i] && alu_class(i, ex_pl_q[i].cls);
        wb_dv_q[i]  <= ex_v_q[i] && alu_class(i, ex_pl_q[i].cls) && ex_pl_q[i].dst_en;
        wb_cmp_q[i] <= ex_v_q[i] && alu_class(i, ex_pl_q[i].cls);
      end
      bw_v_q   <= ex_br;
      bht_we_q <= ex_br && bp.br_kind == BR_COND;
      csr_v_q  <= ex_csr;
      mwk_v_q  <= {mwk_v_q[1:0], rf_mul && iss_pl[1].dst_en};
      bc_v_q   <= {bc_v_q[1:0], ex_mul && p1.bcnt};
      // A MUL in RF or a divide claim takes slot +4: block A1's select next cycle
      a1_block_q <= rf_mul || div_claim;
      if (div_claim)               div_wait_q <= 3'd4;
      else if (div_wait_q != '0)   div_wait_q <= div_wait_q - 1'b1;
    end
  end

  logic unused;
  assign unused = ^{wb_v_q, bw_taken_q, div_cnt, mul_tag[LLT_IDX_W-1:0], csr_ex_pl, opb[Q_LD],
                    opb[Q_STA], f_eq, f_lt, f_ltu, bp};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      assert ($onehot0({csr_v_q, mul_ov, div_ov && div_ordy}))
        else $error("tg_exec: two bank-1 results in one slot");
      assert (!(oth_we && wb_dv_q[1])) else $error("tg_exec: bank 1 write conflict");
    end
  end
`endif
endmodule
