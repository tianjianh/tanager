#!/usr/bin/env python3
"""The first full path of a report_timing -input_pins text, one row a level: the cell's location, type and input pin,
the net delay into it, its own delay, its output net's fanout and name.  path_table.py <report_timing.txt>"""
import re, sys
txt = open(sys.argv[1]).read()
i = txt.find('== the same')
body = txt[i:].split('Slack (', 2)[1] if i >= 0 else txt
lines = body.splitlines()
short = lambda s: re.sub(r'u_soc/g_core\[(\d)\]\.g_tgc\.u_core/', r'c\1:', s)
rows, pend_net, cur = [], None, None
started = False
for k, l in enumerate(lines):
    # A register or a block RAM (the I$ data, TAGE's tables) starts the path
    if re.search(r'(FD[RSCP]E|RAMB(36|18)E2) \(Prop_', l):
        started = True
    if not started:
        continue
    m = re.match(r'\s+net \(fo=(\d+), routed\)\s+([\d.]+)\s+([\d.]+)\s+(\S+)', l)
    if m:
        if cur is not None:
            cur['fo'], cur['out'], cur['net_out'] = m.group(1), short(m.group(4)), float(m.group(2))
            rows.append(cur)
            cur = None
        pend_net = float(m.group(2))
        continue
    # An out-of-context run's reports carry a PBlock column before the pin
    m = re.match(r'\s+(SLICE_\S+|RAMB\S+|DSP\S+)\s+([rf])\s+(?:\S+\s+)?(\S+)$', l.rstrip())
    if m and pend_net is not None:
        cur = {'loc': m.group(1), 'pin': short(m.group(3)), 'net_in': pend_net}
        continue
    m = re.match(r'\s+\S+\s+(\w+) \(Prop_[^)]*\)', l)
    if m and cur is not None:
        cur['type'] = m.group(1)
        d = re.match(r'\s+([-\d.]+)\s+([\d.]+)\s+[rf]\s+(\S+)', lines[k + 1])
        if d:
            cur['dly'], cur['at'] = float(d.group(1)), float(d.group(2))
        continue
dst = re.search(r'Destination:\s+(\S+)', body)
hdr = re.search(r'Data Path Delay:.*', body)
skew = re.search(r'Clock Path Skew:\s+\S+', body)
print(f"{'lvl':>3} {'loc':<14} {'type':<7} {'net in':>6} {'cell':>6} {'at':>7} {'fo':>4}  input pin -> output net")
for n, r in enumerate(rows, 1):
    print(f"{n:>3} {r['loc']:<14} {r.get('type','?'):<7} {r['net_in']:>6.3f} {r.get('dly',0):>6.3f} {r.get('at',0):>7.3f} {r['fo']:>4}  {r['pin']} -> {r['out']}")
if rows and dst:
    print(f"end: {short(dst.group(1))} (net in {rows[-1]['net_out']:.3f})")
if hdr: print(hdr.group(0).strip())
if skew: print(skew.group(0).strip())
