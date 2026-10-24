// KIND=tcore builds only: the core package's constant that tanager_soc reads for the debug module (soc.md §9.4),
// standing in for rtl/core's tg_core_pkg as tcore_as_core.sv stands in for tg_core: the test core has no hart 1.
package tg_core_pkg;
  localparam bit HART1_ON = 1'b0;
endpackage
