# The Linux workload set (DR-141; docs/spec/verification.md §4.6): static rv64 user programs and their
# run script, for the board's initramfs.
#   make -C tests/bench/linux                       build into $(OUT)
#   make -C tests/bench/linux install DESTDIR=DIR   install into a root filesystem tree
#   make -C tests/bench/linux initrd                $(OUT)/tglb-initrd.cpio: the install tree as an extra
#                                                   initrd, for QEMU (-initrd) without rebuilding the image
# A Buildroot package passes CC, OUT and DESTDIR. Standalone, the compiler is sw/versions.sh's RVTC
# unpacked under $(TANAGER_BUILD)/<worktree>/tc. CoreMark and Dhrystone come from perfmodel/third_party
# (perfmodel/scripts/fetch_deps.sh), as for tests/bench; the flag sets are plan §10.2's.
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
WT   := $(notdir $(ROOT))
L    := $(ROOT)/tests/bench/linux
TANAGER_BUILD ?= $(HOME)/tanager-build
OUT  ?= $(TANAGER_BUILD)/$(WT)/linux-bench
RVTC_NAME := $(shell . $(ROOT)/sw/versions.sh && echo $$RVTC_NAME)
ifeq ($(origin CC),default)
  CC := $(TANAGER_BUILD)/$(WT)/tc/$(RVTC_NAME)/bin/riscv64-buildroot-linux-gnu-gcc
endif
TP   ?= $(firstword $(patsubst %/coremark/core_main.c,%,$(wildcard $(ROOT)/perfmodel/third_party/coremark/core_main.c \
           $(HOME)/tanager/perfmodel/third_party/coremark/core_main.c)))

CM_A := -O2 -funroll-loops -fpeel-loops -fgcse-sm -fgcse-las
CM_B := -O3 -funroll-loops
DHRY := -O3 -fno-common -fno-inline
CM_SRC = $(addprefix $(TP)/coremark/,core_list_join.c core_main.c core_matrix.c core_state.c core_util.c) \
         $(L)/coremark/core_portme.c

PROGS := $(OUT)/tg-lbench $(OUT)/coremark-a $(OUT)/coremark-b $(OUT)/dhrystone

.PHONY: all install initrd clean
all: $(PROGS)

$(OUT)/tg-lbench: $(L)/tg_lbench.c $(L)/tglb.h
	@mkdir -p $(OUT)
	$(CC) -O2 -Wall -Wextra -static -I$(L) $< -o $@

$(OUT)/coremark-%: $(wildcard $(L)/coremark/*) $(L)/tglb.h
	@test -n "$(TP)" || { echo "CoreMark sources not found: run perfmodel/scripts/fetch_deps.sh"; exit 2; }
	@mkdir -p $(OUT)
	$(CC) $(CM_$(shell echo $* | tr a-z A-Z)) -static -DPERFORMANCE_RUN=1 '-DTGLB_NAME="coremark-$*"' \
	  '-DFLAGS_STR="$(CM_$(shell echo $* | tr a-z A-Z))"' -I$(L) -I$(L)/coremark -I$(TP)/coremark $(CM_SRC) -lm -o $@

$(OUT)/dhrystone: $(L)/dhrystone/dhry_time.c $(L)/tglb.h
	@test -n "$(TP)" || { echo "Dhrystone source not found: run perfmodel/scripts/fetch_deps.sh"; exit 2; }
	@mkdir -p $(OUT)/gen
	python3 -I $(ROOT)/perfmodel/bench/dhrystone/unshar.py $(TP)/dhrystone/dhry-c $(OUT)/gen > /dev/null
	$(CC) $(DHRY) -std=gnu89 -w -DTIME -Dmain=dhry_main -I$(OUT)/gen -c $(OUT)/gen/dhry_1.c -o $(OUT)/gen/dhry_1.o
	$(CC) $(DHRY) -static -std=gnu89 -w -DTIME -I$(OUT)/gen -I$(L) \
	  $(OUT)/gen/dhry_1.o $(OUT)/gen/dhry_2.c $(L)/dhrystone/dhry_time.c -o $@

install: $(PROGS)
	install -d $(DESTDIR)/usr/bin $(DESTDIR)/etc/init.d
	install -m 0755 $(PROGS) $(L)/tg-lbench.sh $(DESTDIR)/usr/bin/
	install -m 0755 $(L)/S99tglbench $(DESTDIR)/etc/init.d/

initrd: $(PROGS)
	rm -rf $(OUT)/initrd && $(MAKE) --no-print-directory install DESTDIR=$(OUT)/initrd
	cd $(OUT)/initrd && find . | LC_ALL=C sort | cpio -o -H newc --quiet --owner=0:0 > $(OUT)/tglb-initrd.cpio
	@echo "built $(OUT)/tglb-initrd.cpio"

clean:
	rm -rf $(OUT)
