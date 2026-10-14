#!/usr/bin/env python3
"""Cycle-identical check (docs/spec/verification.md §4.5; DR-123): does this tree's RTL behave exactly
like a base commit's, cycle by cycle?

  make cycle-identical CFG=st [BASE=<commit>] [SUITES=isa,stress,bench,random] [RANDN=200] [JOBS=8]
  tools/ci/cycle_identical.py --cfg st,smt2 --base main --suites isa,bench,random,reset

Builds tg_vsim twice with this tree's harness (sim/): once with this tree's rtl/ (the working tree as it
is, uncommitted and untracked files included) and once with the base's rtl/. Runs the same programs with
the same options in both and compares each run's cycle signature (tg_vsim --sig): per 1,024 cycles, a
hash of the commit trace and one of the core's TileLink outputs. For a run that differs, it reruns the
first differing window with full logs and prints the first differing line.

Suites (default isa,stress,bench,random):
  isa     riscv-tests (the regression's suites) and our directed tests, at native latency
  stress  the same programs with memory stress and trace back-pressure (settings drawn per test)
  bench   CoreMark A/B and Dhrystone, rv64im and rv64gcb, at native latency and latency 120
  random  RANDN tg_rand programs (rv64gc with F/D, else rv64imac), memory stress, timer interrupts on
          odd seeds, trace back-pressure on some
  reset   riscv-tests with random initial values in every register without a reset (--rand-reset)

BASE defaults to the merge base of HEAD and main. Builds and signatures are cached in
$TANAGER_BUILD/cycle-identical, shared by all worktrees: a second check against the same base reruns
only this tree's side. Exit status: 0 identical everywhere; 1 some run differs; 2 the check could not run.
"""
import argparse
import concurrent.futures as cf
import fcntl
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
WT = os.path.basename(ROOT)
TB = os.environ.get("TANAGER_BUILD", os.path.expanduser("~/tanager-build"))
CACHE = os.path.join(TB, "cycle-identical")
WORK = os.path.join(TB, WT, "cycle-identical")
KEEP_BUILDS = 12          # cached tg_vsim builds kept (least recently used go first)
NO_WALL_LIMIT = "--timeout=1000000000"  # a wall-clock stop would land on a load-dependent cycle

sys.path.insert(0, os.path.join(ROOT, "tests", "isa"))
sys.path.insert(0, os.path.join(ROOT, "tests", "random"))
import run_isa  # noqa: E402  (elf_symbol, tests_of, read_exclusions)
import run_random  # noqa: E402  (MARCH, stress_args)

# The regression's riscv-tests suites for the product core (tools/ci/regress.sh)
ISA_SUITES = ("rv64ui-p rv64um-p rv64ua-p rv64uc-p rv64uf-p rv64ud-p rv64mi-p rv64si-p rv64ui-v rv64um-v "
              "rv64ua-v rv64uc-v rv64uf-v rv64ud-v rv64uzba-v rv64uzbb-v rv64uzbs-v rv64uzicond-v").split()


def log(msg):
    print(msg, flush=True)


def fail(msg):
    print(f"cycle-identical: {msg}", file=sys.stderr, flush=True)
    sys.exit(2)


def git(*args, env=None):
    p = subprocess.run(["git", *args], cwd=ROOT, env=env, capture_output=True, text=True)
    if p.returncode:
        fail(f"git {' '.join(args)}: {p.stderr.strip()}")
    return p.stdout.strip()


def worktree_tree():
    """The working tree's rtl/ and sim/ as a tree object, written through a temporary index (the
    worktree's own index and files are not touched)."""
    with tempfile.TemporaryDirectory() as d:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(d, "index"))
        git("read-tree", "HEAD", env=env)
        git("add", "-A", "--", "rtl", "sim", env=env)
        return git("write-tree", env=env)


def toolchain_id():
    """What else goes into a tg_vsim build: Verilator, the compiler and Spike's library."""
    parts = []
    for cmd in (["verilator", "--version"], [os.environ.get("CXX", "g++-15"), "--version"]):
        try:
            parts.append(subprocess.run(cmd, capture_output=True, text=True).stdout.splitlines()[0])
        except (OSError, IndexError):
            parts.append("?")
    lib = os.path.join(os.environ.get("SPIKE_ROOT", os.path.expanduser("~/opt/tanager/spike")), "lib", "libriscv.so")
    try:
        st = os.stat(os.path.realpath(lib))
        parts.append(f"{os.path.realpath(lib)}:{st.st_size}:{int(st.st_mtime)}")
    except OSError:
        parts.append("no-spike")
    return "|".join(parts)


