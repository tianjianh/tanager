# UART serial line test (docs/spec/uncore-periph.md §UART).  make -C tests/unit/uart_phy short | run SEED=n
TOP := tb_uart_phy
TB  := $(CURDIR)/tb_uart_phy.sv
LONG_SEEDS := 1 2 3 4
LABEL      := uart_phy
include ../common/unit.mk
$(OUTDIR)/$(TOP): $(REPO)/rtl/uncore/uart/tg_uart_phy.sv
short:
	@$(MAKE) --no-print-directory run SEED=1 | grep -q "TEST PASSED" || { echo "FAIL uart_phy"; exit 1; }; echo "uart_phy: PASS"
long: long-seeds
