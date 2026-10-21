# Unit test of tg_freelist (rtl/core/rename), the per-thread free lists of one register bank (M7's D3, docs/spec/
# threading.md), against a model of each thread's list (tb_freelist.sv). Shapes: merged mode (the one running thread,
# RUN_TID 0 and 1 with SOLO_TID) with a bank's homes (FIRST 32) and without (FIRST 0), split mode (both threads, with
# transfers) with and without homes, hart 1's homes in banks 1 and 2 (FIRST_S 16 and 15: thread 1's share odd), the
# FP banks of 96 (pointers wrapping at a non-power of two), and st (one thread). Then the negatives, which must fail
# (a mismatch, or tg_freelist's own assertion stopping the run): the flush or the pops given thread 0, and the
# transfers' thread flipped.
#   make -C tests/unit/freelist [CYCLES=200000] [SEED=1]
ROOT   := $(abspath ../../..)
ifeq ($(VERILATOR_ROOT),)
$(error source tools/env.sh first: the pinned Verilator is needed)
endif
CYCLES ?= 200000
SEED   ?= 1
OBJ    ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))/unit_freelist
PKGS   := $(addprefix $(ROOT)/rtl/common/,tg_pkg.sv tg_tl_pkg.sv tg_fpu_pkg.sv tg_trace_pkg.sv tg_map_pkg.sv \
            prim/tg_ram_lut.sv) $(ROOT)/rtl/core/exec/tg_alu_pkg.sv $(ROOT)/rtl/core/tg_core_pkg.sv
SRC    := $(ROOT)/rtl/core/rename/tg_freelist.sv tb_freelist.sv
VFLAGS := --binary --assert -Wno-fatal -Wno-lint -Wno-style -j 8 --top-module tb_freelist -I$(ROOT)/rtl/common
# name  cfg  solo  split  first  first_s  depth  defines
SHAPES := m32-t0:smt2:0:0:32:32:64: m0-t0:smt2:0:0:0:0:64: m32-t1:smt2:1:0:32:32:64: m0-t1:smt2:1:0:0:0:64: \
          s32:smt2:0:1:32:32:64: s0:smt2:0:1:0:0:64: s32-solo:smt2:1:1:32:32:64: s16:smt2:0:1:0:16:64: \
          s15:smt2:0:1:0:15:64: s96:smt2:0:1:32:32:96: m96:smt2:0:0:32:32:96: m96-0:smt2:0:0:0:0:96: st32:st:0:0:32:32:64:
NEGS   := s32-neg-flush:smt2:0:1:32:32:64:TB_FLUSH_TID0 s32-neg-pop:smt2:0:1:32:32:64:TB_POP_TID0 \
          s96-neg-want:smt2:0:1:32:32:96:TB_WANT_FLIP

define run_shape
  n=$$(echo $(1) | cut -d: -f1); cfg=$$(echo $(1) | cut -d: -f2); solo=$$(echo $(1) | cut -d: -f3); \
  split=$$(echo $(1) | cut -d: -f4); first=$$(echo $(1) | cut -d: -f5); fs=$$(echo $(1) | cut -d: -f6); \
  depth=$$(echo $(1) | cut -d: -f7); def=$$(echo $(1) | cut -d: -f8); o=$(OBJ)/$$n; mkdir -p $$o; \
  verilator $(VFLAGS) --Mdir $$o -GSPLIT_L=$$split -GFIRST=$$first -GFIRST_S=$$fs -GDEPTH=$$depth -GCYCLES=$(CYCLES) \
    -GSEED=$(SEED) \
    $$( [ $$solo = 1 ] && echo +define+TG_SOLO_TID=1 ) $${def:+ +define+$$def} \
    $(ROOT)/rtl/common/cfg/tg_cfg_$$cfg.sv $(PKGS) $(SRC) > $$o/build.log 2>&1 || { tail -20 $$o/build.log; exit 1; }; \
  $$o/Vtb_freelist > $$o/run.log 2>&1 || true
endef

.PHONY: all neg
all:
	@set -e; for s in $(SHAPES); do \
	  $(call run_shape,$$s); \
	  grep -q "TB_FREELIST PASS" $$o/run.log || { echo "$$n: FAIL (log: $$o/run.log)"; \
	    grep -E "TB_FREELIST|MISMATCH|Error" $$o/run.log | head -5; exit 1; }; \
	  echo "$$n ($$cfg, SOLO_TID=$$solo, split $$split, first $$first/$$fs, depth $$depth): $$(grep "TB_FREELIST PASS" $$o/run.log)"; \
	done
	@$(MAKE) --no-print-directory neg
	@echo "tg_freelist unit test: PASS"

neg:
	@set -e; for s in $(NEGS); do \
	  $(call run_shape,$$s); \
	  grep -q -E "TB_FREELIST FAIL|Assertion failed" $$o/run.log || { echo "negative $$n: did not fail (log: $$o/run.log)"; exit 1; }; \
	  echo "negative $$n ($$def): fails, as it must ($$(grep -o -m1 -E "[0-9]* mismatches|Assertion failed.*" $$o/run.log | cut -c1-110))"; \
	done
