#!/usr/bin/env python3
"""The pair runner (tests/bench/pair; docs/spec/verification.md §4.8; the M7 plan's exit 2): weighted throughput of
two programs on one smt2 core's two harts against each alone, at each memory latency.

Each image comes from build_pair.sh. Alone images run one program on hart 0 at its slot's base with hart 1 parked;
pair images run slot 0's program on hart 0 and slot 1's on hart 1. A program's figure is its first region: IPC is
minstret over mcycle on its own hart, between its markers. Both first regions start together, and a program that
ends first runs again until the other's first region is done. smt2-study's method (smt2_report §2.2-2.4):
  WS(pair)  = IPC_pair(a) / IPC_alone(a, slot 0) + IPC_pair(b) / IPC_alone(b, slot 1)
  a group   = the geometric mean of its pairs' WS (mem+mem, compute+compute, mixed)
  overall   = the geometric mean of the three groups'
  run_pair.py --sim <tg_vsim (smt2)> --images DIR [--lat 30,120,250] [--only alone|pairs] [--jobs N] [--json FILE]
  run_pair.py --sim ... --only pairs --alone FILE   the pairs against alone figures from an earlier run's JSON
  run_pair.py --only pairs --alone FILE --pairs-from FILE   no runs: an earlier run's pairs scored on another basis
  run_pair.py ... --select ms_chase8,ms_gather+ms_stride   some programs (their pairs) or pairs; every program in
                                                           those runs alone too
  run_pair.py --replay <tg_replay> --images DIR   Spike against Spike: the images' own check (IPC is 1 there)
The basis (--basis, required with --sim, printed and kept in the JSON) is what the alone runs had: half, a
program on its half of a split window (hart 1 on, before step 6 merges the window when the sibling sleeps), or
merged, the whole window: from step 6 the pairs' own build with hart 1 asleep in WFI, exit 2's basis (DR-184), or
a build with hart 1 off (--alone-sim). Half-window alone runs read memory pairs high (smt2_report §13.14).
The alone runs go first. A pair's cycle limit (tg_vsim --cycles) is --cap times its two programs' whole alone runs:
a pair that reaches it is a hang, reported with the slot that never finished its first region (one hart starved
while the other runs; tg_vsim's own HANG is no commit on any hart).
Exit 2's conditions (DR-184) come last: every hang (a cycle-limit hit), failed run and pair without alone figures
is a failure. Such a pair is left out of the means, and its latency's line reads FAIL with how many pairs the means
cover. With --off-alone, the alone figures of a build with hart 1 off (an earlier --only alone run on the same
images), each program's IPC alone here is divided by its IPC there: a ratio under 1 (--loss-tol) is a loss, since
one thread alone must lose no speed against the hart-1-off core. The JSON has the basis, each run's region figures
per slot (ipc, cycles, instret and runs, the restarts; alone runs also total, the whole run's cycles), each pair's
WS, the pairs left out (and the hangs among them), the group and overall figures per latency, the ratios against
hart 1 off (no_loss) and exit 2's failures (exit2)."""
import argparse
import concurrent.futures as cf
import json
import math
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "ci"))
import host_policy  # noqa: E402  (the runners' share of a hybrid host)

GROUPS = ("mem+mem", "compute+compute", "mixed")   # make_pairs' groups
CAP_MIN = 5_000_000
BASES = {"half": "each program alone on its half of the split window (hart 1 on, before step 6's merge)",
         "merged": "each program alone on the whole window (step 6's merge, or a build with hart 1 off)"}


