// Puts the commit-trace tap into every tanager_soc (docs/spec/verification.md §4.7). Only the long-boot
// lockstep check compiles it, after the SoC sources and tg_soc_tap.sv, into tb_boot; it uses only
// tanager_soc's ports (soc.md §1), so no testbench changes.
bind tanager_soc tg_soc_tap #(.N_CORES(N_CORES)) u_tg_soc_tap (
  .clk        (clk),
  .rst        (rst),
  .trace      (trace_o),
  .trace_v    (trace_valid_o),
  .trace_wb   (trace_wb_o),
  .trace_wb_v (trace_wb_valid_o)
);
