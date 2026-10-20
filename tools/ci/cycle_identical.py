#!/usr/bin/env python3
"""Cycle-identical check (docs/spec/verification.md §4.5; DR-123): does this tree's RTL behave exactly
like a base commit's, cycle by cycle?

  make cycle-identical CFG=st [BASE=<commit>] [SUITES=isa,stress,bench,random] [RANDN=200] [BOOT=N] [JOBS=8]
  tools/ci/cycle_identical.py --cfg st,smt2 --base main --suites isa,bench,random,reset --boot 20

Builds the simulators twice with this tree's harness (sim/): once with this tree's rtl/ (the working tree
as it is, uncommitted and untracked files included; or --branch REF's) and once with the base's rtl/.
If the base's rtl/ does not build with this harness (the harness uses something new in an RTL package),
the base side takes the base's own sim/ instead and says so (--harness auto, the default; branch forbids
the fallback, own always uses the base's).
Runs the same programs with the same options on both and compares each run's cycle signature: per 1,024
cycles, a hash of the commit trace and of the design's outputs. For a run that differs, it reruns the
first differing window with full logs and prints the first differing line.

Suites of tg_vsim, the core with TileLink models (default isa,stress,bench,random; "none" for none):
  isa     riscv-tests (the regression's suites) and our directed tests, at native latency
  stress  the same programs with memory stress and trace back-pressure (settings drawn per test)
  bench   CoreMark A/B and Dhrystone, rv64im and rv64gcb, at native latency and latency 120
  random  RANDN tg_rand programs (rv64gc with F/D, else rv64imac), a third in S-mode under Sv39, memory
          stress, timer interrupts on odd seeds, trace back-pressure on some
  reset   riscv-tests with random initial values in every register without a reset (--rand-reset)
With --boot N, also the Linux boot's first N million cycles on the whole SoC: tests/unit/boot's tb_boot
(--boot-tree REF for another tree's), with sim/tb/tg_soc_sig.sv bound into tanager_soc, for the uncore
and anything the programs miss. Without --boot, a change to rtl/uncore, rtl/soc or rtl/common (whose
packages and primitives the uncore uses too) boots 3 million cycles with two cores; --boot 0 skips it.

TIMING_CUTS=0|1 (--timing-cuts) builds both sides in that profile of the core's timing cuts (DR-140;
sim/profile.mk), tg_vsim and the boot's tb_boot alike; BRANCH_TIMING_CUTS (--branch-timing-cuts) sets this
side's only, for example 0 to show the all-off fallback is cycle-identical to a base without the switches.
The boot takes the profile through tests/unit/boot's Makefile, which reads sim/profile.mk (DR-141 rule 1:
a cycle cost is reported on the Linux boot by profile). DC_MSHRS=1|4 (--dc-mshrs) and BRANCH_DC_MSHRS
(--branch-dc-mshrs) do the same for the L1D's misses in flight (DR-149): BRANCH_DC_MSHRS=4 against a base
of one MSHR measures the 4-miss L1D; and QUEUE_DECODE=0|1 (--queue-decode) and BRANCH_QUEUE_DECODE
(--branch-queue-decode) for G8's instruction-queue decode bits; PMP_ENTRIES=8|16 (--pmp-entries) and
BRANCH_PMP_ENTRIES for the core's PMP entries (DR-167): BRANCH_PMP_ENTRIES=16 against a base of 16 checks the
switch at 16 (each side's lockstep has as many PMP regions as its own model reports). None of these names
reaches a build from the environment, only as a make variable of sim/profile.mk, which the cache key and the
build's info file name.

BASE defaults to the merge base of HEAD and main. Builds and signatures are cached in
$TANAGER_BUILD/cycle-identical, shared by all worktrees: a second check against the same base reruns
only this tree's side. Exit status: 0 identical everywhere; 1 some run differs; 2 the check could not run.
"""
import argparse
import concurrent.futures as cf
import fcntl
import glob
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
KEEP_BUILDS = 12          # cached builds kept (least recently used go first)
NO_WALL_LIMIT = "--timeout=1000000000"  # a wall-clock stop would land on a load-dependent cycle
BOOT_EXPECT = "TANAGER-BOOT-OK"          # tb_boot ends early if the boot gets there
BOOT_DTS = ("MEM=0x08000000", "FPU=1", "BOOTARGS=console=ttyS0,115200 earlycon")  # as tests/unit/boot's linux target
AUTO_BOOT = 3                            # million cycles, when the change reaches the uncore
# The boot's images (the coordinator, 2026-10-19): OpenSBI's fw_jump.bin from the SoC track's tree and the
# protected reference Image (sw/build_linux.sh rebuilds it only with BR_REBUILD_REFERENCE=1), each pinned by
# its sha256. The boot runs them, and refuses one whose content has changed, unless --boot-fw or
# --boot-kernel (BOOT_FW, BOOT_KERNEL) names a file. Before this it took the newest file under
# $TANAGER_BUILD, and a track's own OpenSBI build (10-19, 02:04-02:26) became every boot's firmware.
REF_IMAGES = {
    "fw": ("OpenSBI's fw_jump.bin",
           os.path.join(TB, "track-soc-160053", "opensbi", "platform", "generic", "firmware", "fw_jump.bin"),
           "b0094d235a36f8bdb857c97d5d60e28bb3852d20a418c9cc3efa45710c0679bb"),
    "kernel": ("the Linux Image",
               os.path.join(TB, "track-soc-160053", "br-tanager_lp64d", "images", "Image"),
               "cea2bf6694672c687ad2587772660d6d268e240b97032f47a0f391097735addf"),
}
RANDOM_VM = 33                           # share of the random programs in S-mode under Sv39 (as the soak's)
UNCORE_PATHS = ("rtl/uncore/", "rtl/soc/", "rtl/common/")

