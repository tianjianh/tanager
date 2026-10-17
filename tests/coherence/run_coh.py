#!/usr/bin/env python3
"""Runs gen_coh programs on the two-core SoC (tests/unit/boot's tb_boot with CORES=2) and checks each three
ways (docs/spec/verification.md §6.5):
  - the program's own check: COH-PASS, or COH-FAIL and the wrong slot;
  - progress: a hang (the board's boot-lottery case) reaches the cycle limit without COH-END;
  - Spike lockstep of both harts: tanager-lockstep --harts=2 on tb_boot's commit trace (+trace_out).
--modes rotates gen_coh's modes over the seeds. --lat sets the DDR models' timing (tb_axi_mem's run-time
options): fixed is one latency per seed, 18 + seed % 9 cycles, with every ready and beat at 100% and in
order, as the board's DDR (the cores then run in step from reset); jitter is 18-26 cycles at random;
board alternates the two by seed. Failures keep their program, console and trace, and a line that
reproduces them.
  run_coh.py --tb <tb_boot> [--lockstep <tanager-lockstep>] --n 20 --seed 1 --workdir DIR [-- plusargs]
"""
import argparse
import concurrent.futures as cf
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def run(args, timeout):
    try:
        p = subprocess.run(args, capture_output=True, text=True, errors="replace", timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return -1, "wall-clock timeout\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tb", required=True, help="tb_boot built with CORES=2")
    ap.add_argument("--lockstep", default="", help="tanager-lockstep (this host's build); none: no lockstep")
    ap.add_argument("--modes", default="mix", help="gen_coh modes, comma-separated, rotated over the seeds")
    ap.add_argument("--harts", default="0,1", help="the harts that take part (gen_coh --harts; 0,2 or 0,1,2,3 on smt2)")
    ap.add_argument("--lat", default="default", help="DDR timing: default (the build's), fixed, jitter, board")
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--max-mcycles", type=int, default=2, help="cycle limit in millions: a program needs well under 1")
    ap.add_argument("--max-kcycles", type=int, default=0, help="cycle limit in thousands instead (tb_boot +max_kcycles)")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--name", default="coherence")
    ap.add_argument("extra", nargs="*", help="more tb_boot plusargs")
    a = ap.parse_args()
    os.makedirs(a.workdir, exist_ok=True)
    faildir = os.path.join(a.workdir, "failures")
    modes = a.modes.split(",")
    if a.lat != "default" or a.max_kcycles:
        # An older tb_boot ignores options it does not know. Look for them in the binary, or in Verilator's
        # C++ beside it (the compiler may build a short string from immediates).
        srcs = [a.tb] + [os.path.join(os.path.dirname(a.tb), f) for f in sorted(os.listdir(os.path.dirname(a.tb)))
                         if f.startswith("V") and f.endswith(".cpp")]
        for opt in ([b"mem_lat_min="] if a.lat != "default" else []) + ([b"max_kcycles="] if a.max_kcycles else []):
            if not any(opt in open(f, "rb").read() for f in srcs):
                sys.exit(f"run_coh: {a.tb} has no +{opt.decode()} option (tb_boot from soc-2's 8882e79 or later)")
    limit = f"+max_kcycles={a.max_kcycles}" if a.max_kcycles else f"+max_mcycles={a.max_mcycles}"
    limit_s = f"{a.max_kcycles} K" if a.max_kcycles else f"{a.max_mcycles} M"

    def timing(seed):
        kind = a.lat if a.lat != "board" else ("fixed", "jitter")[seed % 2]
        if kind == "fixed":
            lat = 18 + seed % 9
            return [f"+mem_lat_min={lat}", f"+mem_lat_max={lat}", "+mem_ready_pct=100", "+mem_r_pct=100", "+mem_ooo=0"]
        if kind == "jitter":
            return ["+mem_lat_min=18", "+mem_lat_max=26"]
        if kind != "default":
            sys.exit(f"run_coh: --lat {a.lat}: default, fixed, jitter or board")
        return []

    def one(seed):
        base = os.path.join(a.workdir, f"c{seed}")
        mode = modes[(seed - a.seed) % len(modes)]
        steps = [[sys.executable, os.path.join(HERE, "gen_coh.py"), "--seed", str(seed), "--mode", mode,
                  "--harts", a.harts, "-o", base + ".S"],
                 ["riscv-none-elf-gcc", "-march=rv64imac_zicsr", "-mabi=lp64", "-nostdlib", "-nostartfiles", "-static",
                  "-mcmodel=medany", "-Wl,--no-warn-rwx-segments", "-T", os.path.join(HERE, "link.ld"), base + ".S",
                  "-o", base + ".elf"],
                 ["riscv-none-elf-objcopy", "-O", "binary", base + ".elf", base + ".bin"]]
        for cmd in steps:
            rc, out = run(cmd, 120)
            if rc:
                return seed, "GEN-FAIL", out.strip().splitlines()[-1] if out.strip() else "?", ""
        plus = ["+expect=COH-END", limit, "+mem_zero"] + timing(seed) + list(a.extra)
        cmd = [a.tb, f"+fw={base}.bin"] + plus + ([f"+trace_out={base}.trace"] if a.lockstep else [])
        rc, out = run(cmd, a.timeout)
        with open(base + ".log", "w") as f:
            f.write(" ".join(cmd) + "\n" + out)
        # tb_boot prints "TEST PASSED (boot" once the console shows +expect (COH-END); its banner and its
        # failure line name COH-END too, so only that line says the program finished
        if "TEST PASSED (boot" not in out:
            last = next((l for l in reversed(out.splitlines()) if "cycle" in l.lower()), "no progress line")
            status, detail = "HANG", f"no COH-END within {limit_s} cycles ({last.strip()[:120]})"
        elif "COH-PASS" not in out:
            status = "FAIL"
            detail = next((l.strip() for l in out.splitlines() if "COH-FAIL" in l), "COH-FAIL")
        elif not a.lockstep:
            for ext in (".S", ".elf", ".bin", ".log"):
                os.remove(base + ext)
            return seed, "PASS", "", ""
        else:
            nharts = max(int(h) for h in a.harts.split(",")) + 1
            nharts = 2 if nharts <= 2 else 4
            rc, lout = run([a.lockstep, f"--fw={base}.bin", f"--harts={nharts}", "--stats=0", base + ".trace"], a.timeout)
            with open(base + ".log", "a") as f:
                f.write("\n---- tanager-lockstep ----\n" + lout)
            if rc == 0 and " PASS after " in lout:
                for ext in (".S", ".elf", ".bin", ".trace", ".log"):
                    os.remove(base + ext)
                return seed, "PASS", "", ""
            status = "LOCKSTEP"
            detail = next((l.strip() for l in lout.splitlines() if "MISMATCH" in l or "NOTHING" in l), "lockstep failed")
        os.makedirs(faildir, exist_ok=True)
        for ext in (".S", ".elf", ".bin", ".trace", ".log"):
            if os.path.exists(base + ext):
                shutil.move(base + ext, os.path.join(faildir, f"c{seed}{ext}"))
        repro = " ".join([a.tb, f"+fw={os.path.join(faildir, f'c{seed}.bin')}"] + plus)
        return seed, status, f"{mode}, {' '.join(timing(seed)) or 'default timing'}: {detail[:200]}", repro

    t0 = time.time()
    seeds = list(range(a.seed, a.seed + a.n))
    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        results = list(ex.map(one, seeds))
    fails = [r for r in results if r[1] != "PASS"]
    for seed, status, detail, repro in fails:
        print(f"  {status:9s} seed {seed}: {detail}")
        if repro:
            print(f"            repro: {repro}")
    counts = {s: sum(1 for r in results if r[1] == s) for s in ("PASS", "FAIL", "HANG", "LOCKSTEP", "GEN-FAIL")}
    print(f"{a.name}: {counts['PASS']} passed, {counts['FAIL']} failed, {counts['HANG']} hung, {counts['LOCKSTEP']} "
          f"lockstep mismatches, {counts['GEN-FAIL']} generator failures (seeds {a.seed}..{a.seed + a.n - 1}"
          f", modes {a.modes}, harts {a.harts}, timing {a.lat}{', ' + ' '.join(a.extra) if a.extra else ''}), {time.time() - t0:.0f} s"
          + (f"; failures kept in {faildir}" if fails else ""))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
