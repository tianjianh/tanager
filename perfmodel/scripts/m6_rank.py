"""M6's remaining pieces re-ranked on main as merged (31e65c6), rtl_m2 revision 7 (docs/perf/area_recovery.md §6.11).

The base is main's core: rtl_m2 (revision 7) with the M6 set as merged: the 32-entry RAS, TAGE-lite with two tagged
tables of 2K entries (btage_li 11) and its training queue, F2 returns and straddlers, the 32-entry FTQ and the branch
cut. Each remaining piece is added alone to that base and measured on:
  bench  make perf's ELFs (CoreMark A and B 10 iterations, Dhrystone 500 runs; rv64im and rv64gc) on tg_vsim's memory
         at native (30) and 120-cycle latency: the geometric mean of cycles, as make perf reports it
  suite  the single-thread suite (rv64gc) on the SoC's uncore at 100 MHz (DR-152: the 1 MiB L2, DRAM 184 ns), as
         §6.5 ran it
  linux  Linux-like workloads on the same uncore, outside the suite: tk_bigcode (200 KiB of code), tk_bsearch_l2 (an
         L2-resident binary search, 47 branch MPKI) and DR-141's working sets (ws_*, 0.5-4 MiB)
The DTLB retry and FENCE.I pieces have no model (bare metal: no translation, no FENCE.I in a region); their gains, and
the boot's bounds for the others, come from the RTL boot profile (scripts/rtlprof/prof_m6.sv; --boot=LOG prints them
beside the model). LUTs: core-2's and DR-149's measurements where they exist, else the plan's ledger estimates
(docs/perf/feature_ledger.md, area % of a 41K-LUT core) scaled 2-3x, as measured features ran over them, or this
study's count of the primitives. Per chip: two cores (the L2 stream prefetcher once).

  python3 scripts/m6_rank.py [--bench DIR] [--workers N] [--boot LOG]   # -> results/m6_rank_rv64.json and tables
"""
import argparse
import json
import math
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dse  # noqa: E402
import m6_steps as m6  # noqa: E402
import tgrun  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "m6_rank_rv64.json"
ISA = "rv64gc"
# main's M6 set (DR-170): TAGE-lite with two tagged tables of 2K entries
M6 = {"ras": 32, "m2_dir": 1, "dirpred": 2, "tage_log": 12, "m2_f2": 1, "m2_btage": 1, "btage_nt": 2, "btage_li": 11,
      "m2_cut": 1, "m2_f2_bubble": 2, "m2_ftq": 32, "m2_ras_f2": 1}
# name: (settings, LUTs per chip low and high, source)
PIECES = {
    "Checkpoints (4)": ({"ckpt": 4}, 2000, 3000, "ledger 1.22% of the core (500) x2-3, per core"),
    "Early retirement": ({"early_retire": 1, "lqcb": 8}, 3900, 5800,
                         "ledger 2.2% (900) and the retired loads' completion buffer of 8 (0.16%, 66) x2-3, per core"),
    "8 L1D misses": ({"l1d_mshr": 8}, 1800, 2000, "DR-156's measured +668 per st core for entries 1-4, per entry"),
    "16 L1D misses": ({"l1d_mshr": 16}, 5400, 6000, "DR-156's per-entry cost, 4 to 16"),
    "L2 stream prefetcher": ({"pf_stream": 1}, 300, 900, "ledger 0.43% of the SoC (150) x2-3, once per chip; x2 "
                                                         "if each of the L2's two banks has its own"),
    "L1D stride prefetcher": ({"pf_stride": 1}, 1200, 1800, "ledger 0.73% (300) x2-3, per core"),
    "Ownership prefetch for stores": ({"rfo_pf": 1}, 400, 600, "ledger 0.24% (100) x2-3, per core"),
    "4 I$ refills": ({"l1i_mshr": 4}, 1000, 1500, "estimate 250 per core (ledger 0.29% for 2 to 4) x2-3"),
    "I$ next-line + 2 refills": ({"pf_i_nextline": 1, "l1i_mshr": 2}, 1000, 1500,
                                 "ledger: part of 0.49% (100) and a second refill (150), x2-3"),
    "I$ FDIP + next-line + 4 refills": ({"fdip": 1, "pf_i_nextline": 1, "l1i_mshr": 4}, 2600, 3900,
                                        "ledger 0.49% (200) and 4 refills (250), x2-3, per core"),
    "Micro-BTB 128": ({"ubtb": 128}, 130, 260, "this study: 2 ways x 64 x 55 bits in RAM64M8 (+64 LUTs) x1-2"),
    "Micro-BTB 256": ({"ubtb": 256}, 750, 1120, "this study: 2 ways x 128 x 55 bits in RAM128X1D (+375) x1-1.5"),
    "DTLB retry from the LQ": ({}, 400, 1200, "this study: per LQ entry a walk wait, the replay's DTLB lookup "
                                              "(200 per core) x1-3"),
    "FENCE.I by generation": ({}, 100, 600, "this study: 2-4 generation bits per I$ line, the compare (50-100 per "
                                            "core) x1-3"),
}
MODELED = [p for p, v in PIECES.items() if v[0]]
# A faster front end moves Dhrystone's store-load race (§6.9): the model's memory-dependence predictor in the base
# and the piece alike takes the race out of the micro-BTB's make perf numbers
RACE_FREE = {"mdp": 1}
RF_PIECES = ["Micro-BTB 128", "Micro-BTB 256"]
BENCH_PROGS = [(p, m, lat) for m in ("rv64im", "rv64gc") for p in ("coremark_A", "coremark_B", "dhrystone")
               for lat in (30, 120)]
