# Host bridge test (docs/spec/host.md).  make -C tests/unit/host_bridge short | run [COMMIT_TRACE=0] [VIRTIO=1] [HDMA=1] [LAT_INJ=0] [REL=1]
# COMMIT_TRACE=0: the bridge built without the trace stream (DR-146). VIRTIO=1: with the forwarded
# virtio window (docs/spec/soc.md §8.1). HDMA=1: with the host DMA port's completion registers. LAT_INJ=0: a release
# build's bridge, without the latency injectors (DR-177): CAPS[1] and the INJ_* registers read 0. REL=1: a release
# build's bridge as tg_uncore RELEASE has it (DR-180), so COMMIT_TRACE=0 and LAT_INJ=0 too: no host console, no DMA
# line counters or completions, trimmed crossings (with HDMA=1 for the DMA registers' release form).
TOP    := tb_host_bridge
TB     := $(CURDIR)/tb_host_bridge.sv
COMMIT_TRACE ?= 1
VIRTIO ?= 0
HDMA   ?= 0
LAT_INJ ?= 1
REL    ?= 0
ifeq ($(REL),1)
  ifneq ($(VIRTIO),0)
    $(error REL=1 builds no virtio window (DR-180): leave VIRTIO at 0)
  endif
  override COMMIT_TRACE := 0
  override LAT_INJ := 0
endif
NAME   := tb_host_bridge$(if $(filter 0,$(COMMIT_TRACE)),_notrace)$(if $(filter 1,$(VIRTIO)),_virtio)$(if $(filter 1,$(HDMA)),_hdma)$(if $(filter 0,$(LAT_INJ)),_rel)$(if $(filter 1,$(REL)),ease)
PARAMS := -GTRACE=$(COMMIT_TRACE) -GVIRTIO=$(VIRTIO) -GHDMA=$(HDMA) -GLAT_INJ=$(LAT_INJ) -GREL=$(REL)
include ../common/unit.mk
short:
	@$(MAKE) --no-print-directory run | grep -q "TEST PASSED" || { echo "FAIL"; exit 1; }; echo "host_bridge: PASS"
	@$(MAKE) --no-print-directory run COMMIT_TRACE=0 | grep -q "TEST PASSED" || { echo "FAIL COMMIT_TRACE=0"; exit 1; }; echo "host_bridge without the trace: PASS"
	@$(MAKE) --no-print-directory run VIRTIO=1 | grep -q "TEST PASSED" || { echo "FAIL VIRTIO=1"; exit 1; }; echo "host_bridge with the virtio window: PASS"
	@$(MAKE) --no-print-directory run HDMA=1 | grep -q "TEST PASSED" || { echo "FAIL HDMA=1"; exit 1; }; echo "host_bridge with the host DMA port: PASS"
	@$(MAKE) --no-print-directory run LAT_INJ=0 | grep -q "TEST PASSED" || { echo "FAIL LAT_INJ=0"; exit 1; }; echo "host_bridge without the latency injectors: PASS"
	@$(MAKE) --no-print-directory run REL=1 HDMA=1 | grep -q "TEST PASSED" || { echo "FAIL REL=1 HDMA=1"; exit 1; }; echo "host_bridge, a release build's (DR-180): PASS"
long: short
