// ACLINT MSWI + MTIMER in the CLINT-compatible layout (docs/spec/uncore-periph.md):
// msip[h] at 4h, mtimecmp[h] at 0x4000 + 8h, mtime at 0xBFF8. mtime ticks at TIMEBASE_HZ from clk
// through a phase accumulator, and is broadcast to the cores.
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
  output logic [63:0]        mtime_o
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
      acc_q <= tick ? 32'(acc_sum - {1'b0, CK_HZ}) : acc_sum[31:0];
      if (mtime_wr)  mtime_q <= merge(mtime_q, req_i.wdata, req_i.be);
      else if (tick) mtime_q <= mtime_q + 64'd1;
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

  always_ff @(posedge clk) begin
    if (rst) irq_mti_o <= '0;
    else for (int h = 0; h < N_HARTS; h++) irq_mti_o[h] <= mtime_q >= cmp_q[h];
  end
  assign irq_msi_o = msip_q;
  assign mtime_o   = mtime_q;

  wire unused = ^{req_i.addr[PA_W-1:16], off[2:0], req_i.size};
endmodule
