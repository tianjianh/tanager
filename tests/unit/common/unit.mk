# Shared rules for the SoC track's unit tests (docs/spec/conventions.md §6).
# A test's Makefile sets TOP, TB (its testbench files) and optionally PARAMS (-G...), then includes
# this file. Targets: build, run (SEED=, OPS= or ARGS=), short, long, clean.
# Builds go to $(SOC_BUILD)/tests/<name>, never into the repository.
REPO      := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
VERILATOR ?= verilator
CFG       ?= st
NAME      ?= $(TOP)
SOC_BUILD ?= $(HOME)/tanager-build/$(notdir $(REPO))
OUTDIR    := $(SOC_BUILD)/tests/$(NAME)_$(CFG)
JOBS      ?= 8
SEED      ?= 1
ARGS      ?=

RTL_SRCS := $(REPO)/rtl/common/cfg/tg_cfg_$(CFG).sv -F $(REPO)/rtl/common/common.f -F $(REPO)/rtl/uncore/uncore.f
TB_COMMON := $(REPO)/tests/unit/common/tb_axi_mem_pkg.sv $(REPO)/tests/unit/common/tb_axi_mem.sv

VFLAGS := --binary --timing --assert -j $(JOBS) -Wno-fatal -Wno-lint -Wno-style -Wno-MULTITOP \
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
