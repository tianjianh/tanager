# The core's build profile, shared by sim/Makefile and the test Makefiles that run tg_vsim
# (docs/spec/verification.md §4.3): DR-140's timing cuts. TIMING_CUTS=0 or 1 forces the profile
# (+define+TG_TIMING_CUTS=0|1, read by rtl/core/tg_core_pkg.sv); unset builds the package's default.
# The default has #4, #5 and the walker start's B3 form on; the fallback (0) has every switch off.
# A forced profile builds in a directory of its own, so the two profiles never overwrite each other.
TIMING_CUTS ?=
ifneq ($(filter-out 0 1,$(TIMING_CUTS)),)
  $(error TIMING_CUTS must be 0, 1 or unset (got "$(TIMING_CUTS)"))
endif
TC_SUFFIX := $(if $(TIMING_CUTS),-tc$(TIMING_CUTS))
TC_DEF    := $(if $(TIMING_CUTS),+define+TG_TIMING_CUTS=$(TIMING_CUTS))
TC_ARG    := $(if $(TIMING_CUTS),TIMING_CUTS=$(TIMING_CUTS))
# #8, one more decode stage (+define+TG_DE_STAGE=0|1): for lint only. It is never on in a build that
# runs programs, in CI or in the soak, until the user decides (DR-140); sim/Makefile refuses it there.
DE_STAGE ?=
ifneq ($(filter-out 0 1,$(DE_STAGE)),)
  $(error DE_STAGE must be 0, 1 or unset (got "$(DE_STAGE)"))
endif
DE_DEF    := $(if $(DE_STAGE),+define+TG_DE_STAGE=$(DE_STAGE))
# #2, store completions reported to the ROB a cycle late (+define+TG_ROB_STORE_REPORT_LATE=0|1): off in
# both profiles since the user's DR-140 update, so it is for lint only too, on top of the default.
ROB_STORE_REPORT_LATE ?=
ifneq ($(filter-out 0 1,$(ROB_STORE_REPORT_LATE)),)
  $(error ROB_STORE_REPORT_LATE must be 0, 1 or unset (got "$(ROB_STORE_REPORT_LATE)"))
endif
# The commit trace (DR-146, +define+TG_COMMIT_TRACE=0|1, rtl/common/tg_trace_pkg.sv): on by default, and
# everything that runs programs here checks it, so off is for lint only.
COMMIT_TRACE ?=
ifneq ($(filter-out 0 1,$(COMMIT_TRACE)),)
  $(error COMMIT_TRACE must be 0, 1 or unset (got "$(COMMIT_TRACE)"))
endif
# The lint-only switches together, for the lint targets; a build that runs programs refuses them.
LINT_ONLY_DEF := $(DE_DEF) $(if $(ROB_STORE_REPORT_LATE),+define+TG_ROB_STORE_REPORT_LATE=$(ROB_STORE_REPORT_LATE)) \
                 $(if $(COMMIT_TRACE),+define+TG_COMMIT_TRACE=$(COMMIT_TRACE))
LINT_ONLY_SET := $(if $(DE_STAGE),DE_STAGE=$(DE_STAGE)) $(if $(ROB_STORE_REPORT_LATE),ROB_STORE_REPORT_LATE=$(ROB_STORE_REPORT_LATE)) \
                 $(if $(filter 0,$(COMMIT_TRACE)),COMMIT_TRACE=0)
