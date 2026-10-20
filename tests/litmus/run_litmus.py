#!/usr/bin/env python3
"""Runs RVWMO litmus tests (litmus-tests-riscv) in batches through litmus_gen.py, on Spike (tg_replay), on the core
alone (tg_vsim) or on the SoC (tb_boot), and judges every final state against herd's (docs/spec/verification.md §6.6).

A test passes when every state it ends in is one herd's RISC-V model allows. Spike runs check the harness: its
harts interleave one instruction at a time, so every state is allowed. Tests with an SC don't run there: each Spike
hart keeps its LR reservation through another hart's store, so the replaying Spike's SC can succeed where the
checker's must fail, and the replay stops.
  run_litmus.py --suite DIR --replay <tg_replay> --harts 0,1 --workdir DIR [--family SAFE,CO] [--sample N]
  run_litmus.py --suite DIR --tb <tb_boot> --harts 0,1 --workdir DIR [--lat fixed|jitter|board|default]
  run_litmus.py --suite DIR --vsim <tg_vsim> --harts 0,1 --workdir DIR
Failing batches are kept in WORKDIR/failures with their program, log and a command that reruns them; every test's
LIT line goes to WORKDIR/results.txt."""
import argparse
import concurrent.futures as cf
import glob
import os
import random
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "ci"))
import host_policy  # noqa: E402  (the runners' share of a hybrid host)


