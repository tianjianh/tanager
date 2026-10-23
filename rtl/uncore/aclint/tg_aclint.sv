// ACLINT MSWI + MTIMER in the CLINT-compatible layout (docs/spec/uncore-periph.md):
// msip[h] at 4h, mtimecmp[h] at 0x4000 + 8h, mtime at 0xBFF8. mtime ticks at TIMEBASE_HZ from clk
// through a phase accumulator, and is broadcast to the cores. freeze_i holds the time base (mtime and
// the accumulator's phase): tg_uncore raises it while the commit trace stalls a core, if the host asks
// (CTRL.TFREEZE), so that board lockstep's back-pressure does not turn into timer ticks.
module tg_aclint
  import tg_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;
#(
  parameter int          N_HARTS = NUM_HARTS,
  parameter int unsigned CLK_HZ  = 100_000_000
) (
  input  logic               clk,
  input  logic               rst,
  input  dev_req_t           req_i,
  input  logic               req_valid_i,
  output dev_rsp_t           rsp_o,
  output logic [N_HARTS-1:0] irq_msi_o,
  output logic [N_HARTS-1:0] irq_mti_o,
  output logic [63:0]        mtime_o,
  input  logic               freeze_i
);
  localparam logic [31:0] TB_HZ = 32'(TIMEBASE_HZ);
  localparam logic [31:0] CK_HZ = 32'(CLK_HZ);

  logic [N_HARTS-1:0]       msip_q;
  logic [N_HARTS-1:0][63:0] cmp_q;
  logic [63:0]              mtime_q;
  logic [31:0]              acc_q;

  wire [15:0] off = req_i.addr[15:0];
  wire        wr  = req_valid_i && req_i.we;

  // Byte-lane merge of a write into a 64-bit register at a doubleword-aligned offset.
  function automatic logic [63:0] merge(input logic [63:0] old, input logic [63:0] wd, input logic [7:0] be);
    logic [63:0] r;
    for (int b = 0; b < 8; b++) r[8*b +: 8] = be[b] ? wd[8*b +: 8] : old[8*b +: 8];
    return r;
  endfunction

  // Time base: acc += TIMEBASE_HZ per cycle; one tick per CLK_HZ.
  wire [32:0] acc_sum = {1'b0, acc_q} + {1'b0, TB_HZ};
  wire        tick    = acc_sum >= {1'b0, CK_HZ};

  wire mtime_wr = wr && off[15:3] == 13'h17FF;   // 0xBFF8

  always_ff @(posedge clk) begin
    if (rst) begin
      acc_q   <= '0;
      mtime_q <= '0;
      msip_q  <= '0;
      for (int h = 0; h < N_HARTS; h++) cmp_q[h] <= '1;
    end else begin
      if (!freeze_i) acc_q <= tick ? 32'(acc_sum - {1'b0, CK_HZ}) : acc_sum[31:0];
      if (mtime_wr)                mtime_q <= merge(mtime_q, req_i.wdata, req_i.be);
      else if (tick && !freeze_i) mtime_q <= mtime_q + 64'd1;
      for (int h = 0; h < N_HARTS; h++) begin
        // msip: one word per hart; the doubleword at 8k holds harts 2k (low) and 2k+1 (high)
        if (wr && off[15:14] == 2'b00 && off[13:3] == 11'(h / 2)) begin
          if (h % 2 == 0 && req_i.be[0]) msip_q[h] <= req_i.wdata[0];
          if (h % 2 == 1 && req_i.be[4]) msip_q[h] <= req_i.wdata[32];
        end
        if (wr && off[15:14] == 2'b01 && off[13:3] == 11'(h))
          cmp_q[h] <= merge(cmp_q[h], req_i.wdata, req_i.be);
      end
    end
  end

  // Read data for the doubleword at `off`, registered (devices answer the cycle after req_valid).
  logic [63:0] rd;
  always_comb begin
    rd = '0;
    if (off[15:14] == 2'b00) begin
      for (int h = 0; h < N_HARTS; h++)
        if (off[13:3] == 11'(h / 2)) rd[32 * (h % 2)] = msip_q[h];
    end else if (off[15:14] == 2'b01) begin
      for (int h = 0; h < N_HARTS; h++)
        if (off[13:3] == 11'(h)) rd = cmp_q[h];
    end else if (off[15:3] == 13'h17FF) begin
      rd = mtime_q;
    end
  end

  always_ff @(posedge clk) begin
    rsp_o.rdata <= rd;
    rsp_o.err   <= 1'b0;
  end

  // MTIP: mtime >= mtimecmp, registered, per hart in two DSP48E2 compares (tg_dsp_cmp at latency 1,
  // whose P register is the compare's register; DR-136): the high words' lt and eq and the low words' lt,
  // combined after the registers. rst_q keeps the synchronous reset: mti_cmp is 0 the cycle after rst.
  // From the first clock edge on, mti_cmp is the register it replaced, cycle for cycle.
  // Each hart's MTIP and MSIP then leave through a register of their own, one cycle later (spikes §8.18):
  // the lines run into the cores' interrupt logic (the CSR file, rename, the ROB, fetch), and a flop that
  // the placer can put by the core keeps the DSPs' clock-to-out, rst_q and the route out of those cones.
  logic rst_q;
  always_ff @(posedge clk) rst_q <= rst;
  logic [N_HARTS-1:0] mti_cmp, mti_q, msi_q;
  for (genvar h = 0; h < N_HARTS; h++) begin : g_mti
    logic hi_eq, hi_lt, lo_eq, lo_lt;
    tg_dsp_cmp #(.W (32), .LAT (1)) u_hi (
      .clk, .ce (1'b1), .opa (mtime_q[63:32]), .opb (cmp_q[h][63:32]), .is_eq (hi_eq), .is_lt (hi_lt)
    );
    tg_dsp_cmp #(.W (32), .LAT (1)) u_lo (
      .clk, .ce (1'b1), .opa (mtime_q[31:0]), .opb (cmp_q[h][31:0]), .is_eq (lo_eq), .is_lt (lo_lt)
    );
    assign mti_cmp[h] = !rst_q && !(hi_lt || (hi_eq && lo_lt));
    wire unused_eq = lo_eq;
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      mti_q <= '0;
      msi_q <= '0;
    end else begin
      mti_q <= mti_cmp;
      msi_q <= msip_q;
    end
  end
  assign irq_mti_o = mti_q;
  assign irq_msi_o = msi_q;
  assign mtime_o   = mtime_q;

  wire unused = ^{req_i.addr[PA_W-1:16], off[2:0], req_i.size};

`ifndef SYNTHESIS
  // The DSPs' compare is the registered compare it replaced
  logic [N_HARTS-1:0] mti_ref_q;
  always_ff @(posedge clk) begin
    if (rst) mti_ref_q <= '0;
    else for (int h = 0; h < N_HARTS; h++) mti_ref_q[h] <= mtime_q >= cmp_q[h];
  end
  logic started_q;                      // past the first edge (before it, no register has loaded)
  always_ff @(posedge clk) started_q <= 1'b1;
  always_ff @(posedge clk) if (started_q === 1'b1) assert (mti_cmp == mti_ref_q) else $error("tg_aclint: MTIP differs from mtime >= mtimecmp");
`endif
endmodule
