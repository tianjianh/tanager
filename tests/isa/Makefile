# riscv-tests ISA suites in tg_vsim with lockstep (docs/spec/verification.md §4.1).
# Run on the build host (Ubuntu 24.04) after `source tools/env.sh`.
#   make -C tests/isa CFG=st [CORE=core|tcore] [SUITES="rv64ui-p rv64um-p"] [LAT=native] [SIMARGS=...]
#   make -C tests/isa replay [SUITES=all]       the same suites, Spike against Spike (tg_replay)
#   make -C tests/isa directed CFG=st [CORE=...] our directed tests (directed/*.S: interrupts, WFI)
#     [DIR_EXCL=<file>]                          leaving out the tests that file lists (exclude/directed-timing.txt)
CFG    ?= st
CORE   ?= core
SUITES ?= rv64ui-p rv64um-p rv64mi-p
LAT    ?= native
JOBS   ?= 8

# Command-line variables of this make (ISA, MARCH, ...) must not reach the sim build, where ISA
# means Spike's ISA: sub-makes get only what is passed to them explicitly.
MAKEOVERRIDES :=

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
include $(ROOT)/sim/profile.mk
EXCL := --exclude $(ROOT)/tests/isa/exclude/tanager.txt $(if $(filter tcore,$(CORE)),--exclude $(ROOT)/tests/isa/exclude/tcore.txt) \
        $(if $(wildcard $(ROOT)/tests/isa/exclude/$(CFG).txt),--exclude $(ROOT)/tests/isa/exclude/$(CFG).txt)

DIR_OUT := $(TANAGER_BUILD)/$(WT)/directed
DIR_SRC := $(wildcard $(ROOT)/tests/isa/directed/*.S)
DIR_ELF := $(patsubst $(ROOT)/tests/isa/directed/%.S,$(DIR_OUT)/tanager-p-%,$(DIR_SRC))

.PHONY: run replay directed build-directed
run:
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim CFG=$(CFG) CORE=$(CORE) $(TC_ARG) build
	python3 $(ROOT)/tests/isa/run_isa.py --sim $(TANAGER_BUILD)/$(WT)/sim/$(CFG)-$(CORE)$(TC_SUFFIX)/tg_vsim --suites "$(SUITES)" \
	  $(EXCL) --jobs $(JOBS) --logdir $(TANAGER_BUILD)/$(WT)/isa-logs/$(CFG)-$(CORE)$(TC_SUFFIX) --name "$(CFG) $(CORE)$(TC_SUFFIX)" -- --lat=$(LAT) $(SIMARGS)

replay:
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim replay
	python3 $(ROOT)/tests/isa/run_isa.py --replay $(TANAGER_BUILD)/$(WT)/sim/replay/tg_replay --suites "$(SUITES)" \
	  --exclude $(ROOT)/tests/isa/exclude/tanager.txt --jobs $(JOBS) --logdir $(TANAGER_BUILD)/$(WT)/isa-logs/replay \
	  --name replay $(if $(SIMARGS),-- $(SIMARGS))

build-directed: $(DIR_ELF)
$(DIR_OUT)/tanager-p-%: $(ROOT)/tests/isa/directed/%.S $(ROOT)/tests/isa/directed/tg_test.h $(ROOT)/tests/isa/directed/link.ld
	@mkdir -p $(DIR_OUT)
	riscv-none-elf-gcc -march=rv64im_zicsr -mabi=lp64 -nostdlib -nostartfiles -static -mcmodel=medany \
	  -T $(ROOT)/tests/isa/directed/link.ld -I$(ROOT)/tests/isa/directed $< -o $@

# Interrupt tests run with random external-interrupt pulses as well.
directed: build-directed
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim CFG=$(CFG) CORE=$(CORE) $(TC_ARG) build
	python3 $(ROOT)/tests/isa/run_isa.py --sim $(TANAGER_BUILD)/$(WT)/sim/$(CFG)-$(CORE)$(TC_SUFFIX)/tg_vsim --tests-dir $(DIR_OUT) \
	  --suites tanager-p $(if $(DIR_EXCL),--exclude $(DIR_EXCL)) --jobs $(JOBS) \
	  --logdir $(TANAGER_BUILD)/$(WT)/isa-logs/$(CFG)-$(CORE)$(TC_SUFFIX) \
	  --name "directed $(CFG) $(CORE)" -- --lat=$(LAT) --irq-rand=5 $(SIMARGS)