LINUX = ["tk_bigcode", "tk_bsearch_l2"] + [f"ws_{k}_{s}" for k in ("chase1", "chase8", "hash", "copy")
                                           for s in (512, 1024, 2048, 4096)]


def settings(piece, soc, extra=None):
    s = {**m6.soc(100), **M6} if soc else dict(M6)
    if piece:
        s.update(PIECES[piece][0])
    s.update(extra or {})
    return s


def suite(pieces, workers):
    cfgs = [("rtl_m2", settings(p, True)) for p in pieces]
    data = dse.collect(cfgs, ISA, workers=workers)
    return [(dse.summarize(data[dse.key(ISA, *c)[0]]), data[dse.key(ISA, *c)[0]]) for c in cfgs]


def linux(pieces, workers):
    cfgs = [("rtl_m2", settings(p, True)) for p in pieces]
    out = [{} for _ in pieces]
    for mname in ("extra", "ws"):
        data = dse.collect(cfgs, ISA, workers=workers, mname=mname)
        for i, c in enumerate(cfgs):
            for r in data[dse.key(f"{ISA}:{mname}", *c)[0]]:
                if r["workload"]["name"] in LINUX:
                    out[i][r["workload"]["name"]] = r
    return out


def ipc(r):
    return r["region"]["instr"] / max(1, r["region"]["cycles"])


def bench(pieces, bdir, workers, extra=None):
    jobs = [(i, p, m, lat) for i in range(len(pieces)) for (p, m, lat) in BENCH_PROGS]

    def one(j):
        i, p, m, lat = j
        w = {"name": p, "elf": f"{bdir}/{m}-i10-r500/{p}.elf", "stdin": "", "ff": 0}
        r = tgrun.run_one(w, "rtl_m2", {**settings(pieces[i], False, extra), "dram_lat": lat})
        if r.get("error") or not r.get("region", {}).get("cycles"):
            raise SystemExit(f"tgsim failed on {w['elf']}: {r.get('error', '')}")
        return j, r["region"]

    with ThreadPoolExecutor(max_workers=workers) as ex:
        reg = dict(ex.map(one, jobs))
    out = []
    for i in range(len(pieces)):
        c = {f"{p}|{m}|{lat}": reg[(i, p, m, lat)] for (p, m, lat) in BENCH_PROGS}
        out.append({"region": c, "geomean_cycles": tgrun.geomean([v["cycles"] for v in c.values()])})
    return out


def boot_log(path):
    """The boot profile's counters (prof_m6.sv's smt2_prof_m6 line, and prof_f2cut.sv's smt2_prof_f2 if bound)."""
    t = open(path, errors="replace").read()
    d = {}
    for tag in ("smt2_prof_m6", "smt2_prof_f2"):
        m = re.search(tag + r": (.*)", t)
        if m:
            toks = m.group(1).split()
            d.update({toks[i]: int(toks[i + 1]) for i in range(0, len(toks) - 1, 2)})
    return d


