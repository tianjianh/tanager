"""DR-169's levers measured in RTL against the model (docs/perf/area_recovery.md §6.9): the store address on its base
alone (STA_BASE) and rename's steering counting the dispatch stage's group (STEER_LA), on fpu-2's levers tree (a857a07).

RTL: fpu-2's region cycles for each lever alone and both (--meas=FILE, its stl_17.tsv), and the both-levers tree's
load and rename profile (--prof=DIR: <program>_<march>.log and rtlsuite_<program>.log from
scripts/rtlprof/prof_sta.sv). Model: rtl_m2 with the M6 set, each lever off and on, under revision 6 (as §6.8
predicted them) and revision 7 (the levers, the store-wait cancel and the drain's cycle; with both levers it is
revision 7 itself). At most 8 runs at a time.

  python3 scripts/m6_lev.py --meas=FILE --prof=DIR [--bench=DIR]   # -> results/m6_lev_rv64.json and tables
"""
import csv
import json
import math
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tgrun  # noqa: E402

ARGS = {a.split("=", 1)[0]: a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--") and "=" in a}
B = ARGS.get("--bench", os.path.expanduser("~/tanager-build/rtlcal/bench"))
P = ARGS["--prof"]
M6 = {"ras": 32, "m2_dir": 1, "dirpred": 2, "tage_log": 12, "m2_f2": 1, "m2_btage": 1, "btage_nt": 2, "m2_cut": 1,
      "m2_f2_bubble": 2, "m2_ftq": 32, "m2_ras_f2": 1}
LEVERS = {"base": {"iq_steer_rn": 1, "sta_split": 0}, "sta": {"iq_steer_rn": 1, "sta_split": 1},
          "steer": {"iq_steer_rn": 2, "sta_split": 0}, "both": {"iq_steer_rn": 2, "sta_split": 1}}
REVS = {"rev 6": {"fwd_wait_cancel": 0, "drain_delay": 0}, "rev 7": {"fwd_wait_cancel": 1, "drain_delay": 1}}
SETS = {f"{r}|{lv}": {**rs, **ls} for r, rs in REVS.items() for lv, ls in LEVERS.items()}
NAMES = [f"rv64{m}-i10-r500/{p}" for m in ("gc", "im") for p in ("coremark_A", "coremark_B", "dhrystone")]
NAMES += sorted(f"rtlsuite/{e[:-4]}" for e in os.listdir(f"{B}/rtlsuite") if e.endswith(".elf"))


def log_of(name):
    d, p = name.split("/")
    return f"{P}/rtlsuite_{p}.log" if d == "rtlsuite" else f"{P}/{p}_{d.split('-')[0]}.log"


def prof(path):
    t = open(path).read()
    d = {}
    for tag in ("smt2_prof_rs", "smt2_prof_ld"):
        toks = re.search(tag + r": (.*)", t).group(1).split()
        d.update({toks[i]: int(toks[i + 1]) for i in range(0, len(toks) - 1, 2)})
    kv = dict(x.split("=", 1) for x in re.search(r"TG-RESULT (.*)", t).group(1).split() if "=" in x)
    d["region_cycles"], d["instret"] = int(kv["region_cycles"]), int(kv["region_instret"])
    return d


def one(job):
    s, name = job
    r = tgrun.run_one({"name": name.split("/")[1], "elf": f"{B}/{name}.elf", "stdin": "", "ff": 0}, "rtl_m2",
                      {**M6, **SETS[s]})
    return job, r["region"]


meas = {row["program"]: {k: int(row[f"{k}_region"]) for k in LEVERS} for row in csv.DictReader(open(ARGS["--meas"]),
                                                                                               delimiter="\t")}
rtl = {n: prof(log_of(n)) for n in NAMES if os.path.exists(log_of(n))}
with ThreadPoolExecutor(max_workers=8) as ex:
    mod = {(s, n): r for (s, n), r in ex.map(one, [(s, n) for s in SETS for n in NAMES])}
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results", "m6_lev_rv64.json")
json.dump({"meas": meas, "rtl": rtl, "model": {f"{s}|{n}": r for (s, n), r in mod.items()}, "m6": M6, "sets": SETS},
          open(OUT, "w"), indent=1)

print("### The levers' speedups: RTL measured / revision 6 / revision 7\n")
print("| Program | STA_BASE alone | STEER_LA alone | both |")
print("|---|---|---|---|")
g = {(w, lv): [] for w in ("rtl", "rev 6", "rev 7") for lv in ("sta", "steer", "both")}
for n in NAMES:
    cells = []
    for lv in ("sta", "steer", "both"):
        sp = {"rtl": meas[n]["base"] / meas[n][lv]}
        for r in REVS:
            sp[r] = mod[(f"{r}|base", n)]["cycles"] / mod[(f"{r}|{lv}", n)]["cycles"]
        for w, v in sp.items():
            g[(w, lv)].append(math.log(v))
        cells.append(" / ".join(f"{sp[w] - 1:+.1%}" for w in ("rtl", "rev 6", "rev 7")))
    print(f"| {n} | " + " | ".join(cells) + " |")
print("| Geometric mean | " + " | ".join(" / ".join(f"{math.exp(sum(g[(w, lv)]) / len(g[(w, lv)])) - 1:+.2%}"
                                                     for w in ("rtl", "rev 6", "rev 7"))
                                          for lv in ("sta", "steer", "both")) + " |")

print("\n### Revision 7 against the levers tree (both levers): region cycles and the loads, per 1K instructions\n")
print("| Program | RTL cycles | model rev 6 / rev 7 | waits for a store's data: RTL / rev 7 | row-clash retries "
      "| cancels | replays at commit | decode held by rename |")
print("|---|---|---|---|---|---|---|---|")
err = {r: [] for r in REVS}
for n in NAMES:
    rc = meas[n]["both"]
    errs = {r: mod[(f"{r}|both", n)]["cycles"] / rc - 1 for r in REVS}
    for r in REVS:
        err[r].append(abs(errs[r]))
    M = mod[("rev 7|both", n)]
    mk = M["instr"] / 1000
    if n in rtl:
        R = rtl[n]
        ki = R["instret"] / 1000
        canc = sum(R[k] for k in R if k.startswith("cancel_"))
        held = sum(R[k] for k in R if k.startswith("h_")) / R["cycles"]
        loads = (f"{R['m2_stq'] / ki:.1f} / {M['ld_fwd_wait'] / mk:.1f} | {R['m2_retry'] / ki:.1f} / "
                 f"{M['dc_clashes'] / mk:.1f} | {canc / ki:.1f} / {M['shadow_cancels'] / mk:.1f} | "
                 f"{R['fl_rpl'] / ki:.2f} / {M['violation_flushes'] / mk:.2f} | {held:.1%} / "
                 f"{M['dec_blocked'] / M['cycles']:.1%}")
    else:
        loads = "– | – | – | – | –"
    print(f"| {n} | {rc:,} | {errs['rev 6']:+.1%} / {errs['rev 7']:+.1%} | {loads} |")
print("\nMean |error| against the both-levers RTL: " +
      ", ".join(f"{r} {sum(v) / len(v):.2%}" for r, v in err.items()) + ".")
