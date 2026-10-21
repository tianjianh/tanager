"""Every TAGE training update of a program in the RTL and in tgsim, aligned in commit order: where the streams part
(area_recovery.md §6.16). The RTL's from tg_vsim built with prof_tage.sv bound in (make -C sim ... COV_EVENTS=<it>),
run with +ptage_all; the model's from TGSIM_BTTRACE=all, on stderr.
  python3 scripts/rtlprof/tage_cmp.py <tg_vsim output, grep "^PT "> <tgsim stderr, grep "^MT ">"""
import re
import sys
from collections import Counter

def parse(line):
    f = line.split()
    if f[1] == "D":
        return None
    base, slot, taken, pred = f[3], int(f[4]), f[5][-1], f[6][-1]
    if line.startswith("PT"):
        rest = " ".join(f[8:])
        tabs = re.findall(r"t(\d):(\w+)/(\w+) (\S+) (\S+) > (\S+) (\S+)", rest)
        ix = tuple((t[1], t[2]) for t in tabs)
        before = tuple((t[3], t[4]) for t in tabs)
        bb = f[7][2:].split("/")[0]
    else:
        head = line.split(" > ")[0].split()
        tabs = [(head[i][head[i].index(":") + 1:], head[i + 1], head[i + 2]) for i in range(len(head))
                if re.match(r"t\d:", head[i])]
        ix = tuple(tuple(t[0].split("/")) for t in tabs)
        before = tuple((t[1], t[2]) for t in tabs)
        bb = head[7][2:]
    return dict(key=(base, slot, taken, ix), pred=pred, before=before, bb=bb, cyc=int(f[2]))

rtl, mod, rd, md = [], [], 0, 0
for l in open(sys.argv[1]):
    e = parse(l)
    if e: rtl.append(e)
    else: rd += 1
for l in open(sys.argv[2]):
    e = parse(l)
    if e: mod.append(e)
    else: md += 1
print(f"RTL {len(rtl)} updates, {rd} drops; model {len(mod)} updates, {md} drops")
i = j = 0
only_rtl, only_mod, state, pred = [], [], [], []
while i < len(rtl) and j < len(mod):
    if rtl[i]["key"] == mod[j]["key"]:
        if rtl[i]["before"] != mod[j]["before"] or rtl[i]["bb"] != mod[j]["bb"]:
            state.append((i, j))
        if rtl[i]["pred"] != mod[j]["pred"]:
            pred.append((i, j))
        i += 1; j += 1
        continue
    # an update one side lacks: look ahead a little on each side
    a = next((k for k in range(j, min(j + 8, len(mod))) if mod[k]["key"] == rtl[i]["key"]), None)
    b = next((k for k in range(i, min(i + 8, len(rtl))) if rtl[k]["key"] == mod[j]["key"]), None)
    if a is not None and (b is None or a - j <= b - i):
        only_mod.extend(range(j, a)); j = a
    elif b is not None:
        only_rtl.extend(range(i, b)); i = b
    else:
        only_rtl.append(i); only_mod.append(j); i += 1; j += 1
print(f"aligned to RTL {i} / model {j}; only in the model {len(only_mod)}, only in the RTL {len(only_rtl)}; "
      f"same update, different state {len(state)}, different fetch-time direction {len(pred)}")
for name, lst in (("first only-in-model", only_mod[:3]),):
    for k in lst:
        print(f"{name}: model #{k} cycle {mod[k]['cyc']} {mod[k]['key'][:3]}")
if state:
    a, b = state[0]
    print(f"first state difference: RTL #{a} (cycle {rtl[a]['cyc']}) model #{b} (cycle {mod[b]['cyc']}) "
          f"{rtl[a]['key'][:3]}")
    print("   RTL  ", rtl[a]["bb"], rtl[a]["before"])
    print("   model", mod[b]["bb"], mod[b]["before"])
