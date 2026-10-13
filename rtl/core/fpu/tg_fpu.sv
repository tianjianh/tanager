// FPU execution units: the port contract of docs/spec/interfaces.md §4.
// Owned by the FPU track. This first version is a stub that returns no results.
module tg_fpu
  import tg_fpu_pkg::*;
(
  input  logic       clk,
  input  logic       rst,

  // FMA pipe: fully pipelined, result exactly FMA_LAT cycles after the request, no backpressure
  input  logic       fma_valid_i,
  input  fpu_req_t   fma_req_i,
  output logic       fma_valid_o,
  output fpu_resp_t  fma_resp_o,

  // FMISC: fully pipelined, result exactly FMISC_LAT cycles after the request, no backpressure
  input  logic       fmisc_valid_i,
  input  fpu_req_t   fmisc_req_i,
  output logic       fmisc_valid_o,
  output fpu_resp_t  fmisc_resp_o,

  // Divide/sqrt: accepts when ready (every FDIV_II cycles); results wait for resp_ready
  input  logic       fdiv_valid_i,
  input  fpu_req_t   fdiv_req_i,
  output logic       fdiv_ready_o,
  output logic       fdiv_valid_o,
  output fpu_resp_t  fdiv_resp_o,
  input  logic       fdiv_ready_i
);

  // ---- Stub ----
  assign fma_valid_o   = 1'b0;
  assign fma_resp_o    = '0;
  assign fmisc_valid_o = 1'b0;
  assign fmisc_resp_o  = '0;
  assign fdiv_ready_o  = 1'b0;
  assign fdiv_valid_o  = 1'b0;
  assign fdiv_resp_o   = '0;

  logic unused;
  assign unused = ^{clk, rst, fma_valid_i, fma_req_i, fmisc_valid_i, fmisc_req_i,
                    fdiv_valid_i, fdiv_req_i, fdiv_ready_i};
endmodule
