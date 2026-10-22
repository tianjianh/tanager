# SoC-track unit tests (docs/spec/conventions.md §6). Run after `source tools/env.sh`.
#   make -C tests/unit short     every block's short suite (about 2 minutes)
#   make -C tests/unit long      long random runs (L2: 1, 2, 4 agents x 10 seeds x 100k ops), and the
#                                real core booting OpenSBI in tanager_soc (1x1, 2x1, 2x2). Each suite runs
#                                its seeds PAR at a time (default 6) and logs them under tests/long_logs.
SOC_TESTS := dsp_reg l2 xbar periph uart_phy lat_inj axi_window host_bridge hdma ps_window trace_stream soc boot

.PHONY: short long $(SOC_TESTS)
short:
	@set -e; for t in $(SOC_TESTS); do $(MAKE) --no-print-directory -C $$t short; done
	@echo "SoC unit tests (short): PASS"

long:
	@set -e; for t in $(SOC_TESTS); do $(MAKE) --no-print-directory -C $$t long; done
	@echo "SoC unit tests (long): PASS"
