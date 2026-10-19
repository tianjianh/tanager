#!/usr/bin/env python3
"""perf: the benchmarks' cycles and IPC on this tree's RTL (or BRANCH's) against BASE, by default main, for
M6's per-feature measurements in simulation (DR-153; docs/spec/verification.md §4.2).

Both sides build as cycle-identical's do (tools/ci/cycle_identical.py: its shared build cache, this tree's
harness, the profile switches of sim/profile.mk), and run CoreMark A and B and Dhrystone (tests/bench) in
tg_vsim with lockstep. The table gives each program's timed region (CoreMark's iterations, Dhrystone's
runs, between the tg_marker stores): cycles and IPC on both sides, the change in cycles (negative is
faster), and CoreMark/MHz or DMIPS/MHz. A feature behind a switch is measured on one commit with BASE=HEAD
and the switch on this side only (BRANCH_DC_MSHRS=4, BRANCH_QUEUE_DECODE=1, ...).
  make perf [BASE=main] [BRANCH=<ref>] [CFG=st] [MARCH=rv64gc] [ITER=10] [RUNS=500] [LAT=native] [JOBS=8]
            [TIMING_CUTS|DC_MSHRS|QUEUE_DECODE|SPEC_WAKE|STA_BASE|STEER_LA|STORE_PF=...] [BRANCH_TIMING_CUTS|..._STEER_LA|..._STORE_PF=...]
MARCH and LAT take lists ("rv64im,rv64gc", "native,120"). Results are cached per build and program, so a
second measurement against the same BASE reruns only this side. Exit status: 0 measured; 2 could not run.
"""
import argparse
import concurrent.futures as cf
import hashlib
import math
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cycle_identical as ci  # noqa: E402

PROGRAMS = ("coremark_A", "coremark_B", "dhrystone")


