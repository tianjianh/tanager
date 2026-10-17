"""The M6 features, from the core as built (the calibrated `rtl_m2` preset), one at a time and in the plan's order.

Single-thread suite (rv64gc) at 115 MHz's latencies with the SoC's uncore: the 1 MiB L2 (10-cycle hit, DATA_LAT 2,
no prefetcher), DRAM 184 ns = 21 cycles, both HP ports (a line in 2 cycles). Each feature is added alone to the
base, and cumulatively in the plan's order (the RAS, TAGE-lite, the block BTB and FTQ, checkpoint recovery,
speculative wakeup, the MSHRs, the prefetchers). LUT figures are the plan's estimates (feature_ledger.md, shares of
the ~41K-LUT core; DR-149 for 4 MSHRs), not measurements.

  python3 scripts/m6_steps.py      # -> results/m6_steps_rv64gc.json and the tables on stdout
At most 8 runs at a time (the build host is shared).
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dse  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "m6_steps_rv64gc.json"
ISA, WORKERS = "rv64gc", 8
SOC115 = {"l2_kb": 1024, "l2_ways": 8, "l2_mshr": 48, "l2_lat": 10, "dram_lat": 21, "dram_line_cyc": 2}
FULL_FE = {"fe_m2": 0, "m2_dir": 0, "dirpred": 2, "tage_log": 12, "ras": 32, "btb_block": 1, "fdip": 1, "ftq": 32}
# (name, settings added, the plan's LUT estimate in K per core, its source)
STEPS = [
    ("RAS (32, decode repair)", {"ras": 32}, None, "not estimated (ledger: block BTB, RAS and FTQ not swept)"),
    ("TAGE-lite (4 x 4K)", {"m2_dir": 1, "dirpred": 2, "tage_log": 12}, 0.82, "ledger: 2.0% of the core, +6 BRAM36"),
    ("Block BTB and FTQ (1K x 4, 32; FDIP)", {"fe_m2": 0, "dirpred": 0, "gshare_log": 9, "ras": 0, "btb_block": 1,
                                              "fdip": 1, "ftq": 32}, None, "not estimated (ledger: not swept)"),
    ("Checkpoint recovery (4)", {"ckpt": 4}, 0.50, "ledger: 0 -> 4, 1.22%"),
    ("Speculative wakeup (hit predictor, shadow 2)", {"spec_wakeup": 1, "hit_pred": 1, "shadow": 2}, 0.50,
     "ledger: 1.22%"),
    ("4 L1D misses in flight (DR-149)", {"l1d_mshr": 4}, 0.55, "DR-149: +450-600 per core"),
    ("16 L1D / 4 L1I MSHRs (the plan's M6)", {"l1d_mshr": 16, "l1i_mshr": 4}, 1.20,
     "ledger: about 75 per L1D MSHR, plus the L1I's"),
    ("Prefetchers (L1D stride, ownership, L2 stream, I$ next-line)", {"pf_stride": 1, "rfo_pf": 1, "pf_stream": 1,
                                                                      "pf_i_nextline": 1}, 0.95,
     "ledger: 0.73% + 0.24% of the core, 0.43% of the SoC, I$ next-line"),
]
ORDER = ["RAS (32, decode repair)", "TAGE-lite (4 x 4K)", "Block BTB and FTQ (1K x 4, 32; FDIP)",
         "Checkpoint recovery (4)", "Speculative wakeup (hit predictor, shadow 2)",
         "16 L1D / 4 L1I MSHRs (the plan's M6)",
         "Prefetchers (L1D stride, ownership, L2 stream, I$ next-line)"]


def run(sets):
    cfg = ("rtl_m2", {**SOC115, **sets})
    return dse.summarize(dse.collect([cfg], ISA, workers=WORKERS)[dse.key(ISA, *cfg)[0]])


def main():
    base = run({})
    res = {"base": base, "alone": {}, "cumulative": []}
    configs = [{}] + [s for _, s, _, _ in STEPS]
    dse.collect([("rtl_m2", {**SOC115, **s}) for s in configs], ISA, workers=WORKERS)  # one batch
    for name, sets, _, _ in STEPS:
        res["alone"][name] = run(sets)
    cum = {}
    for name in ORDER:
        sets = dict(STEPS[[s[0] for s in STEPS].index(name)][1])
        if name.startswith("Block BTB"):
            sets = dict(FULL_FE)  # the plan's whole front end: block BTB, FTQ, with TAGE-lite and the RAS
        cum = {**cum, **sets}
        res["cumulative"].append((name, dict(cum), run(cum)))
    OUT.write_text(json.dumps(res, indent=1, default=str) + "\n")

    def g(a, b, k):
        return a[k] / b[k] - 1

    print("\n| Feature (alone, on the core as built) | Suite IPC | CoreMark/MHz A | Dhrystone DMIPS/MHz | Plan's LUTs (K) "
          "| Suite gain per 1K LUTs | LUT source |")
    print("|---|---|---|---|---|---|---|")
    print(f"| Core as built (`rtl_m2`) | {base['suite_ipc']:.3f} | {base['coremark_A']:.2f} | {base['dmips']:.2f} | — | — | — |")
    for name, _, lut, src in STEPS:
        r = res["alone"][name]
        gs = g(r, base, "suite_ipc")
        per = f"{gs / lut:+.1%}" if lut else "—"
        print(f"| {name} | {gs:+.1%} | {g(r, base, 'coremark_A'):+.1%} | {g(r, base, 'dmips'):+.1%} | "
              f"{lut if lut else '—'} | {per} | {src} |")
    print("\n| Cumulative, in the plan's order | Suite IPC | CoreMark/MHz A | Dhrystone DMIPS/MHz | Step's suite gain |")
    print("|---|---|---|---|---|")
    prev = base
    print(f"| Core as built | {base['suite_ipc']:.3f} | {base['coremark_A']:.2f} | {base['dmips']:.2f} | — |")
    for name, _, r in res["cumulative"]:
        print(f"| + {name} | {r['suite_ipc']:.3f} | {r['coremark_A']:.2f} | {r['dmips']:.2f} | {g(r, prev, 'suite_ipc'):+.1%} |")
        prev = r


if __name__ == "__main__":
    main()
