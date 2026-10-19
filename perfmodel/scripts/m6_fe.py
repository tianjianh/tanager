"""The front end of core-2's TAGE-lite build, the RTL's profile against the model (docs/perf/area_recovery.md §6.7).

RTL: fpu-2's f2cut tree (1e4a503: c149fce's M6 set with F2 restructured) with the measurement-only bind
scripts/rtlprof/prof_f2cut.sv, on make perf's ELFs (timed regions, +smt2_marker=<tg_marker>) and the Linux boot's first
20M cycles (tb_boot, whole run); --prof=DIR holds the logs (<program>_<march>.log, boot_rv64gc.log). Model: rtl_m2
with the M6 set as that tree has it, revisions 4 and 5 (the straddlers and the micro-BTB's training way). Per cause:
events and decode slots lost per 1K instructions, and the lost slots as cycles (two slots a cycle). The model runs the
correct path only, so it has no traps, and it does not boot Linux. At most 8 runs at a time.

  python3 scripts/m6_fe.py --prof=DIR [--bench=DIR]   # -> results/m6_fe_rv64.json and tables
"""
import json
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tgrun  # noqa: E402

ARGS = {a.split("=", 1)[0]: a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--") and "=" in a}
B = ARGS.get("--bench", os.path.expanduser("~/tanager-build/rtlcal/bench"))
P = ARGS["--prof"]
# the f2cut tree's M6 set: the RAS, two-table TAGE-lite at F2 with the cut and the FTQ, returns at F2
M6 = {"ras": 32, "m2_dir": 1, "dirpred": 2, "tage_log": 12, "m2_f2": 1, "m2_btage": 1, "btage_nt": 2, "m2_cut": 1,
      "m2_f2_bubble": 2, "m2_ftq": 32, "m2_ras_f2": 1}
# revisions 4 and 5 as §6.7 ran them (without revisions 6-7, §6.8 and §6.9)
R5 = {"iq_steer_rn": 0, "sta_split": 0, "fwd_wait_cancel": 0, "drain_delay": 0}
REVS = {"rev 4": {**R5, "m2_strad": 0, "m2_ub_way": 0}, "rev 5": R5}
PROGS = [(p, m) for m in ("rv64gc", "rv64im") for p in ("coremark_A", "coremark_B", "dhrystone")]
# (label, the RTL bind's causes, the model's event counters, the model's lost-slot counters)
CAUSES = [
    ("Mispredict: the refill after its flush", ["fl_misp"], ["mp_resolved_commit"], ["lost_flush"]),
    ("Replay at commit (on the bench, ordering): the refill after its flush", ["fl_rpl"], ["violation_flushes"],
     ["lost_replay"]),
    ("Trap, interrupt or serializing instruction: the refill after its flush", ["fl_oth"], [], []),
    ("F2: taken exit at another slot than the micro-BTB's", ["slot"], ["f2o_slot"], ["lost_slot"]),
    ("F2: JAL the micro-BTB missed", ["miss_jal"], ["f2o_miss_jal"], ["lost_miss_jal"]),
    ("F2: taken branch the micro-BTB missed", ["miss_br"], ["f2o_miss_br"], ["lost_miss_br"]),
    ("F2: taken straddler (never in the micro-BTB)", ["miss_strad"], ["f2o_miss_strad"], ["lost_miss_strad"]),
    ("F2: return the micro-BTB missed", ["miss_ret"], ["f2o_miss_ret"], ["lost_miss_ret"]),
    ("F2: return to another target than the micro-BTB's", ["rastgt"], ["f2o_ret"], ["lost_rastgt"]),
    ("F2: micro-BTB taken, TAGE-lite not taken", ["nt"], ["f2o_nt", "f2o_bogus"], ["lost_nt", "lost_bogus"]),
    ("F2: cut before a block's third branch", ["cut"], ["f2_cuts"], ["lost_cut"]),
    ("Decode redirect", ["dred"], ["predecode_redirects"], ["lost_dred"]),
    ("I$ miss", ["icmiss"], [], ["lost_icmiss"]),
    ("ITLB walk", ["itlb"], [], []),
    ("Steady fetch (no event in the last 32 cycles)", ["steady"], [], ["lost_steady"]),
]
F2 = [c[0] for c in CAUSES if c[0].startswith("F2:")]


def parse(path, region=True):
    t = open(path).read()
    toks = re.search(r"smt2_prof_f2: (.*)", t).group(1).split()
    d = {toks[i]: int(toks[i + 1]) for i in range(0, len(toks) - 1, 2)}
    if region:
        d["instret"] = int(re.search(r"region_instret=(\d+)", t).group(1))
        d["region_cycles"] = int(re.search(r"region_cycles=(\d+)", t).group(1))
    else:  # tb_boot: the whole run
        d["region_cycles"], d["instret"] = map(int, re.findall(
            r"\[tb_boot\] (\d+) cycles, (\d+) instructions retired", t)[-1])
    return d


def one(job):
    v, p, m = job
    r = tgrun.run_one({"name": p, "elf": f"{B}/{m}-i10-r500/{p}.elf", "stdin": "", "ff": 0}, "rtl_m2",
                      {**M6, **REVS[v]})
    return job, r["region"]


def rtl_row(R, rk):
    ki = R["instret"] / 1000
    return (sum(R.get("ev_" + k, 0) for k in rk) / ki, sum(R.get("lost_" + k, 0) for k in rk) / ki,
            sum(R.get("lost_" + k, 0) for k in rk) / 2 / R["cycles"] * 100)


def model_row(M, me, ml):
    ki = M["instr"] / 1000
    return (sum(M.get(k, 0) for k in me) / ki if me else None, sum(M.get(k, 0) for k in ml) / ki if ml else None,
            sum(M.get(k, 0) for k in ml) / 2 / M["cycles"] * 100 if ml else None)


def f(x, fmt):
    return "–" if x is None else format(x, fmt)


rtl = {(p, m): parse(f"{P}/{p}_{m}.log") for p, m in PROGS}
boot = parse(f"{P}/boot_rv64gc.log", region=False)
jobs = [(v, p, m) for v in REVS for p, m in PROGS]
with ThreadPoolExecutor(max_workers=8) as ex:
    mod = dict(ex.map(one, jobs))
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results", "m6_fe_rv64.json")
json.dump({"rtl": {f"{p}|{m}": v for (p, m), v in rtl.items()}, "boot": boot,
           "model": {f"{v}|{p}|{m}": r for (v, p, m), r in mod.items()}, "m6": M6, "revs": REVS},
          open(OUT, "w"), indent=1)

for p, m in PROGS:
    R, M4, M5 = rtl[(p, m)], mod[("rev 4", p, m)], mod[("rev 5", p, m)]
    rc = R["region_cycles"]
    print(f"\n### {p} {m}: RTL {rc:,} cycles; model rev 4 {M4['cycles'] / rc - 1:+.1%}, "
          f"rev 5 {M5['cycles'] / rc - 1:+.1%}\n")
    print("| Cause | per 1K instructions: RTL / rev 4 / rev 5 | slots lost per 1K: RTL / rev 4 / rev 5 | "
          "cycles: RTL / rev 4 / rev 5 |")
    print("|---|---|---|---|")
    tot = [0.0, 0.0, 0.0]
    f2t = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    for lab, rk, me, ml in sorted(CAUSES, key=lambda c: -rtl_row(R, c[1])[2]):
        r, a, b = rtl_row(R, rk), model_row(M4, me, ml), model_row(M5, me, ml)
        tot = [tot[0] + r[2], tot[1] + (a[2] or 0), tot[2] + (b[2] or 0)]
        if lab in F2:
            f2t = [f2t[0] + r[0], f2t[1] + (a[0] or 0), f2t[2] + (b[0] or 0), f2t[3] + r[2], f2t[4] + (a[2] or 0),
                   f2t[5] + (b[2] or 0)]
        print(f"| {lab} | {r[0]:.2f} / {f(a[0], '.2f')} / {f(b[0], '.2f')} | {r[1]:.1f} / {f(a[1], '.1f')} / "
              f"{f(b[1], '.1f')} | {r[2]:.2f}% / {f(a[2], '.2f')}% / {f(b[2], '.2f')}% |")
    blk = [1 - (R["take0"] + R["take1"] + R["take2"]) / R["cycles"], M4["dec_blocked"] / M4["cycles"],
           M5["dec_blocked"] / M5["cycles"]]
    print(f"\nAll F2 refetches: {f2t[0]:.1f} / {f2t[1]:.1f} / {f2t[2]:.1f} per 1K, {f2t[3]:.2f}% / {f2t[4]:.2f}% / "
          f"{f2t[5]:.2f}% of cycles. All lost slots: {tot[0]:.1f}% / {tot[1]:.1f}% / {tot[2]:.1f}% of cycles. "
          f"Decode held by rename: {blk[0]:.1%} / {blk[1]:.1%} / {blk[2]:.1%} of cycles.")

ki = boot["instret"] / 1000
print(f"\n### Linux boot, first {boot['region_cycles'] / 1e6:.0f}M cycles (RTL only): "
      f"{boot['instret']:,} instructions, IPC {boot['instret'] / boot['region_cycles']:.3f}\n")
print("| Cause | per 1K instructions | slots lost per 1K | cycles |")
print("|---|---|---|---|")
for lab, rk, _, _ in sorted(CAUSES, key=lambda c: -rtl_row(boot, c[1])[2]):
    r = rtl_row(boot, rk)
    print(f"| {lab} | {r[0]:.2f} | {r[1]:.1f} | {r[2]:.2f}% |")
if "s_f2v0" in boot:
    st = boot["s_f2v0"] + boot["s_hold"] + boot["s_del"]
    print(f"\nSteady fetch's starved cycles: F2 empty {boot['s_f2v0'] / max(1, st):.0%}, holding a block it cannot "
          f"deliver {boot['s_hold'] / max(1, st):.0%}, delivering {boot['s_del'] / max(1, st):.0%}. Blocks delivered: "
          f"{boot['w_ins'] / max(1, boot['w_del']):.2f} instructions each in steady fetch "
          f"({boot['w_del'] / max(1, boot['w_cyc']):.2f} a cycle), {boot['a_ins'] / max(1, boot['a_del']):.2f} over "
          f"the whole boot.")
if "e_f1v" in boot:
    # shares of steady fetch's starved cycles; F1 has no fetch PC only while parked on an I$ miss or ITLB walk (a run
    # of back-to-back misses is one event to the bind, so past 32 cycles it falls to steady fetch)
    st = boot["s_f2v0"] + boot["s_hold"] + boot["s_del"]
    e = {"parked on an I$ miss or ITLB walk": boot["e_f1v"] + boot["e_miss"] + boot["e_walk"],
         "FENCE.I's I$ invalidate": boot["e_ivs"], "stopped after a fault block": boot["e_stop"],
         "PMP descriptors recomputed": boot["e_pmp"], "F2 holding or delivering": boot["s_hold"] + boot["s_del"],
         "none of these": boot["e_oth"]}
    lost = boot["lost_steady"] / 2 / boot["cycles"]
    print("Steady fetch's starved cycles: " + ", ".join(
        f"{k} {v / max(1, st):.0%} (about {lost * v / max(1, st):.2%} of cycles)" for k, v in e.items()) +
        f". FENCE.I flushes {boot['n_icinv'] / ki:.3f} per 1K instructions ({boot['n_icinv']:,}); its I$ invalidate "
        f"takes {boot['c_ivs'] / boot['cycles']:.1%} of cycles.")
print(f"I$ miss cycles {boot['icmiss_cyc'] / boot['cycles']:.1%}, "
      f"ITLB walk cycles {boot['itlb_cyc'] / boot['cycles']:.1%}, "
      f"decode's own rules {boot['dec_rule'] / ki:.1f} slots per 1K, decode held by rename "
      f"{1 - (boot['take0'] + boot['take1'] + boot['take2']) / boot['cycles']:.1%} of cycles.")
