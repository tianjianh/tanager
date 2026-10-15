# tg_dsp_reg2 (rtl/uncore/lib): the behavioural model on Verilator, and the DSP48E2 mapping on Icarus
# with the vendor's simulation model when both are installed (as tests/unit/prim does for tg_dsp_cmp).
#   make -C tests/unit/dsp_reg short
ROOT      := $(abspath ../../..)
SOC_BUILD ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))
OBJ       := $(SOC_BUILD)/tests/dsp_reg
UNISIM    := $(dir $(TANAGER_VIVADO_SETTINGS))data/verilog/src
WIDTHS    := 1 47 48 49 154 193
SEED      ?= 1
CYCLES    ?= 20000
SRC       := $(ROOT)/rtl/uncore/lib/tg_dsp_reg2.sv tb_dsp_reg.sv

.PHONY: short long
short:
	@set -e; for w in $(WIDTHS); do o=$(OBJ)/w$$w; mkdir -p $$o; \
	  verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_dsp_reg -GW=$$w \
	    --Mdir $$o -o tb $(SRC) > $$o/build.log 2>&1 || { tail -20 $$o/build.log; exit 1; }; \
	  $$o/tb +seed=$(SEED) +cycles=$(CYCLES) > $$o/run.log; \
	  echo "dsp_reg W $$w beh: $$(grep -E '^(PASS|FAIL)' $$o/run.log)"; grep -q '^PASS' $$o/run.log; \
	  if command -v iverilog > /dev/null && [ -f $(UNISIM)/unisims/DSP48E2.v ]; then \
	    iverilog -g2012 -DTG_SIM_PRIMS -s tb_dsp_reg -s glbl -P tb_dsp_reg.W=$$w -o $$o/prim.vvp \
	      $(SRC) $(UNISIM)/glbl.v $(UNISIM)/unisims/DSP48E2.v > $$o/prim_build.log 2>&1 || \
	      { tail -20 $$o/prim_build.log; exit 1; }; \
	    vvp -n $$o/prim.vvp +seed=$(SEED) +cycles=$(CYCLES) > $$o/prim_run.log; \
	    echo "dsp_reg W $$w DSP48E2 model: $$(grep -E '^(PASS|FAIL)' $$o/prim_run.log)"; \
	    grep -q '^PASS' $$o/prim_run.log; \
	  else echo "dsp_reg W $$w DSP48E2 model: skipped (needs iverilog and the Vivado install)"; fi; \
	done
long:
	@$(MAKE) --no-print-directory short CYCLES=200000 SEED=7
