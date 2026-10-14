# Unit tests of the primitive wrappers (rtl/common/prim, spikes track).
#   make -C tests/unit/prim                      behavioural model and primitive mapping
#   make -C tests/unit/prim SEED=7 CYCLES=200000
# Objects go to $(TANAGER_BUILD)/<worktree>/unit_prim (conventions §1).
ROOT   := $(abspath ../../..)
# The pinned Verilator (tools/env.sh); /usr/bin/verilator 5.020 gives wrong results here.
ifeq ($(VERILATOR_ROOT),)
$(error source tools/env.sh first: the pinned Verilator is needed, not /usr/bin/verilator)
endif
SEED   ?= 1
CYCLES ?= 20000
KEEP   ?= 0
OBJ    ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))/unit_prim
VFLAGS := --binary --timing -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -j 8 -I$(ROOT)/rtl/common
SRCS   := $(ROOT)/rtl/common/cfg/tg_cfg_st.sv $(ROOT)/rtl/common/tg_pkg.sv \
          $(ROOT)/rtl/common/prim/tg_ram_lut.sv tb_ram_lut.sv
SDP    := $(ROOT)/rtl/common/prim/tg_ram_sdp.sv tb_ram_sdp.sv
MODELS := models/RAM64M8.sv models/RAM32M16.sv models/SRL16E.sv models/SRLC32E.sv
FIFO   := $(ROOT)/rtl/common/prim/tg_ram_lut.sv $(ROOT)/rtl/common/prim/tg_fifo.sv tb_fifo.sv
# tg_fifo: STORAGE-DEPTH; "lutram" and "srl" also run on the primitive models (TG_SIM_PRIMS)
FIFO_V := lutram-2 lutram-4 lutram-16 lutram-64 reg-2 reg-4 reg-16 srl-2 srl-4 srl-16 srl-32
# tg_rom: PRIM-DEPTH-WIDTH-RD_LAT
ROM_V  := block-2048-9-2 block-512-36-1 distributed-64-16-1 distributed-100-37-2
# tg_dsp_cmp: W-SIGNED-LAT. The behavioural model runs on Verilator; the DSP48E2 mapping runs
# on Icarus with the vendor's simulation model (Verilator does not take that model), when
# both are installed.
DSP_V  := 32-0-1 32-1-2 48-0-1 48-0-2 48-1-1 47-1-1 40-1-2 16-0-2 1-0-1
UNISIM := $(dir $(TANAGER_VIVADO_SETTINGS))data/verilog/src

