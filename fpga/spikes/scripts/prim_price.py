#!/usr/bin/env python3
"""Cost tables of the shared primitives (docs/perf/fpga_friendly.md, T2/T4/T5/T6) from the
price tops' synthesis reports (fpga/spikes/rtl/tg_prim_eval.sv, tg_pp_*).

  python3 -I fpga/spikes/scripts/prim_price.py <unit-dir> [mw|mwff|cam|fifo|cmp]...

<unit-dir> holds one directory per price run (pp_mw, pp_mwff, pp_cam, pp_fifo, pp_cmp), each
with the util_hier.rpt that fpga/budget/tcl/unit_synth.tcl writes after opt_design. Each
instance's generate indices map back to its configuration; LUTs include LUTRAM.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "budget"))
import hier_top  # noqa: E402  (fpga/budget/hier_top.py: util_hier.rpt parser)


def instances(path):
    """{index tuple: row} for the instances at depth 1 named g_x[i].g_y[j]... .u"""
    out = {}
    for r in hier_top.rows(path):
        if r["depth"] != 1:
            continue
        idx = tuple(int(x) for x in re.findall(r"\[(\d+)\]", r["path"]))
        if idx:
            out[idx] = r
    return out


def cell(r):
    """LUTs (all) / LUTs as memory (LUTRAM and shift registers) / flip-flops"""
    return f"{r['lut']:,} / {r['lutram'] + r['srl']:,} / {r['ff']:,}"


def mw(d, dff):
    ds, ws, nws, nrs = (32, 64, 128), (8, 32), (2, 4), (4, 8)
    imps = ("LVT in LUTRAM", "LVT in flip-flops", "XOR")
    a = instances(os.path.join(d, "util_hier.rpt"))
    b = instances(os.path.join(dff, "util_hier.rpt")) if dff else {}
    print("| Depth x width | Writers x readers | " +
          " | ".join(f"{m}: LUTs / memory LUTs / FFs" for m in imps) + " | Flip-flops: LUTs / FFs |")
    print("|---|---|" + "---|" * (len(imps) + 1))
    for di, dep in enumerate(ds):
        for wi, wid in enumerate(ws):
            for ni, nw in enumerate(nws):
                for ri, nr in enumerate(nrs):
                    cells = [cell(a[(di, wi, ni, ri, i)]) if (di, wi, ni, ri, i) in a else "—"
                             for i in range(3)]
                    ff = "—"
                    if wid == 8 and (di, ni, ri) in b:
                        x = b[(di, ni, ri)]
                        ff = f"{x['lut']:,} / {x['ff']:,}"
                    print(f"| {dep} x {wid} | {nw} x {nr} | " + " | ".join(cells) + f" | {ff} |")
    if dff:
        for r in hier_top.rows(os.path.join(dff, "util_hier.rpt")):
            if r["depth"] == 1 and "g_w32" in r["path"]:
                print(f"\nFlip-flop baseline at 64 x 32, 4 writers x 8 readers: {r['lut']:,} LUTs, "
                      f"{r['ff']:,} flip-flops.")


def cam(d):
    es, ks = (16, 32, 64), (20, 30, 40)
    imps = ("LUTRAM, second read port", "LUTRAM, shared port", "Flip-flops")
    a = instances(os.path.join(d, "util_hier.rpt"))
    print("| Entries x key bits | " + " | ".join(f"{m}: LUTs / memory LUTs / FFs" for m in imps) + " |")
    print("|---|" + "---|" * len(imps))
    for ei, e in enumerate(es):
        for ki, k in enumerate(ks):
            cells = [cell(a[(ei, ki, i)]) if (ei, ki, i) in a else "—" for i in range(3)]
            print(f"| {e} x {k} | " + " | ".join(cells) + " |")


def fifo(d):
    ds, ws = (4, 8, 16, 32), (8, 32, 64)
    sts = ("srl", "lutram", "reg")
    a = instances(os.path.join(d, "util_hier.rpt"))
    print("| Depth x width | " + " | ".join(f"`{s}`: LUTs / memory LUTs / FFs" for s in sts) + " |")
    print("|---|" + "---|" * len(sts))
    for di, dep in enumerate(ds):
        for wi, wid in enumerate(ws):
            cells = [cell(a[(di, wi, i)]) if (di, wi, i) in a else "—" for i in range(3)]
            print(f"| {dep} x {wid} | " + " | ".join(cells) + " |")


def cmp(d):
    ws = (16, 32, 48)
    imps = ("DSP, latency 1", "DSP, latency 2", "Fabric")
    a = instances(os.path.join(d, "util_hier.rpt"))
    print("| Width | " + " | ".join(f"{m}: LUTs / FFs / DSP" for m in imps) + " |")
    print("|---|" + "---|" * len(imps))
    for wi, w in enumerate(ws):
        cells = []
        for i in range(3):
            r = a.get((wi, i))
            cells.append(f"{r['lut']:,} / {r['ff']:,} / {r['dsp']}" if r else "—")
        print(f"| {w} | " + " | ".join(cells) + " |")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    d = sys.argv[1]
    which = sys.argv[2:] or ["mw", "cam", "fifo", "cmp"]

    def run(name):   # a rerun (name2) supersedes the first run
        return os.path.join(d, name + "2") if os.path.isdir(os.path.join(d, name + "2")) \
            else os.path.join(d, name)
    for w in which:
        print(f"\n### {w}\n")
        if w == "mw":
            mw(run("pp_mw"), run("pp_mwff"))
        elif w == "cam":
            cam(run("pp_cam"))
        elif w == "fifo":
            fifo(run("pp_fifo"))
        elif w == "cmp":
            cmp(run("pp_cmp"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
