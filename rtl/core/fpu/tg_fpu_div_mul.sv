// 60 x 60-bit unsigned multiplier of the divide/sqrt unit (docs/spec/fpu.md, "Area"): twelve
// DSP48E2 tiles (x in 26 + 26 + 8 bits on the 27-bit port, y in 17 + 17 + 17 + 9 bits on the
// 18-bit port). Operands are registered at the end of the cycle they are presented in (c0, the
// DSP input registers); the full 120-bit product is registered at the end of c3.
//   c1: tiles of y chunks 0 and 2 multiply into their P registers; chunks 1 and 3 into M
//   c2: chunks 1 and 3 add the neighbouring tile shifted right by 17 (the DSP cascade pattern)
//   c3: the six pair sums are added: two ternary adders and one binary adder
module tg_fpu_div_mul (
  input  logic          clk,
  input  logic [59:0]   x,
  input  logic [59:0]   y,
  output logic [119:0]  p
);
  logic [25:0] xr [3];
  logic [16:0] yr [4];
  always_ff @(posedge clk) begin
    xr[0] <= x[25:0];
    xr[1] <= x[51:26];
    xr[2] <= {18'b0, x[59:52]};
    yr[0] <= y[16:0];
    yr[1] <= y[33:17];
    yr[2] <= y[50:34];
    yr[3] <= {8'b0, y[59:51]};
  end

  // c1 (use_dsp: Vivado would build the smallest tile, 8 x 9 bits, in LUTs)
  logic [42:0] p0_q [3], p2_q [3];     // tiles (i, 0) and (i, 2): A x B into P
  (* use_dsp = "yes" *) logic [42:0] m1_q [3], m3_q [3];   // tiles (i, 1) and (i, 3): A x B into M
  always_ff @(posedge clk) begin
    for (int i = 0; i < 3; i++) begin
      p0_q[i] <= 43'(xr[i]) * 43'(yr[0]);
      p2_q[i] <= 43'(xr[i]) * 43'(yr[2]);
      m1_q[i] <= 43'(xr[i]) * 43'(yr[1]);
      m3_q[i] <= 43'(xr[i]) * 43'(yr[3]);
    end
  end

  // c2: pair sums x_i * y[33:0] and x_i * y[59:34]
  logic [59:0] lo_q [3];
  logic [51:0] hi_q [3];
  always_ff @(posedge clk) begin
    for (int i = 0; i < 3; i++) begin
      lo_q[i][59:17] <= m1_q[i] + 43'(p0_q[i][42:17]);
      lo_q[i][16:0]  <= p0_q[i][16:0];
      hi_q[i][51:17] <= 35'(m3_q[i] + 43'(p2_q[i][42:17]));
      hi_q[i][16:0]  <= p2_q[i][16:0];
    end
  end

  // c3
  logic [93:0] glo;      // x * y[33:0]
  logic [85:0] ghi;      // x * y[59:34]
  assign glo = 94'(lo_q[0]) + (94'(lo_q[1]) << 26) + (94'(lo_q[2]) << 52);
  assign ghi = 86'(hi_q[0]) + (86'(hi_q[1]) << 26) + (86'(hi_q[2]) << 52);
  always_ff @(posedge clk) begin
    p <= 120'(glo) + (120'(ghi) << 34);
  end
endmodule
