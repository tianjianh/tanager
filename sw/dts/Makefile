# Device trees for the Tanager platform (docs/spec/soc.md §4, §6).
#   make -C sw/dts [O=<dir>] [CORES=2] [THREADS=1] [MEM=0x40000000] [FPU=1] [PMU=0] [BOOTARGS="..."]
# PMU=1 adds OpenSBI's riscv,pmu event map, so Linux's PMU driver can count cycles and instructions
# (the bench image, DR-141).
# Builds tanager-kv260.dtb and tanager-qemu.dtb for one configuration into O.
O       ?= $(SOC_BUILD)/dts
CORES   ?= 2
THREADS ?= 1
MEM     ?= 0x40000000
FPU     ?= 1
PMU     ?= 0
BOOTARGS ?= console=ttyS0,115200 earlycon
DTC     ?= dtc
CPP     ?= cpp

DEFS := -DTG_NUM_CORES=$(CORES) -DTG_NUM_THREADS=$(THREADS) -DTG_MEM_SIZE=$(MEM) -DTG_FPU=$(FPU) -DTG_PMU=$(PMU) \
        -DTG_BOOTARGS='"$(BOOTARGS)"'

.PHONY: all clean
all: $(O)/tanager-kv260.dtb $(O)/tanager-qemu.dtb

$(O)/%.dtb: %.dts tanager.dtsi Makefile
	@mkdir -p $(O)
	$(CPP) -nostdinc -undef -x assembler-with-cpp -P $(DEFS) -I. $< -o $(O)/$*.pp.dts
	$(DTC) -I dts -O dtb -W no-unit_address_vs_reg -o $@ $(O)/$*.pp.dts

clean:
	rm -f $(O)/*.dtb $(O)/*.pp.dts
