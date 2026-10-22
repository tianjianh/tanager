# SoC simulation test (docs/spec/soc.md).  make -C tests/unit/soc short | sdirq | ipirace | run KIND=core|trafgen|tcore [COMMIT_TRACE=0] [VIRTIO=1] [HOST_DMA=1] [PS_WINDOW=1] [SDIRQ=1] [RELEASE=1]
# COMMIT_TRACE=0 builds without the commit trace (+define+TG_COMMIT_TRACE=0, DR-146). VIRTIO=1: with the
# forwarded virtio window, which the host serves (KIND=tcore; docs/spec/soc.md §8.1). HOST_DMA=1: with the
# coherent host DMA port, which the host uses on the program's buffers (KIND=tcore). PS_WINDOW=1: with stage D's
# PS window (+define+TG_PS_WINDOW=1, a map option), against a model of the PS (KIND=tcore; soc.md §8.2). LAT_INJ=0: a
# release build, without the two latency injectors (DR-177): the L2's banks straight to the DDR models. RELEASE=1:
# a release build as the board's product (tanager_soc RELEASE, DR-180), so LAT_INJ=0 and COMMIT_TRACE=0 as well:
# no host console (the bench reads the UART's own output), the PLIC's S contexts alone, no TTC1 source, the DMA
# port without completions or line counters. ipirace RELEASE=1 runs the directed IPI test on such a build.
TOP    := tb_soc
KIND   ?= core
COMMIT_TRACE ?= 1
VIRTIO ?= 0
HOST_DMA ?= 0
PS_WINDOW ?= 0
# SDIRQ=1: SD1's lost interrupt (with the PS window; KIND=tcore, or core for the real cores): sw/sd_irq.c against
# the PS model's SD-like device
SDIRQ  ?= 0
LAT_INJ ?= 1
RELEASE ?= 0
ifeq ($(RELEASE),1)
  ifneq ($(VIRTIO),0)
    $(error RELEASE=1 builds no virtio window (DR-180): leave VIRTIO at 0)
  endif
  override LAT_INJ := 0
  override COMMIT_TRACE := 0
endif
SDPROG ?= sd_irq            # sd_irq_smt2s: S-mode with ticks, the contender on hart 2 (KIND=core CFG=smt2)
NAME   := soc_$(KIND)$(if $(filter 0,$(COMMIT_TRACE)),_notrace)$(if $(filter 1,$(VIRTIO)),_virtio)$(if $(filter 1,$(HOST_DMA)),_hdma)$(if $(filter 1,$(PS_WINDOW)),_pswin)$(if $(filter 1,$(SDIRQ)),_sdirq)$(if $(filter 0,$(LAT_INJ)),_rel)$(if $(filter 1,$(RELEASE)),ease)
EXTRA_VFLAGS += $(if $(filter 0,$(COMMIT_TRACE)),+define+TG_COMMIT_TRACE=0) $(if $(filter 1,$(PS_WINDOW) $(SDIRQ)),+define+TG_PS_WINDOW=1)
# TB_SOC_CORE: the real cores are in (KIND=core), so the bench may name their insides (tb_soc's +ipi_race)
EXTRA_VFLAGS += $(if $(filter core,$(KIND)),+define+TB_SOC_CORE)
TB     := $(CURDIR)/tb_soc.sv
PARAMS := -GKIND='"$(KIND)"' -GVIRTIO=$(VIRTIO) -GHOST_DMA=$(HOST_DMA) -GSDIRQ=$(SDIRQ) -GLAT_INJ=$(LAT_INJ) -GRELEASE=$(RELEASE)
include ../common/unit.mk
ifeq ($(KIND),tcore)
# The verification track's test core stands in for tg_core (tcore_as_core.sv); rtl/core is left out.
RTL_SRCS := $(REPO)/rtl/common/cfg/tg_cfg_$(CFG).sv -F $(REPO)/rtl/common/common.f \
            -F $(REPO)/rtl/uncore/uncore.f -F $(REPO)/rtl/soc/soc.f \
            $(REPO)/sim/tcore/tg_tcore.sv $(CURDIR)/tcore_as_core.sv
ARGS = +prog=$(SOC_BUILD)/tests/soc_sw/$(if $(filter 1,$(SDIRQ)),$(strip $(SDPROG)),soc_test).bin
$(OUTDIR)/$(TOP): $(CURDIR)/tcore_as_core.sv
else
RTL_SRCS := $(REPO)/rtl/common/cfg/tg_cfg_$(CFG).sv -F $(REPO)/rtl/rtl.f
# The real cores: a change in the core, the SoC top or the shared packages rebuilds the model, as tests/unit/boot's
# (unit.mk names only the uncore's sources; without this a core fix ran on the old model)
$(OUTDIR)/$(TOP): $(wildcard $(REPO)/rtl/core/*.sv $(REPO)/rtl/core/*/*.sv $(REPO)/rtl/core/*.f $(REPO)/rtl/core/*/*.f) \
                  $(wildcard $(REPO)/rtl/soc/*.sv $(REPO)/rtl/common/*.sv $(REPO)/rtl/common/*/*.sv)
# SDIRQ=1 with KIND=core: the stress on the real cores
ARGS = $(if $(filter 1,$(SDIRQ)),+prog=$(SOC_BUILD)/tests/soc_sw/$(strip $(SDPROG)).bin)
endif

