#!/usr/bin/env python3
"""tgsim numbers for M9's plan (docs/spec/m9-plan.md; fpu-2's questions, 10-23), on the release's smt2 core as the
model has it (rtl_m2 with main's M6 set; one thread alone on its merged window, and the 42 pairs with step 7 as decided,
with 5f). The model runs the correct path only and does not boot Linux, so the boot's numbers are not here.

--itt  an indirect-target table (itt_entries 256, path or block history) beside the 64-entry micro-BTB, and the
       micro-BTB at 128 entries: the suite and the interpreters (bench/build_m9.sh) alone at 30 cycles; the 42 pairs.
--mdp  the bound on store sets: perfect store sets (mdp 2, an oracle) against none (as built), per program, with the
       ordering flushes per 1,000 instructions, and a 16-entry load-wait table (mdp 1) between; the suite and the
       working-set kernels at 30 and 120 cycles.
--mis  misaligned loads and stores per program (each would trap without hardware misaligned access), from --itt's base.

Single-thread runs use dse's cache (results/dse), pairs m7_smt's (results/m7). Results: results/m9_plan.json."""
import argparse
import json
from pathlib import Path

import dse
import m7_smt as m
import smt
import tgrun

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "m9_plan.json"
PRESET = "rtl_m2"
BASE = {**m.CORE, "m9_counts": 1, "dram_lat": 30}   # the smt2 core with hart 1 off: one thread on its merged window
S7 = {**m.S7_AB, **m.DEC5F}   # step 7 as decided, with 5f (smt2_report §13.21): today's pairs are its cached runs
ITT = {"today: the micro-BTB, 64 entries": {},
       "the micro-BTB at 128 entries": {"ubtb": 128},
       "+ a 256-entry indirect table, path history": {"itt_entries": 256},
       "+ a 256-entry indirect table, block history": {"itt_entries": 256, "itt_hist": 1},
       "the micro-BTB at 128 and the table (path)": {"ubtb": 128, "itt_entries": 256}}
ITT_PAIRS = ("today: the micro-BTB, 64 entries", "the micro-BTB at 128 entries",
             "+ a 256-entry indirect table, path history")
MDP = {"as built: no memory dependence prediction": {},
       "a 16-entry load-wait table (mdp 1, area_recovery §6.10's size)": {"mdp": 1, "mdp_entries": 16},
       "perfect store sets (an oracle)": {"mdp": 2}}


def suite(configs, isa, mname, workers):
    """{config name: {program: region stats}}, cached as dse caches its runs."""
    out = dse.collect([(PRESET, s) for s in configs.values()], isa=isa, workers=workers, mname=mname)
    kisa = isa if mname == "manifest" else f"{isa}:{mname}"
    return {n: {r["workload"]["name"]: r["region"] for r in out[dse.key(kisa, PRESET, s)[0]]}
            for n, s in configs.items()}


def ipc(g):
    return g.get("instr", 0) / max(1, g.get("cycles", 0))


def gm(xs):
    return tgrun.geomean([x for x in xs if x > 0])


def suite_ipc(rs):
    gs = [[n for n in rs if n in ("coremark_A", "coremark_B", "dhrystone")],
          [n for n in rs if n.startswith("embench_")], [n for n in rs if n.startswith("ms_")]]
    return gm(gm(ipc(rs[n]) for n in v) for v in gs if v)


