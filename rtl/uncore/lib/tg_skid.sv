// Two-entry register slice (skid buffer) with valid/ready on both sides.
// Full throughput; out_valid, out_data and in_ready all come straight from flip-flops,
// so the slice cuts every combinational path through it (docs/spec/uncore.md).
// DSP = 1 puts the main data register into DSP48E2 slices (tg_dsp_reg2; DR-136): the same
// register transfer, without the fabric's 2:1 select (about a LUT per two bits).
module tg_skid #(
  parameter type T   = logic [7:0],
  parameter bit  DSP = 1'b0
) (
  input  logic clk,
  input  logic rst,
  input  logic in_valid,
  output logic in_ready,
  input  T     in_data,
  output logic out_valid,
  input  logic out_ready,
  output T     out_data
);
  T     main_q, skid_q;
  logic main_v_q, skid_v_q;

  assign in_ready  = !skid_v_q;
  assign out_valid = main_v_q;
  assign out_data  = main_q;

  wire main_free = !main_v_q || out_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      main_v_q <= 1'b0;
      skid_v_q <= 1'b0;
    end else if (main_free) begin
      main_v_q <= skid_v_q || in_valid;
      skid_v_q <= 1'b0;
    end else if (in_valid && !skid_v_q) begin
      skid_v_q <= 1'b1;
    end
  end

  // The skid entry loads whenever it is empty, not only when it is about to be filled: its contents
  // matter only once skid_v_q is set, which happens exactly when the entry loads in either form. So
  // its clock enable is a register, not the late in_valid and out_ready fanned out to every bit
  // (200 MHz, DR-137: the clock enable of a crossbar D slice's skid entry was 1.3 ns of its path).
  always_ff @(posedge clk)
    if (!skid_v_q) skid_q <= in_data;

`ifndef SYNTHESIS
  // The skid entry holds what the original load rule would have captured, whenever it is in use
  T skid_ref_q;
  always_ff @(posedge clk) if (!main_free && in_valid && !skid_v_q) skid_ref_q <= in_data;
  always_ff @(posedge clk) if (!rst && skid_v_q) assert (skid_q == skid_ref_q) else $error("tg_skid: skid entry differs");
`endif

  if (DSP) begin : g_dsp
    tg_dsp_reg2 #(.W ($bits(T))) u_main (
      .clk, .en (main_free), .sel_c (skid_v_q), .a (in_data), .c (skid_q), .q (main_q)
    );
  end else begin : g_fab
    always_ff @(posedge clk)
      if (main_free) main_q <= skid_v_q ? skid_q : in_data;
  end
endmodule
