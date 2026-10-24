# The debug module from JTAG to the harts (rtl/uncore/debug; docs/spec/soc.md §9.6): a TAP model, tg_dtm, tg_dm and
# two RV64I hart models that run the debug ROM.  make -C tests/unit/dbg short
TOP := tb_dbg
TB  := $(CURDIR)/tb_jtag_tap.sv $(CURDIR)/tb_dbg_harts.sv $(CURDIR)/tb_dbg.sv
include ../common/unit.mk
short:
	@$(MAKE) --no-print-directory run | grep -q "TEST PASSED" || { echo "FAIL dbg"; exit 1; }; echo "dbg: PASS"
long: short
