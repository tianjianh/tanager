// Equality and magnitude comparator in one DSP48E2 (docs/perf/fpga_friendly.md T6), for
// operands that a pipeline register already holds, so the compare costs no LUTs or carry
// chain.
//
//   eq = (a == b), lt = (a < b), signed when SIGNED, both LAT cycles after a and b.
//   LAT = 1: a and b come from fabric registers; the DSP's P register holds the result
//            (the same timing as a fabric comparator followed by a result register).
//   LAT = 2: the DSP's A, B and C registers hold the operands as well: pass the values the
//            pipeline would register (its register's D input), and the compare result comes
//            one cycle after that register stage. ce holds those input registers (a stall).
// Operands: W <= 48. lt is the sign of the 48-bit difference for W <= 47, and the ALU's
// carry out for W = 48 unsigned; for W = 48 signed it is undefined (use W <= 47).
//
// Mapping (SYNTHESIS, or TG_SIM_PRIMS with the primitive's simulation model): the DSP
// computes P = C - A:B with C = a and A:B = b, both extended to 48 bits; the pattern
// detector flags P == 0 (PATTERN 0, MASK 0), registered with P; lt is P[47]. No multiplier:
// USE_MULT "NONE", OPMODE W=0, Z=C, Y=0, X=A:B, ALUMODE 0011 (Z - (W + X + Y + CIN)).
module tg_dsp_cmp #(
  parameter int W      = 32,
  parameter bit SIGNED = 1'b0,
  parameter int LAT    = 1
) (
  input  logic         clk,
  input  logic         ce,      // LAT = 2: enables the operand registers; LAT = 1: unused
  input  logic [W-1:0] a,
  input  logic [W-1:0] b,
  output logic         eq,
  output logic         lt
);
  if (W < 1 || W > 48 || (LAT != 1 && LAT != 2)) begin : g_bad_params
    $error("tg_dsp_cmp: needs 1 <= W <= 48 and LAT 1 or 2");
  end

  // Operands extended to the DSP's 48 bits (zero or sign); lt needs a spare bit (W <= 47).
  logic [47:0] ax, bx;
  if (W == 48) begin : g_w48
    assign ax = a;
    assign bx = b;
  end else if (SIGNED) begin : g_sx
    assign ax = {{(48 - W){a[W-1]}}, a};
    assign bx = {{(48 - W){b[W-1]}}, b};
  end else begin : g_zx
    assign ax = {{(48 - W){1'b0}}, a};
    assign bx = {{(48 - W){1'b0}}, b};
  end

`ifdef SYNTHESIS
  `define TG_DSP_CMP_PRIM
`elsif TG_SIM_PRIMS
  `define TG_DSP_CMP_PRIM
`endif
`ifdef TG_DSP_CMP_PRIM
  `undef TG_DSP_CMP_PRIM
  localparam int IREG = LAT - 1;   // A, B and C registers
  /* verilator lint_off UNUSEDSIGNAL */  // only P[47] and the pattern detector are used
  logic [47:0] p;
  logic        patdet;
  logic        patbdet;
  logic [3:0]  co;
  logic [29:0] acout;
  logic [17:0] bcout;
  logic [47:0] pcout;
  logic [7:0]  xorout;
  logic        ccout, msout, ovf, unf;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        cei;
  assign cei = (LAT == 2) ? ce : 1'b1;

  DSP48E2 #(
    .A_INPUT("DIRECT"), .B_INPUT("DIRECT"),
    .AMULTSEL("A"), .BMULTSEL("B"), .PREADDINSEL("A"),
    .USE_MULT("NONE"), .USE_SIMD("ONE48"), .USE_WIDEXOR("FALSE"), .XORSIMD("XOR24_48_96"),
    .USE_PATTERN_DETECT("PATDET"), .SEL_PATTERN("PATTERN"), .SEL_MASK("MASK"),
    .PATTERN(48'h0), .MASK(48'h0), .RND(48'h0),
    .AUTORESET_PATDET("NO_RESET"), .AUTORESET_PRIORITY("RESET"),
    .AREG(IREG), .ACASCREG(IREG), .BREG(IREG), .BCASCREG(IREG), .CREG(IREG),
    .DREG(0), .ADREG(0), .MREG(0), .PREG(1),
    .INMODEREG(0), .OPMODEREG(0), .ALUMODEREG(0), .CARRYINREG(0), .CARRYINSELREG(0)
  ) u_dsp (
    .ACOUT(acout), .BCOUT(bcout), .CARRYCASCOUT(ccout), .MULTSIGNOUT(msout), .PCOUT(pcout),
    .OVERFLOW(ovf), .PATTERNBDETECT(patbdet), .PATTERNDETECT(patdet), .UNDERFLOW(unf),
    .CARRYOUT(co), .P(p), .XOROUT(xorout),
    .ACIN(30'h0), .BCIN(18'h0), .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0), .PCIN(48'h0),
    .ALUMODE(4'b0011), .CARRYINSEL(3'b000), .CLK(clk), .INMODE(5'b00000),
    .OPMODE(9'b00_011_00_11),
    .A(bx[47:18]), .B(bx[17:0]), .C(ax), .CARRYIN(1'b0), .D(27'h0),
    .CEA1(cei), .CEA2(cei), .CEAD(1'b0), .CEALUMODE(1'b0), .CEB1(cei), .CEB2(cei),
    .CEC(cei), .CECARRYIN(1'b0), .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0), .CEM(1'b0),
    .CEP(1'b1),
    .RSTA(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0), .RSTB(1'b0), .RSTC(1'b0),
    .RSTCTRL(1'b0), .RSTD(1'b0), .RSTINMODE(1'b0), .RSTM(1'b0), .RSTP(1'b0)
  );
  assign eq = patdet;
  // W <= 47: the sign of the 48-bit difference. W = 48 unsigned: the subtraction's carry
  // out, which is set when there is no borrow (a >= b), so lt is its complement.
  if (W == 48 && !SIGNED) begin : g_lt_co
    assign lt = !co[3];
  end else begin : g_lt_sign
    assign lt = p[47];
  end
`else
  // Behavioural model (simulation).
  logic [47:0] ai, bi;
  if (LAT == 2) begin : g_ireg
    always_ff @(posedge clk) begin
      if (ce) begin
        ai <= ax;
        bi <= bx;
      end
    end
  end else begin : g_noireg
    assign ai = ax;
    assign bi = bx;
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_ce;
    assign unused_ce = ce;   // LAT = 1 has no operand registers to enable
    /* verilator lint_on UNUSEDSIGNAL */
  end
  logic [47:0] diff;
  assign diff = ai - bi;
  always_ff @(posedge clk) begin
    eq <= diff == '0;
    lt <= (W == 48 && !SIGNED) ? ai < bi : diff[47];
  end
`endif
endmodule
