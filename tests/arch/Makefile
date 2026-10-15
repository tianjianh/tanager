# riscv-arch-test (ACT4) on Tanager (docs/spec/verification.md §6.1).
# Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make -C tests/arch CFG=st CORE=tcore [ACTCFG=...] [SIMARGS=...]   build the ELFs and run them in tg_vsim
#   make -C tests/arch elfs ACTCFG=...                                 build the ELFs only (Sail runs here)
#   make -C tests/arch replay ACTCFG=...                               run them Spike against Spike (tg_replay)
#   make -C tests/arch tests ACTCFG=...                                generate the test sources (for debugging)
#   make -C tests/arch clean
# A test passes when its self-check (expected values from Sail) passes and lockstep passes.
# Work trees: $TANAGER_BUILD/<worktree>/arch/<ACTCFG>/elfs; the generated sources (tests/) only exist
# while the ELFs are built, or after `make tests`. The riscv-arch-test checkout is only read.

CFG    ?= st
CORE   ?= core
JOBS   ?= 8
ACTCFG ?= $(if $(filter tcore,$(CORE)),tcore-rv64im,core-m3-rv64imafdc)

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
include $(ROOT)/sim/profile.mk
TANAGER_OPT   ?= $(HOME)/opt/tanager
ARCH_TEST ?= $(HOME)/src/tanager/riscv-arch-test
VENV := $(TANAGER_OPT)/act-venv
WORK := $(TANAGER_BUILD)/$(WT)/arch
TESTS := $(WORK)/$(ACTCFG)/tests
CONFIG := $(ROOT)/tests/arch/config/$(ACTCFG)/test_config.yaml
export BUNDLE_PATH := $(TANAGER_OPT)/act-gems

# Command-line variables of this make must not reach the sim build (see tests/random/Makefile).
MAKEOVERRIDES :=

# The Spike configuration of this ACT4 configuration (its test_config.yaml's `# spike:` line): the
# lockstep checker in tg_vsim and the replaying Spike both use it. SIMARGS can override it.
SPIKE_ARGS := $(shell sed -n 's/^\# spike: //p' $(CONFIG))

# Test plans generated with testgen (the other privileged suites are committed upstream and copied):
# every plan a Tanager core could need through F/D; act then selects the tests that apply to the
# configuration's UDB file. A configuration may add plans on a `# testgen:` line of its test_config.yaml.
GEN_PLANS := I M Zmmul Zaamo Zalrsc Zca Zcd Zba Zbb Zbs Zicond Zihintpause Zihpm Zicntr Zicsr Zifencei \
             F D Misalign Sm SmF S U UF ExceptionsSm ExceptionsS ExceptionsU ExceptionsF ExceptionsZaamo \
             ExceptionsZalrsc ExceptionsZc InterruptsSm InterruptsS Sstc SstcSm Sstvala Sstvecd Ssu64xl \
             Ssccptr SsstrictS SsstrictSm SsstrictU Sscounterenw Za64rs ZicsrF
comma := ,
GEN_EXT := $(subst $() ,$(comma),$(strip $(GEN_PLANS) $(subst $(comma), ,$(shell sed -n 's/^\# testgen: //p' $(CONFIG)))))

.PHONY: run elfs tests replay clean
run: elfs
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim CFG=$(CFG) CORE=$(CORE) $(TC_ARG) build
	python3 $(ROOT)/tests/arch/run_arch.py --sim $(TANAGER_BUILD)/$(WT)/sim/$(CFG)-$(CORE)$(TC_SUFFIX)/tg_vsim \
	  --elfs $(WORK)/$(ACTCFG)/elfs --exclude $(ROOT)/tests/arch/exclude/$(ACTCFG).txt --jobs $(JOBS) \
	  --logdir $(WORK)/logs/$(ACTCFG)-$(CFG)-$(CORE)$(TC_SUFFIX) --name "ACT4 $(ACTCFG) on $(CFG) $(CORE)$(TC_SUFFIX)" -- $(SPIKE_ARGS) $(SIMARGS)

replay: elfs
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim replay
	python3 $(ROOT)/tests/arch/run_arch.py --sim $(TANAGER_BUILD)/$(WT)/sim/replay/tg_replay \
	  --elfs $(WORK)/$(ACTCFG)/elfs --exclude $(ROOT)/tests/arch/exclude/$(ACTCFG).txt --jobs $(JOBS) \
	  --logdir $(WORK)/logs/$(ACTCFG)-replay --name "ACT4 $(ACTCFG), Spike against Spike" -- \
	  $(SPIKE_ARGS) $(SIMARGS)

# The ELFs: the framework selects the tests that apply (UDB file), runs them on Sail and compiles
# the expected values in. Rebuilt when any file of the configuration or the shared macros changes.
# The generated sources are deleted afterwards (half the work tree; regenerating takes seconds).
CFG_FILES := $(wildcard $(ROOT)/tests/arch/config/$(ACTCFG)/*) $(ROOT)/tests/arch/config/link.ld \
             $(ROOT)/tests/arch/config/tanager_rvmodel.h
elfs: $(WORK)/$(ACTCFG)/.elfs
$(WORK)/$(ACTCFG)/.elfs: $(lastword $(MAKEFILE_LIST)) $(CFG_FILES)
	@rm -rf $(WORK)/$(ACTCFG)/elfs
	$(gen_tests)
	cd $(ARCH_TEST) && $(VENV)/bin/act $(CONFIG) --workdir $(WORK) --test-dir $(TESTS) --jobs $(JOBS) \
	  --fast --clean-intermediates
	@rm -rf $(TESTS)
	@touch $@

# The test sources: the framework's environment and committed privileged tests, and the suites
# testgen generates for this configuration.
define gen_tests
	@test -f $(CONFIG) || { echo "unknown ACTCFG=$(ACTCFG) (tests/arch/config/*)"; exit 2; }
	@rm -rf $(TESTS) && mkdir -p $(TESTS)/priv
	cp -r $(ARCH_TEST)/tests/env $(TESTS)/
	cp -r $(ARCH_TEST)/tests/priv/. $(TESTS)/priv/
	cd $(ARCH_TEST) && $(VENV)/bin/testgen testplans -o $(TESTS) -j $(JOBS) -e $(GEN_EXT) > /dev/null
	@rm -rf $(TESTS)/rv32i $(TESTS)/rv32e $(TESTS)/rv64e   # RV64 only
endef

tests:
	$(gen_tests)
	@echo "test sources in $(TESTS)"

clean:
	rm -rf $(WORK)
