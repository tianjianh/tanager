# SoC simulation test (docs/spec/soc.md).  make -C tests/unit/soc short | run KIND=core|trafgen
TOP    := tb_soc
KIND   ?= core
NAME   := soc_$(KIND)
TB     := $(CURDIR)/tb_soc.sv
PARAMS := -GKIND='"$(KIND)"'
include ../common/unit.mk
RTL_SRCS := $(REPO)/rtl/common/cfg/tg_cfg_$(CFG).sv -F $(REPO)/rtl/rtl.f
short:
	@for k in core trafgen; do $(MAKE) --no-print-directory run KIND=$$k | grep -q "TEST PASSED" || { echo "FAIL $$k"; exit 1; }; echo "soc $$k: PASS"; done
long: short
