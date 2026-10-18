# The Linux workload set (DR-141; docs/spec/verification.md §4.6): static rv64 user programs and their
# run script, for the board's initramfs.
#   make -C tests/bench/linux                       build into $(OUT)
#   make -C tests/bench/linux install DESTDIR=DIR   install into a root filesystem tree
#   make -C tests/bench/linux initrd                $(OUT)/tglb-initrd.cpio: the install tree as an extra
#                                                   initrd, for QEMU (-initrd) without rebuilding the image
# A Buildroot package passes CC, OUT and DESTDIR, and ROOT (the repository) when it builds from a copy of
# this directory. The flags are the Makefile's own on purpose: the benchmarks keep plan §10.2's flag
# sets, the same as the bare-metal runs (tests/bench), and every program links statically; CFLAGS is
# not used. Standalone, the compiler is sw/versions.sh's RVTC unpacked under
# $(TANAGER_BUILD)/<worktree>/tc, else the shared $(TANAGER_BUILD)/tc. CoreMark and Dhrystone come from perfmodel/third_party
# (perfmodel/scripts/fetch_deps.sh), as for tests/bench.
ROOT ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
WT   := $(notdir $(ROOT))
L    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TANAGER_BUILD ?= $(HOME)/tanager-build
OUT  ?= $(TANAGER_BUILD)/$(WT)/linux-bench
# The compiler: CC from the make command line (the Buildroot package passes its TARGET_CC so), else
# sw/versions.sh's RVTC; never a CC from the environment, which tools/env.sh sets to the host's.
ifneq ($(origin CC),command line)
  RVTC_NAME := $(shell . $(ROOT)/sw/versions.sh && echo $$RVTC_NAME)
  RVTC_GCC := tc/$(RVTC_NAME)/bin/riscv64-buildroot-linux-gnu-gcc
  CC := $(firstword $(wildcard $(TANAGER_BUILD)/$(WT)/$(RVTC_GCC) $(TANAGER_BUILD)/$(RVTC_GCC)) $(TANAGER_BUILD)/$(WT)/$(RVTC_GCC))
endif
ifneq ($(filter-out clean,$(or $(MAKECMDGOALS),all)),)
  CC_MACHINE := $(shell $(CC) -dumpmachine 2>/dev/null)
  ifeq ($(findstring riscv64,$(CC_MACHINE)),)
    $(error CC=$(CC) does not build for riscv64 (it targets "$(CC_MACHINE)"): unpack sw/versions.sh's RVTC under $(TANAGER_BUILD)/tc, or pass CC=<a riscv64 compiler>)
  endif
endif
TP   ?= $(firstword $(patsubst %/coremark/core_main.c,%,$(wildcard $(ROOT)/perfmodel/third_party/coremark/core_main.c \
           $(HOME)/tanager/perfmodel/third_party/coremark/core_main.c)))

# The ISA (the coordinator's call under DR-154, 2026-10-17): rv64gc, lp64d, as Debian's userland and the
# model's suite; until then the toolchain's default, rv64imafd, without compressed code. BRIDGE=1 also
# builds that earlier form of the benchmarks, as coremark-a-imafd, coremark-b-imafd and dhrystone-imafd,
# which tg-lbench.sh runs too: one board run measures both, so the series stays continuous.
MARCH  ?= rv64gc
ARCH   := -march=$(MARCH) -mabi=lp64d
BRIDGE ?=
CM_A := -O2 -funroll-loops -fpeel-loops -fgcse-sm -fgcse-las
CM_B := -O3 -funroll-loops
DHRY := -O3 -fno-common -fno-inline
CM_SRC = $(addprefix $(TP)/coremark/,core_list_join.c core_main.c core_matrix.c core_state.c core_util.c) \
         $(L)/coremark/core_portme.c

PROGS := $(OUT)/tg-lbench $(OUT)/coremark-a $(OUT)/coremark-b $(OUT)/dhrystone \
         $(if $(filter 1,$(BRIDGE)),$(OUT)/coremark-a-imafd $(OUT)/coremark-b-imafd $(OUT)/dhrystone-imafd)

.PHONY: all install initrd clean
all: $(PROGS)

$(OUT)/tg-lbench: $(L)/tg_lbench.c $(L)/tglb.h
	@mkdir -p $(OUT)
	$(CC) $(ARCH) -O2 -Wall -Wextra -static -I$(L) $< -o $@

# The bridge's form first (its pattern's stem is shorter, so make prefers it): the toolchain's default ISA
$(OUT)/coremark-%-imafd: $(wildcard $(L)/coremark/*) $(L)/tglb.h
	@test -n "$(TP)" || { echo "CoreMark sources not found: run perfmodel/scripts/fetch_deps.sh"; exit 2; }
	@mkdir -p $(OUT)
	$(CC) $(CM_$(shell echo $* | tr a-z A-Z)) -static -DPERFORMANCE_RUN=1 '-DTGLB_NAME="coremark-$*-imafd"' \
	  '-DTGLB_MARCH="rv64imafd"' '-DFLAGS_STR="$(CM_$(shell echo $* | tr a-z A-Z))"' -I$(L) -I$(L)/coremark \
	  -I$(TP)/coremark $(CM_SRC) -lm -o $@

$(OUT)/coremark-%: $(wildcard $(L)/coremark/*) $(L)/tglb.h
	@test -n "$(TP)" || { echo "CoreMark sources not found: run perfmodel/scripts/fetch_deps.sh"; exit 2; }
	@mkdir -p $(OUT)
	$(CC) $(ARCH) $(CM_$(shell echo $* | tr a-z A-Z)) -static -DPERFORMANCE_RUN=1 '-DTGLB_NAME="coremark-$*"' \
	  '-DTGLB_MARCH="$(MARCH)"' '-DFLAGS_STR="$(CM_$(shell echo $* | tr a-z A-Z))"' -I$(L) -I$(L)/coremark \
	  -I$(TP)/coremark $(CM_SRC) -lm -o $@

# dhrystone (ARCH) and the bridge's dhrystone-imafd (the toolchain's default): $(call dhry,<name>,<flags>,<march>)
define dhry
$(OUT)/$(1): $(L)/dhrystone/dhry_time.c $(L)/tglb.h
	@test -n "$(TP)" || { echo "Dhrystone source not found: run perfmodel/scripts/fetch_deps.sh"; exit 2; }
	@mkdir -p $(OUT)/gen-$(1)
	python3 -I $(ROOT)/perfmodel/bench/dhrystone/unshar.py $(TP)/dhrystone/dhry-c $(OUT)/gen-$(1) > /dev/null
	$(CC) $(2) $(DHRY) -std=gnu89 -w -DTIME -Dmain=dhry_main -I$(OUT)/gen-$(1) -c $(OUT)/gen-$(1)/dhry_1.c \
	  -o $(OUT)/gen-$(1)/dhry_1.o
	$(CC) $(2) $(DHRY) -static -std=gnu89 -w -DTIME '-DTGLB_NAME="$(1)"' '-DTGLB_MARCH="$(3)"' -I$(OUT)/gen-$(1) \
	  -I$(L) $(OUT)/gen-$(1)/dhry_1.o $(OUT)/gen-$(1)/dhry_2.c $(L)/dhrystone/dhry_time.c -o $$@
endef
$(eval $(call dhry,dhrystone,$(ARCH),$(MARCH)))
$(eval $(call dhry,dhrystone-imafd,,rv64imafd))

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
