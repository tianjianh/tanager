#!/usr/bin/env python3
"""boot-lockstep: the Linux boot on the SoC (tests/unit/boot's tb_boot) under lockstep, as far as a core change
needs it (docs/spec/verification.md §4.7; DR-173). M6's micro-BTB alias passed every program and the 20M-cycle
boot, and panicked Linux on the board about 220M cycles in.

tg_soc_tap (sim/tb) takes every core's commit records at tanager_soc's trace ports and writes them, as the board's
ring holds them, into a FIFO that tanager-lockstep reads as the run goes. The trace stream stays off, so the cores
run at their untraced speed: tb_boot's +trace_out goes through the stream, whose one writer holds the cores near
IPC 0.15. The images are cycle-identical's pinned references (REF_IMAGES), unwritten memory reads zero as for any
traced run (+mem_zero), and a run stops at MCYC million cycles, or at TANAGER-BOOT-OK.

  make boot-lockstep [BRANCH=<ref>] [SHAPE=st|board] [MCYC=100] [TIMING="default board"] [SEED=1] [profile switches]
  make boot-lockstep-gate [BASE=<commit>] [BRANCH=<ref>] [profile switches]
  tools/ci/boot_lockstep.py --nightly           (the crontab's run: main, 400M cycles, st and board, the night's timing)
  tools/ci/boot_lockstep.py --install-cron      (the nightly's entry, with main's checkout's copy)

The RTL is BRANCH's (default: this tree's, with its uncommitted changes); the harness (sim/, tests/unit, sw/dts)
is this tree's, as in cycle-identical. SHAPE st is one st core; board is the board's: two smt2 cores, thread 0 of
each (harts 0 and 2). TIMING names the DDR models' timing, one run each, side by side: board (a fixed 22 cycles,
every ready at 100%), jitter (18-26 cycles), fixedN, default (tb_boot's own, 4-12). The gate runs st at 100M
cycles with default and board timing when the change, against its merge base with BASE (main), reaches the core's
fetch, decode, rename, LSU, MMU or CSR, or its top and package; otherwise it says so and passes.
Exit status: 0 every run checked clean; 1 a lockstep mismatch; 2 a run that could not be checked.
"""
import argparse
import concurrent.futures as cf
import datetime
import fcntl
import glob
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cycle_identical as ci  # noqa: E402
import host_policy  # noqa: E402  (the runners' share of a hybrid host; verification.md §8)

NAME = "boot-lockstep"
CACHE = os.path.join(ci.TB, "boot-lockstep")
WORK = os.path.join(ci.TB, ci.WT, "boot-lockstep")
SOAK_FAIL = os.path.join(ci.TB, "soak", "fail")
KEEP_BUILDS = 4           # tb_boot builds kept, binaries only (least recently used go first)
KEEP_RUNS = 30            # run directories kept (logs and reports), newest first
MEM_PARAMS = "-GL2_SETS_TB=1024"   # the board's L2 sets; the DDR timing is set at run time (TIMINGS)
# shape: (CFG, cores, threads, threads Linux runs, Verilator threads). smp4 is M7's four harts, both threads of both
# smt2 cores (the device tree with RUN_THREADS=2); until hart 1 fetches (M7's step 5) Linux brings up harts 0 and 2
# only, and reports the others failed to come online
SHAPES = {"st": ("st", 1, 1, 1, 1), "board": ("smt2", 2, 2, 1, 4), "smp4": ("smt2", 2, 2, 2, 4)}
GATE_PATHS = tuple(f"rtl/core/{d}/" for d in ("frontend", "decode", "rename", "lsu", "mmu", "csr")) + \
             ("rtl/core/tg_core.sv", "rtl/core/tg_core_pkg.sv")
