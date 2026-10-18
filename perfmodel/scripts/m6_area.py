"""What M6's remaining pieces buy per 1K LUTs, from main as it is (docs/perf/area_recovery.md §6.5).

The base is the core on main with the RAS: `rtl_m2` (revision 3: four L1D misses in flight, speculative load wakeup,
the RTL's issue queues and store address) plus the 32-entry RAS at decode. Each remaining piece is added alone to
that base, and the memory-side pieces and checkpoints also on top of TAGE-lite 4 x 1K. Then the pieces are stacked
one step at a time, ordered by their marginal suite gain per chip LUT from those runs (TAGE's sizes as steps of
growth), each step measured on top of the ones before it, with the running LUT total.
  suite  the single-thread suite (rv64gc) on the SoC's uncore at 100 MHz (DR-152): the 1 MiB L2 (10-cycle hit), DRAM
         184 ns (18 cycles), both HP ports, as §6.3 ran it
  bench  make perf's ELFs (tests/bench, CoreMark 10 iterations, Dhrystone 500 runs; rv64im and rv64gc) on tg_vsim's
         memory at native and 120-cycle latency: the geometric mean of cycles, as make perf reports it
LUTs are per core (smt2, the chip's) and per chip (two cores; the L2 stream prefetcher once): core-2's measurements
where they exist (TAGE's size study, reports/m6-tage-size.md; DR-149's four misses; the RAS; the F2 return repair),
else the plan's ledger estimates (docs/perf/feature_ledger.md), which ran 2-3x low where measured since.

  python3 scripts/m6_area.py [--bench DIR] [--alone-only]   # -> results/m6_area_rv64.json and tables
At most 8 runs at a time (the build host is shared).
"""
import argparse
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dse  # noqa: E402
import m6_steps as m6  # noqa: E402
import tgrun  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "m6_area_rv64.json"
ISA, WORKERS = "rv64gc", 8
# rtl_m2 as this study ran it (revision 3): no D$ row clash or fast forward (revision 4 adds them, §6.6), nor
# revision 5's straddlers and micro-BTB training way (§6.7), nor revision 6's steering at rename (§6.8)
BASE = {"ras": 32, "spec_fwd": 0, "dc_row_clash": 0, "m2_strad": 0, "m2_ub_way": 0, "iq_steer_rn": 0}
TAGE = {"m2_dir": 1, "dirpred": 2, "tage_log": 12, "m2_f2": 1, "m2_btage": 1, "btage_lag": 1, "btage_tq": 4,
        "m2_cut": 1, "m2_f2_bubble": 2, "m2_ftq": 32}
# name: (settings, LUTs per core, LUTs per chip, source)
PIECES = {
    "TAGE-lite 1 x 1K": ({**TAGE, "btage_nt": 1}, 940, 1880, "measured (core-2's size study, whole-core estimate)"),
    "TAGE-lite 2 x 1K": ({**TAGE, "btage_nt": 2}, 1270, 2540, "measured (core-2's size study)"),
    "TAGE-lite 3 x 1K": ({**TAGE, "btage_nt": 3}, 1420, 2840, "measured (core-2's size study)"),
    "TAGE-lite 4 x 1K": ({**TAGE, "btage_nt": 4}, 1590, 3180, "measured (core-2's size study)"),
    "Returns repaired at F2": ({"m2_ras_f2": 1}, 30, 60, "measured (aa500ef: +26 smt2, +36 st; within noise)"),
    "8 L1D misses in flight": ({"l1d_mshr": 8}, 600, 1200, "estimate: DR-149's +543 for entries 1 to 4, per entry"),
    "16 L1D misses in flight": ({"l1d_mshr": 16}, 1700, 3400, "estimate: DR-149's per-entry cost, 4 to 16"),
    "4 I$ refills": ({"l1i_mshr": 4}, 250, 500, "estimate: ledger 0.29% for 2 to 4, from one"),
    "L1D stride prefetcher": ({"pf_stride": 1}, 300, 600, "ledger estimate (0.73% of the core)"),
    "Ownership prefetch for stores": ({"rfo_pf": 1}, 100, 200, "ledger estimate (0.24%)"),
    "L2 stream prefetcher": ({"pf_stream": 1}, 0, 150, "ledger estimate (0.43% of the SoC, once per chip)"),
    "I$ next-line prefetch": ({"pf_i_nextline": 1}, 100, 200, "ledger estimate (part of 0.49%)"),
    "Checkpoint recovery (4)": ({"ckpt": 4}, 500, 1000, "ledger estimate (1.22% of the core)"),
}
TAGE_SIZES = [p for p in PIECES if p.startswith("TAGE")]
BENCH_PROGS = [(p, m, lat) for m in ("rv64im", "rv64gc") for p in ("coremark_A", "coremark_B", "dhrystone")
               for lat in (30, 120)]


