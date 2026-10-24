#!/usr/bin/env python3
"""Per-instance utilization deltas between two report_utilization -hierarchical reports (spikes §8.18, rc3 against rc2):
rows keyed by their full instance path (from the indentation), LUTs and FFs of each, the deltas, worst first, down to
<depth> levels.   hier_diff.py <a.rpt> <b.rpt> [depth=5] [min=20]"""
import re, sys
def parse(p):
    rows, stack = {}, []
    for l in open(p):
        if not l.startswith('|') or 'Instance' in l: continue
        c = [x for x in l.rstrip('\n').split('|')[1:-1]]
        if len(c) < 7: continue
        name = c[0]; ind = len(name) - len(name.lstrip(' ')); name = name.strip()
        try: vals = [int(x) for x in c[2:7]]
        except ValueError: continue
        lvl = (ind - 1) // 2
        stack = stack[:lvl] + [name]
        rows['/'.join(stack)] = (lvl, vals)
    return rows
a, b = parse(sys.argv[1]), parse(sys.argv[2])
depth = int(sys.argv[3]) if len(sys.argv) > 3 else 5
mn = int(sys.argv[4]) if len(sys.argv) > 4 else 20
out = []
for k in set(a) | set(b):
    la, va = a.get(k, (None, [0]*5)); lb, vb = b.get(k, (None, [0]*5))
    lvl = la if la is not None else lb
    if lvl > depth: continue
    dl, dff = vb[0] - va[0], vb[4] - va[4]
    if abs(dl) >= mn or abs(dff) >= mn: out.append((lvl, k, va[0], vb[0], dl, va[4], vb[4], dff, la is None, lb is None))
out.sort(key=lambda r: (r[0], -abs(r[4])))
print(f"{'path':70s} {'LUTs a':>8s} {'LUTs b':>8s} {'dLUT':>6s} {'FFs a':>7s} {'FFs b':>7s} {'dFF':>5s}")
for r in out:
    tag = ' (new)' if r[8] else ' (gone)' if r[9] else ''
    k = re.sub(r'kv260_top/u_soc/', '', r[1]); k = re.sub(r'g_core\[(\d)\]\.g_tgc/u_core', r'c\1', k)
    print(f"{k[:70]:70s} {r[2]:8d} {r[3]:8d} {r[4]:+6d} {r[5]:7d} {r[6]:7d} {r[7]:+5d}{tag}")