# The gate's two timings, the ones that caught M6's micro-BTB alias on 0a1a418 soonest: tb_boot's own random
# timing (89.3M cycles) and the board's fixed 22 (106.2M); jitter (18-26) ran 100M without it (DR-173)
GATE_MCYC, GATE_TIMINGS = 100, ("default", "board")
NIGHT_MCYC, NIGHT_SHAPES = 400, ("st", "board")
NIGHT_TIMINGS = ("board", "jitter", "fixed30", "default")   # one a night, in turn
NIGHT_MEM_GB = 12         # the nightly starts no run while MemAvailable is under this (as the soak)
NIGHT_CRON = "15 0 * * *"
SWITCH_VALUES = {"TIMING_CUTS": (0, 1), "DC_MSHRS": (1, 4), "QUEUE_DECODE": (0, 1), "SPEC_WAKE": (0, 1),
                 "STA_BASE": (0, 1), "STEER_LA": (0, 1), "PMP_ENTRIES": (8, 16), "STORE_PF": (0, 1), "URF": (0, 1),
                 "STORE_PF_MAX": (2, 3), "SOLO_TID": (0, 1), "SPLIT": (0, 1),
                 "HART1": (0, 1), "SPEC_WAKE_FILT": (0, 1, 2)}


def log(msg):
    print(f"{NAME}: {msg}", flush=True)


def fail(msg):
    print(f"{NAME}: {msg}", file=sys.stderr, flush=True)
    sys.exit(2)


ci.fail = fail  # cycle-identical's helpers report under this name


def timing_args(t):
    if t == "board":
        return ["+mem_lat_min=22", "+mem_lat_max=22", "+mem_ready_pct=100", "+mem_r_pct=100", "+mem_ooo=0"]
    if t == "jitter":
        return ["+mem_lat_min=18", "+mem_lat_max=26"]
    m = re.fullmatch(r"fixed(\d+)", t)
    if m:
        return [f"+mem_lat_min={m[1]}", f"+mem_lat_max={m[1]}", "+mem_ready_pct=100", "+mem_r_pct=100", "+mem_ooo=0"]
    if t == "default":
        return []
    fail(f"unknown timing {t} (board, jitter, fixedN, default)")


