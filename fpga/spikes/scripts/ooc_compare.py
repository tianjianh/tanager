#!/usr/bin/env python3
"""DR-191's per-fix out-of-context check: each family's worst path in a fix's run against the baseline's (paths.txt of
ooc_run.tcl with paths_dr191.tcl), and the core's WNS, LUTs and FFs.   ooc_compare.py <base run dir> <fix run dir>..."""
import re, sys
def rd(d):
    p = {}
    for l in open(f'{d}/paths.txt'):
        m = re.match(r'(\S+)\s+slack\s+(-?[\d.]+)\s+levels\s+(\d+)\s+logic\s+([\d.]+)\s+net\s+([\d.]+)\s+(\S+) -> (\S+)', l)
        if m: p[m.group(1)] = (float(m.group(2)), int(m.group(3)), float(m.group(4)), float(m.group(5)), m.group(6), m.group(7))
    s = dict(l.split(None, 1) for l in open(f'{d}/summary.txt') if l.strip() and len(l.split(None, 1)) == 2)
    u = open(f'{d}/util.rpt').read()
    lut = re.search(r'^\| CLB LUTs\s+\|\s+(\d+)', u, re.M); ff = re.search(r'^\| CLB Registers\s+\|\s+(\d+)', u, re.M)
    return p, float(s['wns_ns']), int(lut.group(1)), int(ff.group(1))
base = rd(sys.argv[1])
for d in sys.argv[2:]:
    fx = rd(d)
    print(f"== {d.rstrip('/').split('/')[-1]} against {sys.argv[1].rstrip('/').split('/')[-1]}: WNS {fx[1]:+.3f} ({fx[1]-base[1]:+.3f}), LUTs {fx[2]} ({fx[2]-base[2]:+d}), FFs {fx[3]} ({fx[3]-base[3]:+d})")
    print(f"{'family':15s} {'slack':>15s} {'levels':>9s} {'logic ns':>13s} {'net ns':>13s}  start of the fix's worst")
    for k in base[0]:
        b = base[0][k]; f = fx[0].get(k)
        if not f: print(f"{k:15s} (none)"); continue
        print(f"{k:15s} {b[0]:+.3f}->{f[0]:+.3f} {b[1]:>3d}->{f[1]:<3d}  {b[2]:.2f}->{f[2]:.2f}  {b[3]:.2f}->{f[3]:.2f}  {f[4]}")
