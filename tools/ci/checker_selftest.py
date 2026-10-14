#!/usr/bin/env python3
"""Self-test of the lockstep checker with tg_replay (docs/spec/verification.md §3.8):
  1. every riscv-tests suite, Spike against Spike, plain and with legal perturbations
     (deferred writebacks, nondet values, several harts, wide cycles): all must pass;
  2. fault injection: each fault kind on a set of tests must be reported with the right diagnosis.
Exit status 0 when both hold."""
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
]

FAULTS = ["pc", "skip", "insn", "priv", "rd", "value", "nowrite", "store-data", "store-addr", "nostore",
          "cause", "tval", "trap-as-retire", "retire-as-trap", "nondet-bad", "wb-value", "wb-missing",
          "wb-extra", "tag-reuse"]
FAULT_TESTS = ["rv64ui-p-sw", "rv64um-p-divu", "rv64ua-p-amoadd_d", "rv64ud-p-fadd", "rv64si-p-csr",
               "rv64ui-v-lw", "rv64uc-p-rvc"]


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
        print("== Interrupts (directed tests with random interrupt injection)")
        for t in sorted(f for f in os.listdir(a.directed) if f.startswith("tanager-p-irq")):
            for seed in (1, 2, 3):
                p = subprocess.run([a.replay, "--quiet", "--irq=30", "--defer=50", f"--seed={seed}",
                                    os.path.join(a.directed, t)], capture_output=True, text=True)
                line = next((l for l in p.stdout.splitlines() if l.startswith("TG-REPLAY")), "no result")
                if "status=PASS" not in line:
                    ok = False
                    print(f"  FAIL {t} seed {seed}: {line}")
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
    print(f"checker self-test: {'PASS' if ok else 'FAIL'}, {time.time() - t0:.0f} s")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
