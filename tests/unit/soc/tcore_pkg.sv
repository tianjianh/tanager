// KIND=tcore builds only: the two constants of the core's package that tanager_soc reads for the debug module
// (soc.md §9.4), standing in for rtl/core's tg_core_pkg as tcore_as_core.sv stands in for tg_core: the test core
// runs one thread as hart 0, and there is no hart 1.
package tg_core_pkg;
  import tg_pkg::*;
  localparam tid_t RUN_TID  = '0;
  localparam bit   HART1_ON = 1'b0;
endpackage
