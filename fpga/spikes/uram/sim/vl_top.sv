// The top of tb_urf for Verilator runs with the vendor's URAM288_BASE model, which refers to glbl.GSR: the
// testbench and glbl side by side (xsim elaborates them as two tops instead).
module vl_top #(
  parameter int    NE    = 6,
  parameter int    NL    = 1,
  parameter string WMODE = "mid"
);
  tb_urf #(.NE(NE), .NL(NL), .WMODE(WMODE)) tb ();
  glbl glbl ();
endmodule