def boot_bounds(d, r_rfo):
    """Per piece, the boot's cycles it could remove: (estimate, the bound it comes from), from prof_m6.sv's and
    prof_f2cut.sv's counters. The pieces without a line here have no estimate from the boot. r_rfo: the share of
    rename's SQ-full cycles that the ownership prefetch turns into saved cycles in the model (ws_copy)."""
    def ub(sz):   # an override the larger micro-BTB holds saves the decode slots lost after it, two a cycle
        c = 0.0
        for k, evs in (("br", ("miss_br", "miss_jal", "miss_jalr")), ("ret", ("miss_ret",)),
                       ("strad", ("miss_strad",))):
            n, lost = sum(d.get(f"ev_{e}", 0) for e in evs), sum(d.get(f"lost_{e}", 0) for e in evs)
            c += max(d[f"ub{sz}_{k}"] - d[f"ub64_{k}"], 0) * lost / max(n, 1) / 2
        return c
    return {
        # each mispredict recovered at resolution: its wait to commit, and the flush's cycle after commit (the model
        # saves 1.25-1.38 cycles per cycle of wait on make perf, as this gives)
        "Checkpoints (4)": (d["misp_wait"] + d["misp"], d["misp_wait"] + d["misp"]),
        # zero-commit cycles with the head waiting for a free miss entry / any load waiting for one
        "8 L1D misses": (d["zc_wait_full"], d["ld_wait_full"]),
        "16 L1D misses": (d["zc_wait_full"], d["ld_wait_full"]),
        # rename held by a full SQ while the drain waits on its line, at the model's realization / that hold
        "Ownership prefetch for stores": (d["sq_full_stmiss"] * r_rfo, d["sq_full_stmiss"]),
        # rename held by a full ROB with a load waiting on a miss at the head: a bound only (the model's ROB seldom
        # fills, so it gives no realization)
        "Early retirement": (None, d["rob_full_ldmiss"]),
        # zero-commit cycles parked on a refill of the line after the previous refill's / also after the last block
        "I$ next-line + 2 refills": (d["park_zc_seqref"], d["park_zc_seqref"] + d["park_zc_seqdl"]),
        "I$ FDIP + next-line + 4 refills": (d["park_zc_seqref"] + d["park_zc_seqdl"],
                                            d["park_zc_seqref"] + d["park_zc_seqdl"] + d["park_zc_other"]),
        "Micro-BTB 128": (ub(128), ub(128)),
        "Micro-BTB 256": (ub(256), ub(256)),
        # a load's replay from the LQ RPL cycles after its page's DTLB fill / the retries' whole stall at the head
        "DTLB retry from the LQ": (d["rt_ld_save"], d["rt_ld_head"] + d["rt_ld_stall"]),
        # the sweep's zero-commit cycles with the ROB empty / every sweep cycle
        "FENCE.I by generation": (d["zc_fe_sweep"], d["sweep_cyc"]),
    }


def pct(x):
    return f"{x:+.1%}" if abs(x) >= 0.0005 or x == 0 else f"{x:+.2%}"


ZC = [("zc_fe_sweep", "ROB empty: the I$ sweep after FENCE.I"),
      ("zc_fe_icmiss", "ROB empty: fetch parked on an I$ miss"), ("zc_fe_itlb", "ROB empty: an ITLB walk"),
      ("zc_fe_misp", "ROB empty: the refill after a mispredict"),
      ("zc_fe_rpl", "ROB empty: the refill after a replay (ordering or DTLB)"),
      ("zc_fe_flush", "ROB empty: the refill after a trap, interrupt or serializing flush"),
      ("zc_fe_other", "ROB empty: other"), ("zc_dtlb", "Head: a DTLB miss waiting for its check or walk"),
      ("zc_ld_miss", "Head: a load waiting on a D$ miss"), ("zc_ld_stq", "Head: a load waiting for a store"),
      ("zc_ld_other", "Head: a load, other"), ("zc_st", "Head: a store"),
      ("zc_serial", "Head: a serializing op (fences, CSRs, WFI)"), ("zc_exec", "Head: another op executing"),
      ("zc_held", "Head: complete, commit held")]


def rfo_realization(base, rfo):
    """The model's cycles saved by the ownership prefetch per cycle rename was held by a full SQ without it, over
    the ws_copy sizes (the memcpy kernels, whose stores miss as the boot's page clears do)."""
    ns = [n for n in base if n.startswith("ws_copy_") and n in rfo]
    return sum((base[n]["region"]["cycles"] - rfo[n]["region"]["cycles"]) / max(base[n]["region"]["held_sq"], 1)
               for n in ns) / max(len(ns), 1)


