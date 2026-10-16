# SoC simulation test (docs/spec/soc.md).  make -C tests/unit/soc short | run KIND=core|trafgen|tcore [COMMIT_TRACE=0]
# COMMIT_TRACE=0 builds without the commit trace (+define+TG_COMMIT_TRACE=0, DR-146).
TOP    := tb_soc
KIND   ?= core
COMMIT_TRACE ?= 1
NAME   := soc_$(KIND)$(if $(filter 0,$(COMMIT_TRACE)),_notrace)
EXTRA_VFLAGS += $(if $(filter 0,$(COMMIT_TRACE)),+define+TG_COMMIT_TRACE=0)
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
	@$(MAKE) --no-print-directory run KIND=tcore COMMIT_TRACE=0 | grep -q "TEST PASSED" || { echo "FAIL tcore COMMIT_TRACE=0"; exit 1; }; echo "soc tcore without the trace: PASS"
long: short
