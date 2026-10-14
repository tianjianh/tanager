#!/usr/bin/env python3
"""Prints Markdown tables of spike results (fpga/spikes/results/<run>/summary.txt, paths.txt).

  python3 -I fpga/spikes/scripts/results_table.py [glob ...]     e.g. 's2_*' 's3_*'

One row per run: CLB LUTs (of which LUTRAM), FFs, CARRY8, BRAM tiles, URAM, DSP, worst
slack at the run's clock, Fmax estimate, logic levels and the worst path's endpoints; then
the named paths of each run (slack, levels, logic/net delay).
"""
import pathlib
import sys

RES = pathlib.Path(__file__).resolve().parents[1] / "results"


def kv(path):
    d = {}
    if path.exists():
        for line in path.read_text().splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2:
                d[parts[0]] = parts[1].strip()
    return d


def short(pin):
    return pin.replace("/C", "").replace("/D", "")[:48]


def main():
    globs = sys.argv[1:] or ["*"]
    runs = sorted({p for g in globs for p in RES.glob(g) if (p / "summary.txt").exists()})
    print("| Run | Config | Generics | LUTs (LUTRAM) | FFs | CARRY8 | BRAM | URAM | DSP | WNS ns | Fmax MHz | Levels | Worst path |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in runs:
        s = kv(r / "summary.txt")
        tag = "impl" if "impl_lut_total" in s else "synth"
        g = lambda k: s.get(f"{tag}_{k}", "")
        print(f"| {r.name} | {s.get('cfg', '')} | {s.get('generics', '').replace(',', ' ')} | "
              f"{g('lut_total')} ({g('lut_dram')}) | {g('ff')} | {g('carry8')} | {g('bram_tile')} | "
              f"{g('uram')} | {g('dsp')} | {s.get('wns_ns', '')} | {s.get('fmax_mhz', '')} | "
              f"{s.get('worst_levels', '')} | {short(s.get('worst_from', ''))} → {short(s.get('worst_to', ''))} |")
    print()
    for r in runs:
        p = r / "paths.txt"
        if not p.exists():
            continue
        print(f"**{r.name}**\n")
        print("| Path | Slack ns | Levels | Logic ns | Net ns |")
        print("|---|---|---|---|---|")
        for line in p.read_text().splitlines():
            f = line.split()
            if len(f) >= 9 and f[1] == "slack":
                print(f"| {f[0]} | {f[2]} | {f[4]} | {f[6]} | {f[8]} |")
        print()


if __name__ == "__main__":
    main()
