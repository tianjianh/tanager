# Shared rules for the SoC track's unit tests (docs/spec/conventions.md §6).
# A test's Makefile sets TOP, TB (its testbench files) and optionally PARAMS (-G...), then includes
# this file. Targets: build, run (SEED=, OPS= or ARGS=), short, long, clean; long-seeds (below).
# Builds go to $(SOC_BUILD)/tests/<name>, never into the repository.
REPO      := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
VERILATOR ?= verilator
CFG       ?= st
NAME      ?= $(TOP)
# $TANAGER_BUILD/<worktree> by default, so tools/env.sh alone is enough (conventions §1);
# exported for the sub-makes (the SoC test's program).
SOC_BUILD ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(REPO))
export SOC_BUILD
OUTDIR    := $(SOC_BUILD)/tests/$(NAME)_$(CFG)
JOBS      ?= 8
SEED      ?= 1
ARGS      ?=

RTL_SRCS := $(REPO)/rtl/common/cfg/tg_cfg_$(CFG).sv -F $(REPO)/rtl/common/common.f -F $(REPO)/rtl/uncore/uncore.f
TB_COMMON := $(REPO)/tests/unit/common/tb_axi_mem_pkg.sv $(REPO)/tests/unit/common/tb_axi_mem.sv

VFLAGS := --binary --timing --timescale 1ns/1ps --assert -j $(JOBS) -Wno-fatal -Wno-lint -Wno-style -Wno-MULTITOP \
          -I$(REPO)/rtl/common --top-module $(TOP) -o $(TOP) --Mdir $(OUTDIR) \
          -CFLAGS -O1 $(PARAMS) $(EXTRA_VFLAGS)

.PHONY: build run short long clean
build: $(OUTDIR)/$(TOP)

$(OUTDIR)/$(TOP): $(TB) $(TB_COMMON) $(shell sed -e 's://.*$$::' $(REPO)/rtl/uncore/uncore.f | sed -e '/^\s*$$/d' -e 's:^:$(REPO)/rtl/uncore/:')
	@mkdir -p $(OUTDIR)
	$(VERILATOR) $(VFLAGS) $(RTL_SRCS) $(TB_COMMON) $(TB) > $(OUTDIR)/build.log 2>&1 || { tail -40 $(OUTDIR)/build.log; exit 1; }

run: build
	$(OUTDIR)/$(TOP) +seed=$(SEED) $(ARGS)

clean:
	rm -rf $(OUTDIR)

# Long runs in parallel (conventions §9: use the build host's idle threads). A test sets LONG_SEEDS and
# LABEL before including this file, and its long target depends on long-seeds: one build, then one run
# per seed, PAR at a time, each logged to $(LOGDIR)/$(NAME)_s<seed>.log.
PAR    ?= 6
LOGDIR := $(SOC_BUILD)/tests/long_logs
ifneq ($(strip $(LONG_SEEDS)),)
SEED_RUNS := $(addprefix seed-,$(LONG_SEEDS))
.PHONY: long-seeds $(SEED_RUNS)
long-seeds:
	@$(MAKE) --no-print-directory build
	@mkdir -p $(LOGDIR)
	@$(MAKE) --no-print-directory -j$(PAR) $(SEED_RUNS)
$(SEED_RUNS): seed-%:
	@if $(MAKE) --no-print-directory run SEED=$* > $(LOGDIR)/$(NAME)_s$*.log 2>&1 && grep -q "TEST PASSED" $(LOGDIR)/$(NAME)_s$*.log; \
	then echo "$(LABEL) seed $*: PASS"; else echo "FAIL $(LABEL) seed $* ($(LOGDIR)/$(NAME)_s$*.log)"; exit 1; fi
endif
