# DRAM window test (docs/spec/uncore-mem.md).  make -C tests/unit/axi_window short | run SEED=n
TOP := tb_axi_window
TB  := $(CURDIR)/tb_axi_window.sv
include ../common/unit.mk
short:
	@for s in 1 2; do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "axi_window seed $$s: PASS"; done
long: short
