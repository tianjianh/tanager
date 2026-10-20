# Unit test of tg_urf (rtl/core/regfile; URF, DR-174), the double-pumped UltraRAM register file, against
# tg_ram_lut banks (tb_urf.sv) in the shapes the core builds (NE x NL early and late ports: 3 x 3 in st and
# smt2, 4 x 4 in the w3 configurations). Each shape runs tg_urf's simulation body (clk alone), and its
# UltraRAM body on spikes-2's UG573 model and, when Vivado is installed, on the vendor's model (made
# Verilator-compatible: its unconnected-pin z tests dropped; tg_urf drives every pin). Then the negative
# tests, which must fail: a model doing port B's operation before port A's, and clk2x at the core rate.
#   make -C tests/unit/urf [CYCLES=200000]
ROOT   := $(abspath ../../..)
ifeq ($(VERILATOR_ROOT),)
$(error source tools/env.sh first: the pinned Verilator is needed)
endif
CYCLES ?= 200000
OBJ    ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))/unit_urf
UNISIM := $(dir $(TANAGER_VIVADO_SETTINGS))data/verilog/src
SRC    := $(ROOT)/rtl/common/prim/tg_ram_lut.sv $(ROOT)/rtl/core/regfile/tg_urf.sv tb_urf.sv
PRIMS  := $(ROOT)/tests/unit/prim/models/RAM64M8.sv
SHAPES := 3x3 4x4
VFLAGS := --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-PROCASSINIT -j 8
VSRC   := $(UNISIM)/unisims/URAM288_BASE.v
VENDOR := $(if $(wildcard $(VSRC)),$(OBJ)/URAM288_BASE_vl.v)

.PHONY: all neg
all: $(VENDOR)
	@set -e; for s in $(SHAPES); do ne=$${s%x*}; nl=$${s#*x}; \
	  for v in clk-only ug573 $(if $(VENDOR),vendor); do \
	    o=$(OBJ)/$$v-$$s; mkdir -p $$o; top=tb_urf; \
	    case $$v in \
	      clk-only) defs=""; srcs="$(SRC)" ;; \
	      ug573)    defs="+define+TG_SIM_PRIMS"; srcs="URAM288_BASE.sv $(PRIMS) $(SRC)" ;; \
	      vendor)   defs="+define+TG_SIM_PRIMS"; srcs="$(VENDOR) $(UNISIM)/glbl.v $(PRIMS) $(SRC) vl_top.sv"; top=vl_top ;; \
	    esac; \
	    verilator $(VFLAGS) --Mdir $$o --top-module $$top -GNE=$$ne -GNL=$$nl -GCYCLES=$(CYCLES) $$defs $$srcs \
	      > $$o/build.log 2>&1 || { tail -20 $$o/build.log; exit 1; }; \
	    $$o/V$$top > $$o/run.log 2>&1 || true; \
	    grep -q "TB_URF PASS" $$o/run.log || { echo "$$v $$s: FAIL (log: $$o/run.log)"; \
	      grep -E "TB_URF|MISMATCH|Fatal" $$o/run.log | head -5; exit 1; }; \
	    echo "$$v $$s: $$(grep "TB_URF PASS" $$o/run.log)"; \
	  done; \
	done
	@$(MAKE) --no-print-directory neg
	@echo "tg_urf unit test: PASS"

# Both must fail: the reads of the last cycle's write go wrong with B first, and tg_urf's check stops a
# run whose clk2x does not rise twice a core cycle
neg:
	@set -e; o=$(OBJ)/neg-b-first; mkdir -p $$o; \
	verilator $(VFLAGS) --Mdir $$o --top-module tb_urf -GCYCLES=$(CYCLES) +define+TG_SIM_PRIMS +define+TB_URAM_B_FIRST \
	  URAM288_BASE.sv $(PRIMS) $(SRC) > $$o/build.log 2>&1 || { tail -20 $$o/build.log; exit 1; }; \
	$$o/Vtb_urf > $$o/run.log 2>&1 || true; \
	grep -q "TB_URF FAIL" $$o/run.log || { echo "negative, port B before port A: did not fail (log: $$o/run.log)"; exit 1; }; \
	echo "negative, port B before port A: fails, as it must ($$(grep -o "[0-9]* mismatches" $$o/run.log))"; \
	o=$(OBJ)/neg-slow-clk2x; mkdir -p $$o; \
	verilator $(VFLAGS) --Mdir $$o --top-module tb_urf -GCYCLES=$(CYCLES) +define+TG_SIM_PRIMS +define+TB_SLOW_CLK2X \
	  URAM288_BASE.sv $(PRIMS) $(SRC) > $$o/build.log 2>&1 || { tail -20 $$o/build.log; exit 1; }; \
	$$o/Vtb_urf > $$o/run.log 2>&1 || true; \
	grep -q "clk2x rose 1 times" $$o/run.log || { echo "negative, clk2x at the core rate: not stopped (log: $$o/run.log)"; exit 1; }; \
	echo "negative, clk2x at the core rate: stopped by tg_urf's check, as it must"

$(OBJ)/URAM288_BASE_vl.v: $(VSRC)
	@mkdir -p $(OBJ)
	@sed -E -e "s/\(([A-Za-z_0-9]+(\[[0-9]+\])?) !== 1'bz\) && //g" \
	        -e "s/\(([A-Za-z_0-9]+(\[[0-9]+\])?) === 1'bz\) \|\| //g" \
	        -e "s/^(\s*)tri0 glblGSR/\1wire glblGSR/" $< > $@
