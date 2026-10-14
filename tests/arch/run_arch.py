#!/usr/bin/env python3
"""Runs ACT4 self-checking ELFs in tg_vsim and prints a pass/fail summary per suite
(docs/spec/verification.md §6.1). A test passes only when its self-check prints
`RVCP-SUMMARY: TEST PASSED` and the run passes: lockstep (on unless disabled with -- --no-lockstep)
and the tohost exit.

  run_arch.py --sim <tg_vsim> --elfs <workdir>/<config>/elfs [--exclude FILE] [-- tg_vsim args]
"""
import argparse
import concurrent.futures as cf
import os
import subprocess
import sys
import time


def run_one(sim, extra, elf, logdir, timeout):
    name = os.path.basename(elf)[:-4]
    log = os.path.join(logdir, name + ".log")
    args = [sim, "--quiet"] + list(extra) + [elf]
    t0 = time.time()
    try:
        p = subprocess.run(args, capture_output=True, text=True, errors="replace", timeout=timeout)
        out = p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        out = "wall-clock timeout\n"
    res = next((l for l in out.splitlines() if l.startswith(("TG-RESULT", "TG-REPLAY"))), "")
    status = res.split("status=")[1].split()[0] if "status=" in res else "TIMEOUT"
    selfcheck = "RVCP-SUMMARY: TEST PASSED" in out
    failed_check = "RVCP-SUMMARY: TEST FAILED" in out
    if status == "PASS" and selfcheck:
        verdict, detail = "PASS", ""
    else:
        verdict = "SELFCHECK" if failed_check else status if status != "PASS" else "NO-SUMMARY"
        detail = next((l.split(":", 1)[1].strip() for l in out.splitlines()
                       if l.startswith(("tg_vsim:", "tg_replay:")) and " after " not in l), "")
        if failed_check:
            detail = "self-check failed; " + detail
        with open(log, "w") as f:
            f.write(" ".join(args) + "\n" + out)
    return elf, verdict, detail[:180], time.time() - t0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sim", required=True)
    ap.add_argument("--elfs", required=True, help="the act work directory's <config>/elfs")
    ap.add_argument("--exclude", action="append", default=[], help="file of test names to skip, with reasons")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--logdir", required=True)
    ap.add_argument("--name", default="")
    ap.add_argument("extra", nargs="*")
    a = ap.parse_args()
    os.makedirs(a.logdir, exist_ok=True)
    excl = {}
    for path in a.exclude:
        if path and os.path.exists(path):
            for line in open(path):
                parts = line.split("#", 1)
                if parts[0].strip():
                    excl[parts[0].strip()] = parts[1].strip() if len(parts) > 1 else ""
    elfs = sorted(os.path.join(d, f) for d, _, fs in os.walk(a.elfs) for f in fs if f.endswith(".elf"))
    if not elfs:
        print(f"no ELFs under {a.elfs}")
        return 1
    run = [e for e in elfs if os.path.basename(e)[:-4] not in excl]
    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        results = list(ex.map(lambda e: run_one(a.sim, a.extra, e, a.logdir, a.timeout), run))
    suites = {}
    for elf, verdict, detail, _ in results:
        suite = os.path.relpath(os.path.dirname(elf), a.elfs)
        ok, n = suites.get(suite, (0, 0))
        suites[suite] = (ok + (verdict == "PASS"), n + 1)
        if verdict != "PASS":
            print(f"  {verdict:10s} {os.path.basename(elf)[:-4]:40s} {detail}")
    print(f"\n{'suite':28s} {'pass':>5s} {'total':>5s}")
    for s, (ok, n) in sorted(suites.items()):
        print(f"{s:28s} {ok:5d} {n:5d}{'' if ok == n else '   <-- failures'}")
    npass = sum(1 for r in results if r[1] == "PASS")
    label = f"{a.name}: " if a.name else ""
    print(f"\n{label}{npass} passed, {len(results) - npass} failed, {len(elfs) - len(run)} excluded, "
          f"{time.time() - t0:.0f} s" + (f"; failing logs in {a.logdir}" if npass < len(results) else ""))
    for e in elfs:
        n = os.path.basename(e)[:-4]
        if n in excl:
            print(f"  excluded {n}: {excl[n]}")
    return 0 if npass == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
