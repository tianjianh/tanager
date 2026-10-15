#!/usr/bin/env python3
"""RTL coverage of random programs (docs/spec/verification.md §6.4): merges the coverage files of
tg_vsim runs (a build made with `make -C sim COV=1`, runs with --cov=FILE, for example through
tests/random/run_random.py --cov DIR) and reports, per source file, the line and expression points
that some run reached, and the ones none did.

  cov_report.py DIR_OR_FILE... [--save totals.json] [--compare before.json] [--uncovered 40] [--src ROOT]

A point is a line block or one combination of an expression's terms (Verilator's --coverage-expr,
for example "(we[1]==1 && wa[1]==wa[0]) => 1"); its count is the sum over every instance and run.
Points that no program can reach are counted apart: combinations of constants only (a parameter,
an elaboration-time comparison) and the failing side of assertions. So are points Verilator cannot
measure: on a line whose branch was taken while none of its "=> 1" combinations was ever counted,
which happens when the expression reads a variable its own block reassigns inside the branch
(Verilator samples the terms afterwards); they are listed apart. --save keeps the merged counts;
--compare prints, per file, how a later campaign moved them, and the points it newly reached.
"""
import argparse
import json
import os
import re
import sys
from collections import defaultdict


def points_of(path):
    """(key, count) for every point in one Verilator coverage file; the key leaves out the instance."""
    with open(path, errors="replace") as f:
        for line in f:
            if not line.startswith("C '"):
                continue
            body, _, count = line.rstrip("\n").rpartition("' ")
            kv = {}
            for item in body[3:].split("\x01"):
                if "\x02" in item:
                    k, v = item.split("\x02", 1)
                    kv[k] = v
            f_ = kv.get("f", "?")
            m = re.search(r"/((?:rtl|sim)/.*)$", f_)
            yield (m.group(1) if m else f_, int(kv.get("l", 0)), kv.get("n", ""), kv.get("t", ""),
                   kv.get("o", "")), int(count)


def merge(paths):
    total = defaultdict(int)
    n = 0
    for p in paths:
        files = [os.path.join(p, f) for f in sorted(os.listdir(p)) if f.endswith(".dat")] if os.path.isdir(p) else [p]
        for f in files:
            for k, c in points_of(f):
                total[k] += c
            n += 1
    return total, n


SIZED = re.compile(r"\d+'s?[bhdo][0-9a-fA-F_xzXZ]+")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def unreachable(key, src_line):
    """A point no program reaches: an expression over constants only, or an assertion's condition."""
    if "assert" in src_line:
        return True
    if key[3] != "expr":
        return False
    terms = SIZED.sub("", key[4].split("=>")[0])
    return all(t.isupper() or t.startswith("tg_") for t in IDENT.findall(terms))


def if_condition(src):
    """The condition of the if statement on a source line ("" if there is none)."""
    m = re.search(r"\bif\s*\(", src)
    if not m:
        return ""
    depth, i = 1, m.end()
    while i < len(src) and depth:
        depth += {"(": 1, ")": -1}.get(src[i], 0)
        i += 1
    return src[m.end():i - 1]


def terms(text):
    return set(IDENT.findall(SIZED.sub("", text)))


def unmeasured(total, src_line):
    """Expression points Verilator cannot measure: an if was taken, yet none of the "=> 1"
    combinations of its condition was ever counted. A taken if needs one of them, so the terms were
    sampled after the block reassigned one inside the branch (tg_rob's ex_v and ex_r, for example).
    Only combinations that share a term with the if's own condition count, so an expression in the
    branch's body on the same line is left alone."""
    by_line = defaultdict(list)
    for k, c in total.items():
        by_line[(k[0], k[1])].append((k, c))
    out = set()
    for (f, n), pts in by_line.items():
        if not any(k[3] == "branch" and k[4] == "if" and c > 0 for k, c in pts):
            continue
        cond = terms(if_condition(src_line(f, n)))
        ones = [k for k, c in pts if k[3] == "expr" and k[4].rstrip().endswith("=> 1")]
        if ones and all(total[k] == 0 and cond & terms(k[4].split("=>")[0]) for k in ones):
            out.update(ones)
    return out


