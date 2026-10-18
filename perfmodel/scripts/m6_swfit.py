"""Speculative wakeup's cancels, the model against the RTL (docs/perf/area_recovery.md §6.6): rtl_m2 with the RAS,
base and TAGE-lite 4 x 1K, with the D$ row clash (dc_row_clash) and fast forwards (spec_fwd) added in turn, against
fpu-2's RTL cancel profile (its ras and tage builds, --prof DIR): make perf's regions for both ELF lengths, and the
steady state (the 20-iteration / 1000-run whole run minus the 10 / 500 one; valid for CoreMark only, as Dhrystone's
code layout differs between the lengths). At most 8 runs at a time.

  python3 scripts/m6_swfit.py [--prof=DIR] [--bench=DIR]   # -> results/m6_swfit_rv64.json and tables
"""
import csv
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tgrun  # noqa: E402

ARGS = {a.split("=", 1)[0]: a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--") and "=" in a}
B = ARGS.get("--bench", os.path.expanduser("~/tanager-build/rtlcal/bench"))
P = ARGS.get("--prof", os.path.expanduser("~/tanager-build/track-fpu-395911/swprof"))
TAGE = {"m2_dir": 1, "dirpred": 2, "tage_log": 12, "m2_f2": 1, "m2_btage": 1, "btage_nt": 4, "m2_cut": 1,
        "m2_f2_bubble": 2, "m2_ftq": 32}
V = {"rev 3": {"spec_fwd": 0, "dc_row_clash": 0}, "+ spec_fwd": {"spec_fwd": 1, "dc_row_clash": 0},
     "+ row clash": {"spec_fwd": 0, "dc_row_clash": 1},
     "+ both": {"spec_fwd": 1, "dc_row_clash": 1}}
# revision 4 as this fit ran it: without revision 5's straddlers and micro-BTB training way (§6.7)
REV4 = {"m2_strad": 0, "m2_ub_way": 0}
BUILDS = {"ras": {"ras": 32, **REV4}, "tage": {"ras": 32, **TAGE, **REV4}}
PROGS = [(p, m) for m in ("rv64im", "rv64gc") for p in ("coremark_A", "coremark_B", "dhrystone")]
SETS = ("i10-r500", "i20-r1000")
K = ("cycles", "instr", "ld_fwd", "dc_clashes", "shadow_cancels", "cancelled_issues", "loads")
jobs = [(b, v, p, m, s, w) for b in BUILDS for v in V for (p, m) in PROGS for s in SETS for w in (0, 1)]


def one(j):
    b, v, p, m, s, w = j
    el = {"name": p, "elf": f"{B}/{m}-{s}/{p}.elf", "stdin": "", "ff": 0}
    r = tgrun.run_one(el, "rtl_m2", {**BUILDS[b], **V[v], "whole_run": w})
    g = r.get("region", {})
    return j, {k: g.get(k, 0) for k in K}


with ThreadPoolExecutor(max_workers=8) as ex:
    res = dict(ex.map(one, jobs))
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results", "m6_swfit_rv64.json")
json.dump({"|".join(map(str, k)): v for k, v in res.items()}, open(OUT, "w"), indent=1)

# the RTL: fpu-2's runs (region cycles of i10-r500, and the steady-state counts)
rtl_i10, rtl_i20, rtl_st = {}, {}, {}
for row in csv.DictReader(open(f"{P}/swprof.tsv"), delimiter="\t"):
    if row["lat"] != "native":
        continue
    k = (row["build"], row["program"], row["march"])
    if row["elf_set"].endswith("i10-r500"):
        rtl_i10[k] = int(row["region_cycles"])
    elif row["elf_set"].endswith("i20-r1000"):
        rtl_i20[k] = int(row["region_cycles"])
for row in csv.DictReader(open(f"{P}/swprof_steady.tsv"), delimiter="\t"):
    if row["lat"] == "native":
        rtl_st[(row["build"], row["program"], row["march"])] = row


def score(p, cyc, runs_scale=1):
    return 10e6 / cyc if p.startswith("coremark") else 500e6 / (cyc * 1757)


print("| Build | Program | RTL region | " + " | ".join(V) + " |")
print("|---|---|---|" + "---|" * len(V))
for b in BUILDS:
    for p, m in PROGS:
        rc = rtl_i10.get((b, p, m))
        cells = []
        for v in V:
            mc = res[(b, v, p, m, "i10-r500", 0)]["cycles"]
            cells.append(f"{mc / rc - 1:+.1%}" if rc else f"{mc:,}")
        print(f"| {b} | {p} {m} | {rc:,} | " + " | ".join(cells) + " |" if rc else f"| {b} | {p} {m} | — | " +
              " | ".join(cells) + " |")
print("\nThe 20-iteration / 1000-run binaries' regions, model against RTL (Dhrystone's code layout differs between "
      "the two lengths, so its steady state below mixes two binaries)")
print("| Build | Program | RTL region | " + " | ".join(V) + " |")
print("|---|---|---|" + "---|" * len(V))
for b in BUILDS:
    for p, m in PROGS:
        rc = rtl_i20.get((b, p, m))
        if rc:
            print(f"| {b} | {p} {m} | {rc:,} | " + " | ".join(
                f"{res[(b, v, p, m, 'i20-r1000', 0)]['cycles'] / rc - 1:+.1%}" for v in V) + " |")
print("\nSteady state per 1K instructions: RTL clash / fwd completions / cancels (not m1) against the model")
for b in BUILDS:
    for p, m in PROGS:
        r = rtl_st.get((b, p, m))
        if not r:
            continue
        ki = int(r["instret"]) / 1000
        rcl, rfw = int(r["clash"]) / ki, int(r["completed_fwd"]) / ki
        rca = (int(r["cancels"]) - int(r["m1_exc"]) - int(r["m1_mmio"]) - int(r["m1_tlb"])) / ki
        rcy = int(r["region_cycles"])
        cells = []
        for v in V:
            a = res[(b, v, p, m, "i20-r1000", 1)]
            z = res[(b, v, p, m, "i10-r500", 1)]
            mi = (a["instr"] - z["instr"]) / 1000
            mcy = a["cycles"] - z["cycles"]
            cells.append(f"cyc {mcy / rcy - 1:+.1%} clash {(a['dc_clashes'] - z['dc_clashes']) / mi:.2f} fwd "
                         f"{(a['ld_fwd'] - z['ld_fwd']) / mi:.2f} canc {(a['shadow_cancels'] - z['shadow_cancels']) / mi:.2f}")
        print(f"{b} {p} {m}: RTL clash {rcl:.2f} fwd {rfw:.2f} canc {rca:.2f} cyc {rcy:,} || " + " || ".join(
            f"{v}: {c}" for v, c in zip(V, cells)))