prog:
	@$(MAKE) --no-print-directory -C sw SOC_BUILD=$(SOC_BUILD)
short: prog
	@for k in core trafgen tcore; do $(MAKE) --no-print-directory run KIND=$$k | grep -q "TEST PASSED" || { echo "FAIL $$k"; exit 1; }; echo "soc $$k: PASS"; done
	@$(MAKE) --no-print-directory run KIND=tcore COMMIT_TRACE=0 | grep -q "TEST PASSED" || { echo "FAIL tcore COMMIT_TRACE=0"; exit 1; }; echo "soc tcore without the trace: PASS"
	@$(MAKE) --no-print-directory run KIND=tcore VIRTIO=1 | grep -q "TEST PASSED" || { echo "FAIL tcore VIRTIO=1"; exit 1; }; echo "soc tcore with the virtio window: PASS"
	@$(MAKE) --no-print-directory run KIND=tcore HOST_DMA=1 | grep -q "TEST PASSED" || { echo "FAIL tcore HOST_DMA=1"; exit 1; }; echo "soc tcore with the host DMA port: PASS"
	@$(MAKE) --no-print-directory run KIND=tcore PS_WINDOW=1 | grep -q "TEST PASSED" || { echo "FAIL tcore PS_WINDOW=1"; exit 1; }; echo "soc tcore with the PS window: PASS"
	@$(MAKE) --no-print-directory run KIND=tcore SDIRQ=1 HOST_DMA=1 | grep -q "TEST PASSED" || { echo "FAIL tcore SDIRQ=1 HOST_DMA=1"; exit 1; }; echo "soc tcore SD1 interrupt stress with DMA: PASS"
	@for k in trafgen tcore; do $(MAKE) --no-print-directory run KIND=$$k LAT_INJ=0 | grep -q "TEST PASSED" || { echo "FAIL $$k LAT_INJ=0"; exit 1; }; echo "soc $$k without the latency injectors (release): PASS"; done
	@$(MAKE) --no-print-directory run KIND=trafgen RELEASE=1 | grep -q "TEST PASSED" || { echo "FAIL trafgen RELEASE=1"; exit 1; }; echo "soc trafgen, a release build (DR-180): PASS"
	@$(MAKE) --no-print-directory run KIND=tcore RELEASE=1 HOST_DMA=1 PS_WINDOW=1 | grep -q "TEST PASSED" || { echo "FAIL tcore RELEASE=1 HOST_DMA=1 PS_WINDOW=1"; exit 1; }; echo "soc tcore, a release build with the DMA port and the PS window (DR-180): PASS"
# ipirace: the directed test of SD1's lost interrupt (10-20): on the real smt2 cores, in S-mode as Linux, an IPI to
# hart 0 (MSIP) made pending in the very cycle its LSU issues PLIC claim number IPIRACE (tb_soc +ipi_race). The ROB
# could take an interrupt in the cycle the LSU issues the head's MMIO load, so the claim went out, the load was
# flushed and read again after the trap: source 21 claimed twice, the first ID dropped, never completed (the
# board's capture). PASS when every request completes (after the core's fix); FAIL reproduces the board
IPIRACE ?= 100
ipirace: prog
	@$(MAKE) --no-print-directory run KIND=core CFG=smt2 SDIRQ=1 SDPROG=sd_irq_smt2s \
	  ARGS="+prog=$(SOC_BUILD)/tests/soc_sw/sd_irq_smt2s.bin +ipi_race=$(IPIRACE)" | tee $(SOC_BUILD)/tests/ipirace.log | grep -q "TEST PASSED" \
	  || { echo "FAIL ipirace: an IPI in claim $(IPIRACE)'s issue cycle lost SD1's interrupt ($(SOC_BUILD)/tests/ipirace.log)"; exit 1; }; \
	  echo "soc core ipirace (an IPI in claim $(IPIRACE)'s issue cycle): PASS"
# sdirq: SD1's interrupt stress on the real cores as well (each 15-25 minutes): st in M-mode; smt2 as Linux has it
# (S-mode, ticks, the contender on hart 2), without and with Sv39, the last with the host DMA port's data
sdirq: prog
	@$(MAKE) --no-print-directory run KIND=core SDIRQ=1 | grep -q "TEST PASSED" || { echo "FAIL core SDIRQ=1"; exit 1; }; echo "soc core SD1 interrupt stress (st, M-mode): PASS"
	@$(MAKE) --no-print-directory run KIND=core CFG=smt2 SDIRQ=1 SDPROG=sd_irq_smt2s | grep -q "TEST PASSED" || { echo "FAIL core smt2 sd_irq_smt2s"; exit 1; }; echo "soc core SD1 interrupt stress (smt2, S-mode): PASS"
	@$(MAKE) --no-print-directory run KIND=core CFG=smt2 SDIRQ=1 SDPROG=sd_irq_smt2v | grep -q "TEST PASSED" || { echo "FAIL core smt2 sd_irq_smt2v"; exit 1; }; echo "soc core SD1 interrupt stress (smt2, Sv39): PASS"
	@$(MAKE) --no-print-directory run KIND=core CFG=smt2 SDIRQ=1 HOST_DMA=1 SDPROG=sd_irq_smt2v | grep -q "TEST PASSED" || { echo "FAIL core smt2 sd_irq_smt2v HOST_DMA=1"; exit 1; }; echo "soc core SD1 interrupt stress (smt2, Sv39, DMA): PASS"
long: short
