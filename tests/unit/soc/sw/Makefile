# Bare-metal program for the tcore SoC test (xPack riscv-none-elf GCC 15, tools/env.sh).
CROSS ?= riscv-none-elf-
SOC_BUILD ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../../..))
O     ?= $(SOC_BUILD)/tests/soc_sw
CFLAGS := -march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -fno-builtin -nostdlib -Wall -Werror

.PHONY: all
all: $(O)/soc_test.bin

$(O)/soc_test.elf: start.S soc_test.c link.ld
	@mkdir -p $(O)
	$(CROSS)gcc $(CFLAGS) -T link.ld -o $@ start.S soc_test.c
$(O)/soc_test.bin: $(O)/soc_test.elf
	$(CROSS)objcopy -O binary $< $@
	@ls -l $@
