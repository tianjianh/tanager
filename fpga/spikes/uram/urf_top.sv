// Tier A of spikes.md §8.14: tg_urf (the double-pumped UltraRAM integer register file) alone in the
// XCK26, with the RF stage around it as tg_exec has it, for its timing at 100 MHz with a 200 MHz
// UltraRAM clock. Measurement only.
// - Clocks: tg_clkgen's MMCM (VCO 1200 MHz) with a 200 MHz output beside the 100 MHz core clock.
// - Stand-ins, all registers loaded from LFSRs every cycle: sel_q for the issue select's output (the
//   early ports' next banks and indices), late_q for the store-data tag (the late port), wr_q for the
//   three banks' write ports, byp_q for the LD and STA bases' write-back-level sources and selects.
// - The RF stage: ALU operands (ports 0-3) go straight into ex_q; the LD and STA bases (ports 4, 5)
//   through tg_exec's rbs select (the register value, ALU 0's or 1's result, or the load result);
//   the late port into sd_q, the LSU's store-data capture.
// - LATE_BYP: the late port's capture takes the LD and STA bases' select too (the register value, ALU 0's
//   or 1's result, or the load result: one more LUT level), as an operand read at mid-cycle would.
// - PROBE: one more URAM288 with port B's output register on, read every cycle into a clk2x register,
//   for the output register's clock-to-out.
// All of it folds into one output, so nothing is trimmed.
module urf_top #(
  parameter bit PROBE    = 1'b1,
  parameter bit LATE_BYP = 1'b0
) (
  input  logic clk_in,     // 100 MHz
  output logic dout
);
  localparam int NB = 3, NE = 6, NL = 1, NR = NE + NL, IW = 6, BW = 2, W = 64;

  logic fb, c0, c2x, clk, clk2x;
  MMCME4_BASE #(
    .BANDWIDTH        ("OPTIMIZED"),
    .CLKIN1_PERIOD    (10.0),
    .DIVCLK_DIVIDE    (1),
    .CLKFBOUT_MULT_F  (12.0),
    .CLKOUT0_DIVIDE_F (12.0),
    .CLKOUT2_DIVIDE   (6),
    .STARTUP_WAIT     ("FALSE")
  ) u_mmcm (
    .CLKIN1 (clk_in), .CLKFBIN (fb), .CLKFBOUT (fb), .CLKFBOUTB (),
    .CLKOUT0 (c0), .CLKOUT0B (), .CLKOUT1 (), .CLKOUT1B (), .CLKOUT2 (c2x), .CLKOUT2B (),
    .CLKOUT3 (), .CLKOUT3B (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (),
    .LOCKED (), .PWRDWN (1'b0), .RST (1'b0)
  );
  BUFG u_bufg_core (.I (c0),  .O (clk));
  BUFG u_bufg_2x   (.I (c2x), .O (clk2x));

  // ---- random sources: eight 64-bit LFSRs ----
  logic [7:0][63:0] lf_q;
  initial for (int i = 0; i < 8; i++) lf_q[i] = 64'h9e37_79b9_7f4a_7c15 ^ (64'(i) << 17) ^ 64'(i + 1);
  always_ff @(posedge clk)
    for (int i = 0; i < 8; i++) lf_q[i] <= {lf_q[i][62:0], lf_q[i][63] ^ lf_q[i][62] ^ lf_q[i][60] ^ lf_q[i][59]};

  // ---- stand-ins ----
  logic [NE-1:0][BW-1:0]  sel_bank_q;
  logic [NE-1:0][IW-1:0]  sel_idx_q;
  logic [NL-1:0]          late_en_q;
  logic [NL-1:0][BW-1:0]  late_bank_q;
  logic [NL-1:0][IW-1:0]  late_idx_q;
  logic [NB-1:0]          wr_we_q;
  logic [NB-1:0][IW-1:0]  wr_a_q;
  logic [NB-1:0][W-1:0]   wr_d_q;
  logic [1:0][1:0]        byp_s_q;
  logic [2:0][W-1:0]      byp_d_q;     // ALU 0's and 1's results, the load result
  logic [IW-1:0]          prb_a_q;
  logic [W-1:0]           prb_d_q;
  always_ff @(posedge clk) begin
    for (int p = 0; p < NE; p++) begin
      sel_bank_q[p] <= (lf_q[0][8*p +: 2] == 2'd3) ? 2'd0 : lf_q[0][8*p +: 2];
      sel_idx_q[p]  <= lf_q[0][8*p + 2 +: 6];
    end
    late_en_q   <= '1;
    late_bank_q <= (lf_q[1][1:0] == 2'd3) ? 2'd1 : lf_q[1][1:0];
    late_idx_q  <= lf_q[1][7:2];
    for (int b = 0; b < NB; b++) begin
      wr_we_q[b] <= lf_q[1][8 + b];
      wr_a_q[b]  <= lf_q[1][16 + 6*b +: 6];
      wr_d_q[b]  <= lf_q[2 + b];
    end
    byp_s_q    <= lf_q[1][47:44];
    byp_d_q[0] <= lf_q[5];
    byp_d_q[1] <= lf_q[6];
    byp_d_q[2] <= lf_q[7];
    prb_a_q    <= lf_q[1][55:50];
    prb_d_q    <= lf_q[7] ^ lf_q[6];
  end

  // ---- the register file ----
  logic [NR-1:0][W-1:0] rdata;
  tg_urf #(.NB (NB), .DEPTH (64), .W (W), .NE (NE), .NL (NL)) u_urf (
    .clk, .clk2x, .we (wr_we_q), .waddr (wr_a_q), .wdata (wr_d_q),
    .e_bank_n (sel_bank_q), .e_idx_n (sel_idx_q),
    .l_en (late_en_q), .l_bank (late_bank_q), .l_idx (late_idx_q), .rdata);

  // ---- the RF stage ----
  logic [NE-1:0][W-1:0] ex_q;
  logic [W-1:0]         sd_q;
  always_ff @(posedge clk) begin
    for (int p = 0; p < 4; p++) ex_q[p] <= rdata[p];
    for (int k = 0; k < 2; k++)
      unique case (byp_s_q[k])
        2'd0:    ex_q[4 + k] <= rdata[4 + k];
        2'd1:    ex_q[4 + k] <= byp_d_q[0];
        2'd2:    ex_q[4 + k] <= byp_d_q[1];
        default: ex_q[4 + k] <= byp_d_q[2];
      endcase
    if (LATE_BYP)
      unique case (byp_s_q[0])
        2'd0:    sd_q <= rdata[NE];
        2'd1:    sd_q <= byp_d_q[0];
        2'd2:    sd_q <= byp_d_q[1];
        default: sd_q <= byp_d_q[2];
      endcase
    else sd_q <= rdata[NE];
  end

  // ---- the output register's probe ----
  logic [W-1:0] prb_q;
  if (PROBE) begin : g_probe
    logic [71:0] pd;
    (* dont_touch = "true" *)
    URAM288_BASE #(
      .IREG_PRE_A ("FALSE"), .IREG_PRE_B ("FALSE"), .OREG_A ("FALSE"), .OREG_B ("TRUE"),
      .OREG_ECC_A ("FALSE"), .OREG_ECC_B ("FALSE"), .EN_ECC_RD_A ("FALSE"), .EN_ECC_RD_B ("FALSE"),
      .EN_ECC_WR_A ("FALSE"), .EN_ECC_WR_B ("FALSE"), .EN_AUTO_SLEEP_MODE ("FALSE")
    ) u_probe (
      .CLK (clk2x),
      .ADDR_A (23'(prb_a_q)), .EN_A (1'b1), .RDB_WR_A (1'b1), .BWE_A (9'h1ff), .DIN_A (72'(prb_d_q)),
      .ADDR_B (23'(prb_a_q ^ 6'h15)), .EN_B (1'b1), .RDB_WR_B (1'b0), .BWE_B (9'h000), .DIN_B (72'h0),
      .DOUT_A (), .DOUT_B (pd),
      .OREG_CE_A (1'b1), .OREG_CE_B (1'b1), .OREG_ECC_CE_A (1'b0), .OREG_ECC_CE_B (1'b0),
      .RST_A (1'b0), .RST_B (1'b0), .SLEEP (1'b0),
      .INJECT_SBITERR_A (1'b0), .INJECT_DBITERR_A (1'b0), .INJECT_SBITERR_B (1'b0), .INJECT_DBITERR_B (1'b0),
      .SBITERR_A (), .DBITERR_A (), .SBITERR_B (), .DBITERR_B ()
    );
    always_ff @(posedge clk2x) prb_q <= pd[W-1:0];
  end else begin : g_noprobe
    assign prb_q = '0;
  end

  // ---- one output ----
  logic dout_q;
  always_ff @(posedge clk) dout_q <= ^{ex_q, sd_q, prb_q};
  assign dout = dout_q;
endmodule