.PHONY: all test fifo rom dsp clean
all: test
fifo:
	@set -e; for v in $(FIFO_V); do st=$${v%-*}; d=$${v#*-}; \
	  for m in beh prim; do \
	    if [ $$m = prim ] && [ $$st = reg ]; then continue; fi; \
	    if [ $$m = prim ]; then x="+define+TG_SIM_PRIMS $(MODELS)"; else x=""; fi; \
	    o=$(OBJ)/fifo_$${v}_$$m; mkdir -p $$o; \
	    verilator $(VFLAGS) $$x --Mdir $$o --top-module tb_fifo -GSTORAGE='"'$$st'"' -GDEPTH=$$d \
	      $(FIFO) > $$o/build.log 2>&1 || { tail -20 $$o/build.log; exit 1; }; \
	    $$o/Vtb_fifo +seed=$(SEED) +cycles=$(CYCLES) > $$o/run.log; \
	    echo "fifo $$v $$m: $$(grep -E '^(PASS|FAIL)' $$o/run.log)"; grep -q '^PASS' $$o/run.log; \
	  done; \
	done
$(OBJ)/beh/Vtb_ram_lut: $(SRCS)
	mkdir -p $(OBJ)/beh && verilator $(VFLAGS) --Mdir $(OBJ)/beh --top-module tb_ram_lut $(SRCS) > /dev/null
$(OBJ)/prim/Vtb_ram_lut: $(SRCS) $(MODELS)
	mkdir -p $(OBJ)/prim && verilator $(VFLAGS) +define+TG_SIM_PRIMS --Mdir $(OBJ)/prim --top-module tb_ram_lut \
	  $(MODELS) $(SRCS) > /dev/null
$(OBJ)/sdp/Vtb_ram_sdp: $(SDP)
	mkdir -p $(OBJ)/sdp && verilator $(VFLAGS) --Mdir $(OBJ)/sdp --top-module tb_ram_sdp $(SDP) > /dev/null
rom:
	@set -e; for v in $(ROM_V); do pr=$${v%%-*}; x=$${v#*-}; d=$${x%%-*}; x=$${x#*-}; \
	  w=$${x%%-*}; l=$${x#*-}; \
	  o=$(OBJ)/rom_$$v; mkdir -p $$o; \
	  verilator $(VFLAGS) --Mdir $$o --top-module tb_rom -GPRIM='"'$$pr'"' -GDEPTH=$$d -GWIDTH=$$w \
	    -GRD_LAT=$$l $(ROOT)/rtl/common/prim/tg_rom.sv tb_rom.sv > $$o/build.log 2>&1 || \
	    { tail -20 $$o/build.log; exit 1; }; \
	  $$o/Vtb_rom +seed=$(SEED) +cycles=$(CYCLES) > $$o/run.log; \
	  echo "rom $$v: $$(grep -E '^(PASS|FAIL)' $$o/run.log)"; grep -q '^PASS' $$o/run.log; \
	done
dsp:
	@set -e; for v in $(DSP_V); do w=$${v%%-*}; x=$${v#*-}; sg=$${x%%-*}; l=$${x#*-}; \
	  o=$(OBJ)/dsp_$$v; mkdir -p $$o; \
	  verilator $(VFLAGS) --Mdir $$o --top-module tb_dsp_cmp -GW=$$w -GSIGNED=$$sg -GLAT=$$l \
	    $(ROOT)/rtl/common/prim/tg_dsp_cmp.sv tb_dsp_cmp.sv > $$o/build.log 2>&1 || \
	    { tail -20 $$o/build.log; exit 1; }; \
	  $$o/Vtb_dsp_cmp +seed=$(SEED) +cycles=$(CYCLES) > $$o/run.log; \
	  echo "dsp $$v beh: $$(grep -E '^(PASS|FAIL)' $$o/run.log)"; grep -q '^PASS' $$o/run.log; \
	  if command -v iverilog > /dev/null && [ -f $(UNISIM)/unisims/DSP48E2.v ]; then \
	    iverilog -g2012 -DTG_SIM_PRIMS -s tb_dsp_cmp -s glbl -P tb_dsp_cmp.W=$$w \
	      -P tb_dsp_cmp.SIGNED=$$sg -P tb_dsp_cmp.LAT=$$l -o $$o/prim.vvp \
	      $(ROOT)/rtl/common/prim/tg_dsp_cmp.sv tb_dsp_cmp.sv $(UNISIM)/glbl.v \
	      $(UNISIM)/unisims/DSP48E2.v > $$o/prim_build.log 2>&1 || { tail -20 $$o/prim_build.log; exit 1; }; \
	    vvp -n $$o/prim.vvp +seed=$(SEED) +cycles=$(CYCLES) > $$o/prim_run.log; \
	    echo "dsp $$v DSP48E2 model: $$(grep -E '^(PASS|FAIL)' $$o/prim_run.log)"; \
	    grep -q '^PASS' $$o/prim_run.log; \
	  else echo "dsp $$v DSP48E2 model: skipped (needs iverilog and the Vivado install)"; fi; \
	done
test: $(OBJ)/beh/Vtb_ram_lut $(OBJ)/prim/Vtb_ram_lut $(OBJ)/sdp/Vtb_ram_sdp fifo rom dsp
	$(OBJ)/beh/Vtb_ram_lut +seed=$(SEED) +cycles=$(CYCLES) | tee $(OBJ)/beh/run.log
	@grep -q '^PASS' $(OBJ)/beh/run.log
	$(OBJ)/prim/Vtb_ram_lut +seed=$(SEED) +cycles=$(CYCLES) | tee $(OBJ)/prim/run.log
	@grep -q '^PASS' $(OBJ)/prim/run.log
	$(OBJ)/sdp/Vtb_ram_sdp +seed=$(SEED) +cycles=$(CYCLES) | tee $(OBJ)/sdp/run.log
	@grep -q '^PASS' $(OBJ)/sdp/run.log
	@# keep only the logs (conventions §9: disk); KEEP=1 keeps the objects
	@[ "$(KEEP)" = 1 ] || find $(OBJ) -type f ! -name '*.log' -delete
clean:
	rm -rf $(OBJ)
