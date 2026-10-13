# FPGA spikes (M0)

The M0 spikes of plan §11: timing and area of the structures the plan protects (§8.1), measured on the XCK26 before the core's RTL settles. Results and conclusions are in [docs/perf/spikes.md](../../docs/perf/spikes.md).

| Path | Contents |
|---|---|
| `rtl/` | Spike RTL. Production intent: `tg_iq`, `tg_wake`, `tg_alu`, `tg_irf`, `tg_dtlb`, `tg_ubtb`, `tg_predecode`, `tg_fetch_compact`. Harness tops: `tg_s*_top`. S6 synthetic logic: `tg_s6_*`. |
| `spikes.f` | Filelist, read after `rtl/common/common.f` |
| `sim/` | Random tests against reference models: `make -C fpga/spikes/sim -j8 all` |
| `tcl/ooc_run.tcl` | Out-of-context (or whole-device) synth, place and route with the reports the doc quotes |
| `tcl/paths_s*.tcl` | Named paths per spike |
| `scripts/run_ooc.sh` | One run through `tools/vivado_run.sh`; keeps the small reports in `results/<name>/` and deletes the run directory |
| `scripts/results_table.py` | Markdown tables from `results/` |
| `scripts/gen_s6_core.py`, `scripts/s6_size.py` | S6: generates the synthetic core, sizes a configuration to a LUT target |
| `results/` | One directory per run: `summary.txt` (the exact command is in `top`, `cfg`, `generics`), `paths.txt`, `util_hier.rpt`, `timing_worst.rpt`, `prim_*.txt` |
| `s1/` | S1: the KV260 PL design, the A53 program and the steps for the board ([s1/README.md](s1/README.md)) |

**Commands** (after `source tools/env.sh`):
```bash
make -C fpga/spikes lint                       # every spike top, every configuration
make -C fpga/spikes/sim -j8 all                # every spike test
fpga/spikes/scripts/run_ooc.sh s3_st st tg_s3_top -g BYPASS=0 -paths fpga/spikes/tcl/paths_s3.tcl
python3 -I fpga/spikes/scripts/results_table.py 's3_*'
```

Vivado runs only through `tools/vivado_run.sh` (conventions §9). An out-of-context run takes 5–15 minutes; an S6 whole-device run takes hours and about 10–15 GB of RAM.
