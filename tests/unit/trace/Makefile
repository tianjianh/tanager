# Commit-trace ring test (docs/spec/host.md).  make -C tests/unit/trace short | run SEED=n
TOP := tb_trace
TB  := $(CURDIR)/tb_trace.sv
include ../common/unit.mk
short:
	@for s in 1 2 3; do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "trace seed $$s: PASS"; done
long: short
