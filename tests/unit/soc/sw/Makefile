# Bare-metal programs for the tcore SoC test and the board (xPack riscv-none-elf GCC 15, tools/env.sh).
CROSS ?= riscv-none-elf-
SOC_BUILD ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../../..))
O     ?= $(SOC_BUILD)/tests/soc_sw
CFLAGS := -march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -fno-builtin -nostdlib -Wall -Werror

.PHONY: all
all: $(O)/soc_test.bin $(O)/ps_d1.bin $(O)/ps_reset.bin $(O)/sd_irq.bin $(O)/sd_irq_smt2s.bin $(O)/sd_irq_smt2v.bin \
     $(O)/wst.bin $(O)/wst_h1.bin

# soc_test: the tcore SoC test (and the board's first light); ps_d1: stage D's D1 on the board (soc.md §8.2);
# ps_reset: D4's step 2(a) on the board, the board's reset through the PS window (soc-d4-modes.md);
# sd_irq: SD1's lost interrupt in simulation (tb_soc SDIRQ=1); sd_irq_smt2s: the same as Linux has it on the board's
# smt2 cores (S-mode on context 1, ticks; the contender on core 1's hart 2), for the real cores; sd_irq_smt2v: that
# under Sv39 (the device accesses translated, as ioremap's); wst: DDR write and read streaming as tb_boot's firmware
# (soc.md §8.5), on hart 0 or, wst_h1, on hart 1
$(O)/%.elf: start.S %.c link.ld
	@mkdir -p $(O)
	$(CROSS)gcc $(CFLAGS) -T link.ld -o $@ start.S $*.c
$(O)/sd_irq_smt2s.elf: start.S sd_irq.c link.ld
	@mkdir -p $(O)
	$(CROSS)gcc $(CFLAGS) -DCONT_HART=2 -DSMODE=1 -T link.ld -o $@ start.S sd_irq.c
$(O)/sd_irq_smt2v.elf: start.S sd_irq.c link.ld
	@mkdir -p $(O)
	$(CROSS)gcc $(CFLAGS) -DCONT_HART=2 -DSMODE=2 -T link.ld -o $@ start.S sd_irq.c
$(O)/wst_h1.elf: start.S wst.c link.ld
	@mkdir -p $(O)
	$(CROSS)gcc $(CFLAGS) -DRUN_HART=1 -T link.ld -o $@ start.S wst.c
$(O)/%.bin: $(O)/%.elf
	$(CROSS)objcopy -O binary $< $@
	@ls -l $@
