# Debug ROM image (docs/spec/soc.md §9.5). Needs the xPack riscv-none-elf GCC 15 (tools/env.sh).
#   make -C sw/debugrom          rebuild rtl/uncore/debug/tg_debugrom_img_pkg.sv
#   make -C sw/debugrom check    fail if the committed image is out of date
CROSS ?= riscv-none-elf-
O     ?= $(or $(SOC_BUILD),/tmp)/debugrom
SVH   := ../../rtl/uncore/debug/tg_debugrom_img_pkg.sv

.PHONY: all check clean
all: $(SVH)

$(O)/debugrom.elf: debugrom.S
	@mkdir -p $(O)
	$(CROSS)gcc -march=rv64i_zicsr_zifencei -mabi=lp64 -nostdlib -nostartfiles -Wl,-Ttext=0x11000800 -Wl,--build-id=none -o $@ $<

$(O)/debugrom.bin: $(O)/debugrom.elf
	$(CROSS)objcopy -O binary $< $@

$(O)/debugrom.sym: $(O)/debugrom.elf
	$(CROSS)nm $< > $@

$(O)/tg_debugrom_img_pkg.sv: $(O)/debugrom.bin $(O)/debugrom.sym gen_svh.py
	python3 -I gen_svh.py $(O)/debugrom.bin $(O)/debugrom.sym > $@

$(SVH): $(O)/tg_debugrom_img_pkg.sv
	cp $< $@

check: $(O)/tg_debugrom_img_pkg.sv
	@cmp -s $< $(SVH) || { echo "tg_debugrom_img_pkg.sv is out of date: run make -C sw/debugrom"; exit 1; }
	@echo "debug ROM image is current"

clean:
	rm -rf $(O)
