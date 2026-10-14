# Commit-trace streaming test (docs/spec/uncore-trace.md).  make -C tests/unit/trace_stream short | run SEED=n
TOP := tb_trace_stream
TB  := $(CURDIR)/tb_trace_stream.sv
include ../common/unit.mk
$(OUTDIR)/$(TOP): $(REPO)/rtl/uncore/trace/tg_trace_stream.sv
short:
	@for s in 1 2 3; do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "trace_stream seed $$s: PASS"; done
long:
	@for s in 1 2 3 4 5 6 7 8 9 10; do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "trace_stream seed $$s: PASS"; done
