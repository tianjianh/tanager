// FPU execution units: the port contract of docs/spec/interfaces.md §4 (docs/spec/fpu.md).
// Owned by the FPU track. The three units are independent; this module only instantiates them.
module tg_fpu
  import tg_fpu_pkg::*;
#(
  // 0: Goldschmidt divide/sqrt (tg_fpu_div); 1: the radix-4 fallback (tg_fpu_div_r4)
  parameter bit DIV_RADIX4 = FDIV_RADIX4
) (
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

  // Divide/sqrt: accepts when ready; results wait for resp_ready
  input  logic       fdiv_valid_i,
  input  fpu_req_t   fdiv_req_i,
  output logic       fdiv_ready_o,
  output logic       fdiv_valid_o,
  output fpu_resp_t  fdiv_resp_o,
  input  logic       fdiv_ready_i
);

  tg_fpu_fma u_fma (
    .clk, .rst,
    .valid_i (fma_valid_i), .req_i (fma_req_i),
    .valid_o (fma_valid_o), .resp_o (fma_resp_o)
  );

  tg_fpu_misc u_misc (
    .clk, .rst,
    .valid_i (fmisc_valid_i), .req_i (fmisc_req_i),
    .valid_o (fmisc_valid_o), .resp_o (fmisc_resp_o)
  );

  if (DIV_RADIX4) begin : g_div_r4
    tg_fpu_div_r4 u_div (
      .clk, .rst,
      .valid_i (fdiv_valid_i), .req_i (fdiv_req_i), .ready_o (fdiv_ready_o),
      .valid_o (fdiv_valid_o), .resp_o (fdiv_resp_o), .ready_i (fdiv_ready_i)
    );
  end else begin : g_div_gs
    tg_fpu_div u_div (
      .clk, .rst,
      .valid_i (fdiv_valid_i), .req_i (fdiv_req_i), .ready_o (fdiv_ready_o),
      .valid_o (fdiv_valid_o), .resp_o (fdiv_resp_o), .ready_i (fdiv_ready_i)
    );
  end

endmodule
