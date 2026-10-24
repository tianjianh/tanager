#!/usr/bin/env python3
"""Self-test of the lockstep checker with tg_replay (docs/spec/verification.md §3.8):
  1. every riscv-tests suite, Spike against Spike, plain and with legal perturbations
     (deferred writebacks, nondet values, several harts, wide cycles): all must pass;
  2. fault injection: each fault kind on a set of tests must be reported with the right diagnosis;
  3. external writes (§3.10): random programs with another master's writes into the bytes they load
     must pass, and writes hidden from the checker or from the core must be reported;
  4. several harts (§3.7): programs whose harts race for the same bytes must pass with stores waiting in a
     store buffer and atomics performing before their records, and stores reaching memory in the wrong order
     or past every window, or an atomic's record past the checker's bound, must be reported; and two harts
     share step 6's mtgsmt CSR (--mtgsmt).
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
          "wb-extra", "tag-reuse", "ld-addr", "noload", "debug-entry"]   # debug-entry: the checker stops, not fails
FAULT_TESTS = ["rv64ui-p-sw", "rv64um-p-divu", "rv64ua-p-amoadd_d", "rv64ud-p-fadd", "rv64si-p-csr",
               "rv64ui-v-lw", "rv64uc-p-rvc"]

# External writes (§3.10): tg_rand programs (rv64gc; every third under Sv39), each run with writes into
# the bytes it loads, then with the writes hidden from the checker and from the core.
EXT_SEEDS = range(1, 7)
EXT_KINDS = ["pass", "ext-unannounced", "ext-stale"]

# Several harts (§3.7): two- and four-hart tg_rand programs whose plain stores and atomics race for the same
# bytes (--races), under tg_replay's store buffer (--sb) and early atomics (--atomic-early), alone and together;
# then a directed two-hart race (ORDER_ASM) with each order fault injected at several points.
ORDER_SEEDS = range(1, 7)
ORDER_SEEDS4 = range(1, 4)
ORDER_PASS = [
    ("sb", "--sb=60 --width=3"),
    ("early", "--atomic-early=48 --width=3"),
    ("sb+early+defer", "--sb=60 --atomic-early=64 --width=4 --defer=40"),
    ("sb+early+sc-fail", "--sb=50 --atomic-early=16 --sc-fail=30"),
]
ORDER_PASS4 = [("sb, 4 harts", "--sb=50 --width=4"), ("early, 4 harts", "--atomic-early=48 --width=4")]
ORDER_FAULTS = [("sb-reorder", "--sb=100"), ("sb-late", "--sb=60"), ("atomic-late", "--atomic-early=32")]
# mtgsmt (0x7C0, one per core of two harts; tg_replay --mtgsmt): each hart writes it and reads what the other wrote
# (bit 0 only), handing over through a word, so a register that each hart kept apart would show
MTGSMT_ASM = """/* checker self-test (verification.md §3.8): mtgsmt shared by two harts, bit 0 only (exit codes 2-6) */
.option arch, +zicsr
.section .text.init, "ax"
.globl _start
_start:
  csrr a0, mhartid
  la s0, turn
  la s1, tohost
  bnez a0, h1
  li t1, -1
  csrw 0x7c0, t1
  li t1, 1
  sw t1, 0(s0)
1:
  lw t1, 0(s0)
  li t2, 2
  bne t1, t2, 1b
  csrr t3, 0x7c0
  li a1, 7
  bnez t3, fail
  csrsi 0x7c0, 1
  csrr t4, 0x7c0
  li t2, 1
  li a1, 9
  bne t4, t2, fail
  li t1, 3
  sw t1, 0(s0)
2:
  lw t1, 0(s0)
  li t2, 4
  bne t1, t2, 2b
  csrr t5, 0x7c0
  li a1, 13
  bnez t5, fail
  li t1, 1
  sd t1, 0(s1)
3:
  j 3b
h1:
  lw t1, 0(s0)
  li t2, 1
  bne t1, t2, h1
  csrr t3, 0x7c0
  li a1, 5
  bne t3, t2, fail
  csrw 0x7c0, zero
  li t1, 2
  sw t1, 0(s0)
4:
  lw t1, 0(s0)
  li t2, 3
  bne t1, t2, 4b
  csrrci t3, 0x7c0, 1
  li t2, 1
  li a1, 11
  bne t3, t2, fail
  li t1, 4
  sw t1, 0(s0)
5:
  wfi
  j 5b
fail:
  sd a1, 0(s1)
6:
  j 6b
.section .tohost, "aw", @progbits
.balign 64
.globl tohost
tohost: .dword 0
.balign 64
.globl fromhost
fromhost: .dword 0
.section .data
.balign 64
turn: .dword 0
"""

# Hart 0 bumps a word with an AMO and stores twice to a doubleword, waits, and reads it back; hart 1 reads both
# until hart 0 is done
ORDER_ASM = """/* checker self-test (verification.md §3.8): two harts racing for a word and a doubleword */
.option arch, +zicsr
.section .text.init, "ax"
.globl _start
_start:
  csrr a0, mhartid
  la s0, flag
  la s1, data
  la s2, done
  li t0, 400
  li t1, 1
  bnez a0, h1
h0:
  amoadd.w t5, t1, (s0)
  sd t0, 0(s1)
  addi t2, t0, 7
  sd t2, 0(s1)
  li t6, 60
1:
  addi t6, t6, -1
  bnez t6, 1b
  ld t3, 0(s1)
  addi t0, t0, -1
  bnez t0, h0
  amoadd.w zero, t1, (s2)
