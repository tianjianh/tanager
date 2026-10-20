# RVWMO litmus tests (litmus-tests-riscv) on Tanager (docs/spec/verification.md §6.6; plan §9; the M7 plan's exit 4).
# Run on the build host after `source tools/env.sh`. The suite is a checkout of its own, only read:
#   git clone https://github.com/litmus-tests/litmus-tests-riscv $(LITMUS); git -C $(LITMUS) checkout 08728ed
#   make -C tests/litmus [CFG=st|smt2] [HARTS=...] [LAT=board] [ITERS=100] [FAMILY=SAFE,CO] [SAMPLE=N]   the SoC (tb_boot)
#   make -C tests/litmus replay [HARTS=0,1|0,1,2,3] [ITERS=100]    Spike against Spike: the harness's own check
#   make -C tests/litmus vsim CFG=smt2 HARTS=0,1                  one core's two threads (tg_vsim; M7, once hart 1 fetches)
# HARTS: the harts that run a test's threads, in order: 0,1 is one thread of each of two st cores, 0,2 the same on
# smt2 cores (hart 1 does not fetch until M7's step 5), 0,1 under vsim the two threads of one smt2 core, 0,1,2,3 all
# four. A test with more threads than HARTS is left out. LAT is tb_boot's DDR timing (run_litmus.py --lat).
# Failing batches are kept, with a command that reruns them, in $TANAGER_BUILD/<worktree>/litmus/<run>/failures.
LITMUS   ?= $(HOME)/src/tanager/litmus-tests-riscv
LITMUS_REV := 08728ed
CFG      ?= st
comma    := ,
HARTS    ?= $(if $(filter smt2%,$(CFG)),0$(comma)2,0$(comma)1)
ITERS    ?= 100
BATCH    ?= 20
LAT      ?= board
FAMILY   ?=
SAMPLE   ?= 0
SEED     ?= 1
JOBS     ?= 6
L2_SETS  ?= 1024

MAKEOVERRIDES :=

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
include $(ROOT)/sim/profile.mk
L2TAG := $(if $(filter 64,$(L2_SETS)),,_l2s$(L2_SETS))
TB    := $(TANAGER_BUILD)/$(WT)/tests/boot$(L2TAG)$(TC_SUFFIX)_c2_t1_$(CFG)/tb_boot
RUN   := python3 $(ROOT)/tests/litmus/run_litmus.py --suite $(LITMUS) --harts $(HARTS) --iters $(ITERS) --batch $(BATCH) \
         --seed $(SEED) --jobs $(JOBS) $(if $(FAMILY),--family $(FAMILY)) $(if $(filter-out 0,$(SAMPLE)),--sample $(SAMPLE))
HSFX  := h$(subst $(comma),,$(HARTS))

.PHONY: run replay vsim check-suite
run: check-suite
	@$(MAKE) --no-print-directory -s -C $(ROOT)/tests/unit/boot build CFG=$(CFG) CORES=2 VTHREADS=1 JOBS=$(JOBS) $(TC_ARG) \
	  $(if $(L2TAG),TAG=$(L2TAG) MEM_PARAMS="-GL2_SETS_TB=$(L2_SETS)")
	$(RUN) --tb $(TB) --lat $(LAT) --workdir $(TANAGER_BUILD)/$(WT)/litmus/$(CFG)$(TC_SUFFIX)-$(HSFX) \
	  --name "litmus $(CFG)$(TC_SUFFIX), harts $(HARTS), $(LAT) timing"

replay: check-suite
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim replay
	$(RUN) --replay $(TANAGER_BUILD)/$(WT)/sim/replay/tg_replay --workdir $(TANAGER_BUILD)/$(WT)/litmus/replay-$(HSFX) \
	  --name "litmus, Spike against Spike, harts $(HARTS)"

vsim: check-suite
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim CFG=$(CFG) CORE=core $(TC_ARG) build
	$(RUN) --vsim $(TANAGER_BUILD)/$(WT)/sim/$(CFG)-core$(TC_SUFFIX)/tg_vsim \
	  --workdir $(TANAGER_BUILD)/$(WT)/litmus/vsim-$(CFG)$(TC_SUFFIX)-$(HSFX) --name "litmus, tg_vsim $(CFG), harts $(HARTS)"

check-suite:
	@test -f $(LITMUS)/model-results/herd.logs || { echo "no litmus-tests-riscv at $(LITMUS) (see the top of this Makefile)"; exit 2; }
	@rev=$$(git -C $(LITMUS) rev-parse --short=7 HEAD 2>/dev/null); [ "$$rev" = $(LITMUS_REV) ] || \
	  echo "warning: $(LITMUS) is at $$rev, the results here are for $(LITMUS_REV)"
