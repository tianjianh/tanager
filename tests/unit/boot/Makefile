# Software boot on tanager_soc with the real core (docs/spec/soc.md §Verification).
#   make -C tests/unit/boot opensbi [CORES=1|2] [CFG=st|smt2]  boot ROM -> OpenSBI, passes on the full banner
#   make -C tests/unit/boot linux-kernel [CORES=1]  Linux (Buildroot's lp64d Image) to "Run /init", with a
#                                                   device tree without F/D: the kernel needs no FPU
#   make -C tests/unit/boot linux [CORES=1|2] [CFG=smt2 RUN_THREADS=1]  the full lp64d boot to TANAGER-BOOT-OK (the init
#                                                   script), with the FPU in the device tree
#   make -C tests/unit/boot linux RELEASE=1 [...]   the same boot on a release build (DR-180): serial console alone
#   make -C tests/unit/boot run CORES=2 ARGS="+fw=... +dtb=... +expect=... +max_mcycles=N"
#   ARGS= adds plusargs to any of them, and overrides theirs: it comes first, and a plusarg's first value counts.
#   For example ARGS="+max_mcycles=80", or ARGS="+dump_pc=<hex> +dump_stop" (tb_boot.sv)
#   A failed run (TEST FAILED) exits with status 1, so make fails
#   TIMING_CUTS=0|1 builds the core in that DR-140 profile (unset: the package's default)
# Images: OpenSBI fw_jump from sw/build_opensbi.sh (pinned source; built on first use), a device
# tree built here for CORES x threads of the configuration, 128 MiB, no FPU.
# The core builds with its own switches: every M3 feature, F and D included, is on by default (main b53b0a5).
TOP    := tb_boot
CORES  ?= 1
# VTHREADS: Verilator --threads (conventions §9); each count builds in its own directory. Measured on
# OpenSBI (2026-10-14, host load about 17): 2x1 runs 1.5x faster with 4 threads (193 s against 286 s),
# 1x1 20% slower (133 s against 111 s). So two cores use 4 threads and one core uses 1.
VTHREADS ?= $(if $(filter 1,$(CORES)),1,4)
# TAG: a suffix for a separate build of the same configuration (A/B comparisons, probes); the cores and
# threads stay in the directory name, so builds of different configurations never share one
TAG    ?=
# SERIAL=1: the console on the UART's serial line (tg_uart_phy), decoded by the testbench and checked
# against the host's copy
SERIAL ?= 0
# TIMING_CUTS=0|1: the core's DR-140 profile (sim/profile.mk), each in a directory of its own; unset
# builds the package's default. Optional: the cycle-identical tool builds this test from an archive
# with sim/tb only, where the default applies.
-include ../../../sim/profile.mk
ifneq ($(TIMING_CUTS),)
  ifeq ($(TC_DEF),)
    $(error TIMING_CUTS needs sim/profile.mk, which this tree lacks)
  endif
endif
# LAT_INJ=0: a release build's memory path, without the two latency injectors (DR-177), in a directory of its own
LAT_INJ ?= 1
# RELEASE=1: a release build as the board's product (tanager_soc RELEASE, DR-180), so LAT_INJ=0, no trace
# (+define+TG_COMMIT_TRACE=0) and SERIAL=1, the console on the serial line alone; the idle host DMA port in its
# release form; the device trees with the PLIC's M contexts absent (sw/dts RELEASE=1)
RELEASE ?= 0
# HPM=1 (sim/profile.mk's, which builds M9's counters into the core, DR-190): the device trees describe them too
# (sw/dts HPM=1: Sscofpmf and the riscv,pmu event map), in a directory of their own; HPM unset or 0, the trees without
ifeq ($(RELEASE),1)
  override LAT_INJ := 0
  override SERIAL := 1
endif
NAME   := boot$(TAG)$(TC_SUFFIX)$(if $(filter 1,$(SERIAL)),_ser)$(if $(filter 0,$(LAT_INJ)),_rel)$(if $(filter 1,$(RELEASE)),ease)_c$(CORES)_t$(VTHREADS)
TB     := $(CURDIR)/tb_boot.sv
# MEM_PARAMS: the DDR models' timing (tb_boot MEM_*), for example the board's fixed latency:
#   MEM_PARAMS="-GMEM_LAT_MIN=22 -GMEM_LAT_MAX=22 -GMEM_READY_PCT=100 -GMEM_OOO=0 -GMEM_R_PCT=100" TAG=_lat22
MEM_PARAMS ?=
PARAMS := -GN_CORES=$(CORES) -GUART_SERIAL_TB=$(SERIAL) $(MEM_PARAMS) $(if $(filter 0,$(LAT_INJ)),-GLAT_INJ_TB=0) \
          $(if $(filter 1,$(RELEASE)),-GRELEASE_TB=1 -GHOST_DMA_TB=1)
EXTRA_VFLAGS := -CFLAGS -O2 $(if $(filter-out 1,$(VTHREADS)),--threads $(VTHREADS)) $(TC_DEF) \
                $(if $(filter 1,$(RELEASE)),+define+TG_COMMIT_TRACE=0)
