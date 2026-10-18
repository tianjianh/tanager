"""The M6 features, from the core as built (the calibrated `rtl_m2` preset): each alone, and stacked.

Single-thread suite (rv64gc) with the SoC's uncore: the 1 MiB L2 (10-cycle hit, DATA_LAT 2, no prefetcher), DRAM
184 ns (18 cycles at 100 MHz, 21 at 115), both HP ports (a line in 2 cycles). The clock target is 100 MHz (DR-152);
115 MHz is a second column. Two stackings:
  recommended  greedy: each step adds the remaining feature with the best suite gain per LUT on top of the stack
               (16 MSHRs only after 4); where IPC per LUT runs out is where M6 should stop or re-plan
  plan order   the RAS, TAGE-lite, the block BTB and FTQ, checkpoints, speculative wakeup, MSHRs, prefetchers
LUT figures are estimates per core, not measurements: the plan's (feature_ledger.md, shares of the ~41K-LUT core;
DR-149 for 4 misses in flight) where it has one, else this study's, marked as such.

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
CLOCKS = (100, 115)


def soc(mhz):
    return {"l2_kb": 1024, "l2_ways": 8, "l2_mshr": 48, "l2_lat": 10, "dram_line_cyc": 2, "pf_stream": 0,
            "dram_lat": int(184 * mhz / 1000 + 0.5)}


# name: (LUTs per core in K, source)
FEATURES = {
    "RAS": (0.10, "this study's estimate: a 32 x 39-bit LUTRAM stack, its pointer repair, the next-PC select"),
    "TAGE-lite": (0.82, "ledger: 2.0% of the core, +6 BRAM36"),
    "Block BTB and FTQ": (0.60, "this study's estimate: BTB tags and targets in block RAM, 4-way compare and "
                                "target select, a 32-entry FTQ in LUTRAM with fetch-directed prefetch"),
    "Checkpoints": (0.50, "ledger: 0 -> 4, 1.22%"),
    "Speculative wakeup": (0.50, "ledger: 1.22%"),
    "4 misses in flight": (0.55, "DR-149: +450-600 per core"),
    "16 MSHRs": (0.65, "ledger: about 75 per L1D MSHR, 4 -> 16, plus the L1I's 4"),
    "Prefetchers": (0.95, "ledger: 0.73% + 0.24% of the core, 0.43% of the SoC, I$ next-line"),
}
PLAN_ORDER = ["RAS", "TAGE-lite", "Block BTB and FTQ", "Checkpoints", "Speculative wakeup", "4 misses in flight",
              "16 MSHRs", "Prefetchers"]


# rtl_m2 as this study ran it (its revision 1, area_recovery.md §6.3): one L1D miss, and neither the RTL's issue
# queues nor its store-address rule, which §6.4's revision 2 adds, nor speculative wakeup (revision 3)
REV1 = {"l1d_mshr": 1, "iq_slot_bank": 0, "iq_hold": 0, "sta_split": 1, "spec_wakeup": 0, "hit_pred": 0, "shadow": 0,
        "spec_int_only": 0}


def config(feats, mhz):
    """The model's settings for the core as built plus a set of M6 features."""
    s = {**REV1, **soc(mhz)}
    if "Block BTB and FTQ" in feats:  # the plan's front end, with or without TAGE-lite and the RAS
        s.update({"fe_m2": 0, "btb_block": 1, "fdip": 1, "ftq": 32})
        s.update({"dirpred": 2, "tage_log": 12} if "TAGE-lite" in feats else {"dirpred": 0, "gshare_log": 9})
        s.update({"ras": 32} if "RAS" in feats else {"ras": 0, "ret_btb": 1})
    else:  # M2's front end: the RAS and TAGE-lite repair at decode
        if "RAS" in feats:
            s["ras"] = 32
        if "TAGE-lite" in feats:
            s.update({"m2_dir": 1, "dirpred": 2, "tage_log": 12})
    if "Checkpoints" in feats:
        s["ckpt"] = 4
    if "Speculative wakeup" in feats:
        s.update({"spec_wakeup": 1, "hit_pred": 1, "shadow": 2})
    if "16 MSHRs" in feats:
        s.update({"l1d_mshr": 16, "l1i_mshr": 4})
    elif "4 misses in flight" in feats:
        s["l1d_mshr"] = 4
    if "Prefetchers" in feats:
        s.update({"pf_stride": 1, "rfo_pf": 1, "pf_stream": 1, "pf_i_nextline": 1})
    return ("rtl_m2", s)


def run(feats, mhz):
    cfg = config(feats, mhz)
    return dse.summarize(dse.collect([cfg], ISA, workers=WORKERS)[dse.key(ISA, *cfg)[0]])


def available(stack):
    return [f for f in FEATURES if f not in stack and not (f == "16 MSHRs" and "4 misses in flight" not in stack)]


def greedy(mhz):
    stack, cur, curve = [], run([], mhz), []
    while available(stack):
        cand = available(stack)
        dse.collect([config(stack + [f], mhz) for f in cand], ISA, workers=WORKERS)  # one batch per step
        best = max(cand, key=lambda f: (run(stack + [f], mhz)["suite_ipc"] / cur["suite_ipc"] - 1) / FEATURES[f][0])
        nxt = run(stack + [best], mhz)
        curve.append((best, nxt, (nxt["suite_ipc"] / cur["suite_ipc"] - 1) / FEATURES[best][0]))
        stack.append(best)
        cur = nxt
    return curve


