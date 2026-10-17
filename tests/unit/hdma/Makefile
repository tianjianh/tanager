# Host DMA bridge test (docs/spec/soc.md §8.1).  make -C tests/unit/hdma short | run SEED=n
TOP := tb_hdma
TB  := $(CURDIR)/tb_hdma.sv
LONG_SEEDS := 1 2 3 4 5 6 7 8
LABEL      := hdma
include ../common/unit.mk
short:
	@for s in 1 2 3; do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "hdma seed $$s: PASS"; done
long: long-seeds
