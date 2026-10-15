# Tanager top-level entry points. Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make lint CFG=st         lint all product RTL for one configuration [TIMING_CUTS=0|1] [DE_STAGE=0|1]
#   make lint-all            lint all four configurations, each in DR-140's three elaborations [LINT_JOBS=6]
#   make regress CFG=st      verification regression (tools/ci/regress.sh; CORE=tcore for the test core)
#   make regress-profiles CFG=st   the same for both of DR-140's profiles at once
#   make cycle-identical CFG=st [BASE=<commit>] [BOOT=N]   does this tree's RTL run cycle for cycle like BASE's?
# Track-specific targets live in their areas (sim/, tests/, fpga/); see docs/spec/conventions.md.

CFG  ?= st
CFGS := st smt2 st_w3 smt2_w3
VERILATOR ?= verilator

RTL_CFG := rtl/common/cfg/tg_cfg_$(CFG).sv
RTL_F   := rtl/rtl.f
LINT_FLAGS := --lint-only -Wall -Wno-MULTITOP --timing -Irtl/common rtl/lint.vlt
include sim/profile.mk

.PHONY: lint lint-all regress regress-profiles cycle-identical
lint:
	@test -f $(RTL_CFG) || { echo "unknown CFG=$(CFG) (one of: $(CFGS))"; exit 2; }
	$(VERILATOR) $(LINT_FLAGS) $(TC_DEF) $(DE_DEF) $(RTL_CFG) -F $(RTL_F)
	@echo "lint OK: $(CFG)$(if $(TIMING_CUTS), TIMING_CUTS=$(TIMING_CUTS))$(if $(DE_STAGE), DE_STAGE=$(DE_STAGE))"

# DR-140's elaborations, so that every switch's branches compile: the fallback (#2, #4, #5 off), the
# default (on), and #8 on top of the default (lint only; never run in CI or the soak). LINT_JOBS run at
# a time, and one whose define no RTL file mentions is skipped (tools/ci/lint_all.sh).
LINT_JOBS ?= 6
lint-all:
	@tools/ci/lint_all.sh JOBS=$(LINT_JOBS) CFGS="$(CFGS)"

# Verification regression for one configuration (docs/spec/verification.md §4.3). regress-profiles runs
# both of DR-140's profiles, the default and the fallback, side by side with half the jobs each.
CORE ?= core
REGRESS_ARGS = CFG=$(CFG) CORE=$(CORE) $(if $(LAT),LAT=$(LAT)) $(if $(SUITES),SUITES="$(SUITES)") \
  $(if $(MARCH),MARCH=$(MARCH)) $(if $(SELFTEST),SELFTEST=$(SELFTEST)) $(if $(RANDN),RANDN=$(RANDN)) \
  $(if $(JOBS),JOBS=$(JOBS))
regress:
	@tools/ci/regress.sh $(REGRESS_ARGS) $(if $(TIMING_CUTS),TIMING_CUTS=$(TIMING_CUTS))
regress-profiles:
	@$(if $(TIMING_CUTS),echo "regress-profiles runs both profiles; TIMING_CUTS is for make regress"; exit 2;) \
	  tools/ci/regress.sh $(REGRESS_ARGS) TIMING_CUTS=both

# Cycle-identical check of this tree's RTL (or BRANCH's) against BASE, by default the merge base with main
# (docs/spec/verification.md §4.5; DR-123). CFG takes a list ("st smt2"); SUITES=isa,stress,bench,random,reset
# or none; BOOT=N adds the Linux boot's first N million cycles on the SoC (BOOT_CORES=1|2);
# TIMING_CUTS=0|1 or BRANCH_TIMING_CUTS=0|1 picks the core's timing-cut profile (DR-140).
cycle-identical:
	@python3 tools/ci/cycle_identical.py --cfg "$(CFG)" $(if $(BASE),--base "$(BASE)") $(if $(BRANCH),--branch "$(BRANCH)") \
	  $(if $(SUITES),--suites "$(SUITES)") $(if $(RANDN),--randn $(RANDN)) $(if $(JOBS),--jobs $(JOBS)) \
	  $(if $(BOOT),--boot $(BOOT)) $(if $(BOOT_CORES),--boot-cores $(BOOT_CORES)) \
	  $(if $(TIMING_CUTS),--timing-cuts $(TIMING_CUTS)) $(if $(BRANCH_TIMING_CUTS),--branch-timing-cuts $(BRANCH_TIMING_CUTS))
