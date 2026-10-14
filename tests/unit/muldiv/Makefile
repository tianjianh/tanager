# Unit test of the integer multiplier and divider (rtl/core/exec/tg_mul.sv, tg_div.sv).
#   make -C tests/unit/muldiv                    build and run (SEED=1, N=20000 requests per unit)
#   make -C tests/unit/muldiv SEED=7 N=200000
#   make -C tests/unit/muldiv lint               verilator --lint-only -Wall, all four configurations
# Objects go to $(TANAGER_BUILD)/<worktree>/unit_muldiv (conventions §1).
ROOT   := $(abspath ../../..)
SEED   ?= 1
N      ?= 20000
CFG    ?= st
CFGS   := st smt2 st_w3 smt2_w3
OBJ    ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))/unit_muldiv
PKGS   := $(ROOT)/rtl/common/tg_pkg.sv $(ROOT)/rtl/common/tg_fpu_pkg.sv $(ROOT)/rtl/core/exec/tg_alu_pkg.sv \
          $(ROOT)/rtl/core/tg_core_pkg.sv
RTL    := $(ROOT)/rtl/common/prim/tg_ram_lut.sv $(ROOT)/rtl/common/prim/tg_fifo.sv $(ROOT)/rtl/core/fpu/tg_fpu_lzc.sv \
          $(ROOT)/rtl/core/exec/tg_mul.sv $(ROOT)/rtl/core/exec/tg_div.sv
VFLAGS := --binary --timing --assert -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -j 8 -I$(ROOT)/rtl/common
# rtl/lint.vlt plus lint.vlt here (package items these two units do not use)
LFLAGS := --lint-only --quiet-stats -Wall -Wno-MULTITOP -I$(ROOT)/rtl/common $(ROOT)/rtl/lint.vlt lint.vlt

.PHONY: all test lint clean
all: test
$(OBJ)/$(CFG)/Vtb_muldiv: $(ROOT)/rtl/common/cfg/tg_cfg_$(CFG).sv $(PKGS) $(RTL) tb_muldiv.sv
	mkdir -p $(OBJ)/$(CFG) && verilator $(VFLAGS) --Mdir $(OBJ)/$(CFG) --top-module tb_muldiv $^ > /dev/null
test: $(OBJ)/$(CFG)/Vtb_muldiv
	$< +seed=$(SEED) +n=$(N) | tee $(OBJ)/$(CFG)/run.log
	@grep -q '^PASS' $(OBJ)/$(CFG)/run.log
lint:
	@set -e; for c in $(CFGS); do \
	  verilator $(LFLAGS) $(ROOT)/rtl/common/cfg/tg_cfg_$$c.sv $(PKGS) $(RTL); echo "lint OK: $$c"; done
clean:
	rm -rf $(OBJ)
