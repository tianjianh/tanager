#!/usr/bin/env python3
"""Self-test of the lockstep checker with tg_replay (docs/spec/verification.md §3.8):
  1. every riscv-tests suite, Spike against Spike, plain and with legal perturbations
     (deferred writebacks, nondet values, several harts, wide cycles): all must pass;
  2. fault injection: each fault kind on a set of tests must be reported with the right diagnosis;
  3. external writes (§3.10): random programs with another master's writes into the bytes they load
     must pass, and writes hidden from the checker or from the core must be reported.
Exit status 0 when all hold."""
import argparse
import concurrent.futures as cf
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RUN_ISA = os.path.join(ROOT, "tests", "isa", "run_isa.py")
EXCLUDE = os.path.join(ROOT, "tests", "isa", "exclude", "tanager.txt")

PERTURB = [
    "",
    "--defer=60 --defer-max=50 --width=3 --seed=3",
    "--defer=90 --defer-all --defer-max=300 --nondet --seed=5",
    "--harts=2 --defer=50 --width=3 --seed=7",
    "--harts=4 --defer=50 --defer-all --nondet --width=4 --wb-ports=1 --seed=9",
    "--sc-fail=40 --defer=30 --width=2 --seed=13",   # SCs the core fails: the checker adopts them
]

# Directed tests that tolerate interrupts injected at random enabled boundaries.
INJECT_OK = ("tanager-p-irq_timer", "tanager-p-irq_ext")

FAULTS = ["pc", "skip", "insn", "priv", "rd", "value", "nowrite", "store-data", "store-addr", "nostore",
          "cause", "tval", "trap-as-retire", "retire-as-trap", "nondet-bad", "wb-value", "wb-missing",
          "wb-extra", "tag-reuse", "ld-addr", "noload"]
FAULT_TESTS = ["rv64ui-p-sw", "rv64um-p-divu", "rv64ua-p-amoadd_d", "rv64ud-p-fadd", "rv64si-p-csr",
               "rv64ui-v-lw", "rv64uc-p-rvc"]

