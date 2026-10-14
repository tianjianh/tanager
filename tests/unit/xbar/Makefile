# Interconnect test (docs/spec/uncore.md).  make -C tests/unit/xbar short | run SEED=n
TOP := tb_xbar
TB  := $(CURDIR)/tb_xbar.sv
include ../common/unit.mk
short:
	@for s in 1 2 3; do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "xbar seed $$s: PASS"; done
long:
	@for s in $$(seq 1 12); do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "xbar seed $$s: PASS"; done
