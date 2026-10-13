# L2 bank random test (docs/spec/l2.md §Verification).
#   make -C tests/unit/l2 short            1 agent, 3 seeds x 20k ops (M4 configuration)
#   make -C tests/unit/l2 long             1, 2 and 4 agents, 10 seeds x 100k ops
#   make -C tests/unit/l2 run NA=2 SEED=7 OPS=50000
TOP    := tb_l2
NA     ?= 1
MSHR   ?= 8
NAME   := l2_na$(NA)_m$(MSHR)
TB     := $(CURDIR)/tb_l2.sv
PARAMS := -GNA=$(NA) -GN_MSHR=$(MSHR)
OPS    ?= 20000
ARGS   = +ops=$(OPS)
include ../common/unit.mk

short:
	@for s in 1 2 3; do $(MAKE) --no-print-directory run NA=1 SEED=$$s OPS=20000 | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "l2 NA=1 seed $$s: PASS"; done

long:
	@for na in 1 2 4; do for s in 1 2 3 4 5 6 7 8 9 10; do \
	  $(MAKE) --no-print-directory run NA=$$na SEED=$$s OPS=100000 | grep -q "TEST PASSED" || { echo "FAIL NA=$$na seed $$s"; exit 1; }; \
	  echo "l2 NA=$$na seed $$s: PASS"; done; done
