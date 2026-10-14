# Boot ROM image (docs/spec/uncore-periph.md). Needs the xPack riscv-none-elf GCC 15 (tools/env.sh).
#   make -C sw/bootrom          rebuild rtl/uncore/bootrom/tg_bootrom_img_pkg.sv
#   make -C sw/bootrom check    fail if the committed image is out of date
CROSS ?= riscv-none-elf-
O     ?= $(or $(SOC_BUILD),/tmp)/bootrom
SVH   := ../../rtl/uncore/bootrom/tg_bootrom_img_pkg.sv

.PHONY: all check clean
all: $(SVH)

$(O)/bootrom.elf: bootrom.S
	@mkdir -p $(O)
	$(CROSS)gcc -march=rv64i_zicsr -mabi=lp64 -nostdlib -nostartfiles -Wl,-Ttext=0x1000 -Wl,--build-id=none -o $@ $<

$(O)/bootrom.bin: $(O)/bootrom.elf
	$(CROSS)objcopy -O binary $< $@

$(O)/tg_bootrom_img_pkg.sv: $(O)/bootrom.bin gen_svh.py
	python3 -I gen_svh.py $< > $@

$(SVH): $(O)/tg_bootrom_img_pkg.sv
	cp $< $@

check: $(O)/tg_bootrom_img_pkg.sv
	@cmp -s $< $(SVH) || { echo "tg_bootrom_img_pkg.sv is out of date: run make -C sw/bootrom"; exit 1; }
	@echo "boot ROM image is current"

clean:
	rm -rf $(O)
