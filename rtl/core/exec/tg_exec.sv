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
  // DR-133: the ALU operand ports read UltraRAM copies of the register file (gated: 0 until
  // cycle identity, 200 MHz next to a URAM column and a full-chip placement check pass)
`ifdef TG_IRF_URAM
  parameter bit  IRF_URAM = 1'b1,
`else
  parameter bit  IRF_URAM = 1'b0,
`endif
  localparam int NAP   = IRF_URAM ? 0 : 2 * N_ALU,   // ALU operand ports in tg_irf
  localparam int NRP   = NAP + 3 + COMMIT_WIDTH,
  localparam int P_LD  = NAP,
  localparam int P_STA = NAP + 1,
  localparam int P_SH  = NAP + 2,
  localparam int P_TR  = NAP + 3,
  localparam int NSRC  = 2 * (N_ALU + 1) + 2,
  localparam int SW    = idx_w(NSRC),
  localparam int S_RF  = 0,
  localparam int S_EX  = 1,               // + i: ALU i's res_q; + N_ALU: load result
  localparam int S_WB  = N_ALU + 2,       // + i: ALU i's wbq_q; + N_ALU: load result copy
  localparam int S_IMM = NSRC - 1,
  localparam int TAG_W = PIDX_W + ROBW + COL_W + 1   // {dst_en, dst index, rob, wakeup column}
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         flush,
  input  logic                         misa_c,      // C: jump targets need only 2-byte alignment
  // Reset sequence: zero writes into bank 0
  input  logic                         init_we,
  input  logic [PIDX_W-1:0]            init_idx,
  // Issue (RF stage)
  input  logic [N_XQ-1:0]              iss_valid,
  input  iq_pl_t [N_XQ-1:0]            iss_pl,
  // IS (tg_issue, DR-133): the source tags of the row each ALU queue grants now (RF's a cycle
  // later), the URAM read address with IRF_URAM; unconnected until the core wires them
  input  preg_t [N_ALU-1:0]            is_src1 = '0,
  input  preg_t [N_ALU-1:0]            is_src2 = '0,
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
  // Wakeups (W set at the end of this cycle) and LLT results written
  output logic [NCOL-1:0]              wake_reg,
  output logic [LLT_ENTRIES-1:0]       llt_done,
  output logic [IQ_TAGS-1:0]           tag_free,       // MUL tags, 2 cycles after the write
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
  logic [N_ALU-1:0][1:0][63:0] alu_rd;   // the ALU operands' register values in RF
  if (!IRF_URAM) begin : g_rda
    for (genvar i = 0; i < N_ALU; i++) begin : g_a
      assign rd_bank[2*i]   = preg_bank(iss_pl[i].src1);
      assign rd_idx[2*i]    = preg_idx(iss_pl[i].src1);
      assign rd_bank[2*i+1] = preg_bank(iss_pl[i].src2);
      assign rd_idx[2*i+1]  = preg_idx(iss_pl[i].src2);
      assign alu_rd[i][0]   = rd_data[2*i];
      assign alu_rd[i][1]   = rd_data[2*i+1];
    end
    logic unused_isd;
    assign unused_isd = ^{is_src1, is_src2};
  end else begin : g_uram
    // UltraRAM copies, one per bank and ALU operand port, written like the banks and read with
    // the source tags of IS (is_src1/is_src2), so the data arrives in RF as tg_irf's does. The URAM
    // read is read-first, so a write in the cycle before RF is taken from that write's
    // registers instead (the LUTRAM banks show it to an RF read).
    logic [INT_BANKS-1:0]             pw_we_q;
    logic [INT_BANKS-1:0][PIDX_W-1:0] pw_wa_q;
    logic [INT_BANKS-1:0][63:0]       pw_wd_q;
    always_ff @(posedge clk) begin
      pw_we_q <= rf_we;
      pw_wa_q <= rf_wa;
      pw_wd_q <= rf_wd;
    end
    for (genvar i = 0; i < N_ALU; i++) begin : g_a
      for (genvar o = 0; o < 2; o++) begin : g_o
        logic [INT_BANKS-1:0][63:0] urd;
        for (genvar b = 0; b < INT_BANKS; b++) begin : g_b
          tg_ram_sdp #(.DEPTH(INT_PREGS_PER_BANK), .WIDTH(64), .PRIM("ultra")) u_ur (
            .clk, .we(rf_we[b]), .waddr(rf_wa[b]), .wdata(rf_wd[b]),
            .re(1'b1), .raddr(preg_idx(o ? is_src2[i] : is_src1[i])), .rdata(urd[b]));
        end
        // One encoded select per bit: the source's bank, or that bank's write of the cycle before
        // (picked once per port), so a bit is a 4:1 (with three banks) after a 3:1.
        preg_t t;
        assign t = o ? iss_pl[i].src2 : iss_pl[i].src1;
        logic [BANK_W-1:0] tb;
        logic [63:0]       pw;      // the source bank's write of the cycle before
        logic              hit;
        always_comb begin
          tb  = preg_bank(t);
          pw  = pw_wd_q[0];
          hit = 1'b0;
          for (int b = 0; b < INT_BANKS; b++) begin
            if (tb == BANK_W'(b)) begin
              pw  = pw_wd_q[b];
              hit = pw_we_q[b] && pw_wa_q[b] == preg_idx(t);
            end
          end
          alu_rd[i][o] = urd[0];
          if (hit) alu_rd[i][o] = pw;
          else begin
            for (int b = 1; b < INT_BANKS; b++) if (tb == BANK_W'(b)) alu_rd[i][o] = urd[b];
          end
        end
      end
    end
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

  logic [N_XQ-1:0][SW-1:0] sa, sb;
  logic [N_XQ-1:0][63:0]   ra, rb;
  for (genvar q = 0; q < N_XQ; q++) begin : g_sel
    always_comb begin
      sa[q] = bsel(iss_pl[q].src1, ex_v_q, ex_pl_q, wb_dv_q, wb_dst_q, ld_m2_will, ld_m2_dst,
                   ld_res_valid, ld_res_dst);
      sb[q] = iss_pl[q].b_imm ? SW'(S_IMM)
            : bsel(iss_pl[q].src2, ex_v_q, ex_pl_q, wb_dv_q, wb_dst_q, ld_m2_will, ld_m2_dst,
                   ld_res_valid, ld_res_dst);
      if (q < N_ALU) begin
        ra[q] = alu_rd[(q < N_ALU) ? q : 0][0];   // (the index stays in range where q >= N_ALU)
        rb[q] = alu_rd[(q < N_ALU) ? q : 0][1];
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

  logic [N_XQ-1:0][63:0] opa, opb;
  for (genvar q = 0; q < N_XQ; q++) begin : g_op
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
    tg_alu #(.MINMAX(1'b0)) u_alu (.ctl(ex_pl_q[i].alu), .a(opa[i]), .b(opb[i]), .res(alu_res[i]),
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
    bt_target = (bp.br_kind == BR_JALR) ? ((opa[0] + {{52{bp.jalr_off[11]}}, bp.jalr_off}) & ~64'd1)
                                        : bp.br_target;
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
  assign p1_tag = {p1.dst_en, preg_idx(p1.dst), p1.rob, p1.wid};
  logic              mul_ov;
  logic [63:0]       mul_res;              // unused: the bank 1 write multiplexer selects from
  logic [127:0]      mul_prod;             // the product itself (one LUT level less)
  logic              mul_hi, mul_word;
  logic [TAG_W-1:0]  mul_tag;
  tg_mul #(.TAG_W(TAG_W)) u_mul (
    .clk, .rst, .flush, .in_valid(ex_mul), .in_op(p1.mul_op), .in_word(p1.word && !p1.bcnt), .in_a(opa[1]),
    .in_b(opb[1]), .in_tag(p1_tag), .out_valid(mul_ov), .out_res(mul_res), .out_tag(mul_tag),
    .out_prod(mul_prod), .out_hi(mul_hi), .out_word(mul_word));

  // clz, ctz, cpop and min/max (Zbb) ride the MUL slot: their operands and ALU1's compare flag
  // are registered at the end of EX and the result is computed in the next cycle, then delayed to
  // the MUL's write cycle (spike S3: min/max out of the 1-cycle ALU loop, tg_alu MINMAX = 0; the
  // count needs no bypass, so it may start a cycle late: this takes the load bypass, the count
  // and the flag out of one cycle)
  // - clz and ctz share one leading-zero count, ctz(x) = clz(x bit-reversed). The W forms put ones
  //   beside the low word (below it for clz, above it for ctz), so the count stops at 32.
  // - min/max take ALU1's compare flags (its adder subtracts for them: sub is set in RF, below).
  logic [63:0]       bc_res;
  logic [2:0]        bc_v_q;
  logic [2:1][63:0]  bc_q;
  logic [63:0]       bca_q, bcb_q;             // the operands, registered at the end of EX
  mul_op_e           bcop_q;
  logic              bcw_q, bclt_q, bcmax_q;
  always_comb begin
    logic [63:0] x, y, w;
    int n;
    x = bcw_q ? {32'b0, bca_q[31:0]} : bca_q;
    w = bcw_q ? {32'hFFFF_FFFF, bca_q[31:0]} : bca_q;
    y = bcw_q ? {bca_q[31:0], 32'hFFFF_FFFF} : bca_q;
    if (bcop_q == MUL_H) for (int i = 0; i < 64; i++) y[i] = w[63 - i];      // ctz
    n = 64;
    for (int i = 0; i < 64; i++) if (y[i]) n = 63 - i;                       // clz, ctz
    if (bcop_q == MUL_HSU) begin                                             // cpop
      n = 0;
      for (int i = 0; i < 64; i++) n += int'(x[i]);
    end
    bc_res = 64'(n);
    if (bcop_q == MUL_HU) bc_res = (bclt_q ^ bcmax_q) ? bca_q : bcb_q;       // MIN(U), MAX(U)
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
  logic       fpi_claim;                   // the FP->int result at P4's queue head claims slot +4
  logic [2:0] fpi_wait_q;
  logic       fpi_wr;                      // the claimed head is written this cycle
  assign fpi_claim = EXT_FD && fpi_valid && !fpi_kill && fpi_wait_q == '0 && !rf_mul && !div_claim &&
                     !flush;
  assign fpi_wr    = fpi_wait_q == 3'd1 && !flush;
  assign fpi_ready = fpi_wr || (EXT_FD && fpi_valid && fpi_kill && fpi_wait_q == '0);
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
  // MUL tags return 2 cycles after the result's register write (rename's RN can no longer see
  // it unwritten; tg_issue clears the tag's column)
  logic [1:0]                    tf_v_q;
  logic [1:0][WTAG_W-1:0]        tf_id_q;
  always_comb begin
    tag_free = '0;
    if (tf_v_q[1]) tag_free[tf_id_q[1]] = 1'b1;
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
    if (div_wait_q == 3'd2 && div_tag[TAG_W-1]) wake_reg[div_tag[COL_W-1:0]] = 1'b1;  // its LLT
    if (fpi_wait_q == 3'd2 && fpi_dst_en && !flush) wake_reg[llt_col(int'(fpi_llt))] = 1'b1;
    llt_done = '0;
    if (div_ov && div_ordy && div_tag[TAG_W-1])
      llt_done[LLT_IDX_W'(int'(div_tag[COL_W-1:0]) - IQ_TAGS)] = 1'b1;
    if (fpi_wr && fpi_dst_en) llt_done[fpi_llt] = 1'b1;
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
    // min/max on P1's 2-cycle path read ALU1's compare flags, so its adder subtracts for them
    if (iss_pl[1].cls == C_MUL && iss_pl[1].bcnt && iss_pl[1].mul_op == MUL_HU)
      ex_pl_q[1].alu.sub <= 1'b1;
    ex_sa_q <= sa;
    ex_sb_q <= sb;
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

    if (rst || flush) begin
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
      tf_v_q   <= {tf_v_q[0], !csr_v_q && mul_ov && mul_tag[TAG_W-1]};   // the MUL write slot
      bc_v_q   <= {bc_v_q[1:0], ex_mul && p1.bcnt};
      // A MUL in RF or a divide claim takes slot +4: block A1's select next cycle
      a1_block_q <= rf_mul || div_claim || fpi_claim;
      if (div_claim)               div_wait_q <= 3'd4;
      else if (div_wait_q != '0)   div_wait_q <= div_wait_q - 1'b1;
      if (fpi_claim)               fpi_wait_q <= 3'd4;
      else if (fpi_wait_q != '0)   fpi_wait_q <= fpi_wait_q - 1'b1;
    end
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
    end
  end
`endif
endmodule