def itt(workers):
    out = {}
    rs = {n: {} for n in ITT}
    for mn in ("manifest", "m9"):
        r = suite({n: {**BASE, **c} for n, c in ITT.items()}, "rv64gc", mn, workers)
        for n in ITT:
            rs[n].update(r[n])
    ref = next(iter(ITT))
    names = list(rs[ref])
    suite_names = [p for p in names if not p.startswith("m9_")]
    print("\n**Indirect jumps, one thread alone, 30 cycles** (IPC against today's; indirect jumps other than returns "
          "per 1,000 instructions, and their target mispredicts per 1,000 with each predictor)\n")
    cfgs = list(ITT)[1:]
    print("| Program | Indirect jumps / 1K | Today: target mispredicts / 1K, IPC | " +
          " | ".join(cfgs) + " |\n|---|---|---|" + "---|" * len(cfgs))
    order = sorted(names, key=lambda p: -rs[ref][p].get("br_jalr", 0) / max(1, rs[ref][p].get("instr", 0)))
    out["per"] = {}
    for p in order:
        b = rs[ref][p]
        ki = max(1, b.get("instr", 0)) / 1000
        if b.get("br_jalr", 0) / ki < 0.05 and not p.startswith("m9_interp"):
            continue
        cells = [f"{ipc(rs[n][p]) / ipc(b) - 1:+.2%} ({rs[n][p].get('mp_target', 0) / ki:.2f})" for n in cfgs]
        print(f"| {p} | {b.get('br_jalr', 0) / ki:.2f} | {b.get('mp_target', 0) / ki:.2f}, {ipc(b):.3f} | " +
              " | ".join(cells) + " |")
        out["per"][p] = {n: {k: rs[n][p].get(k, 0) for k in ("instr", "cycles", "br_jalr", "mp_target", "f2o_itt",
                                                             "itt_used", "itt_right", "itt_none")} for n in ITT}
    sref = suite_ipc({p: rs[ref][p] for p in suite_names})
    print(f"| **Suite score** | | {sref:.3f} | " + " | ".join(
        f"{suite_ipc({p: rs[n][p] for p in suite_names}) / sref - 1:+.2%}" for n in cfgs) + " |")
    out["suite"] = {n: suite_ipc({p: rs[n][p] for p in suite_names}) for n in ITT}
    # the 42 pairs (the release: two harts, the micro-BTB and the table shared, the path history per hart)
    names = m.pair_workloads(m.FINALDIR)
    alone = {**m.ALONE, **m.REV8}
    pc = {n: ITT[n] for n in ITT_PAIRS}
    jobs = [(m.PRESET, {**m.RUNNER, **S7, **c, "dram_lat": lat}, f"{a}.s0", f"{b}.s1")
            for c in pc.values() for lat in m.LATS for _, a, b in smt.PAIRS]
    jobs += [(m.PRESET, {**alone, "dram_lat": lat}, w, None) for lat in m.LATS for w in names]
    m.run_all(jobs, workers)
    al = {lat: {w: m.ipc1(m.run7(m.PRESET, {**alone, "dram_lat": lat}, w, None)) for w in names} for lat in m.LATS}
    print(f"\n**The 42 pairs** ({m.FINALDIR.name}; step 7 as decided with 5f; WS against each program alone on its "
          "merged window, over the pairs every configuration completes; 30 / 120 / 250 cycles)\n")
    print("| Configuration | WS | Against today's | Target mispredicts / 1K | Hung |\n|---|---|---|---|---|")
    per = {n: {lat: {} for lat in m.LATS} for n in pc}
    mp = {n: [[0, 0] for _ in m.LATS] for n in pc}
    for n, c in pc.items():
        for i, lat in enumerate(m.LATS):
            for g, a, b in smt.PAIRS:
                r = m.run7(m.PRESET, {**m.RUNNER, **S7, **c, "dram_lat": lat}, f"{a}.s0", f"{b}.s1")
                ip = m.ipc2(r)
                if ip is None:
                    continue
                per[n][lat][(a, b)] = (g, ip[0] / al[lat][f"{a}.s0"] + ip[1] / al[lat][f"{b}.s1"])
                for t in r["threads"]:
                    mp[n][i][0] += t["region"].get("instr", 0)
                    mp[n][i][1] += t["region"].get("mp_target", 0)
    both = {lat: set.intersection(*(set(per[n][lat]) for n in pc)) for lat in m.LATS}
    first, out["pairs"] = None, {}
    for n in pc:
        ws = [gm(gm(w for ab, (gg, w) in per[n][lat].items() if gg == g and ab in both[lat]) for g in m.GROUPS)
              for lat in m.LATS]
        first = first or ws
        out["pairs"][n] = {"ws": ws, "hung": [42 - len(per[n][lat]) for lat in m.LATS]}
        print(f"| {n} | **{' / '.join(f'{x:.3f}' for x in ws)}** | " +
              " / ".join(f"{x / y - 1:+.2%}" for x, y in zip(ws, first)) + " | " +
              " / ".join(f"{c[1] * 1000 / max(1, c[0]):.2f}" for c in mp[n]) + " | " +
              " / ".join(str(42 - len(per[n][lat])) for lat in m.LATS) + " |")
    return out


