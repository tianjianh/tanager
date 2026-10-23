# MMIO peripheral tests (docs/spec/uncore-periph.md).  make -C tests/unit/periph short | run SEED=n [VIRTIO=1] [REL=1]
# VIRTIO=1: the device bus with the virtio slots as a device that waits (the forwarded window's case). REL=1: the
# PLIC as release builds have it (DR-180: the S-mode contexts alone, 1-bit priorities).
TOP := tb_periph
TB  := $(CURDIR)/tb_periph.sv
VIRTIO ?= 0
REL    ?= 0
NAME   := tb_periph$(if $(filter 1,$(VIRTIO)),_virtio)$(if $(filter 1,$(REL)),_rel)
PARAMS := -GVIRTIO=$(VIRTIO) -GREL=$(REL)
LONG_SEEDS := 1 2 3 4 5 6 7 8
LABEL      := periph
include ../common/unit.mk
short:
	@for s in 1 2; do $(MAKE) --no-print-directory run SEED=$$s | grep -q "TEST PASSED" || { echo "FAIL seed $$s"; exit 1; }; echo "periph seed $$s: PASS"; done
	@$(MAKE) --no-print-directory run SEED=3 VIRTIO=1 | grep -q "TEST PASSED" || { echo "FAIL VIRTIO=1"; exit 1; }; echo "periph with the virtio wait: PASS"
	@$(MAKE) --no-print-directory run SEED=4 REL=1 | grep -q "TEST PASSED" || { echo "FAIL REL=1"; exit 1; }; echo "periph with the release PLIC (DR-180): PASS"
long: long-seeds
