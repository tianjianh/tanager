// A 64-bit counter in two DSP48E2 slices (FPGA-friendly T6, plan §8.5 R1): q counts up by inc
// each cycle, loads d, or clears, with no fabric register, adder or multiplexer.
//   q(t+1) = rst(t) ? 0 : ld(t-1) ? d(t) + inc(t) : q(t) + inc(t)
// A load takes effect a cycle late: ld at t switches the slices' registered OPMODE, so in cycle
// t+1 q still counts, and from t+2 it reads d + the increments since t+1, as a counter loaded at
// t would. The caller keeps d stable in cycle t+1 and does not read q then (tg_csr: a counter
// write retires a serialising CSR instruction, so cycle t+1 is its flush, asserted there).
// The OPMODE register keeps ld (the commit decision, late in the cycle) off the slices' ALU path.
// The low slice holds q[47:0] and adds inc on A:B to P, or to C (= d) in the load cycle. The high
// slice holds q[63:48] (its upper bits are not read) and adds this cycle's carry out of bit 47,
// computed in the fabric from registered values: when counting, q[47:IW] is all ones (the low
// slice's pattern detector, registered with P) and q[IW-1:0] + inc >= 2^IW; when loading, the
// same of d. rst clears both P registers; the OPMODE registers are not reset (they take count
// mode in any cycle with ld low, so during reset).
// Mapping: SYNTHESIS, or TG_SIM_PRIMS with the vendor's simulation model (tests/unit/csr_ctr on
// Icarus); otherwise a behavioural model.
module tg_dsp_ctr #(
  parameter int IW = 2               // inc width: inc < 2^IW
) (
  input  logic          clk,
  input  logic          rst,
  input  logic          ld,          // load d one cycle later (above)
  input  logic [63:0]   d,
  input  logic [IW-1:0] inc,
  output logic [63:0]   q
);
  if (IW < 1 || IW > 17) begin : g_bad_params
    $error("tg_dsp_ctr: needs 1 <= IW <= 17");
  end

  logic ld_q;                         // the slices' OPMODE registers hold load mode
  always_ff @(posedge clk) ld_q <= ld;

`ifdef SYNTHESIS
  `define TG_DSP_CTR_PRIM
`elsif TG_SIM_PRIMS
  `define TG_DSP_CTR_PRIM