def sha1(*parts):
    h = hashlib.sha1()
    for p in parts:
        h.update(p if isinstance(p, bytes) else str(p).encode())
        h.update(b"\0")
    return h.hexdigest()


class Side:
    """One side of the comparison: an rtl/ tree and a sim/ tree, built for one configuration."""

    def __init__(self, name, rtl_src, sim_src, cfg, tool):
        self.name, self.cfg = name, cfg
        self.rtl_src, self.sim_src = rtl_src, sim_src      # tree-ishes for git archive
        self.rtl_tree = git("rev-parse", f"{rtl_src}:rtl")
        self.sim_tree = git("rev-parse", f"{sim_src}:sim")
        self.key = sha1(self.rtl_tree, self.sim_tree, cfg, "core", tool)[:16]
        self.dir = os.path.join(CACHE, "build", self.key)
        self.bin = os.path.join(self.dir, "tg_vsim")
        self.sigdir = os.path.join(self.dir, "sig")

    def built(self):
        return os.path.exists(self.bin)

    def build(self, jobs):
        os.makedirs(os.path.dirname(self.dir), exist_ok=True)
        with open(self.dir + ".lock", "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)  # another check may be building the same tree
            if self.built():
                return None
            src, obj = os.path.join(self.dir, "src"), os.path.join(self.dir, "obj")
            shutil.rmtree(self.dir, ignore_errors=True)
            os.makedirs(src)
            for treeish, path in ((self.rtl_src, "rtl"), (self.sim_src, "sim")):
                a = subprocess.Popen(["git", "archive", treeish, path], cwd=ROOT, stdout=subprocess.PIPE)
                subprocess.run(["tar", "-x", "-C", src], stdin=a.stdout, check=True)
                if a.wait():
                    return f"git archive {treeish} {path} failed"
            # Paths under the build directory reach ccache relative to it, so builds of other trees hit.
            env = clean_env(CCACHE_BASEDIR=self.dir)
            t0 = time.time()
            p = subprocess.run(["make", "-s", "-C", os.path.join(src, "sim"), f"CFG={self.cfg}", "CORE=core",
                                f"JOBS={jobs}", f"BUILD={obj}", "build"], env=env, capture_output=True, text=True)
            if os.path.exists(os.path.join(obj, "build.log")):
                shutil.copy(os.path.join(obj, "build.log"), os.path.join(self.dir, "build.log"))
            if p.returncode or not os.path.exists(os.path.join(obj, "tg_vsim")):
                with open(os.path.join(self.dir, "make.log"), "w") as f:
                    f.write(p.stdout + p.stderr)
                shutil.rmtree(src, ignore_errors=True)
                return f"build failed: {os.path.join(self.dir, 'make.log')}"
            os.rename(os.path.join(obj, "tg_vsim"), self.bin)
            shutil.rmtree(obj, ignore_errors=True)
            shutil.rmtree(src, ignore_errors=True)
            with open(os.path.join(self.dir, "info"), "w") as f:
                f.write(f"rtl {self.rtl_tree} from {self.rtl_src}\nsim {self.sim_tree} from {self.sim_src}\n"
                        f"cfg {self.cfg}\nbuilt in {time.time() - t0:.0f} s\n")
            return None


def prune_builds(keep_keys):
    """Keep the KEEP_BUILDS most recently used builds, and any used in the last hour: a check marks its
    builds when it starts, so a running check never loses its binary."""
    bdir = os.path.join(CACHE, "build")
    dirs = [d for d in os.listdir(bdir) if os.path.isdir(os.path.join(bdir, d))]
    dirs.sort(key=lambda d: os.path.getmtime(os.path.join(bdir, d)), reverse=True)
    for d in dirs[KEEP_BUILDS:]:
        if d in keep_keys or time.time() - os.path.getmtime(os.path.join(bdir, d)) < 3600:
            continue
        lock = os.path.join(bdir, d + ".lock")
        with open(lock, "w") as lk:
            try:
                fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue
            shutil.rmtree(os.path.join(bdir, d), ignore_errors=True)
        os.remove(lock)


# ---- Programs ----

def clean_env(**extra):
    """The environment for a sub-make: no variables from a calling make (MAKEFLAGS carries its command
    line) and none of the names the sim build reads from its own command line only."""
    env = dict(os.environ, **extra)
    for v in ("ISA", "PRIV", "PMP", "MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES"):
        env.pop(v, None)
    return env


def make(*args):
    p = subprocess.run(["make", "-s", "--no-print-directory", *args], cwd=ROOT, capture_output=True, text=True,
                       env=clean_env())
    if p.returncode:
        fail(f"make {' '.join(args)}:\n{(p.stdout + p.stderr)[-2000:]}")
    return p.stdout.strip()


def has_fd():
    pkg = os.path.join(ROOT, "rtl", "core", "tg_core_pkg.sv")
    try:
        text = open(pkg).read()
    except OSError:
        return False
    return "EXT_FD" in text and not any("EXT_FD" in l and "1'b0" in l for l in text.splitlines()
                                        if "localparam" in l)


def isa_programs(cfg, args_of):
    """riscv-tests of the regression's suites and our directed tests: (name, elf, args)."""
    tdir = os.path.join(os.environ.get("RISCV_TESTS", ""), "isa")
    if not os.path.isdir(tdir):
        fail("RISCV_TESTS is not set or has no isa/: source tools/env.sh first")
    excl = run_isa.read_exclusions([os.path.join(ROOT, "tests", "isa", "exclude", f)
                                    for f in ("tanager.txt", f"{cfg}.txt")])
    out = []
    for i, (_, t) in enumerate(run_isa.tests_of(tdir, ISA_SUITES)):
        if t in excl:
            continue
        path = os.path.join(tdir, t)
        extra = []
        if "-v-" in t:
            th = run_isa.elf_symbol(path, "tohost")
            if th is not None:
                extra.append("--tohost-va=0x%x" % ((th - run_isa.DRAM_BASE - run_isa.MEGAPAGE) & (2**64 - 1)))
        out.append((t, path, args_of(i, False) + extra))
    make("-C", "tests/isa", "build-directed")
    ddir = os.path.join(TB, WT, "directed")
    for i, t in enumerate(sorted(f for f in os.listdir(ddir) if f.startswith("tanager-p-"))):
        out.append((t, os.path.join(ddir, t), args_of(1000 + i, True)))
    return out


def bench_programs():
    out = []
    for march in ("rv64im", "rv64gcb"):
        make("-C", "tests/bench", f"MARCH={march}", "build")
        odir = make("-C", "tests/bench", f"MARCH={march}", "print-out")
        for p in ("coremark_A", "coremark_B", "dhrystone"):
            for lat in ("native", "120"):
                out.append((f"{p}-{march}-lat{lat}", os.path.join(odir, p + ".elf"), [f"--lat={lat}"]))
    return out


def random_programs(n, jobs):
    isa = "rv64gc" if has_fd() else "rv64imac"
    gen = os.path.join(ROOT, "tests", "random", "tg_rand.py")
    ld = os.path.join(ROOT, "tests", "random", "link.ld")
    gdir = os.path.join(WORK, "random", f"{isa}-{sha1(open(gen, 'rb').read(), open(ld, 'rb').read())[:12]}")
    os.makedirs(gdir, exist_ok=True)

    def one(seed):
        irq = 200 if seed % 2 else 0
        elf = os.path.join(gdir, f"r{seed}-irq{irq}.elf")
        if not os.path.exists(elf):
            s = elf[:-4] + ".S"
            subprocess.run([sys.executable, gen, "--seed", str(seed), "--isa", isa, "--irq", str(irq),
                            "--length", "400", "-o", s], check=True, capture_output=True)
            subprocess.run(["riscv-none-elf-gcc", *run_random.MARCH[isa].split(), "-nostdlib", "-nostartfiles",
                            "-static", "-mcmodel=medany", "-T", ld, s, "-o", elf + ".tmp"], check=True,
                           capture_output=True)
            os.rename(elf + ".tmp", elf)
            os.remove(s)
        return (f"r{seed}-{isa}{'-irq' if irq else ''}", elf, run_random.stress_args(seed, irq, True))

    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        try:
            return list(ex.map(one, range(1, n + 1)))
        except subprocess.CalledProcessError as e:
            fail(f"generating random programs: {' '.join(e.cmd)}: {e.stderr.decode(errors='replace')[-500:]}")


def programs(suites, cfg, randn, jobs):
    out = []
    for s in suites:
        if s == "isa":
            out += [("isa",) + p for p in isa_programs(cfg, lambda i, d: ["--lat=native"] +
                                                       (["--irq-rand=5"] if d else []))]
        elif s == "stress":
            def stress(i, d):
                a = [x for x in run_random.stress_args(i + 1, 0, True) if not x.startswith("--trace-stall")]
                return a + ["--trace-stall=50"] + (["--irq-rand=5"] if d else [])
            out += [("stress",) + p for p in isa_programs(cfg, stress)]
        elif s == "reset":
            out += [("reset",) + p for p in isa_programs(cfg, lambda i, d: ["--lat=native", "--rand-reset",
                                                                            f"--seed={i + 1}"] +
                                                         (["--irq-rand=5"] if d else []))]
        elif s == "bench":
            out += [("bench",) + p for p in bench_programs()]
        elif s == "random":
            out += [("random",) + p for p in random_programs(randn, jobs)]
        else:
            fail(f"unknown suite {s} (isa, stress, bench, random, reset)")
    return out


# ---- Runs and signatures ----

def read_sig(path):
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    return lines if lines and lines[-1].startswith("end ") else None


def run_side(side, elf, args, extra, timeout):
    """The signature of one run (cached per build, program and options); None and a reason on a crash."""
    key = sha1(open(elf, "rb").read(), *args, *extra)
    sig = os.path.join(side.sigdir, key[:2], key + ".sig")
    lines = read_sig(sig)
    if lines is not None:
        return lines, None, True
    os.makedirs(os.path.dirname(sig), exist_ok=True)
    tmp = f"{sig}.{os.getpid()}.{threading.get_ident()}"
    cmd = [side.bin, "--quiet", NO_WALL_LIMIT, *args, *extra, f"--sig={tmp}", elf]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=timeout)
        err = p.stderr
    except subprocess.TimeoutExpired:
        err = f"no result after {timeout} s of wall-clock time"
    lines = read_sig(tmp)
    if lines is None:
        if os.path.exists(tmp):
            os.remove(tmp)
        return None, (err.strip().splitlines() or ["the run ended without a signature"])[-1], False
    os.replace(tmp, sig)
    return lines, None, False


