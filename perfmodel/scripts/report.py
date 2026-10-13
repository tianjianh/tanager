"""Turns results/dse_summary_<isa>.json and results/calibration.json into generated tables and charts:
docs/perf/dse_tables[_<isa>].md, docs/perf/ledger_table.md, docs/perf/ipc_vs_latency[_<isa>].svg and
docs/perf/ratio_vs_latency[_<isa>].svg. The hand-written analysis is in docs/perf/dse_report.md."""
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT.parent / "docs" / "perf"
CORE_LUTS = 41000.0  # plan draft 0.3, section 8.2 (estimate)
SOC_LUTS = 94000.0
DECISION = (("30", "native30"), ("120", "design120"), ("250", "stress250"))

# Per-feature LUT cost estimates (per core unless marked SoC). Estimates, pending synthesis (spikes S2-S6).
LUT_COST = {
    "TAGE-lite -> 4 KB gshare": (800, "core", "hashing and tag compare for 4 tables, update logic; storage in BRAM"),
    "micro-BTB off": (700, "core", "32-entry fully associative flip-flop CAM and target mux"),
    "checkpoints off (recover at commit)": (1000, "core", "8 LUTRAM rename snapshots, restore mux, free-list heads"),
    "SFB predication off": (500, "core", "decode conversion, 3-operand select, candidate table"),
    "jump folding off": (100, "core", "decode skip and retire-count credit"),
    "fusion off": (400, "core", "pair detection and merged uop formation"),
    "speculative load wakeup off": (500, "core", "hit predictor, shadow cancel, row hold"),
    "early retirement off": (900, "core", "long-latency tag columns, completion buffer, deferred free"),
    "memory-dependence wait table off": (100, "core", "1K-bit table (LUTRAM) and check"),
    "branch-first select off": (50, "core", "priority term in IQ-A0 select"),
    "ownership prefetch off": (100, "core", "request on store-address resolution"),
    "L1D stride prefetcher off": (300, "core", "16-entry PC-stride table"),
    "L2 stream prefetcher off": (400, "SoC", "8-stream table in the L2"),
    "I-side prefetch off (FDIP + next line)": (200, "core", "FTQ-directed request and second I$ MSHR"),
    "L1D MSHRs 12 -> 8": (300, "core", "4 MSHRs with fill buffers"),
    "L1s 32 KiB -> 16 KiB": (200, "core", "tags/LRU; data is BRAM (+12 BRAM36)"),
    "L2 1 MiB -> 512 KiB": (200, "SoC", "tags; data is UltraRAM (+16 URAM)"),
    "+ALU+branch fusion": (300, "core", "extra pair patterns, branch uop with a destination"),
    "+micro-BTB 64 entries": (100, "core", "64 x 2-way LUTRAM instead of 32 flip-flop entries"),
    "+second load pipe": (1500, "core", "second AGU/DTLB port, LQ search port, D$ read port (+8 BRAM36)"),
    "+radix-16 FP divide/sqrt": (1200, "core", "two overlapped radix-4 stages per cycle instead of one (divide and "
                                               "square root share the unit)"),
    "+Goldschmidt divide/sqrt, 10-bit seed": (200, "core", "net of the radix-4 unit it replaces: operand muxes, 2 - D, "
                                                         "partial-product sums, remainder correction, sequencing; the "
                                                         "multipliers are DSPs"),
    "+Goldschmidt divide/sqrt, 14-bit seed": (300, "core", "as the 10-bit seed, plus bipartite seed-table logic"),
    "+second FMA pipe": (4400, "core", "second FMA datapath (~2.5K), third FP bank and 7 read ports per bank (~1.3K), "
                                       "FP bypass and second issue port (~0.6K)"),
}


