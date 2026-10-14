# Spike RTL lint (fpga/spikes). Vivado runs: fpga/spikes/scripts/run_ooc.sh; see
# docs/perf/spikes.md. Simulation tests: make -C fpga/spikes/sim.
#   make -C fpga/spikes lint
ROOT := $(abspath ../..)
# The pinned Verilator (tools/env.sh); /usr/bin/verilator 5.020 gives wrong results here.
ifeq ($(VERILATOR_ROOT),)
$(error source tools/env.sh first: the pinned Verilator is needed, not /usr/bin/verilator)
endif
VERILATOR ?= verilator
LINT := $(VERILATOR) --lint-only -Wall -Wno-MULTITOP -I$(ROOT)/rtl/common $(ROOT)/rtl/lint.vlt lint.vlt

# top:cfg:generics
CHECKS := \
  tg_s0_lutram_top:st: \
  $(foreach c,st smt2 smt2_w3,$(foreach s,0 1 2,$(foreach w,0 1,tg_s2_iq_top:$(c):-GSTALE=$(s)+-GWAKE_ENC=$(w) tg_s2_sched_top:$(c):-GSTALE=$(s)+-GWAKE_ENC=$(w)))) \
  $(foreach c,smt2 smt2_w3,tg_s2_sched_top:$(c):-GSTALE=0+-GWAKE_ENC=1+-GDUP_SEL=1\'b1+-GEARLY_W=24+-GMX=1\'b1+-GISS_REG=1\'b1) \
  $(foreach c,st smt2 st_w3 smt2_w3,$(foreach b,0 1,$(foreach r,0 1,$(foreach o,0 1,tg_s3_top:$(c):-GBYPASS=$(b)+-GRF3=$(r)+-GSEL_OH=$(o))))) \
  $(foreach c,st smt2,$(foreach a,0 1,tg_s4_top:$(c):-GALIGN_M1=$(a))) \
  $(foreach c,st smt2 st_w3 smt2_w3,$(foreach f,0 1,$(foreach w,4 8,tg_s5_top:$(c):-GFA=$(f)+-GWR=$(w)))) \
  $(foreach c,st smt2_w3,tg_s6_top:$(c):-GCORE_TILES=300+-GCORE_NRAM=2+-GCORE_NBRAM=2+-GCORE_NDSP=2+-GUNC_TILES=100+-GUNC_NRAM=2+-GS2_MX=$(if $(filter st,$(c)),0,1))

.PHONY: lint
lint:
	@set -e; for ck in $(CHECKS); do \
	  top=$${ck%%:*}; rest=$${ck#*:}; cfg=$${rest%%:*}; g=$$(echo $${rest#*:} | tr '+' ' '); \
	  out=$$($(LINT) $(ROOT)/rtl/common/cfg/tg_cfg_$$cfg.sv -F $(ROOT)/rtl/common/common.f \
	        -F spikes.f --top-module $$top $$g 2>&1 | grep -E '^%' || true); \
	  if [ -n "$$out" ]; then echo "== $$top $$cfg $$g"; echo "$$out"; exit 1; fi; \
	done; \
	out=$$($(LINT) $(ROOT)/rtl/common/prim/tg_ram_sdp.sv s1/rtl/tg_s1_engine.sv \
	      s1/rtl/tg_s1_top.sv --top-module tg_s1_top 2>&1 | grep -E '^%' || true); \
	if [ -n "$$out" ]; then echo "== tg_s1_top"; echo "$$out"; exit 1; fi; \
	echo "spike lint OK ($(words $(CHECKS)) checks + S1)"