`endif
`ifdef TG_DSP_CTR_PRIM
  `undef TG_DSP_CTR_PRIM
  /* verilator lint_off UNUSEDSIGNAL */  // only P and the low slice's pattern detector are used
  logic [47:0] p_lo, p_hi;
  logic        pd_lo, pbd_lo, pd_hi, pbd_hi;
  logic [3:0]  co_lo, co_hi;
  logic [29:0] acout_lo, acout_hi;
  logic [17:0] bcout_lo, bcout_hi;
  logic [47:0] pcout_lo, pcout_hi;
  logic [7:0]  xor_lo, xor_hi;
  logic        ccout_lo, ccout_hi, ms_lo, ms_hi, ov_lo, ov_hi, un_lo, un_hi;
  /* verilator lint_on UNUSEDSIGNAL */
  // Carry out of bit 47 this cycle: of q + inc when counting, of d + inc in the load cycle
  logic [IW:0] csum, lsum;
  logic        carry;
  assign csum  = {1'b0, p_lo[IW-1:0]} + {1'b0, inc};
  assign lsum  = {1'b0, d[IW-1:0]} + {1'b0, inc};
  assign carry = ld_q ? (&d[47:IW] && lsum[IW]) : (pd_lo && csum[IW]);
  // OPMODE {W, Z, Y, X}, registered in the slices: Z = C (load) or P (count); X = A:B (low)
  logic [8:0] op_lo, op_hi;
  assign op_lo = ld ? 9'b00_011_00_11 : 9'b00_010_00_11;
  assign op_hi = ld ? 9'b00_011_00_00 : 9'b00_010_00_00;
  logic [47:0] inc_x;
  assign inc_x = 48'(inc);

  DSP48E2 #(
    .A_INPUT("DIRECT"), .B_INPUT("DIRECT"), .AMULTSEL("A"), .BMULTSEL("B"), .PREADDINSEL("A"),
    .USE_MULT("NONE"), .USE_SIMD("ONE48"), .USE_WIDEXOR("FALSE"), .XORSIMD("XOR24_48_96"),
    .USE_PATTERN_DETECT("PATDET"), .SEL_PATTERN("PATTERN"), .SEL_MASK("MASK"),
    .PATTERN(48'hFFFF_FFFF_FFFF), .MASK(48'((64'd1 << IW) - 1)), .RND(48'h0),
    .AUTORESET_PATDET("NO_RESET"), .AUTORESET_PRIORITY("RESET"),
    .AREG(0), .ACASCREG(0), .BREG(0), .BCASCREG(0), .CREG(0), .DREG(0), .ADREG(0), .MREG(0),
    .PREG(1), .INMODEREG(0), .OPMODEREG(1), .ALUMODEREG(0), .CARRYINREG(0), .CARRYINSELREG(0)
  ) u_lo (
    .ACOUT(acout_lo), .BCOUT(bcout_lo), .CARRYCASCOUT(ccout_lo), .MULTSIGNOUT(ms_lo),
    .PCOUT(pcout_lo), .OVERFLOW(ov_lo), .PATTERNBDETECT(pbd_lo), .PATTERNDETECT(pd_lo),
    .UNDERFLOW(un_lo), .CARRYOUT(co_lo), .P(p_lo), .XOROUT(xor_lo),
    .ACIN(30'h0), .BCIN(18'h0), .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0), .PCIN(48'h0),
    .ALUMODE(4'b0000), .CARRYINSEL(3'b000), .CLK(clk), .INMODE(5'b00000), .OPMODE(op_lo),
    .A(inc_x[47:18]), .B(inc_x[17:0]), .C(d[47:0]), .CARRYIN(1'b0), .D(27'h0),
    .CEA1(1'b0), .CEA2(1'b0), .CEAD(1'b0), .CEALUMODE(1'b0), .CEB1(1'b0), .CEB2(1'b0),
    .CEC(1'b0), .CECARRYIN(1'b0), .CECTRL(1'b1), .CED(1'b0), .CEINMODE(1'b0), .CEM(1'b0),
    .CEP(1'b1),
    .RSTA(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0), .RSTB(1'b0), .RSTC(1'b0),
    .RSTCTRL(1'b0), .RSTD(1'b0), .RSTINMODE(1'b0), .RSTM(1'b0), .RSTP(rst)
  );
  DSP48E2 #(
    .A_INPUT("DIRECT"), .B_INPUT("DIRECT"), .AMULTSEL("A"), .BMULTSEL("B"), .PREADDINSEL("A"),
    .USE_MULT("NONE"), .USE_SIMD("ONE48"), .USE_WIDEXOR("FALSE"), .XORSIMD("XOR24_48_96"),
    .USE_PATTERN_DETECT("NO_PATDET"), .SEL_PATTERN("PATTERN"), .SEL_MASK("MASK"),
    .PATTERN(48'h0), .MASK(48'h3FFF_FFFF_FFFF), .RND(48'h0),
    .AUTORESET_PATDET("NO_RESET"), .AUTORESET_PRIORITY("RESET"),
    .AREG(0), .ACASCREG(0), .BREG(0), .BCASCREG(0), .CREG(0), .DREG(0), .ADREG(0), .MREG(0),
    .PREG(1), .INMODEREG(0), .OPMODEREG(1), .ALUMODEREG(0), .CARRYINREG(0), .CARRYINSELREG(0)
  ) u_hi (
    .ACOUT(acout_hi), .BCOUT(bcout_hi), .CARRYCASCOUT(ccout_hi), .MULTSIGNOUT(ms_hi),
    .PCOUT(pcout_hi), .OVERFLOW(ov_hi), .PATTERNBDETECT(pbd_hi), .PATTERNDETECT(pd_hi),
    .UNDERFLOW(un_hi), .CARRYOUT(co_hi), .P(p_hi), .XOROUT(xor_hi),
    .ACIN(30'h0), .BCIN(18'h0), .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0), .PCIN(48'h0),
    .ALUMODE(4'b0000), .CARRYINSEL(3'b000), .CLK(clk), .INMODE(5'b00000), .OPMODE(op_hi),
    .A(30'h0), .B(18'h0), .C({32'h0, d[63:48]}), .CARRYIN(carry), .D(27'h0),
    .CEA1(1'b0), .CEA2(1'b0), .CEAD(1'b0), .CEALUMODE(1'b0), .CEB1(1'b0), .CEB2(1'b0),
    .CEC(1'b0), .CECARRYIN(1'b0), .CECTRL(1'b1), .CED(1'b0), .CEINMODE(1'b0), .CEM(1'b0),
    .CEP(1'b1),
    .RSTA(1'b0), .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0), .RSTB(1'b0), .RSTC(1'b0),
    .RSTCTRL(1'b0), .RSTD(1'b0), .RSTINMODE(1'b0), .RSTM(1'b0), .RSTP(rst)
  );
  assign q = {p_hi[15:0], p_lo};
`else
  // Behavioural model (simulation)
  logic [63:0] q_q;
  always_ff @(posedge clk) begin
    if (rst)       q_q <= '0;
    else if (ld_q) q_q <= d + 64'(inc);
    else           q_q <= q_q + 64'(inc);
  end
  assign q = q_q;
`endif
endmodule
