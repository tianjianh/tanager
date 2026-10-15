# CoreMark and Dhrystone for the Tanager simulation platform (docs/spec/verification.md §4.2).
# Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make -C tests/bench [MARCH=rv64im|rv64gc|rv64gcb] build      build the ELFs
#   make -C tests/bench CFG=st [CORE=core|tcore] [LAT=...] run    run them in tg_vsim with lockstep
# ITER (CoreMark iterations, default 2) and RUNS (Dhrystone runs, default 500) set the length.
# The sources come from perfmodel/third_party (perfmodel/scripts/fetch_deps.sh), else from the
# main checkout's copy.

MARCH ?= rv64im
ITER  ?= 2
RUNS  ?= 500
CFG   ?= st
CORE  ?= core
LAT   ?= native
JOBS  ?= 8

# Command-line variables of this make (ISA, MARCH, ...) must not reach the sim build, where ISA
# means Spike's ISA: sub-makes get only what is passed to them explicitly.
MAKEOVERRIDES :=

ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
WT    := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
include $(ROOT)/sim/profile.mk
OUT   := $(TANAGER_BUILD)/$(WT)/bench/$(MARCH)-i$(ITER)-r$(RUNS)
TP    ?= $(firstword $(patsubst %/coremark/core_main.c,%,$(wildcard $(ROOT)/perfmodel/third_party/coremark/core_main.c \
           $(HOME)/tanager/perfmodel/third_party/coremark/core_main.c)))
CC    := riscv-none-elf-gcc
B     := $(ROOT)/tests/bench

ifeq ($(MARCH),rv64im)
  ARCH := -march=rv64im_zicsr_zifencei -mabi=lp64
else ifeq ($(MARCH),rv64gc)
  ARCH := -march=rv64gc -mabi=lp64d
else ifeq ($(MARCH),rv64gcb)
  ARCH := -march=rv64gc_zba_zbb_zbs_zicond -mabi=lp64d
else
  $(error unknown MARCH=$(MARCH) (rv64im, rv64gc or rv64gcb))
endif

# Flag sets of plan §10.2
CM_A := -O2 -funroll-loops -fpeel-loops -fgcse-sm -fgcse-las
CM_B := -O3 -funroll-loops
DHRY := -O3 -fno-common -fno-inline

LINK := $(ARCH) -mcmodel=medany -static -nostartfiles -T $(B)/bsp/link.ld -Wl,--gc-sections \
        -Wl,--no-warn-rwx-segments -I$(B)/bsp $(B)/bsp/crt0.S $(B)/bsp/syscalls.c
BSP  := $(wildcard $(B)/bsp/*)
CM_SRC = $(addprefix $(TP)/coremark/,core_list_join.c core_main.c core_matrix.c core_state.c core_util.c) \
         $(B)/coremark/core_portme.c

ELFS := $(OUT)/coremark_A.elf $(OUT)/coremark_B.elf $(OUT)/dhrystone.elf

.PHONY: build run clean print-out
build: $(ELFS)

$(OUT)/coremark_%.elf: $(BSP) $(wildcard $(B)/coremark/*)
	@test -n "$(TP)" || { echo "CoreMark sources not found: run perfmodel/scripts/fetch_deps.sh"; exit 2; }
	@mkdir -p $(OUT)
	$(CC) $(LINK) $(CM_$*) -DPERFORMANCE_RUN=1 -DITERATIONS=$(ITER) '-DFLAGS_STR="$(CM_$*)"' \
	  -I$(B)/coremark -I$(TP)/coremark $(CM_SRC) -lm -o $@

$(OUT)/dhrystone.elf: $(BSP) $(B)/dhrystone/dhry_time.c
	@test -n "$(TP)" || { echo "Dhrystone sources not found: run perfmodel/scripts/fetch_deps.sh"; exit 2; }
	@mkdir -p $(OUT)/gen
	python3 -I $(ROOT)/perfmodel/bench/dhrystone/unshar.py $(TP)/dhrystone/dhry-c $(OUT)/gen > /dev/null
	$(CC) $(ARCH) -mcmodel=medany $(DHRY) -std=gnu89 -w -DTIME -Dmain=dhry_main -I$(OUT)/gen -c $(OUT)/gen/dhry_1.c -o $(OUT)/gen/dhry_1.o
	$(CC) $(LINK) $(DHRY) -std=gnu89 -w -DTIME '-DTG_STDIN="$(RUNS)\n"' -I$(OUT)/gen \
	  $(OUT)/gen/dhry_1.o $(OUT)/gen/dhry_2.c $(B)/dhrystone/dhry_time.c -lm -o $@

run: build
	@$(MAKE) --no-print-directory -C $(ROOT)/sim CFG=$(CFG) CORE=$(CORE) $(TC_ARG) build replay > /dev/null
	python3 $(B)/run_bench.py --sim $(TANAGER_BUILD)/$(WT)/sim/$(CFG)-$(CORE)$(TC_SUFFIX)/tg_vsim \
	  --replay $(TANAGER_BUILD)/$(WT)/sim/replay/tg_replay --iter $(ITER) --runs $(RUNS) --jobs $(JOBS) \
	  --name "$(CFG) $(CORE)$(TC_SUFFIX) $(MARCH) lat=$(LAT)" $(ELFS) -- --lat=$(LAT) $(SIMARGS)

print-out:
	@echo $(OUT)

clean:
	rm -rf $(OUT)
