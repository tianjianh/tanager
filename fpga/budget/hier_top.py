#!/usr/bin/env python3
"""Largest modules of a hierarchical utilisation report, as a Markdown table.

  python3 -I fpga/budget/hier_top.py <util_hier.rpt> [--depth 3] [--min 300] [--top 40]

The report comes from `report_utilization -hierarchical` (the budget run keeps one per unit in
$TANAGER_BUILD/budget/reports/<unit>_<cfg>/util_hier.rpt). Build with -flatten none for exact
per-module counts: a flattened build attributes cells to instances only approximately.
Rows are instances down to --depth with at least --min LUTs, largest first, with their path.
"""
import argparse
import re
import sys


def rows(path):
    stack, out = [], []
    with open(path) as f:
        for line in f:
            m = re.match(r"^\|(\s+)(\S.*?)\s+\|", line)
            if not m:
                continue
            c = [x.strip() for x in line.strip().strip("|").split("|")]
            try:
                n = [float(x) for x in c[2:11]]
            except (ValueError, IndexError):
                continue
            depth = (len(m.group(1)) - 1) // 2
            name = c[0]
            if name.startswith("(") and name.endswith(")"):
                continue          # the instance's own logic, apart from its children
            del stack[depth:]
            stack.append(name)
            out.append(dict(path="/".join(stack[1:]) or stack[0], module=c[1], depth=depth,
                            lut=int(n[0]), lutram=int(n[2]), srl=int(n[3]), ff=int(n[4]),
                            bram=n[5] + 0.5 * n[6], dsp=int(n[8])))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("report")
    ap.add_argument("--depth", type=int, default=3)
    ap.add_argument("--min", type=int, default=300)
    ap.add_argument("--top", type=int, default=40)
    a = ap.parse_args()
    r = rows(a.report)
    if not r:
        sys.exit("no hierarchy rows found")
    total = r[0]["lut"]
    sel = [x for x in r[1:] if x["depth"] <= a.depth and x["lut"] >= a.min]
    sel.sort(key=lambda x: -x["lut"])
    print(f"Total: {total:,} LUTs ({r[0]['module']})\n")
    print("| Instance | Module | LUTs | Share | LUTRAM | FFs | BRAM36 | DSP |")
    print("|---|---|---|---|---|---|---|---|")
    for x in sel[:a.top]:
        print(f"| {x['path']} | {x['module']} | {x['lut']:,} | {100 * x['lut'] / total:.1f}% | "
              f"{x['lutram']:,} | {x['ff']:,} | {x['bram']:g} | {x['dsp']} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
