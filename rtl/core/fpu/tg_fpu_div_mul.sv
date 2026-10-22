// 60 x 60-bit unsigned multiplier of the divide/sqrt unit (docs/spec/fpu.md, "Area"): twelve
// DSP48E2 tiles (x in 26 + 26 + 8 bits on the 27-bit port, y in 17 + 17 + 17 + 9 bits on the
// 18-bit port). Operands are registered at the end of the cycle they are presented in (c0, the
// DSP input registers); the full 120-bit product is registered at the end of c3.
//   c1: every tile multiplies into its M register
//   c2: each x chunk's four tiles add along the DSP cascade, each the previous one's sum shifted
//       right by 17 (Z = PCIN >> 17): x_i * y in one chain, whose low 17 bits a stage leave it
//   c3: the three chains' sums are added: one ternary adder
// (The area pass, lever 9: the chains run the whole of y, where c2 summed pairs before, so c3 has
// one fabric adder where it had three.)
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
  (* use_dsp = "yes" *) logic [42:0] m_q [3][4];
  always_ff @(posedge clk) begin
    for (int i = 0; i < 3; i++)
      for (int j = 0; j < 4; j++)
        m_q[i][j] <= 43'(xr[i]) * 43'(yr[j]);
  end

  // c2: the chains (x_i * y = s3 : s2[16:0] : s1[16:0] : s0[16:0])
  logic [42:0] s0 [3], s1 [3], s2 [3];
  logic [43:0] s3 [3];
  logic [85:0] r_q [3];
  always_comb begin
    for (int i = 0; i < 3; i++) begin
      s0[i] = m_q[i][0];
      s1[i] = m_q[i][1] + 43'(s0[i][42:17]);
      s2[i] = m_q[i][2] + 43'(s1[i][42:17]);
      s3[i] = 44'(m_q[i][3]) + 44'(s2[i][42:17]);
    end
  end
  always_ff @(posedge clk) begin
    for (int i = 0; i < 3; i++) r_q[i] <= {s3[i][34:0], s2[i][16:0], s1[i][16:0], s0[i][16:0]};
  end

  // c3
  always_ff @(posedge clk) begin
    p <= 120'(r_q[0]) + (120'(r_q[1]) << 26) + (120'(r_q[2]) << 52);
  end
endmodule