def settings(stack):
    s = {**m6.soc(100), **BASE}
    for p in stack:
        s.update(PIECES[p][0])
    return s


def bench_settings(stack):
    s = dict(BASE)
    for p in stack:
        s.update(PIECES[p][0])
    return s


def suite(stacks):
    cfgs = [("rtl_m2", settings(st)) for st in stacks]
    data = dse.collect(cfgs, ISA, workers=WORKERS)
    return [dse.summarize(data[dse.key(ISA, *c)[0]]) for c in cfgs]


def bench(stacks, bdir):
    jobs = [(i, p, m, lat) for i, st in enumerate(stacks) for (p, m, lat) in BENCH_PROGS]

    def one(j):
        i, p, m, lat = j
        w = {"name": p, "elf": f"{bdir}/{m}-i10-r500/{p}.elf", "stdin": "", "ff": 0}
        r = tgrun.run_one(w, "rtl_m2", {**bench_settings(stacks[i]), "dram_lat": lat})
        if r.get("error") or not r.get("region", {}).get("cycles"):
            raise SystemExit(f"tgsim failed on {w['elf']}: {r.get('error', '')}")
        return j, r["region"]["cycles"]

    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        cyc = dict(ex.map(one, jobs))
    out = []
    for i in range(len(stacks)):
        c = {f"{p}|{m}|{lat}": cyc[(i, p, m, lat)] for (p, m, lat) in BENCH_PROGS}
        out.append({"cycles": c, "geomean_cycles": tgrun.geomean(list(c.values()))})
    return out


def luts(stack, chip):
    return sum(PIECES[p][2 if chip else 1] for p in stack)


STEPS = [  # the cumulative curve's candidates: (name, the pieces it adds, the pieces it replaces)
    ("TAGE-lite 1 x 1K", ["TAGE-lite 1 x 1K"], []),
    ("TAGE-lite 1 to 2 tables", ["TAGE-lite 2 x 1K"], ["TAGE-lite 1 x 1K"]),
    ("TAGE-lite 2 to 3 tables", ["TAGE-lite 3 x 1K"], ["TAGE-lite 2 x 1K"]),
    ("TAGE-lite 3 to 4 tables", ["TAGE-lite 4 x 1K"], ["TAGE-lite 3 x 1K"]),
    ("Returns repaired at F2", ["Returns repaired at F2"], []),
    ("8 L1D misses in flight", ["8 L1D misses in flight"], []),
    ("8 to 16 L1D misses in flight", ["16 L1D misses in flight"], ["8 L1D misses in flight"]),
    ("4 I$ refills", ["4 I$ refills"], []),
    ("L1D stride prefetcher", ["L1D stride prefetcher"], []),
    ("Ownership prefetch for stores", ["Ownership prefetch for stores"], []),
    ("L2 stream prefetcher", ["L2 stream prefetcher"], []),
    ("I$ next-line prefetch", ["I$ next-line prefetch"], []),
    ("Checkpoint recovery (4)", ["Checkpoint recovery (4)"], []),
]
NEEDS = {"TAGE-lite 1 to 2 tables": "TAGE-lite 1 x 1K", "TAGE-lite 2 to 3 tables": "TAGE-lite 1 to 2 tables",
         "TAGE-lite 3 to 4 tables": "TAGE-lite 2 to 3 tables", "Returns repaired at F2": "TAGE-lite 1 x 1K",
         "8 to 16 L1D misses in flight": "8 L1D misses in flight"}
