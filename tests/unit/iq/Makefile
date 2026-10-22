# Unit test of the issue queue's per-thread caps flags (rtl/core/issue/tg_iq.sv; M7 step 7).
#   make -C tests/unit/iq                    build and run every variant (SEED=1, N=50000 cycles each)
#   make -C tests/unit/iq SEED=7 N=500000
#   make -C tests/unit/iq lint               verilator --lint-only -Wall, all four configurations
#   make -C tests/unit/iq cc                 tb_iqcc: the carry-chain readiness and select (CC) against the
#                                            LUT form, on the CARRY8 model (TG_SIM_PRIMS)
# Variants: ROWS x DW x the cap (50% or 75%) x BANK_CAP, the smt2 configuration (two threads).
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
# ROWS-DW-CAP_PCT-BANK_CAP: the smt2 queues (10, 6, 4 rows) at DW 2 and 3, both caps
VARIANTS := 10-2-50-1 6-2-50-1 4-2-50-1 10-2-75-0 6-2-75-1 10-3-50-1 6-3-50-0 4-3-75-1
# tb_iqcc's ROWS-DW-NCOL-RA-MX-CBLK-STALE-CC: the smt2 queues (ALU 10, FP 10 with the class block, LD 6, STA 4),
# no matrix with column clears, and sizes that leave partial stages and chains past one CARRY8; CC 3 both chains,
# 1 the readiness only, 2 the select only
CC_VARIANTS := 10-2-40-20-1-0-0-3 10-2-40-20-1-1-0-3 6-2-40-20-1-0-0-3 4-2-40-20-1-0-0-3 10-2-40-20-0-0-2-3 \
               5-2-17-7-1-0-0-3 3-3-9-4-1-1-0-3 2-2-26-2-1-0-0-3 1-1-5-2-1-0-0-3 12-3-64-30-1-1-2-3 \
               10-2-40-20-1-1-0-1 6-2-40-20-1-0-0-1 10-2-40-20-1-0-0-2 4-2-40-20-1-0-0-2

.PHONY: all test cc lint clean
all: test cc
define variant
$(OBJ)/$(1)/Vtb_iqcap: $(PKGS) $(RTL) tb_iqcap.sv
	mkdir -p $(OBJ)/$(1) && verilator $(VFLAGS) --Mdir $(OBJ)/$(1) --top-module tb_iqcap \
	  -GROWS=$(word 1,$(subst -, ,$(1))) -GDW=$(word 2,$(subst -, ,$(1))) \
	  -GCAP_PCT=$(word 3,$(subst -, ,$(1))) -GBANK_CAP=$(word 4,$(subst -, ,$(1))) $$^ > /dev/null
endef
$(foreach v,$(VARIANTS),$(eval $(call variant,$(v))))
test: $(foreach v,$(VARIANTS),$(OBJ)/$(v)/Vtb_iqcap)
	@set -e; for v in $(VARIANTS); do \
	  $(OBJ)/$$v/Vtb_iqcap +seed=$(SEED) +n=$(N) > $(OBJ)/$$v/run.log; grep -E '^(PASS|FAIL)' $(OBJ)/$$v/run.log; \
	  grep -q '^PASS' $(OBJ)/$$v/run.log; done
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
