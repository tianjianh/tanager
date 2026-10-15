# The core's build profile, shared by sim/Makefile and the test Makefiles that run tg_vsim
# (docs/spec/verification.md §4.3): DR-140's timing cuts. TIMING_CUTS=0 or 1 forces the profile
# (+define+TG_TIMING_CUTS=0|1, read by rtl/core/tg_core_pkg.sv); unset builds the package's default.
# A forced profile builds in a directory of its own, so the two profiles never overwrite each other.
TIMING_CUTS ?=
ifneq ($(filter-out 0 1,$(TIMING_CUTS)),)
  $(error TIMING_CUTS must be 0, 1 or unset (got "$(TIMING_CUTS)"))
endif
TC_SUFFIX := $(if $(TIMING_CUTS),-tc$(TIMING_CUTS))
TC_DEF    := $(if $(TIMING_CUTS),+define+TG_TIMING_CUTS=$(TIMING_CUTS))
TC_ARG    := $(if $(TIMING_CUTS),TIMING_CUTS=$(TIMING_CUTS))
