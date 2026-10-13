// Tanager core: the port contract of docs/spec/interfaces.md §1–§5.
// Owned by the core track. This first version is a stub that keeps every output idle,
// so that the SoC and verification tracks can build around the real ports from day one.
module tg_core
  import tg_pkg::*, tg_tl_pkg::*, tg_trace_pkg::*;
#(
  parameter int unsigned CORE_ID = 0  // used for mhartid and trace hart IDs
) (
  input  logic                         clk,
  input  logic                         rst,
  input  paddr_t                       boot_addr_i,   // reset PC of every hart of this core

  // Interrupts and time: one bit per hart of this core (index = TID)
  input  logic [NUM_THREADS-1:0]       irq_mei_i,     // machine external (PLIC M context)
  input  logic [NUM_THREADS-1:0]       irq_sei_i,     // supervisor external (PLIC S context)
  input  logic [NUM_THREADS-1:0]       irq_mti_i,     // ACLINT MTIMER
  input  logic [NUM_THREADS-1:0]       irq_msi_i,     // ACLINT MSWI
  input  logic [NUM_THREADS-1:0]       irq_ssi_i,     // ACLINT SSWI (may be tied 0)
  input  logic [63:0]                  mtime_i,       // ACLINT mtime, for `time` and Sstc
  input  logic [NUM_THREADS-1:0]       debug_req_i,   // debug module halt request (M9; tie 0)
  output logic [NUM_THREADS-1:0]       merr_o,        // bus error on an early-retired load (plan §4.5)

  // Instruction fetch: Get only (channels A, D)
  output tl_a_t                        l1i_a_o,
  output logic                         l1i_a_valid_o,
  input  logic                         l1i_a_ready_i,
  input  tl_d_t                        l1i_d_i,
  input  logic                         l1i_d_valid_i,
  output logic                         l1i_d_ready_o,

  // Cacheable data: TL-C (channels A, B, C, D, E)
  output tl_a_t                        l1d_a_o,
  output logic                         l1d_a_valid_o,
  input  logic                         l1d_a_ready_i,
  input  tl_b_t                        l1d_b_i,
  input  logic                         l1d_b_valid_i,
  output logic                         l1d_b_ready_o,
  output tl_c_t                        l1d_c_o,
  output logic                         l1d_c_valid_o,
  input  logic                         l1d_c_ready_i,
  input  tl_d_t                        l1d_d_i,
  input  logic                         l1d_d_valid_i,
  output logic                         l1d_d_ready_o,
  output tl_e_t                        l1d_e_o,
  output logic                         l1d_e_valid_o,
  input  logic                         l1d_e_ready_i,

  // Uncached device accesses: Get, PutFullData, PutPartialData (channels A, D)
  output tl_a_t                        mmio_a_o,
  output logic                         mmio_a_valid_o,
  input  logic                         mmio_a_ready_i,
  input  tl_d_t                        mmio_d_i,
  input  logic                         mmio_d_valid_i,
  output logic                         mmio_d_ready_o,

  // Commit trace (lockstep in simulation, trace streaming on the FPGA)
  output tr_rec_t [COMMIT_WIDTH-1:0]   trace_o,
  output logic    [COMMIT_WIDTH-1:0]   trace_valid_o,
  output tr_wb_t  [TRACE_WB_PORTS-1:0] trace_wb_o,
  output logic    [TRACE_WB_PORTS-1:0] trace_wb_valid_o
);

  // ---- Stub: idle on every port ----
  localparam hart_t HART0 = hart_t'(CORE_ID * NUM_THREADS);
  assign merr_o           = '0;
  assign l1i_a_o          = '0;
  assign l1i_a_valid_o    = 1'b0;
  assign l1i_d_ready_o    = 1'b1;
  assign l1d_a_o          = '0;
  assign l1d_a_valid_o    = 1'b0;
  assign l1d_b_ready_o    = 1'b1;
  assign l1d_c_o          = '0;
  assign l1d_c_valid_o    = 1'b0;
  assign l1d_d_ready_o    = 1'b1;
  assign l1d_e_o          = '0;
  assign l1d_e_valid_o    = 1'b0;
  assign mmio_a_o         = '0;
  assign mmio_a_valid_o   = 1'b0;
  assign mmio_d_ready_o   = 1'b1;
  assign trace_o          = '0;
  assign trace_valid_o    = '0;
  assign trace_wb_o       = '0;
  assign trace_wb_valid_o = '0;

  // Inputs the stub ignores
  logic unused;
  assign unused = ^{HART0, clk, rst, boot_addr_i, irq_mei_i, irq_sei_i, irq_mti_i, irq_msi_i, irq_ssi_i,
                    mtime_i, debug_req_i, l1i_a_ready_i, l1i_d_i, l1i_d_valid_i, l1d_a_ready_i,
                    l1d_b_i, l1d_b_valid_i, l1d_c_ready_i, l1d_d_i, l1d_d_valid_i, l1d_e_ready_i,
                    mmio_a_ready_i, mmio_d_i, mmio_d_valid_i};
endmodule
