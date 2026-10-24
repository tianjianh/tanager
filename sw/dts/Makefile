# Device trees for the Tanager platform (docs/spec/soc.md §4, §6).
#   make -C sw/dts [O=<dir>] [CORES=2] [THREADS=1] [RUN_THREADS=$(THREADS)] [MEM=0x40000000] [FPU=1] [PMU=0] [HPM=0] [VIRTIO=0] [UART1=0] [SD1=0] [INITRD=0] [BOARD_RESET=0] [UART1_STDOUT=1] [ETH=0] [ETH_MAC=xx:xx:xx:xx:xx:xx] [RELEASE=0] [BOOTARGS="..."]
# RUN_THREADS=1 with THREADS=2: an SMT2 build that runs thread 0 of each core (until M7, DR-147),
# so the tree describes harts 0 and 2.
# PMU=1 adds OpenSBI's riscv,pmu event map, so Linux's PMU driver can count cycles and instructions
# (the bench image, DR-141).
# HPM=1, for a core built with TG_HPM=1 (M9's counters, DR-190): Sscofpmf in the ISA strings, and the riscv,pmu map
# puts fpu-2's events on mhpmcounter3-6. Never for a core without them: OpenSBI and Linux would count on counters
# that read zero (docs/spec/firmware_switches.md).
# VIRTIO=1 lists the forwarded virtio window's four virtio-mmio slots (bitstreams built with
# TG_VIRTIO_WINDOW=1; docs/spec/soc.md §8.1).
# UART1=1 adds the PS's UART1, the board's USB serial port, through the PS window and makes it the
# stdout path: stage D's D3 (bitstreams built with TG_PS_WINDOW=1, after the A53 releases its getty;
# docs/spec/soc.md §8.2, DR-163). Its default BOOTARGS list console=ttyPS0 first, so /dev/console stays
# the PL UART (the boot marker the harnesses wait for) while UART1 gets the kernel's log and a login.
# SD1=1 adds the PS's SD1 (the board's card) through the PS window, its DMA into the RISC-V's RAM through
# the host DMA port (D-c): stage D's D4, Debian natively from p3 (docs/spec/soc.md §8.2); its default
# BOOTARGS boot p3 with the kernel's console on the PL UART: Debian's kernel has the 8250 built in, and the
# Cadence UART only as our module, which Kconfig keeps from being a console (UART1 gets a getty instead).
# INITRD=1 names the initrd window tanager-host load --initrd fills (0x8800_0000-0x8C00_0000) in /chosen.
# BOARD_RESET=1 points reboot and poweroff at the board's reset, CRL_APB RESET_CTRL through the PS window, instead of
# tanager-host's power register: D4's RISC-V mode, with UART1=1 UART1_STDOUT=0 SD1=1 (docs/spec/soc-d4-modes.md).
# UART1_STDOUT=0 keeps the stdout path on the PL UART with UART1=1: Debian's kernel has no Cadence UART built in, so
# its plain earlycon (the extlinux append's) finds a console only there.
# ETH=1 adds the PS's GEM3 and its DP83867 PHY (D5, docs/spec/soc-d5-gem3.md), with ETH_MAC as its MAC address (the
# A53's eth0's: the modes never run together); RISC-V mode only, as riscv.scr takes the PHY out of reset.
# RELEASE=1: a release build's PLIC (DR-180), with no machine-mode contexts: the tree lists each hart's M context as
# absent (-1) in their places, which OpenSBI and Linux skip; RISC-V mode's trees (board-trees.sh). A release tree
# also boots a development build, whose M contexts nothing uses; a release build is not meant for VIRTIO=1.
# Builds tanager-kv260.dtb and tanager-qemu.dtb for one configuration into O. Each tree must give every MMIO range whole
# 4 KiB pages (check_pages.py; soc.md §4, "PMP regions: whole pages"): a smaller one becomes a PMP region in OpenSBI
# that costs every 4K page its cached PMP result in the core (-23.6% on a store loop). A tree that fails is not kept.
O       ?= $(SOC_BUILD)/dts
CORES   ?= 2
THREADS ?= 1
RUN_THREADS ?= $(THREADS)
MEM     ?= 0x40000000
FPU     ?= 1
PMU     ?= 0
HPM     ?= 0
VIRTIO  ?= 0
UART1   ?= 0
SD1     ?= 0
INITRD  ?= 0
BOARD_RESET ?= 0
UART1_STDOUT ?= 1
ETH     ?= 0
ETH_MAC ?=
RELEASE ?= 0
ifeq ($(RELEASE)$(VIRTIO),11)
  $(error RELEASE=1 is a release build's tree, which has no virtio window: leave VIRTIO at 0)
endif
ifeq ($(SD1),1)
BOOTARGS ?= console=ttyS0,115200 earlycon=uart8250,mmio,0x10000000,115200n8 root=LABEL=tanager-root rootwait
else ifeq ($(UART1),1)
BOOTARGS ?= console=ttyPS0,115200 console=ttyS0,115200 earlycon
else
BOOTARGS ?= console=ttyS0,115200 earlycon
endif
DTC     ?= dtc
CPP     ?= cpp

DEFS := -DTG_NUM_CORES=$(CORES) -DTG_NUM_THREADS=$(THREADS) -DTG_RUN_THREADS=$(RUN_THREADS) -DTG_MEM_SIZE=$(MEM) -DTG_FPU=$(FPU) -DTG_PMU=$(PMU) -DTG_HPM=$(HPM) -DTG_VIRTIO=$(VIRTIO) -DTG_UART1=$(UART1) -DTG_SD1=$(SD1) -DTG_INITRD=$(INITRD) -DTG_BOARD_RESET=$(BOARD_RESET) -DTG_UART1_STDOUT=$(UART1_STDOUT) -DTG_ETH=$(ETH) -DTG_RELEASE=$(RELEASE) \
        $(if $(ETH_MAC),-DTG_ETH_MAC='$(subst :, ,$(ETH_MAC))') \
        -DTG_BOOTARGS='"$(BOOTARGS)"'

.PHONY: all clean
all: $(O)/tanager-kv260.dtb $(O)/tanager-qemu.dtb

$(O)/%.dtb: %.dts tanager.dtsi Makefile
	@mkdir -p $(O)
	$(CPP) -nostdinc -undef -x assembler-with-cpp -P $(DEFS) -I. $< -o $(O)/$*.pp.dts
	$(DTC) -I dts -O dtb -W no-unit_address_vs_reg -o $@.tmp $(O)/$*.pp.dts
	python3 check_pages.py $@.tmp
	mv $@.tmp $@

clean:
	rm -f $(O)/*.dtb $(O)/*.pp.dts
