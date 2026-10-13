# Simulation tests of the spike RTL (fpga/spikes/rtl).
#   make -C fpga/spikes/sim iq                 tg_iq + tg_wake, every variant, smt2 and smt2_w3
#   make -C fpga/spikes/sim iq SEED=5 CYCLES=100000
#   make -C fpga/spikes/sim -j8 all          every spike test: iq, alu, fetch, dtlb, s1
ROOT   := $(abspath ../../..)
SEED   ?= 1
CYCLES ?= 20000
OBJ    ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))/spike_sim
VFLAGS := --binary --timing --assert -Wno-fatal -Wno-lint -Wno-style -j 8 -I$(ROOT)/rtl/common
COMMON := $(ROOT)/rtl/common/tg_pkg.sv $(ROOT)/rtl/common/prim/tg_ram_lut.sv
IQ_SRC := $(ROOT)/fpga/spikes/rtl/tg_iq.sv $(ROOT)/fpga/spikes/rtl/tg_wake.sv tb_iq.sv
# STALE = 1 (phase bit) is left out: it deadlocks when a pooled ID is reused twice while a
# row waits (run iq-st_s1_w0_d0_e32 to see it); see tg_iq.sv.
IQ_VARIANTS := $(foreach c,st smt2 smt2_w3,$(foreach s,0 2,$(foreach w,0 1,$(c)_s$(s)_w$(w)_d0_e32))) \
               $(foreach c,st smt2 smt2_w3,$(foreach s,0 2,$(c)_s$(s)_w1_d1_e16)) \
               $(foreach c,st smt2 smt2_w3,$(foreach s,0 2,$(c)_s$(s)_w1_d1_e16_mx))

.PHONY: iq clean
iq: $(addprefix iq-,$(IQ_VARIANTS))
iq-%:
	@set -e; v=$*; cfg=$${v%%_s*}; rest=$${v#*_s}; s=$${rest%%_w*}; rest=$${rest#*_w}; \
	w=$${rest%%_d*}; rest=$${rest#*_d}; dup=$${rest%%_e*}; rest=$${rest#*_e}; e=$${rest%%_mx}; \
	mx=0; case $$v in *_mx) mx=1;; esac; \
	d=$(OBJ)/iq_$$v; mkdir -p $$d; \
	verilator $(VFLAGS) --Mdir $$d --top-module tb_iq -GSTALE=$$s -GWAKE_ENC=$$w -GDUP_SEL=$$dup -GEARLY_W=$$e -GMX=$$mx \
	  $(ROOT)/rtl/common/cfg/tg_cfg_$$cfg.sv $(COMMON) $(IQ_SRC) > $$d/build.log 2>&1 || \
	  { tail -20 $$d/build.log; exit 1; }; \
	$$d/Vtb_iq +seed=$(SEED) +cycles=$(CYCLES) > $$d/run.log; \
	echo "$$v: $$(grep -E '^(PASS|FAIL)' $$d/run.log) $$(grep -E 'ops [0-9]+ selected' $$d/run.log)"; \
	grep -q '^PASS' $$d/run.log || { grep -E 'ERROR|never' $$d/run.log | head; exit 1; }
clean:
	rm -rf $(OBJ)

# tg_alu against the ISA reference
.PHONY: alu
alu:
	@d=$(OBJ)/alu; mkdir -p $$d; \
	verilator $(VFLAGS) --Mdir $$d --top-module tb_alu $(ROOT)/fpga/spikes/rtl/tg_alu_pkg.sv \
	  $(ROOT)/fpga/spikes/rtl/tg_alu.sv tb_alu.sv > $$d/build.log 2>&1 || { tail -20 $$d/build.log; exit 1; }; \
	$$d/Vtb_alu +seed=$(SEED) > $$d/run.log; cat $$d/run.log | grep -vE '^-' | head -12; grep -q '^PASS' $$d/run.log

# S5 IF2/IF3: tg_predecode + tg_fetch_compact, write widths 4 and 8, decode widths 2 and 3
FETCH_VARIANTS := st_wr4 st_wr8 st_w3_wr4 st_w3_wr8
.PHONY: fetch
fetch: $(addprefix fetch-,$(FETCH_VARIANTS))
fetch-%:
	@set -e; v=$*; cfg=$${v%_wr*}; wr=$${v##*_wr}; d=$(OBJ)/fetch_$$v; mkdir -p $$d; \
	verilator $(VFLAGS) --Mdir $$d --top-module tb_fetch -GWR=$$wr \
	  $(ROOT)/rtl/common/cfg/tg_cfg_$$cfg.sv $(COMMON) $(ROOT)/fpga/spikes/rtl/tg_predecode.sv \
	  $(ROOT)/fpga/spikes/rtl/tg_fetch_compact.sv tb_fetch.sv > $$d/build.log 2>&1 || \
	  { tail -20 $$d/build.log; exit 1; }; \
	$$d/Vtb_fetch +seed=$(SEED) > $$d/run.log; \
	echo "$$v: $$(grep -E '^(PASS|FAIL)' $$d/run.log)"; \
	grep -q '^PASS' $$d/run.log || { grep -E 'ERROR' $$d/run.log | head; exit 1; }

# tg_dtlb against a reference model, single-thread and SMT2 configurations
.PHONY: dtlb
dtlb: dtlb-st dtlb-smt2
dtlb-%:
	@d=$(OBJ)/dtlb_$*; mkdir -p $$d; \
	verilator $(VFLAGS) --Mdir $$d --top-module tb_dtlb $(ROOT)/rtl/common/cfg/tg_cfg_$*.sv \
	  $(COMMON) $(ROOT)/fpga/spikes/rtl/tg_dtlb.sv tb_dtlb.sv > $$d/build.log 2>&1 || { tail -20 $$d/build.log; exit 1; }; \
	$$d/Vtb_dtlb +seed=$(SEED) > $$d/run.log; echo "$*: $$(grep -E '^(PASS|FAIL)' $$d/run.log)"; \
	grep -q '^PASS' $$d/run.log || { grep ERROR $$d/run.log | head; exit 1; }

# S1 PL logic against AXI memory models
.PHONY: s1
s1:
	@d=$(OBJ)/s1; mkdir -p $$d; \
	verilator $(VFLAGS) --Mdir $$d --top-module tb_s1 $(ROOT)/rtl/common/prim/tg_ram_sdp.sv \
	  $(ROOT)/fpga/spikes/s1/rtl/tg_s1_engine.sv $(ROOT)/fpga/spikes/s1/rtl/tg_s1_top.sv \
	  $(ROOT)/fpga/spikes/s1/sim/tb_s1.sv > $$d/build.log 2>&1 || { tail -20 $$d/build.log; exit 1; }; \
	$$d/Vtb_s1 +seed=$(SEED) > $$d/run.log; echo "s1: $$(grep -E '^(PASS|FAIL)' $$d/run.log)"; \
	grep -q '^PASS' $$d/run.log || { grep ERROR $$d/run.log | head; exit 1; }

# Everything (about 5 minutes with -j8)
.PHONY: all
all: iq alu fetch dtlb s1