def parse_end(lines):
    kv = dict(x.split("=", 1) for x in lines[-1].split()[1:])
    return int(kv.get("cycles", 0)), kv.get("status", "?")


def first_diff(a, b):
    """Index of the first differing signature line, and the cycle window it covers."""
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            break
    else:
        i = min(len(a), len(b))
    prev = 0
    for line in a[1:i]:
        prev = int(line.split()[0])
    return i, prev


def explain(base, branch, elf, args, extra, start, end, outdir, name):
    """Rerun cycles start..end-1 of both sides with full logs; the first differing log line."""
    os.makedirs(outdir, exist_ok=True)
    logs = {}
    for side in (base, branch):
        lg = os.path.join(outdir, f"{name}.{side.name}.log")
        cmd = [side.bin, "--quiet", NO_WALL_LIMIT, *args, *(extra if side is branch else []), f"--log={lg}",
               f"--log-from={start}", "--log-bus", f"--cycles={end}", elf]
        subprocess.run(cmd, capture_output=True, timeout=7200)
        logs[side.name] = (lg, open(lg, errors="replace").read().splitlines() if os.path.exists(lg) else [])
    (la, a), (lb, b) = logs["base"], logs["branch"]
    i = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
    ctx = [f"    = {x}" for x in a[max(0, i - 3):i]]
    ctx += [f"    base   {x}" for x in a[i:i + 3]] or ["    base   (no more lines)"]
    ctx += [f"    branch {x}" for x in b[i:i + 3]] or ["    branch (no more lines)"]
    return ctx, la, lb


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cfg", default="st", help="configurations, comma- or space-separated (st smt2 st_w3 smt2_w3)")
    ap.add_argument("--base", default="", help="the base commit (default: merge base of HEAD and main)")
    ap.add_argument("--suites", default="isa,stress,bench,random")
    ap.add_argument("--randn", type=int, default=200, help="random programs")
    ap.add_argument("--jobs", type=int, default=8, help="parallel runs, and make jobs across both builds")
    ap.add_argument("--harness", choices=("branch", "own"), default="branch",
                    help="the base side's sim/: this tree's (default) or the base commit's")
    ap.add_argument("--branch-args", default="",
                    help="extra tg_vsim options for this tree's side only (to check that the tool sees a difference)")
    ap.add_argument("--timeout", type=int, default=3600, help="wall-clock seconds per run before it counts as broken")
    ap.add_argument("--show", type=int, default=5, help="differing runs to explain in detail")
    a = ap.parse_args()

    if not os.environ.get("RISCV_TESTS"):
        fail("source tools/env.sh first")
    cfgs = a.cfg.replace(",", " ").split()
    suites = a.suites.replace(",", " ").split()
    extra = a.branch_args.split()
    base_commit = a.base or git("merge-base", "HEAD", "main")
    base_commit = git("rev-parse", "--verify", f"{base_commit}^{{commit}}")
    head = git("rev-parse", "--short", "HEAD")
    tree = worktree_tree()
    dirty = git("diff", "--stat", "HEAD", tree, "--", "rtl", "sim").strip()
    changed = git("diff", "--name-only", base_commit, tree, "--", "rtl").splitlines()
    tool = toolchain_id()
    log(f"cycle-identical: base {base_commit[:10]} ({git('log', '-1', '--format=%s', base_commit)[:70]})")
    log(f"  this tree: {WT} at {head}{' with uncommitted changes' if dirty else ''}; "
        f"{len(changed)} rtl file(s) differ from the base{': ' + ', '.join(c[4:] for c in changed[:6]) if changed else ''}"
        f"{' ...' if len(changed) > 6 else ''}")
    if not changed:
        log("  (the RTL is the base's: identical by construction; the runs still check the tool)")
    os.makedirs(WORK, exist_ok=True)

    t_start = time.time()
    all_ok, any_broken = True, False
    for cfg in cfgs:
        base = Side("base", base_commit, tree if a.harness == "branch" else base_commit, cfg, tool)
        branch = Side("branch", tree, tree, cfg, tool)
        need = [s for s in {base.key: base, branch.key: branch}.values() if not s.built()]
        t0 = time.time()
        if need:
            log(f"[{cfg}] building tg_vsim for {' and '.join(s.name for s in need)} "
                f"(-j{max(1, a.jobs // len(need))} each)...")
            with cf.ThreadPoolExecutor(max_workers=2) as ex:
                errs = list(ex.map(lambda s: s.build(max(1, a.jobs // len(need))), need))
            for s, e in zip(need, errs):
                if e:
                    fail(f"[{cfg}] {s.name}: {e}")
            log(f"[{cfg}] built in {time.time() - t0:.0f} s")
        for s in (base, branch):
            os.utime(s.dir)  # most recently used
        prune_builds({base.key, branch.key})

        progs = programs(suites, cfg, a.randn, a.jobs)
        log(f"[{cfg}] {len(progs)} programs x 2 sides ({', '.join(suites)})...")
        t1 = time.time()
        jobs = [(i, s) for i in range(len(progs)) for s in (base, branch)]
        res = {}
        with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
            futs = {ex.submit(run_side, s, progs[i][2], progs[i][3], extra if s is branch else [], a.timeout):
                    (i, s.name) for i, s in jobs}
            for fu in cf.as_completed(futs):
                res[futs[fu]] = fu.result()
        cached = sum(1 for r in res.values() if r[2])

        per_suite = {}
        diffs, broken, base_failed = [], [], 0
        for i, p in enumerate(progs):
            suite, name, elf, args = p
            (sa, ea, _), (sb, eb, _) = res[(i, "base")], res[(i, "branch")]
            st = per_suite.setdefault(suite, [0, 0, 0, 0, 0])  # programs, identical, differ, cycles: base, branch
            st[0] += 1
            if sa is None or sb is None:
                broken.append((p, ea or eb, "base" if sa is None else "branch"))
                continue
            ca, status_a = parse_end(sa)
            cb, _ = parse_end(sb)
            st[3] += ca
            st[4] += cb
            if status_a != "PASS":
                base_failed += 1
            if sa == sb:
                st[1] += 1
            else:
                st[2] += 1
                diffs.append((p, sa, sb))

        outdir = os.path.join(WORK, cfg)
        shutil.rmtree(outdir, ignore_errors=True)
        os.makedirs(outdir)
        rep = open(os.path.join(outdir, "report.txt"), "w")

        def out(line, console=True):
            rep.write(line + "\n")
            if console:
                log(line)

        out(f"[{cfg}] {'suite':8s} {'programs':>8s} {'identical':>9s} {'differ':>6s} {'cycles':>9s} {'change':>8s}")
        for suite, (n, ok, nd, ca, cb) in per_suite.items():
            out(f"[{cfg}] {suite:8s} {n:8d} {ok:9d} {nd:6d} {ca / 1e6:8.2f}M "
                f"{'0' if ca == cb else f'{100.0 * (cb - ca) / max(1, ca):+.3f}%':>8s}")
        out(f"[{cfg}] runs took {time.time() - t1:.0f} s ({cached} of {len(jobs)} signatures from the cache)")
        if base_failed:
            out(f"[{cfg}] note: {base_failed} base run(s) did not pass; they are compared all the same")
        for p, why, side in broken:
            any_broken = True
            out(f"[{cfg}] BROKEN {p[0]}/{p[1]}: the {side} run gave no signature: {why}"
                + (" (a base harness older than tg_vsim --sig? drop --harness own)"
                   if side == "base" and a.harness == "own" else ""))
        for k, (p, sa, sb) in enumerate(diffs):
            suite, name, elf, args = p
            i, start = first_diff(sa, sb)
            ca, status_a = parse_end(sa)
            cb, status_b = parse_end(sb)
            what = "the run's end"
            end = max(ca, cb) + 1
            if i < len(sa) - 1 and i < len(sb) - 1:
                fa, fb = sa[i].split(), sb[i].split()
                end = int(fa[0])
                parts = []
                if fa[1:4] != fb[1:4]:
                    parts.append(f"commit trace ({fa[1]} -> {fb[1]} records)")
                if fa[4:6] != fb[4:6]:
                    parts.append(f"TileLink ({fa[4]} -> {fb[4]} events)")
                what = " and ".join(parts) or "window"
            status = "" if status_a == status_b else f", status {status_a} -> {status_b}"
            show = k < a.show + 20
            out(f"[{cfg}] DIFF {suite}/{name}: cycles {ca} -> {cb} ({cb - ca:+d}){status}; "
                f"first difference in cycles {start}..{end - 1}: {what}", show)
            if k < a.show:
                ctx, la, lb = explain(base, branch, elf, args, extra, start, end, outdir, f"{suite}-{name}")
                for c in ctx:
                    out(c)
                out(f"    logs: {la} {lb}")
                out(f"    rerun: {branch.bin} {' '.join(args + extra)} --log=FILE --log-from={start} --log-bus "
                    f"--cycles={end} {elf}  (base: {base.bin})")
        if len(diffs) > a.show + 20:
            log(f"[{cfg}] ... and {len(diffs) - a.show - 20} more differences")
        if diffs or broken:
            all_ok = False
        out(f"[{cfg}] {'IDENTICAL' if not diffs and not broken else 'NOT IDENTICAL'}: "
            f"{len(progs) - len(diffs) - len(broken)} of {len(progs)} programs identical"
            f"{f', {len(diffs)} differ' if diffs else ''}{f', {len(broken)} broken' if broken else ''}"
            f"; report: {rep.name}")
        rep.close()
    log(f"cycle-identical: {'PASS' if all_ok else 'FAIL'} ({', '.join(cfgs)}; base {base_commit[:10]}; "
        f"{time.time() - t_start:.0f} s)")
    return 0 if all_ok else (2 if any_broken else 1)


if __name__ == "__main__":
    sys.exit(main())
