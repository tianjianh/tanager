#!/usr/bin/env python3
# Ranks q_cell_groups.tcl's families by what B adds to A (spikes §8.18's follow-up: hart 1 on against off). Per unit:
# A's and B's totals, then the families with the largest |B - A| in LUTs, with flip-flops and LUTRAM sites.
#   python3 -I cell_groups_diff.py <groups_A.tsv> <groups_B.tsv> [rows-per-unit=25] [min-LUTs=20]
import sys
from collections import defaultdict

def load(p):
    d = defaultdict(lambda: [0, 0, 0])
    for ln in open(p):
        u, f, l, ff, r = ln.rstrip("\n").split("\t")
        d[(u, f)] = [int(l), int(ff), int(r)]
    return d

a, b = load(sys.argv[1]), load(sys.argv[2])
rows = int(sys.argv[3]) if len(sys.argv) > 3 else 25
minl = int(sys.argv[4]) if len(sys.argv) > 4 else 20
units = []
for (u, _f) in list(a) + list(b):
    if u not in units:
        units.append(u)
for u in units:
    keys = sorted({f for (uu, f) in list(a) + list(b) if uu == u})
    ta = [sum(a[(u, f)][i] for f in keys) for i in range(3)]
    tb = [sum(b[(u, f)][i] for f in keys) for i in range(3)]
    print("== %s: LUTs %d -> %d (%+d), FFs %d -> %d (%+d), LUTRAM sites %d -> %d (%+d)" % (
        u, ta[0], tb[0], tb[0] - ta[0], ta[1], tb[1], tb[1] - ta[1], ta[2], tb[2], tb[2] - ta[2]))
    diffs = []
    for f in keys:
        da = a[(u, f)]; db = b[(u, f)]
        dl = db[0] - da[0]
        if abs(dl) >= minl or abs(db[1] - da[1]) >= 64 or abs(db[2] - da[2]) >= 16:
            diffs.append((dl, f, da, db))
    diffs.sort(key=lambda x: (-abs(x[0]), x[1]))
    print("   %-58s %7s %7s %7s   %6s %6s   %5s %5s" % ("family", "LUT A", "LUT B", "B-A", "FF A", "FF B", "RAM A", "RAM B"))
    for dl, f, da, db in diffs[:rows]:
        print("   %-58s %7d %7d %+7d   %6d %6d   %5d %5d" % (f[:58], da[0], db[0], dl, da[1], db[1], da[2], db[2]))
