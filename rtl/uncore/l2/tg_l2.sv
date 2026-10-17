// Shared L2: N_BANKS banks interleaved on address bit 6 (docs/spec/l2.md). The interconnect
// already delivers each bank only its own addresses; this wrapper instantiates the banks and
// gathers their status.
module tg_l2
  import tg_pkg::*, tg_tl_pkg::*, tg_uncore_pkg::*;
#(
  parameter int N_AGENTS  = NUM_CORES,
  parameter int SETS      = 1024,
  parameter int N_MSHR    = 24,
  parameter int N_WB      = 4,
  parameter int N_PUTBUF  = 4,
  parameter     DATA_PRIM = "ultra",
  parameter int DATA_LAT  = 2,
  parameter logic [3:0] RSLICE_DSP = '0,  // per bank: its R slice in DSP48E2s (tg_l2_bank)
  parameter bit         MWAY_OH    = 1'b1,// the MSHRs' way flip-flops one-hot (tg_l2_bank, DR-142)
  parameter bit         DIR_S3     = 1'b1 // the directory RAM written at S3 (tg_l2_bank, DR-142)
) (
  input  logic                  clk,
  input  logic                  rst,
  input  tl_a_t   [N_BANKS-1:0] a_i,
  input  logic    [N_BANKS-1:0] a_valid_i,
  output logic    [N_BANKS-1:0] a_ready_o,
  output tl_b_t   [N_BANKS-1:0] b_o,
  output logic    [N_BANKS-1:0] b_valid_o,
  input  logic    [N_BANKS-1:0] b_ready_i,
  input  tl_c_t   [N_BANKS-1:0] c_i,
  input  logic    [N_BANKS-1:0] c_valid_i,
  output logic    [N_BANKS-1:0] c_ready_o,
  output tl_d_t   [N_BANKS-1:0] d_o,
  output logic    [N_BANKS-1:0] d_valid_o,
  input  logic    [N_BANKS-1:0] d_ready_i,
  input  tl_e_t   [N_BANKS-1:0] e_i,
  input  logic    [N_BANKS-1:0] e_valid_i,
  output logic    [N_BANKS-1:0] e_ready_o,
  output axi_ax_t [N_BANKS-1:0] ar_o,
  output logic    [N_BANKS-1:0] ar_valid_o,
  input  logic    [N_BANKS-1:0] ar_ready_i,
  input  axi_r_t  [N_BANKS-1:0] r_i,
  input  logic    [N_BANKS-1:0] r_valid_i,
  output logic    [N_BANKS-1:0] r_ready_o,
  output axi_ax_t [N_BANKS-1:0] aw_o,
  output logic    [N_BANKS-1:0] aw_valid_o,
  input  logic    [N_BANKS-1:0] aw_ready_i,
  output axi_w_t  [N_BANKS-1:0] w_o,
  output logic    [N_BANKS-1:0] w_valid_o,
  input  logic    [N_BANKS-1:0] w_ready_i,
  input  axi_b_t  [N_BANKS-1:0] bresp_i,
  input  logic    [N_BANKS-1:0] bresp_valid_i,
  output logic    [N_BANKS-1:0] bresp_ready_o,
  output logic                  init_done_o,
  output logic    [N_BANKS-1:0] ev_hit_o,
  output logic    [N_BANKS-1:0] ev_miss_o,
  output logic    [N_BANKS-1:0] ev_wb_o,
  output logic    [N_BANKS-1:0] ev_probe_o,
  output logic    [N_BANKS-1:0] ev_err_o,
  output logic    [N_BANKS-1:0][31:0]     ev_err_info_o,   // with ev_err_o: what it was (tg_l2_bank)
  output logic    [N_BANKS-1:0][PA_W-7:0] ev_err_line_o
);
  logic [N_BANKS-1:0] done;

  for (genvar b = 0; b < N_BANKS; b++) begin : g_bank
    tg_l2_bank #(
      .BANK (b), .N_AGENTS (N_AGENTS), .SETS (SETS), .N_MSHR (N_MSHR), .N_WB (N_WB),
      .N_PUTBUF (N_PUTBUF), .DATA_PRIM (DATA_PRIM), .DATA_LAT (DATA_LAT), .RSLICE_DSP (RSLICE_DSP[b]),
      .MWAY_OH (MWAY_OH), .DIR_S3 (DIR_S3)
    ) u_bank (
      .clk, .rst,
      .a_i (a_i[b]), .a_valid_i (a_valid_i[b]), .a_ready_o (a_ready_o[b]),
      .b_o (b_o[b]), .b_valid_o (b_valid_o[b]), .b_ready_i (b_ready_i[b]),
      .c_i (c_i[b]), .c_valid_i (c_valid_i[b]), .c_ready_o (c_ready_o[b]),
      .d_o (d_o[b]), .d_valid_o (d_valid_o[b]), .d_ready_i (d_ready_i[b]),
      .e_i (e_i[b]), .e_valid_i (e_valid_i[b]), .e_ready_o (e_ready_o[b]),
      .ar_o (ar_o[b]), .ar_valid_o (ar_valid_o[b]), .ar_ready_i (ar_ready_i[b]),
      .r_i (r_i[b]), .r_valid_i (r_valid_i[b]), .r_ready_o (r_ready_o[b]),
      .aw_o (aw_o[b]), .aw_valid_o (aw_valid_o[b]), .aw_ready_i (aw_ready_i[b]),
      .w_o (w_o[b]), .w_valid_o (w_valid_o[b]), .w_ready_i (w_ready_i[b]),
      .bresp_i (bresp_i[b]), .bresp_valid_i (bresp_valid_i[b]), .bresp_ready_o (bresp_ready_o[b]),
      .init_done_o (done[b]),
      .ev_hit_o (ev_hit_o[b]), .ev_miss_o (ev_miss_o[b]), .ev_wb_o (ev_wb_o[b]),
      .ev_probe_o (ev_probe_o[b]), .ev_err_o (ev_err_o[b]),
      .ev_err_info_o (ev_err_info_o[b]), .ev_err_line_o (ev_err_line_o[b])
    );
  end

  assign init_done_o = &done;
endmodule
