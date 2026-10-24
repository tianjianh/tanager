#!/usr/bin/env python3
# Sorts one unit's q_cell_groups.tcl families into functional categories (spikes §8.18's area exploration, the
# coordinator 10-21: the LSU and rename breakdowns). Each family is attributed by the first rule matching its name
# (rules: an ordered list of (regex, category) in a JSON file). Failing that, it goes to the RTL section that
# declares its base signal: the nearest "// ----" or "// ====" header above the declaration in the unit's source,
# mapped by the rules' "sections" table. Anything left is "unassigned", listed. Prints each category's LUT cells,
# flip-flops and LUTRAM sites, and its largest families.
#   python3 -I unit_categories.py <groups.tsv> <unit> <unit.sv> <rules.json> [top-per-category=6]
import json, re, sys
from collections import defaultdict

groups, unit, src, rules_p = sys.argv[1:5]
top = int(sys.argv[5]) if len(sys.argv) > 5 else 6
rules = json.load(open(rules_p))
fam_rules = [(re.compile(r), c) for r, c in rules["families"]]
sec_rules = [(re.compile(r), c) for r, c in rules["sections"]]

# the section each declared identifier sits in
lines = open(src).read().split("\n")
section, decl = "(head)", {}
for ln in lines:
    m = re.match(r"\s*// (?:-{4}|={4,}) ?(.*?) ?(?:-{4}|={4,})?\s*$", ln)
    if m and m.group(1):
        section = m.group(1).strip(" -=")
        continue
    code = ln.split("//", 1)[0]
    m = re.match(r"\s*(?:logic|wire|reg|tid_t|robid_t|lqid_t|sqid_t|[a-z_]+_[te]|[a-z_]+_t)\b[^;=(]*?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\]]*\]\s*)*(?:[;,=])", code)
    if m:
        for name in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\]]*\]\s*)*(?=[;,=])", code.split("=", 1)[0]):
            decl.setdefault(name, section)
    m = re.match(r"\s*(tg_[a-z0-9_]+)\s*(?:#\s*\(.*)?\s*(u_[a-z0-9_]+)\s*\(", code)
    if m:
        decl.setdefault(m.group(2), section)

def base(fam):
    f = fam.rstrip("/")
    f = f.split("/")[0]
    f = re.sub(r"\[\]", "", f)
    f = f.split(".")[-1] if f.startswith("g_") and "." in f else f
    f = re.sub(r"^FSM_(onehot|sequential)_", "", f)
    return f

cat = defaultdict(lambda: [0, 0, 0])
members = defaultdict(list)
for ln in open(groups):
    u, f, l, ff, r = ln.rstrip("\n").split("\t")
    if u != unit:
        continue
    v = [int(l), int(ff), int(r)]
    c = None
    for rx, cc in fam_rules:
        if rx.search(f):
            c = cc
            break
    if c is None:
        sec = decl.get(base(f))
        if sec is not None:
            for rx, cc in sec_rules:
                if rx.search(sec):
                    c = cc
                    break
            if c is None:
                c = "section: " + sec
    if c is None:
        c = "unassigned"
    for i in range(3):
        cat[c][i] += v[i]
    members[c].append((v[0], v[1], v[2], f))

tot = [sum(v[i] for v in cat.values()) for i in range(3)]
print("== %s: %d LUT cells, %d FFs, %d LUTRAM sites" % (unit, tot[0], tot[1], tot[2]))
print("%-44s %7s %6s %6s %6s   %s" % ("category", "LUTs", "share", "FFs", "LUTRAM", "largest families (LUT cells)"))
for c, v in sorted(cat.items(), key=lambda x: -x[1][0]):
    big = sorted(members[c], key=lambda x: -x[0])[:top]
    print("%-44s %7d %5.1f%% %6d %6d   %s" % (c[:44], v[0], 100.0 * v[0] / max(tot[0], 1), v[1], v[2],
          ", ".join("%s %d" % (m[3], m[0]) for m in big if m[0] > 0)))