def mdp(workers):
    out = {}
    for lat in (30, 120):
        rs = {n: {} for n in MDP}
        for mn in ("manifest", "ws"):
            r = suite({n: {**BASE, **c, "dram_lat": lat} for n, c in MDP.items()}, "rv64gc", mn, workers)
            for n in MDP:
                rs[n].update(r[n])
        cfgs = list(MDP)
        ref, orc = cfgs[0], cfgs[-1]
        names = list(rs[ref])
        print(f"\n**Ordering flushes and the bound on store sets, {lat} cycles** (one thread alone; per program: "
              "ordering flushes per 1,000 instructions as built, the cycles each costs (the oracle's saving per "
              "flush), and the IPC each predictor adds)\n")
        print("| Program | Ordering flushes / 1K | Cycles per flush | IPC as built | " + " | ".join(cfgs[1:]) +
              " |\n|---|---|---|---|" + "---|" * (len(cfgs) - 1))
        order = sorted(names, key=lambda p: -(ipc(rs[orc][p]) / ipc(rs[ref][p])))
        for p in order:
            b = rs[ref][p]
            fl = b.get("violation_flushes", 0)
            gains = [ipc(rs[n][p]) / ipc(b) - 1 for n in cfgs[1:]]
            if fl * 1000 / max(1, b.get("instr", 0)) < 0.005 and max(abs(g) for g in gains) < 0.0005:
                continue
            cpf = f"{(b.get('cycles', 0) - rs[orc][p].get('cycles', 0)) / fl:.0f}" if fl else ""
            print(f"| {p} | {fl * 1000 / max(1, b.get('instr', 0)):.3f} | {cpf} | {ipc(b):.3f} | " +
                  " | ".join(f"{g:+.2%}" for g in gains) + " |")
        sn = [p for p in names if not p.startswith("ws_")]
        sb = suite_ipc({p: rs[ref][p] for p in sn})
        print(f"| **Suite score** | | | {sb:.3f} | " +
              " | ".join(f"**{suite_ipc({p: rs[n][p] for p in sn}) / sb - 1:+.2%}**" for n in cfgs[1:]) + " |")
        tot = sum(rs[ref][p].get("violation_flushes", 0) for p in sn)
        ins = sum(rs[ref][p].get("instr", 0) for p in sn)
        row = ["All the suite's programs", f"{tot * 1000 / max(1, ins):.3f}", "", ""] + [""] * (len(cfgs) - 1)
        print("| " + " | ".join(row) + " |")
        out[lat] = {n: {p: {k: g.get(k, 0) for k in ("instr", "cycles", "violations", "violation_flushes",
                                                       "mdp_waits")} for p, g in r.items()} for n, r in rs.items()}
    return out


def mis(workers):
    rs = {}
    for mn in ("manifest", "m9", "ws"):
        rs.update(suite({"base": BASE}, "rv64gc", mn, workers)["base"])
    print("\n**Misaligned accesses, one thread alone** (committed loads and stores not aligned to their size; each "
          "would trap to the kernel's emulation without hardware misaligned access)\n")
    print("| Program | Instructions | Misaligned loads | Misaligned stores | Per 1M instructions |\n"
          "|---|---|---|---|---|")
    out, tot, ins = {}, 0, 0
    for p, g in sorted(rs.items()):
        n = g.get("ld_misaligned", 0) + g.get("st_misaligned", 0)
        tot, ins = tot + n, ins + g.get("instr", 0)
        out[p] = {k: g.get(k, 0) for k in ("instr", "ld_misaligned", "st_misaligned")}
        if n:
            print(f"| {p} | {g['instr']:,} | {g.get('ld_misaligned', 0):,} | {g.get('st_misaligned', 0):,} | "
                  f"{n * 1e6 / max(1, g['instr']):.1f} |")
    print(f"| **All {len(rs)} programs** | {ins:,} | | | **{tot * 1e6 / max(1, ins):.2f}** ({tot:,} in all) |")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--itt", action="store_true", help="the indirect-target table and the 128-entry micro-BTB")
    ap.add_argument("--mdp", action="store_true", help="the bound on store sets")
    ap.add_argument("--mis", action="store_true", help="misaligned loads and stores")
    ap.add_argument("--workers", type=int, default=14)
    a = ap.parse_args()
    res = json.loads(OUT.read_text()) if OUT.exists() else {}
    for name, fn in (("itt", itt), ("mdp", mdp), ("mis", mis)):
        if getattr(a, name):
            res[name] = fn(a.workers)
            OUT.write_text(json.dumps(res, indent=1) + "\n")


if __name__ == "__main__":
    main()
