// Spike S3: the writer-sharded integer register file, the bypass network and the
// ALU -> bypass -> ALU loop (plan §4.7, §4.8, §8.1), with registered inputs and outputs.
//
// Ports. N_ALU ALU ports (two operands each), the load and store-address ports (a base
// operand each, bypassed like ALU operands) and the shared read port (store data, FP's
// integer source; no bypass). Banks: B0..B(N_ALU-1) written by the ALUs (B1 also takes the
// MUL/DIV/CSR/FP-to-int results through a write mux), B(N_ALU) by the load pipe.
// Logical read ports: 2 per ALU, LD, STA, SH = 2 * N_ALU + 3.
//
// Pipeline: RF (read, bank mux, rf_q) -> EX (operand mux, ALU, res_q) -> WB.
//   BYPASS = 0: full bypass from EX and WB (operand mux of 2 * (N_ALU + 1) + 2 sources:
//               RF, ALU EX results, load result, their WB copies, immediate/PC); the
//               register file is written at the end of WB from the result registers.
//   BYPASS = 1: lever R8, EX-only bypass with write-through: the register file is written
//               at the end of EX straight from the ALU, so the WB level disappears
//               (N_ALU + 3 sources).
//   RF3    = 0: every bank has all logical read ports (with 3 ALUs: 9, "replication").
//   RF3    = 1: lever R11, read-port sharing: banks keep 7 ports; ALU2's operands use the
//               STA and SH physical ports when its arbitration bit (set at select) is on.
//   SEL_OH = 0: binary operand selects (8:1 and 16:1 muxes map to LUT6 + MUXF7/F8);
//            1: one-hot AND-OR selects.
// Operand selects and controls are computed before EX (RF stage) and arrive registered.
module tg_s3_top
  import tg_pkg::*;
  import tg_alu_pkg::*;
