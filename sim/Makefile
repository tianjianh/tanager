# tg_vsim: the Verilator harness around tg_core (docs/spec/verification.md §2).
# Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make -C sim CFG=st                 build tg_vsim for the product core (rtl/core)
#   make -C sim CFG=st CORE=tcore      build it around the test core (sim/tcore)
#   make -C sim CFG=st TIMING_CUTS=0   the core's other profile (DR-140; sim/profile.mk), in its own directory
#   make -C sim replay                 build tg_replay (Spike against Spike, no RTL)
#   make -C sim lint CFG=st CORE=tcore lint the testbench and the test core
#   make -C sim lockstep               tanager-lockstep for this host (FPGA lockstep, verification.md §3.9)
#   make -C sim lockstep-aarch64       the same, static for the A53 (Spike cross-built from sw/fetch.sh)
#   make -C sim clean                  remove this worktree's sim build trees
#   make -C sim CFG=st COV=1 [COV_UNITS="rename rob lsu"]   a separate build with line and expression
#                                      coverage of those rtl/core units only (tg_vsim --cov=FILE;
#                                      tools/ci/cov_report.py; verification.md §6.4)
# The binary is $(BUILD)/tg_vsim; `make -C sim print-bin CFG=... CORE=...` prints its path.

CFG  ?= st
CORE ?= core
CFGS := st smt2 st_w3 smt2_w3
JOBS ?= 8

ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
WT       := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
BUILD_ROOT := $(TANAGER_BUILD)/$(WT)/sim
COV       ?=
COV_UNITS ?= rename rob lsu
empty    :=
space    := $(empty) $(empty)
include $(ROOT)/sim/profile.mk
# The lint-only switches (#2, #8; the commit trace off) never reach a model that runs programs, even an
# up-to-date one (DR-140: #2 and #8 are not verified; DR-146: lockstep needs the trace).
ifneq ($(strip $(LINT_ONLY_SET)),)
  ifneq ($(filter-out lint,$(or $(MAKECMDGOALS),all)),)
    $(error $(strip $(LINT_ONLY_SET)) is for lint only (DR-140: #2 and #8 are not verified; DR-146: lockstep needs the commit trace))
  endif
endif
BUILD    := $(BUILD_ROOT)/$(CFG)-$(CORE)$(TC_SUFFIX)$(if $(COV),-cov-$(subst $(space),+,$(strip $(COV_UNITS))))
VERILATOR ?= verilator
CXX      ?= g++-15
SPIKE_ROOT ?= $(HOME)/opt/tanager/spike

# Verilator's makefile lets ccache cache its precompiled headers (CCACHE_SLOPPINESS=pch_defines,
# time_macros). GCC 15 crashes compiling against such a header when ccache returns it from the
# cache (reproduced with st_w3 builds, 2026-10-13), so ccache leaves precompiled headers alone:
# those compiles run uncached; Verilator's runtime and our C++ are still cached.
export CCACHE_SLOPPINESS :=

# Spike's default ISA and privilege modes for each core (verification.md §3.2). The core track
# widens ISA/PRIV as features land; --isa and --priv override them per run. They come from this
# make's command line or these defaults, never from the environment: a runner's own ISA variable
# (tests/random: the generator's ISA) reaches the environment of its sub-makes. Spike's PMP regions
# are the core's PMP entries (DR-167): the model reports them, and PMP_TB is what sim/profile.mk read
# from the package, which the model checks at every run (TG_TB_PMP_RTL).
$(foreach v,ISA PRIV PMP,$(if $(filter environment,$(origin $(v))),$(eval undefine $(v))))
ifeq ($(CORE),tcore)
  ISA  ?= rv64im_zicsr_zicntr_zifencei
  PRIV ?= MU
  PMP_TB := 0
  CORE_TOP := tg_tcore
  CORE_F   := -F $(ROOT)/rtl/common/common.f -F $(ROOT)/sim/tcore/tcore.f
  CORE_DEF := +define+TG_TCORE
else ifeq ($(CORE),core)
  ISA  ?= rv64imafdc_zicsr_zicntr_zihpm_zifencei_zba_zbb_zbs_zicond_sstc_svinval_za64rs
  PRIV ?= MSU
  PMP_TB := $(PMP_RTL)
  CORE_TOP := tg_core
  CORE_F   := -F $(ROOT)/rtl/rtl.f
  CORE_DEF :=
else
  $(error unknown CORE=$(CORE) (core or tcore))
endif
# PMP=N, Spike's regions before DR-167, is accepted only where it names the core's count
ifneq ($(PMP),)
  ifneq ($(PMP),$(PMP_TB))
    $(error PMP=$(PMP): Spike's PMP regions are the core's PMP entries since DR-167 ($(PMP_TB) for this build); PMP_ENTRIES=8|16 sets the core's)
  endif
endif
PMP_DEF := +define+TG_TB_PMP_RTL=$(PMP_TB) $(if $(PMP_PKG_HAS),+define+TG_TB_PKG_PMP)

RTL_CFG := $(ROOT)/rtl/common/cfg/tg_cfg_$(CFG).sv
SRCS    := main.cpp tb_dpi.cpp tlmodels.cpp elfload.cpp lockstep.cpp
HDRS    := $(wildcard $(ROOT)/sim/src/*.h)
SV      := $(shell find $(ROOT)/rtl $(ROOT)/sim -name '*.sv' -o -name '*.f')

CXXFLAGS_TB := -std=c++20 -O2 -I$(ROOT)/sim/src -I$(SPIKE_ROOT)/include \
               -DTG_DEFAULT_ISA=\\\"$(ISA)\\\" -DTG_DEFAULT_PRIV=\\\"$(PRIV)\\\" -DTG_CORE_NAME=\\\"$(CORE_TOP)\\\"
LDFLAGS_TB  := -L$(SPIKE_ROOT)/lib -Wl,-rpath,$(SPIKE_ROOT)/lib -lriscv

VFLAGS := --cc --exe --build -j $(JOBS) --top-module tg_tb_top -O3 --assert \
          --x-assign unique --x-initial unique --trace-fst --trace-structs \
          -Wall -Wno-fatal -Wno-MULTITOP -Wno-DECLFILENAME $(ROOT)/sim/tb/tb.vlt $(ROOT)/sim/tcore/tcore.vlt $(ROOT)/rtl/lint.vlt \
          -I$(ROOT)/rtl/common $(CORE_DEF) $(TC_DEF) $(PMP_DEF) \
          -MAKEFLAGS "OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2" \
          -CFLAGS "$(CXXFLAGS_TB)" -LDFLAGS "$(LDFLAGS_TB)" $(if $(COV),--coverage-line --coverage-expr $(BUILD)/cov.vlt)

# COV=1 instruments only the core units in COV_UNITS: Verilator's coverage_on does not undo a
# coverage_off, so the configuration names everything else (the other units, the core's top files,
# rtl/common and the testbench). Fewer points keep the build and the runs fast.
COV_OFF := $(filter-out $(COV_UNITS),$(patsubst $(ROOT)/rtl/core/%/,%,$(wildcard $(ROOT)/rtl/core/*/)))
# and binds event points into the product core: conditions none of the core's own expressions shows
COV_EVENTS := $(if $(and $(COV),$(filter core,$(CORE))),$(ROOT)/sim/cov/tg_core_events.sv)

.PHONY: all build lint replay lockstep lockstep-aarch64 clean print-bin print-build
all: build

build: $(BUILD)/tg_vsim

$(BUILD)/tg_vsim: $(SV) $(addprefix $(ROOT)/sim/src/,$(SRCS)) $(HDRS) $(ROOT)/sim/tb/tb.vlt $(lastword $(MAKEFILE_LIST))
	@test -f $(RTL_CFG) || { echo "unknown CFG=$(CFG) (one of: $(CFGS))"; exit 2; }
	@mkdir -p $(BUILD)
	$(if $(COV),@{ printf '`verilator_config\n'; for d in $(COV_OFF); do printf 'coverage_off -file "*/rtl/core/%s/*"\n' $$d; done; \
	  printf 'coverage_off -file "*/rtl/core/tg_core*"\ncoverage_off -file "*/rtl/common/*"\ncoverage_off -file "*/sim/tb/*"\ncoverage_off -file "*/sim/tcore/*"\n'; } > $(BUILD)/cov.vlt)
	$(VERILATOR) $(VFLAGS) --Mdir $(BUILD) -o tg_vsim \
	  $(RTL_CFG) $(CORE_F) $(ROOT)/sim/tb/tg_tb_top.sv $(COV_EVENTS) $(addprefix $(ROOT)/sim/src/,$(SRCS)) \
	  > $(BUILD)/build.log 2>&1 || { tail -40 $(BUILD)/build.log; exit 1; }
	@grep -E '^%Warning' $(BUILD)/build.log | head -20 || true
	@touch $@  # Verilator does not relink when the generated code is unchanged
	@echo "built $@"

lint:
	$(VERILATOR) --lint-only -Wall -Wno-MULTITOP --top-module tg_tb_top $(ROOT)/sim/tb/tb.vlt $(ROOT)/sim/tcore/tcore.vlt $(ROOT)/rtl/lint.vlt \
	  -I$(ROOT)/rtl/common $(CORE_DEF) $(TC_DEF) $(PMP_DEF) $(LINT_ONLY_DEF) $(RTL_CFG) $(CORE_F) $(ROOT)/sim/tb/tg_tb_top.sv
	@echo "sim lint OK: $(CFG) $(CORE)"

# The PMP regions tg_replay and tanager-lockstep default to (DR-167): the package's default PMP entries
# (PMP_DEFAULT, sim/profile.mk), in a header rewritten only when that count changes, so they rebuild then.
# A build with PMP_ENTRIES forced keeps them on the default; their runs name another count with --pmp.
PMP_HDR := $(BUILD_ROOT)/gen/tg_pmp_default.h
$(PMP_HDR): $(wildcard $(PMP_PKG_FILE)) $(ROOT)/sim/profile.mk
	@mkdir -p $(dir $@)
	@echo '#define TG_DEFAULT_PMP $(PMP_DEFAULT)' > $@.$$$$ && { cmp -s $@.$$$$ $@ && rm -f $@.$$$$ || mv -f $@.$$$$ $@; }

REPLAY := $(BUILD_ROOT)/replay/tg_replay
replay: $(REPLAY)
$(REPLAY): $(ROOT)/sim/src/replay.cpp $(ROOT)/sim/src/lockstep.cpp $(ROOT)/sim/src/elfload.cpp $(HDRS) $(PMP_HDR)
	@mkdir -p $(dir $@)
	$(CXX) -std=c++20 -O2 -g -Wall -Wextra -I$(ROOT)/sim/src -I$(SPIKE_ROOT)/include -include $(PMP_HDR) \
	  $(ROOT)/sim/src/replay.cpp $(ROOT)/sim/src/lockstep.cpp $(ROOT)/sim/src/elfload.cpp \
	  -o $@ $(LDFLAGS_TB)
	@echo "built $@"

# ---- FPGA lockstep (verification.md §3.9): tanager-lockstep checks the board's commit-trace stream ----
LS_SRCS := $(addprefix $(ROOT)/sim/src/,tanager_lockstep.cpp lockstep.cpp elfload.cpp)
LS_DIR  := $(BUILD_ROOT)/lockstep
LS_HDR  := $(LS_DIR)/tanager_bootrom.h
LS_DEFS := -DTG_DEFAULT_ISA=\"$(ISA)\" -include $(PMP_HDR)
$(LS_HDR): $(ROOT)/rtl/uncore/bootrom/tg_bootrom_img_pkg.sv $(ROOT)/sim/src/gen_bootrom_h.py
	@mkdir -p $(LS_DIR)
	python3 -I $(ROOT)/sim/src/gen_bootrom_h.py $< > $@

lockstep: $(LS_DIR)/tanager-lockstep
$(LS_DIR)/tanager-lockstep: $(LS_SRCS) $(HDRS) $(LS_HDR) $(PMP_HDR)
	$(CXX) -std=c++20 -O2 -Wall -Wextra -I$(ROOT)/sim/src -I$(LS_DIR) -I$(SPIKE_ROOT)/include $(LS_DEFS) \
	  $(LS_SRCS) -o $@ $(LDFLAGS_TB)
	@echo "built $@"

# The A53 build: Spike at tools/versions.sh's SPIKE_SHA, cross-built with sw/versions.sh's aarch64 musl
# toolchain, linked statically (a static musl binary runs on the board's Ubuntu, as tanager-host does).
# Spike's own flags carry -g (libriscv.a would be 973 MB; the user flags come last, so -g0 wins), and
# only the libraries and headers are kept (the object tree is 2 GB).
SPIKE_SHA := $(shell . $(ROOT)/tools/versions.sh && echo $$SPIKE_SHA)
SOC_DL    ?= $(TANAGER_BUILD)/$(WT)/dl
SPIKE_TAR ?= $(SOC_DL)/spike/spike-$(SPIKE_SHA).tar.gz
A64_TRIP  := aarch64-buildroot-linux-musl
AATC_NAME := $(shell . $(ROOT)/sw/versions.sh && echo $$AATC_NAME)
# The worktree's own unpacked toolchain, else the shared one in $(TANAGER_BUILD)/tc (as sw/env.sh's
# SOC_AATC), else the worktree's again, where sw/fetch.sh aatc unpacks it.
A64_TC    ?= $(firstword $(wildcard $(TANAGER_BUILD)/$(WT)/tc/$(AATC_NAME)/bin $(TANAGER_BUILD)/tc/$(AATC_NAME)/bin) \
               $(TANAGER_BUILD)/$(WT)/tc/$(AATC_NAME)/bin)
A64_SPIKE := $(BUILD_ROOT)/aarch64/spike-$(SPIKE_SHA)
A64_LIBS  := libriscv.a libdisasm.a libsoftfloat.a libfesvr.a libfdt.a

$(SPIKE_TAR):
	bash $(ROOT)/sw/fetch.sh spike
$(A64_TC)/$(A64_TRIP)-g++:
	bash $(ROOT)/sw/fetch.sh aatc

$(A64_SPIKE)/install/lib/libriscv.a: $(SPIKE_TAR) | $(A64_TC)/$(A64_TRIP)-g++
	rm -rf $(A64_SPIKE) && mkdir -p $(A64_SPIKE)/src $(A64_SPIKE)/build
	tar -xzf $(SPIKE_TAR) -C $(A64_SPIKE)/src --strip-components=1
	cd $(A64_SPIKE)/build && PATH=$(A64_TC):$$PATH ../src/configure --host=$(A64_TRIP) --prefix=$(A64_SPIKE)/install \
	  --without-boost --without-boost-asio --without-boost-regex \
	  CC=$(A64_TRIP)-gcc CXX=$(A64_TRIP)-g++ AR=$(A64_TRIP)-ar RANLIB=$(A64_TRIP)-ranlib \
	  > configure.log 2>&1 || { tail -20 configure.log; exit 1; }
	PATH=$(A64_TC):$$PATH $(MAKE) -C $(A64_SPIKE)/build -j$(JOBS) CFLAGS="-O2 -g0" CXXFLAGS="-O2 -g0" $(A64_LIBS) \
	  > $(A64_SPIKE)/build/make.log 2>&1 || { tail -20 $(A64_SPIKE)/build/make.log; exit 1; }
	PATH=$(A64_TC):$$PATH $(MAKE) -C $(A64_SPIKE)/build install-hdrs > /dev/null
	mkdir -p $(A64_SPIKE)/install/lib && cp $(addprefix $(A64_SPIKE)/build/,$(A64_LIBS)) $(A64_SPIKE)/install/lib/
	rm -rf $(A64_SPIKE)/build $(A64_SPIKE)/src

lockstep-aarch64: $(LS_DIR)/aarch64/tanager-lockstep
$(LS_DIR)/aarch64/tanager-lockstep: $(LS_SRCS) $(HDRS) $(LS_HDR) $(PMP_HDR) $(A64_SPIKE)/install/lib/libriscv.a
	@mkdir -p $(dir $@)
	$(A64_TC)/$(A64_TRIP)-g++ -std=c++20 -O2 -Wall -Wextra -static -I$(ROOT)/sim/src -I$(LS_DIR) \
	  -I$(A64_SPIKE)/install/include \
	  $(LS_DEFS) $(LS_SRCS) -o $@ -L$(A64_SPIKE)/install/lib -lriscv -ldisasm -lsoftfloat -lfesvr -lfdt -lpthread
	$(A64_TC)/$(A64_TRIP)-strip $@
	@file $@
	@echo "built $@"

print-bin:
	@echo $(BUILD)/tg_vsim
print-build:
	@echo $(BUILD)

clean:
	rm -rf $(BUILD_ROOT)
