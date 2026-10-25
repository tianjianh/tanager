# The debug module from JTAG to the harts (rtl/uncore/debug; docs/spec/soc.md §9.6): a TAP model, tg_dtm, tg_dm and
# two RV64I hart models that run the debug ROM. tb_jtag_dmi.svh, the debugger over JTAG, is tb_boot's too.
#   make -C tests/unit/dbg short
TOP := tb_dbg
TB  := $(CURDIR)/tb_jtag_tap.sv $(CURDIR)/tb_dbg_harts.sv $(CURDIR)/tb_dbg.sv
EXTRA_VFLAGS := -I$(CURDIR)
include ../common/unit.mk
$(OUTDIR)/$(TOP): $(CURDIR)/tb_jtag_dmi.svh
short:
	@$(MAKE) --no-print-directory run | grep -q "TEST PASSED" || { echo "FAIL dbg"; exit 1; }; echo "dbg: PASS"
long: short