class Build:
    """tb_boot with the tap, and tanager-lockstep, from the tested RTL and this tree's harness, in
    CACHE/build/<key>: the checker takes its boot ROM and PMP default from that RTL too."""

    def __init__(self, rtl_src, harness_src, shape, prof, tool):
        self.cfg, self.cores, _, _, self.vthreads = SHAPES[shape]
        self.rtl_src, self.harness_src = rtl_src, harness_src
        self.prof = [f"{v}={prof[v]}" for v, _ in ci.PROFILE_VARS if v in prof]
        trees = [ci.git("rev-parse", f"{rtl_src}:rtl")] + [ci.git("rev-parse", f"{harness_src}:{p}")
                                                          for p in ("sim", "tests/unit")]
        self.key = ci.sha1("tap", *trees, self.cfg, self.cores, self.vthreads, MEM_PARAMS, tool, *self.prof)[:16]
        self.dir = os.path.join(CACHE, "build", self.key)
        self.src, self.obj = os.path.join(self.dir, "src"), os.path.join(self.dir, "obj")
        self.ls = os.path.join(self.obj, "src", "sim", "lockstep", "tanager-lockstep")

    def tb(self):
        found = glob.glob(os.path.join(self.obj, "tests", "*", "tb_boot"))
        return found[0] if len(found) == 1 else None

    def built(self):
        return os.path.exists(os.path.join(self.dir, "OK")) and self.tb() and os.path.exists(self.ls)

    def build(self, jobs):
        """None, or why it failed."""
        os.makedirs(os.path.dirname(self.dir), exist_ok=True)
        with open(self.dir + ".lock", "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)  # another run may be building the same tree
            if self.built():
                os.utime(self.dir)
                return None
            shutil.rmtree(self.dir, ignore_errors=True)
            os.makedirs(self.src)
            for treeish, path in ((self.rtl_src, "rtl"), (self.harness_src, "sim"), (self.harness_src, "tests/unit")):
                a = subprocess.Popen(["git", "archive", treeish, path], cwd=ci.ROOT, stdout=subprocess.PIPE)
                subprocess.run(["tar", "-x", "-C", self.src], stdin=a.stdout, check=True)
                if a.wait():
                    return f"git archive {treeish} {path} failed"
            env = ci.clean_env(CCACHE_BASEDIR=self.dir)
            tbs = " ".join(os.path.join(self.src, f) for f in ("tests/unit/boot/tb_boot.sv", "sim/tb/tg_soc_tap.sv",
                                                                "sim/tb/tg_soc_tap_bind.sv"))
            for cmd in (["make", "-s", "-C", os.path.join(self.src, "tests", "unit", "boot"), f"CFG={self.cfg}",
                         f"CORES={self.cores}", f"VTHREADS={self.vthreads}", f"JOBS={jobs}", f"SOC_BUILD={self.obj}",
                         f"TB={tbs}", "TAG=_tap", f"MEM_PARAMS={MEM_PARAMS}", *self.prof, "build"],
                        ["make", "-s", "-C", os.path.join(self.src, "sim"), f"TANAGER_BUILD={self.obj}", "lockstep"]):
                p = subprocess.run(cmd, env=env, capture_output=True, text=True,
                                   preexec_fn=host_policy.preexec(1))
                if p.returncode:
                    return f"{' '.join(cmd[:4])}: {(p.stdout + p.stderr)[-1500:]}"
            tb = self.tb()
            if not tb:
                return "the build left no single tb_boot"
            # Keep what the runs need: Verilator's objects and precompiled headers are most of a build's 300 MB
            for f in glob.glob(os.path.join(os.path.dirname(tb), "*")):
                if f != tb:
                    shutil.rmtree(f) if os.path.isdir(f) else os.remove(f)
            open(os.path.join(self.dir, "OK"), "w").close()
            return None


def prune_builds(keep):
    bdir = os.path.join(CACHE, "build")
    dirs = [d for d in os.listdir(bdir) if os.path.isdir(os.path.join(bdir, d))]
    for d in sorted(dirs, key=lambda d: -os.path.getmtime(os.path.join(bdir, d)))[KEEP_BUILDS:]:
        if d in keep:
            continue
        with open(os.path.join(bdir, d + ".lock"), "a") as lk:
            try:
                fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue
            shutil.rmtree(os.path.join(bdir, d), ignore_errors=True)


def device_tree(harness_src, shape):
    """The shape's device tree from this tree's sw/dts, as cycle-identical's boot makes it (128 MiB, FPU)."""
    _, cores, threads, run_threads, _ = SHAPES[shape]
    dsrc = ci.git("rev-parse", f"{harness_src}:sw/dts")
    ddir = os.path.join(CACHE, "dts", f"{dsrc[:12]}-c{cores}t{threads}r{run_threads}")
    dtb = os.path.join(ddir, "tanager-kv260.dtb")
    os.makedirs(os.path.dirname(ddir), exist_ok=True)
    with open(ddir + ".lock", "a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        if not os.path.exists(dtb):
            src = os.path.join(ddir, "src")
            shutil.rmtree(ddir, ignore_errors=True)
            os.makedirs(src)
            a = subprocess.Popen(["git", "archive", harness_src, "sw/dts"], cwd=ci.ROOT, stdout=subprocess.PIPE)
            subprocess.run(["tar", "-x", "-C", src], stdin=a.stdout, check=True)
            a.wait()
            p = subprocess.run(["make", "-s", "-C", os.path.join(src, "sw", "dts"), f"O={ddir}", f"CORES={cores}",
                                f"THREADS={threads}", f"RUN_THREADS={run_threads}", *ci.BOOT_DTS],
                               capture_output=True, text=True, env=ci.clean_env(), preexec_fn=host_policy.preexec(1))
            if p.returncode or not os.path.exists(dtb):
                fail(f"building the {shape} device tree: {(p.stdout + p.stderr)[-1000:]}")
    return dtb


def first_victim():
    """For the nightly's runs: the first out-of-memory victim, as the soak. Not niced to 19: the board shape's model
    runs on four threads that meet at every cycle, and at nice 19 on a busy host it made under 1M cycles in 11
    minutes (2026-10-19). The host policy (host_policy.preexec) places them instead."""
    try:
        with open("/proc/self/oom_score_adj", "w") as f:
            f.write("900")
    except OSError:
        pass


def run_one(build, dtb, images, shape, timing, mcyc, seed, outdir, nice=False, plant=None):
    """One boot: tb_boot into the FIFO, tanager-lockstep out of it. Returns (verdict, line, detail)."""
    shutil.rmtree(outdir, ignore_errors=True)
    os.makedirs(outdir)
    fifo = os.path.join(outdir, "tap.fifo")
    os.mkfifo(fifo)
    harts = 1 if SHAPES[shape][1] * SHAPES[shape][3] == 1 else 4   # the record's hart field: harts 0 and 2
    fw, kernel = images["fw"][0], images["kernel"][0]
    # The host policy (verification.md §8): on a hybrid host the st shape's model and its checker at nice 10 or more,
    # the board shape's four-thread model and its checker on the E-cores
    pol = host_policy.preexec(SHAPES[shape][4])

    def pre():
        if nice:
            first_victim()
        if pol:
            pol()

    io = []
    t0 = time.time()
    with open(os.path.join(outdir, "lockstep.log"), "w") as lf, open(os.path.join(outdir, "tb_boot.log"), "w") as tf:
        ls = subprocess.Popen([*io, build.ls, f"--fw={fw}", f"--kernel={kernel}", f"--dtb={dtb}", f"--harts={harts}",
                               *(["--mtgsmt=1"] if "HART1=1" in build.prof else []),  # a core with hart 1 has mtgsmt
                               "--stats=600", *([f"--plant={plant}"] if plant is not None else []), fifo],
                              stdout=lf, stderr=subprocess.STDOUT, preexec_fn=pre if nice or pol else None)
        tb = subprocess.Popen([*io, build.tb(), f"+fw={fw}", f"+dtb={dtb}", f"+kernel={kernel}",
                               f"+expect={ci.BOOT_EXPECT}", f"+max_mcycles={mcyc}", f"+verilator+seed+{seed}",
                               "+mem_zero", f"+tap_out={fifo}", *timing_args(timing)],
                              stdout=tf, stderr=subprocess.STDOUT, preexec_fn=pre if nice or pol else None)
        limit = max(3600, mcyc * 180)   # wall seconds: 3 minutes a million cycles, four times today's pace
        timed_out = False
        for p in (tb, ls):
            try:
                p.wait(timeout=max(1, limit - (time.time() - t0)))
            except subprocess.TimeoutExpired:
                timed_out = True
                tb.kill()
                ls.kill()
                p.wait()
    minutes = (time.time() - t0) / 60
    os.remove(fifo)
    lsl = open(os.path.join(outdir, "lockstep.log"), errors="replace").read()
    tbl = open(os.path.join(outdir, "tb_boot.log"), errors="replace").read()
    prog = re.findall(r"\[tb_boot\] (\d+) M cycles, (\d+) instructions retired", tbl)
    cyc_m, instr = (int(prog[-1][0]), int(prog[-1][1])) if prog else (0, 0)
    end = re.search(r"tanager-lockstep: (PASS|MISMATCH) after (\d+) records", lsl)
    where = f"{cyc_m}M cycles, {instr / 1e6:.1f}M instructions{f' (IPC {instr / (cyc_m * 1e6):.2f})' if cyc_m else ''}"
    tag = f"{shape} {timing} {mcyc}M seed {seed}{f' (planted fault at record {plant})' if plant is not None else ''}"
    if end and end[1] == "MISMATCH":
        first = re.search(r"MISMATCH at record (\d+) \(cycle (\d+)\): (.*)", lsl)
        rtl = re.search(r"RTL record: +(.*)", lsl)
        detail = (f"MISMATCH at record {int(first[1]):,} (cycle {int(first[2]):,}): {first[3]}" if first else "MISMATCH") + \
                 (f"; RTL {' '.join(rtl[1].split())[:120]}" if rtl else "")
        return "MISMATCH", f"{tag}: {detail}; {minutes:.0f} min; report {outdir}/lockstep.log", detail
    reached = "TEST PASSED (boot" in tbl
    limit_hit = "not seen" in tbl
    if end and end[1] == "PASS" and (reached or limit_hit) and not timed_out:
        what = "to TANAGER-BOOT-OK" if reached else "to the cycle limit"
        return "PASS", f"{tag}: PASS, {int(end[2]):,} records {what} ({where}), {minutes:.0f} min", ""
    why = ("wall-clock limit" if timed_out else
           next((l.strip() for l in (tbl + lsl).splitlines() if re.search(r"%Error|%Fatal|fatal|NOTHING|cannot", l)),
                "no verdict from tanager-lockstep or tb_boot"))
    return "BROKEN", f"{tag}: could not be checked: {why[:200]} ({where}); logs in {outdir}", why


def resolve(a):
    """(the tested RTL's tree-ish, its label)."""
    if a.branch:
        rtl = ci.git("rev-parse", "--verify", f"{a.branch}^{{commit}}")
        return rtl, f"{a.branch} ({rtl[:10]})"
    tree = ci.worktree_tree()
    dirty = ci.git("diff", "--stat", "HEAD", tree, "--", "rtl").strip()
    return tree, f"{ci.WT} at {ci.git('rev-parse', '--short', 'HEAD')}{' with uncommitted changes' if dirty else ''}"


def install_cron():
    """The nightly's crontab entry, with main's checkout's copy (as the soak's @reboot entry)."""
    main_dir = os.path.dirname(ci.git("rev-parse", "--path-format=absolute", "--git-common-dir"))
    os.makedirs(CACHE, exist_ok=True)
    line = (f"{NIGHT_CRON} /bin/bash -lc 'cd {main_dir} && source tools/env.sh > /dev/null 2>&1 && "
            f"python3 tools/ci/boot_lockstep.py --nightly' >> {CACHE}/nightly.log 2>&1")
    old = subprocess.run(["crontab", "-l"], capture_output=True, text=True).stdout.splitlines()
    new = [l for l in old if "tools/ci/boot_lockstep.py" not in l] + [line]
    subprocess.run(["crontab", "-"], input="\n".join(new) + "\n", text=True, check=True)
    log(f"crontab: {line}")


def nightly(a, tool):
    """main's head, NIGHT_MCYC cycles, every NIGHT_SHAPES shape, the night's timing; findings to the soak's list."""
    os.makedirs(CACHE, exist_ok=True)
    lk = open(os.path.join(CACHE, "nightly.lock"), "a")
    try:
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fail("another nightly run holds the lock")
    for _ in range(36):  # memory first (conventions §9): wait up to 3 hours for room
        mem = int(re.search(r"MemAvailable:\s+(\d+)", open("/proc/meminfo").read())[1]) // (1 << 20)
        if mem >= NIGHT_MEM_GB:
            break
        log(f"MemAvailable {mem} GB, under {NIGHT_MEM_GB}: waiting")
        time.sleep(300)
    else:
        fail("no memory for the nightly run")
    day = datetime.date.today().toordinal()
    a.branch, a.shape, a.mcyc = "main", ",".join(NIGHT_SHAPES), a.mcyc or NIGHT_MCYC
    a.timing, a.seed = NIGHT_TIMINGS[day % len(NIGHT_TIMINGS)], day % 1000 + 1
    return checks(a, tool, nice=True, nightly=True)


def record_finding(commit, shape, timing, mcyc, seed, verdict, detail, outdir):
    """A finding in the soak's list (summary.md's 'Failures to triage'): repro.txt line 1 what, 2 the repro, 3 why."""
    d = os.path.join(SOAK_FAIL, f"{time.strftime('%Y%m%d-%H%M%S')}-boot-{shape}-{timing}")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "repro.txt"), "w") as f:
        f.write(f"main {commit[:10]}, boot-lockstep {shape} {timing} {mcyc}M seed {seed}\n")
        f.write(f"make boot-lockstep BRANCH={commit[:10]} SHAPE={shape} TIMING={timing} MCYC={mcyc} SEED={seed}\n")
        f.write(f"boot-lockstep {verdict}: {detail[:300]}\n")
    for src, dst in (("lockstep.log", "tail.log"), ("tb_boot.log", "console.log")):
        try:
            with open(os.path.join(outdir, src), errors="replace") as s:
                lines = s.read().splitlines()
            with open(os.path.join(d, dst), "w") as o:
                o.write("\n".join(lines[-200:]) + "\n")
        except OSError:
            pass


