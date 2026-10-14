# MMIO peripheral tests (docs/spec/uncore-periph.md).  make -C tests/unit/periph short | run SEED=n
TOP := tb_periph
TB  := $(CURDIR)/tb_periph.sv
LONG_SEEDS := 1 2 3 4 5 6 7 8
LABEL      := periph
include ../common/unit.mk
short:
	@for s in 1 2; do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "periph seed $$s: PASS"; done
long: long-seeds