# the RTL's TAGE sizes on the bench (core-2, reports/m6-tage-size.md: make perf cycles against the RAS head)
RTL_TAGE = {"TAGE-lite 1 x 1K": -0.1234, "TAGE-lite 2 x 1K": -0.1596, "TAGE-lite 3 x 1K": -0.1660,
            "TAGE-lite 4 x 1K": -0.1681}


def pct(x):
    return f"{x:+.1%}"


def per_k(gain, dl):
    return gain / (max(dl, 1) / 1000)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bench", default=os.path.expanduser("~/tanager-build/rtlcal/bench"))
    ap.add_argument("--alone-only", action="store_true")
    a = ap.parse_args()
    res = {"pieces": {p: {"luts_core": v[1], "luts_chip": v[2], "source": v[3], "settings": v[0]}
                      for p, v in PIECES.items()}}
    T4 = "TAGE-lite 4 x 1K"
    others = [p for p in PIECES if p not in TAGE_SIZES and p != "Returns repaired at F2"]
    # phases 1 and 2: each piece alone on main with the RAS, and each non-TAGE piece on top of TAGE-lite 4 x 1K
    stacks = ([[]] + [[t] for t in TAGE_SIZES] + [[T4, "Returns repaired at F2"]] + [[p] for p in others] +
              [[T4, p] for p in others])
    su, be = suite(stacks), bench(stacks, a.bench)
    R = {tuple(st): (s, b) for st, s, b in zip(stacks, su, be)}
    res["runs"] = {" + ".join(st) or "base": {"suite": s, "bench": b} for st, s, b in zip(stacks, su, be)}
    OUT.write_text(json.dumps(res, indent=1) + "\n")
    b_s, b_b = R[()]

    def gains(st, ref):
        s, b = R[tuple(st)]
        rs, rb = R[tuple(ref)]
        return s["suite_ipc"] / rs["suite_ipc"] - 1, rb["geomean_cycles"] / b["geomean_cycles"] - 1, \
            b["geomean_cycles"] / rb["geomean_cycles"] - 1

    print("**Each piece alone on main with the RAS, and on top of TAGE-lite 4 x 1K** (LUTs per chip: two cores)\n")
    print("| Piece | LUTs per core / chip | LUT source | Suite IPC gain | make perf cycles | Suite gain per 1K "
          "chip LUTs | Bench speed-up per 1K chip LUTs | After TAGE 4 x 1K: suite / per 1K | make perf cycles |")
    print("|---|---|---|---|---|---|---|---|---|")
    for p in TAGE_SIZES + ["Returns repaired at F2"] + others:
        st = [T4, p] if p == "Returns repaired at F2" else [p]
        ref = [T4] if p == "Returns repaired at F2" else []
        gs, gb, cyc = gains(st, ref)
        lh = PIECES[p][2]
        after = "—"
        if p in others:
            gs2, gb2, cyc2 = gains([T4, p], [T4])
            after = f"{pct(gs2)} / {pct(per_k(gs2, lh))} | {pct(cyc2)}"
        else:
            after = "— | —"
        print(f"| {p} | {PIECES[p][1]:,} / {lh:,} | {PIECES[p][3]} | {pct(gs)} | {pct(cyc)} | {pct(per_k(gs, lh))} | "
              f"{pct(per_k(gb, lh))} | {after} |")
    print("\n**TAGE-lite's sizes on the bench, the model against the RTL** (make perf cycles against the RAS head)\n")
    print("| Tables | Model | RTL (core-2) |")
    print("|---|---|---|")
    for t in TAGE_SIZES:
        print(f"| {t} | {pct(gains([t], [])[2])} | {pct(RTL_TAGE[t])} |")
    if a.alone_only:
        return
    # phase 3: the cumulative curve, steps ordered by their marginal suite gain per chip LUT (estimated from the
    # runs above: TAGE's steps on the base, the rest after TAGE-lite 4 x 1K), each run on top of the previous
    est = {}
    prev_t = []
    for (name, add, rep), t in zip(STEPS[:4], TAGE_SIZES):
        est[name] = per_k(gains([t], prev_t)[0], PIECES[t][2] - (PIECES[prev_t[0]][2] if prev_t else 0))
        prev_t = [t]
    est["Returns repaired at F2"] = per_k(gains([T4, "Returns repaired at F2"], [T4])[0], PIECES["Returns repaired at F2"][2])
    for name, add, rep in STEPS[4:]:
        if name in est:
            continue
        if name == "8 to 16 L1D misses in flight":
            est[name] = per_k(gains([T4, add[0]], [T4, rep[0]])[0], PIECES[add[0]][2] - PIECES[rep[0]][2])
        else:
            est[name] = per_k(gains([T4, add[0]], [T4])[0], PIECES[add[0]][2])
    order, left = [], [s[0] for s in STEPS]
    while left:
        ok = [n for n in left if NEEDS.get(n) is None or NEEDS[n] in order]
        n = max(ok, key=lambda x: est[x])
        order.append(n)
        left.remove(n)
    step = {s[0]: s for s in STEPS}
    stack, stacks = [], []
    for n in order:
        _, add, rep = step[n]
        stack = [q for q in stack if q not in rep] + add
        stacks.append(list(stack))
    su, be = suite(stacks), bench(stacks, a.bench)
    curve, cur_s, cur_b, tot = [], b_s, b_b, 0
    for n, st, s, b in zip(order, stacks, su, be):
        dl = luts(st, True) - tot
        tot = luts(st, True)
        gs, gb = s["suite_ipc"] / cur_s["suite_ipc"] - 1, cur_b["geomean_cycles"] / b["geomean_cycles"] - 1
        curve.append({"step": n, "stack": st, "luts_chip_added": dl, "luts_chip_total": tot, "suite": s, "bench": b,
                      "suite_gain": gs, "bench_gain": gb, "estimate_per_1k": est[n]})
        cur_s, cur_b = s, b
    res["curve"] = curve
    OUT.write_text(json.dumps(res, indent=1) + "\n")
    print("\n**Stacked, best suite gain per LUT first** (each step measured on top of the ones before it)\n")
    print("| Step | LUTs added per chip | Running total per chip | Suite IPC | CoreMark A | Dhrystone | make perf "
          "cycles against main with the RAS | Step's suite gain per 1K LUTs | Step's bench speed-up per 1K LUTs |")
    print("|---|---|---|---|---|---|---|---|---|")
    print(f"| main with the RAS | — | 0 | {b_s['suite_ipc']:.3f} | {b_s['coremark_A']:.2f} | {b_s['dmips']:.2f} | — | — | "
          f"— |")
    for c in curve:
        cyc = c["bench"]["geomean_cycles"] / b_b["geomean_cycles"] - 1
        print(f"| + {c['step']} | {c['luts_chip_added']:,} | {c['luts_chip_total']:,} | {c['suite']['suite_ipc']:.3f} "
              f"({pct(c['suite']['suite_ipc'] / b_s['suite_ipc'] - 1)}) | {c['suite']['coremark_A']:.2f} | "
              f"{c['suite']['dmips']:.2f} | {pct(cyc)} | {pct(per_k(c['suite_gain'], c['luts_chip_added']))} | "
              f"{pct(per_k(c['bench_gain'], c['luts_chip_added']))} |")


if __name__ == "__main__":
    main()
