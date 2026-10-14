"""The device fit from per-unit budget runs (docs/perf/area_recovery.md section 7; AR-7, AR-8).

Reads the budget flow's latest.json (fpga/budget/run_budget.py) for a core configuration and for the uncore,
adds hart 1's state where the RTL does not have it yet (the smt2 builds run hart 0 only until M7), and prints
the per-unit gap against fpga/budget/budgets.tsv and the dual-core total against the fill limits.

  python3 perfmodel/scripts/area_fit.py --core core/latest.json --uncore uncore/latest.json [--cfg smt2]
  python3 perfmodel/scripts/area_fit.py ... --no-hart1        # once M7 builds hart 1's state

Pass --budget-total to judge a configuration that has no per-unit lines yet (smt2_w3 before AR-9's lines).
"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUDGETS = ROOT / "fpga" / "budget" / "budgets.tsv"
DEVICE = 117120
# 88% is S6's 200 MHz result and the sum of v1's budgets; 90% is the plan's ceiling (DR-011); the 180 MHz
# figures are the full fill test's (area_synth.md section 5). AR-9's v2 budget came from the earlier 94.2% (110,280).
LIMITS = (("200 MHz, 88% (S6)", 103040), ("200 MHz, 90% (DR-011)", 105408),
          ("180 MHz, v1 closes at 95.3%", 111633), ("180 MHz, v2 closes at 96.0%", 112441))
UNITS = ("fe", "dec", "ren", "iq", "ex", "lsu_mmu", "rob_csr", "p4")
BUDGET_ROW = {"p4": "fpu"}  # P4 (tg_fp_exec) is judged against the FPU line; it also holds the FP register file
# Hart 1's state per unit, until M7 builds it: budgets.md's SMT2 additions after R1 and R2 (area_recovery.md 7.1).
HART1 = {"smt2": {"fe": 1000, "dec": 150, "ren": 1300, "rob_csr": 1650, "lsu_mmu": 100},
         "smt2_w3": {"fe": 1000, "dec": 200, "ren": 1450, "rob_csr": 1650, "lsu_mmu": 100}}


def budgets():
    rows = []
    for line in BUDGETS.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        rows.append(line.split("\t"))
    return rows


def budget_for(rows, unit, cfg):
    """The LUT budget of a unit (None when it is tracked only), as fpga/budget/run_budget.py looks it up."""
    for want in (cfg, "*"):
        for r in rows:
            if r[0] == unit and r[1] == want:
                return int(r[2]) if r[2] != "-" else None
    return None


def measured(path, cfg):
    data = json.loads(Path(path).read_text())
    out = {r["unit"]: r["values"]["opt_lut"] for r in data["results"] if r.get("cfg") == cfg and r.get("ok")}
    return out, data.get("stamp", "?"), data.get("commit", "?")


def k(x):
    return f"{x / 1000:.2f}".rstrip("0").rstrip(".") + "K"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--core", required=True, help="latest.json of a budget run with the core units")
    ap.add_argument("--uncore", required=True, help="latest.json of a budget run with the uncore")
    ap.add_argument("--cfg", default="smt2")
    ap.add_argument("--no-hart1", action="store_true", help="the RTL already has hart 1's state (M7)")
    ap.add_argument("--budget-total", type=int, help="per-core budget when the configuration has no lines")
    ap.add_argument("--uncore-cfg", help="the uncore run's configuration (default --cfg; smt2 for smt2_w3)")
    a = ap.parse_args()
    ucfg = a.uncore_cfg or a.cfg

    rows = budgets()
    core, stamp, commit = measured(a.core, a.cfg)
    unc, ustamp, _ = measured(a.uncore, ucfg)
    hart1 = {} if a.no_hart1 else HART1.get(a.cfg, {})
    print(f"core {a.cfg}: budget run {stamp} at {commit}; uncore: {ustamp}\n")
    print("| Unit | Budget | Measured | + hart 1 (est.) | Over |\n|---|---|---|---|---|")
    for u in UNITS:
        if u not in core:
            continue
        b = budget_for(rows, BUDGET_ROW.get(u, u), a.cfg)
        m, h = core[u], hart1.get(u, 0)
        over = f"{m + h - b:+,}" if b is not None else "—"
        print(f"| {u} | {b if b is not None else '—':,} | {m:,} | {('+' + k(h)) if h else '—'} | {over} |"
              if b is not None else f"| {u} | — | {m:,} | {('+' + k(h)) if h else '—'} | — |")
    core_total = core["core"] + sum(hart1.values())
    core_budget = a.budget_total or budget_for(rows, "core", a.cfg)
    h1 = f"**+{k(sum(hart1.values()))}**" if hart1 else "—"
    print(f"| **core** | **{core_budget:,}** | **{core['core']:,}** | {h1} | "
          f"**{core_total - core_budget:+,}** |" if core_budget else f"| core | — | {core['core']:,} | | |")
    ub = budget_for(rows, "uncore", ucfg)
    soc = 2 * core_total + unc["uncore"]
    print(f"\nuncore: {unc['uncore']:,} against {ub:,} ({unc['uncore'] - ub:+,})" if ub else "")
    print(f"dual-core: 2 x {core_total:,} + {unc['uncore']:,} = {soc:,} ({soc / DEVICE:.1%} of the XCK26)")
    for name, lim in LIMITS:
        print(f"  against {name} {lim:,}: {soc - lim:+,}")


if __name__ == "__main__":
    main()
