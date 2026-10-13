#!/usr/bin/env python3
"""Runs benchmark ELFs in tg_vsim (lockstep on) and checks their console output against a Spike
reference from tg_replay; reports CoreMark/MHz and DMIPS/MHz from the tg_marker region
(docs/spec/verification.md §4.2). Arguments after `--` go to every tg_vsim run."""
import argparse
import concurrent.futures as cf
import os
import subprocess
import sys
import time


def split_result(text, tag):
    """(console text, {key: value}) from a run's stdout."""
    kv, lines = {}, []
    for line in text.splitlines(keepends=True):
        if line.startswith(tag):
            kv = dict(x.split("=", 1) for x in line.split()[1:] if "=" in x)
        else:
            lines.append(line)
    return "".join(lines), kv


def run(args, timeout):
    t0 = time.time()
    p = subprocess.run(args, capture_output=True, text=True, errors="replace", timeout=timeout)
    return p.returncode, p.stdout, p.stderr, time.time() - t0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sim", required=True)
    ap.add_argument("--replay", required=True)
    ap.add_argument("--iter", type=int, default=2)
    ap.add_argument("--runs", type=int, default=500)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=7200)
    ap.add_argument("--name", default="")
    ap.add_argument("elfs", nargs="+")
    ap.add_argument("extra", nargs="*")
    a = ap.parse_args()
    if "--" in sys.argv:
        extra = sys.argv[sys.argv.index("--") + 1:]
        elfs = [e for e in a.elfs if e not in extra]
    else:
        extra, elfs = [], a.elfs

    def one(elf):
        name = os.path.basename(elf).rsplit(".", 1)[0]
        rc, out, err, _ = run([a.replay, "--quiet", elf], a.timeout)
        ref, rkv = split_result(out, "TG-REPLAY")
        if rkv.get("status") != "PASS":
            return name, "REF-FAIL", f"reference run failed: {err.strip()[-200:]}", {}, ""
        rc, out, err, dt = run([a.sim, "--quiet"] + extra + [elf], a.timeout)
        con, kv = split_result(out, "TG-RESULT")
        status = kv.get("status", "FAIL")
        detail = ""
        if status != "PASS":
            detail = next((l for l in err.splitlines() if l.startswith("tg_vsim:") or "MISMATCH" in l), err[-200:])
        elif con != ref:
            status, detail = "OUTPUT", "console output differs from the Spike reference"
        elif name.startswith("coremark") and "Correct operation validated." not in con:
            status, detail = "FAIL", "CoreMark did not validate"
        kv["secs"] = f"{dt:.1f}"
        return name, status, detail, kv, err if status != "PASS" else ""

    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        results = list(ex.map(one, elfs))

    print(f"\n{'benchmark':14s} {'status':8s} {'cycles':>10s} {'instret':>10s} {'IPC':>6s} {'region cyc':>11s} {'score':>16s} {'sim s':>7s}")
    nfail = 0
    for name, status, detail, kv, err in results:
        score = ""
        rc = int(kv.get("region_cycles", 0) or 0)
        if status == "PASS" and rc:
            if name.startswith("coremark"):
                score = f"{a.iter * 1e6 / rc:.3f} CM/MHz"
            elif name.startswith("dhrystone"):
                score = f"{a.runs * 1e6 / (rc * 1757):.3f} DMIPS/MHz"
        print(f"{name:14s} {status:8s} {kv.get('cycles', ''):>10s} {kv.get('instret', ''):>10s} "
              f"{kv.get('ipc', '')[:6]:>6s} {str(rc or ''):>11s} {score:>16s} {kv.get('secs', ''):>7s}")
        if status != "PASS":
            nfail += 1
            print(f"    {detail}")
            if err:
                print("    " + "\n    ".join(err.strip().splitlines()[-25:]))
    label = f"{a.name}: " if a.name else ""
    print(f"\n{label}{len(results) - nfail} passed, {nfail} failed, {time.time() - t0:.0f} s")
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())
