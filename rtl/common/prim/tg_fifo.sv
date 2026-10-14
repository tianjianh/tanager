// Synchronous FIFO with valid/ready on both sides.
// Push is accepted when in_ready; pop happens when out_valid && out_ready.
// DEPTH must be a power of two. No fall-through: data appears one cycle after the push.
// STORAGE (plan §8.3: memories are explicit, and the primitive check counts them):
//   "lutram" (default): the entries are a tg_ram_lut (one asynchronous read port), so the
//            LUTRAM is the wrapper's deterministic mapping, not an inferred array.
//   "reg":   flip-flops. Each bit costs a flip-flop plus its share of a DEPTH:1 read mux,
//            so this pays only for a few narrow entries, or where SLICEM sites run short.
module tg_fifo #(
  parameter type T       = logic [7:0],
  parameter int  DEPTH   = 4,
  parameter      STORAGE = "lutram",   // "lutram" or "reg"
  localparam int AW      = (DEPTH > 1) ? $clog2(DEPTH) : 1
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
  logic [AW:0] wr_q, rd_q;

  wire push = in_valid && in_ready;
  wire pop  = out_valid && out_ready;

  assign count     = wr_q - rd_q;
  assign in_ready  = count != DEPTH[AW:0];
  assign out_valid = count != '0;

  always_ff @(posedge clk) begin
    if (rst) begin
      wr_q <= '0;
      rd_q <= '0;
    end else begin
      if (push) wr_q <= wr_q + 1'b1;
      if (pop)  rd_q <= rd_q + 1'b1;
    end
  end

  if (STORAGE == "reg") begin : g_reg
    (* ram_style = "registers" *) T mem [DEPTH];
    always_ff @(posedge clk) begin
      if (push) mem[wr_q[AW-1:0]] <= in_data;
    end
    assign out_data = mem[rd_q[AW-1:0]];
  end else begin : g_lut
    localparam int W = $bits(T);
    logic [0:0][AW-1:0] ra;
    logic [0:0][W-1:0]  rd;
    assign ra[0] = rd_q[AW-1:0];
    tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(W), .NR(1)) u_mem (
      .clk, .we(push), .waddr(wr_q[AW-1:0]), .wdata(W'(in_data)), .raddr(ra), .rdata(rd));
    assign out_data = T'(rd[0]);
  end

  if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin : g_bad_depth
    $error("tg_fifo: DEPTH must be a power of two >= 2");
  end
  if (STORAGE != "lutram" && STORAGE != "reg") begin : g_bad_storage
    $error("tg_fifo: STORAGE must be \"lutram\" or \"reg\"");
  end
endmodule
