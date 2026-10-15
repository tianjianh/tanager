// DR-133 gate 3: a v1 full-chip fit with the real cores. Two tg_core instances (the
// configuration's cores, e.g. smt2 with IRF_URAM's UltraRAM register-file copies) and the S6
// L2 stand-in (tg_s6_l2: the 1 MiB L2 in 32 UltraRAMs, with L2_TILES of filler), placed and
// routed together, so the cores' UltraRAMs and the L2's share the device's URAM columns.
// Every core input is a register fed by a random shift chain, and every core output feeds a
// fold into the L2 stand-in's input bus, so nothing is constant and nothing is trimmed (the
// S6 method, docs/perf/spikes.md §8). The design is not functional; it is for placement and
// timing. Not in spikes.f: fpga/spikes/tcl/ooc_run.tcl reads it with -rtl 1 and -file for
// it, fpga/spikes/rtl/tg_s6_fill.sv and tg_s6_l2.sv (not spikes.f, whose spike modules share
// names with the production units).
module tg_g3_top
  import tg_pkg::*, tg_tl_pkg::*, tg_trace_pkg::*;
#(
  parameter int L2_TILES = 40,
  parameter int BUS_W    = 256
) (
  input  logic        clk,
  input  logic [63:0] seed_i,
  output logic [63:0] out_o
);
  // per core: every input bit, then every output bit
  localparam int NIN  = 2 + $bits(paddr_t) + 6 * NUM_THREADS + 64 + 5 + 4
                        + 3 * $bits(tl_d_t) + $bits(tl_b_t);
  localparam int NOUT = NUM_THREADS + 3 * $bits(tl_a_t) + $bits(tl_c_t) + $bits(tl_e_t) + 9
                        + COMMIT_WIDTH * ($bits(tr_rec_t) + 1)
                        + TRACE_WB_PORTS * ($bits(tr_wb_t) + 1);

  logic [1:0][BUS_W-1:0] to_l2_q, from_l2;
  logic [15:0]           l2_obs;
  logic [1:0][63:0]      xs;     // each core's random source, for the top output

  for (genvar c = 0; c < 2; c++) begin : g_core
    // random source: a 64-bit xorshift mixed with the seed and the L2's responses
    logic [63:0] x_q, x_n, back;
    always_comb begin
      back = '0;
      for (int i = 0; i < BUS_W; i++) back[i % 64] ^= from_l2[c][i];
      x_n = x_q ^ (x_q << 13);
      x_n = x_n ^ (x_n >> 7);
      x_n = x_n ^ (x_n << 17);
    end
    // the input registers: a chain that shifts 64 new bits in each cycle
    logic [NIN-1:0] in_q;
    always_ff @(posedge clk) begin
      x_q  <= x_n ^ seed_i ^ back ^ 64'(c);
      in_q <= {in_q[NIN-65:0], x_q};
    end
    assign xs[c] = x_q;

    logic                         rst, trace_stall;
    paddr_t                       boot_addr;
    logic [NUM_THREADS-1:0]       irq_mei, irq_sei, irq_mti, irq_msi, irq_ssi, debug_req;
    logic [63:0]                  mtime;
    logic                         l1i_a_ready, l1d_a_ready, l1d_c_ready, l1d_e_ready, mmio_a_ready;
    tl_d_t                        l1i_d, l1d_d, mmio_d;
    tl_b_t                        l1d_b;
    logic                         l1i_d_valid, l1d_b_valid, l1d_d_valid, mmio_d_valid;
    assign {rst, trace_stall, boot_addr, irq_mei, irq_sei, irq_mti, irq_msi, irq_ssi, debug_req,
            mtime, l1i_a_ready, l1d_a_ready, l1d_c_ready, l1d_e_ready, mmio_a_ready,
            l1i_d_valid, l1d_b_valid, l1d_d_valid, mmio_d_valid, l1i_d, l1d_d, mmio_d, l1d_b} = in_q;

    logic [NUM_THREADS-1:0]       merr;
    tl_a_t                        l1i_a, l1d_a, mmio_a;
    tl_c_t                        l1d_c;
    tl_e_t                        l1d_e;
    logic                         l1i_a_valid, l1i_d_ready, l1d_a_valid, l1d_b_ready, l1d_c_valid;
    logic                         l1d_d_ready, l1d_e_valid, mmio_a_valid, mmio_d_ready;
    tr_rec_t [COMMIT_WIDTH-1:0]   trace;
    logic    [COMMIT_WIDTH-1:0]   trace_valid;
    tr_wb_t  [TRACE_WB_PORTS-1:0] trace_wb;
    logic    [TRACE_WB_PORTS-1:0] trace_wb_valid;

    tg_core #(.CORE_ID(c)) u_core (
      .clk, .rst, .boot_addr_i(boot_addr),
      .irq_mei_i(irq_mei), .irq_sei_i(irq_sei), .irq_mti_i(irq_mti), .irq_msi_i(irq_msi),
      .irq_ssi_i(irq_ssi), .mtime_i(mtime), .debug_req_i(debug_req), .merr_o(merr),
      .l1i_a_o(l1i_a), .l1i_a_valid_o(l1i_a_valid), .l1i_a_ready_i(l1i_a_ready),
      .l1i_d_i(l1i_d), .l1i_d_valid_i(l1i_d_valid), .l1i_d_ready_o(l1i_d_ready),
      .l1d_a_o(l1d_a), .l1d_a_valid_o(l1d_a_valid), .l1d_a_ready_i(l1d_a_ready),
      .l1d_b_i(l1d_b), .l1d_b_valid_i(l1d_b_valid), .l1d_b_ready_o(l1d_b_ready),
      .l1d_c_o(l1d_c), .l1d_c_valid_o(l1d_c_valid), .l1d_c_ready_i(l1d_c_ready),
      .l1d_d_i(l1d_d), .l1d_d_valid_i(l1d_d_valid), .l1d_d_ready_o(l1d_d_ready),
      .l1d_e_o(l1d_e), .l1d_e_valid_o(l1d_e_valid), .l1d_e_ready_i(l1d_e_ready),
      .mmio_a_o(mmio_a), .mmio_a_valid_o(mmio_a_valid), .mmio_a_ready_i(mmio_a_ready),
      .mmio_d_i(mmio_d), .mmio_d_valid_i(mmio_d_valid), .mmio_d_ready_o(mmio_d_ready),
      .trace_o(trace), .trace_valid_o(trace_valid), .trace_wb_o(trace_wb),
      .trace_wb_valid_o(trace_wb_valid), .trace_stall_i(trace_stall));

    // every output bit, folded onto the bus to the L2 stand-in
    logic [NOUT-1:0]  outv;
    logic [BUS_W-1:0] fold;
    assign outv = {merr, l1i_a, l1d_a, mmio_a, l1d_c, l1d_e, l1i_a_valid, l1i_d_ready, l1d_a_valid,
                   l1d_b_ready, l1d_c_valid, l1d_d_ready, l1d_e_valid, mmio_a_valid, mmio_d_ready,
                   trace, trace_valid, trace_wb, trace_wb_valid};
    always_comb begin
      fold = '0;
      for (int i = 0; i < NOUT; i++) fold[i % BUS_W] ^= outv[i];
    end
    always_ff @(posedge clk) to_l2_q[c] <= fold;
  end

  tg_s6_l2 #(.TILES(L2_TILES), .NRAM(0), .BUS_W(BUS_W)) u_l2 (
    .clk, .c_in(to_l2_q), .c_out(from_l2), .obs(l2_obs));

  always_ff @(posedge clk) out_o <= {48'd0, l2_obs} ^ xs[0] ^ xs[1];
endmodule
