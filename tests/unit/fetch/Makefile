# Unit test of tg_fetch with two streams (rtl/core/frontend; M7's step 5b, docs/spec/threading.md): two harts' fetch
# under random flushes and decode redirects (some in one cycle for both), FENCE.I, I$ misses and the l1i's delays, each
# thread's instructions checked as decode takes them (tb_fetch.sv). smt2 with hart 1 (TG_HART1=1). Then the negatives,
# which must fail: every flush, or every decode redirect, given thread 0.
#   make -C tests/unit/fetch [CYCLES=200000] [SEED=1]
ROOT   := $(abspath ../../..)
ifeq ($(VERILATOR_ROOT),)
$(error source tools/env.sh first: the pinned Verilator is needed)
endif
CYCLES ?= 200000
SEED   ?= 1
OBJ    ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))/unit_fetch
VFLAGS := --binary --assert --timing -Wno-fatal -Wno-lint -Wno-style -Wno-MULTITOP -j 8 --top-module tb_fetch \
          -I$(ROOT)/rtl/common +define+TG_HART1=1
SRCS   := $(ROOT)/rtl/common/cfg/tg_cfg_smt2.sv -F $(ROOT)/rtl/common/common.f -F $(ROOT)/rtl/core/core.f tb_fetch.sv
# name  define
SHAPES := two:
NEGS   := neg-flush:TB_FLUSH_TID0 neg-dred:TB_DRED_TID0

define run_shape
  n=$$(echo $(1) | cut -d: -f1); def=$$(echo $(1) | cut -d: -f2); o=$(OBJ)/$$n; mkdir -p $$o; \
  verilator $(VFLAGS) --Mdir $$o -GCYCLES=$(CYCLES) -GSEED=$(SEED) $${def:+ +define+$$def} $(SRCS) \
    > $$o/build.log 2>&1 || { tail -20 $$o/build.log; exit 1; }; \
  $$o/Vtb_fetch > $$o/run.log 2>&1 || true
endef

.PHONY: all neg
all:
	@set -e; for s in $(SHAPES); do \
	  $(call run_shape,$$s); \
	  grep -q "TB_FETCH PASS" $$o/run.log || { echo "$$n: FAIL (log: $$o/run.log)"; \
	    grep -E "TB_FETCH|MISMATCH|Error" $$o/run.log | head -8; exit 1; }; \
	  echo "$$n: $$(grep "TB_FETCH PASS" $$o/run.log)"; \
	done
	@echo "tg_fetch unit test: PASS"
neg:
	@set -e; for s in $(NEGS); do \
	  $(call run_shape,$$s); \
	  grep -q -E "TB_FETCH FAIL|Assertion failed|Error" $$o/run.log || { echo "negative $$n: did not fail (log: $$o/run.log)"; exit 1; }; \
	  echo "negative $$n ($$def): fails, as it must ($$(grep -o -m1 -E "[0-9]* mismatches|Assertion failed.*" $$o/run.log | cut -c1-110))"; \
	done
