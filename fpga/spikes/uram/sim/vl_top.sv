// The top of tb_urf for Verilator runs with the vendor's URAM288_BASE model, which refers to glbl.GSR: the
// testbench and glbl side by side (xsim elaborates them as two tops instead).
module vl_top;
  tb_urf tb ();
  glbl glbl ();
endmodule
