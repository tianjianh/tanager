// FMA normalisation (docs/spec/fpu.md, "FMA unit", E3): leading-zero count of x | marker (the
// marker limits the count at emin) and the left shift x << lz, keeping only the top K bits plus
// a sticky. The shift runs in four radix-4 stages; each stage keeps just the bits that can still
// reach the top K and ORs the rest into the sticky, so no wide OR follows the last stage. The
// count is tg_fpu_lzc's radix-4 tree, whose bits come out in the order the stages use them.
module tg_fpu_fma_norm #(
  parameter int W = 165,
  parameter int K = 55
) (
  input  logic [W-1:0]  x,
  input  logic [W-1:0]  marker,
  output logic [7:0]    lz,
  output logic [K-1:0]  n,
  output logic          st
);
  localparam int W1 = K + 63;   // kept after the shift by lz[7:6] * 64
  localparam int W2 = K + 15;   // after lz[5:4] * 16
  localparam int W3 = K + 3;    // after lz[3:2] * 4

  tg_fpu_lzc #(.W(W), .R4(1'b1)) u_lzc (.x(x | marker), .cnt(lz));

  logic [W-1:0]  s1;
  logic [W1-1:0] s2;
  logic [W2-1:0] s3;
  logic [W3-1:0] s4;
  logic [K-1:0]  s5;
  logic          st1, st2, st3, st4;
  always_comb begin
    s1  = x << {lz[7:6], 6'b0};
    st1 = |s1[W-W1-1:0];
    s2  = s1[W-1 -: W1] << {lz[5:4], 4'b0};
    st2 = |s2[W1-W2-1:0];
    s3  = s2[W1-1 -: W2] << {lz[3:2], 2'b0};
    st3 = |s3[W2-W3-1:0];
    s4  = s3[W2-1 -: W3] << lz[1:0];
    st4 = |s4[W3-K-1:0];
    s5  = s4[W3-1 -: K];
  end
  assign n  = s5;
  assign st = st1 || st2 || st3 || st4;
endmodule
