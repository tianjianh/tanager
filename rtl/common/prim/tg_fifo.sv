// Synchronous FIFO with valid/ready on both sides.
// Push is accepted when in_ready; pop happens when out_valid && out_ready.
// DEPTH must be a power of two. No fall-through: data appears one cycle after the push.
// STORAGE (plan §8.3: memories are explicit, and the primitive check counts them):
//   "lutram" (default): the entries are a tg_ram_lut (one asynchronous read port), so the
//            LUTRAM is the wrapper's deterministic mapping, not an inferred array.
//   "reg":   flip-flops. Each bit costs a flip-flop plus its share of a DEPTH:1 read mux,
//            so this pays only for a few narrow entries, or where SLICEM sites run short.
//   "srl":   shift-register LUTs (fpga_friendly.md T4), DEPTH <= 32. A push shifts every
//            entry one place; the oldest sits at position count - 1, which is the read
//            address. One count register replaces the two pointers. Per data bit: one
//            SRL16E (DEPTH <= 16; Vivado packs two in a LUT) or one SRLC32E (DEPTH 32).
// All three behave identically at the ports, cycle by cycle (tests/unit/prim/tb_fifo.sv).
module tg_fifo #(
  parameter type T       = logic [7:0],
  parameter int  DEPTH   = 4,
  parameter string STORAGE = "lutram",  // "lutram", "reg" or "srl"
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
  localparam int W = $bits(T);

  wire push = in_valid && in_ready;
  wire pop  = out_valid && out_ready;

  assign in_ready  = count != DEPTH[AW:0];
  assign out_valid = count != '0;

  if (STORAGE == "srl") begin : g_srl
    logic [AW:0] cnt_q;
    always_ff @(posedge clk) begin
      if (rst) cnt_q <= '0;
      else if (push && !pop) cnt_q <= cnt_q + 1'b1;
      else if (pop && !push) cnt_q <= cnt_q - 1'b1;
    end
    assign count = cnt_q;

    // read address: the oldest entry (don't care while empty)
    logic [AW-1:0] ra;
    assign ra = AW'(cnt_q - 1'b1);
    logic [W-1:0] wd, rd;
    assign wd = W'(in_data);
    assign out_data = T'(rd);

`ifdef SYNTHESIS
  `define TG_FIFO_SRL_PRIMS
`elsif TG_SIM_PRIMS
  `define TG_FIFO_SRL_PRIMS
`endif
`ifdef TG_FIFO_SRL_PRIMS
  `undef TG_FIFO_SRL_PRIMS
    for (genvar i = 0; i < W; i++) begin : g_bit
      if (DEPTH <= 16) begin : g_s16
        logic [3:0] a;
        assign a = 4'(ra);
        SRL16E #(.INIT(16'h0)) u_srl (
          .Q(rd[i]), .A0(a[0]), .A1(a[1]), .A2(a[2]), .A3(a[3]),
          .CE(push), .CLK(clk), .D(wd[i]));
      end else begin : g_s32
        /* verilator lint_off UNUSEDSIGNAL */  // the cascade output is not used
        logic q31;
        /* verilator lint_on UNUSEDSIGNAL */
        SRLC32E #(.INIT(32'h0)) u_srl (
          .Q(rd[i]), .Q31(q31), .A(5'(ra)), .CE(push), .CLK(clk), .D(wd[i]));
      end
    end
`else
    // Behavioural model (simulation): entry 0 is the newest.
    logic [DEPTH-1:0][W-1:0] sr;
    always_ff @(posedge clk) begin
      if (push) sr <= {sr[DEPTH-2:0], wd};
    end
    assign rd = sr[ra];
`endif
    if (DEPTH > 32) begin : g_bad_srl
      $error("tg_fifo: STORAGE \"srl\" needs DEPTH <= 32 (deeper FIFOs use \"lutram\")");
    end
  end else begin : g_ptr
    logic [AW:0] wr_q, rd_q;
    always_ff @(posedge clk) begin
      if (rst) begin
        wr_q <= '0;
        rd_q <= '0;
      end else begin
        if (push) wr_q <= wr_q + 1'b1;
        if (pop)  rd_q <= rd_q + 1'b1;
      end
    end
    assign count = wr_q - rd_q;

    if (STORAGE == "reg") begin : g_reg
      (* ram_style = "registers" *) T mem [DEPTH];
      always_ff @(posedge clk) begin
        if (push) mem[wr_q[AW-1:0]] <= in_data;
      end
      assign out_data = mem[rd_q[AW-1:0]];
    end else begin : g_lut
      logic [0:0][AW-1:0] ra;
      logic [0:0][W-1:0]  rd;
      assign ra[0] = rd_q[AW-1:0];
      tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(W), .NR(1)) u_mem (
        .clk, .we(push), .waddr(wr_q[AW-1:0]), .wdata(W'(in_data)), .raddr(ra), .rdata(rd));
      assign out_data = T'(rd[0]);
    end
  end

  if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin : g_bad_depth
    $error("tg_fifo: DEPTH must be a power of two >= 2");
  end
  if (STORAGE != "lutram" && STORAGE != "reg" && STORAGE != "srl") begin : g_bad_storage
    $error("tg_fifo: STORAGE must be \"lutram\", \"reg\" or \"srl\"");
  end
endmodule