# Other costs per feature: (BRAM/URAM, protected loop or timing exposure (plan section 8.1), verification surface).
FEATURE_NOTES = {
    "TAGE-lite -> 4 KB gshare": ("+1 to 3 BRAM36", "none (overrides the micro-BTB a stage later)", "low: prediction only"),
    "micro-BTB off": ("none", "is the next-PC loop", "low: prediction only"),
    "checkpoints off (recover at commit)": ("none", "rename restore select", "high: recovery"),
    "SFB predication off": ("none", "third operand on P0; select on the ALU0 bypass", "medium: retire count, debug rules"),
    "jump folding off": ("none", "none", "medium: retire count"),
    "fusion off": ("none", "decode only", "medium: faulting second half re-executes unfused"),
    "speculative load wakeup off": ("none", "wakeup-select loop: shadow cancel", "high: cancel and replay"),
    "early retirement off": ("none", "LLT columns in the wakeup matrix", "high: precise state, ordering, writeback records"),
    "memory-dependence wait table off": ("none", "none", "low"),
    "branch-first select off": ("none", "IQ-A0 select priority term", "low"),
    "ownership prefetch off": ("none", "none", "low-medium: coherence requests"),
    "L1D stride prefetcher off": ("none", "none", "low"),
    "L2 stream prefetcher off": ("none", "none", "low"),
    "I-side prefetch off (FDIP + next line)": ("none", "none", "low"),
    "L1D MSHRs 12 -> 8": ("none", "MSHR CAM on the miss path", "medium"),
    "L1s 32 KiB -> 16 KiB": ("+12 BRAM36 per core", "8-way way select on the load-to-use path", "low"),
    "L2 1 MiB -> 512 KiB": ("+16 URAM", "none", "low"),
    "+ALU+branch fusion": ("none", "branch unit gains an ALU result write", "medium"),
    "+micro-BTB 64 entries": ("none", "next-PC loop through LUTRAM (the plan's fallback)", "low"),
    "+second load pipe": ("+8 BRAM36 per core", "second AGU, DTLB port and LQ search port", "high: two-load ordering"),
    "+radix-16 FP divide/sqrt": ("none", "longer quotient-digit selection path in the iterative unit", "medium: TestFloat"),
    "+Goldschmidt divide/sqrt, 10-bit seed": ("+1 BRAM18, +24 DSP48E2", "DSP cascades (registered, 4 stages)",
                                              "medium-high: correct rounding needs the remainder step; TestFloat"),
    "+Goldschmidt divide/sqrt, 14-bit seed": ("+2-4 BRAM36, +24 DSP48E2", "as 10-bit seed",
                                              "medium-high: as 10-bit seed"),
    "+second FMA pipe": ("+12 DSP48E2", "FP bypass network grows; FP register read ports 4 -> 7",
                         "medium: TestFloat per pipe, issue/writeback arbitration"),
}

