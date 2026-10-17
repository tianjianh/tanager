#!/usr/bin/env python3
"""Generates, builds and runs tg_rand programs in tg_vsim with lockstep, N at a time from a base seed,
and keeps only the failures (docs/spec/verification.md §6.2).

  run_random.py --sim <tg_vsim> --replay <tg_replay> --n 100 --seed 1 --isa rv64im [--stress] [-- sim args]
  run_random.py --replay-only --replay <tg_replay> --n 100 --isa rv64gc

Each program is first run Spike against Spike (tg_replay), so a broken program is reported as a
generator failure, not as an RTL bug. With --stress, every seed also picks its own memory-system
settings (latency, jitter, backpressure, D gaps, toB grants, random probes) from the seed. With
--replay-only (for ISAs no core runs yet, such as F/D) the second run is tg_replay too, with the
checker perturbations of verification.md §3.8 (deferred writebacks, wide cycles, nondet values)
drawn from the seed. Failures keep their .S, .elf and log, and a one-line command that reproduces them."""
import argparse
import concurrent.futures as cf
import os
import random
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MARCH = {
    "rv64i": "-march=rv64i_zicsr_zifencei -mabi=lp64",
    "rv64im": "-march=rv64im_zicsr_zifencei -mabi=lp64",
    "rv64ima": "-march=rv64ima_zicsr_zifencei -mabi=lp64",
    "rv64imac": "-march=rv64imac_zicsr_zifencei -mabi=lp64",
    "rv64gc": "-march=rv64gc -mabi=lp64d",
}


# tg_rand's DENY_PAGE and DENY_IO: stressed runs deny them, so the programs' accesses there take bus errors
DENY = ["--deny=0x80F00000:4096", "--deny=0x10001000:4096"]


def stress_args(seed, irq, trace_stall=False):
    r = random.Random(seed * 7919 + 13)
    lat = r.choice(['native', 'native', '90', '120', '250'])
    args = [f"--lat={lat}"] + DENY
    if irq:
        # Stretch mtime with the latency so that the timer period stays longer than the handler, which
        # otherwise livelocks a slow core in interrupts (20 cycles per tick at native latency).
        args.append(f"--mtime-div={20 * max(1, (30 if lat == 'native' else int(lat)) // 30)}")
    if r.randrange(2):
        args.append(f"--lat-jitter={r.choice([4, 16, 64])}")
    if r.randrange(2):
        args.append(f"--bp={r.choice([10, 30, 60])}")
    if r.randrange(2):
        args.append(f"--d-gap={r.choice([10, 30, 60])}")
    if r.randrange(3) == 0:
        args.append(f"--grant-b={r.choice([50, 100])}")
    if r.randrange(3) == 0:
        args.append(f"--probe-rate={r.choice([5, 50, 200])}")
    if trace_stall and r.randrange(3) == 0:
        args.append(f"--trace-stall={r.choice([10, 50, 200])}")
    if r.randrange(2):  # DR-149: probes against in-flight misses (drawn last: earlier choices stay as they were)
        args.append(f"--probe-miss={r.choice([20, 50, 100])}")
    args.append(f"--seed={seed}")
    return args


def replay_args(seed):
    r = random.Random(seed * 104729 + 7)
    args = [f"--defer={r.choice([30, 60, 90])}", f"--width={r.randrange(1, 5)}", f"--seed={seed}"]
    if r.randrange(3) == 0:
        args.append("--defer-all")
    if r.randrange(2):
        args.append("--nondet")
    if r.randrange(2):
        args.append(f"--sc-fail={r.choice([20, 50])}")
    return args


def mem_available_gb():
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) / (1 << 20)
    return 1e9


def wait_for_memory(gb):
    """Start nothing while the machine has less than `gb` GB available (conventions §9)."""
    while gb and mem_available_gb() < gb:
        time.sleep(30)


