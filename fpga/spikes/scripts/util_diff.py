#!/usr/bin/env python3
# Unit-by-unit difference of two `report_utilization -hierarchical` reports (spikes §8.18: q_util_hier.tcl's
# util_<label>.rpt). Each instance's path is rebuilt from the report's indentation; for every path in either
# report, prints Total LUTs, LUTRAMs and FFs of A and B and B - A, where |B - A| reaches the threshold, largest first.
#   python3 -I util_diff.py <A.rpt> <B.rpt> [threshold=150] [max-depth=4]
import re, sys

def parse(path):
    rows, cols, stack = {}, None, []
    for ln in open(path):
        if not ln.startswith("|"):
            continue
        cells = [c for c in ln.rstrip("\n").split("|")[1:-1]]
        if cols is None:
            if cells and cells[0].strip() == "Instance":
                cols = [c.strip() for c in cells]
            continue
        name = cells[0]
        if not name.strip() or name.strip() == "Instance":
            continue
        depth = (len(name) - len(name.lstrip(" "))) // 2
        inst = name.strip()
        stack = stack[:depth]
        stack.append(inst)
        key = "/".join(stack[1:]) if len(stack) > 1 else stack[0]
        vals = {}
        for c, v in zip(cols, cells):
            v = v.strip()
            if re.fullmatch(r"-?\d+(\.\d+)?", v):
                vals[c] = float(v)
        vals["_depth"] = depth
        rows[key] = vals
    return rows

def col(r, *names):
    for n in names:
        if n in r:
            return r[n]
    return 0.0

if __name__ == "__main__":
    a, b = parse(sys.argv[1]), parse(sys.argv[2])
    thr = float(sys.argv[3]) if len(sys.argv) > 3 else 150
    maxd = int(sys.argv[4]) if len(sys.argv) > 4 else 4
    out = []
    for k in sorted(set(a) | set(b)):
        ra, rb = a.get(k, {}), b.get(k, {})
        d = max(ra.get("_depth", 99), rb.get("_depth", 99)) if ra and rb else (ra or rb).get("_depth", 99)
        if d > maxd:
            continue
        la, lb = col(ra, "Total LUTs"), col(rb, "Total LUTs")
        if abs(lb - la) < thr:
            continue
        out.append((lb - la, k, la, lb, col(ra, "LUTRAMs"), col(rb, "LUTRAMs"), col(ra, "FFs"), col(rb, "FFs"), d))
    print("%-70s %9s %9s %8s   %7s %7s   %8s %8s" % ("instance (B - A, Total LUTs)", "A", "B", "B-A", "RAM A", "RAM B", "FF A", "FF B"))
    for dl, k, la, lb, ma, mb, fa, fb, d in sorted(out, key=lambda x: -abs(x[0])):
        print("%-70s %9.0f %9.0f %+8.0f   %7.0f %7.0f   %8.0f %8.0f" % ("  " * d + k.split("/")[-1] if d else k, la, lb, dl, ma, mb, fa, fb))
