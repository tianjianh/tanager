# Tanager top-level entry points. Run on the build host (Ubuntu 24.04) after `source tools/env.sh`.
#   make lint CFG=st         lint all product RTL for one configuration [TIMING_CUTS=0|1] [DE_STAGE=0|1]
#                            [ROB_STORE_REPORT_LATE=0|1] [COMMIT_TRACE=0|1] [SYNTH=1]
#   make lint-all            lint all four configurations, each in six elaborations, the synthesis view included, and
#                            Vivado's own reading of the RTL (tools/ci/vivado_rtl_lint.sh) [LINT_JOBS=6] [VIVADO=0|1]
#   make regress CFG=st      verification regression (tools/ci/regress.sh; CORE=tcore for the test core)
#   make regress-profiles CFG=st   the same for both of DR-140's profiles at once
#   make cycle-identical CFG=st [BASE=<commit>] [BOOT=N]   does this tree's RTL run cycle for cycle like BASE's?
#   make perf [BASE=main] [BRANCH=<ref>] [MARCH=rv64gc] [ITER=10]   the benchmarks' cycles and IPC against BASE (M6)
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

.PHONY: lint lint-all regress regress-profiles cycle-identical perf
lint:
	@test -f $(RTL_CFG) || { echo "unknown CFG=$(CFG) (one of: $(CFGS))"; exit 2; }
	$(VERILATOR) $(LINT_FLAGS) $(TC_DEF) $(LINT_ONLY_DEF) $(RTL_CFG) -F $(RTL_F) $(SYNTH_FLAGS)
	@echo "lint OK: $(CFG)$(if $(TIMING_CUTS), TIMING_CUTS=$(TIMING_CUTS))$(if $(DC_MSHRS), DC_MSHRS=$(DC_MSHRS))$(if $(QUEUE_DECODE), QUEUE_DECODE=$(QUEUE_DECODE))$(if $(SPEC_WAKE), SPEC_WAKE=$(SPEC_WAKE))$(if $(STA_BASE), STA_BASE=$(STA_BASE))$(if $(STEER_LA), STEER_LA=$(STEER_LA))$(if $(PMP_ENTRIES), PMP_ENTRIES=$(PMP_ENTRIES))$(if $(strip $(LINT_ONLY_SET)), $(strip $(LINT_ONLY_SET)))$(if $(SYNTH), SYNTH=1)"

# DR-140's elaborations, so that every switch's branches compile: the fallback (every switch off), the
# default (#4, #5 on), and #2, #8 and the commit trace off (DR-146) each on top of the default (lint only;
# never run in CI or the soak); and the default's synthesis view (SYNTH=1).
# LINT_JOBS run at a time, and one whose define no RTL file mentions is skipped (tools/ci/lint_all.sh).
# Beside them Vivado parses and elaborates the RTL (VIVADO=0 skips it): implicit and undriven nets, and
# names used before their declaration, which Verilator resolves its own way (DR-150, rn_fire).
LINT_JOBS ?= 6
VIVADO    ?= 1
lint-all:
	@tools/ci/lint_all.sh JOBS=$(LINT_JOBS) CFGS="$(CFGS)" VIVADO=$(VIVADO)

# Verification regression for one configuration (docs/spec/verification.md §4.3). regress-profiles runs
# both of DR-140's profiles, the default and the fallback, side by side with half the jobs each.
CORE ?= core
REGRESS_ARGS = CFG=$(CFG) CORE=$(CORE) $(if $(LAT),LAT=$(LAT)) $(if $(SUITES),SUITES="$(SUITES)") \
  $(if $(MARCH),MARCH=$(MARCH)) $(if $(SELFTEST),SELFTEST=$(SELFTEST)) $(if $(RANDN),RANDN=$(RANDN)) \
  $(if $(JOBS),JOBS=$(JOBS)) $(foreach v,DC_MSHRS QUEUE_DECODE SPEC_WAKE STA_BASE STEER_LA PMP_ENTRIES,$(if $($(v)),$(v)=$($(v))))
regress:
	@tools/ci/regress.sh $(REGRESS_ARGS) $(if $(TIMING_CUTS),TIMING_CUTS=$(TIMING_CUTS))
regress-profiles:
	@$(if $(TIMING_CUTS),echo "regress-profiles runs both profiles; TIMING_CUTS is for make regress"; exit 2;) \
	  tools/ci/regress.sh $(REGRESS_ARGS) TIMING_CUTS=both