def main():
    res = {"features": FEATURES, "alone": {}, "recommended": {}, "plan_order": {}}
    for mhz in CLOCKS:
        dse.collect([config(f, mhz) for f in [[]] + [[x] for x in FEATURES if x != "16 MSHRs"]
                     + [["4 misses in flight", "16 MSHRs"]]], ISA, workers=WORKERS)
        base = run([], mhz)
        res["alone"][mhz] = {"base": base}
        for f in FEATURES:
            feats = ["4 misses in flight", "16 MSHRs"] if f == "16 MSHRs" else [f]
            res["alone"][mhz][f] = run(feats, mhz)
    res["recommended"][100] = greedy(100)
    stack, plan = [], []
    for f in PLAN_ORDER:
        stack.append(f)
        plan.append((f, run(stack, 100)))
    res["plan_order"][100] = plan
    OUT.write_text(json.dumps(res, indent=1, default=str) + "\n")

    def g(a, b, k):
        return a[k] / b[k] - 1

    b100, b115 = res["alone"][100]["base"], res["alone"][115]["base"]
    print("\n| Feature, alone on the core as built (100 MHz) | Suite IPC | CoreMark/MHz (A) | Dhrystone DMIPS/MHz "
          "| Suite at 115 MHz | LUTs per core (K) | Suite gain per 1K LUTs | LUT source |")
    print("|---|---|---|---|---|---|---|---|")
    print(f"| The core as built (`rtl_m2`) | {b100['suite_ipc']:.3f} | {b100['coremark_A']:.2f} | {b100['dmips']:.2f} "
          f"| {b115['suite_ipc']:.3f} | — | — | — |")
    for f, (lut, src) in FEATURES.items():
        r, r115 = res["alone"][100][f], res["alone"][115][f]
        lut_all = lut + (FEATURES["4 misses in flight"][0] if f == "16 MSHRs" else 0)
        gs = g(r, b100, "suite_ipc")
        print(f"| {f}{' (from 1)' if f == '16 MSHRs' else ''} | {gs:+.1%} | {g(r, b100, 'coremark_A'):+.1%} | "
              f"{g(r, b100, 'dmips'):+.1%} | {g(r115, b115, 'suite_ipc'):+.1%} | {lut_all:.2f} | {gs / lut_all:+.0%} | {src} |")
    print("\n| Recommended order (greedy on suite gain per LUT), 100 MHz | Suite IPC | CoreMark/MHz (A) | "
          "Dhrystone DMIPS/MHz | LUTs added (K) | Running LUT total (K) | Step's suite gain per 1K LUTs |")
    print("|---|---|---|---|---|---|---|")
    print(f"| The core as built | {b100['suite_ipc']:.3f} | {b100['coremark_A']:.2f} | {b100['dmips']:.2f} | — | 0 | — |")
    total = 0.0
    for f, r, per in res["recommended"][100]:
        total += FEATURES[f][0]
        print(f"| + {f} | {r['suite_ipc']:.3f} | {r['coremark_A']:.2f} | {r['dmips']:.2f} | {FEATURES[f][0]:.2f} | "
              f"{total:.2f} | {per:+.0%} |")
    print("\n| Plan's order, 100 MHz | Suite IPC | CoreMark/MHz (A) | Dhrystone DMIPS/MHz |")
    print("|---|---|---|---|")
    for f, r in res["plan_order"][100]:
        print(f"| + {f} | {r['suite_ipc']:.3f} | {r['coremark_A']:.2f} | {r['dmips']:.2f} |")
    nax_check(res)


def nax_check(res):
    """§6.2's claim with the core as built: one core alone at 100 MHz against NaxRiscv at 135 and 150 MHz, on the
    same uncore (the L2 without a prefetcher, both ports, DRAM 184 ns)."""
    rows = {}
    for m in (1, 4):
        cfg = ("rtl_m2", {**soc(100), "l1d_mshr": m})
        rows[f"v1 as built, {m} L1D miss{'es' if m > 1 else ''}, 100 MHz"] = (100, dse.summarize(
            dse.collect([cfg], ISA, workers=WORKERS)[dse.key(ISA, *cfg)[0]]))
    for f in (135, 150):
        cfg = ("nax", soc(f))
        rows[f"NaxRiscv, {f} MHz"] = (f, dse.summarize(dse.collect([cfg], ISA, workers=WORKERS)[dse.key(ISA, *cfg)[0]]))
    nx = [rows["NaxRiscv, 135 MHz"], rows["NaxRiscv, 150 MHz"]]
    print("\n| One core alone | Suite IPC x MHz | ÷ NaxRiscv 135 / 150 | Memsuite IPC x MHz | ÷ NaxRiscv 135 / 150 |")
    print("|---|---|---|---|---|")
    for name, (f, s) in rows.items():
        ps, pm = s["suite_ipc"] * f, s["memsuite_ipc"] * f
        rs = " / ".join(f"{ps / (n['suite_ipc'] * nf):.2f}" for nf, n in nx)
        rm = " / ".join(f"{pm / (n['memsuite_ipc'] * nf):.2f}" for nf, n in nx)
        print(f"| {name} | {ps:.0f} | {rs} | {pm:.0f} | {rm} |")
    res["nax_check"] = {k: {"mhz": f, "suite_ipc": s["suite_ipc"], "memsuite_ipc": s["memsuite_ipc"]}
                        for k, (f, s) in rows.items()}
    OUT.write_text(json.dumps(res, indent=1, default=str) + "\n")


if __name__ == "__main__":
    main()
