# Coherence programs on the two-core SoC (docs/spec/verification.md §6.5): gen_coh's harts contend for
# cache lines with AMOs and LR/SC loops, all leaving the boot ROM in the same cycle, as OpenSBI's boot
# lottery does on the board. Each program checks itself, the cycle limit catches a hang, and
# tanager-lockstep checks every hart against Spike.
# Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make -C tests/coherence [CFG=st|smt2] [N=40] [SEED=1] [MODES=lottery,amo,mix,lrsc,lottery-lrsc,mp,race] [LAT=default]
#                           [LOCKSTEP=1] [L2_SETS=1024]
#   make -C tests/coherence gen SEED=1 [MODE=lottery] [HARTS=0,1]    one program to stdout
#   make -C tests/coherence prog SEED=1 [MODE=lottery] [HARTS=0,1]   one program built for tb_boot's +fw
# CFG=st runs harts 0 and 1 (two cores); smt2 runs harts 0 and 2, thread 0 of each core, which is the
# board's shape (smt2 cores run one thread until M7). LAT=fixed|jitter|board sets the DDR timing (18-26
# cycles; run_coh.py) and needs tb_boot's DDR options (soc-2's 8882e79). The mix, lrsc and lottery-lrsc
# modes run LR/SC loops, which need the L1D's hold of a young LR reservation (a0631fb): without it two
# harts in the same constrained loop never leave it.
# L2_SETS is the L2's sets in tb_boot (L2_SETS_TB): the board's 1024 by default, as tanager_soc builds it
# for the KV260; 64 is tb_boot's own default, which the boot test keeps. Each count other than 64 builds
# tb_boot in a directory of its own (the boot test's TAG).
# Failures are kept, with a line that reproduces them, in $TANAGER_BUILD/<worktree>/coherence/<cfg>/failures.
CFG      ?= st
N        ?= 40
SEED     ?= 1
MODES    ?= lottery,amo,mix,lrsc,lottery-lrsc,mp,race
MODE     ?= lottery
LAT      ?= default
LOCKSTEP ?= 1
JOBS     ?= 6
L2_SETS  ?= 1024
comma    := ,
HARTS    ?= $(if $(filter smt2%,$(CFG)),0$(comma)2,0$(comma)1)

MAKEOVERRIDES :=

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
include $(ROOT)/sim/profile.mk
L2TAG := $(if $(filter 64,$(L2_SETS)),,_l2s$(L2_SETS))
TB   := $(TANAGER_BUILD)/$(WT)/tests/boot$(L2TAG)$(TC_SUFFIX)_c2_t1_$(CFG)/tb_boot
LS   := $(TANAGER_BUILD)/$(WT)/sim/lockstep/tanager-lockstep
WORK := $(TANAGER_BUILD)/$(WT)/coherence/$(CFG)$(TC_SUFFIX)

PROG := $(WORK)/prog/c$(SEED)-$(MODE)-h$(subst $(comma),,$(HARTS))

.PHONY: run gen prog
run:
	@$(MAKE) --no-print-directory -s -C $(ROOT)/tests/unit/boot build CFG=$(CFG) CORES=2 VTHREADS=1 JOBS=$(JOBS) $(TC_ARG) \
	  $(if $(L2TAG),TAG=$(L2TAG) MEM_PARAMS=-GL2_SETS_TB=$(L2_SETS))
	$(if $(filter 1,$(LOCKSTEP)),@$(MAKE) --no-print-directory -s -C $(ROOT)/sim lockstep)
	python3 $(ROOT)/tests/coherence/run_coh.py --tb $(TB) $(if $(filter 1,$(LOCKSTEP)),--lockstep $(LS)) \
	  --harts $(HARTS) --modes $(MODES) --lat $(LAT) --max-mcycles 1 --n $(N) --seed $(SEED) --jobs $(JOBS) \
	  --workdir $(WORK) --name "coherence $(CFG)$(TC_SUFFIX), L2 $(L2_SETS) sets"

gen:
	@python3 $(ROOT)/tests/coherence/gen_coh.py --seed $(SEED) --mode $(MODE) --harts $(HARTS)

prog:
	@mkdir -p $(dir $(PROG))
	@python3 $(ROOT)/tests/coherence/gen_coh.py --seed $(SEED) --mode $(MODE) --harts $(HARTS) -o $(PROG).S
	@riscv-none-elf-gcc -march=rv64imac_zicsr -mabi=lp64 -nostdlib -nostartfiles -static -mcmodel=medany \
	  -Wl,--no-warn-rwx-segments -T $(ROOT)/tests/coherence/link.ld $(PROG).S -o $(PROG).elf
	@riscv-none-elf-objcopy -O binary $(PROG).elf $(PROG).bin
	@echo "$(PROG).bin: run it with tb_boot (CORES=2) +fw=$(PROG).bin +expect=COH-END +mem_zero"
