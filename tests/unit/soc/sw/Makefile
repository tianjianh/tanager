# Bare-metal programs for the tcore SoC test and the board (xPack riscv-none-elf GCC 15, tools/env.sh).
CROSS ?= riscv-none-elf-
SOC_BUILD ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../../..))
O     ?= $(SOC_BUILD)/tests/soc_sw
CFLAGS := -march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -fno-builtin -nostdlib -Wall -Werror

.PHONY: all
all: $(O)/soc_test.bin $(O)/ps_d1.bin $(O)/ps_reset.bin

# soc_test: the tcore SoC test (and the board's first light); ps_d1: stage D's D1 on the board (soc.md §8.2);
# ps_reset: D4's step 2(a) on the board, the board's reset through the PS window (soc-d4-modes.md)
$(O)/%.elf: start.S %.c link.ld
	@mkdir -p $(O)
	$(CROSS)gcc $(CFLAGS) -T link.ld -o $@ start.S $*.c
$(O)/%.bin: $(O)/%.elf
	$(CROSS)objcopy -O binary $< $@
	@ls -l $@
