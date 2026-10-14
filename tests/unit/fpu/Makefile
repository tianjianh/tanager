# FPU unit tests (docs/spec/fpu.md, "Verification"). Run after `source tools/env.sh`.
#   make test            short regression (a few minutes): model check, TestFloat level 1 samples,
#                        directed and random tests on the RTL
#   make test-long       full regression: TestFloat level 1 and 2 for every operation (hours; -j8)
#   make model           bit-accurate Goldschmidt model against SoftFloat
#   make seed            regenerate the seed ROM (rtl/core/fpu/tg_fpu_seed_pkg.sv, seed_tab.h)
#   make tb              build the Verilator testbench (CFG=st by default; DIV=gs|r4 picks the
#                        Goldschmidt divider or the radix-4 fallback)
# Builds go to $TANAGER_BUILD/<worktree>/fpu (conventions §1).

ROOT     := $(abspath ../../..)
CFG      ?= st
BUILD    ?= $(TANAGER_BUILD)/$(notdir $(ROOT))/fpu
SOFTFLOAT ?= $(HOME)/src/tanager/berkeley-softfloat-3
SF_INC   := $(SOFTFLOAT)/source/include
SF_LIB   := $(SOFTFLOAT)/build/Linux-x86_64-GCC/softfloat.a
CXX      ?= g++-15
CXXFLAGS := -O2 -std=c++17 -Wall -I. -I$(SF_INC)
JOBS     ?= 8
VERILATOR ?= verilator

ifeq ($(TANAGER_BUILD),)
$(error run `source tools/env.sh` first)
endif

.PHONY: all model seed tb test test-long clean
all: test

$(BUILD):
	mkdir -p $@

seed:
	python3 gen_seed.py $(ROOT)/rtl/core/fpu/tg_fpu_seed_pkg.sv seed_tab.h

$(BUILD)/gs_check: gs_check.cpp gs_model.h fpu_ref.h operands.h seed_tab.h | $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ gs_check.cpp $(SF_LIB)

model: $(BUILD)/gs_check
	$(BUILD)/gs_check -n 2000000

# ---- RTL testbench ----
RTL_SRCS := $(shell sed -e 's://.*$$::' $(ROOT)/rtl/core/fpu/fpu.f | grep -v '^\s*$$' | sed -e 's:^:$(ROOT)/rtl/core/fpu/:')
DIV      ?= gs
ifeq ($(DIV),r4)
VDIR     := $(BUILD)/obj_$(CFG)_r4
DIV_G    := -GDIV_RADIX4=1
DIV_LAT  := FDIV_R4_LAT_S FDIV_R4_LAT_D FSQRT_R4_LAT_S FSQRT_R4_LAT_D
else
VDIR     := $(BUILD)/obj_$(CFG)
DIV_G    := -GDIV_RADIX4=0
DIV_LAT  := FDIV_GS_LAT_S FDIV_GS_LAT_D FSQRT_GS_LAT_S FSQRT_GS_LAT_D
endif
# The testbench checks latencies against the constants the core uses (tg_fpu_pkg).
pkg_int   = $(shell sed -n 's/.*localparam int $(1) *= *\([0-9]*\);.*/\1/p' $(ROOT)/rtl/common/tg_fpu_pkg.sv)
PKG_LAT  := -DFMA_LAT=$(call pkg_int,FMA_LAT) -DFMISC_LAT=$(call pkg_int,FMISC_LAT) \
            $(join -DFDIV_LAT_S= -DFDIV_LAT_D= -DFSQRT_LAT_S= -DFSQRT_LAT_D=,$(foreach c,$(DIV_LAT),$(call pkg_int,$(c))))
VFLAGS   := --cc --exe --build -j $(JOBS) -O3 --assert -Wall -Wno-fatal --top-module tg_fpu $(DIV_G) \
            -I$(ROOT)/rtl/common -I$(ROOT)/rtl/core/fpu $(ROOT)/rtl/lint.vlt \
            -CFLAGS "-O2 -std=c++17 -I$(CURDIR) -I$(SF_INC) $(PKG_LAT)" -LDFLAGS "$(SF_LIB)" \
            -MAKEFLAGS "OPT_FAST=-O3 OPT_GLOBAL=-O3 OPT_SLOW=-O1" --Mdir $(VDIR) -o tb_fpu

$(VDIR)/tb_fpu: tb_fpu.cpp fpu_ref.h operands.h gs_model.h seed_tab.h $(RTL_SRCS) $(ROOT)/rtl/common/tg_fpu_pkg.sv | $(BUILD)
	$(VERILATOR) $(VFLAGS) $(ROOT)/rtl/common/cfg/tg_cfg_$(CFG).sv -F $(ROOT)/rtl/common/common.f \
	  -F $(ROOT)/rtl/core/fpu/fpu.f $(CURDIR)/tb_fpu.cpp

tb: $(VDIR)/tb_fpu

test: model tb
	./run_tests.sh short $(VDIR)/tb_fpu

test-long: model tb
	./run_tests.sh long $(VDIR)/tb_fpu

clean:
	rm -rf $(BUILD)
