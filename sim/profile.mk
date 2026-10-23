# The core's build profile, shared by sim/Makefile and the test Makefiles that run tg_vsim
# (docs/spec/verification.md §4.3): DR-140's timing cuts. TIMING_CUTS=0 or 1 forces the profile
# (+define+TG_TIMING_CUTS=0|1, read by rtl/core/tg_core_pkg.sv); unset builds the package's default.
# The default has #4, #5 and the walker start's B3 form on; the fallback (0) has every switch off.
# A forced profile builds in a directory of its own, so the two profiles never overwrite each other.
PROFILE_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
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
# Its filter, 0, 1 or 2 (+define+TG_SPEC_WAKE_FILT, tg_core_pkg::SPEC_WAKE_FILT; the FPU track's): 1 by default; 2
# leaves a load's count alone when it misses the D$; 0 lets every tracked load wake its dependants speculatively, as
# before the filter. Not cycle-exact; runs programs.
SPEC_WAKE_FILT ?=
ifneq ($(filter-out 0 1 2,$(SPEC_WAKE_FILT)),)
  $(error SPEC_WAKE_FILT must be 0, 1, 2 or unset (got "$(SPEC_WAKE_FILT)"))
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
# M6's ownership prefetch for stores, 0 or 1 (+define+TG_STORE_PF, tg_core_pkg::STORE_PF; DR-171): on by
# default; 0 gives no prefetch as before. Not cycle-exact; runs programs.
STORE_PF ?=
ifneq ($(filter-out 0 1,$(STORE_PF)),)
  $(error STORE_PF must be 0, 1 or unset (got "$(STORE_PF)"))
endif
# How many store prefetches may be in flight, 2 or 3 (+define+TG_STORE_PF_MAX, tg_core_pkg::STORE_PF_MAX; DR-171's
# follow-up): unset builds the package's default; 2 gives the first form. Not cycle-exact; runs programs.
STORE_PF_MAX ?=
ifneq ($(filter-out 2 3,$(STORE_PF_MAX)),)
  $(error STORE_PF_MAX must be 2, 3 or unset (got "$(STORE_PF_MAX)"))
endif
# DR-167: the core's PMP entries, 8 or 16 (+define+TG_PMP_ENTRIES, tg_core_pkg::PMP_ENTRIES; the core track's
# switch); unset builds the package's default. Lockstep's Spike gets as many regions (PMP_RTL below).
PMP_ENTRIES ?=
ifneq ($(filter-out 8 16,$(PMP_ENTRIES)),)
  $(error PMP_ENTRIES must be 8, 16 or unset (got "$(PMP_ENTRIES)"))
endif
# DR-174: the integer register file's issue-time reads in UltraRAM, double-pumped at clk2x, 0 or 1
# (+define+TG_URF, tg_core_pkg::URF; the core track's switch, the area reserve): off by default. 1 gives the
# same cycles; its simulation model runs on clk alone (tg_urf), so no testbench drives clk2x.
URF ?=
ifneq ($(filter-out 0 1,$(URF)),)
  $(error URF must be 0, 1 or unset (got "$(URF)"))
endif
# M7's test mode (DR-175), 0 or 1 (+define+TG_SOLO_TID, tg_core_pkg::SOLO_TID; the core track's switch; smt2 builds only):
# the core's one thread runs as tid 1 inside the core, hart 0 to software, so the tests exercise the tid=1 paths.
# The same cycles as 0.
SOLO_TID ?=
ifneq ($(filter-out 0 1,$(SOLO_TID)),)
  $(error SOLO_TID must be 0, 1 or unset (got "$(SOLO_TID)"))
endif
# M7's split mode (DR-175, step 3), 0 or 1 (+define+TG_SPLIT, tg_core_pkg::SPLIT; the core track's switch; smt2 builds
# only): the static halves of the ROB, LQ and SQ, with the one thread in its half (thread 1's with SOLO_TID=1), so the
# halves are tested before hart 1 runs. Not the same cycles: the thread's window is half.
SPLIT ?=
ifneq ($(filter-out 0 1,$(SPLIT)),)
  $(error SPLIT must be 0, 1 or unset (got "$(SPLIT)"))