sys.path.insert(0, os.path.join(ROOT, "tests", "isa"))
sys.path.insert(0, os.path.join(ROOT, "tests", "random"))
import run_isa  # noqa: E402  (elf_symbol, tests_of, read_exclusions)
import run_random  # noqa: E402  (MARCH, stress_args)
import host_policy  # noqa: E402  (tools/ci: the runners' share of a hybrid host)

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


# The make variables of sim/profile.mk this check can force, with each one's tag in the cache key (the order
# keeps the keys of builds made before the later ones were added)
PROFILE_VARS = (("TIMING_CUTS", "tc"), ("DC_MSHRS", "dcm"), ("QUEUE_DECODE", "qd"), ("SPEC_WAKE", "sw"),
                ("STA_BASE", "sb"), ("STEER_LA", "sl"), ("PMP_ENTRIES", "pmp"), ("STORE_PF", "spf"), ("URF", "urf"),
                ("STORE_PF_MAX", "spm"), ("SOLO_TID", "solo"), ("SPLIT", "sp"))


def profile_takes(ref, var):
    """Whether ref's sim/profile.mk takes var; one without it would drop it without a word."""
    return (git("ls-tree", "--name-only", ref, "sim/profile.mk") != "" and
            var in git("show", f"{ref}:sim/profile.mk"))


def worktree_tree():
    """The working tree's rtl/, sim/ and tests/unit/ as a tree object, written through a temporary
    index (the worktree's own index and files are not touched)."""
    with tempfile.TemporaryDirectory() as d:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(d, "index"))
        git("read-tree", "HEAD", env=env)
        git("add", "-A", "--", "rtl", "sim", "tests/unit", env=env)
        return git("write-tree", env=env)


def toolchain_id():
    """What else goes into a build: Verilator, the compiler and Spike's library."""
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


_digests = {}


def file_digest(path):
    """sha1 of a file's content, computed once per run of this script."""
    st = os.stat(path)
    k = (path, st.st_size, st.st_mtime_ns)
    if k not in _digests:
        h = hashlib.sha1()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        _digests[k] = h.hexdigest()
    return _digests[k]


def clean_env(**extra):
    """The environment for a sub-make: no variables from a calling make (MAKEFLAGS carries its command
    line) and none of the names the sim build reads from its own command line only."""
    env = dict(os.environ, **extra)
    for v in ("ISA", "PRIV", "PMP", *(v for v, _ in PROFILE_VARS), "MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES"):
        env.pop(v, None)
    return env


