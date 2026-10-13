# Latency injector test (docs/spec/uncore-mem.md).  make -C tests/unit/lat_inj short | run SEED=n
TOP  := tb_lat_inj
TB   := $(CURDIR)/tb_lat_inj.sv
include ../common/unit.mk
short:
	@for s in 1 2 3; do $(MAKE) --no-print-directory run SEED=$$s | tail -3 | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "lat_inj seed $$s: PASS"; done
long: short
