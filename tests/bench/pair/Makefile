# The pair runner (docs/spec/verification.md §4.8; the M7 plan's exit 2): smt2-study's 13 programs and 42 pairs
# (perfmodel/scripts/smt.py) on one smt2 core's two harts against each alone, in tg_vsim's flat memory at the latencies
# smt2-study's model uses. Run on the build host after `source tools/env.sh`.
#   make -C tests/bench/pair [REPEAT=1|0]         the programs, at both slots, and the images (build_pair.sh); the
#                                                 memory kernels repeat their region (exit 2's method, §4.8), or with
#                                                 REPEAT=0 run again from the top, in a build directory of its own
#   make -C tests/bench/pair replay               Spike against Spike: the images' own check (IPC 1, WS 2)
#   make -C tests/bench/pair run BASIS=half|merged [ALONE_SIM=<tg_vsim>] [ONLY=alone|pairs|all] [LAT=30,120,250]
#                                [JOBS=8] [LOCKSTEP=1] [SELECT=...] [OFF_ALONE=<json>]
#                                                 BASIS names what the alone runs have (run_pair.py --basis): half, a
#                                                 half of the split window (hart 1 on, before step 6), or merged
#                                                 tg_vsim, CFG=smt2; ONLY=pairs takes the alone figures of ONLY=alone's
#                                                 run (ws-alone.json); SELECT=prog,a+b runs some (ws-<only>-sel.json)
#                                                 OFF_ALONE: the no-loss check (DR-184) against a hart-1-off build's
#                                                 alone figures, e.g. ws-alone.json of `run BASIS=merged ONLY=alone`
#                                                 without HART1; exit 2's runs are `run HART1=1 BASIS=merged` after step 6
# The pairs need hart 1 (M7's step 5); the alone runs park it and run today. JSON lands beside the images.
ONLY     ?= all
LAT      ?= 30,120,250
JOBS     ?= 8
LOCKSTEP ?= 1
SELECT   ?=
BASIS    ?=
ALONE_SIM ?=
OFF_ALONE ?=
REPEAT   ?= 1

MAKEOVERRIDES :=

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
include $(ROOT)/sim/profile.mk
OUT  := $(TANAGER_BUILD)/$(WT)/pair$(if $(filter 0,$(REPEAT)),-restart)
SRC  := $(wildcard $(ROOT)/tests/bench/pair/*.S $(ROOT)/tests/bench/pair/*.c $(ROOT)/tests/bench/pair/*.h \
          $(ROOT)/tests/bench/pair/*.ld $(ROOT)/tests/bench/pair/inc/*.h) $(ROOT)/tests/bench/pair/build_pair.sh \
        $(wildcard $(ROOT)/perfmodel/bench/memsuite/*.[ch]) $(ROOT)/perfmodel/bench/coremark/core_portme.c \
        $(ROOT)/perfmodel/bench/embench/boardsupport.c $(ROOT)/tests/bench/dhrystone/dhry_time.c \
        $(ROOT)/perfmodel/scripts/smt.py

.PHONY: build replay run
build: $(OUT)/.built
$(OUT)/.built: $(SRC)
	REPEAT=$(REPEAT) bash $(ROOT)/tests/bench/pair/build_pair.sh $(OUT)
	@touch $@

replay: build
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim replay
	python3 $(ROOT)/tests/bench/pair/run_pair.py --replay $(TANAGER_BUILD)/$(WT)/sim/replay/tg_replay --images $(OUT) \
	  --only $(ONLY) --jobs $(JOBS)

run: build
	@test -n "$(BASIS)" || { echo "make run needs BASIS=half|merged: what the alone runs have (verification.md §4.8)"; exit 2; }
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim CFG=smt2 CORE=core $(TC_ARG) build
	python3 $(ROOT)/tests/bench/pair/run_pair.py --sim $(TANAGER_BUILD)/$(WT)/sim/smt2-core$(TC_SUFFIX)/tg_vsim \
	  --images $(OUT) --only $(ONLY) --lat $(LAT) --jobs $(JOBS) $(if $(filter 0,$(LOCKSTEP)),--no-lockstep) \
	  $(if $(SELECT),--select $(SELECT)) $(if $(filter pairs,$(ONLY)),--alone $(OUT)/ws-alone$(TC_SUFFIX).json) \
	  --basis $(BASIS) $(if $(ALONE_SIM),--alone-sim $(ALONE_SIM)) $(if $(OFF_ALONE),--off-alone $(OFF_ALONE)) \
	  --json $(OUT)/ws-$(ONLY)$(if $(SELECT),-sel)$(TC_SUFFIX).json
