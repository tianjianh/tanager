# The fan's PL regulator (fpga/kv260/rtl/tg_fan.sv; docs/spec/soc.md §8.2, D2).  make -C tests/unit/fan short
TOP := tb_fan
TB  := $(CURDIR)/sysmone4_stub.sv $(abspath $(CURDIR)/../../../fpga/kv260/rtl/tg_fan.sv) $(CURDIR)/tb_fan.sv
include ../common/unit.mk
short:
	@$(MAKE) --no-print-directory run | grep -q "TEST PASSED" || { echo "FAIL fan"; exit 1; }; echo "fan: PASS"
long: short
