# Unit tests of the memory-primitive wrappers (rtl/common/prim, spikes track).
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
MODELS := models/RAM64M8.sv models/RAM32M16.sv

.PHONY: all test clean
all: test
$(OBJ)/beh/Vtb_ram_lut: $(SRCS)
	mkdir -p $(OBJ)/beh && verilator $(VFLAGS) --Mdir $(OBJ)/beh --top-module tb_ram_lut $(SRCS) > /dev/null
$(OBJ)/prim/Vtb_ram_lut: $(SRCS) $(MODELS)
	mkdir -p $(OBJ)/prim && verilator $(VFLAGS) +define+TG_SIM_PRIMS --Mdir $(OBJ)/prim --top-module tb_ram_lut \
	  $(MODELS) $(SRCS) > /dev/null
$(OBJ)/sdp/Vtb_ram_sdp: $(SDP)
	mkdir -p $(OBJ)/sdp && verilator $(VFLAGS) --Mdir $(OBJ)/sdp --top-module tb_ram_sdp $(SDP) > /dev/null
test: $(OBJ)/beh/Vtb_ram_lut $(OBJ)/prim/Vtb_ram_lut $(OBJ)/sdp/Vtb_ram_sdp
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
