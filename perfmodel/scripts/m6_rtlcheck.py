"""The first M6 stack checked against the RTL (docs/perf/area_recovery.md §6.4).

core-2's stack (the RAS, TAGE-lite overriding at F2, returns repaired at F2, on main's four misses in flight) and
main itself, on make perf's own ELFs (tests/bench: CoreMark 10 iterations, Dhrystone 500 runs; rv64im and rv64gc;
tg_vsim's memory at native latency; timed regions). The model runs with each correction this check found added in
turn, against the RTL's scores (main cee5332 and core-2's measured head 96a1c81, make perf):
  1  §6.3's settings for the stack: the model's TAGE-lite, a 1-cycle F2 override
  2  + TAGE-lite as built (m2_btage), the cut, a 2-cycle override and the FTQ
  3  + the RTL's issue queues (iq_slot_bank, iq_hold)
  4  + the store address waiting for its data (sta_split 0): rtl_m2 as recalibrated
--levers: two RTL questions on the recalibrated model, on main and on the stack: the store address issuing on its
base alone (sta_split 1), and issue-queue rows freed at their select (iq_hold 1, as without the shadow).

  python3 scripts/m6_rtlcheck.py [--bench DIR] [--levers]   # -> results/m6_rtlcheck_rv64.json and tables
DIR holds <march>-i10-r500/ from `make -C tests/bench MARCH=<march> ITER=10 RUNS=500 build` (default: the build
host's ~/tanager-build/rtlcal/bench). At most 8 runs at a time (the build host is shared).
"""
import argparse
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tgrun  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "m6_rtlcheck_rv64.json"
TAGE = {"m2_dir": 1, "dirpred": 2, "tage_log": 12, "m2_f2": 1}
RTL_TAGE = {"m2_btage": 1, "btage_lag": 1, "btage_tq": 4, "m2_cut": 1, "m2_f2_bubble": 2, "m2_ftq": 32}
STACK = {"ras": 32, **TAGE, "m2_ras_f2": 1}
OLD = {"iq_slot_bank": 0, "iq_hold": 0, "sta_split": 1}       # rtl_m2 before §6.4 (with four misses)
IQ = {"iq_slot_bank": 1, "iq_hold": 3, "sta_split": 1}
VARIANTS = {  # (main, the stack)
    "1": (OLD, {**OLD, **STACK, "m2_f2_bubble": 1}),
    "2": (OLD, {**OLD, **STACK, **RTL_TAGE}),
    "3": (IQ, {**IQ, **STACK, **RTL_TAGE}),
    "4": ({}, {**STACK, **RTL_TAGE}),
}
LEVERS = {"as built": {}, "STA on its base alone": {"sta_split": 1}, "rows freed at select": {"iq_hold": 1},
          "both": {"sta_split": 1, "iq_hold": 1}}
PROGS = [(p, m) for m in ("rv64im", "rv64gc") for p in ("coremark_A", "coremark_B", "dhrystone")]
# The RTL, make perf (st, native, timed regions): main cee5332, and core-2's stack (96a1c81, the same scores)
RTL = {("coremark_A", "rv64im"): (3.056, 3.808), ("coremark_B", "rv64im"): (2.896, 3.607),
       ("dhrystone", "rv64im"): (1.632, 2.426), ("dhrystone", "rv64gc"): (1.483, 2.431),
       ("coremark_A", "rv64gc"): (3.064, 3.779), ("coremark_B", "rv64gc"): (None, 3.577)}


def score(p, cyc):
    return 10e6 / cyc if p.startswith("coremark") else 500e6 / (cyc * 1757)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bench", default=os.path.expanduser("~/tanager-build/rtlcal/bench"))
    ap.add_argument("--levers", action="store_true")
    ap.add_argument("--jobs", type=int, default=8)
    a = ap.parse_args()
    table = {k: v for k, v in VARIANTS.items()} if not a.levers else \
        {k: ({**v}, {**STACK, **RTL_TAGE, **v}) for k, v in LEVERS.items()}
    jobs = [(p, m, v, i) for (p, m) in PROGS for v in table for i in (0, 1)]

    def one(j):
        p, m, v, i = j
        w = {"name": p, "elf": f"{a.bench}/{m}-i10-r500/{p}.elf", "stdin": "", "ff": 0}
        r = tgrun.run_one(w, "rtl_m2", table[v][i])
        if r.get("error") or not r.get("region", {}).get("cycles"):
            raise SystemExit(f"tgsim failed on {w['elf']}: {r.get('error', '')}")
        return j, r["region"]

    with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        res = dict(ex.map(one, jobs))
    sc = {k: score(k[0], r["cycles"]) for k, r in res.items()}
    old = json.loads(OUT.read_text()) if OUT.exists() else {}
    old["levers" if a.levers else "check"] = {"|".join(map(str, k)): {"score": sc[k], **{x: res[k].get(x, 0) for x in (
        "cycles", "instr", "mp_dir", "mp_resolved_commit", "f2_overrides", "f2_cuts", "violation_flushes",
        "disp_stall_slot", "disp_stall_iq")}} for k in res}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(old, indent=1) + "\n")
    if a.levers:
        print("| Program | Core | as built | " + " | ".join(list(LEVERS)[1:]) + " |")
        print("|---|---|---|" + "---|" * (len(LEVERS) - 1))
        for p, m in PROGS:
            for i, core in ((0, "main"), (1, "stack")):
                b = sc[(p, m, "as built", i)]
                print(f"| {p} {m} | {core} | {b:.3f} | " +
                      " | ".join(f"{sc[(p, m, v, i)] / b - 1:+.1%}" for v in list(LEVERS)[1:]) + " |")
        return
    print("| Program | RTL: main -> the stack | " + " | ".join(f"model {v}" for v in VARIANTS) + " |")
    print("|---|---|" + "---|" * len(VARIANTS))
    for p, m in PROGS:
        rb, rs = RTL[(p, m)]
        rc = f"{rb:.3f} -> {rs:.3f} ({rs / rb - 1:+.1%})" if rb else f"— -> {rs:.3f}"
        cells = [f"{sc[(p, m, v, 0)]:.3f} -> {sc[(p, m, v, 1)]:.3f} ({sc[(p, m, v, 1)] / sc[(p, m, v, 0)] - 1:+.1%})"
                 for v in VARIANTS]
        print(f"| {p} {m} | {rc} | " + " | ".join(cells) + " |")
    print("\n| Program | the stack's score, model against RTL: " + " | ".join(VARIANTS) + " |")
    print("|---|" + "---|" * len(VARIANTS))
    for p, m in PROGS:
        rs = RTL[(p, m)][1]
        print(f"| {p} {m} | " + " | ".join(f"{sc[(p, m, v, 1)] / rs - 1:+.1%}" for v in VARIANTS) + " |")


if __name__ == "__main__":
    main()
