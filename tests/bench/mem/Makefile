# memcal (docs/spec/verification.md §4.7): the memory system's streaming rates and latency, bare-metal on hart 0,
# for tb_boot's DDR model against the board's DDR (follow-up 14).
#   make -C tests/bench/mem          memcal.bin (the DDR tests once, for simulation) and memcal-big.bin (four times),
#                                    wsdp.bin and wsdp-sim.bin (the L2's write-back batching swept: wsdp.c; 16 and 2 MiB)
#   tb_boot +fw=memcal.bin +expect=MEMCAL-END [+mem_lat_min=...]
#   the board: tanager-host boot --fw memcal-big.bin --kernel /dev/null --dtb /dev/null --timeout 20 (it parks after
#   MEMCAL-END; about 3 s at 100 MHz)
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
OUT  := $(TANAGER_BUILD)/$(WT)/bench/mem
CFLAGS := -march=rv64imac_zicsr -mabi=lp64 -O2 -nostdlib -nostartfiles -static -mcmodel=medany \
          -Wl,--no-warn-rwx-segments -T $(ROOT)/tests/coherence/link.ld
SRC := crt0.S memcal.c

.PHONY: all print-out
all: $(OUT)/memcal.bin $(OUT)/memcal-big.bin $(OUT)/wsdp.bin $(OUT)/wsdp-sim.bin
$(OUT)/memcal.elf: $(SRC) Makefile
	@mkdir -p $(OUT)
	riscv-none-elf-gcc $(CFLAGS) -DBIG=1 $(SRC) -o $@
$(OUT)/memcal-big.elf: $(SRC) Makefile
	@mkdir -p $(OUT)
	riscv-none-elf-gcc $(CFLAGS) -DBIG=4 $(SRC) -o $@
$(OUT)/wsdp.elf: crt0.S wsdp.c Makefile
	@mkdir -p $(OUT)
	riscv-none-elf-gcc $(CFLAGS) -DWSD_MB=16 crt0.S wsdp.c -o $@
$(OUT)/wsdp-sim.elf: crt0.S wsdp.c Makefile
	@mkdir -p $(OUT)
	riscv-none-elf-gcc $(CFLAGS) -DWSD_MB=2 crt0.S wsdp.c -o $@
$(OUT)/%.bin: $(OUT)/%.elf
	riscv-none-elf-objcopy -O binary $< $@
print-out:
	@echo $(OUT)