def run(args, timeout, log=None):
    try:
        p = subprocess.run(args, capture_output=True, text=True, errors="replace", timeout=timeout)
        out = p.stdout + p.stderr
        rc = p.returncode
    except subprocess.TimeoutExpired:
        out, rc = "wall-clock timeout\n", -1
    if log:
        with open(log, "w") as f:
            f.write(" ".join(args) + "\n" + out)
    return rc, out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim", help="tg_vsim (not needed with --replay-only)")
    ap.add_argument("--replay-only", action="store_true", help="the second run is tg_replay with perturbations")
    ap.add_argument("--mem-gate", type=float, default=0,
                    help="start no program while MemAvailable is under this many GB (the soak uses 12)")
    ap.add_argument("--replay", required=True)
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--isa", default="rv64im", choices=sorted(MARCH))
    ap.add_argument("--spike-isa", default=None, help="Spike ISA for the tg_replay pre-check")
    ap.add_argument("--irq", type=int, default=0, help="timer interrupt period (ticks); 0 = none")
    ap.add_argument("--length", type=int, default=300)
    ap.add_argument("--miss", type=int, default=2, help="weight of tg_rand's miss-burst template (DR-149; 12: mostly "
                                                       "misses in flight)")
    ap.add_argument("--vm", type=int, default=0, help="percentage of programs in S-mode under Sv39 (tg_rand --vm; "
                                                      "the core needs S-mode)")
    ap.add_argument("--stress", action="store_true")
    ap.add_argument("--trace-stall", action="store_true", help="with --stress: some seeds also stall the trace")
    ap.add_argument("--cov", default="", help="directory for each run's RTL coverage (a tg_vsim built with COV=1)")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--name", default="")
    ap.add_argument("extra", nargs="*")
    a = ap.parse_args()
    os.makedirs(a.workdir, exist_ok=True)
    if a.cov:
        os.makedirs(a.cov, exist_ok=True)
    faildir = os.path.join(a.workdir, "failures")
    spike_isa = a.spike_isa or {"rv64i": "rv64i_zicsr_zicntr_zifencei", "rv64im": "rv64im_zicsr_zicntr_zifencei",
                                "rv64ima": "rv64ima_zicsr_zicntr_zifencei", "rv64imac": "rv64imac_zicsr_zicntr_zifencei",
                                "rv64gc": "rv64gc_zicntr"}[a.isa]

    def one(seed):
        wait_for_memory(a.mem_gate)
        base = os.path.join(a.workdir, f"r{seed}")
        gen = [sys.executable, os.path.join(HERE, "tg_rand.py"), "--seed", str(seed), "--isa", a.isa,
               "--irq", str(a.irq), "--length", str(a.length), "--vm", str(a.vm), "--miss", str(a.miss),
               "-o", base + ".S"]
        rc, out = run(gen, 120)
        if rc:
            return seed, "GEN-FAIL", out.strip().splitlines()[-1] if out.strip() else "generator failed", ""
        cc = ["riscv-none-elf-gcc"] + MARCH[a.isa].split() + ["-nostdlib", "-nostartfiles", "-static",
                                                              "-mcmodel=medany", "-T", os.path.join(HERE, "link.ld"),
                                                              base + ".S", "-o", base + ".elf"]
        rc, out = run(cc, 120)
        if rc:
            return seed, "GEN-FAIL", "assembly failed: " + (out.strip().splitlines() or ["?"])[0], ""
        priv = "--priv=MSU" if a.vm else "--priv=MU"  # programs under Sv39 need S-mode
        rc, out = run([a.replay, "--quiet", f"--isa={spike_isa}", priv, "--max-steps=5000000", base + ".elf"], 600)
        if "status=PASS" not in out:
            return seed, "GEN-FAIL", "Spike-against-Spike run failed: " + out.strip().splitlines()[-1], ""
        if a.replay_only:
            sim = a.replay
            simargs = [f"--isa={spike_isa}", priv, "--max-steps=5000000"] + replay_args(seed) + list(a.extra)
        else:
            sim = a.sim
            simargs = (stress_args(seed, a.irq, a.trace_stall) if a.stress else []) + list(a.extra)
            if a.cov:
                simargs.append(f"--cov={os.path.join(a.cov, f'r{seed}.dat')}")
        cmd = [sim, "--quiet"] + simargs + [base + ".elf"]
        rc, out = run(cmd, a.timeout, base + ".log")
        l1d_line = next((l for l in out.splitlines() if l.startswith("TG-L1D")), "")
        l1d.append(dict(kv.split("=") for kv in l1d_line.split()[1:]))
        res = next((l for l in out.splitlines() if l.startswith(("TG-RESULT", "TG-REPLAY"))), "")
        status = res.split("status=")[1].split()[0] if "status=" in res else "FAIL"
        if status == "PASS":
            for ext in (".S", ".elf", ".log"):
                os.remove(base + ext)
            return seed, "PASS", res, ""
        detail = next((l.split(":", 1)[1].strip() for l in out.splitlines()
                       if l.startswith(("tg_vsim:", "tg_replay:")) and "after" not in l), status)
        os.makedirs(faildir, exist_ok=True)
        for ext in (".S", ".elf", ".log"):
            shutil.move(base + ext, os.path.join(faildir, f"r{seed}{ext}"))
        repro = " ".join([sim] + simargs + [os.path.join(faildir, f"r{seed}.elf")])
        return seed, status, detail[:200], repro

    t0 = time.time()
    l1d = []  # each tg_vsim run's TG-L1D counters (DR-149 coverage)
    seeds = list(range(a.seed, a.seed + a.n))
    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        results = list(ex.map(one, seeds))
    fails = [r for r in results if r[1] != "PASS"]
    for seed, status, detail, repro in fails:
        print(f"  {status:9s} seed {seed}: {detail}")
        if repro:
            print(f"            repro: {repro}")
    label = f"{a.name}: " if a.name else ""
    gen_fails = sum(1 for r in fails if r[1] == "GEN-FAIL")
    print(f"{label}{len(results) - len(fails)} passed, {len(fails) - gen_fails} failed, {gen_fails} generator failures "
          f"(seeds {a.seed}..{a.seed + a.n - 1}, isa {a.isa}{', stress' if a.stress else ''}"
          f"{', replay only' if a.replay_only else ''}), {time.time() - t0:.0f} s"
          + (f"; failures kept in {faildir}" if fails else ""))
    tot = {}
    for d in l1d:
        for k, v in d.items():
            tot[k] = max(tot.get(k, 0), int(v)) if k == "max_inflight" else tot.get(k, 0) + int(v)
    if tot.get("acquires"):
        print(f"{label}l1d: {tot['acquires']} Acquires by misses in flight with them "
              f"{tot['inflight1']}/{tot['inflight2']}/{tot['inflight3']}/{tot['inflight4']} (1/2/3/4+, max "
              f"{tot['max_inflight']}); probes on a miss's line {tot['probe_acq']}, in its set {tot['probe_set']}; "
              f"Releases during a miss {tot['rel_acq']}; same-set misses {tot['acq_set']}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
