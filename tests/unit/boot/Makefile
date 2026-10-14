# Software boot on tanager_soc with the real core (docs/spec/soc.md §Verification).
#   make -C tests/unit/boot opensbi [CORES=1|2] [CFG=st|smt2]  boot ROM -> OpenSBI, passes on the full banner
#   make -C tests/unit/boot linux-kernel [CORES=1]  Linux (Buildroot's lp64d Image) to "Run /init", with a
#                                                   device tree without F/D: the kernel needs no FPU
#   make -C tests/unit/boot linux [CORES=1|2]       the full lp64d boot to TANAGER-BOOT-OK (the init
#                                                   script), with the FPU in the device tree
#   make -C tests/unit/boot run CORES=2 ARGS="+fw=... +dtb=... +expect=... +max_mcycles=N"
#   ARGS= adds plusargs to any of them, for example ARGS="+dump_pc=<hex> +dump_stop" (tb_boot.sv)
# Images: OpenSBI fw_jump from sw/build_opensbi.sh (pinned source; built on first use), a device
# tree built here for CORES x threads of the configuration, 128 MiB, no FPU.
# The core builds with its own switches: every M3 feature, F and D included, is on by default (main b53b0a5).
TOP    := tb_boot
CORES  ?= 1
# VTHREADS: Verilator --threads (conventions §9); each count builds in its own directory. Measured on
# OpenSBI (2026-10-14, host load about 17): 2x1 runs 1.5x faster with 4 threads (193 s against 286 s),
# 1x1 20% slower (133 s against 111 s). So two cores use 4 threads and one core uses 1.
VTHREADS ?= $(if $(filter 1,$(CORES)),1,4)
NAME   := boot_c$(CORES)_t$(VTHREADS)
TB     := $(CURDIR)/tb_boot.sv
PARAMS := -GN_CORES=$(CORES)
EXTRA_VFLAGS := -CFLAGS -O2 $(if $(filter-out 1,$(VTHREADS)),--threads $(VTHREADS))
include ../common/unit.mk

THREADS := $(if $(filter smt2%,$(CFG)),2,1)
# MCYC: the OpenSBI runs' cycle limit, in millions (the banner comes by 10.7 M cycles at 2x2)
MCYC    ?= 20
OSBI_FW := $(SOC_BUILD)/opensbi/platform/generic/firmware/fw_jump.bin
FW      ?= $(OSBI_FW)
DTB     := $(OUTDIR)/dts/tanager-kv260.dtb

CORE_DIR := $(REPO)/rtl/core
RTL_SRCS := $(REPO)/rtl/common/cfg/tg_cfg_$(CFG).sv -F $(REPO)/rtl/common/common.f -F $(CORE_DIR)/core.f \
            -F $(REPO)/rtl/uncore/uncore.f -F $(REPO)/rtl/soc/soc.f
# Any change in the core, the SoC top or the shared packages rebuilds the model
$(OUTDIR)/$(TOP): $(wildcard $(CORE_DIR)/*.sv $(CORE_DIR)/*/*.sv $(CORE_DIR)/*.f $(CORE_DIR)/*/*.f) \
                  $(wildcard $(REPO)/rtl/soc/*.sv $(REPO)/rtl/soc/*.f $(REPO)/rtl/common/*.sv $(REPO)/rtl/common/*/*.sv)

# BOOTARGS: the kernel command line in the device trees (earlycon=sbi prints through OpenSBI)
BOOTARGS ?= console=ttyS0,115200 earlycon
$(DTB): $(REPO)/sw/dts/tanager-kv260.dts $(REPO)/sw/dts/tanager.dtsi Makefile
	$(MAKE) --no-print-directory -B -C $(REPO)/sw/dts O=$(OUTDIR)/dts CORES=$(CORES) THREADS=$(THREADS) MEM=0x08000000 FPU=0 BOOTARGS="$(BOOTARGS)"
DTB_FPU := $(OUTDIR)/dts-fpu/tanager-kv260.dtb
$(DTB_FPU): $(REPO)/sw/dts/tanager-kv260.dts $(REPO)/sw/dts/tanager.dtsi Makefile
	$(MAKE) --no-print-directory -B -C $(REPO)/sw/dts O=$(OUTDIR)/dts-fpu CORES=$(CORES) THREADS=$(THREADS) MEM=0x08000000 FPU=1 BOOTARGS="$(BOOTARGS)"

KERNEL     ?= $(SOC_BUILD)/br-tanager_lp64d/images/Image
LINUX_MCYC ?= 1500
$(KERNEL):
	@echo "no $(KERNEL): build it with sw/build_linux.sh"; exit 1

$(OSBI_FW):
	bash $(REPO)/sw/build_opensbi.sh

.PHONY: opensbi
opensbi: build $(DTB) $(FW)
	$(OUTDIR)/$(TOP) +fw=$(FW) +dtb=$(DTB) +expect="Boot HART MEDELEG" +max_mcycles=$(MCYC) $(ARGS)

.PHONY: linux-kernel linux $(DTB) $(DTB_FPU)
linux-kernel: build $(DTB) $(FW) $(KERNEL)
	$(OUTDIR)/$(TOP) +fw=$(FW) +dtb=$(DTB) +kernel=$(KERNEL) +expect="Run /init as init process" +max_mcycles=$(LINUX_MCYC) $(ARGS)
linux: build $(DTB_FPU) $(FW) $(KERNEL)
	$(OUTDIR)/$(TOP) +fw=$(FW) +dtb=$(DTB_FPU) +kernel=$(KERNEL) +expect="TANAGER-BOOT-OK" +max_mcycles=$(LINUX_MCYC) $(ARGS)

# The boots take minutes: only the long suite runs them, OpenSBI in 1x1, 2x1 and 2x2 at once
# (cores x threads; 2x2 is CFG=smt2), each built with -j3 so the three builds stay within -j8 or so.
# Each run's log: $(SOC_BUILD)/tests/boot_logs/<run>.log.
LONG_RUNS := osbi-st-1 osbi-st-2 osbi-smt2-2
LOGDIR    := $(SOC_BUILD)/tests/boot_logs
.PHONY: short long $(LONG_RUNS)
short:
	@echo "boot: skipped in the short suite (make -C tests/unit/boot long)"
long:
	@$(MAKE) --no-print-directory -j$(words $(LONG_RUNS)) $(LONG_RUNS)
$(LONG_RUNS): osbi-%:
	@mkdir -p $(LOGDIR)
	@set -- $(subst -, ,$*); \
	if $(MAKE) --no-print-directory opensbi CFG=$$1 CORES=$$2 JOBS=3 > $(LOGDIR)/$@.log 2>&1 && grep -q "TEST PASSED" $(LOGDIR)/$@.log; \
	then echo "boot OpenSBI $$1, $$2 core(s): PASS"; else echo "FAIL boot OpenSBI $$1, $$2 core(s) ($(LOGDIR)/$@.log)"; exit 1; fi
