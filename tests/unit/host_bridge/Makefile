# Host bridge test (docs/spec/host.md).  make -C tests/unit/host_bridge short | run
TOP := tb_host_bridge
TB  := $(CURDIR)/tb_host_bridge.sv
include ../common/unit.mk
short:
	@$(MAKE) --no-print-directory run | grep -q "TEST PASSED" || { echo "FAIL"; exit 1; }; echo "host_bridge: PASS"
long: short