# Structure-size LUT cost estimates: param -> (LUTs as a function of the swept value, scope, basis).
SIZE_COST = {
    "rob": (lambda v: 30 * v, "core", "about 30 LUTs/entry: ROB LUTRAM and completion bits, plus one dependency "
                                      "column in every issue-queue row (registers held at 3 x 64)"),
    "iq": (lambda v: 80 * (4 * v + max(4, 2 * v // 3)), "core", "about 80 LUTs/entry (plan section 8.2: 4.6K for 56 "
                                                               "entries); A0, A1, LD and FP change by v, STA by 2v/3"),
    "lq": (lambda v: 40 * v, "core", "about 40 LUTs per CAM entry"),
    "sq": (lambda v: 50 * v, "core", "about 50 LUTs per entry (CAM, forwarding select, data in LUTRAM)"),
    "lqcb": (lambda v: 8 * v, "core", "about 8 LUTs per completion-buffer entry (LUTRAM, no CAM)"),
    "l1d_mshr": (lambda v: 75 * v, "core", "about 75 LUTs per MSHR with its fill buffer in LUTRAM"),
    "l2_mshr": (lambda v: 50 * v, "SoC", "about 50 LUTs per L2 MSHR"),
    "l1i_mshr": (lambda v: 60 * v, "core", "about 60 LUTs per L1I MSHR with its line buffer"),
    "ubtb": (lambda v: {0: 0, 16: 350, 32: 700, 64: 800, 128: 860}[v], "core",
             "16 and 32 entries: fully associative flip-flops (about 22 LUTs/entry); 64 and 128: 2-way LUTRAM"),
    "llt": (lambda v: 25 * v, "core", "about 25 LUTs per tag: one dependency column in every issue-queue row"),
    "tage_log": (lambda v: 30 * v, "core", "LUTs nearly flat; the four tagged tables are BRAM: about 2, 2, 4 and 8 "
                                           "BRAM36 at log2 sizes 9, 10, 11 and 12"),
    "ckpt": (lambda v: 125 * v, "core", "about 125 LUTs per checkpoint (LUTRAM snapshot and restore select)"),
    "pf_stride_dist": (lambda v: 0, "core", "run-time register (plan section 4.11)"),
    "pf_stream_dist": (lambda v: 0, "SoC", "run-time register"),
    "lat_fma": (lambda v: 0, "core", "FMA pipeline depth: the cost is timing (DSP48E2 cascade at 200 MHz), not LUTs; "
                                     "the plan allows 4-5 cycles"),
}


def pct(a, b):
    return (a / b - 1.0) * 100.0 if b else 0.0


def fmt(x, nd=3):
    return f"{x:.{nd}f}"


def svg_chart(path, title, xlabel, ylabel, xs, series, refs=(), ymin=None, ymax=None):
    """series: list of (label, ys, color, dash). refs: list of (y, label). Plain SVG, no dependencies."""
    W, H, ml, mr, mt, mb = 720, 420, 64, 210, 40, 52
    pw, ph = W - ml - mr, H - mt - mb
    ally = [y for _, ys, _, _ in series for y in ys] + [r[0] for r in refs]
    lo = min(ally) if ymin is None else ymin
    hi = max(ally) if ymax is None else ymax
    span = (hi - lo) or 1.0
    step = next(s for s in (0.05, 0.1, 0.2, 0.25, 0.5, 1.0, 2.0, 5.0) if span / s <= 8)
    lo = math.floor(lo / step + 1e-9) * step
    hi = math.ceil(hi / step + 0.25) * step
    x0, x1 = min(xs), max(xs)
    X = lambda x: ml + (x - x0) / (x1 - x0) * pw  # noqa: E731
    Y = lambda y: mt + (1 - (y - lo) / (hi - lo)) * ph  # noqa: E731
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif" '
         f'font-size="12">', f'<rect width="{W}" height="{H}" fill="#ffffff"/>',
         f'<text x="{ml}" y="22" font-size="15" font-weight="bold" fill="#222">{title}</text>']
    # grid and ticks
    for i in range(int(round((hi - lo) / step)) + 1):
        yv = lo + i * step
        o.append(f'<line x1="{ml}" x2="{ml + pw}" y1="{Y(yv):.1f}" y2="{Y(yv):.1f}" stroke="#e5e5e5"/>')
        o.append(f'<text x="{ml - 8}" y="{Y(yv) + 4:.1f}" text-anchor="end" fill="#555">{yv:.2f}</text>')
    for x in xs:
        o.append(f'<line x1="{X(x):.1f}" x2="{X(x):.1f}" y1="{mt}" y2="{mt + ph}" stroke="#eeeeee"/>')
        o.append(f'<text x="{X(x):.1f}" y="{mt + ph + 18}" text-anchor="middle" fill="#555">{x}</text>')
    o.append(f'<rect x="{ml}" y="{mt}" width="{pw}" height="{ph}" fill="none" stroke="#999"/>')
    o.append(f'<text x="{ml + pw / 2}" y="{H - 12}" text-anchor="middle" fill="#333">{xlabel}</text>')
    o.append(f'<text transform="translate(16,{mt + ph / 2}) rotate(-90)" text-anchor="middle" fill="#333">{ylabel}</text>')
    for i, (yv, lab) in enumerate(refs):
        o.append(f'<line x1="{ml}" x2="{ml + pw}" y1="{Y(yv):.1f}" y2="{Y(yv):.1f}" stroke="#c0392b" '
                 f'stroke-dasharray="2 4"/>')
        dy = 14 if i % 2 == 0 else -5  # alternate below/above the line so neighbouring labels do not collide
        o.append(f'<text x="{ml + pw - 4}" y="{Y(yv) + dy:.1f}" text-anchor="end" fill="#c0392b">{lab}</text>')
    for i, (lab, ys, color, dash) in enumerate(series):
        pts = " ".join(f"{X(x):.1f},{Y(y):.1f}" for x, y in zip(xs, ys))
        da = f' stroke-dasharray="{dash}"' if dash else ""
        o.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="2.2"{da}/>')
        for x, y in zip(xs, ys):
            o.append(f'<circle cx="{X(x):.1f}" cy="{Y(y):.1f}" r="3" fill="{color}"/>')
        ly = mt + 14 + i * 20
        o.append(f'<line x1="{ml + pw + 14}" x2="{ml + pw + 44}" y1="{ly}" y2="{ly}" stroke="{color}" '
                 f'stroke-width="2.2"{da}/>')
        o.append(f'<text x="{ml + pw + 50}" y="{ly + 4}" fill="#222">{lab}</text>')
    o.append("</svg>")
    path.write_text("\n".join(o) + "\n")


def charts(s, suffix):
    lat = s["latencies"]
    xs = list(lat.values())
    T = [s["baseline"][n]["tanager_v1"] for n in lat]
    N = [s["baseline"][n]["nax"] for n in lat]
    teal, orange = "#1f77b4", "#e67e22"
    series = []
    for key, lab, dash in (("suite_ipc", "suite", ""), ("kernels_ipc", "kernels", "7 4"),
                           ("embench_ipc", "Embench", "2 3"), ("memsuite_ipc", "memsuite", "10 3 2 3")):
        series.append((f"Tanager v1, {lab}", [t[key] for t in T], teal, dash))
        series.append((f"NaxRiscv-like, {lab}", [n[key] for n in N], orange, dash))
    svg_chart(DOCS / f"ipc_vs_latency{suffix}.svg", f"IPC vs DRAM latency ({s['isa']})",
              "L2-miss round trip to DRAM (core cycles)", "IPC (geomean)", xs, series, ymin=0)
    colors = {"suite_ipc": "#222222", "kernels_ipc": "#1f77b4", "embench_ipc": "#2ca02c", "memsuite_ipc": "#9467bd"}
    rs = [(lab, [t[k] / n[k] for t, n in zip(T, N)], colors[k], "")
          for k, lab in (("suite_ipc", "suite"), ("kernels_ipc", "kernels"), ("embench_ipc", "Embench"),
                         ("memsuite_ipc", "memsuite"))]
    svg_chart(DOCS / f"ratio_vs_latency{suffix}.svg", f"Tanager v1 / NaxRiscv-like IPC ratio ({s['isa']})",
              "L2-miss round trip to DRAM (core cycles)", "IPC ratio", xs, rs,
              refs=((1.15, "1.15 (section 0 target)"), (1.2, "1.2 (M1 exit)")), ymin=1.0)


def freeze_charts(f, suffix):
    """Suite IPC and ratio vs latency for draft-0.3 v1, the rule-only greedy freeze and the proposed freeze."""
    lat = f["latencies"]
    xs = list(lat.values())
    pick = [("v1 (draft 0.3)", "v1 (draft 0.3)", "#7f7f7f", "7 4"),
            ("greedy freeze (rule only)", "greedy, rule only", "#2ca02c", "2 3"),
            ("final C: B + FP IQ 10", "proposed v1 freeze", "#1f77b4", "")]
    pick = [p for p in pick if p[0] in f["candidates"]]
    ipc = [(lab, [f["candidates"][k]["by_lat"][ln]["suite_ipc"] for ln in lat], col, dash) for k, lab, col, dash in pick]
    ipc.append(("NaxRiscv-like control", [f["nax"][ln]["suite_ipc"] for ln in lat], "#e67e22", ""))
    svg_chart(DOCS / f"freeze_ipc_vs_latency{suffix}.svg", f"Suite IPC vs DRAM latency ({f['isa']})",
              "L2-miss round trip to DRAM (core cycles)", "suite IPC (geomean)", xs, ipc, ymin=0)
    rat = [(lab, [f["candidates"][k]["by_lat"][ln]["suite_ipc"] / f["candidates"][k]["nax_by_lat"][ln]["suite_ipc"]
                  for ln in lat], col, dash) for k, lab, col, dash in pick]
    svg_chart(DOCS / f"freeze_ratio_vs_latency{suffix}.svg", f"IPC ratio to the NaxRiscv-like control ({f['isa']})",
              "L2-miss round trip to DRAM (core cycles)", "suite IPC ratio", xs, rat,
              refs=((1.15, "1.15 (section 0 target)"), (1.2, "1.2 (M1 exit)")), ymin=1.0)


def baseline_tables(s):
    L = []
    lat = s["latencies"]
    L.append(f"## Tanager v1 vs the NaxRiscv-like control ({s['isa']}, identical binaries, same L2 and DRAM)\n")
    L.append("| DRAM round trip | Suite IPC T / N | Ratio | Kernels ratio | Embench ratio | Memsuite ratio | "
             "CoreMark/MHz A, B (T) | CoreMark/MHz A, B (N) | DMIPS/MHz T / N | MLP chase8 / chase16 / chase8f16 (T) | "
             "same (N) |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for name, cyc in lat.items():
        t, n = s["baseline"][name]["tanager_v1"], s["baseline"][name]["nax"]
        r = t["suite_ipc"] / n["suite_ipc"]
        L.append(f"| {cyc} cycles ({name}) | {fmt(t['suite_ipc'])} / {fmt(n['suite_ipc'])} | **{r:.3f}** | "
                 f"{t['kernels_ipc'] / n['kernels_ipc']:.3f} | {t['embench_ipc'] / n['embench_ipc']:.3f} | "
                 f"{t['memsuite_ipc'] / n['memsuite_ipc']:.3f} | {t['coremark_A']:.2f}, {t['coremark_B']:.2f} | "
                 f"{n['coremark_A']:.2f}, {n['coremark_B']:.2f} | {t['dmips']:.2f} / {n['dmips']:.2f} | "
                 f"{t['mlp_chase8']:.2f} / {t['mlp_chase16']:.2f} / {t['mlp_chase8f16']:.2f} | "
                 f"{n['mlp_chase8']:.2f} / {n['mlp_chase16']:.2f} / {n['mlp_chase8f16']:.2f} |")
    L.append("")
    L.append("## IPC retention (IPC at each point / IPC at 30 cycles)\n")
    names = list(lat)
    L.append("| Workload | " + " | ".join(f"T @{lat[n]}" for n in names[1:]) + " | "
             + " | ".join(f"N @{lat[n]}" for n in names[1:]) + " |")
    L.append("|---|" + "---|" * (2 * (len(names) - 1)))
    t0, n0 = s["baseline"][names[0]]["tanager_v1"]["ipc"], s["baseline"][names[0]]["nax"]["ipc"]
    for w in sorted(t0):
        tr = [s["baseline"][n]["tanager_v1"]["ipc"][w] / t0[w] for n in names[1:]]
        nr = [s["baseline"][n]["nax"]["ipc"][w] / n0[w] for n in names[1:]]
        L.append(f"| {w} | " + " | ".join(f"{x:.2f}" for x in tr) + " | " + " | ".join(f"{x:.2f}" for x in nr) + " |")
    L.append("")
    L.append("## Per-workload IPC at the 120-cycle decision point\n")
    t, n = s["baseline"]["design120"]["tanager_v1"], s["baseline"]["design120"]["nax"]
    L.append("| Workload | Tanager v1 | NaxRiscv-like | Ratio |")
    L.append("|---|---|---|---|")
    for w in sorted(t["ipc"]):
        L.append(f"| {w} | {t['ipc'][w]:.3f} | {n['ipc'][w]:.3f} | {t['ipc'][w] / max(1e-9, n['ipc'][w]):.2f} |")
    L.append("")
    return L


def tables(s, cal):
    L = ["# tgsim DSE tables (generated by perfmodel/scripts/report.py; do not edit)\n"]
    L += baseline_tables(s)
    if s.get("ablations"):
        L.append("## Ablations: Tanager v1 with one change (suite IPC change vs v1)\n")
        L.append("| Change | 30 cycles | 120 cycles | 250 cycles | Kernels @120 | Embench @120 | Memsuite @120 | "
                 "CoreMark A @120 | MLP chase8f16 @120 |")
        L.append("|---|---|---|---|---|---|---|---|---|")
        for name, a in s["ablations"].items():
            row = [pct(a["by_lat"][lt]["suite_ipc"], s["baseline"][bl]["tanager_v1"]["suite_ipc"]) for lt, bl in DECISION]
            v1 = s["baseline"]["design120"]["tanager_v1"]
            a120 = a["by_lat"]["120"]
            L.append(f"| {name} | {row[0]:+.1f}% | {row[1]:+.1f}% | {row[2]:+.1f}% | "
                     f"{pct(a120['kernels_ipc'], v1['kernels_ipc']):+.1f}% | {pct(a120['embench_ipc'], v1['embench_ipc']):+.1f}% | "
                     f"{pct(a120['memsuite_ipc'], v1['memsuite_ipc']):+.1f}% | {a120['coremark_A']:.2f} | "
                     f"{a120['mlp_chase8f16']:.2f} |")
        L.append("")
    if s.get("er_study"):
        L.append("## Early-retirement study (suite IPC, MLP of the pointer-chase tests)\n")
        L.append("| Configuration | Suite @30 | Suite @120 | Suite @250 | Memsuite @120 | chase8 MLP @120 | "
                 "chase8f16 MLP @120 | chase8f16 IPC @120 | chase8f16 MLP @250 |")
        L.append("|---|---|---|---|---|---|---|---|---|")
        rows = [("v1 (ER on, ROB 64)", {lt: s["baseline"][bl]["tanager_v1"] for lt, bl in DECISION})]
        rows += [(n, a["by_lat"]) for n, a in s["er_study"].items()]
        for name, by in rows:
            L.append(f"| {name} | {fmt(by['30']['suite_ipc'])} | {fmt(by['120']['suite_ipc'])} | "
                     f"{fmt(by['250']['suite_ipc'])} | {fmt(by['120']['memsuite_ipc'])} | {by['120']['mlp_chase8']:.2f} | "
                     f"{by['120']['mlp_chase8f16']:.2f} | {by['120']['ipc']['ms_chase8f16']:.3f} | "
                     f"{by['250']['mlp_chase8f16']:.2f} |")
        L.append("")
    if s.get("sweeps"):
        L.append("## Structure sweeps (suite IPC; other parameters at v1 values)\n")
        for p, vals in s["sweeps"].items():
            L.append(f"**{p}**\n")
            L.append("| Value | 30 cycles | 120 cycles | 250 cycles | CoreMark A @120 | Memsuite @120 | "
                     "MLP chase8 / chase8f16 @120 |")
            L.append("|---|---|---|---|---|---|---|")
            for v, by in vals.items():
                L.append(f"| {v} | {fmt(by['30']['suite_ipc'])} | {fmt(by['120']['suite_ipc'])} | "
                         f"{fmt(by['250']['suite_ipc'])} | {by['120']['coremark_A']:.2f} | "
                         f"{fmt(by['120']['memsuite_ipc'])} | {by['120']['mlp_chase8']:.2f} / "
                         f"{by['120']['mlp_chase8f16']:.2f} |")
            L.append("")
    if cal:
        L.append("## Calibration of the NaxRiscv-like model (rv32im, against NaxRiscv's published RV32 numbers)\n")
        L.append("| Interpretation | Dhrystone IPC | CoreMark IPC | Embench IPC | Max error | DMIPS/MHz | CoreMark/MHz | "
                 "Embench |")
        L.append("|---|---|---|---|---|---|---|---|")
        L.append("| Published | 1.65 | 1.28 | 1.42 | | 2.93 | 5.02 | 1.67 |")
        for name, x in cal["results"].items():
            e = x["err"]
            L.append(f"| {name} | {x['dhrystone_ipc']:.3f} ({e['dhrystone_ipc']:+.1%}) | {x['coremark_ipc']:.3f} "
                     f"({e['coremark_ipc']:+.1%}) | {x['embench_ipc']:.3f} ({e['embench_ipc']:+.1%}) | "
                     f"{x['max_abs_err']:.1%} | {x['dmips_mhz']:.2f} | {x['coremark_mhz']:.2f} | {x['embench_score']:.2f} |")
        L.append("")
    return "\n".join(L)


def targeted_tables(t):
    ws = ["tk_bigcode", "tk_bsearch_l2", "tk_histo", "tk_dgemm", "coremark_N"]
    L = [f"## Targeted kernels ({t['isa']}; IPC, change vs v1 in brackets)\n",
         "| Configuration | DRAM | " + " | ".join(ws) + " |", "|---|---|" + "---|" * len(ws)]
    v1 = t["configs"]["v1"]["by_lat"]
    for name, c in t["configs"].items():
        for lat, per in c["by_lat"].items():
            cells = []
            for w in ws:
                x, b = per[w]["ipc"], v1[lat][w]["ipc"]
                cells.append(f"{x:.3f}" if name == "v1" else f"{x:.3f} ({pct(x, b):+.1f}%)")
            L.append(f"| {name} | {lat} | " + " | ".join(cells) + " |")
    L.append("")
    v = v1["120"]
    L.append("v1 at 120 cycles: " + "; ".join(
        f"{w}: L1I MPKI {v[w]['l1i_mpki']:.1f}, branch MPKI {v[w]['mpki']:.1f}, L1D MPKI {v[w]['l1d_mpki']:.1f}, "
        f"MLP {v[w]['mlp']:.2f}, violation flushes {v[w]['violation_flushes']}" for w in ws) + "\n")
    return "\n".join(L)


def freeze_tables(f):
    lat = f["latencies"]
    L = [f"## Freeze candidates ({f['isa']}; suite IPC and ratio to the NaxRiscv-like control)\n"]
    L.append("| Candidate | " + " | ".join(f"{c} cycles" for c in lat.values()) + " | CoreMark/MHz A, B @120 | "
             "DMIPS/MHz | MLP chase8 / chase16 / chase8f16 @120 |")
    L.append("|---|" + "---|" * len(lat) + "---|---|---|")
    for name, c in f["candidates"].items():
        cells = []
        for ln in lat:
            # the control runs with the candidate's uncore (L2, L2 MSHRs, stream prefetcher)
            x, n = c["by_lat"][ln]["suite_ipc"], c.get("nax_by_lat", f["nax"])[ln]["suite_ipc"]
            cells.append(f"{x:.3f} ({x / n:.3f}x)")
        b = c["by_lat"]["design120"]
        L.append(f"| {name} | " + " | ".join(cells) + f" | {b['coremark_A']:.2f}, {b['coremark_B']:.2f} | "
                 f"{b['dmips']:.2f} | {b['mlp_chase8']:.2f} / {b['mlp_chase16']:.2f} / {b['mlp_chase8f16']:.2f} |")
    L.append(f"| NaxRiscv-like control | " + " | ".join(f"{f['nax'][ln]['suite_ipc']:.3f}" for ln in lat) + " | "
             f"{f['nax']['design120']['coremark_A']:.2f}, {f['nax']['design120']['coremark_B']:.2f} | "
             f"{f['nax']['design120']['dmips']:.2f} | {f['nax']['design120']['mlp_chase8']:.2f} / "
             f"{f['nax']['design120']['mlp_chase16']:.2f} / {f['nax']['design120']['mlp_chase8f16']:.2f} |")
    L.append("")
    if "nax_fma5_120" in f:
        n5 = f["nax_fma5_120"]["suite_ipc"]
        L.append(f"Control sensitivity: with a 5-cycle FMA instead of the assumed 7, the control's suite IPC at 120 "
                 f"cycles is {n5:.3f} (vs {f['nax']['design120']['suite_ipc']:.3f}); each candidate's ratio at 120 "
                 f"would be {f['nax']['design120']['suite_ipc'] / n5:.4f}x of the value shown.\n")
    ws = ["tk_bigcode", "tk_bsearch_l2", "tk_histo", "tk_dgemm", "coremark_N"]
    L.append("Targeted kernels at 120 cycles (IPC):\n")
    L.append("| Candidate | " + " | ".join(ws) + " |")
    L.append("|---|" + "---|" * len(ws))
    for name, c in f["candidates"].items():
        L.append(f"| {name} | " + " | ".join(f"{c['targeted']['120'][w]:.3f}" for w in ws) + " |")
    L.append("")
    L.append("Per-workload ratio to the control, worst three at each point:\n")
    for name, c in f["candidates"].items():
        if name == "v1 (draft 0.3)":
            continue
        parts = []
        for ln, cyc in lat.items():
            nb = c.get("nax_by_lat", f["nax"])[ln]["ipc"]
            r = sorted((c["by_lat"][ln]["ipc"][w] / nb[w], w) for w in c["by_lat"][ln]["ipc"])
            parts.append(f"{cyc}: " + ", ".join(f"{w} {x:.3f}" for x, w in r[:3]))
        L.append(f"- **{name}**: " + "; ".join(parts))
    L.append("")
    return "\n".join(L)


def greedy_tables(g):
    L = [f"## Greedy freeze ({g['isa']}): the acceptance rule applied to the combined design\n",
         "Start: " + ", ".join(f"{k}={v}" for k, v in g["lean"].items()) + "\n"]
    for i, r in enumerate(g["rounds"], 1):
        L.append(f"**Round {i}** (suite IPC at 120 cycles {r['suite_ipc_120']:.4f}; chosen: {r['chosen'] or 'none, stop'})\n")
        L.append("| Increment | Gain @120 | LUTs | LUT share | Gain / cost | Guards @30 / @250 |")
        L.append("|---|---|---|---|---|---|")
        for c in r["candidates"]:
            guards = f"{c['gain_30']:+.2f}% / {c['gain_250']:+.2f}%" if "gain_30" in c else ""
            L.append(f"| {c['increment']} | {c['gain_120']:+.2f}% | {c['lut']} | {c['lut_share']:.2f}% | "
                     f"{c['ratio']:.2f} | {guards} |")
        L.append("")
    L.append("Final: " + ", ".join(f"{k}={v}" for k, v in g["final"].items()) + "\n")
    return "\n".join(L)


def width_tables(w):
    L = [f"## Front-end width study ({w['isa']}; suite IPC, change vs the 2-wide greedy freeze)\n",
         "| Configuration | 30 cycles | 120 cycles | 250 cycles | CoreMark/MHz A, B @120 | DMIPS/MHz |",
         "|---|---|---|---|---|---|"]
    base = w["configs"]["greedy freeze, 2-wide"]["by_lat"]
    for name, c in w["configs"].items():
        b = c["by_lat"]
        cells = [f"{b[lt]['suite_ipc']:.3f} ({pct(b[lt]['suite_ipc'], base[lt]['suite_ipc']):+.1f}%)"
                 for lt in ("30", "120", "250")]
        L.append(f"| {name} | " + " | ".join(cells) + f" | {b['120']['coremark_A']:.2f}, {b['120']['coremark_B']:.2f} | "
                 f"{b['120']['dmips']:.2f} |")
    L.append("")
    return "\n".join(L)


def ledger(s):
    L = ["| Feature | Contribution @30 | @120 | @250 | Est. LUTs | LUT share | Gain / cost @120 | Rule verdict |",
         "|---|---|---|---|---|---|---|---|"]
    for name, a in s["ablations"].items():
        cost, scope, _ = LUT_COST[name]
        share = cost / (SOC_LUTS if scope == "SoC" else CORE_LUTS) * 100.0
        contrib = {}
        for lt, bl in DECISION:
            v1 = s["baseline"][bl]["tanager_v1"]["suite_ipc"]
            x = a["by_lat"][lt]["suite_ipc"]
            # Removal ablation: contribution = v1 / without - 1. Addition (+...): with / v1 - 1.
            contrib[lt] = pct(x, v1) if name.startswith("+") else pct(v1, x)
        ratio = contrib["120"] / share
        if contrib["120"] >= share and contrib["30"] >= -0.25 and contrib["250"] >= -0.25:
            verdict = "adopt" if name.startswith("+") else "pass"
        else:
            verdict = "reject" if name.startswith("+") else "below the line"
        L.append(f"| {name} | {contrib['30']:+.2f}% | {contrib['120']:+.2f}% | {contrib['250']:+.2f}% | "
                 f"{cost} ({scope}) | {share:.2f}% | {ratio:.1f}x | {verdict} |")
    L.append("")
    L.append("| Feature | What the LUT estimate covers | BRAM / URAM | Timing exposure | Verification surface |")
    L.append("|---|---|---|---|---|")
    for name, (cost, scope, why) in LUT_COST.items():
        mem, tim, ver = FEATURE_NOTES[name]
        L.append(f"| {name} | {why} | {mem} | {tim} | {ver} |")
    L.append("")
    L.append("### Size steps (each step judged against the next smaller size)\n")
    L.append("| Parameter | Step | Gain @30 | Gain @120 | Gain @250 | Est. LUT change | LUT share | Rule verdict |")
    L.append("|---|---|---|---|---|---|---|---|")
    for p, vals in s["sweeps"].items():
        f, scope, _ = SIZE_COST[p]
        denom = SOC_LUTS if scope == "SoC" else CORE_LUTS
        vs = list(vals)
        for a, b in zip(vs, vs[1:]):
            g = {lt: pct(vals[b][lt]["suite_ipc"], vals[a][lt]["suite_ipc"]) for lt, _ in DECISION}
            dl = f(int(b)) - f(int(a))
            share = dl / denom * 100.0
            if p == "lat_fma":
                verdict = "timing trade-off, not judged on LUTs"
            elif dl <= 0:
                verdict = "free: take the better" if abs(g["120"]) > 0.05 else "free, no effect"
            elif g["120"] >= share and g["30"] >= -0.25 and g["250"] >= -0.25:
                verdict = "pass"
            else:
                verdict = "below the line"
            L.append(f"| {p} | {a} -> {b} | {g['30']:+.2f}% | {g['120']:+.2f}% | {g['250']:+.2f}% | {dl:+d} ({scope}) | "
                     f"{share:.2f}% | {verdict} |")
    L.append("")
    L.append("Size cost bases:\n")
    for p, (_, scope, why) in SIZE_COST.items():
        L.append(f"- **{p}** ({scope}): {why}")
    return "\n".join(L)


def main():
    isa = sys.argv[1] if len(sys.argv) > 1 else "rv64gc"
    suffix = "" if isa == "rv64gc" else f"_{isa}"
    s = json.loads((ROOT / "results" / f"dse_summary_{isa}.json").read_text())
    calf = ROOT / "results" / "calibration.json"
    cal = json.loads(calf.read_text()) if calf.exists() and isa == "rv64gc" else None
    DOCS.mkdir(parents=True, exist_ok=True)
    text = tables(s, cal)
    for name, fn in ((f"targeted_{isa}.json", targeted_tables), (f"greedy_{isa}.json", greedy_tables),
                     (f"freeze_{isa}.json", freeze_tables), (f"width_{isa}.json", width_tables)):
        p = ROOT / "results" / name
        if p.exists():
            text += "\n" + fn(json.loads(p.read_text()))
    (DOCS / f"dse_tables{suffix}.md").write_text(text)
    charts(s, suffix)
    fz = ROOT / "results" / f"freeze_{isa}.json"
    if fz.exists():
        freeze_charts(json.loads(fz.read_text()), suffix)
    out = [f"dse_tables{suffix}.md", f"ipc_vs_latency{suffix}.svg", f"ratio_vs_latency{suffix}.svg"]
    if s.get("ablations"):
        (DOCS / "ledger_table.md").write_text(ledger(s) + "\n")
        out.append("ledger_table.md")
    print("wrote", ", ".join(out), "in", DOCS)


if __name__ == "__main__":
    main()
