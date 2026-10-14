#!/usr/bin/env python3
"""Per-unit budget run (plan §8.5; fpga/budget/README.md).

Synthesises every unit of units.tsv out of context in each of its configurations, one at a
time through tools/vivado_run.sh, then compares LUTs, LUTRAM, FFs, DSP and block RAM with
budgets.tsv and with the previous run, and runs the memory-primitive check.

  python3 -I fpga/budget/run_budget.py [--root R] [--out DIR] [--units a,b] [--cfgs c,d]
                                       [--commit SHA] [--keep] [--dry-run]

Output in --out (default $TANAGER_BUILD/budget): latest.md (the report), latest.json,
history/<time>_<commit>.json (one per run, for the deltas), reports/<unit>_<cfg>/ (the
primitive check and hierarchical utilisation of the last run). Run directories are deleted.
Exit status: 0 every enforced unit within budget and primitive-clean; 1 a unit over budget
or a primitive failure; 2 a synthesis that did not finish.
"""
import argparse
import datetime
import glob
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
METRICS = [  # (summary key after opt_design, budget column, report heading)
    ("opt_lut", "lut", "LUTs"),
    ("opt_lut_dram", "lutram", "LUTRAM"),
    ("opt_ff", "ff", "FFs"),
    ("opt_dsp", "dsp", "DSP"),
    ("opt_bram", "bram36", "BRAM36"),
]


