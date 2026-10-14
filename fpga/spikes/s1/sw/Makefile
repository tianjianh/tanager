# Spike S1 A53 program.
#   make            on the KV260 (Kria Ubuntu: sudo apt install build-essential)
#   make cross      on the build host: a static aarch64 binary, tg_s1.aarch64, with the pinned
#                   toolchain that builds tanager-host (sw/versions.sh: Bootlin aarch64 musl,
#                   GCC 15; sw/fetch.sh unpacks it under <build>/tc). It runs on the board's
#                   Ubuntu with no compiler there. CROSS overrides the prefix; O the directory.
AATC  := aarch64--musl--stable-2026.08-1
CROSS ?= $(patsubst %gcc,%,$(firstword $(wildcard \
           $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/*/tc/$(AATC)/bin/aarch64-buildroot-linux-musl-gcc)))
O     ?= .

tg_s1: tg_s1.c
	gcc -O2 -Wall -Wextra -o $@ $< -lpthread

cross: tg_s1.c
	@test -n "$(CROSS)" || { echo "no aarch64 toolchain: run sw/fetch.sh or set CROSS"; exit 1; }
	@mkdir -p $(O)
	$(CROSS)gcc -O2 -Wall -Wextra -static -o $(O)/tg_s1.aarch64 $< -lpthread
	$(CROSS)strip $(O)/tg_s1.aarch64
	@file $(O)/tg_s1.aarch64

clean:
	rm -f tg_s1 tg_s1.aarch64

.PHONY: cross clean