def print_boot(boots, r_rfo):
    names = list(boots)
    print(f"\nThe ownership prefetch's realization in the model (ws_copy): {r_rfo:.2f} of the SQ-full cycles.")
    print("\n**The boot (RTL, main 31e65c6, st, the first 20M cycles): cycles without a commit, by the ROB head**\n")
    print("| Cause | " + " | ".join(names) + " |")
    print("|---|" + "---|" * len(names))
    print("| Instructions retired | " + " | ".join(f"{boots[n]['instret']:,}" for n in names) + " |")
    for k, label in ZC:
        print(f"| {label} | " + " | ".join(f"{boots[n][k] / boots[n]['cycles']:.2%}" for n in names) + " |")
    print("\n**Each piece's share of the boot's cycles: estimate (bound)**\n")
    print("| Piece | LUTs per chip | " + " | ".join(f"{n}: estimate (bound) | {n}: per 1K LUTs" for n in names) + " |")
    print("|---|---|" + "---|---|" * len(names))
    bb = {n: boot_bounds(boots[n], r_rfo) for n in names}
    for p in PIECES:
        if p not in bb[names[0]]:
            continue
        mid = (PIECES[p][1] + PIECES[p][2]) / 2000
        cells = []
        for n in names:
            est, bound = bb[n][p]
            c = boots[n]["cycles"]
            if est is None:
                cells.append(f"– (at most {bound / c:.2%}) | at most {bound / c / mid:.2%}")
            else:
                cells.append(f"{est / c:.2%} ({bound / c:.2%}) | {est / c / mid:.2%}")
        print(f"| {p} | {PIECES[p][1]:,}-{PIECES[p][2]:,} | " + " | ".join(cells) + " |")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bench", default=os.path.expanduser("~/tanager-build/rtlcal/bench"))
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--boot", action="append", default=[],
                    help="NAME=LOG: a boot profile's log (prof_m6.sv, prof_f2cut.sv) for the boot's tables; repeatable")
    a = ap.parse_args()
    boots = {b.split("=", 1)[0]: boot_log(b.split("=", 1)[1]) for b in a.boot}
    runs = [None] + MODELED
    su, lx, be = suite(runs, a.workers), linux(runs, a.workers), bench(runs, a.bench, a.workers)
    rf = bench([None] + RF_PIECES, a.bench, a.workers, RACE_FREE)
    res = {"m6": M6, "pieces": {p: {"settings": v[0], "luts_chip": [v[1], v[2]], "source": v[3]}
                                for p, v in PIECES.items()},
           "runs": {(p or "base"): {"suite": s, "linux": {n: r["region"] for n, r in lx[i].items()},
                                    "bench": be[i]} for i, (p, (s, _)) in enumerate(zip(runs, su))},
           "race_free": {"settings": RACE_FREE, "bench": {(p or "base"): b for p, b in zip([None] + RF_PIECES, rf)}}}
    r_rfo = rfo_realization(lx[0], lx[runs.index("Ownership prefetch for stores")])
    if boots:
        res["boot"] = {n: {"counters": d, "pieces": boot_bounds(d, r_rfo)} for n, d in boots.items()}
        res["rfo_realization"] = r_rfo
    OUT.write_text(json.dumps(res, indent=1) + "\n")

    b_s, b_l, b_b = su[0][0], lx[0], be[0]
    print("**Each piece alone on main's M6 set (rtl_m2 revision 7)**\n")
    print("| Piece | LUTs per chip | make perf cycles | CoreMark A / B, Dhrystone (native) | Suite IPC | Linux-like "
          "geomean | tk_bigcode | tk_bsearch_l2 | ws_* geomean | make perf per 1K LUTs | Linux-like per 1K LUTs |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for i, p in enumerate(runs[1:], 1):
        s, l, b = su[i][0], lx[i], be[i]
        lo, hi = PIECES[p][1], PIECES[p][2]
        cyc = b["geomean_cycles"] / b_b["geomean_cycles"] - 1
        nat = []
        for prog in ("coremark_A", "coremark_B", "dhrystone"):
            k = f"{prog}|rv64gc|30"
            nat.append(b_b["region"][k]["cycles"] / b["region"][k]["cycles"] - 1)
        gl = {n: ipc(l[n]) / ipc(b_l[n]) - 1 for n in LINUX if n in l and n in b_l}
        lg = math.exp(sum(math.log(1 + v) for v in gl.values()) / max(len(gl), 1)) - 1
        ws = [v for n, v in gl.items() if n.startswith("ws_")]
        wg = math.exp(sum(math.log(1 + v) for v in ws) / max(len(ws), 1)) - 1
        sp = -cyc / (1 + cyc)
        mid = (lo + hi) / 2000
        print(f"| {p} | {lo:,}-{hi:,} | {pct(cyc)} | {' / '.join(pct(x) for x in nat)} | "
              f"{pct(s['suite_ipc'] / b_s['suite_ipc'] - 1)} | {pct(lg)} | {pct(gl.get('tk_bigcode', 0))} | "
              f"{pct(gl.get('tk_bsearch_l2', 0))} | {pct(wg)} | {pct(sp / mid)} | {pct(lg / mid)} |")
    print(f"\nBase: make perf geomean {b_b['geomean_cycles']:,.0f} cycles; suite IPC {b_s['suite_ipc']:.3f}, "
          f"CoreMark A {b_s['coremark_A']:.2f}, Dhrystone {b_s['dmips']:.2f}.")
    print("\n**The micro-BTB's make perf with Dhrystone's store-load race taken out (the model's memory-dependence "
          "predictor in the base and the piece)**\n")
    print("| Piece | make perf cycles | CoreMark A / B, Dhrystone (native, rv64gc) | Ordering replays per 1K, "
          "Dhrystone rv64gc native: as built / race-free |")
    print("|---|---|---|---|")
    for i, p in enumerate(RF_PIECES, 1):
        cyc = rf[i]["geomean_cycles"] / rf[0]["geomean_cycles"] - 1
        nat = [rf[0]["region"][f"{q}|rv64gc|30"]["cycles"] / rf[i]["region"][f"{q}|rv64gc|30"]["cycles"] - 1
               for q in ("coremark_A", "coremark_B", "dhrystone")]
        k = "dhrystone|rv64gc|30"
        j = runs.index(p)
        vf = [x["region"][k]["violation_flushes"] / x["region"][k]["instr"] * 1000
              for x in (be[0], be[j], rf[0], rf[i])]
        print(f"| {p} | {pct(cyc)} | {' / '.join(pct(x) for x in nat)} | {vf[0]:.2f} -> {vf[1]:.2f} / "
              f"{vf[2]:.2f} -> {vf[3]:.2f} |")
    print("\n**The working sets by kernel (IPC gain, geomean over 0.5-4 MiB)**\n")
    print("| Piece | ws_chase1 | ws_chase8 | ws_hash | ws_copy |")
    print("|---|---|---|---|---|")
    for i, p in enumerate(runs[1:], 1):
        cells = []
        for kern in ("chase1", "chase8", "hash", "copy"):
            ns = [f"ws_{kern}_{s}" for s in (512, 1024, 2048, 4096) if f"ws_{kern}_{s}" in lx[i]]
            g = math.exp(sum(math.log(ipc(lx[i][n]) / ipc(b_l[n])) for n in ns) / max(len(ns), 1)) - 1
            cells.append(pct(g))
        print(f"| {p} | " + " | ".join(cells) + " |")
    # the checkpoints' realization: cycles saved per cycle of resolve-to-commit wait without them
    print("\n**Checkpoints: cycles saved per cycle of mispredict wait (resolve to commit) in the base**\n")
    print("| Workload | Mispredicts per 1K | Wait per mispredict | Cycles saved / wait |")
    print("|---|---|---|---|")
    ck = runs.index("Checkpoints (4)")
    rows = [(f"{prog} {m} {lat}", b_b["region"][f"{prog}|{m}|{lat}"], be[ck]["region"][f"{prog}|{m}|{lat}"])
            for (prog, m, lat) in BENCH_PROGS if lat == 30]
    rows += [(n, b_l[n]["region"], lx[ck][n]["region"]) for n in ("tk_bigcode", "tk_bsearch_l2", "ws_hash_1024")
             if n in b_l and n in lx[ck]]
    for name, r0, r1 in rows:
        mp = r0.get("mp_resolved_commit", 0)
        w = r0.get("mp_wait_cycles", 0)
        print(f"| {name} | {mp / r0['instr'] * 1000:.2f} | {w / max(mp, 1):.1f} | "
              f"{(r0['cycles'] - r1['cycles']) / max(w, 1):.2f} |")
    if boots:
        print_boot(boots, r_rfo)


if __name__ == "__main__":
    main()