def result(side, elf, args):
    """The TG-RESULT fields of one run, cached in the build's directory (the runs are cycle-exact)."""
    key = hashlib.sha1("\0".join([ci.file_digest(elf), *args]).encode()).hexdigest()
    path = os.path.join(side.dir, "perf", key + ".txt")
    if os.path.exists(path):
        line = open(path).read()
    else:
        p = subprocess.run([side.bin, "--quiet", ci.NO_WALL_LIMIT, *args, elf], capture_output=True, text=True,
                           env=ci.clean_env())
        line = next((l for l in p.stdout.splitlines() if l.startswith("TG-RESULT")), "")
        if "status=PASS" not in line:
            return None, (p.stdout + p.stderr).strip().splitlines()[-3:]
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(line)
    return {k: v for k, v in re.findall(r"(\w+)=(\S+)", line)}, None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="main")
    ap.add_argument("--branch", default="", help="measure this ref's RTL instead of the working tree's")
    ap.add_argument("--cfg", default="st")
    ap.add_argument("--march", default="rv64gc", help="rv64im, rv64gc, rv64gcb, or a list")
    ap.add_argument("--iter", type=int, default=10, help="CoreMark iterations (10: warm caches)")
    ap.add_argument("--runs", type=int, default=500, help="Dhrystone runs")
    ap.add_argument("--lat", default="native", help="tg_vsim memory latency: native, 90, 120, 250, or a list")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--harness", choices=("auto", "branch", "own"), default="auto",
                    help="the base side's sim/, as cycle-identical's --harness")
    for var, opt, vals in (("TIMING_CUTS", "timing-cuts", (0, 1)), ("DC_MSHRS", "dc-mshrs", (1, 4)),
                           ("QUEUE_DECODE", "queue-decode", (0, 1)), ("SPEC_WAKE", "spec-wake", (0, 1)),
                           ("STA_BASE", "sta-base", (0, 1)), ("STEER_LA", "steer-la", (0, 1)),
                           ("STORE_PF", "store-pf", (0, 1))):
        ap.add_argument(f"--{opt}", type=int, choices=vals, default=None, help=f"{var} on both sides")
        ap.add_argument(f"--branch-{opt}", type=int, choices=vals, default=None, help=f"{var} on this side only")
    a = ap.parse_args()
    if not os.environ.get("RISCV_TESTS"):
        ci.fail("source tools/env.sh first")

    base_commit = ci.git("rev-parse", "--verify", f"{a.base}^{{commit}}")
    tree = ci.worktree_tree()
    if a.branch:
        branch_rtl = ci.git("rev-parse", "--verify", f"{a.branch}^{{commit}}")
        label = f"{a.branch} ({branch_rtl[:10]})"
    else:
        branch_rtl = tree
        dirty = ci.git("diff", "--stat", "HEAD", tree, "--", "rtl", "sim").strip()
        label = f"{ci.WT} at {ci.git('rev-parse', '--short', 'HEAD')}{' with uncommitted changes' if dirty else ''}"
    both = {"TIMING_CUTS": (a.timing_cuts, a.branch_timing_cuts), "DC_MSHRS": (a.dc_mshrs, a.branch_dc_mshrs),
            "QUEUE_DECODE": (a.queue_decode, a.branch_queue_decode), "SPEC_WAKE": (a.spec_wake, a.branch_spec_wake),
            "STA_BASE": (a.sta_base, a.branch_sta_base), "STEER_LA": (a.steer_la, a.branch_steer_la),
            "STORE_PF": (a.store_pf, a.branch_store_pf)}
    prof_base = {v: b for v, (b, _) in both.items() if b is not None}
    prof_branch = {v: br if br is not None else b for v, (b, br) in both.items() if br is not None or b is not None}
    for v in set(prof_base) | set(prof_branch):
        if not ci.profile_takes(tree, v):
            ci.fail(f"this tree's sim/profile.mk does not take {v}")
    prof = lambda p: ", ".join(f"{v}={p[v]}" for v, _ in ci.PROFILE_VARS if v in p) or "default profile"
    marches = a.march.replace(",", " ").split()
    lats = a.lat.replace(",", " ").split()
    tool = ci.toolchain_id()

    # The programs, from this tree's tests/bench
    progs = []
    for m in marches:
        mk = [f"MARCH={m}", f"ITER={a.iter}", f"RUNS={a.runs}"]
        ci.make("-C", "tests/bench", *mk, "build")
        odir = ci.make("-C", "tests/bench", *mk, "print-out")
        for p in PROGRAMS:
            for lat in lats:
                progs.append((p, m, lat, os.path.join(odir, p + ".elf"), [f"--lat={lat}"]))

    harness_base = base_commit if a.harness == "own" else tree
    sides = {"base": ci.Side("base", "vsim", a.cfg, tool, base_commit, harness_base, prof=prof_base),
             "branch": ci.Side("branch", "vsim", a.cfg, tool, branch_rtl, tree, prof=prof_branch)}
    failed = ci.build_all(list(sides.values()), a.jobs, a.cfg)
    harness = {"base": "this tree's sim/" if harness_base == tree else "its own sim/", "branch": "this tree's sim/"}
    if failed and a.harness == "auto":
        # A commit's RTL may not fit this tree's harness (a port it lacks): that side takes its own sim/,
        # if that sim/ can force the side's profile (one without the variable would drop it unseen)
        retry = {}
        for name, s in sides.items():
            rtl, p = s.args[3], s.args[7]
            if s.key in failed and rtl != tree and s.harness_src != rtl and not all(ci.profile_takes(rtl, v) for v in p):
                failed[s.key] += (f" (its own sim/profile.mk does not take {', '.join(v for v in p if not ci.profile_takes(rtl, v))}, "
                                  "so it cannot build there either: merge main into it first)")
            elif s.key in failed and rtl != tree and s.harness_src != rtl:
                ci.log(f"{name}: its RTL does not build with this tree's harness ({failed.pop(s.key)}); using its own sim/")
                retry[name] = ci.Side(name, "vsim", a.cfg, tool, rtl, rtl, prof=p)
                harness[name] = "its own sim/"
        if retry:
            failed.update(ci.build_all(list(retry.values()), a.jobs, a.cfg))
            sides.update(retry)
    if failed:
        ci.fail("; ".join(failed.values()))
    base, branch = sides["base"], sides["branch"]

    jobs = [(i, s) for i in range(len(progs)) for s in (base, branch)]
    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        res = dict(zip(jobs, ex.map(lambda j: result(j[1], progs[j[0]][3], progs[j[0]][4]), jobs)))
    base.release()
    branch.release()

    print(f"perf: base {base_commit[:10]} ({ci.git('log', '-1', '--format=%s', base_commit)[:60]}), {prof(prof_base)}, "
          f"{harness['base']}")
    print(f"      this side {label}, {prof(prof_branch)}, {harness['branch']}")
    print(f"      {a.cfg}, CoreMark {a.iter} iterations, Dhrystone {a.runs} runs; timed regions, lockstep on")
    print(f"{'program':24s} {'base cycles':>12s} {'IPC':>6s} {'this cycles':>12s} {'IPC':>6s} {'change':>8s}   score")
    ratios, bad = [], 0
    for i, (p, m, lat, _, _) in enumerate(progs):
        name = f"{p} {m}" + (f" lat{lat}" if len(lats) > 1 or lat != "native" else "")
        (rb, eb), (rt, et) = res[(i, base)], res[(i, branch)]
        if rb is None or rt is None:
            bad += 1
            print(f"{name:24s} FAILED on {'the base' if rb is None else 'this side'}: {' | '.join(eb or et)[:150]}")
            continue
        cb, ct = int(rb["region_cycles"]), int(rt["region_cycles"])
        ib, it = int(rb["region_instret"]), int(rt["region_instret"])
        ratios.append(ct / cb)
        if p.startswith("coremark"):
            score = f"{a.iter * 1e6 / cb:.3f} -> {a.iter * 1e6 / ct:.3f} CM/MHz"
        else:
            score = f"{a.runs * 1e6 / (cb * 1757):.3f} -> {a.runs * 1e6 / (ct * 1757):.3f} DMIPS/MHz"
        print(f"{name:24s} {cb:12,d} {ib / cb:6.3f} {ct:12,d} {it / ct:6.3f} {(ct / cb - 1) * 100:+7.2f}%   {score}")
    if ratios:
        print(f"{'geometric mean':24s} {'':12s} {'':6s} {'':12s} {'':6s} "
              f"{(math.exp(sum(map(math.log, ratios)) / len(ratios)) - 1) * 100:+7.2f}%")
    return 2 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