endif
# M7's hart 1 (DR-175, step 5), 0 or 1 (+define+TG_HART1, tg_core_pkg::HART1_ON; the core track's switch; smt2 builds
# only; with SOLO_TID=1 hart 0 runs as tid 1): the split window, each register bank's free list divided between the
# harts with transfers, hart 1's homes and FP banks of 96; from step 5c hart 1 runs. Until then hart 0 runs alone. Not
# the same cycles.
HART1 ?=
ifneq ($(filter-out 0 1,$(HART1)),)
  $(error HART1 must be 0, 1 or unset (got "$(HART1)"))
endif
# PMP checks at TLB fill (DR-183, docs/spec/pmp-at-fill.md), 0 or 1 (+define+TG_PMP_FILL, tg_core_pkg::PMP_FILL; soc-2's
# switch in the core track's files): one shared checker in place of fetch's and the load port's. On by default (the
# package); 0 builds the three checkers, as before. Not the same cycles.
PMP_FILL ?=
ifneq ($(filter-out 0 1,$(PMP_FILL)),)
  $(error PMP_FILL must be 0, 1 or unset (got "$(PMP_FILL)"))
endif
TC_SUFFIX := $(if $(TIMING_CUTS),-tc$(TIMING_CUTS))$(if $(DC_MSHRS),-m$(DC_MSHRS))$(if $(QUEUE_DECODE),-qd$(QUEUE_DECODE))$(if $(SPEC_WAKE),-sw$(SPEC_WAKE))$(if $(SPEC_WAKE_FILT),-swf$(SPEC_WAKE_FILT))$(if $(STA_BASE),-sb$(STA_BASE))$(if $(STEER_LA),-sl$(STEER_LA))$(if $(PMP_ENTRIES),-p$(PMP_ENTRIES))$(if $(STORE_PF),-spf$(STORE_PF))$(if $(URF),-urf$(URF))$(if $(STORE_PF_MAX),-spm$(STORE_PF_MAX))$(if $(SOLO_TID),-solo$(SOLO_TID))$(if $(SPLIT),-sp$(SPLIT))$(if $(HART1),-h$(HART1))$(if $(PMP_FILL),-pf$(PMP_FILL))
TC_DEF    := $(strip $(if $(TIMING_CUTS),+define+TG_TIMING_CUTS=$(TIMING_CUTS)) $(if $(DC_MSHRS),+define+TG_DC_MSHRS=$(DC_MSHRS)) \
                     $(if $(QUEUE_DECODE),+define+TG_QUEUE_DECODE=$(QUEUE_DECODE)) $(if $(SPEC_WAKE),+define+TG_SPEC_WAKE=$(SPEC_WAKE)) \
                     $(if $(SPEC_WAKE_FILT),+define+TG_SPEC_WAKE_FILT=$(SPEC_WAKE_FILT)) $(if $(STA_BASE),+define+TG_STA_BASE=$(STA_BASE)) \
                     $(if $(STEER_LA),+define+TG_STEER_LA=$(STEER_LA)) $(if $(PMP_ENTRIES),+define+TG_PMP_ENTRIES=$(PMP_ENTRIES)) \
                     $(if $(STORE_PF),+define+TG_STORE_PF=$(STORE_PF)) $(if $(URF),+define+TG_URF=$(URF)) \
                     $(if $(STORE_PF_MAX),+define+TG_STORE_PF_MAX=$(STORE_PF_MAX)) $(if $(SOLO_TID),+define+TG_SOLO_TID=$(SOLO_TID)) \
                     $(if $(SPLIT),+define+TG_SPLIT=$(SPLIT)) $(if $(HART1),+define+TG_HART1=$(HART1)) \
                     $(if $(PMP_FILL),+define+TG_PMP_FILL=$(PMP_FILL)))
TC_ARG    := $(strip $(if $(TIMING_CUTS),TIMING_CUTS=$(TIMING_CUTS)) $(if $(DC_MSHRS),DC_MSHRS=$(DC_MSHRS)) \
                     $(if $(QUEUE_DECODE),QUEUE_DECODE=$(QUEUE_DECODE)) $(if $(SPEC_WAKE),SPEC_WAKE=$(SPEC_WAKE)) \
                     $(if $(SPEC_WAKE_FILT),SPEC_WAKE_FILT=$(SPEC_WAKE_FILT)) $(if $(STA_BASE),STA_BASE=$(STA_BASE)) \
                     $(if $(STEER_LA),STEER_LA=$(STEER_LA)) $(if $(PMP_ENTRIES),PMP_ENTRIES=$(PMP_ENTRIES)) \
                     $(if $(STORE_PF),STORE_PF=$(STORE_PF)) $(if $(URF),URF=$(URF)) \
                     $(if $(STORE_PF_MAX),STORE_PF_MAX=$(STORE_PF_MAX)) $(if $(SOLO_TID),SOLO_TID=$(SOLO_TID)) $(if $(SPLIT),SPLIT=$(SPLIT)) \
                     $(if $(HART1),HART1=$(HART1)) $(if $(PMP_FILL),PMP_FILL=$(PMP_FILL)))
