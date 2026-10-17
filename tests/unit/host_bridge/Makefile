# Host bridge test (docs/spec/host.md).  make -C tests/unit/host_bridge short | run [COMMIT_TRACE=0] [VIRTIO=1] [HDMA=1]
# COMMIT_TRACE=0: the bridge built without the trace stream (DR-146). VIRTIO=1: with the forwarded
# virtio window (docs/spec/soc.md §8.1). HDMA=1: with the host DMA port's completion registers.
TOP    := tb_host_bridge
TB     := $(CURDIR)/tb_host_bridge.sv
COMMIT_TRACE ?= 1
VIRTIO ?= 0
HDMA   ?= 0
NAME   := tb_host_bridge$(if $(filter 0,$(COMMIT_TRACE)),_notrace)$(if $(filter 1,$(VIRTIO)),_virtio)$(if $(filter 1,$(HDMA)),_hdma)
PARAMS := -GTRACE=$(COMMIT_TRACE) -GVIRTIO=$(VIRTIO) -GHDMA=$(HDMA)
include ../common/unit.mk
short:
	@$(MAKE) --no-print-directory run | grep -q "TEST PASSED" || { echo "FAIL"; exit 1; }; echo "host_bridge: PASS"
	@$(MAKE) --no-print-directory run COMMIT_TRACE=0 | grep -q "TEST PASSED" || { echo "FAIL COMMIT_TRACE=0"; exit 1; }; echo "host_bridge without the trace: PASS"
	@$(MAKE) --no-print-directory run VIRTIO=1 | grep -q "TEST PASSED" || { echo "FAIL VIRTIO=1"; exit 1; }; echo "host_bridge with the virtio window: PASS"
	@$(MAKE) --no-print-directory run HDMA=1 | grep -q "TEST PASSED" || { echo "FAIL HDMA=1"; exit 1; }; echo "host_bridge with the host DMA port: PASS"
long: short
