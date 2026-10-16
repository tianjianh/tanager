// AXI4 register slice (docs/spec/uncore-mem.md): a two-entry skid buffer on each of the five
// channels, so every signal between the two sides starts or ends at a flip-flop. One cycle each way.
// DSP: per channel (bit 0 AR, 1 AW, 2 W, 3 R, 4 B), the skid's main data register in DSP48E2s
// (tg_skid DSP; DR-136). ON = 0 passes every channel straight through (a timing study at lower
// clocks, DR-145: the slices then cost no cycle and no area).
module tg_axi_slice
  import tg_uncore_pkg::*;
#(
  parameter logic [4:0] DSP = '0,
  parameter bit         ON  = 1'b1
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
  if (ON) begin : g_on
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
  end else begin : g_off
    assign m_ar_o = s_ar_i;  assign m_ar_valid_o = s_ar_valid_i;  assign s_ar_ready_o = m_ar_ready_i;
    assign m_aw_o = s_aw_i;  assign m_aw_valid_o = s_aw_valid_i;  assign s_aw_ready_o = m_aw_ready_i;
    assign m_w_o  = s_w_i;   assign m_w_valid_o  = s_w_valid_i;   assign s_w_ready_o  = m_w_ready_i;
    assign s_r_o  = m_r_i;   assign s_r_valid_o  = m_r_valid_i;   assign m_r_ready_o  = s_r_ready_i;
    assign s_b_o  = m_b_i;   assign s_b_valid_o  = m_b_valid_i;   assign m_b_ready_o  = s_b_ready_i;
    wire unused = ^{clk, rst};
  end
endmodule
