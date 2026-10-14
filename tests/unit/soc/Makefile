# SoC simulation test (docs/spec/soc.md).  make -C tests/unit/soc short | run KIND=core|trafgen
TOP    := tb_soc
KIND   ?= core
NAME   := soc_$(KIND)
TB     := $(CURDIR)/tb_soc.sv
PARAMS := -GKIND='"$(KIND)"'
include ../common/unit.mk
ifeq ($(KIND),tcore)
# The verification track's test core stands in for tg_core (tcore_as_core.sv); rtl/core is left out.
RTL_SRCS := $(REPO)/rtl/common/cfg/tg_cfg_$(CFG).sv -F $(REPO)/rtl/common/common.f \
            -F $(REPO)/rtl/uncore/uncore.f -F $(REPO)/rtl/soc/soc.f \
            $(REPO)/sim/tcore/tg_tcore.sv $(CURDIR)/tcore_as_core.sv
ARGS = +prog=$(SOC_BUILD)/tests/soc_sw/soc_test.bin
$(OUTDIR)/$(TOP): $(CURDIR)/tcore_as_core.sv
else
RTL_SRCS := $(REPO)/rtl/common/cfg/tg_cfg_$(CFG).sv -F $(REPO)/rtl/rtl.f
endif

prog:
	@$(MAKE) --no-print-directory -C sw SOC_BUILD=$(SOC_BUILD)
short: prog
	@for k in core trafgen tcore; do $(MAKE) --no-print-directory run KIND=$$k | grep -q "TEST PASSED" || { echo "FAIL $$k"; exit 1; }; echo "soc $$k: PASS"; done
long: short
