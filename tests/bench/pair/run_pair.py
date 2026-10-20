#!/usr/bin/env python3
"""The pair runner (tests/bench/pair; docs/spec/verification.md §4.8; the M7 plan's exit 2): weighted throughput of
two programs on one smt2 core's two harts against each alone, at each memory latency.

Each image comes from build_pair.sh. Alone images run one program on hart 0 at its slot's base with hart 1 parked;
pair images run slot 0's program on hart 0 and slot 1's on hart 1. A program's figure is its first region: IPC is
minstret over mcycle on its own hart, between its markers. Both first regions start together, and a program that
ends first runs again from the top until the other's first region is done. smt2-study's method (smt2_report §2.2-2.4):
  WS(pair)  = IPC_pair(a) / IPC_alone(a, slot 0) + IPC_pair(b) / IPC_alone(b, slot 1)
  a group   = the geometric mean of its pairs' WS (mem+mem, compute+compute, mixed)
  overall   = the geometric mean of the three groups'
  run_pair.py --sim <tg_vsim (smt2)> --images DIR [--lat 30,120,250] [--only alone|pairs] [--jobs N] [--json FILE]
  run_pair.py --replay <tg_replay> --images DIR   Spike against Spike: the images' own check (IPC is 1 there)
The JSON has each run's region figures per slot (ipc, cycles, instret and runs, the restarts), each pair's WS, and
the group and overall figures per latency."""
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


def run(args, timeout):
    try:
        p = subprocess.run(args, capture_output=True, text=True, errors="replace", timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return -1, "wall-clock timeout\n"


def pairs_of():
    """The pairs, with their groups, from smt2-study's make_pairs (perfmodel/scripts/smt.py), as build_pair.sh."""
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim", help="tg_vsim built for smt2")
    ap.add_argument("--replay", help="tg_replay (Spike against Spike)")
    ap.add_argument("--images", required=True, help="build_pair.sh's output directory")
    ap.add_argument("--lat", default="30,120,250")
    ap.add_argument("--only", choices=("alone", "pairs", "all"), default="all")
    ap.add_argument("--no-lockstep", action="store_true", help="tg_vsim without Spike lockstep (faster)")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=7200)
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    if bool(a.sim) == bool(a.replay):
        ap.error("one of --sim and --replay")
    policy = host_policy.apply_self(1)
    if policy:
        print(f"run_pair: {policy}", flush=True)
    progs, pairs = pairs_of()
    lats = [int(x) for x in a.lat.split(",")] if a.sim else [0]
    jobs = []
    if a.only in ("alone", "all"):
        jobs += [("alone", p, s, lat) for p in progs for s in (0, 1) for lat in lats]
    if a.only in ("pairs", "all"):
        jobs += [("pair", (g, x, y), None, lat) for g, x, y in pairs for lat in lats]

    def one(job):
        kind, what, slot, lat = job
        img = os.path.join(a.images, "img", f"alone-{what}-s{slot}.elf" if kind == "alone" else f"pair-{what[1]}+{what[2]}.elf")
        if a.sim:
            cmd = [a.sim, "--quiet", f"--lat={lat}"] + (["--no-lockstep"] if a.no_lockstep else []) + [img]
        else:
            cmd = [a.replay, "--isa=rv64gc_zicntr", "--priv=MU", "--max-steps=400000000"] + \
                  (["--harts=2"] if kind == "pair" else []) + [img]
        t0 = time.time()
        rc, out = run(cmd, a.timeout)
        res = {int(m[1]): (int(m[2]), int(m[3]), int(m[4]))
               for m in re.finditer(r"PAIR slot=(\d) cycles=(\d+) instret=(\d+) runs=(\d+)", out)}
        ok = "PAIR-END" in out and ("TG-RESULT status=PASS" in out or "TG-REPLAY status=PASS" in out)
        why = "" if ok else next((l.strip() for l in reversed(out.splitlines()) if l.strip()), "no output")[:200]
        return job, res, why, " ".join(cmd), time.time() - t0

    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        results = list(ex.map(one, jobs))
    alone, pair, fails = {}, {}, []
    for (kind, what, slot, lat), res, why, cmd, dt in results:
        if why:
            fails.append(f"  FAIL {kind} {what if kind == 'alone' else what[1] + '+' + what[2]}"
                         f"{' slot ' + str(slot) if kind == 'alone' else ''} lat {lat}: {why}\n       repro: {cmd}")
            continue
        fig = {s: {"ipc": i / c, "cycles": c, "instret": i, "runs": r} for s, (c, i, r) in res.items()}
        if kind == "alone":
            alone[(what, slot, lat)] = fig[slot]
        else:
            pair[(what, lat)] = fig
    for f in fails:
        print(f)
    report = {"alone": {f"{p}@s{s}@{lat}": v for (p, s, lat), v in alone.items()}, "pairs": [], "groups": {}, "overall": {}}
    if a.only in ("alone", "all"):
        print(f"{'program':24s}" + "".join(f"  IPC s0/s1 lat {lat:<3d}" for lat in lats))
        for p in progs:
            row = "".join(f"  {ipc(alone.get((p, 0, lat))):6.3f}/{ipc(alone.get((p, 1, lat))):6.3f}       " for lat in lats)
            print(f"{p:24s}{row}")
    if a.only in ("pairs", "all") and pair:
        print(f"{'pair':40s} {'group':16s}" + "".join(f"  WS lat {lat:<4d}" for lat in lats))
        groups = {}
        for g, x, y in pairs:
            ws_row = []
            for lat in lats:
                pr, ax, ay = pair.get(((g, x, y), lat)), alone.get((x, 0, lat)), alone.get((y, 1, lat))
                ws = (pr[0]["ipc"] / ax["ipc"] + pr[1]["ipc"] / ay["ipc"]) if pr and ax and ay and 0 in pr and 1 in pr \
                    else float("nan")
                ws_row.append(ws)
                groups.setdefault((g, lat), []).append(ws)
                report["pairs"].append({"group": g, "a": x, "b": y, "lat": lat, "ws": ws, "slots": pr})
            print(f"{x + '+' + y:40s} {g:16s}" + "".join(f"  {w:10.3f}" for w in ws_row))
        for lat in lats:
            gm = {g: geomean(groups.get((g, lat), [])) for g in GROUPS}
            report["groups"][lat] = gm
            report["overall"][lat] = geomean(list(gm.values()))
            print(f"lat {lat}: " + ", ".join(f"{g} {v:.3f}" for g, v in gm.items()) + f"; overall {report['overall'][lat]:.3f}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(report, f, indent=1)
    print(f"run_pair: {len(results) - len(fails)} of {len(results)} runs, {time.time() - t0:.0f} s")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
