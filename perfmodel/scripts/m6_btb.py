"""Where the block BTB and FTQ step's gain comes from (core-2's question before building it; area_recovery.md §6.3).

From the recommended stack before that step (the core as built with TAGE-lite, 4 misses in flight and the RAS, on
M2's front end), at 100 MHz's latencies with the SoC's L2:
  A    the stack as ranked: M2's front end, TAGE-lite's and the RAS's redirects at decode
  B    core-2's front end (c48b1ce): TAGE-lite overrides the micro-BTB at F2 with pre-decoded direct targets
       (m2_f2, a 1- or 2-cycle bubble); the RAS at decode; indirect jumps from the micro-BTB only
  C    the plan's front end: the block BTB (1K x 4), the FTQ with fetch-directed prefetch, the RAS at fetch;
       then C without each of its parts
Also core-2's front end on the RTL bench's CoreMark A (rv64im, tg_vsim's memory), for its RTL counters.

  python3 scripts/m6_btb.py      # -> results/m6_btb_rv64gc.json and the tables on stdout
At most 8 runs at a time (the build host is shared).
"""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dse  # noqa: E402
import m6_steps as m6  # noqa: E402
import tgrun  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "m6_btb_rv64gc.json"
ISA, WORKERS = "rv64gc", 8
STACK = ["TAGE-lite", "4 misses in flight", "RAS"]
A = m6.config(STACK, 100)[1]
C = m6.config(STACK + ["Block BTB and FTQ"], 100)[1]
VARIANTS = {
    "A: the stack as ranked (decode redirects)": A,
    "B: core-2's front end, F2 bubble 1": {**A, "m2_f2": 1, "m2_f2_bubble": 1},
    "B: core-2's front end, F2 bubble 2": {**A, "m2_f2": 1, "m2_f2_bubble": 2},
    "B with returns repaired at F2, bubble 1": {**A, "m2_f2": 1, "m2_f2_bubble": 1, "m2_ras_f2": 1},
    "B with returns repaired at F2, bubble 2": {**A, "m2_f2": 1, "m2_f2_bubble": 2, "m2_ras_f2": 1},
    "C: the plan's front end": C,
    "C without fetch-directed prefetch": {**C, "fdip": 0},
    "C with returns repaired at decode": {**C, "ras_at_decode": 1},
    "C without the main BTB (pre-decoded direct targets, 2-cycle bubble)": {**C, "btb_sets": 1, "btb_ways": 1,
                                                                            "btb_slots": 1, "predecode_bubble": 2},
}
KINDS = ("mp_dir", "mp_cold", "mp_ret", "mp_target", "f2_overrides", "predecode_redirects", "taken_bubbles")


def per_k(reg, k):
    return reg.get(k, 0) * 1000.0 / max(1, reg["instr"])  # runs cached before a counter existed have none


def main():
    cfgs = {n: ("rtl_m2", s) for n, s in VARIANTS.items()}
    data = dse.collect(list(cfgs.values()), ISA, workers=WORKERS)
    res = {}
    for n, cfg in cfgs.items():
        rs = data[dse.key(ISA, *cfg)[0]]
        s = dse.summarize(rs)
        cm = next(r for r in rs if r["workload"]["name"] == "coremark_A")["region"]
        res[n] = {"suite_ipc": s["suite_ipc"], "coremark_A": s["coremark_A"], "dmips": s["dmips"],
                  "coremark_A_per_1k": {k: per_k(cm, k) for k in KINDS}, "sets": cfg[1]}
    base = res["A: the stack as ranked (decode redirects)"]
    print("\n| Front end (100 MHz, with TAGE-lite, the RAS and 4 misses) | Suite IPC | CoreMark/MHz (A) | DMIPS/MHz "
          "| CoreMark A per 1K instructions: direction / no-target / return / indirect mispredicts | F2 / decode redirects "
          "| Bubble cycles |")
    print("|---|---|---|---|---|---|---|")
    for n, r in res.items():
        k = r["coremark_A_per_1k"]
        print(f"| {n} | {r['suite_ipc']:.3f} ({r['suite_ipc'] / base['suite_ipc'] - 1:+.1%}) | {r['coremark_A']:.2f} | "
              f"{r['dmips']:.2f} | {k['mp_dir']:.1f} / {k['mp_cold']:.1f} / {k['mp_ret']:.1f} / {k['mp_target']:.1f} | "
              f"{k['f2_overrides']:.1f} / {k['predecode_redirects']:.1f} | {k['taken_bubbles']:.0f} |")
    # core-2's front end on the RTL bench's CoreMark A, for its RTL counters (c48b1ce: per 717K instructions, 3.5K
    # mispredict flushes, 15.5K F2 overrides, 1.4K decode redirects)
    elf = os.path.expanduser("~/tanager-build/rtlcal/bench/rv64im-i2-r500/coremark_A.elf")
    if os.path.exists(elf):
        bench = {}
        for bub in (1, 2):
            r = tgrun.run_one({"name": "coremark_A", "elf": elf, "stdin": "", "ff": 0}, "rtl_m2",
                              {**m6.REV1, "ras": 32, "m2_dir": 1, "dirpred": 2, "tage_log": 12, "m2_f2": 1,
                               "m2_f2_bubble": bub})["region"]
            bench[bub] = {"cycles": r["cycles"], "instr": r["instr"], "cm_mhz": 2e6 / r["cycles"],
                          "flushes_per_1k": per_k(r, "mp_resolved_commit"), "f2_per_1k": per_k(r, "f2_overrides"),
                          "decode_per_1k": per_k(r, "predecode_redirects")}
            print(f"\nBench CoreMark A rv64im, core-2's front end, F2 bubble {bub}: {bench[bub]['cm_mhz']:.2f} CM/MHz; "
                  f"per 1K instructions {bench[bub]['flushes_per_1k']:.1f} mispredicts, {bench[bub]['f2_per_1k']:.1f} F2 "
                  f"overrides, {bench[bub]['decode_per_1k']:.1f} decode redirects (RTL c48b1ce: 4.9, 21.6, 2.0)")
        res["bench_coremark_A"] = bench
    OUT.write_text(json.dumps(res, indent=1) + "\n")


if __name__ == "__main__":
    main()
