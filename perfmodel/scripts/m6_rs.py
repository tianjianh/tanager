"""Rename's stalls on core-2's TAGE-lite build, the RTL's profile against the model (docs/perf/area_recovery.md §6.8),
and the model's prediction for the store address issuing on its base alone.

RTL: fpu-2's f2cut tree (1e4a503) with the measurement-only bind scripts/rtlprof/prof_rs.sv, on make perf's ELFs
(timed regions) and the RTL suite's; --prof=DIR holds the logs (<program>_<march>.log, rtlsuite_<program>.log). Model:
rtl_m2 with the M6 set as that tree has it: revision 5 (ALU ops steered at dispatch with the current rows), revision 6
(steered at rename, as the RTL does), and revision 6 with the lever (sta_split 1: the store's address issues on its
base alone, where rename makes its IQ-STA row wait on the data register too). Every cycle decode is held (the RTL's
!de_take) is charged to what stops rename or dispatch: an issue queue's bank full (by queue), the ROB, LQ or SQ full,
a free list short, tags or LLTs, serializing uops, and the rest. When a queue's bank stops dispatch, its rows in that
bank are counted by state, and for IQ-STA by what they wait on. At most 8 runs at a time.

  python3 scripts/m6_rs.py --prof=DIR [--bench=DIR]   # -> results/m6_rs_rv64.json and tables
"""
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
# the f2cut tree's M6 set (as scripts/m6_fe.py)
M6 = {"ras": 32, "m2_dir": 1, "dirpred": 2, "tage_log": 12, "m2_f2": 1, "m2_btage": 1, "btage_nt": 2, "m2_cut": 1,
      "m2_f2_bubble": 2, "m2_ftq": 32, "m2_ras_f2": 1}
# revision 6 as §6.8 ran it (revision 7 changes sta_split and iq_steer_rn, and adds fwd_wait_cancel and drain_delay)
R6 = {"iq_steer_rn": 1, "sta_split": 0, "fwd_wait_cancel": 0, "drain_delay": 0}
VARS = {"rev 5": {**R6, "iq_steer_rn": 0}, "rev 6": R6, "rev 6, STA on its base": {**R6, "sta_split": 1}}
# for the predictions only: revision 5 with the lever, and revision 6 with rename counting the dispatch stage's group
# when it reads the ALU queues' bank flags (iq_steer_rn 2), without and with the lever
EXTRA = {"rev 5, STA on its base": {**R6, "iq_steer_rn": 0, "sta_split": 1},
         "rev 6, steering fix": {**R6, "iq_steer_rn": 2},
         "rev 6, steering fix, STA on its base": {**R6, "iq_steer_rn": 2, "sta_split": 1}}
PERF = [(p, m) for m in ("rv64gc", "rv64im") for p in ("coremark_A", "coremark_B", "dhrystone")]
SUITE = sorted(e[:-4] for e in os.listdir(f"{B}/rtlsuite") if e.endswith(".elf"))
PROGS = [(f"{m}/{p}", f"{B}/{m}-i10-r500/{p}.elf", f"{P}/{p}_{m}.log") for p, m in PERF]
PROGS += [(f"rtlsuite/{p}", f"{B}/rtlsuite/{p}.elf", f"{P}/rtlsuite_{p}.log") for p in SUITE]
# (label, the RTL bind's held causes, the model's)
CAUSES = [
    ("IQ-A0 bank full", ["h_iq_a0"], ["held_iq_a0"]),
    ("IQ-A1 bank full", ["h_iq_a1"], ["held_iq_a1"]),
    ("IQ-LD bank full", ["h_iq_ld"], ["held_iq_ld"]),
    ("IQ-STA bank full", ["h_iq_sta"], ["held_iq_sta"]),
    ("IQ-FP bank full", ["h_iq_fp"], ["held_iq_fp"]),
    ("ROB full", ["h_rob"], ["held_rob"]),
    ("LQ full", ["h_lq"], ["held_lq"]),
    ("SQ full", ["h_sq"], ["held_sq"]),
    ("Free list short", ["h_fl", "h_ffl"], ["held_reg"]),
    ("Wakeup tags or LLTs short", ["h_tag"], ["held_llt", "held_wtag"]),
    ("Serializing uop (waiting for an empty window, or the block until its flush)", ["h_serial", "h_block"], []),
    ("Divide or FP-op limit", ["h_lim"], []),
    ("Flush", ["h_flush"], []),
    ("Other", ["h_init", "h_rdy", "h_other"], ["held_other"]),
]


def parse(path):
    t = open(path).read()
    toks = re.search(r"smt2_prof_rs: (.*)", t).group(1).split()
    d = {toks[i]: int(toks[i + 1]) for i in range(0, len(toks) - 1, 2)}
    kv = dict(x.split("=", 1) for x in re.search(r"TG-RESULT (.*)", t).group(1).split() if "=" in x)
    d["region_cycles"] = int(kv["region_cycles"])
    d["region_instret"] = int(kv["region_instret"])
    return d


def one(job):
    v, name, elf = job
    r = tgrun.run_one({"name": os.path.basename(elf)[:-4], "elf": elf, "stdin": "", "ff": 0}, "rtl_m2",
                      {**M6, **VARS_ALL[v]})
    return job, r["region"]


def pct(x, c):
    return "–" if x is None else f"{x / c * 100:.1f}%"


