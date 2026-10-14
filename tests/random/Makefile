# Constrained-random programs in tg_vsim with lockstep (docs/spec/verification.md §6.2).
# Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make -C tests/random CFG=st [CORE=core|tcore] [N=100] [SEED=1] [ISA=rv64im] [IRQ=0] [STRESS=1] [SIMARGS=...]
#   make -C tests/random gen SEED=42 [ISA=...]     write one program to stdout
# Failures are kept (with a reproduction command) in $TANAGER_BUILD/<worktree>/random/<cfg>-<core>/failures.
CFG    ?= st
CORE   ?= core
N      ?= 100
SEED   ?= 1
ISA    ?= rv64im
IRQ    ?= 0
LENGTH ?= 300
STRESS ?= 1
JOBS   ?= 8

# Command-line variables of this make (ISA, MARCH, ...) must not reach the sim build, where ISA
# means Spike's ISA: sub-makes get only what is passed to them explicitly.
MAKEOVERRIDES :=

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
WORK := $(TANAGER_BUILD)/$(WT)/random/$(CFG)-$(CORE)
# Stressed seeds may also stall the trace when the core has trace_stall_i.
TRACE_STALL := $(shell $(MAKE) -s --no-print-directory -C $(ROOT)/sim CORE=$(CORE) print-trace-stall)

.PHONY: run gen
run:
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim CFG=$(CFG) CORE=$(CORE) build replay
	python3 $(ROOT)/tests/random/run_random.py --sim $(TANAGER_BUILD)/$(WT)/sim/$(CFG)-$(CORE)/tg_vsim \
	  --replay $(TANAGER_BUILD)/$(WT)/sim/replay/tg_replay --n $(N) --seed $(SEED) --isa $(ISA) --irq $(IRQ) \
	  --length $(LENGTH) $(if $(filter 1,$(STRESS)),--stress $(if $(filter 1,$(TRACE_STALL)),--trace-stall)) \
	  --jobs $(JOBS) --workdir $(WORK) \
	  --name "random $(CFG) $(CORE)" -- $(SIMARGS)

gen:
	@python3 $(ROOT)/tests/random/tg_rand.py --seed $(SEED) --isa $(ISA) --irq $(IRQ) --length $(LENGTH)
