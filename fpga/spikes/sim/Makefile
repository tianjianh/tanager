# Simulation tests of the spike RTL (fpga/spikes/rtl).
#   make -C fpga/spikes/sim iq                 tg_iq + tg_wake, every variant, smt2 and smt2_w3
#   make -C fpga/spikes/sim iq SEED=5 CYCLES=100000
ROOT   := $(abspath ../../..)
SEED   ?= 1
CYCLES ?= 20000
OBJ    ?= $(or $(TANAGER_BUILD),$(HOME)/tanager-build)/$(notdir $(ROOT))/spike_sim
VFLAGS := --binary --timing --assert -Wno-fatal -Wno-lint -Wno-style -j 8 -I$(ROOT)/rtl/common
COMMON := $(ROOT)/rtl/common/tg_pkg.sv $(ROOT)/rtl/common/prim/tg_ram_lut.sv
IQ_SRC := $(ROOT)/fpga/spikes/rtl/tg_iq.sv $(ROOT)/fpga/spikes/rtl/tg_wake.sv tb_iq.sv
IQ_VARIANTS := $(foreach c,st smt2 smt2_w3,$(foreach s,0 1 2,$(foreach w,0 1,$(c)_s$(s)_w$(w)_d0_e32))) \
               $(foreach c,st smt2 smt2_w3,$(foreach s,0 1 2,$(c)_s$(s)_w1_d1_e16))

.PHONY: iq clean
iq: $(addprefix iq-,$(IQ_VARIANTS))
iq-%:
	@set -e; v=$*; cfg=$${v%%_s*}; rest=$${v#*_s}; s=$${rest%%_w*}; rest=$${rest#*_w}; \
	w=$${rest%%_d*}; rest=$${rest#*_d}; dup=$${rest%%_e*}; e=$${rest#*_e}; \
	d=$(OBJ)/iq_$$v; mkdir -p $$d; \
	verilator $(VFLAGS) --Mdir $$d --top-module tb_iq -GSTALE=$$s -GWAKE_ENC=$$w -GDUP_SEL=$$dup -GEARLY_W=$$e \
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
