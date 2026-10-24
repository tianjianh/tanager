# riscv-arch-test (ACT4) on Tanager (docs/spec/verification.md §6.1).
# Run on the build host (Ubuntu 24.04) after `source tools/env.sh`.
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
# The core's configuration follows its PMP entries (DR-167; PMP_RTL, sim/profile.mk): 8 usable of 16 with -p8; and
# M9's performance counters (HPM=1, DR-190): -hpm declares mhpmcounter3-6 with Sscofpmf, so Zihpm's tests expect them
ACTCFG ?= $(if $(filter tcore,$(CORE)),tcore-rv64im,core-m3-rv64imafdc$(if $(filter 8,$(PMP_RTL)),-p8)$(if $(filter 1,$(HPM)),-hpm))

ARCH_MK := $(lastword $(MAKEFILE_LIST))
ROOT := $(abspath $(dir $(ARCH_MK))/../..)
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
# UDB's binaries (Z3, espresso, eqntott, must: sw/versions.sh's UDB_* pins, verification.md §6.1) in a shared tools
# folder that cleanups keep, given only to act, which runs udb (XDG_CACHE_HOME), so other tools' caches stay put. udb
# fetches a missing binary by itself; the check below stops first, as any download needs the user's yes
UDB_CACHE ?= $(TANAGER_BUILD)/tools/udb-deps
udb_pin = $(shell sed -n 's/^$(1)=\([^ #]*\).*/\1/p' $(ROOT)/sw/versions.sh)
UDB_BINS := z3/$(call udb_pin,UDB_Z3_VER)/x64/libz3.so espresso/$(call udb_pin,UDB_ESPRESSO_VER)/x64/espresso \
            eqntott/$(call udb_pin,UDB_EQNTOTT_VER)/x64/eqntott must/$(call udb_pin,UDB_MUST_VER)/x64/must

# Command-line variables of this make must not reach the sim build (see tests/random/Makefile).
MAKEOVERRIDES :=

# The Spike configuration of this ACT4 configuration (its test_config.yaml's `# spike:` line): the
# lockstep checker in tg_vsim and the replaying Spike both use it. SIMARGS can override it.
SPIKE_ARGS := $(shell sed -n 's/^\# spike: //p' $(CONFIG))
# Its PMP regions must be the core's PMP entries (DR-167): tg_vsim refuses any other --pmp, so say it once here
ACT_PMP  := $(patsubst --pmp=%,%,$(filter --pmp=%,$(SPIKE_ARGS)))
CORE_PMP := $(if $(filter tcore,$(CORE)),0,$(PMP_RTL))
ifneq ($(filter run,$(or $(MAKECMDGOALS),run)),)
  ifneq ($(filter-out $(CORE_PMP),$(ACT_PMP)),)
    $(error ACT4 configuration $(ACTCFG) is for $(ACT_PMP) PMP entries, but this $(CORE) has $(CORE_PMP) (DR-167): leave ACTCFG to its default or build the core with PMP_ENTRIES=$(ACT_PMP))
  endif
  # ... and its counters: a configuration with Sscofpmf for HPM=1, one without for the default
  ifneq ($(if $(findstring _sscofpmf,$(SPIKE_ARGS)),1),$(if $(filter 1,$(HPM)),1))
    $(error ACT4 configuration $(ACTCFG) $(if $(findstring _sscofpmf,$(SPIKE_ARGS)),declares,does not declare) M9's counters, but this core is built with$(if $(filter 1,$(HPM)),, no) HPM=1 (DR-190): leave ACTCFG to its default)
  endif
endif

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
$(WORK)/$(ACTCFG)/.elfs: $(ARCH_MK) $(CFG_FILES)
	@for f in $(UDB_BINS); do test -f $(UDB_CACHE)/udb/$$f || { echo "ACT4: no $(UDB_CACHE)/udb/$$f: fetch sw/versions.sh's UDB_* pins (with the user's yes) by the udb gem's ext/udb_download/extconf.rb with XDG_CACHE_HOME=$(UDB_CACHE), verification.md §6.1"; exit 1; }; done
	@rm -rf $(WORK)/$(ACTCFG)/elfs
	$(gen_tests)
	cd $(ARCH_TEST) && XDG_CACHE_HOME=$(UDB_CACHE) $(VENV)/bin/act $(CONFIG) --workdir $(WORK) --test-dir $(TESTS) \
	  --jobs $(JOBS) --fast --clean-intermediates
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
