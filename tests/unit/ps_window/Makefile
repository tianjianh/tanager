# The PS window alone (rtl/uncore/ps/tg_ps_window.sv; docs/spec/soc.md §8.2, docs/spec/soc-d4-modes.md): directed
# cycle-exact cases, the board's reset included.  make -C tests/unit/ps_window short
TOP := tb_ps_window
TB  := $(CURDIR)/tb_ps_window.sv
include ../common/unit.mk
short:
	@$(MAKE) --no-print-directory run | grep -q "TEST PASSED" || { echo "FAIL ps_window"; exit 1; }; echo "ps_window: PASS"
long: short
