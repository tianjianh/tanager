# Host bridge test (docs/spec/host.md).  make -C tests/unit/host_bridge short | run [COMMIT_TRACE=0]
# COMMIT_TRACE=0: the bridge built without the trace stream (DR-146).
TOP    := tb_host_bridge
TB     := $(CURDIR)/tb_host_bridge.sv
COMMIT_TRACE ?= 1
NAME   := tb_host_bridge$(if $(filter 0,$(COMMIT_TRACE)),_notrace)
PARAMS := -GTRACE=$(COMMIT_TRACE)
include ../common/unit.mk
short:
	@$(MAKE) --no-print-directory run | grep -q "TEST PASSED" || { echo "FAIL"; exit 1; }; echo "host_bridge: PASS"
	@$(MAKE) --no-print-directory run COMMIT_TRACE=0 | grep -q "TEST PASSED" || { echo "FAIL COMMIT_TRACE=0"; exit 1; }; echo "host_bridge without the trace: PASS"
long: short
