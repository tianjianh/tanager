// FPU execution units: the port contract of docs/spec/interfaces.md §4 (docs/spec/fpu.md).
// Owned by the FPU track. The three units are independent; this module instantiates them and, with
// SHARE_UNPACK (P4, where one request feeds both), unpacks the FMA's and FMISC's a and b once.
module tg_fpu
  import tg_fpu_pkg::*;
  import tg_fpu_util_pkg::*;
#(
  // 1: the FMA and FMISC take one request (fma_req_i; P4), so their operands are unpacked once
  parameter bit SHARE_UNPACK = 1'b0,
  // 0: Goldschmidt divide/sqrt (tg_fpu_div); 1: the radix-4 fallback (tg_fpu_div_r4)
  parameter bit DIV_RADIX4 = FDIV_RADIX4,
  // Divide tag bits the user reads: the Goldschmidt unit's output queue keeps only these
  parameter int DIV_TAG_W = tg_pkg::FPU_TAG_W
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

  // a and b unpacked in the operand format (FCVT.F.F's source format; else fmt), as both units read
  // them; with SHARE_UNPACK they serve both units (fmisc_req_i must then be fma_req_i)
  logic    sdbl;
  fp_unp_t ua, ub;
  assign sdbl = (fma_req_i.op == FOP_FCVT_F_F) ? (fma_req_i.src_fmt == FMT_D) : (fma_req_i.fmt == FMT_D);
  assign ua   = unpack(fma_req_i.a, sdbl);
  assign ub   = unpack(fma_req_i.b, sdbl);
  tg_fpu_fma #(.SHARED(SHARE_UNPACK)) u_fma (
    .clk, .rst, .ua_i(ua), .ub_i(ub),
    .valid_i (fma_valid_i), .req_i (fma_req_i),
    .valid_o (fma_valid_o), .resp_o (fma_resp_o)
  );

  tg_fpu_misc #(.SHARED(SHARE_UNPACK)) u_misc (
    .clk, .rst, .ua_i(ua), .ub_i(ub),
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
    tg_fpu_div #(.TAG_W(DIV_TAG_W)) u_div (
      .clk, .rst,
      .valid_i (fdiv_valid_i), .req_i (fdiv_req_i), .ready_o (fdiv_ready_o),
      .valid_o (fdiv_valid_o), .resp_o (fdiv_resp_o), .ready_i (fdiv_ready_i)
    );
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && SHARE_UNPACK && fmisc_valid_i)
      assert (fmisc_req_i == fma_req_i) else $error("tg_fpu: SHARE_UNPACK with two different requests");
  end
`endif

endmodule
