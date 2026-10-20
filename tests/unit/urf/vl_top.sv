// The top of tb_urf for runs with the vendor's URAM288_BASE model, which refers to glbl.GSR: the testbench
// and glbl side by side (from spikes-2's vl_top).
module vl_top #(
  parameter int NE     = 3,
  parameter int NL     = 3,
  parameter int CYCLES = 200000
);
  tb_urf #(.NE(NE), .NL(NL), .CYCLES(CYCLES)) tb ();
  glbl glbl ();
endmodule
