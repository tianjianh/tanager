# Host DMA bridge test (docs/spec/soc.md §8.1).  make -C tests/unit/hdma short | run SEED=n [REL=1]
# REL=1: the port as a release build without the trace has it (DR-180): no completions, no line counters.
TOP := tb_hdma
TB  := $(CURDIR)/tb_hdma.sv
REL ?= 0
NAME   := tb_hdma$(if $(filter 1,$(REL)),_rel)
PARAMS := -GREL=$(REL)
LONG_SEEDS := 1 2 3 4 5 6 7 8
LABEL      := hdma
include ../common/unit.mk
short:
	@for s in 1 2 3; do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "hdma seed $$s: PASS"; done
	@$(MAKE) --no-print-directory run SEED=4 REL=1 | grep -q "TEST PASSED" || { echo "FAIL REL=1"; exit 1; }; echo "hdma seed 4, the release form (DR-180): PASS"
long: long-seeds
