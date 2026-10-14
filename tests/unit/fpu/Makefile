# FPU unit tests (docs/spec/fpu.md, "Verification"). Run after `source tools/env.sh`.
#   make test            short regression (a few minutes): model check, TestFloat level 1 samples,
#                        directed and random tests on the RTL
#   make test-long       full regression: TestFloat level 1 and 2 for every operation (hours; -j8)
#   make model           bit-accurate Goldschmidt and radix-4 models against SoftFloat
#   make seed            regenerate the seed ROM (rtl/core/fpu/tg_fpu_seed_pkg.sv, seed_tab.h)
#   make tb              build the Verilator testbench (CFG=st by default; DIV=gs|r4 picks the
#                        Goldschmidt divider or the radix-4 fallback)
#   make tbx             build the FP back-end testbench (tg_fp_exec with tg_fprf and tg_fpu;
#                        CFG=st|smt2|st_w3|smt2_w3, DIV=gs|r4)
#   make tbc             build the fcsr testbench (tg_fcsr)
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

.PHONY: all model seed tb tbx tbc test test-long test-be clean
all: test

$(BUILD):
	mkdir -p $@

seed:
	python3 gen_seed.py $(ROOT)/rtl/core/fpu/tg_fpu_seed_pkg.sv seed_tab.h

$(BUILD)/gs_check: gs_check.cpp gs_model.h fpu_ref.h operands.h seed_tab.h | $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ gs_check.cpp $(SF_LIB)

$(BUILD)/r4_check: r4_check.cpp r4_model.h gs_model.h fpu_ref.h operands.h seed_tab.h | $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ r4_check.cpp $(SF_LIB)

model: $(BUILD)/gs_check $(BUILD)/r4_check
	$(BUILD)/gs_check -n 2000000
	$(BUILD)/r4_check -n 500000

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

# ---- FP back end (docs/spec/fpu.md, "Core integration") ----
CFG_F    := $(ROOT)/rtl/common/cfg/tg_cfg_$(CFG).sv
cfg_int   = $(shell sed -n 's/.*localparam int $(1) *= *\([0-9]*\);.*/\1/p' $(CFG_F))
CFG_DEFS := -DROB_ENTRIES=$(call cfg_int,ROB_ENTRIES) -DLLT_ENTRIES=$(call cfg_int,LLT_ENTRIES) \
            -DTID_W=$(call cfg_int,TID_W) -DFP_PREGS=$(call cfg_int,FP_PREGS_PER_BANK) \
            -DINT_PREGS=$(call cfg_int,INT_PREGS_PER_BANK) -DDECODE_WIDTH=$(call cfg_int,DECODE_WIDTH)
BE_SRCS  := $(ROOT)/rtl/core/exec/tg_alu_pkg.sv $(ROOT)/rtl/core/tg_core_pkg.sv \
            $(addprefix $(ROOT)/rtl/core/fpu/,$(shell sed -e 's://.*$$::' $(ROOT)/rtl/core/fpu/fpu_be.f | grep -v '^\s*$$'))
XDIR     := $(BUILD)/objx_$(CFG)$(if $(filter r4,$(DIV)),_r4,)
XFLAGS   := --cc --exe --build -j $(JOBS) -O3 --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
            -I$(ROOT)/rtl/common -I$(ROOT)/rtl/core/fpu $(ROOT)/rtl/lint.vlt \
            -CFLAGS "-O2 -std=c++17 -I$(CURDIR) -I$(SF_INC) $(PKG_LAT) $(CFG_DEFS)" -LDFLAGS "$(SF_LIB)" \
            -MAKEFLAGS "OPT_FAST=-O3 OPT_GLOBAL=-O3 OPT_SLOW=-O1"
$(XDIR)/tb_fpx: tb_fpx.cpp tb_fpx_top.sv tf_table.h fpu_ref.h operands.h $(RTL_SRCS) $(BE_SRCS) $(ROOT)/rtl/common/tg_fpu_pkg.sv | $(BUILD)
	$(VERILATOR) $(XFLAGS) --top-module tb_fpx_top -GDIV_RADIX4=$(if $(filter r4,$(DIV)),1,0) --Mdir $(XDIR) -o tb_fpx \
	  $(CFG_F) -F $(ROOT)/rtl/common/common.f -F $(ROOT)/rtl/core/fpu/fpu.f $(BE_SRCS) $(CURDIR)/tb_fpx_top.sv \
	  $(CURDIR)/tb_fpx.cpp
tbx: $(XDIR)/tb_fpx

CDIR     := $(BUILD)/objc_$(CFG)
$(CDIR)/tb_fcsr: tb_fcsr.cpp $(BE_SRCS) | $(BUILD)
	$(VERILATOR) --cc --exe --build -j $(JOBS) -O3 --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM --top-module tg_fcsr \
	  -I$(ROOT)/rtl/common -I$(ROOT)/rtl/core/fpu $(ROOT)/rtl/lint.vlt \
	  -CFLAGS "-O2 -std=c++17 $(CFG_DEFS)" --Mdir $(CDIR) -o tb_fcsr \
	  $(CFG_F) -F $(ROOT)/rtl/common/common.f -F $(ROOT)/rtl/core/fpu/fpu.f $(BE_SRCS) $(CURDIR)/tb_fcsr.cpp
tbc: $(CDIR)/tb_fcsr

test-be: tbx tbc
	./run_be_tests.sh short $(XDIR)/tb_fpx $(CDIR)/tb_fcsr

test: model tb
	./run_tests.sh short $(VDIR)/tb_fpu

test-long: model tb
	./run_tests.sh long $(VDIR)/tb_fpu

clean:
	rm -rf $(BUILD)
