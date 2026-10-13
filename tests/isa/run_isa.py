#!/usr/bin/env python3
"""Runs riscv-tests ISA binaries through tg_vsim (RTL + lockstep) or tg_replay (Spike against
Spike) and prints a pass/fail summary (docs/spec/verification.md §4.1).

  run_isa.py --sim $(make -s -C sim print-bin CFG=st) --suites "rv64ui-p rv64um-p"
  run_isa.py --replay <tg_replay> --suites all -- --defer=50 --nondet

Arguments after `--` go to every run. Exit status: 0 when every selected test passes.
"""
import argparse
import concurrent.futures as cf
import os
import struct
import subprocess
import sys
import time

# Suites in plan order; "all" selects every one that exists in the test directory.
ALL_SUITES = [
    "rv64ui-p", "rv64um-p", "rv64mi-p", "rv64ua-p", "rv64uc-p", "rv64si-p", "rv64uf-p", "rv64ud-p",
    "rv64uzba-p", "rv64uzbb-p", "rv64uzbs-p", "rv64uzicond-p",
    "rv64ui-v", "rv64um-v", "rv64ua-v", "rv64uc-v", "rv64uf-v", "rv64ud-v",
    "rv64uzba-v", "rv64uzbb-v", "rv64uzbs-v", "rv64uzicond-v",
]

DRAM_BASE = 0x80000000
MEGAPAGE = 0x200000  # riscv-tests -v kernel alias: pa - DRAM_BASE - MEGAPAGE (env/v/vm.c, Sv39)


def elf_symbol(path, name):
    """Value of a symbol in an ELF64 little-endian file, or None."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 2:
        return None
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x3A)
    for i in range(shnum):
        off = shoff + i * shentsize
        sh_type, = struct.unpack_from("<I", data, off + 4)
        if sh_type != 2:  # SHT_SYMTAB
            continue
        sh_offset, sh_size = struct.unpack_from("<QQ", data, off + 0x18)
        sh_link, = struct.unpack_from("<I", data, off + 0x28)
        stro, = struct.unpack_from("<Q", data, shoff + sh_link * shentsize + 0x18)
        for s in range(sh_offset, sh_offset + sh_size, 24):
            st_name, = struct.unpack_from("<I", data, s)
            st_value, = struct.unpack_from("<Q", data, s + 8)
            end = data.index(b"\0", stro + st_name)
            if data[stro + st_name:end].decode() == name:
                return st_value
    return None


def tests_of(tdir, suites):
    names = sorted(f for f in os.listdir(tdir) if not f.endswith(".dump"))
    out = []
    for s in suites:
        sel = [n for n in names if n.startswith(s + "-")]
        if not sel:
            print(f"warning: no tests for suite {s} in {tdir}", file=sys.stderr)
        out += [(s, n) for n in sel]
    return out


def read_exclusions(files):
    ex = {}
    for path in files:
        if not path or not os.path.exists(path):
            continue
        for line in open(path):
            line = line.split("#", 1)
            name = line[0].strip()
            if name:
                ex[name] = line[1].strip() if len(line) > 1 else ""
    return ex


def run_one(binary, extra, tdir, test, logdir, timeout, keep):
    path = os.path.join(tdir, test)
    args = [binary] + list(extra)
    if "-v-" in test:
        th = elf_symbol(path, "tohost")
        if th is not None:
            args.append("--tohost-va=0x%x" % ((th - DRAM_BASE - MEGAPAGE) & (2**64 - 1)))
    args.append(path)
    log = os.path.join(logdir, test + ".log")
    t0 = time.time()
    try:
        with open(log, "w") as f:
            f.write(" ".join(args) + "\n")
            f.flush()
            rc = subprocess.run(args, stdout=f, stderr=subprocess.STDOUT, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        rc = -1
    dt = time.time() - t0
    text = open(log, errors="replace").read()
    status, detail = "FAIL", ""
    for line in text.splitlines():
        if line.startswith("TG-RESULT") or line.startswith("TG-REPLAY"):
            kv = dict(x.split("=", 1) for x in line.split()[1:] if "=" in x)
            status = kv.get("status", "FAIL")
            detail = " ".join(f"{k}={kv[k]}" for k in ("cycles", "instret", "ipc", "records") if k in kv)
    if rc == -1:
        status, detail = "TIMEOUT", f"wall clock > {timeout}s"
    elif rc != 0 and status == "PASS":
        status = "FAIL"
    if status != "PASS":
        # The most useful line: the first error or mismatch description.
        for line in text.splitlines():
            if line.startswith(("tg_vsim:", "tg_replay:", "tg: error")) and not line.startswith("tg_vsim: /"):
                detail = line.split(":", 1)[1].strip()[:160]
                break
    if status == "PASS" and not keep:
        os.remove(log)
    return test, status, detail, dt


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--sim", help="tg_vsim binary")
    g.add_argument("--replay", help="tg_replay binary")
    ap.add_argument("--suites", default="rv64ui-p rv64um-p rv64mi-p", help='space-separated suites, or "all"')
    ap.add_argument("--tests-dir", default=os.path.join(os.environ.get("RISCV_TESTS", ""), "isa"))
    ap.add_argument("--exclude", action="append", default=[], help="exclusion list file (repeatable)")
    ap.add_argument("--only", default="", help="comma-separated test names to run (overrides --suites)")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=1800, help="wall-clock seconds per test")
    ap.add_argument("--logdir", default=None)
    ap.add_argument("--keep-logs", action="store_true")
    ap.add_argument("--name", default="", help="label for the summary line")
    ap.add_argument("extra", nargs="*", help="arguments for every run (after --)")
    a = ap.parse_args()

    binary = a.sim or a.replay
    suites = ALL_SUITES if a.suites.strip() == "all" else a.suites.split()
    if a.only:
        tests = [("only", t) for t in a.only.split(",")]
    else:
        tests = tests_of(a.tests_dir, suites)
    excl = read_exclusions(a.exclude)
    run = [(s, t) for s, t in tests if t not in excl]
    skipped = [(s, t) for s, t in tests if t in excl]
    logdir = a.logdir or os.path.join(os.environ.get("TANAGER_BUILD", os.path.expanduser("~/tanager-build")),
                                      "isa-logs")
    os.makedirs(logdir, exist_ok=True)

    t0 = time.time()
    results = {}
    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        futs = [ex.submit(run_one, binary, a.extra, a.tests_dir, t, logdir, a.timeout, a.keep_logs) for _, t in run]
        for fu in cf.as_completed(futs):
            test, status, detail, dt = fu.result()
            results[test] = (status, detail, dt)
            if status != "PASS":
                print(f"  {status:8s} {test:32s} {detail}", flush=True)

    by_suite = {}
    for s, t in run:
        p = results[t][0] == "PASS"
        ok, n = by_suite.get(s, (0, 0))
        by_suite[s] = (ok + p, n + 1)
    print(f"\n{'suite':16s} {'pass':>5s} {'total':>5s}")
    for s, (ok, n) in by_suite.items():
        print(f"{s:16s} {ok:5d} {n:5d}{'' if ok == n else '   <-- failures'}")
    npass = sum(1 for t in results.values() if t[0] == "PASS")
    nfail = len(results) - npass
    label = f"{a.name}: " if a.name else ""
    print(f"\n{label}{npass} passed, {nfail} failed, {len(skipped)} excluded, {time.time() - t0:.0f} s"
          + (f"; failing logs in {logdir}" if nfail else ""))
    for s, t in skipped:
        print(f"  excluded {t}: {excl[t]}")
    return 0 if nfail == 0 and results else 1


if __name__ == "__main__":
    sys.exit(main())
