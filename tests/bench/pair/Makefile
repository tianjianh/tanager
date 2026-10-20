# The pair runner (docs/spec/verification.md §4.8; the M7 plan's exit 2): smt2-study's 13 programs and 42 pairs
# (perfmodel/scripts/smt.py) on one smt2 core's two harts against each alone, in tg_vsim's flat memory at the latencies
# smt2-study's model uses. Run on the build host after `source tools/env.sh`.
#   make -C tests/bench/pair                      the programs, at both slots, and the images (build_pair.sh)
#   make -C tests/bench/pair replay               Spike against Spike: the images' own check (IPC 1, WS 2)
#   make -C tests/bench/pair run [ONLY=alone|pairs|all] [LAT=30,120,250] [JOBS=8] [LOCKSTEP=1]   tg_vsim, CFG=smt2
# The pairs need hart 1 (M7's step 5); the alone runs park it and run today. JSON lands beside the images.
ONLY     ?= all
LAT      ?= 30,120,250
JOBS     ?= 8
LOCKSTEP ?= 1

MAKEOVERRIDES :=

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
WT   := $(notdir $(ROOT))
TANAGER_BUILD ?= $(HOME)/tanager-build
include $(ROOT)/sim/profile.mk
OUT  := $(TANAGER_BUILD)/$(WT)/pair
SRC  := $(wildcard $(ROOT)/tests/bench/pair/*.S $(ROOT)/tests/bench/pair/*.c $(ROOT)/tests/bench/pair/*.h \
          $(ROOT)/tests/bench/pair/*.ld $(ROOT)/tests/bench/pair/inc/*.h) $(ROOT)/tests/bench/pair/build_pair.sh

.PHONY: build replay run
build: $(OUT)/.built
$(OUT)/.built: $(SRC)
	bash $(ROOT)/tests/bench/pair/build_pair.sh $(OUT)
	@touch $@

replay: build
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim replay
	python3 $(ROOT)/tests/bench/pair/run_pair.py --replay $(TANAGER_BUILD)/$(WT)/sim/replay/tg_replay --images $(OUT) \
	  --only $(ONLY) --jobs $(JOBS)

run: build
	@$(MAKE) --no-print-directory -s -C $(ROOT)/sim CFG=smt2 CORE=core $(TC_ARG) build
	python3 $(ROOT)/tests/bench/pair/run_pair.py --sim $(TANAGER_BUILD)/$(WT)/sim/smt2-core$(TC_SUFFIX)/tg_vsim \
	  --images $(OUT) --only $(ONLY) --lat $(LAT) --jobs $(JOBS) $(if $(filter 0,$(LOCKSTEP)),--no-lockstep) \
	  --json $(OUT)/ws-$(ONLY)$(TC_SUFFIX).json
