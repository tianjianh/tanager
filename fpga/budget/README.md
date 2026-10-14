# Per-unit budgets in CI (plan §8.5)

Synthesises each real unit out of context in each configuration and holds it to its budget:
- LUTs, LUTRAM, flip-flops, DSP and block RAM, compared with [`budgets.tsv`](budgets.tsv) and with the previous run;
- the memory-primitive check ([`tools/tcl/tg_prim_check.tcl`](../../tools/tcl/tg_prim_check.tcl)) after synthesis and after `opt_design`.

The budgets and how they are derived are in [docs/perf/budgets.md](../../docs/perf/budgets.md).

## Commands

```bash
fpga/budget/nightly.sh
```
The nightly run, on main's latest commit.
- **Where it builds:** a copy exported with `git archive` under `$TANAGER_BUILD/budget/src`, deleted afterwards. No checkout is touched.
- **When it skips:** when main has not moved since the last run (`--force` overrides), and while drive C: has under 20 GB free.
- **Output** in `$TANAGER_BUILD/budget/`:
  - `latest.md`, the report;
  - `latest.json`;
  - `history/`, one file per run, for the deltas;
  - `reports/<unit>_<cfg>/`, the primitive check and hierarchical utilisation.

```bash
source tools/env.sh
python3 -I fpga/budget/run_budget.py --units fpu,iq --cfgs smt2
```
The same check on the current checkout, for some units (`--dry-run` lists what would run).

**Exit status:**
- 0: every enforced unit is within budget and primitive-clean;
- 1: a unit is over budget, or there is a primitive failure;
- 2: a synthesis did not finish;
- 3 (nightly only): skipped for disk space.

**Time:** each synthesis takes 1–2 minutes. All 13 of today's run one after another through `tools/vivado_run.sh`, queueing for a Vivado slot like any other job, in about 20 minutes.

## Files

| File | What it is |
|---|---|
| [`units.tsv`](units.tsv) | The units to build: name, configurations, top module, sources beyond `rtl/rtl.f`, generics. A line whose top module does not exist yet is skipped. |
| [`budgets.tsv`](budgets.tsv) | Budget per unit and configuration (`*` for all). `enforce` judges it; `track` only reports it. |
| [`tcl/unit_synth.tcl`](tcl/unit_synth.tcl) | The Vivado script: product RTL for the configuration, out-of-context synthesis, `opt_design`, primitive check, utilisation. |
| [`run_budget.py`](run_budget.py) | Runs the syntheses, compares, writes the report. |
| [`nightly.sh`](nightly.sh) | Exports main and runs `run_budget.py` on it. |

## Adding a unit

When the core track merges a unit (a plan §8.2 row), add one line to `units.tsv`: the budget name, the configurations, its top module, and `-` for files if it is in `rtl/rtl.f`.
- Its budget is already in `budgets.tsv`.
- Drop any spike stand-in for it. Today the scheduler comes from `fpga/spikes/rtl` (`tg_s2_sched_top`).

## Schedule

The run starts nightly from the user's crontab:
```
30 1 * * * /bin/bash -lc /home/w/tanager/fpga/budget/nightly.sh >> /home/w/tanager-build/budget/nightly.log 2>&1
```
- `crontab -l` shows the entry; `crontab -e` edits or removes it.
- Until `fpga/budget` is on main, the run says so and does nothing.
