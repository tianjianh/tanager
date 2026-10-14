# tg_vsim: the Verilator harness around tg_core (docs/spec/verification.md §2).
# Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make -C sim CFG=st                 build tg_vsim for the product core (rtl/core)
#   make -C sim CFG=st CORE=tcore      build it around the test core (sim/tcore)
#   make -C sim replay                 build tg_replay (Spike against Spike, no RTL)
#   make -C sim lint CFG=st CORE=tcore lint the testbench and the test core
#   make -C sim clean                  remove this worktree's sim build trees
#   make -C sim print-trace-stall CORE=...   1 if that core's build has trace_stall_i
# The binary is $(BUILD)/tg_vsim; `make -C sim print-bin CFG=... CORE=...` prints its path.

CFG  ?= st
CORE ?= core
CFGS := st smt2 st_w3 smt2_w3
JOBS ?= 8

ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
WT       := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
BUILD_ROOT := $(TANAGER_BUILD)/$(WT)/sim
BUILD    := $(BUILD_ROOT)/$(CFG)-$(CORE)
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
# (tests/random: the generator's ISA) reaches the environment of its sub-makes.
$(foreach v,ISA PRIV PMP,$(if $(filter environment,$(origin $(v))),$(eval undefine $(v))))
# TRACE_STALL=1 connects trace_stall_i (interfaces.md v1.3); tg_core gets it by default once its
# port is on main.
ifeq ($(CORE),tcore)
  ISA  ?= rv64im_zicsr_zicntr_zifencei
  PRIV ?= MU
  PMP  ?= 0
  TRACE_STALL ?= 1
  CORE_TOP := tg_tcore
  CORE_F   := -F $(ROOT)/rtl/common/common.f -F $(ROOT)/sim/tcore/tcore.f
  CORE_DEF := +define+TG_TCORE
else ifeq ($(CORE),core)
  ISA  ?= rv64im_zicsr_zicntr_zifencei
  PRIV ?= M
  PMP  ?= 16
  TRACE_STALL ?= 0
  CORE_TOP := tg_core
  CORE_F   := -F $(ROOT)/rtl/rtl.f
  CORE_DEF :=
else
  $(error unknown CORE=$(CORE) (core or tcore))
endif

CORE_DEF += $(if $(filter 1,$(TRACE_STALL)),+define+TG_TRACE_STALL)

RTL_CFG := $(ROOT)/rtl/common/cfg/tg_cfg_$(CFG).sv
SRCS    := main.cpp tb_dpi.cpp tlmodels.cpp elfload.cpp lockstep.cpp
HDRS    := $(wildcard $(ROOT)/sim/src/*.h)
SV      := $(shell find $(ROOT)/rtl $(ROOT)/sim -name '*.sv' -o -name '*.f')

CXXFLAGS_TB := -std=c++20 -O2 -I$(ROOT)/sim/src -I$(SPIKE_ROOT)/include \
               -DTG_DEFAULT_ISA=\\\"$(ISA)\\\" -DTG_DEFAULT_PRIV=\\\"$(PRIV)\\\" -DTG_DEFAULT_PMP=$(PMP) -DTG_CORE_NAME=\\\"$(CORE_TOP)\\\"
LDFLAGS_TB  := -L$(SPIKE_ROOT)/lib -Wl,-rpath,$(SPIKE_ROOT)/lib -lriscv

VFLAGS := --cc --exe --build -j $(JOBS) --top-module tg_tb_top -O3 --assert \
          --x-assign unique --x-initial unique --trace-fst --trace-structs \
          -Wall -Wno-fatal -Wno-MULTITOP -Wno-DECLFILENAME $(ROOT)/sim/tb/tb.vlt $(ROOT)/sim/tcore/tcore.vlt $(ROOT)/rtl/lint.vlt \
          -I$(ROOT)/rtl/common $(CORE_DEF) \
          -MAKEFLAGS "OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2" \
          -CFLAGS "$(CXXFLAGS_TB)" -LDFLAGS "$(LDFLAGS_TB)"

.PHONY: all build lint replay clean print-bin print-build print-trace-stall
all: build

build: $(BUILD)/tg_vsim

$(BUILD)/tg_vsim: $(SV) $(addprefix $(ROOT)/sim/src/,$(SRCS)) $(HDRS) $(ROOT)/sim/tb/tb.vlt $(lastword $(MAKEFILE_LIST))
	@test -f $(RTL_CFG) || { echo "unknown CFG=$(CFG) (one of: $(CFGS))"; exit 2; }
	@mkdir -p $(BUILD)
	$(VERILATOR) $(VFLAGS) --Mdir $(BUILD) -o tg_vsim \
	  $(RTL_CFG) $(CORE_F) $(ROOT)/sim/tb/tg_tb_top.sv $(addprefix $(ROOT)/sim/src/,$(SRCS)) \
	  > $(BUILD)/build.log 2>&1 || { tail -40 $(BUILD)/build.log; exit 1; }
	@grep -E '^%Warning' $(BUILD)/build.log | head -20 || true
	@touch $@  # Verilator does not relink when the generated code is unchanged
	@echo "built $@"

lint:
	$(VERILATOR) --lint-only -Wall -Wno-MULTITOP --top-module tg_tb_top $(ROOT)/sim/tb/tb.vlt $(ROOT)/sim/tcore/tcore.vlt $(ROOT)/rtl/lint.vlt \
	  -I$(ROOT)/rtl/common $(CORE_DEF) $(RTL_CFG) $(CORE_F) $(ROOT)/sim/tb/tg_tb_top.sv
	@echo "sim lint OK: $(CFG) $(CORE)"

REPLAY := $(BUILD_ROOT)/replay/tg_replay
replay: $(REPLAY)
$(REPLAY): $(ROOT)/sim/src/replay.cpp $(ROOT)/sim/src/lockstep.cpp $(ROOT)/sim/src/elfload.cpp $(HDRS)
	@mkdir -p $(dir $@)
	$(CXX) -std=c++20 -O2 -g -Wall -Wextra -I$(ROOT)/sim/src -I$(SPIKE_ROOT)/include \
	  $(ROOT)/sim/src/replay.cpp $(ROOT)/sim/src/lockstep.cpp $(ROOT)/sim/src/elfload.cpp \
	  -o $@ $(LDFLAGS_TB)
	@echo "built $@"

print-bin:
	@echo $(BUILD)/tg_vsim
print-build:
	@echo $(BUILD)
print-trace-stall:  # 1 when this core's tg_vsim has trace_stall_i
	@echo $(if $(filter 1,$(TRACE_STALL)),1,0)

clean:
	rm -rf $(BUILD_ROOT)