def run(args, timeout):
    try:
        p = subprocess.run(args, capture_output=True, text=True, errors="replace", timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        return -1, (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "") + "\nwall-clock timeout\n"


def listed(path):
    """The tests an @all list names, its lines being test files or further lists, relative to it: the suite's
    canonical set, the one herd's results cover (a few files elsewhere repeat a listed test's name)."""
    out, d = [], os.path.dirname(path)
    for line in open(path, errors="replace"):
        line = line.split("#")[0].strip()
        if not line:
            continue
        p = os.path.normpath(os.path.join(d, line))
        if os.path.basename(p).startswith("@"):
            out += listed(p)
        elif p.endswith(".litmus") and os.path.exists(p):
            out.append(p)
    return out


def threads_of(path):
    """A test's thread count from its code header (P0 | P1 ...), or 0."""
    with open(path, errors="replace") as f:
        for line in f:
            if re.match(r"^\s*P0\b", line):
                return line.count("|") + 1
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--suite", required=True, help="the litmus-tests-riscv checkout (read only)")
    ap.add_argument("--replay", help="tg_replay: Spike against Spike")
    ap.add_argument("--vsim", help="tg_vsim: the core alone (its harts are its threads)")
    ap.add_argument("--tb", help="tb_boot built with CORES=2: the SoC")
    ap.add_argument("--harts", default="0,1")
    ap.add_argument("--family", default="", help="families of tests/non-mixed-size (their @all lists), comma-separated; "
                                                 "default the suite's whole list")
    ap.add_argument("--list", default="", help="a file of test names or paths, one a line (instead of --family)")
    ap.add_argument("--sample", type=int, default=0, help="this many tests at random from the selection (0: all)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--iters", type=int, default=200)
    ap.add_argument("--batch", type=int, default=40, help="tests a program")
    ap.add_argument("--lat", default="default", help="tb_boot's DDR timing: default, fixed (22), jitter (18-26), "
                                                     "board (fixed and jitter by batch), slow (120)")
    ap.add_argument("--max-mcycles", type=int, default=400)
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=7200)
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--name", default="litmus")
    a = ap.parse_args()
    harness = [k for k in ("replay", "vsim", "tb") if getattr(a, k)]
    if len(harness) != 1:
        ap.error("one of --replay, --vsim, --tb")
    harness = harness[0]
    harts = [int(h) for h in a.harts.split(",")]
    policy = host_policy.apply_self(1)
    if policy:
        print(f"run_litmus: {policy}", flush=True)
    herd = os.path.join(a.suite, "model-results", "herd.logs")
    base = os.path.join(a.suite, "tests", "non-mixed-size")
    if a.list:
        names = [l.strip() for l in open(a.list) if l.strip() and not l.startswith("#")]
        allp = {os.path.splitext(os.path.basename(p))[0]: p for p in glob.glob(os.path.join(base, "**", "*.litmus"), recursive=True)}
        paths = [n if os.path.exists(n) else allp[n] for n in names if os.path.exists(n) or n in allp]
    else:
        fams = [f for f in a.family.split(",") if f]
        paths = sorted(set(listed(os.path.join(base, "@all")) if not fams else
                           [p for f in fams for p in listed(os.path.join(base, f, "@all"))]))
    stale = {l.strip() for l in open(os.path.join(HERE, "stale.txt")) if l.strip() and not l.startswith("#")}
    nstale = len(paths)
    paths = [p for p in paths if os.path.splitext(os.path.basename(p))[0] not in stale]
    nstale -= len(paths)
    paths = [p for p in paths if 0 < threads_of(p) <= len(harts)]
    # The load-acquire and store-release forms the core does not have (litmus_gen skips them too): left out before
    # batching, so batches stay full
    nlar = len(paths)
    paths = [p for p in paths if not re.search(r"\b(lw|ld|lh|lb)\.aq\b|\b(sw|sd|sh|sb)\.rl\b", open(p, errors="replace").read())]
    nlar -= len(paths)
    if a.sample and a.sample < len(paths):
        paths = sorted(random.Random(a.seed).sample(paths, a.sample))
    nlrsc = 0
    if a.replay:   # see the docstring: Spike's harts keep their reservations through each other's stores
        keep = [p for p in paths if not re.search(r"\bsc\.[wd]", open(p, errors="replace").read())]
        nlrsc, paths = len(paths) - len(keep), keep
    os.makedirs(a.workdir, exist_ok=True)
    faildir = os.path.join(a.workdir, "failures")
    batches = [paths[i:i + a.batch] for i in range(0, len(paths), a.batch)]
    spike = harness == "replay"
    isa = "rv64imac_zicsr_zicntr_zifencei"

    def timing(k):
        kind = a.lat if a.lat != "board" else ("fixed", "jitter")[k % 2]
        return {"fixed": ["+mem_lat_min=22", "+mem_lat_max=22", "+mem_ready_pct=100", "+mem_r_pct=100", "+mem_ooo=0"],
                "jitter": ["+mem_lat_min=18", "+mem_lat_max=26"],
                "slow": ["+mem_lat_min=120", "+mem_lat_max=120"], "default": []}[kind]

    def one(k):
        stem = os.path.join(a.workdir, f"b{k}")
        rc, gout = run([sys.executable, "-I", os.path.join(HERE, "litmus_gen.py"), "--herd", herd, "--harts", a.harts,
                        "--iters", str(a.iters), "--seed", str(a.seed * 1000 + k), "-o", stem + ".S"] + batches[k], 300)
        skipped = {l.split("skip ", 1)[1].rsplit(": ", 1)[0] for l in gout.splitlines() if "litmus_gen: skip " in l}
        if rc == 3:            # every test of the batch skipped
            return k, {}, skipped, "", ""
        if rc:
            return k, {}, skipped, "GEN-FAIL " + (gout.strip().splitlines() or ["?"])[-1], ""
        for cmd in (["riscv-none-elf-gcc", "-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-nostdlib", "-nostartfiles",
                     "-static", "-mcmodel=medany", "-Wl,--no-warn-rwx-segments", "-T", os.path.join(HERE, "link.ld"),
                     stem + ".S", "-o", stem + ".elf"],
                    ["riscv-none-elf-objcopy", "-O", "binary", stem + ".elf", stem + ".bin"]):
            rc, out = run(cmd, 300)
            if rc:
                return k, {}, skipped, "BUILD-FAIL " + (out.strip().splitlines() or ["?"])[0][:200], ""
        if harness == "replay":
            cmd = [a.replay, f"--isa={isa}", "--priv=MU", f"--harts={max(harts) + 1}", "--max-steps=400000000",
                   stem + ".elf"]
        elif harness == "vsim":
            cmd = [a.vsim, "--no-lockstep", f"--cycles={a.max_mcycles * 1000000}", stem + ".elf"]
        else:
            cmd = [a.tb, f"+fw={stem}.bin", "+expect=LIT-END", f"+max_mcycles={a.max_mcycles}", "+mem_zero"] + timing(k)
        rc, out = run(cmd, a.timeout)
        with open(stem + ".log", "w") as f:
            f.write(" ".join(cmd) + "\n" + out)
        # tb_boot's progress lines start with a newline, so one can cut a console line in two: join it back
        out = re.sub(r"\n\[tb_boot\][^\n]*\n", "", out)
        with open(os.path.join(a.workdir, "results.txt"), "a") as f:   # every test's line, kept after the logs go
            f.writelines(re.sub(r"^\d{10} ", "", l) + "\n" for l in out.splitlines() if re.search(r"\bLIT(-BAD)? ", l))
        res = {}
        for m in re.finditer(r"^.*?LIT (\S+) k=(\d+) bad=(\d+) s=([\d,]*)", out, re.M):
            res[m[1]] = {"bad": int(m[3]), "s": [int(c) for c in m[4].split(",") if c]}
        for m in re.finditer(r"^.*?LIT-BAD (\S+) (.*)$", out, re.M):
            if m[1] in res:
                res[m[1]]["first"] = m[2].strip()
        status = "" if "LIT-END" in out else "no LIT-END (" + (out.strip().splitlines() or ["?"])[-1][:120] + ")"
        return k, res, skipped, status, " ".join(cmd)

    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        results = list(ex.map(one, range(len(batches))))
    npass = nbad = nmiss = nskip = seen = allowed = 0
    lines = []
    for k, res, skipped, status, cmd in results:
        nskip += len(skipped)
        names = {}
        for p in batches[k]:
            if p in skipped:
                continue
            with open(p, errors="replace") as f:
                head = f.readline().split()
                txt = f.read()
            names[head[1] if len(head) > 1 else p] = bool(re.search(r"\bsc\.[wd]\b", txt))
        bad_batch = bool(status)
        for name, lrsc in names.items():
            if name in res:
                r = res[name]
                seen += sum(1 for c in r["s"] if c)
                allowed += len(r["s"])
                if r["bad"]:
                    nbad += 1
                    bad_batch = True
                    lines.append(f"  BAD      {name}: {r['bad']} of {a.iters} ended in a state herd does not allow, first "
                                 f"{r.get('first', '?')} (batch {k})")
                else:
                    npass += 1
            else:
                nmiss += 1
                lines.append(f"  MISSING  {name} (batch {k})")
        if status:
            lines.append(f"  BATCH    {k}: {status}")
        if bad_batch:
            os.makedirs(faildir, exist_ok=True)
            for ext in (".S", ".elf", ".bin", ".log"):
                if os.path.exists(os.path.join(a.workdir, f"b{k}{ext}")):
                    shutil.move(os.path.join(a.workdir, f"b{k}{ext}"), os.path.join(faildir, f"b{k}{ext}"))
            lines.append(f"           repro: {cmd.replace(os.path.join(a.workdir, f'b{k}'), os.path.join(faildir, f'b{k}'))}")
        else:
            for ext in (".S", ".elf", ".bin", ".log"):
                p = os.path.join(a.workdir, f"b{k}{ext}")
                if os.path.exists(p):
                    os.remove(p)
    for l in lines:
        print(l)
    print(f"{a.name}: {npass} passed, {nbad} with a state herd does not allow, {nmiss} missing, {nskip} skipped by the "
          f"generator" + (f", {nlrsc} with an SC not run on Spike" if spike else "") +
          (f", {nstale} with stale herd results left out (stale.txt)" if nstale else "") +
          (f", {nlar} with load-acquire or store-release forms left out" if nlar else "") +
          f" ({len(paths)} tests in {len(batches)} programs, harts {a.harts}, {a.iters} iterations each, {harness}"
          f"{', ' + a.lat if harness == 'tb' and a.lat != 'default' else ''}); allowed states seen {seen} of {allowed}; "
          f"{time.time() - t0:.0f} s")
    return 1 if nbad or nmiss or any(r[3] for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
