# Unit test of the issue queue (rtl/core/issue/tg_iq.sv): tb_iqcc, the carry-chain readiness and select (CC, the area
# pass's lever 2) against the LUT form, on the CARRY8 model (TG_SIM_PRIMS).
#   make -C tests/unit/iq                    build and run every variant (SEED=1, N=50000 cycles each)
#   make -C tests/unit/iq SEED=7 N=500000
#   make -C tests/unit/iq lint               verilator --lint-only -Wall, all four configurations
# Objects go to $(TANAGER_BUILD)/<worktree>/unit_iq (conventions §1).
ROOT   := $(abspath ../../..)
SEED   ?= 1
N      ?= 50000
CFGS   := st smt2 st_w3 smt2_w3
OBJ    ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))/unit_iq
PKGS   := $(ROOT)/rtl/common/cfg/tg_cfg_smt2.sv $(ROOT)/rtl/common/tg_pkg.sv
RTL    := $(ROOT)/rtl/common/prim/tg_ram_lut.sv $(ROOT)/rtl/core/issue/tg_iq.sv
VFLAGS := --binary --timing --assert -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -j 8 -I$(ROOT)/rtl/common
LFLAGS := --lint-only --quiet-stats -Wall -Wno-MULTITOP -I$(ROOT)/rtl/common $(ROOT)/rtl/lint.vlt lint.vlt
# tb_iqcc's ROWS-DW-NCOL-RA-MX-CBLK-STALE-CC: the smt2 queues (ALU 10, FP 10 with the class block, LD 6, STA 4),
# no matrix with column clears, and sizes that leave partial stages and chains past one CARRY8; CC 3 both chains,
# 1 the readiness only (the core's), 2 the select only
CC_VARIANTS := 10-2-40-20-1-0-0-3 10-2-40-20-1-1-0-3 6-2-40-20-1-0-0-3 4-2-40-20-1-0-0-3 10-2-40-20-0-0-2-3 \
               5-2-17-7-1-0-0-3 3-3-9-4-1-1-0-3 2-2-26-2-1-0-0-3 1-1-5-2-1-0-0-3 12-3-64-30-1-1-2-3 \
               10-2-40-20-1-1-0-1 6-2-40-20-1-0-0-1 10-2-40-20-1-0-0-2 4-2-40-20-1-0-0-2

.PHONY: all cc lint clean
all: cc
define cc_variant
$(OBJ)/cc-$(1)/Vtb_iqcc: $(PKGS) $(RTL) models/CARRY8.sv tb_iqcc.sv
	mkdir -p $(OBJ)/cc-$(1) && verilator $(VFLAGS) +define+TG_SIM_PRIMS --Mdir $(OBJ)/cc-$(1) --top-module tb_iqcc \
	  -GROWS=$(word 1,$(subst -, ,$(1))) -GDW=$(word 2,$(subst -, ,$(1))) -GNCOL=$(word 3,$(subst -, ,$(1))) \
	  -GRA=$(word 4,$(subst -, ,$(1))) -GMX=$(word 5,$(subst -, ,$(1))) -GCBLK=$(word 6,$(subst -, ,$(1))) \
	  -GSTALE=$(word 7,$(subst -, ,$(1))) -GCCV=$(word 8,$(subst -, ,$(1))) $$^ > /dev/null
endef
$(foreach v,$(CC_VARIANTS),$(eval $(call cc_variant,$(v))))
cc: $(foreach v,$(CC_VARIANTS),$(OBJ)/cc-$(v)/Vtb_iqcc)
	@set -e; for v in $(CC_VARIANTS); do \
	  $(OBJ)/cc-$$v/Vtb_iqcc +seed=$(SEED) +n=$(N) > $(OBJ)/cc-$$v/run.log; grep -E '^(PASS|FAIL)' $(OBJ)/cc-$$v/run.log; \
	  grep -q '^PASS' $(OBJ)/cc-$$v/run.log; done
lint:
	@set -e; for c in $(CFGS); do \
	  verilator $(LFLAGS) $(ROOT)/rtl/common/cfg/tg_cfg_$$c.sv $(ROOT)/rtl/common/tg_pkg.sv $(RTL); echo "lint OK: $$c"; done
clean:
	rm -rf $(OBJ)