def read_tsv(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            rows.append(line.split("\t"))
    return rows


def f_files(path):
    """Files of a Verilator-style list (-F nests, // and # comments), like tg_files.tcl."""
    out, base = [], os.path.dirname(os.path.abspath(path))
    with open(path) as f:
        for line in f:
            line = re.sub(r"//.*$", "", line)
            line = re.sub(r"#.*$", "", line).strip()
            if not line:
                continue
            m = re.match(r"^-F\s+(\S+)", line)
            if m:
                out += f_files(os.path.join(base, m.group(1)))
            else:
                out.append(os.path.join(base, line))
    return out


def has_module(files, top):
    pat = re.compile(r"^\s*module\s+" + re.escape(top) + r"\b", re.M)
    for p in files:
        try:
            with open(p) as f:
                if pat.search(f.read()):
                    return True
        except OSError:
            pass
    return False


def budget_for(budgets, unit, cfg):
    for row in budgets:
        if row[0] == unit and row[1] == cfg:
            return row
    for row in budgets:
        if row[0] == unit and row[1] == "*":
            return row
    return None


def num(s):
    try:
        v = float(s)
        return int(v) if v == int(v) else v
    except (TypeError, ValueError):
        return None


def fmt(v):
    if v is None:
        return "–"
    if isinstance(v, float):
        return f"{v:g}"
    return f"{v:,}"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    ap.add_argument("--out", default=os.path.join(
        os.environ.get("TANAGER_BUILD", os.path.expanduser("~/tanager-build")), "budget"))
    ap.add_argument("--units", default="")
    ap.add_argument("--cfgs", default="")
    ap.add_argument("--commit", default="")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    commit = a.commit or subprocess.run(["git", "-C", root, "rev-parse", "--short", "HEAD"],
                                        capture_output=True, text=True).stdout.strip() or "?"
    units = read_tsv(os.path.join(root, "fpga", "budget", "units.tsv"))
    budgets = read_tsv(os.path.join(root, "fpga", "budget", "budgets.tsv"))
    want_u = set(filter(None, a.units.split(",")))
    want_c = set(filter(None, a.cfgs.split(",")))
    rtl = f_files(os.path.join(root, "rtl", "rtl.f"))

    jobs, skipped = [], []
    for u, cfgs, top, files, gens in units:
        if want_u and u not in want_u:
            continue
        extra = [] if files == "-" else files.split(",")
        if not has_module(rtl + [os.path.join(root, f) for f in extra], top):
            skipped.append(f"{u} ({top} not in the sources yet)")
            continue
        for c in cfgs.split(","):
            if want_c and c not in want_c:
                continue
            jobs.append(dict(unit=u, cfg=c, top=top, files=extra,
                             generics=[] if gens == "-" else gens.split(",")))
    print(f"budget run: {len(jobs)} syntheses at {commit}" +
          (f"; skipped: {', '.join(skipped)}" if skipped else ""), flush=True)
    if a.dry_run:
        for j in jobs:
            print(f"  {j['unit']:8s} {j['cfg']:8s} {j['top']} {','.join(j['generics']) or '-'}")
        return 0

    os.makedirs(os.path.join(a.out, "history"), exist_ok=True)
    runs = os.path.join(a.out, "runs")
    results, infra = [], 0
    for j in jobs:
        name = f"{j['unit']}_{j['cfg']}"
        rd = os.path.join(runs, name)
        shutil.rmtree(rd, ignore_errors=True)
        cmd = ["bash", os.path.join(root, "tools", "vivado_run.sh"), rd,
               os.path.join(root, "fpga", "budget", "tcl", "unit_synth.tcl"), root, j["cfg"], j["top"]]
        for g in j["generics"]:
            cmd += ["-g", g]
        for f in j["files"]:
            cmd += ["-file", f]
        t0 = datetime.datetime.now()
        rc = subprocess.run(cmd, cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        summ = {}
        try:
            with open(os.path.join(rd, "summary.txt")) as f:
                for line in f:
                    k, _, v = line.strip().partition(" ")
                    summ[k] = v.strip()
        except OSError:
            pass
        ok = rc == 0 and "opt_lut" in summ
        if not ok:
            infra += 1
        r = dict(unit=j["unit"], cfg=j["cfg"], top=j["top"], generics=j["generics"], ok=ok,
                 minutes=round((datetime.datetime.now() - t0).total_seconds() / 60, 1),
                 values={k: num(summ.get(k)) for k, _, _ in METRICS},
                 prim_fail=(num(summ.get("prim_fail_synth")) or 0) + (num(summ.get("prim_fail_opt")) or 0),
                 prim_stray=num(summ.get("prim_stray")) or 0)
        results.append(r)
        print(f"  {name:16s} {'ok' if ok else 'FAILED rc=%d' % rc:8s} LUTs {fmt(r['values']['opt_lut'])}"
              f" ({r['minutes']} min)", flush=True)
        keep = os.path.join(a.out, "reports", name)
        shutil.rmtree(keep, ignore_errors=True)
        os.makedirs(keep, exist_ok=True)
        for f in ("summary.txt", "prim_synth.txt", "prim_opt.txt", "util_hier.rpt", "vivado.log"):
            if os.path.exists(os.path.join(rd, f)) and (f != "vivado.log" or not ok):
                shutil.copy(os.path.join(rd, f), keep)
        if not a.keep:
            shutil.rmtree(rd, ignore_errors=True)

    # Previous run, for the deltas
    prev = {}
    hist = sorted(glob.glob(os.path.join(a.out, "history", "*.json")))
    if hist:
        with open(hist[-1]) as f:
            for r in json.load(f)["results"]:
                prev[(r["unit"], r["cfg"])] = r
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")

    # Report
    over, primbad, lines = 0, 0, []
    lines.append(f"# Per-unit budget run, {stamp}, commit {commit}\n")
    lines.append("Budgets: fpga/budget/budgets.tsv (derivation: docs/perf/budgets.md). Values after "
                 "opt_design, out of context, per core. Δ is the change since the previous run.\n")
    lines.append("| Unit | Config | " + " | ".join(h for _, _, h in METRICS) +
                 " | Primitive check | Status |")
    lines.append("|---|---|" + "---|" * len(METRICS) + "---|---|")
    for r in results:
        b = budget_for(budgets, r["unit"], r["cfg"])
        mode = b[7] if b and len(b) > 7 else "track"
        cells, status = [], "OK"
        for i, (key, col, _) in enumerate(METRICS):
            v = r["values"][key]
            bud = num(b[2 + i]) if b else None
            p = prev.get((r["unit"], r["cfg"]))
            pv = p["values"].get(key) if p and p.get("ok") else None
            cell = fmt(v)
            if bud is not None:
                cell += f" / {fmt(bud)}"
                if v is not None and v > bud:
                    cell = f"**{cell}**"
                    if mode == "enforce":
                        status = "OVER"
            if v is not None and pv is not None and v != pv:
                d = v - pv
                cell += f" (Δ {'+' if d > 0 else ''}{fmt(d)})"
            cells.append(cell)
        prim = "clean" if r["prim_fail"] == 0 else f"{r['prim_fail']} FAIL"
        if r["prim_stray"]:
            prim += f", {r['prim_stray']} stray"
        if not r["ok"]:
            status = "NOT BUILT"
        elif r["prim_fail"]:
            status = "PRIM FAIL" if status == "OK" else status + ", PRIM FAIL"
            primbad += 1
        if status.startswith("OVER"):
            over += 1
        if mode == "track" and status == "OK":
            status = "tracked"
        r["status"] = status
        lines.append(f"| {r['unit']} | {r['cfg']} | " + " | ".join(cells) + f" | {prim} | {status} |")
    lines.append("")
    lines.append("Cells read value / budget; bold is over budget. Units with no budget are tracked only.")
    if skipped:
        lines.append(f"\nNot built yet (no RTL): {', '.join(skipped)}.")
    gone = [f"{u}/{c}" for (u, c) in prev if not any(r["unit"] == u and r["cfg"] == c for r in results)]
    if gone and not (want_u or want_c):
        lines.append(f"\nIn the previous run but not this one: {', '.join(gone)}.")
    report = "\n".join(lines) + "\n"
    with open(os.path.join(a.out, "latest.md"), "w") as f:
        f.write(report)
    doc = dict(stamp=stamp, commit=commit, results=results)
    with open(os.path.join(a.out, "latest.json"), "w") as f:
        json.dump(doc, f, indent=1)
    if not (want_u or want_c) and not infra:
        with open(os.path.join(a.out, "history", f"{stamp}_{commit}.json"), "w") as f:
            json.dump(doc, f, indent=1)
    print(report)
    print(f"budget run: {len(results)} built, {over} over budget, {primbad} with primitive "
          f"failures, {infra} not built; report in {os.path.join(a.out, 'latest.md')}")
    return 2 if infra else (1 if over or primbad else 0)


if __name__ == "__main__":
    sys.exit(main())