class Side:
    """One side of the comparison for one configuration: tg_vsim ("vsim"), or tests/unit/boot's tb_boot
    with tg_soc_sig bound into the SoC ("boot"). `srcs` are (tree-ish, path) pairs for git archive."""

    def __init__(self, name, kind, cfg, tool, rtl_src, harness_src, tb_src=None, cores=1, prof=None):
        self.name, self.kind, self.cfg, self.cores = name, kind, cfg, cores
        prof = {v: x for v, x in (prof or {}).items() if x is not None}
        self.args = (kind, cfg, tool, rtl_src, harness_src, tb_src, cores, prof)  # to rebuild with another harness
        self.harness_src = harness_src
        # The make variables of sim/profile.mk forced on this side (PROFILE_VARS: the core's timing cuts,
        # DR-140; the L1D's misses in flight, DR-149; G8's queue decode bits); the rest take the package's
        # default. Part of the key only when forced, so the default's cached builds stay valid. The boot
        # reads them through tests/unit/boot's Makefile, which includes sim/profile.mk: archived when any is.
        self.prof = [f"{v}={prof[v]}" for v, _ in PROFILE_VARS if v in prof]
        if kind == "vsim":
            self.srcs = [(rtl_src, "rtl"), (harness_src, "sim")]
        else:
            self.srcs = [(rtl_src, "rtl"), (harness_src, "sim/tb"), (tb_src, "tests/unit")]
            if self.prof:
                self.srcs.append((harness_src, "sim/profile.mk"))
        trees = [git("rev-parse", f"{src}:{path}") for src, path in self.srcs]
        self.key = sha1(kind, *trees, cfg, cores, tool, *(f"{t}{prof[v]}" for v, t in PROFILE_VARS if v in prof))[:16]
        self.dir = os.path.join(CACHE, "build", self.key)
        self.bin = os.path.join(self.dir, "tg_vsim" if kind == "vsim" else "tb_boot")
        self.sigdir = os.path.join(self.dir, "sig")

    def built(self):
        return os.path.exists(self.bin)

    def hold(self):
        """A shared lock on this build for the rest of the check, and the build marked as used. Another
        worktree's check prunes the cache by taking the lock exclusively without waiting, so it skips a
        build that a check holds (it once removed one between this check's look and its first run)."""
        os.makedirs(os.path.dirname(self.dir), exist_ok=True)
        self._lk = open(self.dir + ".lock", "a")
        fcntl.flock(self._lk, fcntl.LOCK_SH)
        if os.path.isdir(self.dir):
            os.utime(self.dir)

    def release(self):
        if getattr(self, "_lk", None):
            self._lk.close()  # closing the file drops the lock
            self._lk = None

    def build(self, jobs):
        os.makedirs(os.path.dirname(self.dir), exist_ok=True)
        with open(self.dir + ".lock", "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)  # another check may be building the same tree
            if self.built():
                return None
            src, obj = os.path.join(self.dir, "src"), os.path.join(self.dir, "obj")
            shutil.rmtree(self.dir, ignore_errors=True)
            os.makedirs(src)
            for treeish, path in self.srcs:
                a = subprocess.Popen(["git", "archive", treeish, path], cwd=ROOT, stdout=subprocess.PIPE)
                subprocess.run(["tar", "-x", "-C", src], stdin=a.stdout, check=True)
                if a.wait():
                    return f"git archive {treeish} {path} failed"
            # Paths under the build directory reach ccache relative to it, so builds of other trees hit.
            env = clean_env(CCACHE_BASEDIR=self.dir)
            t0 = time.time()
            if self.kind == "vsim":
                cmd = ["make", "-s", "-C", os.path.join(src, "sim"), f"CFG={self.cfg}", "CORE=core", f"JOBS={jobs}",
                       f"BUILD={obj}", *self.prof, "build"]
            else:
                # One Verilator thread: a threaded model maps the memory models' random draws to threads
                # by its own partition, which a change elsewhere in the design can move.
                bdir = os.path.join(src, "tests", "unit", "boot")
                tb = " ".join(os.path.join(src, f) for f in ("tests/unit/boot/tb_boot.sv", "sim/tb/tg_soc_sig.sv",
                                                              "sim/tb/tg_soc_sig_bind.sv"))
                cmd = ["make", "-s", "-C", bdir, f"CFG={self.cfg}", f"CORES={self.cores}", "VTHREADS=1",
                       f"JOBS={jobs}", f"SOC_BUILD={obj}", f"TB={tb}",
                       *self.prof, "build"]
            p = subprocess.run(cmd, env=env, capture_output=True, text=True)
            made = (glob.glob(os.path.join(obj, "tg_vsim")) if self.kind == "vsim" else
                    glob.glob(os.path.join(obj, "tests", "*", "tb_boot")))
            logs = glob.glob(os.path.join(obj, "build.log")) + glob.glob(os.path.join(obj, "tests", "*", "build.log"))
            if logs:
                shutil.copy(logs[0], os.path.join(self.dir, "build.log"))
            if p.returncode or len(made) != 1:
                with open(os.path.join(self.dir, "make.log"), "w") as f:
                    f.write(" ".join(cmd) + "\n" + p.stdout + p.stderr)
                shutil.rmtree(src, ignore_errors=True)
                shutil.rmtree(obj, ignore_errors=True)
                return f"build failed: {os.path.join(self.dir, 'make.log')}"
            os.rename(made[0], self.bin)
            shutil.rmtree(obj, ignore_errors=True)
            shutil.rmtree(src, ignore_errors=True)
            with open(os.path.join(self.dir, "info"), "w") as f:
                f.write("".join(f"{path} from {treeish}\n" for treeish, path in self.srcs) +
                        f"{self.kind} cfg {self.cfg} cores {self.cores}"
                        f"{''.join(' ' + p for p in self.prof)}\nbuilt in {time.time() - t0:.0f} s\n")
            return None


def build_all(sides, jobs, cfg):
    """Holds every build the check uses (Side.hold) and builds the missing ones; returns {key: error} for
    the builds that failed. The sides of one key share a Side's lock: flock conflicts between two open
    files even in one process."""
    uniq = {}
    for s in sides:
        uniq.setdefault(s.key, s)
    for s in uniq.values():
        s.hold()
    need = [s for s in uniq.values() if not s.built()]
    if need:
        t0 = time.time()
        each = max(1, jobs // len(need))
        log(f"[{cfg}] building {', '.join(f'{s.kind} for {s.name}' for s in need)} (-j{each} each)...")
        for s in need:
            s.release()  # building takes the lock exclusively
        with cf.ThreadPoolExecutor(max_workers=len(need)) as ex:
            errs = list(ex.map(lambda s: s.build(each), need))
        failed = {}
        for s, e in zip(need, errs):
            if e:
                failed[s.key] = f"{s.kind} for {s.name}: {e}"
            else:
                s.hold()
        log(f"[{cfg}] built in {time.time() - t0:.0f} s{f' ({len(failed)} failed)' if failed else ''}")
        return failed
    return {}


def prune_builds(keep_keys):
    """Keep the KEEP_BUILDS most recently used builds, any used in the last hour, and any that a running
    check holds (Side.hold): a build is removed only under its lock, taken exclusively without waiting,
    and only if it was not used since the listing. Lock files stay: removing one would let two checks
    lock different files of the same name."""
    bdir = os.path.join(CACHE, "build")
    age = lambda d: time.time() - os.path.getmtime(os.path.join(bdir, d))
    ages = {}
    for d in os.listdir(bdir):
        try:
            if os.path.isdir(os.path.join(bdir, d)):
                ages[d] = age(d)
        except FileNotFoundError:
            pass  # another check's prune removed it meanwhile
    for d in sorted(ages, key=ages.get)[KEEP_BUILDS:]:
        if d in keep_keys:
            continue
        with open(os.path.join(bdir, d + ".lock"), "a") as lk:
            try:
                fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue  # held or being built
            try:
                if age(d) < 3600:
                    continue
            except FileNotFoundError:
                continue
            shutil.rmtree(os.path.join(bdir, d), ignore_errors=True)


# ---- Programs: (suite, name, kind, payload); payload (elf, args) for vsim, (plusargs, files) for boot ----

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
                            "--length", "400", "--vm", str(RANDOM_VM), "-o", s], check=True, capture_output=True)
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


