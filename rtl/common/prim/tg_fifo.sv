// Synchronous FIFO with valid/ready on both sides, flip-flop storage.
// Push is accepted when in_ready; pop happens when out_valid && out_ready.
// DEPTH must be a power of two. No fall-through: data appears one cycle after the push.
module tg_fifo #(
  parameter type T     = logic [7:0],
  parameter int  DEPTH = 4,
  localparam int AW    = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
  input  logic  clk,
  input  logic  rst,
  input  logic  in_valid,
  output logic  in_ready,
  input  T      in_data,
  output logic  out_valid,
  input  logic  out_ready,
  output T      out_data,
  output logic [AW:0] count
);
  T            mem [DEPTH];
  logic [AW:0] wr_q, rd_q;

  wire push = in_valid && in_ready;
  wire pop  = out_valid && out_ready;

  assign count     = wr_q - rd_q;
  assign in_ready  = count != DEPTH[AW:0];
  assign out_valid = count != '0;
  assign out_data  = mem[rd_q[AW-1:0]];

  always_ff @(posedge clk) begin
    if (rst) begin
      wr_q <= '0;
      rd_q <= '0;
    end else begin
      if (push) wr_q <= wr_q + 1'b1;
      if (pop)  rd_q <= rd_q + 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (push) mem[wr_q[AW-1:0]] <= in_data;
  end

  if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin : g_bad_depth
    $error("tg_fifo: DEPTH must be a power of two >= 2");
  end
endmodule
