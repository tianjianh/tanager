# SoC-track unit tests (docs/spec/conventions.md §6). Run after `source tools/env.sh`.
#   make -C tests/unit short     every block's short suite (about 2 minutes)
#   make -C tests/unit long      long random runs (L2: 1, 2, 4 agents x 10 seeds x 100k ops), and the
#                                real core booting OpenSBI in tanager_soc (1 and 2 cores)
SOC_TESTS := l2 xbar periph lat_inj axi_window host_bridge trace_stream soc boot

.PHONY: short long $(SOC_TESTS)
short:
	@set -e; for t in $(SOC_TESTS); do $(MAKE) --no-print-directory -C $$t short; done
	@echo "SoC unit tests (short): PASS"

long:
	@set -e; for t in $(SOC_TESTS); do $(MAKE) --no-print-directory -C $$t long; done
	@echo "SoC unit tests (long): PASS"
