# D4 modes step 5's test image (rvtest.c), S-mode at 0x8020_0000 (xPack riscv-none-elf GCC, tools/env.sh):
#   make -C sw/d4mode/rvtest [O=<dir>]    -> $(O)/rvtest.bin
CROSS ?= riscv-none-elf-
SOC_BUILD ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..))
O     ?= $(SOC_BUILD)/d4mode
CFLAGS := -march=rv64im_zicsr -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -fno-builtin -nostdlib -Wall -Werror

$(O)/rvtest.bin: $(O)/rvtest.elf
	$(CROSS)objcopy -O binary $< $@
	@ls -l $@
$(O)/rvtest.elf: start.S rvtest.c link.ld
	@mkdir -p $(O)
	$(CROSS)gcc $(CFLAGS) -T link.ld -o $@ start.S rvtest.c
