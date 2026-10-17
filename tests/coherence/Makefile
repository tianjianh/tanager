# Coherence programs on the two-core SoC (docs/spec/verification.md §6.5): gen_coh's harts contend for
# cache lines with AMOs and LR/SC loops, all leaving the boot ROM in the same cycle, as OpenSBI's boot
# lottery does on the board. Each program checks itself, the cycle limit catches a hang, and
# tanager-lockstep checks every hart against Spike.
# Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make -C tests/coherence [CFG=st|smt2] [N=40] [SEED=1] [MODES=lottery,amo] [LAT=default] [LOCKSTEP=1]
#   make -C tests/coherence gen SEED=1 [MODE=lottery] [HARTS=0,1]    one program to stdout
# CFG=st runs harts 0 and 1 (two cores); smt2 runs harts 0 and 2, thread 0 of each core, which is the
# board's shape (smt2 cores run one thread until M7). LAT=fixed|jitter|board sets the DDR timing (18-26
# cycles; run_coh.py) and needs tb_boot's DDR options (soc-2's 8882e79). MODES=mix,lrsc,lottery-lrsc add
# LR/SC loops, which hang on today's RTL: two harts in the same constrained loop never leave it.
# Failures are kept, with a line that reproduces them, in $TANAGER_BUILD/<worktree>/coherence/<cfg>/failures.
CFG      ?= st
N        ?= 40
SEED     ?= 1
MODES    ?= lottery,amo
MODE     ?= lottery
LAT      ?= default
LOCKSTEP ?= 1
JOBS     ?= 6
comma    := ,
HARTS    ?= $(if $(filter smt2%,$(CFG)),0$(comma)2,0$(comma)1)

MAKEOVERRIDES :=

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
include $(ROOT)/sim/profile.mk
TB   := $(TANAGER_BUILD)/$(WT)/tests/boot$(TC_SUFFIX)_c2_t1_$(CFG)/tb_boot
LS   := $(TANAGER_BUILD)/$(WT)/sim/lockstep/tanager-lockstep
WORK := $(TANAGER_BUILD)/$(WT)/coherence/$(CFG)$(TC_SUFFIX)

.PHONY: run gen
run:
	@$(MAKE) --no-print-directory -s -C $(ROOT)/tests/unit/boot build CFG=$(CFG) CORES=2 VTHREADS=1 JOBS=$(JOBS) $(TC_ARG)
	$(if $(filter 1,$(LOCKSTEP)),@$(MAKE) --no-print-directory -s -C $(ROOT)/sim lockstep)
	python3 $(ROOT)/tests/coherence/run_coh.py --tb $(TB) $(if $(filter 1,$(LOCKSTEP)),--lockstep $(LS)) \
	  --harts $(HARTS) --modes $(MODES) --lat $(LAT) --max-mcycles 1 --n $(N) --seed $(SEED) --jobs $(JOBS) \
	  --workdir $(WORK) --name "coherence $(CFG)$(TC_SUFFIX)"

gen:
	@python3 $(ROOT)/tests/coherence/gen_coh.py --seed $(SEED) --mode $(MODE) --harts $(HARTS)
