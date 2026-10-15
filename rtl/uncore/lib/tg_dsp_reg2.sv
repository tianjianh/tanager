// A W-bit register that loads one of two inputs, in DSP48E2 slices (docs/perf/fpga_friendly.md §4,
// "DSP48E2 as a registered multiplexer"; DR-136):
//
//   if (en) q <= sel_c ? c : a;
//
// It replaces a fabric register with a 2:1 select and a clock enable, which costs about one LUT
// per two bits; the DSPs cost none. Per 48 bits one DSP: OPMODE selects X = A:B (a) or Z = C (c),
// the others 0, ALUMODE adds, so P is the selected input; CEP is en; P is the register. No input
// registers (AREG = BREG = CREG = 0), so the timing is a fabric register's: the inputs arrive in
// the cycle q loads them. en goes to the clock enable, the late signal's short path; sel_c to
// OPMODE, which wants an early one (a register).
//
// Mapping under SYNTHESIS, or TG_SIM_PRIMS with the vendor's DSP48E2 model (tests/unit/dsp_reg);
// otherwise a behavioural model, as tg_dsp_cmp does. Like a fabric data register, q has no reset.
module tg_dsp_reg2 #(
  parameter int W = 48
) (
  input  logic         clk,
  input  logic         en,
  input  logic         sel_c,
  input  logic [W-1:0] a,
  input  logic [W-1:0] c,
  output logic [W-1:0] q
);
  if (W < 1) begin : g_bad_params
    $error("tg_dsp_reg2: needs W >= 1");
  end

`ifdef SYNTHESIS
  `define TG_DSP_REG2_PRIM
`elsif TG_SIM_PRIMS
  `define TG_DSP_REG2_PRIM
`endif
`ifdef TG_DSP_REG2_PRIM
  `undef TG_DSP_REG2_PRIM
  localparam int N = (W + 47) / 48;
  // X = A:B (OPMODE[1:0] = 11) or Z = C (OPMODE[6:4] = 011); W = Y = 0
  wire [8:0] opmode = sel_c ? 9'b00_011_00_00 : 9'b00_000_00_11;
  for (genvar i = 0; i < N; i++) begin : g_dsp
    localparam int LO = i * 48;
    localparam int HI = (LO + 48 > W) ? W : LO + 48;
    logic [47:0] ax, cx, px;
    assign ax = 48'(a[HI-1:LO]);
    assign cx = 48'(c[HI-1:LO]);
    DSP48E2 #(
      .AMULTSEL ("A"), .A_INPUT ("DIRECT"), .BMULTSEL ("B"), .B_INPUT ("DIRECT"), .PREADDINSEL ("A"),
      .USE_MULT ("NONE"), .USE_SIMD ("ONE48"), .USE_PATTERN_DETECT ("NO_PATDET"),
      .AREG (0), .BREG (0), .CREG (0), .DREG (0), .ADREG (0), .MREG (0), .PREG (1),
      .ACASCREG (0), .BCASCREG (0), .ALUMODEREG (0), .CARRYINREG (0), .CARRYINSELREG (0),
      .INMODEREG (0), .OPMODEREG (0)
    ) u_dsp (
      .CLK (clk),
      .A (ax[47:18]), .B (ax[17:0]), .C (cx), .D (27'd0),
      .OPMODE (opmode), .ALUMODE (4'b0000), .INMODE (5'b00000), .CARRYINSEL (3'b000), .CARRYIN (1'b0),
      .CEA1 (1'b0), .CEA2 (1'b0), .CEB1 (1'b0), .CEB2 (1'b0), .CEC (1'b0), .CED (1'b0), .CEAD (1'b0),
      .CEM (1'b0), .CEP (en), .CECTRL (1'b0), .CEINMODE (1'b0), .CEALUMODE (1'b0), .CECARRYIN (1'b0),
      .RSTA (1'b0), .RSTB (1'b0), .RSTC (1'b0), .RSTD (1'b0), .RSTM (1'b0), .RSTP (1'b0),
      .RSTCTRL (1'b0), .RSTINMODE (1'b0), .RSTALUMODE (1'b0), .RSTALLCARRYIN (1'b0),
      .ACIN (30'd0), .BCIN (18'd0), .PCIN (48'd0), .CARRYCASCIN (1'b0), .MULTSIGNIN (1'b0),
      .P (px), .ACOUT (), .BCOUT (), .PCOUT (), .CARRYCASCOUT (), .MULTSIGNOUT (), .CARRYOUT (),
      .OVERFLOW (), .UNDERFLOW (), .PATTERNDETECT (), .PATTERNBDETECT (), .XOROUT ()
    );
    assign q[HI-1:LO] = px[HI-LO-1:0];
  end
`else
  always_ff @(posedge clk) if (en) q <= sel_c ? c : a;
`endif
endmodule
