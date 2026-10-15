# Unit test of tg_dsp_ctr (rtl/core/csr, R1): the behavioural model on Verilator, and the DSP48E2
# mapping on Icarus with the vendor's simulation model when both are installed.
#   make -C tests/unit/csr_ctr [SEED=1] [CYCLES=200000]
ROOT   := $(abspath ../../..)
ifeq ($(VERILATOR_ROOT),)
$(error source tools/env.sh first: the pinned Verilator is needed)
endif
SEED   ?= 1
CYCLES ?= 200000
OBJ    ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))/unit_csr_ctr
UNISIM := $(dir $(TANAGER_VIVADO_SETTINGS))data/verilog/src
SRC    := $(ROOT)/rtl/core/csr/tg_dsp_ctr.sv tb_dsp_ctr.sv
IWS    := 1 2 3

.PHONY: all
all:
	@set -e; for iw in $(IWS); do \
	  o=$(OBJ)/iw$$iw; mkdir -p $$o; \
	  verilator --binary --timing -Wno-fatal -j 8 --Mdir $$o --top-module tb_dsp_ctr -GIW=$$iw $(SRC) \
	    > $$o/build.log 2>&1 || { tail -20 $$o/build.log; exit 1; }; \
	  $$o/Vtb_dsp_ctr +seed=$(SEED) +cycles=$(CYCLES) | grep "tb_dsp_ctr IW" | sed "s/^/behavioural: /"; \
	  if command -v iverilog > /dev/null && [ -f $(UNISIM)/unisims/DSP48E2.v ]; then \
	    iverilog -g2012 -DTG_SIM_PRIMS -s tb_dsp_ctr -s glbl -P tb_dsp_ctr.IW=$$iw -o $$o/prim.vvp \
	      $(SRC) $(UNISIM)/glbl.v $(UNISIM)/unisims/DSP48E2.v > $$o/prim_build.log 2>&1 \
	      || { tail -20 $$o/prim_build.log; exit 1; }; \
	    vvp -n $$o/prim.vvp +seed=$(SEED) +cycles=$(CYCLES) | grep "tb_dsp_ctr IW" | sed "s/^/DSP48E2:     /"; \
	  fi; \
	done