def vsim_programs(suites, cfg, randn, jobs):
    out = []

    def add(suite, progs):
        out.extend((suite, name, "vsim", (elf, args)) for name, elf, args in progs)

    for s in suites:
        if s == "none":
            continue
        if s == "isa":
            add("isa", isa_programs(cfg, lambda i, d: ["--lat=native"] + (["--irq-rand=5"] if d else [])))
        elif s == "stress":
            def stress(i, d):
                a = [x for x in run_random.stress_args(i + 1, 0, True) if not x.startswith("--trace-stall")]
                return a + ["--trace-stall=50"] + (["--irq-rand=5"] if d else [])
            add("stress", isa_programs(cfg, stress))
        elif s == "reset":
            add("reset", isa_programs(cfg, lambda i, d: ["--lat=native", "--rand-reset", f"--seed={i + 1}"] +
                                      (["--irq-rand=5"] if d else [])))
        elif s == "bench":
            add("bench", bench_programs())
        elif s == "random":
            add("random", random_programs(randn, jobs))
        else:
            fail(f"unknown suite {s} (isa, stress, bench, random, reset, none)")
    return out


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def boot_image(kind, given):
    """The boot's image of this kind ("fw" or "kernel"): (path, sha256, what it is). By default the pinned
    reference, which must still have its sha256; a file named on the command line runs whatever it holds."""
    name, ref_path, ref_sha = REF_IMAGES[kind]
    if given:
        if not os.path.isfile(given):
            fail(f"--boot-{kind} {given}: no such file")
        h = sha256_of(given)
        return given, h, "the reference" if h == ref_sha else "NOT the reference, as given"
    if not os.path.isfile(ref_path):
        fail(f"the boot's reference {name}, {ref_path} (sha256 {ref_sha[:16]}...), is missing: restore it, "
             f"or name a file with --boot-{kind} (BOOT_{'FW' if kind == 'fw' else 'KERNEL'})")
    h = sha256_of(ref_path)
    if h != ref_sha:
        fail(f"the boot's reference {name}, {ref_path}, has sha256 {h[:16]}..., not {ref_sha[:16]}...: it was "
             f"rebuilt or replaced, which would move every boot baseline. Restore it, or name the file with "
             f"--boot-{kind} (BOOT_{'FW' if kind == 'fw' else 'KERNEL'}) to run it anyway")
    return ref_path, h, "the reference"


def boot_program(a, cfg, tb_src, images):
    """The Linux boot's first N million cycles: tb_boot's plusargs and the images they name."""
    fw, kernel = images["fw"][0], images["kernel"][0]
    # The device tree for the configuration, from the boot tree's sw/dts
    threads = 2 if cfg.startswith("smt2") else 1
    dsrc = git("rev-parse", f"{tb_src}:sw/dts")
    ddir = os.path.join(WORK, "boot", f"dts-{dsrc[:12]}-c{a.boot_cores}t{threads}")
    dtb = os.path.join(ddir, "tanager-kv260.dtb")
    if not os.path.exists(dtb):
        src = os.path.join(ddir, "src")
        shutil.rmtree(ddir, ignore_errors=True)
        os.makedirs(src)
        ar = subprocess.Popen(["git", "archive", tb_src, "sw/dts"], cwd=ROOT, stdout=subprocess.PIPE)
        subprocess.run(["tar", "-x", "-C", src], stdin=ar.stdout, check=True)
        ar.wait()
        p = subprocess.run(["make", "-s", "-C", os.path.join(src, "sw", "dts"), f"O={ddir}", f"CORES={a.boot_cores}",
                            f"THREADS={threads}", *BOOT_DTS], capture_output=True, text=True, env=clean_env())
        if p.returncode or not os.path.exists(dtb):
            fail(f"building the boot's device tree: {(p.stdout + p.stderr)[-1000:]}")
    plus = [f"+fw={fw}", f"+dtb={dtb}", f"+kernel={kernel}", f"+expect={BOOT_EXPECT}", f"+max_mcycles={a.boot}",
            f"+verilator+seed+{a.boot_seed}"]
    return ("boot", f"linux-{a.boot}M-c{a.boot_cores}", "boot", (plus, [fw, dtb, kernel]))


# ---- Runs and signatures ----

def read_sig(path):
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    return lines if lines and lines[-1].startswith("end ") else None


def run_cmd(side, prog, extra, out_args):
    """The command line of one run of `prog` on `side`, with `out_args` for its signature or log."""
    _, _, kind, payload = prog
    if kind == "vsim":
        elf, args = payload
        return [side.bin, "--quiet", NO_WALL_LIMIT, *args, *extra, *out_args, elf]
    plus, _ = payload
    return [side.bin, *plus, *extra, *out_args]


def run_side(side, prog, extra, timeout):
    """The signature of one run (cached per build, program and options); None and a reason on a crash."""
    _, _, kind, payload = prog
    if kind == "vsim":
        key = sha1(file_digest(payload[0]), *payload[1], *extra)
    else:
        key = sha1(*(file_digest(f) for f in payload[1]), *(p for p in payload[0] if not p.startswith(("+fw", "+dtb", "+kernel"))),
                   *extra)
    sig = os.path.join(side.sigdir, key[:2], key + ".sig")
    lines = read_sig(sig)
    if lines is not None:
        return lines, None, True
    os.makedirs(os.path.dirname(sig), exist_ok=True)
    tmp = f"{sig}.{os.getpid()}.{threading.get_ident()}"
    cmd = run_cmd(side, prog, extra, [f"--sig={tmp}"] if kind == "vsim" else [f"+sig={tmp}"])
    so = open(tmp + ".out", "w") if kind == "boot" else subprocess.DEVNULL  # a boot's console and progress
    try:
        p = subprocess.run(cmd, stdout=so, stderr=subprocess.PIPE, text=True, errors="replace", timeout=timeout)
        err = p.stderr
    except subprocess.TimeoutExpired:
        err = f"no result after {timeout} s of wall-clock time"
    finally:
        if so is not subprocess.DEVNULL:
            so.close()
    lines = read_sig(tmp)
    if lines is None:
        for f in (tmp, tmp + ".out"):
            if os.path.exists(f):
                os.remove(f)
        return None, (err.strip().splitlines() or ["the run ended without a signature"])[-1], False
    if kind == "boot":
        os.replace(tmp + ".out", sig[:-4] + ".out")
    os.replace(tmp, sig)
    return lines, None, False


def parse_end(lines):
    """(cycles, status, work) of a run: work is what it did in those cycles (instret, or a boot's records)."""
    kv = dict(x.split("=", 1) for x in lines[-1].split()[1:])
    return int(kv.get("cycles", 0)), kv.get("status", "?"), int(kv.get("instret", kv.get("records", 0)))


