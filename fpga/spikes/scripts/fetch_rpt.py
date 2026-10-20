#!/usr/bin/env python3
# Timelines of the paths in q_fetch_paths.tcl's fetch_paths.rpt (the fetch timing study, 10-20): per path, each hop's
# cell (type, delay) and net (fanout, delay), with the time since the launch clock edge at the net's end.
#   python3 -I fetch_rpt.py <fetch_paths.rpt> [section-regex]      (prints every section matching the regex)
import re, sys

def sections(text):
    cur = None
    for ln in text.split("\n"):
        if ln.startswith("######## "):
            if cur: yield cur
            cur = [ln[9:], []]
        elif cur is not None:
            cur[1].append(ln)
    if cur: yield cur

def strip(name):
    return re.sub(r"^u_soc/g_core\[\d\]\.g_tgc\.u_core/", "", name)

def parse(lines):
    info, hops = {}, []
    for ln in lines:
        m = re.match(r"Slack \((\w+)\) :\s+(-?[0-9.]+)ns", ln)
        if m: info["slack"] = float(m.group(2))
        m = re.match(r"\s+Logic Levels:\s+(\d+)", ln)
        if m: info["levels"] = int(m.group(1))
        m = re.match(r"\s+Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns.*route ([0-9.]+)ns", ln)
        if m: info["dp"], info["logic"], info["route"] = map(float, m.groups())
        m = re.match(r"\s+Clock Path Skew:\s+(-?[0-9.]+)ns", ln)
        if m: info["skew"] = float(m.group(1))
    # the data path: after the launch clock's pin, up to the separator before the capture clock
    seps = [i for i, ln in enumerate(lines) if re.match(r"\s+-{60,}\s+-{10,}", ln)]
    if len(seps) < 3: return info, hops
    body = lines[seps[1] + 1:seps[2]]
    t0, cell = None, None
    i = 0
    while i < len(body):
        ln = body[i]
        m = re.match(r"\s+\S+\s+([A-Z0-9_]+) \((Prop_[^)]*)\)", ln)
        if m:
            nxt = body[i + 1] if i + 1 < len(body) else ""
            n2 = re.match(r"\s+(-?[0-9.]+)\s+(-?[0-9.]+) [rf]\s+(\S+)", nxt)
            if n2:
                d, p = float(n2.group(1)), float(n2.group(2))
                if t0 is None: t0 = p - d
                cell = [m.group(1), d, strip(n2.group(3))]
                i += 2
                continue
        m = re.match(r"\s+net \(fo=(\d+), routed\)\s+([0-9.]+)\s+([0-9.]+)\s+(\S+)", ln)
        if m and cell:
            hops.append(cell + [int(m.group(1)), float(m.group(2)), float(m.group(3)) - t0, strip(m.group(4))])
            cell = None
        i += 1
    m = [ln for ln in body if re.match(r"\s+\S+\s+\S+\s+[rf]\s+\S+/[A-Z0-9_\[\]]+$", ln)]
    info["end"] = strip(m[-1].split()[-1]) if m else "?"
    return info, hops

if __name__ == "__main__":
    text = open(sys.argv[1]).read()
    rx = re.compile(sys.argv[2]) if len(sys.argv) > 2 else None
    for head, lines in sections(text):
        if rx and not rx.search(head): continue
        info, hops = parse(lines)
        print("## %s: slack %.3f, %d levels, logic %.2f route %.2f, skew %.3f, to %s" % (
            head, info.get("slack", 0), info.get("levels", 0), info.get("logic", 0), info.get("route", 0),
            info.get("skew", 0), info.get("end", "?")))
        for t, d, pin, fo, nd, at, net in hops:
            print("   %-9s %.3f  fo%-4d %.3f  @%6.3f  %s" % (t, d, fo, nd, at, net))
