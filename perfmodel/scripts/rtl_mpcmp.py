"""Calibration aid (scripts/rtlcal.py): mispredicts by PC, the RTL's refill gaps (>= 8 cycles after a retired control
instruction in tg_vsim's commit trace, inside the region) against tgsim's TGSIM_MPDUMP. Prints the PCs that differ most.
  python3 scripts/rtl_mpcmp.py <tg_vsim --log file> <region start cycle> <region end cycle> <TGSIM_MPDUMP file>"""
import collections
import re
import sys

log, lo, hi, dump = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
pat = re.compile(r"^\s*(\d+)\s+h0\s+\S+\s+retire\s+pc=([0-9a-f]+)\s+\(([0-9a-f]+)\)\s+(\S+)\s*(.*)$")
rows = []
for line in open(log, errors="replace"):
    m = pat.match(line)
    if m and lo <= int(m.group(1)) <= hi:
        rows.append((int(m.group(1)), int(m.group(2), 16), m.group(4), m.group(5).split("  ")[0].strip()))
isctrl = lambda op: op.startswith(("b", "c.b", "j", "c.j", "ret", "c.ret", "call", "tail"))
rtl, count, text = collections.Counter(), collections.Counter(), {}
gap_sum = 0
for (c0, pc0, op0, a0), (c1, _, _, _) in zip(rows, rows[1:]):
    if not isctrl(op0):
        continue
    count[pc0] += 1
    text[pc0] = f"{op0} {a0}"
    if c1 - c0 >= 8:
        rtl[pc0] += 1
        gap_sum += c1 - c0
model = collections.Counter()
for line in open(dump):
    pc, n = line.split()
    model[int(pc, 16)] = int(n)
print(f"RTL refills {sum(rtl.values())} (mean gap {gap_sum / max(1, sum(rtl.values())):.1f}), model mispredicts {sum(model.values())}")
pcs = sorted(set(rtl) | set(model), key=lambda p: -abs(rtl[p] - model[p]))
print("| PC | instruction | executions | RTL refills | model mispredicts |")
print("|---|---|---|---|---|")
for p in pcs[:25]:
    print(f"| {p:x} | {text.get(p, '?')} | {count[p]} | {rtl[p]} | {model[p]} |")