include ../common/unit.mk

THREADS := $(if $(filter smt2%,$(CFG)),2,1)
# RUN_THREADS=1 with CFG=smt2: the device tree describes thread 0 of each core only (harts 0 and 2),
# the board's shape until M7 (DR-147); each choice builds its trees in a directory of its own
RUN_THREADS ?= $(THREADS)
DTS_SFX := $(if $(filter-out $(THREADS),$(RUN_THREADS)),-r$(RUN_THREADS))$(if $(filter 1,$(HPM)),-hpm)
# MCYC: the OpenSBI runs' cycle limit, in millions: 20 (the banner comes by 10.7 M cycles at 2x2), or 60 with the
# console on the serial line (SERIAL=1, RELEASE=1), where "Boot HART MEDELEG" ends about 2,700 characters in, at
# 8,680 cycles each (115200 baud at 100 MHz): about 24 M cycles
MCYC    ?= $(if $(filter 1,$(SERIAL)),60,20)
OSBI_REV := $(shell sed -n 's/^OPENSBI_REV=\([^ ]*\).*/\1/p' $(REPO)/sw/versions.sh)
OSBI_FW := $(SOC_BUILD)/opensbi-$(OSBI_REV)/platform/generic/firmware/fw_jump.bin
FW      ?= $(OSBI_FW)
DTB     := $(OUTDIR)/dts$(DTS_SFX)/tanager-kv260.dtb

CORE_DIR := $(REPO)/rtl/core
RTL_SRCS := $(REPO)/rtl/common/cfg/tg_cfg_$(CFG).sv -F $(REPO)/rtl/common/common.f -F $(CORE_DIR)/core.f \
            -F $(REPO)/rtl/uncore/uncore.f -F $(REPO)/rtl/soc/soc.f
# Any change in the core, the SoC top or the shared packages rebuilds the model
$(OUTDIR)/$(TOP): $(wildcard $(CORE_DIR)/*.sv $(CORE_DIR)/*/*.sv $(CORE_DIR)/*.f $(CORE_DIR)/*/*.f) \
                  $(wildcard $(REPO)/rtl/soc/*.sv $(REPO)/rtl/soc/*.f $(REPO)/rtl/common/*.sv $(REPO)/rtl/common/*/*.sv)

# BOOTARGS: the kernel command line in the device trees (earlycon=sbi prints through OpenSBI)
BOOTARGS ?= console=ttyS0,115200 earlycon
$(DTB): $(REPO)/sw/dts/tanager-kv260.dts $(REPO)/sw/dts/tanager.dtsi Makefile
	$(MAKE) --no-print-directory -B -C $(REPO)/sw/dts O=$(OUTDIR)/dts$(DTS_SFX) CORES=$(CORES) THREADS=$(THREADS) RUN_THREADS=$(RUN_THREADS) MEM=0x08000000 FPU=0 RELEASE=$(RELEASE) HPM=$(or $(HPM),0) BOOTARGS="$(BOOTARGS)"
DTB_FPU := $(OUTDIR)/dts-fpu$(DTS_SFX)/tanager-kv260.dtb
$(DTB_FPU): $(REPO)/sw/dts/tanager-kv260.dts $(REPO)/sw/dts/tanager.dtsi Makefile
	$(MAKE) --no-print-directory -B -C $(REPO)/sw/dts O=$(OUTDIR)/dts-fpu$(DTS_SFX) CORES=$(CORES) THREADS=$(THREADS) RUN_THREADS=$(RUN_THREADS) MEM=0x08000000 FPU=1 RELEASE=$(RELEASE) HPM=$(or $(HPM),0) BOOTARGS="$(BOOTARGS)"

KERNEL     ?= $(SOC_BUILD)/br-tanager_lp64d/images/Image
LINUX_MCYC ?= 1500
$(KERNEL):
	@echo "no $(KERNEL): build it with sw/build_linux.sh"; exit 1

$(OSBI_FW):
	bash $(REPO)/sw/build_opensbi.sh

.PHONY: opensbi
opensbi: build $(DTB) $(FW)
	$(OUTDIR)/$(TOP) $(ARGS) +fw=$(FW) +dtb=$(DTB) +expect="Boot HART MEDELEG" +max_mcycles=$(MCYC)

.PHONY: linux-kernel linux $(DTB) $(DTB_FPU)
linux-kernel: build $(DTB) $(FW) $(KERNEL)
	$(OUTDIR)/$(TOP) $(ARGS) +fw=$(FW) +dtb=$(DTB) +kernel=$(KERNEL) +expect="Run /init as init process" +max_mcycles=$(LINUX_MCYC)
linux: build $(DTB_FPU) $(FW) $(KERNEL)
	$(OUTDIR)/$(TOP) $(ARGS) +fw=$(FW) +dtb=$(DTB_FPU) +kernel=$(KERNEL) +expect="TANAGER-BOOT-OK" +max_mcycles=$(LINUX_MCYC)

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
