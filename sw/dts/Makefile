# Device trees for the Tanager platform (docs/spec/soc.md §4, §6).
#   make -C sw/dts [O=<dir>] [CORES=2] [THREADS=1] [MEM=0x40000000] [FPU=1]
# Builds tanager-kv260.dtb and tanager-qemu.dtb for one configuration into O.
O       ?= $(SOC_BUILD)/dts
CORES   ?= 2
THREADS ?= 1
MEM     ?= 0x40000000
FPU     ?= 1
DTC     ?= dtc
CPP     ?= cpp

DEFS := -DTG_NUM_CORES=$(CORES) -DTG_NUM_THREADS=$(THREADS) -DTG_MEM_SIZE=$(MEM) -DTG_FPU=$(FPU)

.PHONY: all clean
all: $(O)/tanager-kv260.dtb $(O)/tanager-qemu.dtb

$(O)/%.dtb: %.dts tanager.dtsi Makefile
	@mkdir -p $(O)
	$(CPP) -nostdinc -undef -x assembler-with-cpp -P $(DEFS) -I. $< -o $(O)/$*.pp.dts
	$(DTC) -I dts -O dtb -W no-unit_address_vs_reg -o $@ $(O)/$*.pp.dts

clean:
	rm -f $(O)/*.dtb $(O)/*.pp.dts
