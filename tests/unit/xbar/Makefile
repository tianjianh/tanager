# Interconnect test (docs/spec/uncore.md).  make -C tests/unit/xbar short | run SEED=n [SLICE=1]
# SLICE=1: the crossbar's register slices on (tg_xbar SLICE), in a directory of its own; off by default, as
# tg_uncore builds the crossbar since DR-186
TOP    := tb_xbar
TB     := $(CURDIR)/tb_xbar.sv
SLICE  ?= 0
NAME   := tb_xbar$(if $(filter 1,$(SLICE)),_slice)
PARAMS := -GSLICE_TB=$(SLICE)
LONG_SEEDS := 1 2 3 4 5 6 7 8 9 10 11 12
LABEL      := xbar
include ../common/unit.mk
short:
	@for s in 1 2 3; do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "xbar seed $$s: PASS"; done
	@for s in 1 2; do $(MAKE) --no-print-directory run SEED=$$s SLICE=1 | grep -q "TEST PASSED" || { echo "FAIL seed $$s SLICE=1"; exit 1; }; echo "xbar seed $$s with the slices: PASS"; done
long: long-seeds