# External writes (§3.10): tg_rand programs (rv64gc; every third under Sv39), each run with writes into
# the bytes it loads, then with the writes hidden from the checker and from the core.
EXT_SEEDS = range(1, 7)
EXT_KINDS = ["pass", "ext-unannounced", "ext-stale"]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--replay", required=True)
    ap.add_argument("--tests-dir", default=os.path.join(os.environ.get("RISCV_TESTS", ""), "isa"))
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--logdir", default=None)
    ap.add_argument("--directed", default=None, help="directory with the built directed tests (tests/isa)")
    a = ap.parse_args()
    logdir = a.logdir or os.path.join(os.environ.get("TANAGER_BUILD", os.path.expanduser("~/tanager-build")),
                                      "checker-selftest")
    os.makedirs(logdir, exist_ok=True)
    t0 = time.time()
    ok = True

    print("== Spike against Spike over all suites")
    for args in PERTURB:
        cmd = [sys.executable, RUN_ISA, "--replay", a.replay, "--suites", "all", "--exclude", EXCLUDE,
               "--jobs", str(a.jobs), "--logdir", logdir, "--name", f"replay {args or 'plain'}"]
        if args:
            cmd += ["--"] + args.split()
        p = subprocess.run(cmd, capture_output=True, text=True)
        summary = [l for l in p.stdout.splitlines() if l.startswith("replay ")]
        print("  " + (summary[0] if summary else "no summary"))
        if p.returncode != 0:
            ok = False
            print("\n".join("    " + l for l in p.stdout.splitlines() if l.startswith("  ")))

    if a.directed:
        # Every directed test with deferred writebacks; the two written for it (they count nothing
        # that an extra interrupt would upset) also with random interrupts injected.
        print("== Directed tests (tests/isa/directed), deferral; interrupt injection where the test allows it")
        for t in sorted(f for f in os.listdir(a.directed) if f.startswith("tanager-p-")):
            inject = t in INJECT_OK
            for seed in (1, 2, 3):
                args = [a.replay, "--quiet", "--defer=50", f"--seed={seed}"] + (["--irq=30"] if inject else [])
                p = subprocess.run(args + [os.path.join(a.directed, t)], capture_output=True, text=True)
                line = next((l for l in p.stdout.splitlines() if l.startswith("TG-REPLAY")), "no result")
                if "status=PASS" not in line:
                    ok = False
                    print(f"  FAIL {t} seed {seed}{' (interrupts injected)' if inject else ''}: {line}")
        print("  done")

    print("== Fault injection")
    jobs = []
    for f in FAULTS:
        for t in FAULT_TESTS:
            for seed in (1, 2):
                jobs.append((f, t, seed))
    if a.directed:
        for seed in (1, 2, 3, 4):
            jobs.append(("irq-cause", "tanager-p-irq_ext", seed))

    def one(job):
        f, t, seed = job
        args = [a.replay, "--quiet", f"--seed={seed}", "--defer=70", f"--inject={f}",
                f"--inject-at={(seed * 37) % 60 + (100 if t.startswith('tanager') else 0)}"]
        if "-v-" in t:
            args.append("--tohost-va=0xffffffffffe01000")
        if t.startswith("tanager"):
            args += ["--irq=30", os.path.join(a.directed, t)]
        else:
            args.append(os.path.join(a.tests_dir, t))
        p = subprocess.run(args, capture_output=True, text=True)
        line = next((l for l in p.stdout.splitlines() if l.startswith("TG-REPLAY")), "")
        status = "PASS" if "status=PASS" in line else "NA" if "status=NA" in line else "MISSED"
        detail = next((l for l in p.stderr.splitlines() if l.startswith("tg_replay: inject")), "")
        return f, t, seed, status, detail

    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        res = list(ex.map(one, jobs))
    per_fault = {}
    for f, t, seed, status, detail in res:
        d = per_fault.setdefault(f, {"PASS": 0, "NA": 0, "MISSED": 0})
        d[status] += 1
        if status == "MISSED":
            ok = False
            print(f"  MISSED {f} on {t} seed {seed}: {detail}")
    for f, d in per_fault.items():
        flag = "" if d["PASS"] and not d["MISSED"] else "   <-- not covered" if not d["PASS"] else "   <-- MISSED"
        if flag and not d["MISSED"] and not d["PASS"]:
            ok = False
        print(f"  {f:16s} detected {d['PASS']:3d}  not applicable {d['NA']:3d}  missed {d['MISSED']:3d}{flag}")
    print("== External writes (random programs)")
    ext_dir = os.path.join(logdir, "ext")
    os.makedirs(ext_dir, exist_ok=True)

    def build(seed):
        base = os.path.join(ext_dir, f"r{seed}")
        gen = [sys.executable, os.path.join(ROOT, "tests", "random", "tg_rand.py"), "--seed", str(seed), "--isa", "rv64gc",
               "--irq", "0", "--length", "400", "--vm", "100" if seed % 3 == 0 else "0", "-o", base + ".S"]
        cc = ["riscv-none-elf-gcc", "-march=rv64gc", "-mabi=lp64d", "-nostdlib", "-nostartfiles", "-static",
              "-mcmodel=medany", "-T", os.path.join(ROOT, "tests", "random", "link.ld"), base + ".S", "-o", base + ".elf"]
        for cmd in (gen, cc):
            if subprocess.run(cmd, capture_output=True, text=True).returncode:
                return seed, None
        return seed, base + ".elf"

    def ext_one(job):
        seed, elf, kind = job
        args = [a.replay, "--quiet", "--isa=rv64gc_zicntr", "--priv=MSU", "--max-steps=5000000", f"--seed={seed}",
                "--ext=100", "--width=3"] + ([] if kind == "pass" else [f"--inject={kind}"])
        p = subprocess.run(args + [elf], capture_output=True, text=True)
        line = next((l for l in p.stdout.splitlines() if l.startswith("TG-REPLAY")), "no result")
        status = "PASS" if "status=PASS" in line else "NA" if "status=NA" in line else "FAIL"
        return seed, kind, status, line

    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        elfs = list(ex.map(build, EXT_SEEDS))
        missing = [seed for seed, elf in elfs if not elf]
        if missing:
            ok = False
            print(f"  generator or assembler failed for seeds {missing}")
        ext_res = list(ex.map(ext_one, [(seed, elf, k) for seed, elf in elfs if elf for k in EXT_KINDS]))
    for k in EXT_KINDS:
        rows = [r for r in ext_res if r[1] == k]
        npass = sum(r[2] == "PASS" for r in rows)
        for seed, _, status, line in rows:
            if status == "FAIL":
                ok = False
                print(f"  FAIL {k} seed {seed}: {line}")
        if not npass:
            ok = False
        what = "passed" if k == "pass" else "detected"
        print(f"  {k:16s} {what} {npass:3d} of {len(rows)}" + ("" if npass else "   <-- not covered"))
    print(f"checker self-test: {'PASS' if ok else 'FAIL'}, {time.time() - t0:.0f} s")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