rtl = {name: parse(log) for name, _, log in PROGS if os.path.exists(log)}
VARS_ALL = {**VARS, **EXTRA}
jobs = [(v, name, elf) for v in VARS_ALL for name, elf, _ in PROGS]
with ThreadPoolExecutor(max_workers=8) as ex:
    mod = {(v, name): r for (v, name, _), r in ex.map(one, jobs)}
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results", "m6_rs_rv64.json")
json.dump({"rtl": rtl, "model": {f"{v}|{n}": r for (v, n), r in mod.items()}, "m6": M6, "vars": VARS_ALL},
          open(OUT, "w"), indent=1)

for name, _, _ in PROGS:
    if name not in rtl:
        continue
    R, rc = rtl[name], rtl[name]["region_cycles"]
    Ms = [mod[(v, name)] for v in VARS]
    print(f"\n### {name}: RTL {rc:,} cycles; model " +
          ", ".join(f"{v} {M['cycles'] / rc - 1:+.1%}" for v, M in zip(VARS, Ms)) + "\n")
    print("| Decode held by | RTL | " + " | ".join(f"model {v}" for v in VARS) + " |")
    print("|---|---|" + "---|" * len(VARS))
    for lab, rk, mk in CAUSES:
        cells = [pct(sum(M.get(k, 0) for k in mk) if mk else None, M["cycles"]) for M in Ms]
        print(f"| {lab} | {pct(sum(R[k] for k in rk), R['cycles'])} | " + " | ".join(cells) + " |")
    held = sum(R[k] for c in CAUSES for k in c[1])
    print(f"| **All** | **{pct(held, R['cycles'])}** | " +
          " | ".join(f"**{pct(M['dec_blocked'], M['cycles'])}**" for M in Ms) + " |")
    M6r = mod[("rev 6", name)]
    nr, nm = max(1, R["h_iq_sta"]), max(1, M6r["held_iq_sta"])
    sta = " ".join(f"{s} {R['sta_' + s] / nr:.2f} / {M6r['sta_rows_' + s] / nm:.2f};"
                   for s in ("base", "data", "ready", "held"))
    print(f"\nRows of the bank that stopped dispatch, per such cycle (RTL / model revision 6). IQ-STA: {sta} "
          f"cycles with one waiting only for its data {R['sta_data_cyc'] / nr:.0%} / {M6r['sta_held_data'] / nm:.0%}.")
    if "a0_wait" in R:  # the bind's ALU-queue and IQ-LD census
        for q, lab in (("a0", "IQ-A0"), ("a1", "IQ-A1"), ("ld", "IQ-LD")):
            nr, nm = max(1, R[f"h_iq_{q}"]), max(1, M6r[f"held_iq_{q}"])
            print(f"{lab}: " + " ".join(f"{s} {R[f'{q}_{s}'] / nr:.2f} / {M6r[f'{q}_rows_{s}'] / nm:.2f};"
                                        for s in ("wait", "ready", "held")))
        na = max(1, R["h_iq_a0"] + R["h_iq_a1"])
        nma = max(1, M6r["held_iq_a0"] + M6r["held_iq_a1"])
        print(f"ALU-queue stalls whose ALU op had a row in the other ALU queue's bank for its slot: "
              f"{R['alu_other'] / na:.0%} in the RTL ({R['alu_other'] / R['cycles']:.1%} of cycles), "
              f"{M6r['held_alu_other'] / nma:.0%} in the model. A1's select blocked for a MUL, DIV or CSR result in "
              f"{R['a1_blk'] / max(1, R['h_iq_a1']):.0%} of the RTL's IQ-A1 stalls.")

print("\n### The model against the RTL, and its predictions (region cycles; speedups over the model as built)\n")
print("| Program | RTL | model rev 5 | model rev 6 | STA on its base (rev 5 / rev 6) | steering fix (rev 6) "
      "| both (rev 6) |")
print("|---|---|---|---|---|---|---|")
LOGS = {k: [] for k in ("sta5", "sta6", "fix", "both")}
e5, e6 = [], []
for name, _, _ in PROGS:
    c = {v: mod[(v, name)]["cycles"] for v in VARS_ALL}
    c5, c6 = c["rev 5"], c["rev 6"]
    sp = {"sta5": c5 / c["rev 5, STA on its base"], "sta6": c6 / c["rev 6, STA on its base"],
          "fix": c6 / c["rev 6, steering fix"], "both": c6 / c["rev 6, steering fix, STA on its base"]}
    for k, v in sp.items():
        LOGS[k].append(math.log(v))
    rc = rtl[name]["region_cycles"] if name in rtl else None
    if rc:
        e5.append(abs(c5 / rc - 1))
        e6.append(abs(c6 / rc - 1))
    print(f"| {name} | {f'{rc:,}' if rc else '–'} | {c5 / rc - 1:+.1%} | {c6 / rc - 1:+.1%} | "
          if rc else f"| {name} | – | {c5:,} | {c6:,} | ", end="")
    print(f"{sp['sta5'] - 1:+.1%} / {sp['sta6'] - 1:+.1%} | {sp['fix'] - 1:+.1%} | {sp['both'] - 1:+.1%} |")
gm = {k: math.exp(sum(v) / len(v)) - 1 for k, v in LOGS.items()}
print(f"\nGeometric means over {len(PROGS)} programs: the STA on its base {gm['sta5']:+.2%} (revision 5), "
      f"{gm['sta6']:+.2%} (revision 6); the steering fix {gm['fix']:+.2%}; both {gm['both']:+.2%}. "
      f"Mean |error| against the RTL: revision 5 {sum(e5) / max(1, len(e5)):.2%}, "
      f"revision 6 {sum(e6) / max(1, len(e6)):.2%}.")
