// Asynchronous FIFO between two clock domains with valid/ready on both sides (docs/spec/host.md).
// First-word fall-through: out_data is valid whenever out_valid. rd_level counts entries visible
// on the read side, wr_level the entries the write side sees in use (each lags the other side's
// pointer through its synchronizer). DEPTH: power of two, >= 16.
// The reset is synchronous to wr_clk, as xpm_fifo_async requires; the read side follows it.
// xpm_fifo_async under SYNTHESIS; a Gray-code pointer FIFO with the same contract in simulation.
// MEM is xpm_fifo_async's FIFO_MEMORY_TYPE: "auto" lets synthesis choose, "distributed" keeps a
// small FIFO in LUTRAM where block RAM is short.
module tg_afifo #(
  parameter int  W     = 8,
  parameter int  DEPTH = 16,
  parameter      MEM   = "auto",
  localparam int AW    = $clog2(DEPTH)
) (
  input  logic         wr_clk,
  input  logic         wr_rst,
  input  logic         in_valid,
  output logic         in_ready,
  input  logic [W-1:0] in_data,
  output logic [AW:0]  wr_level,
  input  logic         rd_clk,
  output logic         out_valid,
  input  logic         out_ready,
  output logic [W-1:0] out_data,
  output logic [AW:0]  rd_level
);
`ifdef SYNTHESIS
  logic full, empty, wr_busy, rd_busy;
  xpm_fifo_async #(
    .CDC_SYNC_STAGES     (3),
    .DOUT_RESET_VALUE    ("0"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_MEMORY_TYPE    (MEM),
    .FIFO_READ_LATENCY   (0),
    .FIFO_WRITE_DEPTH    (DEPTH),
    .FULL_RESET_VALUE    (0),
    .PROG_EMPTY_THRESH   (10),
    .PROG_FULL_THRESH    (10),
    .RD_DATA_COUNT_WIDTH (AW + 1),
    .READ_DATA_WIDTH     (W),
    .READ_MODE           ("fwft"),
    .RELATED_CLOCKS      (0),
    .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0404"),   // rd_data_count, wr_data_count
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (W),
    .WR_DATA_COUNT_WIDTH (AW + 1)
  ) u_fifo (
    .rst           (wr_rst),
    .wr_clk        (wr_clk),
    .wr_en         (in_valid && in_ready),
    .din           (in_data),
    .full          (full),
    .wr_rst_busy   (wr_busy),
    .rd_clk        (rd_clk),
    .rd_en         (out_valid && out_ready),
    .dout          (out_data),
    .empty         (empty),
    .rd_rst_busy   (rd_busy),
    .rd_data_count (rd_level),
    .sleep         (1'b0),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .wr_data_count (wr_level),
    .prog_full     (), .overflow (), .wr_ack (), .almost_full (),
    .prog_empty    (), .underflow (), .data_valid (), .almost_empty (), .sbiterr (), .dbiterr ()
  );
  assign in_ready  = !full && !wr_busy;
  assign out_valid = !empty && !rd_busy;
`else
  wire unused_mem = MEM == "";
  logic [W-1:0] mem [DEPTH];
  logic [AW:0]  wbin_q, wgray_q, rbin_q, rgray_q;
  logic [AW:0]  rgray_w1, rgray_w2, wgray_r1, wgray_r2;   // synchronizers
  logic [2:0]   rst_r_q;                                   // reset into the read domain

  function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    return b ^ (b >> 1);
  endfunction
  function automatic logic [AW:0] gray2bin(input logic [AW:0] g);
    logic [AW:0] b;
    b[AW] = g[AW];
    for (int i = AW - 1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  wire [AW:0] rbin_w = gray2bin(rgray_w2);
  assign wr_level = wbin_q - rbin_w;
  assign in_ready = wr_level != (AW+1)'(DEPTH);
  always_ff @(posedge wr_clk) begin
    if (wr_rst) begin
      wbin_q   <= '0;
      wgray_q  <= '0;
      rgray_w1 <= '0;
      rgray_w2 <= '0;
    end else begin
      rgray_w1 <= rgray_q;
      rgray_w2 <= rgray_w1;
      if (in_valid && in_ready) begin
        wbin_q  <= wbin_q + 1'b1;
        wgray_q <= bin2gray(wbin_q + 1'b1);
      end
    end
    if (in_valid && in_ready) mem[wbin_q[AW-1:0]] <= in_data;
  end

  wire        rd_rst = rst_r_q[2];
  wire [AW:0] wbin_r = gray2bin(wgray_r2);
  assign rd_level  = wbin_r - rbin_q;
  assign out_valid = !rd_rst && (rd_level != '0);
  assign out_data  = mem[rbin_q[AW-1:0]];
  always_ff @(posedge rd_clk) begin
    rst_r_q <= {rst_r_q[1:0], wr_rst};
    if (rd_rst) begin
      rbin_q   <= '0;
      rgray_q  <= '0;
      wgray_r1 <= '0;
      wgray_r2 <= '0;
    end else begin
      wgray_r1 <= wgray_q;
      wgray_r2 <= wgray_r1;
      if (out_valid && out_ready) begin
        rbin_q  <= rbin_q + 1'b1;
        rgray_q <= bin2gray(rbin_q + 1'b1);
      end
    end
  end
`endif
endmodule