# The PMP entries of the core this tree builds, for Spike's regions in lockstep (DR-167): PMP_ENTRIES when
# set, else the package's default, from its one `localparam int PMP_ENTRIES = N;` line, else 16 (the core
# before the switch). tg_vsim takes the count from the model itself and stops if this reading differs, so
# it cannot drift; tg_replay and tanager-lockstep, which have no RTL, take PMP_DEFAULT as their default.
PMP_PKG_FILE := $(PROFILE_ROOT)/rtl/core/tg_core_pkg.sv
PMP_PKG_HAS  := $(shell grep -qsE '^[[:space:]]*localparam[[:space:]]+int[[:space:]]+PMP_ENTRIES\b' $(PMP_PKG_FILE) && echo 1)
PMP_PKG      := $(shell sed -n -E 's/^[[:space:]]*localparam[[:space:]]+int[[:space:]]+PMP_ENTRIES[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*;.*/\1/p' $(PMP_PKG_FILE) 2>/dev/null)
ifneq ($(PMP_PKG_HAS),)
  ifneq ($(words $(PMP_PKG)),1)
    $(error sim/profile.mk: expected one line `localparam int PMP_ENTRIES = N;` (the default) in rtl/core/tg_core_pkg.sv, found "$(PMP_PKG)": lockstep's PMP regions come from it)
  endif
endif
PMP_DEFAULT := $(or $(PMP_PKG),16)
PMP_RTL     := $(or $(PMP_ENTRIES),$(PMP_DEFAULT))
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
# TAGE-lite's sizes (tg_core_pkg's TG_TAGE_NT, _LI, _TW and _BI; DR-170 built two tagged tables of 2K): other sizes
# for lint only, as a bigger chip's four tables of 4K (TAGE_NT=4 TAGE_LI=12, area_switches.md)
TAGE_NT ?=
TAGE_LI ?=
TAGE_TW ?=
TAGE_BI ?=
ifneq ($(filter-out 1 2 3 4,$(TAGE_NT)),)
  $(error TAGE_NT must be 1 to 4 or unset (got "$(TAGE_NT)"))
endif
TAGE_SET := $(foreach v,NT LI TW BI,$(if $(TAGE_$(v)),TAGE_$(v)=$(TAGE_$(v))))
# DR-185's rename payload LUTRAM written through a register (tg_core_pkg's TG_PAY_WREG, 1 by default) or directly
# (PAY_WREG=0: about 770 flip-flops a core fewer, if decode's paths close): the other form for lint only
PAY_WREG ?=
ifneq ($(filter-out 0 1,$(PAY_WREG)),)
  $(error PAY_WREG must be 0, 1 or unset (got "$(PAY_WREG)"))
endif
# The lint-only switches together, for the lint targets; a build that runs programs refuses them.
LINT_ONLY_DEF := $(DE_DEF) $(if $(ROB_STORE_REPORT_LATE),+define+TG_ROB_STORE_REPORT_LATE=$(ROB_STORE_REPORT_LATE)) \
                 $(if $(COMMIT_TRACE),+define+TG_COMMIT_TRACE=$(COMMIT_TRACE)) \
                 $(foreach v,NT LI TW BI,$(if $(TAGE_$(v)),+define+TG_TAGE_$(v)=$(TAGE_$(v)))) \
                 $(if $(PAY_WREG),+define+TG_PAY_WREG=$(PAY_WREG))
LINT_ONLY_SET := $(if $(DE_STAGE),DE_STAGE=$(DE_STAGE)) $(if $(ROB_STORE_REPORT_LATE),ROB_STORE_REPORT_LATE=$(ROB_STORE_REPORT_LATE)) \
                 $(if $(filter 0,$(COMMIT_TRACE)),COMMIT_TRACE=0) $(TAGE_SET) $(if $(PAY_WREG),PAY_WREG=$(PAY_WREG))
