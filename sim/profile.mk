# The core's build profile, shared by sim/Makefile and the test Makefiles that run tg_vsim
# (docs/spec/verification.md §4.3): DR-140's timing cuts. TIMING_CUTS=0 or 1 forces the profile
# (+define+TG_TIMING_CUTS=0|1, read by rtl/core/tg_core_pkg.sv); unset builds the package's default.
# The default has #4, #5 and the walker start's B3 form on; the fallback (0) has every switch off.
# A forced profile builds in a directory of its own, so the two profiles never overwrite each other.
TIMING_CUTS ?=
ifneq ($(filter-out 0 1,$(TIMING_CUTS)),)
  $(error TIMING_CUTS must be 0, 1 or unset (got "$(TIMING_CUTS)"))
endif
# DR-149: the L1D's misses in flight, 1 or 4 (+define+TG_DC_MSHRS, tg_core_pkg::DC_MSHRS); unset builds
# the package's default (1 in both profiles until the user decides). Like the profile, a build with it
# set has a directory of its own, and the test makefiles pass it on with the profile (TC_ARG).
DC_MSHRS ?=
ifneq ($(filter-out 1 4,$(DC_MSHRS)),)
  $(error DC_MSHRS must be 1, 4 or unset (got "$(DC_MSHRS)"))
endif
# G8's instruction-queue decode bits, 0 or 1 (+define+TG_QUEUE_DECODE, tg_core_pkg::QUEUE_DECODE); unset
# builds the package's default (off in both profiles until the user decides with G7). Cycle-exact either
# way, so it runs programs too, in a directory of its own, passed on like DC_MSHRS.
QUEUE_DECODE ?=
ifneq ($(filter-out 0 1,$(QUEUE_DECODE)),)
  $(error QUEUE_DECODE must be 0, 1 or unset (got "$(QUEUE_DECODE)"))
endif
# M6's speculative load wakeup, 0 or 1 (+define+TG_SPEC_WAKE, tg_core_pkg::SPEC_WAKE; the FPU track's feature,
# DR-153): off by default; a performance feature, so not cycle-exact; runs programs like DC_MSHRS.
SPEC_WAKE ?=
ifneq ($(filter-out 0 1,$(SPEC_WAKE)),)
  $(error SPEC_WAKE must be 0, 1 or unset (got "$(SPEC_WAKE)"))
endif
# M6's store address on its base alone, 0 or 1 (+define+TG_STA_BASE, tg_core_pkg::STA_BASE; DR-169): on by
# default; 0 gives the wait for the store's data as before. Not cycle-exact; runs programs.
STA_BASE ?=
ifneq ($(filter-out 0 1,$(STA_BASE)),)
  $(error STA_BASE must be 0, 1 or unset (got "$(STA_BASE)"))
endif
# M6's ALU-queue steering a group ahead, 0 or 1 (+define+TG_STEER_LA, tg_core_pkg::STEER_LA; DR-169): on by
# default; 0 steers on the one bank-free flag as before. Not cycle-exact; runs programs.
STEER_LA ?=
ifneq ($(filter-out 0 1,$(STEER_LA)),)
  $(error STEER_LA must be 0, 1 or unset (got "$(STEER_LA)"))
endif
TC_SUFFIX := $(if $(TIMING_CUTS),-tc$(TIMING_CUTS))$(if $(DC_MSHRS),-m$(DC_MSHRS))$(if $(QUEUE_DECODE),-qd$(QUEUE_DECODE))$(if $(SPEC_WAKE),-sw$(SPEC_WAKE))$(if $(STA_BASE),-sb$(STA_BASE))$(if $(STEER_LA),-sl$(STEER_LA))
TC_DEF    := $(strip $(if $(TIMING_CUTS),+define+TG_TIMING_CUTS=$(TIMING_CUTS)) $(if $(DC_MSHRS),+define+TG_DC_MSHRS=$(DC_MSHRS)) \
                     $(if $(QUEUE_DECODE),+define+TG_QUEUE_DECODE=$(QUEUE_DECODE)) $(if $(SPEC_WAKE),+define+TG_SPEC_WAKE=$(SPEC_WAKE)) \
                     $(if $(STA_BASE),+define+TG_STA_BASE=$(STA_BASE)) \
                     $(if $(STEER_LA),+define+TG_STEER_LA=$(STEER_LA)))
TC_ARG    := $(strip $(if $(TIMING_CUTS),TIMING_CUTS=$(TIMING_CUTS)) $(if $(DC_MSHRS),DC_MSHRS=$(DC_MSHRS)) \
                     $(if $(QUEUE_DECODE),QUEUE_DECODE=$(QUEUE_DECODE)) $(if $(SPEC_WAKE),SPEC_WAKE=$(SPEC_WAKE)) \
                     $(if $(STA_BASE),STA_BASE=$(STA_BASE)) \
                     $(if $(STEER_LA),STEER_LA=$(STEER_LA)))
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