# Cycle-identical check of this tree's RTL (or BRANCH's) against BASE, by default the merge base with main
# (docs/spec/verification.md §4.5; DR-123). CFG takes a list ("st smt2"); SUITES=isa,stress,bench,random,reset
# or none; BOOT=N adds the Linux boot's first N million cycles on the SoC (BOOT_CORES=1|2; BOOT_TREE=<ref> takes
# tests/unit and sw/dts from another tree; the reference fw_jump.bin and Image, pinned by sha256 in
# tools/ci/cycle_identical.py, unless BOOT_FW=<file> or BOOT_KERNEL=<file> names another); TIMING_CUTS=0|1 or
# BRANCH_TIMING_CUTS=0|1 picks the core's timing-cut profile (DR-140), DC_MSHRS=1|4 or BRANCH_DC_MSHRS=1|4 the
# L1D's misses in flight (DR-149), QUEUE_DECODE=0|1 or BRANCH_QUEUE_DECODE=0|1 G8's queue decode bits,
# SPEC_WAKE=0|1 or BRANCH_SPEC_WAKE=0|1 M6's speculative load wakeup, STA_BASE=0|1 or BRANCH_STA_BASE=0|1 M6's
# store address on its base alone, STEER_LA=0|1 or BRANCH_STEER_LA=0|1 M6's ALU-queue steering a group ahead
# (DR-169), PMP_ENTRIES=8|16 or BRANCH_PMP_ENTRIES=8|16 the core's PMP entries (DR-167; each side's lockstep
# follows its model), on the boot too; HARNESS=auto|branch|own picks the base side's sim/.
cycle-identical:
	@python3 tools/ci/cycle_identical.py --cfg "$(CFG)" $(if $(BASE),--base "$(BASE)") $(if $(BRANCH),--branch "$(BRANCH)") \
	  $(if $(SUITES),--suites "$(SUITES)") $(if $(RANDN),--randn $(RANDN)) $(if $(JOBS),--jobs $(JOBS)) \
	  $(if $(BOOT),--boot $(BOOT)) $(if $(BOOT_CORES),--boot-cores $(BOOT_CORES)) $(if $(BOOT_TREE),--boot-tree "$(BOOT_TREE)") \
	  $(if $(BOOT_FW),--boot-fw "$(BOOT_FW)") $(if $(BOOT_KERNEL),--boot-kernel "$(BOOT_KERNEL)") \
	  $(if $(TIMING_CUTS),--timing-cuts $(TIMING_CUTS)) $(if $(BRANCH_TIMING_CUTS),--branch-timing-cuts $(BRANCH_TIMING_CUTS)) \
	  $(if $(DC_MSHRS),--dc-mshrs $(DC_MSHRS)) $(if $(BRANCH_DC_MSHRS),--branch-dc-mshrs $(BRANCH_DC_MSHRS)) \
	  $(if $(QUEUE_DECODE),--queue-decode $(QUEUE_DECODE)) $(if $(BRANCH_QUEUE_DECODE),--branch-queue-decode $(BRANCH_QUEUE_DECODE)) \
	  $(if $(SPEC_WAKE),--spec-wake $(SPEC_WAKE)) $(if $(BRANCH_SPEC_WAKE),--branch-spec-wake $(BRANCH_SPEC_WAKE)) \
	  $(if $(STA_BASE),--sta-base $(STA_BASE)) $(if $(BRANCH_STA_BASE),--branch-sta-base $(BRANCH_STA_BASE)) \
	  $(if $(STEER_LA),--steer-la $(STEER_LA)) $(if $(BRANCH_STEER_LA),--branch-steer-la $(BRANCH_STEER_LA)) \
	  $(if $(PMP_ENTRIES),--pmp-entries $(PMP_ENTRIES)) $(if $(BRANCH_PMP_ENTRIES),--branch-pmp-entries $(BRANCH_PMP_ENTRIES)) \
	  $(if $(HARNESS),--harness $(HARNESS))

# M6's per-feature measurement (DR-153; docs/spec/verification.md §4.2): CoreMark A/B and Dhrystone, each
# program's timed-region cycles and IPC on this tree's RTL (or BRANCH's) and on BASE (default main), and the
# change; MARCH and LAT take lists; the profile switches as cycle-identical's (BRANCH_* for this side only).
perf:
	@python3 tools/ci/perf.py $(if $(BASE),--base "$(BASE)") $(if $(BRANCH),--branch "$(BRANCH)") --cfg "$(CFG)" \
	  $(if $(MARCH),--march "$(MARCH)") $(if $(ITER),--iter $(ITER)) $(if $(RUNS),--runs $(RUNS)) \
	  $(if $(LAT),--lat "$(LAT)") $(if $(JOBS),--jobs $(JOBS)) $(if $(HARNESS),--harness $(HARNESS)) \
	  $(if $(TIMING_CUTS),--timing-cuts $(TIMING_CUTS)) $(if $(BRANCH_TIMING_CUTS),--branch-timing-cuts $(BRANCH_TIMING_CUTS)) \
	  $(if $(DC_MSHRS),--dc-mshrs $(DC_MSHRS)) $(if $(BRANCH_DC_MSHRS),--branch-dc-mshrs $(BRANCH_DC_MSHRS)) \
	  $(if $(QUEUE_DECODE),--queue-decode $(QUEUE_DECODE)) $(if $(BRANCH_QUEUE_DECODE),--branch-queue-decode $(BRANCH_QUEUE_DECODE)) \
	  $(if $(SPEC_WAKE),--spec-wake $(SPEC_WAKE)) $(if $(BRANCH_SPEC_WAKE),--branch-spec-wake $(BRANCH_SPEC_WAKE)) \
	  $(if $(STA_BASE),--sta-base $(STA_BASE)) $(if $(BRANCH_STA_BASE),--branch-sta-base $(BRANCH_STA_BASE)) \
	  $(if $(STEER_LA),--steer-la $(STEER_LA)) $(if $(BRANCH_STEER_LA),--branch-steer-la $(BRANCH_STEER_LA)) \
	  $(if $(PMP_ENTRIES),--pmp-entries $(PMP_ENTRIES)) $(if $(BRANCH_PMP_ENTRIES),--branch-pmp-entries $(BRANCH_PMP_ENTRIES))
