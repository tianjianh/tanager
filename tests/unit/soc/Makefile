# SoC simulation test (docs/spec/soc.md).  make -C tests/unit/soc short | run KIND=core|trafgen|tcore [COMMIT_TRACE=0] [VIRTIO=1] [HOST_DMA=1]
# COMMIT_TRACE=0 builds without the commit trace (+define+TG_COMMIT_TRACE=0, DR-146). VIRTIO=1: with the
# forwarded virtio window, which the host serves (KIND=tcore; docs/spec/soc.md §8.1). HOST_DMA=1: with the
# coherent host DMA port, which the host uses on the program's buffers (KIND=tcore).
TOP    := tb_soc
KIND   ?= core
COMMIT_TRACE ?= 1
VIRTIO ?= 0
HOST_DMA ?= 0
NAME   := soc_$(KIND)$(if $(filter 0,$(COMMIT_TRACE)),_notrace)$(if $(filter 1,$(VIRTIO)),_virtio)$(if $(filter 1,$(HOST_DMA)),_hdma)
EXTRA_VFLAGS += $(if $(filter 0,$(COMMIT_TRACE)),+define+TG_COMMIT_TRACE=0)
TB     := $(CURDIR)/tb_soc.sv
PARAMS := -GKIND='"$(KIND)"' -GVIRTIO=$(VIRTIO) -GHOST_DMA=$(HOST_DMA)
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
	@$(MAKE) --no-print-directory run KIND=tcore VIRTIO=1 | grep -q "TEST PASSED" || { echo "FAIL tcore VIRTIO=1"; exit 1; }; echo "soc tcore with the virtio window: PASS"
	@$(MAKE) --no-print-directory run KIND=tcore HOST_DMA=1 | grep -q "TEST PASSED" || { echo "FAIL tcore HOST_DMA=1"; exit 1; }; echo "soc tcore with the host DMA port: PASS"
long: short
