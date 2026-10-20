# Constrained-random programs in tg_vsim with lockstep (docs/spec/verification.md §6.2).
# Run on the build host (Ubuntu 24.04) after `source tools/env.sh`.
#   make -C tests/random CFG=st [CORE=core|tcore] [N=100] [SEED=1] [ISA=rv64im] [IRQ=0] [STRESS=1] [MISS=2] [SIMARGS=...]
#   make -C tests/random replay ISA=rv64gc [N=100] [SEED=1]   Spike against Spike only (ISAs no core runs yet)
#   make -C tests/random gen SEED=42 [ISA=...]     write one program to stdout
#   HARTS=0,1 [SHARED=3]: M7's several harts, each a program of its own (tg_rand --harts; the A extension):
#   with run, the two threads of an smt2 core (CFG=smt2); with replay, Spike's harts
# Failures are kept (with a reproduction command) in $TANAGER_BUILD/<worktree>/random/<cfg>-<core>/failures.
CFG    ?= st
CORE   ?= core
N      ?= 100
SEED   ?= 1
ISA    ?= rv64im
IRQ    ?= 0
LENGTH ?= 300
STRESS ?= 1
MISS   ?= 2   # weight of tg_rand's miss-burst template (DR-149); 12 makes misses in flight most of the program
JOBS   ?= 8
HARTS  ?= 0
SHARED ?= 0
MH     := $(if $(filter-out 0,$(HARTS)),--harts $(HARTS) --shared $(SHARED))
MHSFX  := $(if $(filter-out 0,$(HARTS)),-h$(subst $(comma),,$(HARTS)))
comma  := ,

# Command-line variables of this make (ISA, MARCH, ...) must not reach the sim build, where ISA
# means Spike's ISA: sub-makes get only what is passed to them explicitly.
MAKEOVERRIDES :=

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
include $(ROOT)/sim/profile.mk
WORK := $(TANAGER_BUILD)/$(WT)/random/$(CFG)-$(CORE)$(TC_SUFFIX)$(MHSFX)

.PHONY: run replay gen
run:
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim CFG=$(CFG) CORE=$(CORE) $(TC_ARG) build replay
	python3 $(ROOT)/tests/random/run_random.py --sim $(TANAGER_BUILD)/$(WT)/sim/$(CFG)-$(CORE)$(TC_SUFFIX)/tg_vsim \
	  --replay $(TANAGER_BUILD)/$(WT)/sim/replay/tg_replay --n $(N) --seed $(SEED) --isa $(ISA) --irq $(IRQ) \
	  --length $(LENGTH) --miss $(MISS) $(MH) $(if $(filter 1,$(STRESS)),--stress --trace-stall) \
	  --jobs $(JOBS) --workdir $(WORK) \
	  --name "random $(CFG) $(CORE)" -- $(SIMARGS)

replay:
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim replay
	python3 $(ROOT)/tests/random/run_random.py --replay-only --replay $(TANAGER_BUILD)/$(WT)/sim/replay/tg_replay \
	  --n $(N) --seed $(SEED) --isa $(ISA) --irq $(IRQ) --length $(LENGTH) $(MH) --jobs $(JOBS) \
	  --workdir $(TANAGER_BUILD)/$(WT)/random/replay-$(ISA)$(MHSFX) --name "random $(ISA), Spike against Spike" -- $(SIMARGS)

gen:
	@python3 $(ROOT)/tests/random/tg_rand.py --seed $(SEED) --isa $(ISA) --irq $(IRQ) --length $(LENGTH) $(MH)
