# Unit test of tg_tlb (rtl/core/mmu) with two threads' entries (M7's step 4; docs/spec/threading.md): random lookups,
# fills and per-hart flushes against a model of each thread's pages (tb_tlb.sv). Shapes: the DTLB's (CAM, 32 entries,
# 3 lookups, EARLY ports 0 and 1, and none), the ITLB's (flip-flops, 16 entries, 1 lookup). smt2 (two threads).
# Then the negatives, which must fail: every lookup given thread 0, every fill given thread 0.
#   make -C tests/unit/tlb [CYCLES=100000] [SEED=1]
ROOT   := $(abspath ../../..)
ifeq ($(VERILATOR_ROOT),)
$(error source tools/env.sh first: the pinned Verilator is needed)
endif
CYCLES ?= 100000
SEED   ?= 1
OBJ    ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))/unit_tlb
PKGS   := $(addprefix $(ROOT)/rtl/common/,tg_pkg.sv tg_tl_pkg.sv tg_fpu_pkg.sv tg_trace_pkg.sv tg_map_pkg.sv \
            prim/tg_ram_lut.sv) $(ROOT)/rtl/core/exec/tg_alu_pkg.sv $(ROOT)/rtl/core/tg_core_pkg.sv
SRC    := $(ROOT)/rtl/core/mmu/tg_tlb.sv tb_tlb.sv
VFLAGS := --binary --assert -Wno-fatal -Wno-lint -Wno-style -j 8 --top-module tb_tlb -I$(ROOT)/rtl/common
# name  NE  NR  CAM  EARLY  define
SHAPES := dtlb-early:32:3:1:3: dtlb-now:32:3:1:0: itlb:16:1:0:0:
NEGS   := neg-lktid:32:3:1:3:TB_LKTID0 neg-filltid:16:1:0:0:TB_FILLTID0

define run_shape
  n=$$(echo $(1) | cut -d: -f1); ne=$$(echo $(1) | cut -d: -f2); nr=$$(echo $(1) | cut -d: -f3); \
  cam=$$(echo $(1) | cut -d: -f4); er=$$(echo $(1) | cut -d: -f5); def=$$(echo $(1) | cut -d: -f6); \
  o=$(OBJ)/$$n; mkdir -p $$o; \
  verilator $(VFLAGS) --Mdir $$o -GNE=$$ne -GNR=$$nr -GCAM=$$cam -GEARLYN=$$er -GCYCLES=$(CYCLES) -GSEED=$(SEED) \
    $${def:+ +define+$$def} $(ROOT)/rtl/common/cfg/tg_cfg_smt2.sv $(PKGS) $(SRC) > $$o/build.log 2>&1 \
    || { tail -20 $$o/build.log; exit 1; }; \
  $$o/Vtb_tlb > $$o/run.log 2>&1 || true
endef

.PHONY: all neg
all:
	@set -e; for s in $(SHAPES); do \
	  $(call run_shape,$$s); \
	  grep -q "TB_TLB PASS" $$o/run.log || { echo "$$n: FAIL (log: $$o/run.log)"; \
	    grep -E "TB_TLB|MISMATCH|Error" $$o/run.log | head -5; exit 1; }; \
	  echo "$$n (NE $$ne, NR $$nr, CAM $$cam, EARLY $$er): $$(grep "TB_TLB PASS" $$o/run.log)"; \
	done
	@$(MAKE) --no-print-directory neg
	@echo "tg_tlb unit test: PASS"

neg:
	@set -e; for s in $(NEGS); do \
	  $(call run_shape,$$s); \
	  grep -q -E "TB_TLB FAIL|Assertion failed" $$o/run.log || { echo "negative $$n: did not fail (log: $$o/run.log)"; exit 1; }; \
	  echo "negative $$n ($$def): fails, as it must ($$(grep -o -m1 -E "[0-9]* mismatches|Assertion failed.*" $$o/run.log | cut -c1-100))"; \
	done
