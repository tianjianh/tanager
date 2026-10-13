# Unit tests of the memory-primitive wrappers (rtl/common/prim, spikes track).
#   make -C tests/unit/prim                      behavioural model and primitive mapping
#   make -C tests/unit/prim SEED=7 CYCLES=200000
# Objects go to $(TANAGER_BUILD)/<worktree>/unit_prim (conventions §1).
ROOT   := $(abspath ../../..)
SEED   ?= 1
CYCLES ?= 20000
OBJ    ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))/unit_prim
VFLAGS := --binary --timing -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -j 8 -I$(ROOT)/rtl/common
SRCS   := $(ROOT)/rtl/common/cfg/tg_cfg_st.sv $(ROOT)/rtl/common/tg_pkg.sv \
          $(ROOT)/rtl/common/prim/tg_ram_lut.sv tb_ram_lut.sv
MODELS := models/RAM64M8.sv models/RAM32M16.sv

.PHONY: all test clean
all: test
$(OBJ)/beh/Vtb_ram_lut: $(SRCS)
	mkdir -p $(OBJ)/beh && verilator $(VFLAGS) --Mdir $(OBJ)/beh --top-module tb_ram_lut $(SRCS) > /dev/null
$(OBJ)/prim/Vtb_ram_lut: $(SRCS) $(MODELS)
	mkdir -p $(OBJ)/prim && verilator $(VFLAGS) +define+TG_SIM_PRIMS --Mdir $(OBJ)/prim --top-module tb_ram_lut \
	  $(MODELS) $(SRCS) > /dev/null
test: $(OBJ)/beh/Vtb_ram_lut $(OBJ)/prim/Vtb_ram_lut
	$(OBJ)/beh/Vtb_ram_lut +seed=$(SEED) +cycles=$(CYCLES) | tee $(OBJ)/beh/run.log
	@grep -q '^PASS' $(OBJ)/beh/run.log
	$(OBJ)/prim/Vtb_ram_lut +seed=$(SEED) +cycles=$(CYCLES) | tee $(OBJ)/prim/run.log
	@grep -q '^PASS' $(OBJ)/prim/run.log
clean:
	rm -rf $(OBJ)