def run(args, timeout):
    try:
        p = subprocess.run(args, capture_output=True, text=True, errors="replace", timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return -1, "wall-clock timeout\n"


def pairs_of():
    """The programs and the pairs, with their groups, from smt2-study's make_pairs (perfmodel/scripts/smt.py), as
    build_pair.sh reads them."""
    import ast
    src = open(os.path.join(ROOT, "perfmodel", "scripts", "smt.py")).read()
    env = {}
    for node in ast.parse(src).body:
        if (isinstance(node, ast.Assign) and any(getattr(t, "id", "") in ("MEM", "COMP") for t in node.targets)) or \
           (isinstance(node, ast.FunctionDef) and node.name == "make_pairs"):
            exec(compile(ast.Module([node], []), "smt.py", "exec"), env)
    return env["MEM"] + env["COMP"], env["make_pairs"]()


def ipc(fig):
    return fig["ipc"] if fig else float("nan")


def geomean(xs):
    xs = [x for x in xs if x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float("nan")


def brief(why):
    """A left-out pair's reason, short: a hang with its limit and the slot that never finished its first region."""
    m = re.match(r"hang: no end within ([\d,]+) cycles: (?:slot \d finished its first region, slot (\d) did not|(.*))", why)
    return (f"hang at {m[1]} cycles, " + (f"slot {m[2]} unfinished" if m[2] else m[3])) if m else why[:60]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim", help="tg_vsim built for smt2")
    ap.add_argument("--replay", help="tg_replay (Spike against Spike)")
    ap.add_argument("--images", required=True, help="build_pair.sh's output directory")
    ap.add_argument("--lat", default="30,120,250")
    ap.add_argument("--only", choices=("alone", "pairs", "all"), default="all")
    ap.add_argument("--alone", default="", help="with --only pairs: alone figures from an earlier JSON (same build)")
    ap.add_argument("--basis", choices=tuple(BASES), default=None, help="what the alone runs had (required with --sim): "
                    + "; ".join(f"{k}, {v}" for k, v in BASES.items()))
    ap.add_argument("--alone-sim", default="", help="another tg_vsim for the alone runs (default --sim): a build with "
                    "hart 1 off gives the merged basis before step 6")
    ap.add_argument("--pairs-from", default="", help="with --only pairs and --alone: no runs; the pairs of an earlier "
                    "run's JSON (same images), scored against --alone's figures and basis")
    ap.add_argument("--off-alone", default="", help="the single-thread no-loss check (DR-184): the alone figures of a "
                    "build with hart 1 off, from an earlier --only alone JSON on the same images; each program's IPC "
                    "alone here is compared with them")
    ap.add_argument("--loss-tol", type=float, default=0.0, help="with --off-alone: a ratio under 1 - this is a loss "
                    "(default 0: any)")
    ap.add_argument("--cap", type=float, default=3.0, help="a pair's cycle limit: this many times its two programs' "
                    f"whole alone runs (at least {CAP_MIN:,}; tg_vsim's 50M default without alone figures)")
    ap.add_argument("--max-cycles", type=int, default=0, help="a fixed cycle limit for every pair run instead")
    ap.add_argument("--select", default="", help="only these programs and pairs (a+b), comma-separated: a program "
                    "selects its alone runs and every pair it is in")
    ap.add_argument("--no-lockstep", action="store_true", help="tg_vsim without Spike lockstep (faster)")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=7200, help="wall-clock seconds a run")
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    if a.pairs_from and (a.only != "pairs" or not a.alone):
        ap.error("--pairs-from needs --only pairs and --alone FILE")
    if a.pairs_from and not (a.sim or a.replay):
        a.sim = "(none: --pairs-from)"
    if bool(a.sim) == bool(a.replay):
        ap.error("one of --sim and --replay")
    policy = host_policy.apply_self(1)
    if policy:
        print(f"run_pair: {policy}", flush=True)
    progs, pairs = pairs_of()
    if a.select:
        sel = set(a.select.split(","))
        unknown = sel - set(progs) - {f"{x}+{y}" for _, x, y in pairs}
        if unknown:
            ap.error(f"--select: no program or pair {', '.join(sorted(unknown))}")
        pairs = [(g, x, y) for g, x, y in pairs if x in sel or y in sel or f"{x}+{y}" in sel]
        need = sel | {x for _, x, _ in pairs} | {y for _, _, y in pairs}   # the selected pairs' partners run alone too
        progs = [p for p in progs if p in need]
    lats = [int(x) for x in a.lat.split(",")] if a.sim else [0]
    alone, pair, fails, hangs, pair_why = {}, {}, [], [], {}
    if a.sim and a.only == "pairs" and not a.alone:
        ap.error("--only pairs needs --alone FILE: the alone figures of the same build (--only alone writes them)")
    if a.sim and not a.basis:
        ap.error("--basis half|merged: what the alone runs have (half before step 6 on a build with hart 1 on)")
    basis = {"name": a.basis or "spike", "label": BASES.get(a.basis, "Spike against Spike"),
             "alone_sim": a.alone_sim or a.sim or a.replay}
    if a.alone:
        if not os.path.exists(a.alone):
            ap.error(f"--alone: no {a.alone} (run --only alone first, on the same build)")
        aj = json.load(open(a.alone))
        if "basis" not in aj:
            print(f"run_pair: {a.alone} names no basis; taking --basis {a.basis}", flush=True)
        elif aj["basis"]["name"] != basis["name"]:
            ap.error(f"--alone: {a.alone} is on the {aj['basis']['name']} basis, not {basis['name']}")
        else:
            basis = aj["basis"]
        for k, v in aj["alone"].items():
            p, s, lat = k.split("@")
            alone[(p, int(s[1:]), int(lat))] = v
    off, off_sim = {}, ""
    if a.off_alone:
        if not os.path.exists(a.off_alone):
            ap.error(f"--off-alone: no {a.off_alone} (--only alone on the hart-1-off build, the same images)")
        oj = json.load(open(a.off_alone))
        off_sim = oj.get("basis", {}).get("alone_sim", "(not named)")
        for k, v in oj["alone"].items():
            p, s, lat = k.split("@")
            off[(p, int(s[1:]), int(lat))] = v
        print(f"run_pair: no-loss check against {a.off_alone} ({off_sim})", flush=True)
    print(f"run_pair: basis {basis['name']}: {basis['label']} ({basis['alone_sim']})", flush=True)
    if a.pairs_from:   # an earlier run's pairs: their figures, hangs and failures; no simulation
        pj = json.load(open(a.pairs_from))
        for e in pj["pairs"] + pj.get("excluded", []):
            k = ((e["group"], e["a"], e["b"]), e["lat"])
            if e.get("slots"):
                pair[k] = {int(sl): v for sl, v in e["slots"].items()}
            if "why" in e and not e["why"].startswith("no alone figures"):
                pair_why[k] = e["why"]
                if e["why"].startswith("hang: "):
                    pair[k] = {"hang": e["why"][len("hang: "):]}
        lats = sorted({e["lat"] for e in pj["pairs"] + pj.get("excluded", [])})
        print(f"run_pair: the pairs of {a.pairs_from}, at {', '.join(map(str, lats))} cycles", flush=True)

    def one(job):
        kind, what, slot, lat, cap = job
        img = os.path.join(a.images, "img", f"alone-{what}-s{slot}.elf" if kind == "alone" else f"pair-{what[1]}+{what[2]}.elf")
        if a.sim:
            cmd = [a.alone_sim or a.sim if kind == "alone" else a.sim, "--quiet", f"--lat={lat}", f"--timeout={a.timeout}"] + \
                  ([f"--cycles={cap}"] if cap else []) + (["--no-lockstep"] if a.no_lockstep else []) + [img]
        else:
            cmd = [a.replay, "--isa=rv64gc_zicntr", "--priv=MU", "--max-steps=400000000"] + \
                  (["--harts=2"] if kind == "pair" else []) + [img]
        t0 = time.time()
        rc, out = run(cmd, a.timeout + 120)
        res = {int(m[1]): (int(m[2]), int(m[3]), int(m[4]))
               for m in re.finditer(r"PAIR slot=(\d) cycles=(\d+) instret=(\d+) runs=(\d+)", out)}
        total = re.search(r"TG-RESULT status=\w+ code=-?\d+ cycles=(\d+)", out)
        ok = "PAIR-END" in out and ("TG-RESULT status=PASS" in out or "TG-REPLAY status=PASS" in out)
        why, hang = "", False
        missing = sorted(({slot} if kind == "alone" else {0, 1}) - set(res))
        if ok and missing:
            why = f"no PAIR line for slot {', '.join(map(str, missing))} (the output interleaved?)"
        elif not ok:
            stopped = sorted({int(s) for s in re.findall(r"PAIR-STOP slot=(\d)", out)})
            if "TIMEOUT: cycle limit" in out:
                hang = True
                why = f"no end within {cap or 50_000_000:,} cycles: " + \
                      ("its first region did not finish" if kind == "alone" else
                       f"slot {stopped[0]} finished its first region, slot {1 - stopped[0]} did not" if stopped
                       else "neither slot finished its first region")
            else:
                why = next((l.strip() for l in reversed(out.splitlines()) if l.strip()), "no output")[:200]
        return job, res, int(total[1]) if total else 0, why, hang, " ".join(cmd), time.time() - t0

    def run_all(jobs):
        with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
            return list(ex.map(one, jobs))

    def label(kind, what, slot, lat):
        return (f"{what} slot {slot}" if kind == "alone" else f"{what[1]}+{what[2]}") + f" lat {lat}"

    t0 = time.time()
    results, alone_failed = [], []
    if a.only in ("alone", "all"):
        results += run_all([("alone", p, s, lat, 0) for p in progs for s in (0, 1) for lat in lats])
        for (kind, what, slot, lat, _), res, total, why, hang, cmd, dt in results:
            if why:
                fails.append(f"  FAIL {label(kind, what, slot, lat)}: {why}\n       repro: {cmd}")
                alone_failed.append(label(kind, what, slot, lat) + (" (cycle limit)" if hang else ""))
                continue
            c, i, r = res[slot]
            alone[(what, slot, lat)] = {"ipc": i / c, "cycles": c, "instret": i, "runs": r, "total": total}
    if a.only in ("pairs", "all"):
        def cap(x, y, lat):
            if not a.sim or a.max_cycles:
                return a.max_cycles if a.sim else 0
            tx, ty = (alone.get((x, 0, lat)) or {}).get("total"), (alone.get((y, 1, lat)) or {}).get("total")
            return max(CAP_MIN, int(a.cap * (tx + ty))) if tx and ty else 0
        pres = [] if a.pairs_from else \
            run_all([("pair", (g, x, y), None, lat, cap(x, y, lat)) for g, x, y in pairs for lat in lats])
        results += pres
        for (kind, what, slot, lat, _), res, total, why, hang, cmd, dt in pres:
            if why:
                (hangs if hang else fails).append(f"  {'HANG' if hang else 'FAIL'} {label(kind, what, slot, lat)}: {why}"
                                                  f"\n       repro: {cmd}")
                if hang:
                    pair[(what, lat)] = {"hang": why}
                pair_why[(what, lat)] = ("hang: " if hang else "failed: ") + why
                continue
            pair[(what, lat)] = {s: {"ipc": i / c, "cycles": c, "instret": i, "runs": r} for s, (c, i, r) in res.items()}
    for f in fails + hangs:
        print(f)
    report = {"basis": basis, "alone": {f"{p}@s{s}@{lat}": v for (p, s, lat), v in alone.items()}, "pairs": [],
              "excluded": [], "hangs": [], "groups": {}, "overall": {}}
    if a.only in ("alone", "all"):
        print(f"{'program':24s}" + "".join(f"  IPC s0/s1 lat {lat:<3d}" for lat in lats))
        for p in progs:
            row = "".join(f"  {ipc(alone.get((p, 0, lat))):6.3f}/{ipc(alone.get((p, 1, lat))):6.3f}       " for lat in lats)
            print(f"{p:24s}{row}")
    losses, unchecked = [], []
    if off:   # DR-184: one thread alone loses no speed against the hart-1-off core
        print(f"single thread against hart 1 off: IPC alone here / on {off_sim} (a loss under {1 - a.loss_tol:.4f})")
        print(f"{'program':24s}" + "".join(f"  ratio s0/s1 lat {lat:<3d}" for lat in lats))
        ratios = {}
        for p in progs:
            row = ""
            for lat in lats:
                cell = []
                for s in (0, 1):
                    h, o = alone.get((p, s, lat)), off.get((p, s, lat))
                    if not h or not o or h["instret"] != o["instret"]:   # a region's instructions: the same images
                        unchecked.append(f"{p} slot {s} lat {lat}" + (": region instructions differ, other images?"
                                                                      if h and o else ""))
                        cell.append("   -  ")
                        continue
                    r = ratios[(p, s, lat)] = h["ipc"] / o["ipc"]
                    if r < 1 - a.loss_tol:
                        losses.append({"prog": p, "slot": s, "lat": lat, "ratio": r, "cycles": h["cycles"],
                                       "off_cycles": o["cycles"]})
                    cell.append(f"{r:6.4f}")
                row += f"  {'/'.join(cell):13s}      "
            print(f"{p:24s}{row}")
        losses.sort(key=lambda e: e["ratio"])
        worst = min(ratios, key=ratios.get) if ratios else None
        print(f"no loss alone: {len(ratios) - len(losses)} of {len(ratios)} runs at least as fast as with hart 1 off" +
              (f", the slowest {ratios[worst]:.4f} ({worst[0]} slot {worst[1]} lat {worst[2]})" if worst else "") +
              "".join(f"\n  LOSS {e['prog']} slot {e['slot']} lat {e['lat']}: {e['ratio']:.4f} ({e['cycles']:,} cycles "
                      f"against {e['off_cycles']:,})" for e in losses[:10]) +
              (f"\n  ... and {len(losses) - 10} more (the table)" if len(losses) > 10 else "") +
              "".join(f"\n  NOT COMPARED {u}" for u in unchecked))
        report["no_loss"] = {"off_alone": a.off_alone, "off_sim": off_sim, "tol": a.loss_tol,
                             "ratios": {f"{p}@s{s}@{lat}": r for (p, s, lat), r in ratios.items()},
                             "losses": losses, "unchecked": unchecked}
    if a.only in ("pairs", "all") and (pair or pair_why):
        print(f"{'pair':40s} {'group':16s}" + "".join(f"  WS lat {lat:<4d}" for lat in lats))
        groups = {}
        for g, x, y in pairs:
            ws_row = []
            for lat in lats:
                pr, ax, ay = pair.get(((g, x, y), lat)), alone.get((x, 0, lat)), alone.get((y, 1, lat))
                why = pair_why.get(((g, x, y), lat)) or ("" if ax and ay else
                      "no alone figures for " + " and ".join(f"{p} slot {s}" for p, s, f in ((x, 0, ax), (y, 1, ay)) if not f))
                if why:   # left out of the means, and named (with the pair's figures when it ran: --pairs-from)
                    report["excluded"].append({"group": g, "a": x, "b": y, "lat": lat, "why": why,
                                               **({"slots": pr} if pr and "hang" not in pr else {})})
                    if pr and "hang" in pr:
                        report["hangs"].append({"group": g, "a": x, "b": y, "lat": lat, "why": pr["hang"]})
                    ws_row.append("HANG" if pr and "hang" in pr else "FAIL" if why.startswith("failed: ") else "no alone")
                    continue
                ws = pr[0]["ipc"] / ax["ipc"] + pr[1]["ipc"] / ay["ipc"]
                ws_row.append(ws)
                groups.setdefault((g, lat), []).append(ws)
                report["pairs"].append({"group": g, "a": x, "b": y, "lat": lat, "ws": ws, "slots": pr})
            print(f"{x + '+' + y:40s} {g:16s}" + "".join(f"  {w:>10s}" if isinstance(w, str) else f"  {w:10.3f}"
                                                        for w in ws_row))
        for lat in lats:
            gm = {g: geomean(groups.get((g, lat), [])) for g in GROUPS}
            report["groups"][lat] = gm
            empty = [g for g in GROUPS if not groups.get((g, lat))]   # the overall needs all three groups
            report["overall"][lat] = float("nan") if empty else geomean(list(gm.values()))
            out = [e for e in report["excluded"] if e["lat"] == lat]
            n = sum(len(groups.get((g, lat), [])) for g in GROUPS)
            print(f"lat {lat}: " + ("FAIL, " if out else "") + ", ".join(f"{g} {v:.3f}" for g, v in gm.items()) +
                  f"; overall {report['overall'][lat]:.3f} over {n} of {len(pairs)} pairs" +
                  (f" (no pairs in {', '.join(empty)})" if empty else "") +
                  (f"; failed: {'; '.join(e['a'] + '+' + e['b'] + ' (' + brief(e['why']) + ')' for e in out)}" if out else ""))
        print(f"basis: {basis['name']}, {basis['label']}")
    # Exit 2's conditions (DR-184): no hang (a cycle-limit hit), failed run or pair without alone figures, and no loss
    # for one thread alone against hart 1 off. A failure is named, never a missing value in the means.
    def some(xs, n=6):
        return ", ".join(xs[:n]) + (f" and {len(xs) - n} more" if len(xs) > n else "")
    failures = []
    for kind, es in (("hangs (cycle limit)", report["hangs"]),
                     ("failed pair runs", [e for e in report["excluded"] if e["why"].startswith("failed: ")]),
                     ("pairs without alone figures", [e for e in report["excluded"] if e["why"].startswith("no alone")])):
        if es:
            failures.append(f"{len(es)} {kind}: " + some([f"{e['a']}+{e['b']} at {e['lat']}" for e in es]))
    if alone_failed:
        failures.append(f"{len(alone_failed)} failed alone runs: " + some(alone_failed))
    if losses:
        failures.append(f"{len(losses)} alone runs slower than with hart 1 off: " +
                        some([f"{e['prog']} slot {e['slot']} at {e['lat']} {e['ratio']:.4f}" for e in losses]))
    if unchecked:
        failures.append(f"{len(unchecked)} alone runs not compared with hart 1 off")
    report["exit2"] = {"failures": failures, "no_loss_checked": bool(off)}
    print("exit 2's conditions (DR-184): " + ("FAIL: " + "; ".join(failures) if failures else
          "no hang, cycle-limit hit or failed run" + ("; no loss alone against hart 1 off" if off else
                                                      "; the no-loss check not run (--off-alone)")))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(report, f, indent=1)
    print(f"run_pair: {len(results) - len(fails) - len(hangs)} of {len(results)} runs"
          f"{f', {len(hangs)} hangs' if hangs else ''}, {time.time() - t0:.0f} s")
    return 1 if fails or hangs or failures else 0


if __name__ == "__main__":
    sys.exit(main())
