// Divide/sqrt unit (docs/spec/fpu.md, "Divide/sqrt unit"). Temporary stub while the unit is written.
module tg_fpu_div
  import tg_fpu_pkg::*;
(
  input  logic       clk,
  input  logic       rst,
  input  logic       valid_i,
  input  fpu_req_t   req_i,
  output logic       ready_o,
  output logic       valid_o,
  output fpu_resp_t  resp_o,
  input  logic       ready_i
);
  assign ready_o = 1'b0;
  assign valid_o = 1'b0;
  assign resp_o  = '0;
  logic unused;
  assign unused = ^{clk, rst, valid_i, req_i, ready_i};
endmodule
