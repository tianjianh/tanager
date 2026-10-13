// FMA unit (docs/spec/fpu.md, "FMA unit"). Temporary stub while the unit is written.
module tg_fpu_fma
  import tg_fpu_pkg::*;
(
  input  logic       clk,
  input  logic       rst,
  input  logic       valid_i,
  input  fpu_req_t   req_i,
  output logic       valid_o,
  output fpu_resp_t  resp_o
);
  assign valid_o = 1'b0;
  assign resp_o  = '0;
  logic unused;
  assign unused = ^{clk, rst, valid_i, req_i};
endmodule
