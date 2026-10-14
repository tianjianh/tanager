# riscv-arch-test (ACT4) on Tanager (docs/spec/verification.md §6.1).
# Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make -C tests/arch CFG=st CORE=tcore [ACTCFG=...] [SIMARGS=...]   build the ELFs and run them in tg_vsim
#   make -C tests/arch elfs ACTCFG=...                                 build the ELFs only (Sail runs here)
#   make -C tests/arch replay ACTCFG=...                               run them Spike against Spike (tg_replay)
#   make -C tests/arch clean
# A test passes when its self-check (expected values from Sail) passes and lockstep passes.
# Work trees: $TANAGER_BUILD/<worktree>/arch/<ACTCFG>/{tests,elfs}; the riscv-arch-test checkout is only read.

CFG    ?= st
CORE   ?= tcore
JOBS   ?= 8
ACTCFG ?= $(if $(filter tcore,$(CORE)),tcore-rv64im,core-m2-rv64im)

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
TANAGER_OPT   ?= $(HOME)/opt/tanager
ARCH_TEST ?= $(HOME)/src/tanager/riscv-arch-test
VENV := $(TANAGER_OPT)/act-venv
WORK := $(TANAGER_BUILD)/$(WT)/arch
TESTS := $(WORK)/$(ACTCFG)/tests
CONFIG := $(ROOT)/tests/arch/config/$(ACTCFG)/test_config.yaml
export BUNDLE_PATH := $(TANAGER_OPT)/act-gems

# Command-line variables of this make must not reach the sim build (see tests/random/Makefile).
MAKEOVERRIDES :=

# Test suites generated from ACT4's testplans for this configuration: the `# testgen:` line of its
# test_config.yaml (the other privileged suites are committed upstream and copied).
GEN_EXT := $(shell sed -n 's/^\# testgen: //p' $(CONFIG))

.PHONY: run elfs tests replay clean
run: elfs
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim CFG=$(CFG) CORE=$(CORE) build
	python3 $(ROOT)/tests/arch/run_arch.py --sim $(TANAGER_BUILD)/$(WT)/sim/$(CFG)-$(CORE)/tg_vsim \
	  --elfs $(WORK)/$(ACTCFG)/elfs --exclude $(ROOT)/tests/arch/exclude/$(ACTCFG).txt --jobs $(JOBS) \
	  --logdir $(WORK)/logs/$(ACTCFG)-$(CFG)-$(CORE) --name "ACT4 $(ACTCFG) on $(CFG) $(CORE)" -- $(SIMARGS)

replay: elfs
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim replay
	python3 $(ROOT)/tests/arch/run_arch.py --sim $(TANAGER_BUILD)/$(WT)/sim/replay/tg_replay \
	  --elfs $(WORK)/$(ACTCFG)/elfs --exclude $(ROOT)/tests/arch/exclude/$(ACTCFG).txt --jobs $(JOBS) \
	  --logdir $(WORK)/logs/$(ACTCFG)-replay --name "ACT4 $(ACTCFG), Spike against Spike" -- \
	  $(shell sed -n 's/^# replay: //p' $(CONFIG)) $(SIMARGS)

# The ELFs: the framework selects the tests that apply (UDB file), runs them on Sail and compiles
# the expected values in. Rebuilt when any file of the configuration or the shared macros changes.
CFG_FILES := $(wildcard $(ROOT)/tests/arch/config/$(ACTCFG)/*) $(ROOT)/tests/arch/config/link.ld \
             $(ROOT)/tests/arch/config/tanager_rvmodel.h
elfs: $(WORK)/$(ACTCFG)/.elfs
$(WORK)/$(ACTCFG)/.elfs: $(TESTS)/.stamp $(CFG_FILES)
	@test -f $(CONFIG) || { echo "unknown ACTCFG=$(ACTCFG) (tests/arch/config/*)"; exit 2; }
	@rm -rf $(WORK)/$(ACTCFG)/elfs
	cd $(ARCH_TEST) && $(VENV)/bin/act $(CONFIG) --workdir $(WORK) --test-dir $(TESTS) --jobs $(JOBS) \
	  --fast --clean-intermediates
	@touch $@

tests: $(TESTS)/.stamp
$(TESTS)/.stamp: $(lastword $(MAKEFILE_LIST)) $(CONFIG)
	@rm -rf $(TESTS) && mkdir -p $(TESTS)/priv
	cp -r $(ARCH_TEST)/tests/env $(TESTS)/
	cp -r $(ARCH_TEST)/tests/priv/. $(TESTS)/priv/
	cd $(ARCH_TEST) && $(VENV)/bin/testgen testplans -o $(TESTS) -j $(JOBS) -e $(GEN_EXT) > /dev/null
	@rm -rf $(TESTS)/rv32i $(TESTS)/rv32e $(TESTS)/rv64e   # RV64 only
	@touch $@

clean:
	rm -rf $(WORK)
