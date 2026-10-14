# tanager-host, the A53 control program (docs/spec/host.md).
#   make -C sw/host                 static aarch64 binary with the pinned external toolchain
#   make -C sw/host native          host build (syntax and warnings check only)
# The aarch64 toolchain (Bootlin aarch64 musl, GCC 15; sw/versions.sh) is unpacked under
# $(SOC_BUILD)/tc by sw/fetch.sh; CROSS overrides the prefix.
SOC_BUILD ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(abspath ../..))
CROSS     ?= $(SOC_BUILD)/tc/aarch64--musl--stable-2026.08-1/bin/aarch64-buildroot-linux-musl-
O         ?= $(SOC_BUILD)/host
CFLAGS    := -O2 -std=gnu11 -Wall -Wextra -Werror -Wno-unused-result

.PHONY: all native clean
all: $(O)/tanager-host

$(O)/tanager-host: tanager-host.c Makefile
	@mkdir -p $(O)
	$(CROSS)gcc $(CFLAGS) -static -o $@ $<
	$(CROSS)strip $@
	@file $@

native: tanager-host.c
	@mkdir -p $(O)
	gcc-15 $(CFLAGS) -o $(O)/tanager-host-native $<
	@echo "native build OK"

clean:
	rm -rf $(O)
