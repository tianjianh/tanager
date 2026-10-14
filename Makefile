# Tanager top-level entry points. Run in WSL Ubuntu-24.04 after `source tools/env.sh`.
#   make lint CFG=st         lint all product RTL for one configuration
#   make lint-all            lint all four configurations
#   make regress CFG=st      verification regression (tools/ci/regress.sh; CORE=tcore for the test core)
# Track-specific targets live in their areas (sim/, tests/, fpga/); see docs/spec/conventions.md.

CFG  ?= st
CFGS := st smt2 st_w3 smt2_w3
VERILATOR ?= verilator

RTL_CFG := rtl/common/cfg/tg_cfg_$(CFG).sv
RTL_F   := rtl/rtl.f
LINT_FLAGS := --lint-only -Wall -Wno-MULTITOP --timing -Irtl/common rtl/lint.vlt

.PHONY: lint lint-all regress
lint:
	@test -f $(RTL_CFG) || { echo "unknown CFG=$(CFG) (one of: $(CFGS))"; exit 2; }
	$(VERILATOR) $(LINT_FLAGS) $(RTL_CFG) -F $(RTL_F)
	@echo "lint OK: $(CFG)"

lint-all:
	@set -e; for c in $(CFGS); do $(MAKE) --no-print-directory lint CFG=$$c; done

# Verification regression for one configuration (docs/spec/verification.md §4.3).
CORE ?= core
regress:
	@tools/ci/regress.sh CFG=$(CFG) CORE=$(CORE) $(if $(LAT),LAT=$(LAT)) $(if $(SUITES),SUITES="$(SUITES)") \
	  $(if $(MARCH),MARCH=$(MARCH)) $(if $(SELFTEST),SELFTEST=$(SELFTEST)) $(if $(RANDN),RANDN=$(RANDN))
