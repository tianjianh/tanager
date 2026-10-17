# Tanager top-level entry points. Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make lint CFG=st         lint all product RTL for one configuration [TIMING_CUTS=0|1] [DE_STAGE=0|1]
#                            [ROB_STORE_REPORT_LATE=0|1] [COMMIT_TRACE=0|1] [SYNTH=1]
#   make lint-all            lint all four configurations, each in six elaborations, the synthesis view included [LINT_JOBS=6]
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
# SYNTH=1: the synthesis view (+define+SYNTHESIS, the RTL as Vivado elaborates it), with stand-ins for the
# Xilinx primitives it instantiates. A signal that synthesized logic reads but only simulation-only code
# drives is an error there (UNDRIVEN); unused signals are not, since simulation-only code reads many.
SYNTH ?=
ifneq ($(filter-out 1,$(SYNTH)),)
  $(error SYNTH must be 1 or unset (got "$(SYNTH)"))
endif
SYNTH_MODELS := $(addprefix tests/unit/prim/models/,RAM32M16.sv RAM64M8.sv RAM64X8SW.sv SRL16E.sv SRLC32E.sv)
SYNTH_FLAGS := $(if $(SYNTH),+define+SYNTHESIS -Wno-UNUSED tools/ci/synth_lint/synth.vlt \
                 tools/ci/synth_lint/xilinx_stubs.sv $(SYNTH_MODELS))

.PHONY: lint lint-all regress regress-profiles cycle-identical
lint:
	@test -f $(RTL_CFG) || { echo "unknown CFG=$(CFG) (one of: $(CFGS))"; exit 2; }
	$(VERILATOR) $(LINT_FLAGS) $(TC_DEF) $(LINT_ONLY_DEF) $(RTL_CFG) -F $(RTL_F) $(SYNTH_FLAGS)
	@echo "lint OK: $(CFG)$(if $(TIMING_CUTS), TIMING_CUTS=$(TIMING_CUTS))$(if $(DC_MSHRS), DC_MSHRS=$(DC_MSHRS))$(if $(strip $(LINT_ONLY_SET)), $(strip $(LINT_ONLY_SET)))$(if $(SYNTH), SYNTH=1)"

# DR-140's elaborations, so that every switch's branches compile: the fallback (every switch off), the
# default (#4, #5 on), and #2, #8 and the commit trace off (DR-146) each on top of the default (lint only;
# never run in CI or the soak); and the default's synthesis view (SYNTH=1).
# LINT_JOBS run at a time, and one whose define no RTL file mentions is skipped (tools/ci/lint_all.sh).
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
# or none; BOOT=N adds the Linux boot's first N million cycles on the SoC (BOOT_CORES=1|2; BOOT_TREE=<ref>
# takes tests/unit and sw/dts from another tree); TIMING_CUTS=0|1 or BRANCH_TIMING_CUTS=0|1 picks the
# core's timing-cut profile (DR-140), on the boot too; HARNESS=auto|branch|own picks the base side's sim/.
cycle-identical:
	@python3 tools/ci/cycle_identical.py --cfg "$(CFG)" $(if $(BASE),--base "$(BASE)") $(if $(BRANCH),--branch "$(BRANCH)") \
	  $(if $(SUITES),--suites "$(SUITES)") $(if $(RANDN),--randn $(RANDN)) $(if $(JOBS),--jobs $(JOBS)) \
	  $(if $(BOOT),--boot $(BOOT)) $(if $(BOOT_CORES),--boot-cores $(BOOT_CORES)) $(if $(BOOT_TREE),--boot-tree "$(BOOT_TREE)") \
	  $(if $(TIMING_CUTS),--timing-cuts $(TIMING_CUTS)) $(if $(BRANCH_TIMING_CUTS),--branch-timing-cuts $(BRANCH_TIMING_CUTS)) \
	  $(if $(HARNESS),--harness $(HARNESS))
