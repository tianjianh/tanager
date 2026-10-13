# riscv-tests ISA suites in tg_vsim with lockstep (docs/spec/verification.md §4.1).
# Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make -C tests/isa CFG=st [CORE=core|tcore] [SUITES="rv64ui-p rv64um-p"] [LAT=native] [SIMARGS=...]
#   make -C tests/isa replay [SUITES=all]       the same suites, Spike against Spike (tg_replay)
CFG    ?= st
CORE   ?= core
SUITES ?= rv64ui-p rv64um-p rv64mi-p
LAT    ?= native
JOBS   ?= 8

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
EXCL := --exclude $(ROOT)/tests/isa/exclude/tanager.txt $(if $(filter tcore,$(CORE)),--exclude $(ROOT)/tests/isa/exclude/tcore.txt) \
        $(if $(wildcard $(ROOT)/tests/isa/exclude/$(CFG).txt),--exclude $(ROOT)/tests/isa/exclude/$(CFG).txt)

.PHONY: run replay
run:
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim CFG=$(CFG) CORE=$(CORE) build
	python3 $(ROOT)/tests/isa/run_isa.py --sim $(TANAGER_BUILD)/$(WT)/sim/$(CFG)-$(CORE)/tg_vsim --suites "$(SUITES)" \
	  $(EXCL) --jobs $(JOBS) --logdir $(TANAGER_BUILD)/$(WT)/isa-logs/$(CFG)-$(CORE) --name "$(CFG) $(CORE)" -- --lat=$(LAT) $(SIMARGS)

replay:
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim replay
	python3 $(ROOT)/tests/isa/run_isa.py --replay $(TANAGER_BUILD)/$(WT)/sim/replay/tg_replay --suites "$(SUITES)" \
	  --exclude $(ROOT)/tests/isa/exclude/tanager.txt --jobs $(JOBS) --logdir $(TANAGER_BUILD)/$(WT)/isa-logs/replay \
	  --name replay $(if $(SIMARGS),-- $(SIMARGS))
