#!/usr/bin/env python3
"""For each path report given (spikes §8.18, the indirect-target table's heads): its levels, the first level whose
cell or output net is in the table (u_itt), the first level in TAGE (u_tage), and the table's cells on the path.
Run from the worktree's root.  itt_levels.py <path_*.rpt>..."""
import re, subprocess, sys
for f in sys.argv[1:]:
    out = subprocess.run([sys.executable, 'fpga/spikes/scripts/path_table.py', f], capture_output=True, text=True).stdout
    rows = [l for l in out.splitlines() if re.match(r'\s*\d+ ', l)]
    itt = [(int(l.split()[0]), l.split('  ')[-1].strip()) for l in rows if 'u_itt' in l]
    tage = [int(l.split()[0]) for l in rows if 'g_tage.u_tage/' in l.split('->')[0]]
    print(f"{f.split('/')[-2]:<13} {f.split('/')[-1][5:-4]:<12} levels {len(rows):>2}  u_itt from {itt[0][0] if itt else '-':>2}  u_tage from {tage[0] if tage else '-':>2}")
    for n, s in itt:
        print(f"    {n:>2}  {re.sub(r'u_fetch/', '', s)}")