def checks(a, tool, nice=False, nightly=False):
    rtl, label = resolve(a)
    harness = ci.worktree_tree()
    shapes = a.shape.replace(",", " ").split()
    timings = a.timing.replace(",", " ").split()
    for s in shapes:
        if s not in SHAPES:
            fail(f"unknown shape {s} ({', '.join(SHAPES)})")
    for t in timings:
        timing_args(t)
    prof = {v: getattr(a, v.lower()) for v, _ in ci.PROFILE_VARS if getattr(a, v.lower(), None) is not None}
    for v in prof:
        if not ci.profile_takes(harness, v):
            fail(f"this tree's sim/profile.mk does not take {v}")
    images = {k: ci.boot_image(k, a.boot_fw if k == "fw" else a.boot_kernel) for k in ("fw", "kernel")}
    log(f"{label}: {', '.join(shapes)}; timing {', '.join(timings)}; {a.mcyc}M cycles; seed {a.seed}"
        f"{'; ' + ', '.join(f'{v}={p}' for v, p in prof.items()) if prof else ''}")
    for k, (path, h, what) in images.items():
        log(f"  {'firmware' if k == 'fw' else 'kernel  '}: sha256 {h} ({what}), {path}")
    builds = {s: Build(rtl, harness, s, prof, tool) for s in shapes}
    t0 = time.time()
    for s, b in builds.items():
        why = b.build(a.jobs)
        if why:
            fail(f"building {s}: {why}")
    log(f"built in {time.time() - t0:.0f} s; running {len(shapes) * len(timings)} boot(s) side by side")
    prune_builds({b.key for b in builds.values()})
    dtbs = {s: device_tree(harness, s) for s in shapes}
    stamp = time.strftime("%Y%m%d-%H%M%S")
    runs = [(s, t) for s in shapes for t in timings]
    with cf.ThreadPoolExecutor(max_workers=len(runs)) as ex:
        futs = {ex.submit(run_one, builds[s], dtbs[s], images, s, t, a.mcyc, a.seed,
                          os.path.join(CACHE if nightly else WORK, "runs", f"{stamp}-{s}-{t}"), nice, a.plant): (s, t)
                for s, t in runs}
        res = {futs[f]: f.result() for f in cf.as_completed(futs)}
    rdir = os.path.join(CACHE if nightly else WORK, "runs")
    for d in sorted(os.listdir(rdir), reverse=True)[KEEP_RUNS:]:
        shutil.rmtree(os.path.join(rdir, d), ignore_errors=True)
    status = 0
    commit = rtl if a.branch else ci.git("rev-parse", "HEAD")
    for s, t in runs:
        verdict, line, detail = res[(s, t)]
        log(line)
        if verdict != "PASS":
            status = max(status, 1 if verdict == "MISMATCH" else 2)
            if nightly:
                record_finding(commit, s, t, a.mcyc, a.seed, verdict, detail,
                               os.path.join(CACHE, "runs", f"{stamp}-{s}-{t}"))
    if nightly:
        with open(os.path.join(CACHE, "nightly.md"), "a") as f:
            for s, t in runs:
                f.write(f"- {stamp} main {commit[:10]}: {res[(s, t)][1]}\n")
    log(f"{('PASS' if status == 0 else 'MISMATCH' if status == 1 else 'BROKEN')} ({time.time() - t0:.0f} s)")
    return status


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--branch", default="", help="the RTL to check (default: this tree's, uncommitted changes too)")
    ap.add_argument("--shape", default="st", help="st, board, smp4 (M7's four harts), or a list")
    ap.add_argument("--timing", default="board", help="board, jitter, fixedN, default, or a list (one run each)")
    ap.add_argument("--mcyc", type=int, default=None, help=f"million cycles a run lasts at most (default {GATE_MCYC})")
    ap.add_argument("--seed", type=int, default=1, help="tb_boot's random seed (+verilator+seed+)")
    ap.add_argument("--jobs", type=int, default=8, help="make jobs for the builds")
    ap.add_argument("--boot-fw", default="", help="another fw_jump.bin than the pinned reference")
    ap.add_argument("--boot-kernel", default="", help="another Image than the pinned reference")
    ap.add_argument("--gate", action="store_true",
                    help=f"run only if the change against --base reaches the core's {', '.join(GATE_PATHS)}; "
                         f"then st at {GATE_MCYC}M with {' and '.join(GATE_TIMINGS)}")
    ap.add_argument("--base", default="", help="the gate's base: the change is what BRANCH (or HEAD) adds to its "
                                               "merge base with it (default main)")
    ap.add_argument("--nightly", action="store_true", help="the crontab's run (main; see the description)")
    ap.add_argument("--install-cron", action="store_true", help="add the nightly's crontab entry")
    ap.add_argument("--plant", type=int, default=None,
                    help="self-test: tanager-lockstep corrupts the first value it compares at or after this record, "
                         "so the run must end in a mismatch (the failure path, findings included)")
    # Every profile switch cycle-identical knows (its PROFILE_VARS), so a new one is never missing here; one this
    # table does not know yet takes any number and sim/profile.mk checks it
    for var, _ in ci.PROFILE_VARS:
        ap.add_argument(f"--{var.lower().replace('_', '-')}", type=int, choices=SWITCH_VALUES.get(var), default=None,
                        help=f"build the core with {var}")
    a = ap.parse_args()
    if a.install_cron:
        install_cron()
        return 0
    if not os.environ.get("RISCV_TESTS"):
        fail("source tools/env.sh first")
    tool = ci.toolchain_id()
    if a.nightly:
        return nightly(a, tool)
    if a.gate:
        # What the change itself brings: against its merge base with BASE (main), not BASE's tip, which may
        # have moved on (a diff against the tip would count main's newer files as the change's)
        base = a.base or "main"
        fork = ci.git("merge-base", base, a.branch or "HEAD")
        rtl, label = resolve(a)
        changed = [c for c in ci.git("diff", "--name-only", fork, rtl, "--", "rtl/core").splitlines()
                   if c.startswith(GATE_PATHS)]
        if not changed:
            log(f"gate: {label} changes nothing in the core's fetch, decode, rename, LSU, MMU or CSR against "
                f"{fork[:10]} (its merge base with {base}): skipped")
            return 0
        log(f"gate: {len(changed)} file(s) against {fork[:10]} (the merge base with {base}): "
            f"{', '.join(c[9:] for c in changed[:6])}{' ...' if len(changed) > 6 else ''}")
        a.shape, a.timing = "st", " ".join(GATE_TIMINGS)
    a.mcyc = a.mcyc or GATE_MCYC
    return checks(a, tool)


if __name__ == "__main__":
    sys.exit(main())
