// AXI4 register slice (docs/spec/uncore-mem.md): a two-entry skid buffer on each of the five
// channels, so every signal between the two sides starts or ends at a flip-flop. One cycle each way.
// DSP: per channel (bit 0 AR, 1 AW, 2 W, 3 R, 4 B), the skid's main data register in DSP48E2s
// (tg_skid DSP; DR-136).
module tg_axi_slice
  import tg_uncore_pkg::*;
#(
  parameter logic [4:0] DSP = '0
) (
  input  logic    clk,
  input  logic    rst,
  input  axi_ax_t s_ar_i,  input  logic s_ar_valid_i, output logic s_ar_ready_o,
  output axi_r_t  s_r_o,   output logic s_r_valid_o,  input  logic s_r_ready_i,
  input  axi_ax_t s_aw_i,  input  logic s_aw_valid_i, output logic s_aw_ready_o,
  input  axi_w_t  s_w_i,   input  logic s_w_valid_i,  output logic s_w_ready_o,
  output axi_b_t  s_b_o,   output logic s_b_valid_o,  input  logic s_b_ready_i,
  output axi_ax_t m_ar_o,  output logic m_ar_valid_o, input  logic m_ar_ready_i,
  input  axi_r_t  m_r_i,   input  logic m_r_valid_i,  output logic m_r_ready_o,
  output axi_ax_t m_aw_o,  output logic m_aw_valid_o, input  logic m_aw_ready_i,
  output axi_w_t  m_w_o,   output logic m_w_valid_o,  input  logic m_w_ready_i,
  input  axi_b_t  m_b_i,   input  logic m_b_valid_i,  output logic m_b_ready_o
);
  tg_skid #(.T(axi_ax_t), .DSP(DSP[0])) u_ar (.clk, .rst, .in_valid (s_ar_valid_i), .in_ready (s_ar_ready_o), .in_data (s_ar_i),
                                .out_valid (m_ar_valid_o), .out_ready (m_ar_ready_i), .out_data (m_ar_o));
  tg_skid #(.T(axi_ax_t), .DSP(DSP[1])) u_aw (.clk, .rst, .in_valid (s_aw_valid_i), .in_ready (s_aw_ready_o), .in_data (s_aw_i),
                                .out_valid (m_aw_valid_o), .out_ready (m_aw_ready_i), .out_data (m_aw_o));
  tg_skid #(.T(axi_w_t), .DSP(DSP[2]))  u_w  (.clk, .rst, .in_valid (s_w_valid_i), .in_ready (s_w_ready_o), .in_data (s_w_i),
                                .out_valid (m_w_valid_o), .out_ready (m_w_ready_i), .out_data (m_w_o));
  tg_skid #(.T(axi_r_t), .DSP(DSP[3]))  u_r  (.clk, .rst, .in_valid (m_r_valid_i), .in_ready (m_r_ready_o), .in_data (m_r_i),
                                .out_valid (s_r_valid_o), .out_ready (s_r_ready_i), .out_data (s_r_o));
  tg_skid #(.T(axi_b_t), .DSP(DSP[4]))  u_b  (.clk, .rst, .in_valid (m_b_valid_i), .in_ready (m_b_ready_o), .in_data (m_b_i),
                                .out_valid (s_b_valid_o), .out_ready (s_b_ready_i), .out_data (s_b_o));
endmodule