def cost(kind, ca, wa, cb, wb):
    """The branch's cost in cycles, relative to the base: tg_vsim runs a program to its end, so cycles;
    a boot runs a fixed number of cycles, so the cycles it would need for the base's work."""
    if kind == "vsim":
        return cb - ca, ca
    return (ca * wa / wb - ca) if wb else 0.0, ca


def first_diff(a, b):
    """Index of the first differing signature line, and the first cycle of the window it covers."""
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            break
    else:
        i = min(len(a), len(b))
    prev = 0
    for line in a[1:i]:
        prev = int(line.split()[0])
    return i, prev


def explain(base, branch, prog, extra, start, end, outdir):
    """Rerun cycles start..end-1 of both sides with full logs; the first differing log line."""
    suite, name, kind, _ = prog
    os.makedirs(outdir, exist_ok=True)

    def one(side):
        lg = os.path.join(outdir, f"{suite}-{name}.{side.name}.log")
        out = ([f"--log={lg}", f"--log-from={start}", "--log-bus", f"--cycles={end}"] if kind == "vsim" else
               [f"+sig_log={lg}", f"+sig_log_from={start}", f"+sig_stop={end}"])
        subprocess.run(run_cmd(side, prog, extra if side is branch else [], out), capture_output=True, timeout=14400)
        return lg, open(lg, errors="replace").read().splitlines() if os.path.exists(lg) else []

    with cf.ThreadPoolExecutor(max_workers=2) as ex:
        (la, a), (lb, b) = ex.map(one, (base, branch))
    i = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
    ctx = [f"    = {x}" for x in a[max(0, i - 3):i]]
    ctx += [f"    base   {x}" for x in a[i:i + 3]] or ["    base   (no more lines)"]
    ctx += [f"    branch {x}" for x in b[i:i + 3]] or ["    branch (no more lines)"]
    return ctx, la, lb


# Signature columns after the window's end cycle: tg_vsim has the trace and TileLink; tg_soc_sig adds the host.
COLUMNS = {"vsim": (("commit trace", "records"), ("TileLink", "events")),
           "boot": (("commit trace", "records"), ("memory side", "events"), ("host side", "events"))}


