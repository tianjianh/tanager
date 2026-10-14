# Software boot on tanager_soc with the real core (docs/spec/soc.md §Verification).
#   make -C tests/unit/boot opensbi [CORES=1|2]     boot ROM -> OpenSBI, passes on the full banner
#   make -C tests/unit/boot linux-kernel [CORES=1]  Linux (Buildroot's lp64d Image) to "Run /init", with a
#                                                   device tree without F/D: the kernel needs no FPU
#   make -C tests/unit/boot linux [CORES=1]         the full lp64d boot to TANAGER-BOOT-OK, once the
#                                                   core has F/D (device tree with the FPU)
#   make -C tests/unit/boot run CORES=2 ARGS="+fw=... +dtb=... +expect=... +max_mcycles=N"
# Images: OpenSBI fw_jump from sw/build_opensbi.sh (pinned source; built on first use), a device
# tree built here for CORES x threads of the configuration, 128 MiB, no FPU.
# The core's M3 switches (tg_core_pkg EXT_*) are on in this build. Until the core track turns them on
# by default, a copy of tg_core_pkg.sv with them set is compiled in place of the original.
TOP    := tb_boot
CORES  ?= 1
NAME   := boot_c$(CORES)
TB     := $(CURDIR)/tb_boot.sv
PARAMS := -GN_CORES=$(CORES)
EXTRA_VFLAGS := -CFLAGS -O2
include ../common/unit.mk

THREADS := $(if $(filter smt2%,$(CFG)),2,1)
MCYC    ?= 40
OSBI_FW := $(SOC_BUILD)/opensbi/platform/generic/firmware/fw_jump.bin
FW      ?= $(OSBI_FW)
DTB     := $(OUTDIR)/dts/tanager-kv260.dtb

CORE_DIR := $(REPO)/rtl/core
M3_PKG   := $(OUTDIR)/tg_core_pkg_m3.sv
CORE_F   := $(OUTDIR)/core_m3.f
CORE_SRCS := $(shell sed -e 's://.*$$::' -e '/^\s*$$/d' -e '/^-F/d' $(CORE_DIR)/core.f | sed -e 's:^:$(CORE_DIR)/:') \
             $(shell sed -e 's://.*$$::' -e '/^\s*$$/d' $(CORE_DIR)/fpu/fpu.f | sed -e 's:^:$(CORE_DIR)/fpu/:')
SOC_SRCS  := $(shell sed -e 's://.*$$::' -e '/^\s*$$/d' $(REPO)/rtl/soc/soc.f | sed -e 's:^:$(REPO)/rtl/soc/:')

RTL_SRCS := $(REPO)/rtl/common/cfg/tg_cfg_$(CFG).sv -F $(REPO)/rtl/common/common.f -F $(CORE_F) \
            -F $(REPO)/rtl/uncore/uncore.f -F $(REPO)/rtl/soc/soc.f

$(M3_PKG): $(CORE_DIR)/tg_core_pkg.sv Makefile
	@mkdir -p $(OUTDIR)
	sed -E "/localparam bit EXT_/s/1'b0/1'b1/" $< > $@
	@grep -q "EXT_SU *= *1'b1" $@

$(CORE_F): $(CORE_DIR)/core.f $(M3_PKG) Makefile
	@mkdir -p $(OUTDIR)
	@sed -e 's://.*$$::' -e '/^\s*$$/d' $(CORE_DIR)/core.f | \
	  awk -v d=$(CORE_DIR) -v pkg=$(M3_PKG) '/^-F/ { print "-F " d "/" $$2; next } \
	    $$1 == "tg_core_pkg.sv" { print pkg; next } { print d "/" $$1 }' > $@

$(OUTDIR)/$(TOP): $(CORE_F) $(CORE_SRCS) $(SOC_SRCS)

$(DTB): $(REPO)/sw/dts/tanager-kv260.dts $(REPO)/sw/dts/tanager.dtsi Makefile
	$(MAKE) --no-print-directory -C $(REPO)/sw/dts O=$(OUTDIR)/dts CORES=$(CORES) THREADS=$(THREADS) MEM=0x08000000 FPU=0
DTB_FPU := $(OUTDIR)/dts-fpu/tanager-kv260.dtb
$(DTB_FPU): $(REPO)/sw/dts/tanager-kv260.dts $(REPO)/sw/dts/tanager.dtsi Makefile
	$(MAKE) --no-print-directory -C $(REPO)/sw/dts O=$(OUTDIR)/dts-fpu CORES=$(CORES) THREADS=$(THREADS) MEM=0x08000000 FPU=1

KERNEL     ?= $(SOC_BUILD)/br-tanager_lp64d/images/Image
LINUX_MCYC ?= 1500
$(KERNEL):
	@echo "no $(KERNEL): build it with sw/build_linux.sh"; exit 1

$(OSBI_FW):
	bash $(REPO)/sw/build_opensbi.sh

.PHONY: opensbi
opensbi: build $(DTB) $(FW)
	$(OUTDIR)/$(TOP) +fw=$(FW) +dtb=$(DTB) +expect="Boot HART MEDELEG" +max_mcycles=$(MCYC)

.PHONY: linux-kernel linux
linux-kernel: build $(DTB) $(FW) $(KERNEL)
	$(OUTDIR)/$(TOP) +fw=$(FW) +dtb=$(DTB) +kernel=$(KERNEL) +expect="Run /init as init process" +max_mcycles=$(LINUX_MCYC)
linux: build $(DTB_FPU) $(FW) $(KERNEL)
	$(OUTDIR)/$(TOP) +fw=$(FW) +dtb=$(DTB_FPU) +kernel=$(KERNEL) +expect="TANAGER-BOOT-OK" +max_mcycles=$(LINUX_MCYC)

# The boots take minutes: only the long suite runs them.
.PHONY: short long
short:
	@echo "boot: skipped in the short suite (make -C tests/unit/boot long)"
long:
	@for c in 1 2; do $(MAKE) --no-print-directory opensbi CORES=$$c | grep -q "TEST PASSED" || { echo "FAIL OpenSBI, $$c core(s)"; exit 1; }; echo "boot OpenSBI $$c core(s): PASS"; done
