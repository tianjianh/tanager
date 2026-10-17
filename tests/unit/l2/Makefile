# L2 bank random test (docs/spec/l2.md §Verification).
#   make -C tests/unit/l2 short            1 agent, 3 seeds x 20k ops (M4 configuration)
#   make -C tests/unit/l2 long             1, 2 and 4 agents, 10 seeds x 100k ops
#   make -C tests/unit/l2 run NA=2 SEED=7 OPS=50000 [MSHR=8] [LAT=2] [S3=1] [ACQ=4]
#   ACQ: Acquires an agent keeps outstanding (DR-149's 4-miss L1D: 4; default 1)
TOP    := tb_l2
NA     ?= 1
MSHR   ?= 8
LAT    ?= 2
S3     ?= 1
ACQ    ?= 1
NAME   := l2_na$(NA)_m$(MSHR)_l$(LAT)$(if $(filter 0,$(S3)),_s2w)$(if $(filter-out 1,$(ACQ)),_a$(ACQ))
TB     := $(CURDIR)/tb_l2.sv
PARAMS := -GNA=$(NA) -GN_MSHR=$(MSHR) -GDATA_LAT=$(LAT) -GDIR_S3=$(S3) -GACQ_N=$(ACQ)
OPS    ?= 20000
EXTRA_ARGS ?=
ARGS   = +ops=$(OPS) $(EXTRA_ARGS)
include ../common/unit.mk

short:
	@for s in 1 2 3; do $(MAKE) --no-print-directory run NA=1 SEED=$$s OPS=20000 | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "l2 NA=1 seed $$s: PASS"; done
	@$(MAKE) --no-print-directory run NA=1 SEED=4 OPS=20000 EXTRA_ARGS=+errlines | grep -q "TEST PASSED" || { echo "FAIL errlines"; exit 1; }; echo "l2 NA=1 AXI errors: PASS"
	@$(MAKE) --no-print-directory run NA=1 SEED=5 OPS=20000 LAT=4 | grep -q "TEST PASSED" || { echo "FAIL LAT=4"; exit 1; }; echo "l2 NA=1 data latency 4: PASS"
	@$(MAKE) --no-print-directory run NA=1 SEED=6 OPS=20000 S3=0 | grep -q "TEST PASSED" || { echo "FAIL S3=0"; exit 1; }; echo "l2 NA=1 directory written at S2: PASS"
	@$(MAKE) --no-print-directory run NA=2 SEED=8 OPS=20000 ACQ=4 | grep -q "TEST PASSED" || { echo "FAIL ACQ=4"; exit 1; }; echo "l2 NA=2 four Acquires per agent: PASS"

# long: every model is built first (NA 1, 2, 4 x LAT 2, 4), then all 36 runs go PAR at a time,
# each logged to $(LOGDIR)/l2_<run>.log
L2_LONG := $(foreach na,1 2 4,$(foreach s,1 2 3 4 5 6 7 8 9 10,na$(na)-s$(s)) na$(na)-err na$(na)-lat4 na$(na)-acq4)
.PHONY: long $(L2_LONG)
long:
	@for na in 1 2 4; do for lat in 2 4; do $(MAKE) --no-print-directory build NA=$$na LAT=$$lat || exit 1; done; \
	  $(MAKE) --no-print-directory build NA=$$na ACQ=4 || exit 1; done
	@mkdir -p $(LOGDIR)
	@$(MAKE) --no-print-directory -j$(PAR) $(L2_LONG)
$(L2_LONG): na%:
	@set -- $(subst -, ,$*); case $$2 in \
	  s*)   args="SEED=$${2#s} OPS=100000"; what="seed $${2#s}";; \
	  err)  args="SEED=99 OPS=50000 EXTRA_ARGS=+errlines"; what="AXI errors";; \
	  lat4) args="SEED=77 OPS=100000 LAT=4"; what="data latency 4";; \
	  acq4) args="SEED=55 OPS=100000 ACQ=4"; what="four Acquires per agent";; esac; \
	if $(MAKE) --no-print-directory run NA=$$1 $$args > $(LOGDIR)/l2_$@.log 2>&1 && grep -q "TEST PASSED" $(LOGDIR)/l2_$@.log; \
	then echo "l2 NA=$$1 $$what: PASS"; else echo "FAIL l2 NA=$$1 $$what ($(LOGDIR)/l2_$@.log)"; exit 1; fi
