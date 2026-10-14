# Interconnect test (docs/spec/uncore.md).  make -C tests/unit/xbar short | run SEED=n
TOP := tb_xbar
TB  := $(CURDIR)/tb_xbar.sv
LONG_SEEDS := 1 2 3 4 5 6 7 8 9 10 11 12
LABEL      := xbar
include ../common/unit.mk
short:
	@for s in 1 2 3; do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "xbar seed $$s: PASS"; done
long: long-seeds