def what_differs(kind, fa, fb):
    parts = []
    for j, (label, unit) in enumerate(COLUMNS[kind]):
        lo = 1 if j == 0 else 2 + 2 * j  # the trace takes three columns (records, writebacks, hash)
        hi = 4 if j == 0 else lo + 2
        if fa[lo:hi] != fb[lo:hi]:
            parts.append(f"{label} ({fa[lo]} -> {fb[lo]} {unit})")
    return " and ".join(parts) or "window"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cfg", default="st", help="configurations, comma- or space-separated (st smt2 st_w3 smt2_w3)")
    ap.add_argument("--base", default="", help="the base commit (default: merge base of HEAD and main)")
    ap.add_argument("--branch", default="", help="take this side's rtl/ from this ref instead of the working tree")
    ap.add_argument("--suites", default="isa,stress,bench,random")
    ap.add_argument("--randn", type=int, default=200, help="random programs")
    ap.add_argument("--boot", type=int, default=None,
                    help="also the Linux boot's first N million cycles (0: no; default: 3 when the change reaches "
                         "the uncore, else 0)")
    ap.add_argument("--boot-cores", type=int, default=None, choices=(1, 2),
                    help="cores in the booted SoC (default: 2 when the change reaches the uncore, else 1)")
    ap.add_argument("--boot-fw", default="",
                    help="OpenSBI fw_jump.bin (default: the reference, REF_IMAGES, which must keep its sha256)")
    ap.add_argument("--boot-kernel", default="",
                    help="Linux Image (default: the reference, REF_IMAGES, which must keep its sha256)")
    ap.add_argument("--boot-seed", type=int, default=1, help="the memory models' random seed (+verilator+seed+)")
    ap.add_argument("--boot-tree", default="", help="take tests/unit (tb_boot) and sw/dts from this ref")
    ap.add_argument("--jobs", type=int, default=8, help="parallel runs, and make jobs across the builds")
    ap.add_argument("--harness", choices=("auto", "branch", "own"), default="auto",
                    help="the base side's sim/: this tree's (branch), the base commit's (own), or this tree's "
                         "unless the base's RTL does not build with it, then the base's own (auto, the default)")
    ap.add_argument("--branch-args", default="",
                    help="extra tg_vsim options for this tree's side only (to check that the tool sees a difference)")
    ap.add_argument("--timing-cuts", type=int, choices=(0, 1), default=None,
                    help="build both sides (tg_vsim and the boot) with this profile of the core's timing cuts "
                         "(DR-140; default: the core package's)")
    ap.add_argument("--branch-timing-cuts", type=int, choices=(0, 1), default=None,
                    help="this side's profile only: 0 checks the all-off fallback against a base without the switches")
    ap.add_argument("--dc-mshrs", type=int, choices=(1, 4), default=None,
                    help="build both sides with this many L1D misses in flight (DR-149; default: the core package's)")
    ap.add_argument("--branch-dc-mshrs", type=int, choices=(1, 4), default=None,
                    help="this side's only: 4 against a base of one MSHR measures the 4-miss L1D")
    ap.add_argument("--queue-decode", type=int, choices=(0, 1), default=None,
                    help="build both sides with G8's instruction-queue decode bits off or on (default: the core package's)")
    ap.add_argument("--branch-queue-decode", type=int, choices=(0, 1), default=None,
                    help="this side's only: the other setting against the same RTL, or on against a base without them")
    ap.add_argument("--spec-wake", type=int, choices=(0, 1), default=None,
                    help="build both sides with M6's speculative load wakeup off or on (DR-153; default: the package's)")
    ap.add_argument("--branch-spec-wake", type=int, choices=(0, 1), default=None,
                    help="this side's only: 1 against a base without it measures the feature's cycles")
    ap.add_argument("--sta-base", type=int, choices=(0, 1), default=None,
                    help="build both sides with M6's store address on its base alone off or on (DR-169; default: the package's)")
    ap.add_argument("--branch-sta-base", type=int, choices=(0, 1), default=None, help="this side's only")
    ap.add_argument("--steer-la", type=int, choices=(0, 1), default=None,
                    help="build both sides with M6's ALU-queue steering a group ahead off or on (DR-169; default: the package's)")
    ap.add_argument("--branch-steer-la", type=int, choices=(0, 1), default=None, help="this side's only")
    ap.add_argument("--pmp-entries", type=int, choices=(8, 16), default=None,
                    help="build both sides with this many PMP entries (DR-167; default: the package's); each side's "
                         "lockstep has as many PMP regions as its model reports")
    ap.add_argument("--branch-pmp-entries", type=int, choices=(8, 16), default=None,
                    help="this side's only: 16 against a base of 16 checks the switch at 16")
    ap.add_argument("--store-pf", type=int, choices=(0, 1), default=None,
                    help="build both sides with M6's ownership prefetch for stores off or on (DR-171; default: the package's)")
    ap.add_argument("--branch-store-pf", type=int, choices=(0, 1), default=None, help="this side's only")
    ap.add_argument("--urf", type=int, choices=(0, 1), default=None,
                    help="build both sides with the UltraRAM integer register file off or on (DR-174; default: the package's)")
    ap.add_argument("--branch-urf", type=int, choices=(0, 1), default=None,
                    help="this side's only: 1 against a base without it checks that it gives the same cycles")
    ap.add_argument("--store-pf-max", type=int, choices=(2, 3), default=None,
                    help="build both sides with this many store prefetches in flight (DR-171; default: the package's)")
    ap.add_argument("--branch-store-pf-max", type=int, choices=(2, 3), default=None, help="this side's only")
    ap.add_argument("--solo-tid", type=int, choices=(0, 1), default=None,
                    help="build both sides with M7's test mode, the one thread as tid 1 (DR-175; smt2 only)")
    ap.add_argument("--branch-solo-tid", type=int, choices=(0, 1), default=None,
                    help="this side's only: 1 against a base without it checks the tid=1 paths give the same cycles")
    ap.add_argument("--split", type=int, choices=(0, 1), default=None,
                    help="build both sides with M7's split mode, the thread in its half (DR-175; smt2 only)")
    ap.add_argument("--branch-split", type=int, choices=(0, 1), default=None,
                    help="this side's only (the halves change the cycles: compare two trees that both have it)")
    ap.add_argument("--timeout", type=int, default=3600, help="wall-clock seconds per run before it counts as broken")
    ap.add_argument("--show", type=int, default=5, help="differing runs to explain in detail")
    a = ap.parse_args()
    policy = host_policy.apply_self(1)   # every model here is single-threaded (VTHREADS=1); verification.md §8
    if policy:
        log(f"cycle-identical: {policy}")

    if not os.environ.get("RISCV_TESTS"):
        fail("source tools/env.sh first")
    cfgs = a.cfg.replace(",", " ").split()
    suites = [s for s in a.suites.replace(",", " ").split() if s != "none"]
    extra = a.branch_args.split()
    base_commit = a.base or git("merge-base", "HEAD", "main")
    base_commit = git("rev-parse", "--verify", f"{base_commit}^{{commit}}")
    tree = worktree_tree()
    if a.branch:
        branch_rtl = git("rev-parse", "--verify", f"{a.branch}^{{commit}}")
        label = f"{a.branch} ({branch_rtl[:10]})"
    else:
        branch_rtl = tree
        dirty = git("diff", "--stat", "HEAD", tree, "--", "rtl", "sim", "tests/unit").strip()
        label = f"{WT} at {git('rev-parse', '--short', 'HEAD')}{' with uncommitted changes' if dirty else ''}"
    changed = git("diff", "--name-only", base_commit, branch_rtl, "--", "rtl").splitlines()
    tb_src = git("rev-parse", "--verify", f"{a.boot_tree}^{{commit}}") if a.boot_tree else tree
    has_tb = git("ls-tree", "--name-only", tb_src, "tests/unit/boot/tb_boot.sv") != ""
    # The uncore and the SoC top see only the boot; rtl/common's packages and primitives are theirs too
    uncore = [c for c in changed if c.startswith(UNCORE_PATHS)]
    auto_note = ""
    if a.boot is None:
        a.boot = AUTO_BOOT if uncore and has_tb else 0
        if uncore:
            auto_note = (f"  {len(uncore)} of the changed files reach the uncore ({', '.join(c[4:] for c in uncore[:3])}"
                         f"{' ...' if len(uncore) > 3 else ''}): "
                         + (f"the boot runs by default (BOOT={AUTO_BOOT}; BOOT=0 skips it)" if has_tb else
                            "the boot would run, but this tree has no tests/unit/boot"))
    if a.boot_cores is None:
        a.boot_cores = 2 if uncore else 1
    if a.boot and not has_tb:
        fail("this tree has no tests/unit/boot/tb_boot.sv: give --boot-tree with a ref that has it")
    tool = toolchain_id()
    log(f"cycle-identical: base {base_commit[:10]} ({git('log', '-1', '--format=%s', base_commit)[:70]})")
    log(f"  this side: {label}; {len(changed)} rtl file(s) differ from the base"
        f"{': ' + ', '.join(c[4:] for c in changed[:6]) if changed else ''}{' ...' if len(changed) > 6 else ''}")
    # Each profile variable: both sides' value, and this side's own if it has one
    both = {"TIMING_CUTS": (a.timing_cuts, a.branch_timing_cuts), "DC_MSHRS": (a.dc_mshrs, a.branch_dc_mshrs),
            "QUEUE_DECODE": (a.queue_decode, a.branch_queue_decode), "SPEC_WAKE": (a.spec_wake, a.branch_spec_wake),
            "STA_BASE": (a.sta_base, a.branch_sta_base), "STEER_LA": (a.steer_la, a.branch_steer_la),
            "PMP_ENTRIES": (a.pmp_entries, a.branch_pmp_entries),
            "STORE_PF": (a.store_pf, a.branch_store_pf), "URF": (a.urf, a.branch_urf),
            "STORE_PF_MAX": (a.store_pf_max, a.branch_store_pf_max),
            "SOLO_TID": (a.solo_tid, a.branch_solo_tid),
            "SPLIT": (a.split, a.branch_split)}
    prof_base = {v: b for v, (b, _) in both.items() if b is not None}
    prof_branch = {v: br if br is not None else b for v, (b, br) in both.items() if br is not None or b is not None}
    if prof_base or prof_branch:
        if a.harness == "own":
            fail("--timing-cuts, --dc-mshrs and --queue-decode need this tree's harness (--harness auto or branch): "
                 "the profile is a make variable of this tree's sim/")
        for v in set(prof_base) | set(prof_branch):
            if not profile_takes(tree, v):
                fail(f"this tree's sim/profile.mk does not take {v}")
        prof = lambda p: ", ".join(f"{v}={p[v]}" for v, _ in PROFILE_VARS if v in p) or "the package's default"
        log(f"  profile (DR-140, DR-149, G8, DR-153, DR-167): base {prof(prof_base)}, this side {prof(prof_branch)}"
            f"{', on the boot too' if a.boot else ''}")
        # tests/unit/boot reads sim/profile.mk only if it is there (soc-2's 97b528a), so a boot tree
        # without the hook would build the default without a word: refuse it instead.
        if a.boot and "TC_DEF" not in git("show", f"{tb_src}:tests/unit/boot/Makefile"):
            fail("a forced profile with the boot needs a tests/unit/boot whose Makefile takes it: give "
                 "--boot-tree with a ref that has it, or --boot 0")
    if not changed and prof_base == prof_branch:
        log("  (the RTL is the base's: identical by construction; the runs still check the tool)")
    if auto_note:
        log(auto_note)
    images = {}
    if a.boot:
        images = {k: boot_image(k, a.boot_fw if k == "fw" else a.boot_kernel) for k in ("fw", "kernel")}
        for k, (path, h, what) in images.items():
            log(f"  boot {'firmware' if k == 'fw' else 'kernel  '}: sha256 {h} ({what}), {path}")
    os.makedirs(WORK, exist_ok=True)

    t_start = time.time()
    all_ok, any_broken = True, False
    for cfg in cfgs:
        harness_base = base_commit if a.harness == "own" else tree
        sides = {}  # kind -> (base, branch)
        if suites:
            sides["vsim"] = (Side("base", "vsim", cfg, tool, base_commit, harness_base, prof=prof_base),
                             Side("branch", "vsim", cfg, tool, branch_rtl, tree, prof=prof_branch))
        if a.boot:
            sides["boot"] = (Side("base", "boot", cfg, tool, base_commit, harness_base, tb_src, a.boot_cores,
                                  prof=prof_base),
                             Side("branch", "boot", cfg, tool, branch_rtl, tree, tb_src, a.boot_cores,
                                  prof=prof_branch))
        if not sides:
            fail("nothing to run: no suites and no --boot")
        boot_tb = tb_src  # the boot's tests/unit and sw/dts (both sides)
        failed = build_all([s for pair in sides.values() for s in pair], a.jobs, cfg)
        if failed and a.harness == "auto":
            # The base's RTL may not build with this tree's harness: the harness can use something only
            # this tree's packages have (tg_tb_top read tg_trace_pkg::COMMIT_TRACE before main had it).
            # That side then takes the base's own harness, and the two sides differ in harness as well.
            # The boot's harness is tb_boot too: one that connects ports the base's SoC lacks (PINNOTFOUND)
            # makes both sides take the base's tests/unit/boot and sw/dts, as BOOT_TREE=<base> does, so
            # the boot keeps one testbench on both sides.
            retry = {}
            for kind, (b, br) in sides.items():
                if b.key in failed and br.key not in failed and b.harness_src != base_commit:
                    if not all(profile_takes(base_commit, v) for v in b.args[7]):
                        continue  # the base's own sim/ cannot force this profile: leave the failure standing
                    kind_, cfg_, tool_, rtl_, _, tb_, cores_, prof_ = b.args
                    if kind == "boot" and tb_ != base_commit:
                        mk = "tests/unit/boot/Makefile"
                        if git("ls-tree", "--name-only", base_commit, "tests/unit/boot/tb_boot.sv") == "" or (
                                prof_ and "TC_DEF" not in git("show", f"{base_commit}:{mk}")):
                            continue  # the base has no tb_boot that can take this boot: leave the failure standing
                        log(f"[{cfg}] the base's RTL does not build with this tree's tb_boot ({failed.pop(b.key)}); "
                            f"both sides' boot take the base's tests/unit/boot and sw/dts (as BOOT_TREE=<base>), "
                            f"and the base its own sim/, so the sides differ in harness as well as RTL "
                            f"(HARNESS=branch to forbid this)")
                        bkind, bcfg, btool, brtl, bharness, _, bcores, bprof = br.args
                        retry[kind] = (Side("base", kind_, cfg_, tool_, rtl_, base_commit, base_commit, cores_, prof=prof_),
                                       Side("branch", bkind, bcfg, btool, brtl, bharness, base_commit, bcores, prof=bprof))
                        boot_tb = base_commit
                        continue
                    log(f"[{cfg}] the base's RTL does not build with this tree's harness ({failed.pop(b.key)}); "
                        f"building the base's {kind} with the base's own sim/ instead, so the sides differ in "
                        f"harness as well as RTL (HARNESS=branch to forbid this)")
                    retry[kind] = (Side("base", kind_, cfg_, tool_, rtl_, base_commit, tb_, cores_, prof=prof_), None)
            if retry:
                failed.update(build_all([s for pair in retry.values() for s in pair if s], a.jobs, cfg))
                for kind, (nb, nbr) in retry.items():
                    if nbr is not None and nbr.key in failed and nb.key not in failed:
                        # The branch's RTL does not build with the base's tb_boot either (it needs what only
                        # this tree's connects): each side keeps its own testbench, the branch its first build
                        log(f"[{cfg}] the branch's RTL does not build with the base's tb_boot either "
                            f"({failed.pop(nbr.key)}); each side's boot takes its own tests/unit/boot, so the "
                            f"testbenches differ as well (the device tree stays the base's)")
                        nbr = None
                    sides[kind] = (nb, nbr or sides[kind][1])
        if failed:
            fail(f"[{cfg}] " + "; ".join(failed.values()))
        prune_builds({s.key for pair in sides.values() for s in pair})

        # The boot first: it is long, and the programs run beside it
        progs = ([boot_program(a, cfg, boot_tb, images)] if a.boot else []) + vsim_programs(suites, cfg, a.randn, a.jobs)
        log(f"[{cfg}] {len(progs)} programs x 2 sides ({', '.join(suites + (['boot'] if a.boot else []))})...")
        t1 = time.time()
        jobs = [(i, side) for i, p in enumerate(progs) for side in sides[p[2]]]
        res = {}
        with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
            futs, same = {}, {}  # a run both sides share (one build, the same options) runs once
            for i, side in jobs:
                xa = extra if side.name == "branch" and progs[i][2] == "vsim" else []
                k = (side.key, i, tuple(xa))
                if k in same:
                    same[k].append((i, side.name))
                    continue
                same[k] = [(i, side.name)]
                limit = a.timeout if progs[i][2] == "vsim" else max(a.timeout, a.boot * 500)
                futs[ex.submit(run_side, side, progs[i], xa, limit)] = k
            for fu in cf.as_completed(futs):
                for who in same[futs[fu]]:
                    res[who] = fu.result()
        cached = sum(1 for r in res.values() if r[2])

        per_suite = {}
        diffs, broken, base_failed = [], [], 0
        for i, p in enumerate(progs):
            suite = p[0]
            (sa, ea, _), (sb, eb, _) = res[(i, "base")], res[(i, "branch")]
            st = per_suite.setdefault(suite, [0, 0, 0, 0, 0.0])  # programs, identical, differ, cycles, cost
            st[0] += 1
            if sa is None or sb is None:
                broken.append((p, ea or eb, "base" if sa is None else "branch"))
                continue
            ca, status_a, wa = parse_end(sa)
            cb, _, wb = parse_end(sb)
            d, _ = cost(p[2], ca, wa, cb, wb)
            st[3] += ca
            st[4] += d
            if status_a not in ("PASS", "RAN"):
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

        for k, (path, h, what) in images.items():
            out(f"[{cfg}] boot {'firmware' if k == 'fw' else 'kernel  '}: sha256 {h} ({what}), {path}", console=False)
        out(f"[{cfg}] {'suite':8s} {'programs':>8s} {'identical':>9s} {'differ':>6s} {'cycles':>9s} {'change':>8s}")
        for suite, (n, ok, nd, ca, d) in per_suite.items():
            out(f"[{cfg}] {suite:8s} {n:8d} {ok:9d} {nd:6d} {ca / 1e6:8.2f}M "
                f"{'0' if ok == n else f'{100.0 * d / max(1, ca):+.3f}%':>8s}")
        out(f"[{cfg}] runs took {time.time() - t1:.0f} s ({cached} of {len(jobs)} signatures from the cache)")
        if base_failed:
            out(f"[{cfg}] note: {base_failed} base run(s) did not pass; they are compared all the same")
        for p, why, side in broken:
            any_broken = True
            out(f"[{cfg}] BROKEN {p[0]}/{p[1]}: the {side} run gave no signature: {why}"
                + (" (a base harness older than the signatures? the base used its own sim/)"
                   if side == "base" and sides[p[2]][0].harness_src == base_commit else ""))
        for k, (p, sa, sb) in enumerate(diffs):
            suite, name, kind, _ = p
            base, branch = sides[kind]
            i, start = first_diff(sa, sb)
            ca, status_a, wa = parse_end(sa)
            cb, status_b, wb = parse_end(sb)
            what = "the run's end"
            end = max(ca, cb) + 1
            if i < len(sa) - 1 and i < len(sb) - 1:
                fa, fb = sa[i].split(), sb[i].split()
                end = int(fa[0])
                what = what_differs(kind, fa, fb)
            status = "" if status_a == status_b else f", status {status_a} -> {status_b}"
            show = k < a.show + 20
            amount = (f"cycles {ca} -> {cb} ({cb - ca:+d})" if kind == "vsim" else
                      f"records retired in {ca} cycles {wa} -> {wb} ({wb - wa:+d})")
            out(f"[{cfg}] DIFF {suite}/{name}: {amount}{status}; first difference in cycles {start}..{end - 1}: {what}",
                show)
            if k < a.show:
                xb = extra if kind == "vsim" else []
                ctx, la, lb = explain(base, branch, p, xb, start, end, outdir)
                for c in ctx:
                    out(c)
                out(f"    logs: {la} {lb}")
                lopts = ([f"--log=FILE", f"--log-from={start}", "--log-bus", f"--cycles={end}"] if kind == "vsim" else
                         ["+sig_log=FILE", f"+sig_log_from={start}", f"+sig_stop={end}"])
                out(f"    rerun: {' '.join(run_cmd(branch, p, xb, lopts))}  (base: {base.bin})")
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
