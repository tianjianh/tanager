# tanager-host, the A53 control program (docs/spec/host.md).
#   make -C sw/host                 static aarch64 binary with the pinned external toolchain
#   make -C sw/host native          host build (a build and warnings check; it fails as the board's build would)
#   make -C sw/host test            the virtio back-ends' test, native (test/vio_test.c), plain and with
#                                   the external-write records (extwrite.c)
# The aarch64 toolchain (Bootlin aarch64 musl, GCC 15; sw/versions.sh), unpacked by sw/fetch.sh: this
# worktree's $(SOC_BUILD)/tc, else the shared $(TANAGER_BUILD)/tc (sw/env.sh SOC_AATC); CROSS
# overrides the prefix.
HERE      := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SOC_BUILD ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(abspath $(HERE)../..))
AATC_NAME := $(shell . $(HERE)../versions.sh && echo $$AATC_NAME)
SOC_TC_SHARED ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/tc
SOC_AATC  ?= $(firstword $(wildcard $(SOC_BUILD)/tc/$(AATC_NAME)) $(wildcard $(SOC_TC_SHARED)/$(AATC_NAME)) \
               $(SOC_BUILD)/tc/$(AATC_NAME))
CROSS     ?= $(SOC_AATC)/bin/aarch64-buildroot-linux-musl-
O         ?= $(SOC_BUILD)/host
CFLAGS    := -O2 -std=gnu11 -Wall -Wextra -Werror -Wno-unused-result

SRCS      := tanager-host.c virtio.c extwrite.c
HDRS      := virtio.h extwrite.h

.PHONY: all native test clean
all: $(O)/tanager-host

$(O)/tanager-host: $(SRCS) $(HDRS) Makefile
	@mkdir -p $(O)
	$(CROSS)gcc $(CFLAGS) -static -o $@ $(SRCS)
	$(CROSS)strip $@
	@file $@

native: $(SRCS) $(HDRS)
	@mkdir -p $(O)
	gcc-15 $(CFLAGS) -o $(O)/tanager-host-native $(SRCS)
	@echo "native build OK"

test: test/vio_test.c virtio.c extwrite.c $(HDRS)
	@mkdir -p $(O)
	gcc-15 $(CFLAGS) -o $(O)/vio_test test/vio_test.c virtio.c extwrite.c
	TMPDIR=$(O) $(O)/vio_test
	TMPDIR=$(O) $(O)/vio_test xw

clean:
	rm -rf $(O)