def per_file(total, skip=lambda k: False):
    out = defaultdict(lambda: [0, 0, 0, 0])  # lines, lines hit, expression points, expression points hit
    for k, c in total.items():
        if skip(k):
            continue
        f, t = k[0], k[3]
        e = out[f]
        if t == "expr":
            e[2] += 1
            e[3] += c > 0
        else:
            e[0] += 1
            e[1] += c > 0
    return out


def pct(h, n):
    return f"{100.0 * h / n:5.1f}%" if n else "    -"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*", help="coverage files, or directories of them")
    ap.add_argument("--load", default="", help="merged counts saved by --save, instead of inputs")
    ap.add_argument("--save", default="", help="write the merged counts (JSON)")
    ap.add_argument("--compare", default="", help="merged counts of an earlier campaign (JSON)")
    ap.add_argument("--uncovered", type=int, default=30, help="uncovered points listed per file")
    ap.add_argument("--src", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")),
                    help="the tree whose rtl/ the source lines are read from")
    a = ap.parse_args()

    if a.load:
        with open(a.load) as f:
            total = {tuple(k): c for k, c in json.load(f)["points"]}
        runs = 0
    else:
        total, runs = merge(a.inputs)
        if not total:
            sys.exit("cov_report: no coverage points (a tg_vsim built with COV=1, runs with --cov=FILE)")
    if a.save:
        with open(a.save, "w") as f:
            json.dump({"runs": runs, "points": [[list(k), c] for k, c in sorted(total.items())]}, f)
    before = {}
    if a.compare:
        with open(a.compare) as f:
            before = {tuple(k): c for k, c in json.load(f)["points"]}

    src_cache = {}

    def src_line(f, n):
        if f not in src_cache:
            try:
                with open(os.path.join(a.src, f), errors="replace") as fh:
                    src_cache[f] = fh.read().splitlines()
            except OSError:
                src_cache[f] = []
        lines = src_cache[f]
        return lines[n - 1].strip() if 0 < n <= len(lines) else ""

    blind = unmeasured(total, src_line)

    def skip(k):
        return k in blind or unreachable(k, src_line(k[0], k[1]))

    files = per_file(total, skip)
    old = per_file(before, skip) if before else {}
    nskip = sum(1 for k in total if skip(k) and k not in blind)
    print(f"coverage of {runs or 'saved'} run(s): {len(total)} points, {nskip} of them unreachable by construction "
          f"(constants, assertions) and {len(blind)} not measurable, left out below")
    print(f"{'file':44s} {'lines':>11s} {'':>6s} {'expressions':>13s} {'':>6s}" + ("   before: lines, expressions" if old else ""))
    for f in sorted(files):
        l, lh, e, eh = files[f]
        row = f"{f:44s} {lh:5d}/{l:<5d} {pct(lh, l)} {eh:6d}/{e:<6d} {pct(eh, e)}"
        if f in old:
            ol, olh, oe, oeh = old[f]
            row += f"   {pct(olh, ol)} {pct(oeh, oe)}"
        print(row)

    if before:
        newly = sorted(k for k, c in total.items() if c > 0 and before.get(k, 0) == 0)
        print(f"\nnewly reached: {len(newly)} points")
        for k in newly[:a.uncovered]:
            print(f"  {k[0]}:{k[1]} {k[3] or 'line'} {k[4]}")
    if a.uncovered:
        for f in sorted(files):
            miss = sorted(k for k, c in total.items() if k[0] == f and c == 0 and not skip(k))
            if not miss:
                continue
            print(f"\n{f}: {len(miss)} points never reached")
            for k in miss[:a.uncovered]:
                print(f"  {k[1]:5d} {k[3] or 'line':5s} {k[4][:70]:70s} | {src_line(f, k[1])[:80]}")
            if len(miss) > a.uncovered:
                print(f"  ... {len(miss) - a.uncovered} more")
    if blind:
        print(f"\nnot measurable ({len(blind)}): the branch was taken, but the block reassigns a term")
        for k in sorted(blind)[:a.uncovered]:
            print(f"  {k[0]}:{k[1]} {k[4][:70]:70s} | {src_line(k[0], k[1])[:60]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