2:
  lw t3, 0(s2)
  li t4, 2
  bne t3, t4, 2b
  la t4, tohost
  sd t1, 0(t4)
3:
  j 3b
h1:
  lw t3, 0(s0)
  ld t4, 0(s1)
  lw t3, 0(s2)
  beqz t3, h1
  amoadd.w zero, t1, (s2)
4:
  wfi
  j 4b
.section .tohost, "aw", @progbits
.balign 64
.globl tohost
tohost: .dword 0
.balign 64
.globl fromhost
fromhost: .dword 0
.section .data
.balign 64
flag: .dword 0
.balign 64
data: .dword 0
.balign 64
done: .dword 0
"""


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
    print("== Several harts: store buffer and early atomics (§3.7)")
    ord_dir = os.path.join(logdir, "order")
    os.makedirs(ord_dir, exist_ok=True)

    def build_order(job):
        harts, seed = job
        base = os.path.join(ord_dir, f"r{len(harts.split(','))}_{seed}")
        gen = [sys.executable, os.path.join(ROOT, "tests", "random", "tg_rand.py"), "--seed", str(seed), "--isa", "rv64gc",
               "--irq", "0", "--length", "300", "--harts", harts, "--shared", "6", "--races", "-o", base + ".S"]
        cc = ["riscv-none-elf-gcc", "-march=rv64gc", "-mabi=lp64d", "-nostdlib", "-nostartfiles", "-static",
              "-mcmodel=medany", "-T", os.path.join(ROOT, "tests", "random", "link.ld"), base + ".S", "-o", base + ".elf"]
        for cmd in (gen, cc):
            if subprocess.run(cmd, capture_output=True, text=True).returncode:
                return job, None
        return job, base + ".elf"

    race = os.path.join(ord_dir, "race2")
    with open(race + ".S", "w") as f:
        f.write(ORDER_ASM)
    cc = ["riscv-none-elf-gcc", "-march=rv64gc", "-mabi=lp64d", "-nostdlib", "-nostartfiles", "-static",
          "-mcmodel=medany", "-T", os.path.join(ROOT, "tests", "random", "link.ld"), race + ".S", "-o", race + ".elf"]
    if subprocess.run(cc, capture_output=True, text=True).returncode:
        ok = False
        print("  the directed race did not assemble")

    def order_one(job):
        elf, harts, tag, args, seed = job
        cmd = [a.replay, "--quiet", "--isa=rv64gc_zicntr", "--priv=MSU", "--max-steps=5000000", f"--harts={harts}",
               f"--seed={seed}"] + args.split()
        p = subprocess.run(cmd + [elf], capture_output=True, text=True)
        line = next((l for l in p.stdout.splitlines() if l.startswith("TG-REPLAY")), "no result")
        status = "PASS" if "status=PASS" in line else "NA" if "status=NA" in line else "FAIL"
        return tag, os.path.basename(elf), seed, status, line

    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        built = list(ex.map(build_order, [("0,1", s) for s in ORDER_SEEDS] + [("0,1,2,3", s) for s in ORDER_SEEDS4]))
        missing = [job for job, elf in built if not elf]
        if missing:
            ok = False
            print(f"  generator or assembler failed for {missing}")
        jobs = []
        for (harts, seed), elf in built:
            if not elf:
                continue
            nh = len(harts.split(","))
            for tag, args in ORDER_PASS if nh == 2 else ORDER_PASS4:
                jobs.append((elf, nh, tag, args, seed))
        smt = os.path.join(ord_dir, "mtgsmt2")
        with open(smt + ".S", "w") as f:
            f.write(MTGSMT_ASM)
        if subprocess.run(cc[:-3] + [smt + ".S", "-o", smt + ".elf"], capture_output=True, text=True).returncode == 0:
            for seed in (1, 2, 3):
                jobs.append((smt + ".elf", 2, "mtgsmt", "--mtgsmt --width=3", seed))
        else:
            ok = False
            print("  the mtgsmt program did not assemble")
        if os.path.exists(race + ".elf"):
            for tag, args in ORDER_PASS:
                for seed in (1, 2):
                    jobs.append((race + ".elf", 2, tag, args, seed))
            for kind, args in ORDER_FAULTS:
                for seed in (1, 2):
                    for at in (300, 3000, 12000):
                        jobs.append((race + ".elf", 2, kind, f"{args} --inject={kind} --inject-at={at}", seed))
        res = list(ex.map(order_one, jobs))
    for tag, _ in ORDER_PASS + ORDER_PASS4 + [("mtgsmt", "")]:
        rows = [r for r in res if r[0] == tag]
        npass = sum(r[3] == "PASS" for r in rows)
        for _, elf, seed, status, line in rows:
            if status != "PASS":
                ok = False
                print(f"  FAIL {tag} {elf} seed {seed}: {line}")
        print(f"  {tag:18s} passed {npass:3d} of {len(rows)}")
    for kind, _ in ORDER_FAULTS:
        rows = [r for r in res if r[0] == kind]
        det = sum(r[3] == "PASS" for r in rows)
        na = sum(r[3] == "NA" for r in rows)
        for _, elf, seed, status, line in rows:
            if status == "FAIL":
                ok = False
                print(f"  MISSED {kind} seed {seed}: {line}")
        if not det:
            ok = False
        print(f"  {kind:18s} detected {det:3d}  not applicable {na:3d}  missed {len(rows) - det - na:3d}" +
              ("" if det else "   <-- not covered"))
    print(f"checker self-test: {'PASS' if ok else 'FAIL'}, {time.time() - t0:.0f} s")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
