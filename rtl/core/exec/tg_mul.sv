// Pipelined RV64 integer multiplier (core-pipeline.md §7.2, port P1): MUL, MULH, MULHSU,
// MULHU and MULW. One request per cycle, no back-pressure, fixed latency 3: a request with
// in_valid in cycle c has out_valid, out_res and out_tag in cycle c+3, from a register.
//   M1 (c+1): operands, extended to 65 bits (a signed for MULH/MULHSU, b for MULH), so one
//             signed multiply covers every op.
//   M2 (c+2): the product's low 128 bits.
//   M3 (c+3): the high or low half, or MULW's low word sign-extended: the output register.
//             out_prod, out_hi and out_word give the same result unselected (the M3 register
//             holds the whole product), so a user with a write multiplexer of its own can fold
//             the select into it (tg_exec: one LUT level less; fpga_friendly.md T7).
// The single 65x65 multiply keeps simulation fast. Synthesis maps it onto DSP48E2 tiles and
// their cascade, absorbing M1 and M2 into the tiles' pipeline registers (AREG/BREG, then
// MREG/PREG); a hand-partitioned tile array can replace it if timing needs one.
// flush kills every request in flight, including one presented in the flush cycle: their
// out_valid never rises. A result already in M3 is still presented in the flush cycle.
// Valid bits reset; data registers do not (they load only with their valid bit).
module tg_mul
  import tg_pkg::*, tg_core_pkg::*;
#(parameter int TAG_W = 8)
(
  input  logic             clk,
  input  logic             rst,
  input  logic             flush,      // kills every request in flight (their out_valid never rises)
  input  logic             in_valid,
  input  mul_op_e          in_op,
  input  logic             in_word,    // MULW: only with MUL_LO; 32-bit product of the low words, sign-extended
  input  logic [63:0]      in_a,
  input  logic [63:0]      in_b,
  input  logic [TAG_W-1:0] in_tag,
  output logic             out_valid,
  output logic [63:0]      out_res,
  output logic [TAG_W-1:0] out_tag,
  output logic [127:0]     out_prod,   // the product's low 128 bits; out_res is
  output logic             out_hi,     //   out_word ? sext(out_prod[31:0]) : out_hi ? out_prod[127:64]
  output logic             out_word    //   : out_prod[63:0]
);
  logic                v1_q, v2_q, v3_q;
  logic signed [64:0]  a1_q, b1_q;
  logic                hi1_q, hi2_q, word1_q, word2_q;
  logic [TAG_W-1:0]    tag1_q, tag2_q, tag3_q;
  logic [127:0]        prod2_q, prod3_q;
  logic [63:0]         res3_q;
  logic                hi3_q, word3_q;

  always_ff @(posedge clk) begin
    if (rst) {v1_q, v2_q, v3_q} <= '0;
    else     {v1_q, v2_q, v3_q} <= {in_valid, v1_q, v2_q} & {3{!flush}};
  end

  // The low 128 bits of the 130-bit signed product: a signed extension to 128 bits keeps them
  // exact, and every result is in them. MUL and MULW use bits 63:0, the high forms 127:64.
  logic [127:0] prod;
  assign prod = 128'(a1_q) * 128'(b1_q);

  always_ff @(posedge clk) begin
    if (in_valid) begin
      a1_q    <= {(in_op == MUL_H || in_op == MUL_HSU) && in_a[63], in_a};
      b1_q    <= {in_op == MUL_H && in_b[63], in_b};
      hi1_q   <= in_op != MUL_LO;
      word1_q <= in_word;
      tag1_q  <= in_tag;
    end
    if (v1_q) begin
      prod2_q <= prod;
      hi2_q   <= hi1_q;
      word2_q <= word1_q;
      tag2_q  <= tag1_q;
    end
    if (v2_q) begin
      if (word2_q)    res3_q <= {{32{prod2_q[31]}}, prod2_q[31:0]};
      else if (hi2_q) res3_q <= prod2_q[127:64];
      else            res3_q <= prod2_q[63:0];
      tag3_q  <= tag2_q;
      prod3_q <= prod2_q;
      hi3_q   <= hi2_q;
      word3_q <= word2_q;
    end
  end

  assign out_valid = v3_q;
  assign out_res   = res3_q;
  assign out_tag   = tag3_q;
  assign out_prod  = prod3_q;
  assign out_hi    = hi3_q;
  assign out_word  = word3_q;

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && in_valid) assert (!in_word || in_op == MUL_LO) else $error("tg_mul: W form of a MULH op");
  end
`endif
endmodule
