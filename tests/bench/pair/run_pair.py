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
  run_pair.py ... --select ms_chase8,ms_gather+ms_stride   some programs (their alone runs and pairs) or pairs
  run_pair.py --replay <tg_replay> --images DIR   Spike against Spike: the images' own check (IPC is 1 there)
The alone runs go first. A pair's cycle limit (tg_vsim --cycles) is --cap times its two programs' whole alone runs:
a pair that reaches it is a hang, reported with the slot that never finished its first region (one hart starved
while the other runs; tg_vsim's own HANG is no commit on any hart). The JSON has each run's region figures per slot
(ipc, cycles, instret and runs, the restarts; alone runs also total, the whole run's cycles), each pair's WS, the
hangs, and the group and overall figures per latency."""
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim", help="tg_vsim built for smt2")
    ap.add_argument("--replay", help="tg_replay (Spike against Spike)")
    ap.add_argument("--images", required=True, help="build_pair.sh's output directory")
    ap.add_argument("--lat", default="30,120,250")
    ap.add_argument("--only", choices=("alone", "pairs", "all"), default="all")
    ap.add_argument("--alone", default="", help="with --only pairs: alone figures from an earlier JSON (same build)")
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
        progs = [p for p in progs if p in sel]
        pairs = [(g, x, y) for g, x, y in pairs if x in sel or y in sel or f"{x}+{y}" in sel]
    lats = [int(x) for x in a.lat.split(",")] if a.sim else [0]
    alone, pair, fails, hangs = {}, {}, [], []
    if a.sim and a.only == "pairs" and not a.alone:
        ap.error("--only pairs needs --alone FILE: the alone figures of the same build (--only alone writes them)")
    if a.alone:
        if not os.path.exists(a.alone):
            ap.error(f"--alone: no {a.alone} (run --only alone first, on the same build)")
        for k, v in json.load(open(a.alone))["alone"].items():
            p, s, lat = k.split("@")
            alone[(p, int(s[1:]), int(lat))] = v

    def one(job):
        kind, what, slot, lat, cap = job
        img = os.path.join(a.images, "img", f"alone-{what}-s{slot}.elf" if kind == "alone" else f"pair-{what[1]}+{what[2]}.elf")
        if a.sim:
            cmd = [a.sim, "--quiet", f"--lat={lat}", f"--timeout={a.timeout}"] + \
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
        if not ok:
            stopped = sorted({int(s) for s in re.findall(r"PAIR-STOP slot=(\d)", out)})
            if "TIMEOUT: cycle limit" in out:
                hang = True
                why = f"no end within {cap or 50_000_000:,} cycles: " + \
                      (f"slot {stopped[0]} finished its first region, slot {1 - stopped[0]} did not" if stopped
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
    results = []
    if a.only in ("alone", "all"):
        results += run_all([("alone", p, s, lat, 0) for p in progs for s in (0, 1) for lat in lats])
        for (kind, what, slot, lat, _), res, total, why, hang, cmd, dt in results:
            if why:
                fails.append(f"  FAIL {label(kind, what, slot, lat)}: {why}\n       repro: {cmd}")
                continue
            c, i, r = res[slot]
            alone[(what, slot, lat)] = {"ipc": i / c, "cycles": c, "instret": i, "runs": r, "total": total}
    if a.only in ("pairs", "all"):
        def cap(x, y, lat):
            if not a.sim or a.max_cycles:
                return a.max_cycles if a.sim else 0
            tx, ty = (alone.get((x, 0, lat)) or {}).get("total"), (alone.get((y, 1, lat)) or {}).get("total")
            return max(CAP_MIN, int(a.cap * (tx + ty))) if tx and ty else 0
        pres = run_all([("pair", (g, x, y), None, lat, cap(x, y, lat)) for g, x, y in pairs for lat in lats])
        results += pres
        for (kind, what, slot, lat, _), res, total, why, hang, cmd, dt in pres:
            if why:
                (hangs if hang else fails).append(f"  {'HANG' if hang else 'FAIL'} {label(kind, what, slot, lat)}: {why}"
                                                  f"\n       repro: {cmd}")
                if hang:
                    pair[(what, lat)] = {"hang": why}
                continue
            pair[(what, lat)] = {s: {"ipc": i / c, "cycles": c, "instret": i, "runs": r} for s, (c, i, r) in res.items()}
    for f in fails + hangs:
        print(f)
    report = {"alone": {f"{p}@s{s}@{lat}": v for (p, s, lat), v in alone.items()}, "pairs": [], "hangs": [],
              "groups": {}, "overall": {}}
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
                if pr and "hang" in pr:
                    report["hangs"].append({"group": g, "a": x, "b": y, "lat": lat, "why": pr["hang"]})
                    ws_row.append("hang")
                    continue
                ws = (pr[0]["ipc"] / ax["ipc"] + pr[1]["ipc"] / ay["ipc"]) if pr and ax and ay and 0 in pr and 1 in pr \
                    else float("nan")
                ws_row.append(ws)
                groups.setdefault((g, lat), []).append(ws)
                report["pairs"].append({"group": g, "a": x, "b": y, "lat": lat, "ws": ws, "slots": pr})
            print(f"{x + '+' + y:40s} {g:16s}" + "".join(f"  {w:>10s}" if isinstance(w, str) else f"  {w:10.3f}"
                                                        for w in ws_row))
        for lat in lats:
            gm = {g: geomean(groups.get((g, lat), [])) for g in GROUPS}
            report["groups"][lat] = gm
            report["overall"][lat] = geomean(list(gm.values()))
            nh = sum(1 for h in report["hangs"] if h["lat"] == lat)
            print(f"lat {lat}: " + ", ".join(f"{g} {v:.3f}" for g, v in gm.items()) +
                  f"; overall {report['overall'][lat]:.3f}" + (f" ({nh} hung pairs left out)" if nh else ""))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(report, f, indent=1)
    print(f"run_pair: {len(results) - len(fails) - len(hangs)} of {len(results)} runs"
          f"{f', {len(hangs)} hangs' if hangs else ''}, {time.time() - t0:.0f} s")
    return 1 if fails or hangs else 0


if __name__ == "__main__":
    sys.exit(main())