#(
  parameter int BYPASS = 0,
  parameter int RF3    = 0,
  parameter int SEL_OH = 0,
  localparam int NB    = INT_BANKS,
  localparam int IW    = idx_w(INT_PREGS_PER_BANK),
  localparam int BW    = idx_w(NB),
  localparam int NLOG  = 2 * N_ALU + 3,                  // logical read ports
  localparam int P_LD  = 2 * N_ALU,
  localparam int P_STA = 2 * N_ALU + 1,
  localparam int P_SH  = 2 * N_ALU + 2,
  localparam bit SHARE = (RF3 == 1) && (N_ALU == 3),
  localparam int NPHYS = SHARE ? 7 : NLOG,               // physical read ports per bank
  localparam int NSRC  = (BYPASS == 1) ? N_ALU + 3 : 2 * (N_ALU + 1) + 2,
  localparam int SW    = (SEL_OH != 0) ? NSRC : idx_w(NSRC),
  localparam int CTL_W = $bits(alu_ctl_t)
) (
  input  logic                         clk,
  input  logic                         rst_i,
  // Issue (IS -> RF register): per logical read port a {bank, index} tag
  input  logic [NLOG-1:0][BW-1:0]      rbank_i,
  input  logic [NLOG-1:0][IW-1:0]      ridx_i,
  input  logic                         a2_share_i,       // RF3 = 1: ALU2 owns STA/SH ports
  input  logic [N_ALU-1:0]             alu_valid_i,
  input  logic [N_ALU-1:0][CTL_W-1:0]  alu_ctl_i,
  input  logic [N_ALU-1:0][IW-1:0]     alu_dest_i,       // index in the port's own bank
  input  logic [N_ALU-1:0][63:0]       alu_imm_i,        // immediate (operand b) or PC (a)
  input  logic [N_ALU-1:0][1:0][SW-1:0] alu_sel_i,       // operand selects
  input  logic [1:0][SW-1:0]           base_sel_i,       // LD, STA base operand selects
  // Load pipe result (M2 output) and the B1 write mux's other sources
  input  logic                         ld_valid_i,
  input  logic [IW-1:0]                ld_dest_i,
  input  logic [63:0]                  ld_data_i,
  input  logic                         oth_valid_i,
  input  logic [IW-1:0]                oth_dest_i,
  input  logic [63:0]                  oth_data_i,
  // Results
  output logic [N_ALU-1:0][63:0]       alu_res_o,
  output logic [N_ALU-1:0][2:0]        alu_flags_o,      // eq, lt, ltu
  output logic [1:0][63:0]             base_o,           // LD, STA base operands
  output logic [63:0]                  sd_o              // shared port: store data
);
  localparam int S_RF  = 0;
  localparam int S_EX  = 1;            // S_EX + i: ALU i EX result; S_EX + N_ALU: load
  localparam int S_WB  = N_ALU + 2;    // BYPASS = 0: S_WB + i: WB copies; + N_ALU: load
  localparam int S_IMM = NSRC - 1;

  // ---- IS -> RF registers ----
  logic                         rst;
  logic [NLOG-1:0][BW-1:0]      rbank_q;
  logic [NLOG-1:0][IW-1:0]      ridx_q;
  logic                         a2_share_q;
  logic [N_ALU-1:0]             rf_valid_q;
  alu_ctl_t [N_ALU-1:0]         rf_ctl_q;
  logic [N_ALU-1:0][IW-1:0]     rf_dest_q;
  logic [N_ALU-1:0][63:0]       rf_imm_q;
  logic [N_ALU-1:0][1:0][SW-1:0] rf_sel_q;
  logic [1:0][SW-1:0]           rf_bsel_q;
  logic                         ld_m2_valid_q, oth_valid_q;
  logic [IW-1:0]                ld_m2_dest_q, oth_dest_q;
  logic [63:0]                  ld_m2_data_q, oth_data_q;
  always_ff @(posedge clk) begin
    rst        <= rst_i;
    rbank_q    <= rbank_i;
    ridx_q     <= ridx_i;
    a2_share_q <= a2_share_i;
    rf_valid_q <= alu_valid_i;
    rf_ctl_q   <= alu_ctl_i;
    rf_dest_q  <= alu_dest_i;
    rf_imm_q   <= alu_imm_i;
    rf_sel_q   <= alu_sel_i;
    rf_bsel_q  <= base_sel_i;
    ld_m2_valid_q <= ld_valid_i;
    ld_m2_dest_q  <= ld_dest_i;
    ld_m2_data_q  <= ld_data_i;
    oth_valid_q <= oth_valid_i;
    oth_dest_q  <= oth_dest_i;
    oth_data_q  <= oth_data_i;
  end

  // ---- Register file ----
  logic [NPHYS-1:0][BW-1:0]   prbank;
  logic [NPHYS-1:0][IW-1:0]   pridx;
  logic [NPHYS-1:0][63:0]     prdata;
  logic [NLOG-1:0][63:0]      lrdata;
  if (SHARE) begin : g_share
    // Physical ports: A0a A0b A1a A1b LD STA/A2a SH/A2b
    for (genvar p = 0; p < 5; p++) begin : g_fixed
      assign prbank[p] = rbank_q[p];
      assign pridx[p]  = ridx_q[p];
    end
    assign prbank[5] = a2_share_q ? rbank_q[4] : rbank_q[P_STA];
    assign pridx[5]  = a2_share_q ? ridx_q[4]  : ridx_q[P_STA];
    assign prbank[6] = a2_share_q ? rbank_q[5] : rbank_q[P_SH];
    assign pridx[6]  = a2_share_q ? ridx_q[5]  : ridx_q[P_SH];
    for (genvar p = 0; p < 4; p++) begin : g_l
      assign lrdata[p] = prdata[p];
    end
    assign lrdata[4]     = prdata[5];   // ALU2 operand a
    assign lrdata[5]     = prdata[6];   // ALU2 operand b
    assign lrdata[P_LD]  = prdata[4];
    assign lrdata[P_STA] = prdata[5];
    assign lrdata[P_SH]  = prdata[6];
  end else begin : g_repl
    assign prbank = rbank_q;
    assign pridx  = ridx_q;
    assign lrdata = prdata;
    logic unused;
    assign unused = a2_share_q;   // read-port sharing only with 3 ALUs and RF3 = 1
  end

  logic [NB-1:0]          rf_we;
  logic [NB-1:0][IW-1:0]  rf_waddr;
  logic [NB-1:0][63:0]    rf_wdata;
  tg_irf #(.NB(NB), .DEPTH(INT_PREGS_PER_BANK), .NR(NPHYS)) u_irf (
    .clk, .we(rf_we), .waddr(rf_waddr), .wdata(rf_wdata), .rbank(prbank), .ridx(pridx),
    .rdata(prdata));

  // ---- RF -> EX registers ----
  logic [NLOG-1:0][63:0]        rf_q;
  logic [N_ALU-1:0]             ex_valid_q;
  alu_ctl_t [N_ALU-1:0]         ex_ctl_q;
  logic [N_ALU-1:0][IW-1:0]     ex_dest_q;
  logic [N_ALU-1:0][63:0]       ex_imm_q;
  logic [N_ALU-1:0][1:0][SW-1:0] ex_sel_q;
  logic [1:0][SW-1:0]           ex_bsel_q;
  always_ff @(posedge clk) begin
    rf_q      <= lrdata;
    ex_ctl_q  <= rf_ctl_q;
    ex_dest_q <= rf_dest_q;
    ex_imm_q  <= rf_imm_q;
    ex_sel_q  <= rf_sel_q;
    ex_bsel_q <= rf_bsel_q;
    if (rst) ex_valid_q <= '0;
    else     ex_valid_q <= rf_valid_q;
  end

  // ---- Bypass sources ----
  logic [N_ALU-1:0][63:0] res_q, wb_q, alu_res;
  logic [N_ALU-1:0][2:0]  flags;
  logic [N_ALU-1:0]       wb_valid_q;
  logic [N_ALU-1:0][IW-1:0] wb_dest_q;
  logic [63:0]            ld_q, ld_wb_q;
  logic [NSRC-1:0][63:0]  src_common;   // all sources but RF and IMM (filled per consumer)
  assign src_common[S_RF] = '0;
  assign src_common[S_IMM] = '0;
  for (genvar i = 0; i < N_ALU; i++) begin : g_src_ex
    assign src_common[S_EX + i] = res_q[i];
  end
  assign src_common[S_EX + N_ALU] = ld_q;
  if (BYPASS == 0) begin : g_src_wb
    for (genvar i = 0; i < N_ALU; i++) begin : g_i
      assign src_common[S_WB + i] = wb_q[i];
    end
    assign src_common[S_WB + N_ALU] = ld_wb_q;
  end

  function automatic logic [63:0] opmux(input logic [NSRC-1:0][63:0] s, input logic [SW-1:0] sel);
    logic [63:0] o;
    o = '0;
    if (SEL_OH != 0) begin
      for (int k = 0; k < NSRC; k++) if (sel[k]) o |= s[k];
    end else begin
      for (int k = 0; k < NSRC; k++) if (sel == SW'(k)) o = s[k];
    end
    return o;
  endfunction

  // ---- EX: operand muxes and ALUs ----
  for (genvar i = 0; i < N_ALU; i++) begin : g_alu
    logic [NSRC-1:0][63:0] sa, sb;
    logic [63:0] a, b;
    always_comb begin
      sa = src_common;
      sb = src_common;
      sa[S_RF]  = rf_q[2 * i];
      sb[S_RF]  = rf_q[2 * i + 1];
      sa[S_IMM] = ex_imm_q[i];        // PC
      sb[S_IMM] = ex_imm_q[i];        // immediate
    end
    assign a = opmux(sa, ex_sel_q[i][0]);
    assign b = opmux(sb, ex_sel_q[i][1]);
    tg_alu u_alu (.ctl(ex_ctl_q[i]), .a, .b, .res(alu_res[i]), .eq(flags[i][2]),
                  .lt(flags[i][1]), .ltu(flags[i][0]));
  end

  logic [1:0][63:0] base_q;
  for (genvar j = 0; j < 2; j++) begin : g_base
    logic [NSRC-1:0][63:0] s;
    always_comb begin
      s = src_common;
      s[S_RF]  = rf_q[P_LD + j];
      s[S_IMM] = '0;
    end
    always_ff @(posedge clk) base_q[j] <= opmux(s, ex_bsel_q[j]);
  end

  always_ff @(posedge clk) begin
    res_q   <= alu_res;
    ld_q    <= ld_m2_data_q;
    wb_q    <= res_q;
    ld_wb_q <= ld_q;
    wb_dest_q <= ex_dest_q;
    if (rst) wb_valid_q <= '0;
    else     wb_valid_q <= ex_valid_q;
  end

  // ---- Register-file writes ----
  // BYPASS = 0: from the result registers at the end of WB; BYPASS = 1: from the ALU
  // output at the end of EX (and from the M2 output for loads).
  logic ld_wb_valid_q;
  logic [IW-1:0] ld_wb_dest_q;
  always_ff @(posedge clk) begin
    ld_wb_dest_q <= ld_m2_dest_q;
    if (rst) ld_wb_valid_q <= 1'b0;
    else     ld_wb_valid_q <= ld_m2_valid_q;
  end
  always_comb begin
    for (int i = 0; i < N_ALU; i++) begin
      if (BYPASS == 1) begin
        rf_we[i]    = ex_valid_q[i];
        rf_waddr[i] = ex_dest_q[i];
        rf_wdata[i] = alu_res[i];
      end else begin
        rf_we[i]    = wb_valid_q[i];
        rf_waddr[i] = wb_dest_q[i];
        rf_wdata[i] = res_q[i];
      end
    end
    // B1 also takes MUL/DIV/CSR/FP-to-int results (the reservation register avoids clashes)
    if (oth_valid_q) begin
      rf_we[1]    = 1'b1;
      rf_waddr[1] = oth_dest_q;
      rf_wdata[1] = oth_data_q;
    end
    if (BYPASS == 1) begin
      rf_we[N_ALU]    = ld_m2_valid_q;
      rf_waddr[N_ALU] = ld_m2_dest_q;
      rf_wdata[N_ALU] = ld_m2_data_q;
    end else begin
      rf_we[N_ALU]    = ld_wb_valid_q;
      rf_waddr[N_ALU] = ld_wb_dest_q;
      rf_wdata[N_ALU] = ld_q;
    end
  end

  // ---- Outputs ----
  always_ff @(posedge clk) begin
    alu_res_o   <= res_q;
    alu_flags_o <= flags;
    base_o      <= base_q;
    sd_o        <= rf_q[P_SH];
  end

  if (BYPASS == 1) begin : g_unused
    logic unused;
    assign unused = ^{wb_q, ld_wb_q};   // no WB bypass level
  end
endmodule
