"""Generated tables for the SMT2 study: results/smt2_rv64gc.json -> docs/perf/smt2_tables.md and
docs/perf/smt2_ws_vs_latency.svg. The hand-written analysis is in docs/perf/smt2_report.md.

  python3 scripts/smt_tables.py      (or: python3 scripts/smt.py --tables)
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import smt  # noqa: E402
import tgrun  # noqa: E402

LATS = ("30", "120", "250")
# LUT cost of the M1 options (scripts/report.py LUT_COST; third ALU and 3-wide from docs/perf/dse_report.md section 9).
OPTION_LUTS = {"ld_ports": 1500, "fp_ports": 4400, "alu3": 4500, "3wide": 10000}
MAIN = ("v1_freeze, SMT2", "v2 (greedy)", "v2b (greedy with window steps)", "3-wide SMT2 (greedy with window steps)")
SIZED_2W, SIZED_3W, SMT_3W_V1 = ("v2b (greedy with window steps)", "3-wide SMT2 (greedy with window steps)",
                                 "3-wide decode/rename/commit + third ALU")


def option_luts(sets):
    if sets.get("decode_width", 2) == 3:
        return OPTION_LUTS["3wide"]
    n = 0
    if sets.get("ld_ports", 1) == 2:
        n += OPTION_LUTS["ld_ports"]
    if sets.get("fp_ports", 1) == 2:
        n += OPTION_LUTS["fp_ports"]
    if sets.get("alu3", 0):
        n += OPTION_LUTS["alu3"]
    return n


def config_luts(sets, smt_on=True):
    """Estimated per-core LUT change against v1_freeze (single thread): sizes, options and the SMT2 overhead
    (central estimate); and the SoC-level (L2) change."""
    core, soc = smt.lut_delta(sets)
    core += option_luts(sets)
    if smt_on and sets.get("threads", 1) == 2:
        core += smt.smt_overhead(sets.get("decode_width", 2))[1]
    return core, soc


def pct(a, b):
    return (a / b - 1) * 100


def fmt_sizes(s):
    keys = [("rob", "ROB"), ("lq", "LQ"), ("sq", "SQ"), ("lqcb", "CB"), ("iq_a0", "A0"), ("iq_a1", "A1"), ("iq_ld", "LD"),
            ("iq_sta", "STA"), ("iq_fp", "FP"), ("llt", "LLT"), ("l1d_mshr", "L1D MSHR"), ("l2_mshr", "L2 MSHR")]
    return ", ".join(f"{lab} {s[k]}" for k, lab in keys if k in s)


def summary_table(res):
    cfgs = res["configs"]
    base = cfgs["v1_freeze, SMT2"]["by_lat"]
    L = ["| Configuration | WS_ref @30 | @120 | @250 | vs SMT2 base @120 | WS (same config) @120 | Fairness @120 | "
         "Throughput (IPC) @120 | Single-thread suite IPC @120 | Est. core LUTs vs v1 |",
         "|---|---|---|---|---|---|---|---|---|---|"]
    for n, c in cfgs.items():
        b = c["by_lat"]
        core, soc = config_luts(c["sets"])
        cost = f"{core:+,}" + (f" (+{soc:,} SoC)" if soc else "")
        e = b["120"]
        L.append(f"| {n} | {b['30']['ws_ref']:.3f} | **{e['ws_ref']:.3f}** | {b['250']['ws_ref']:.3f} | "
                 f"{pct(e['ws_ref'], base['120']['ws_ref']):+.1f}% | {e['ws']:.3f} | {e['fair']:.3f} | "
                 f"{e['throughput']:.3f} | {e['alone_suite_ipc']:.3f} | {cost} |")
    return "\n".join(L) + "\n"


def group_table(res, name):
    c = res["configs"][name]["by_lat"]
    L = [f"**{name}**\n", "| Group | WS_ref @30 | @120 | @250 | WS @120 | Fairness @120 | Throughput @120 |",
         "|---|---|---|---|---|---|---|"]
    for g in smt.GROUPS:
        e = {lt: c[lt]["groups"][g] for lt in LATS}
        L.append(f"| {g} | {e['30']['ws_ref']:.3f} | {e['120']['ws_ref']:.3f} | {e['250']['ws_ref']:.3f} | "
                 f"{e['120']['ws']:.3f} | {e['120']['fair']:.3f} | {e['120']['throughput']:.3f} |")
    L.append(f"| **all** | {c['30']['ws_ref']:.3f} | {c['120']['ws_ref']:.3f} | {c['250']['ws_ref']:.3f} | "
             f"{c['120']['ws']:.3f} | {c['120']['fair']:.3f} | {c['120']['throughput']:.3f} |")
    return "\n".join(L) + "\n"


def pairs_table(res, name, lat="120"):
    e = res["configs"][name]["by_lat"][lat]
    L = [f"**{name}, {lat} cycles** (IPC; speedup = IPC / IPC alone on the same configuration)\n",
         "| Pair (thread 0 + thread 1) | Group | IPC 0 | IPC 1 | Speedup 0 | Speedup 1 | WS | WS_ref | Fairness | "
         "Throughput | Main dispatch stall (share of cycles), thread 0 / 1 |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    for p, m in e["pairs"].items():
        st = []
        for i in range(2):
            k = max(("disp_stall_rob", "disp_stall_lq", "disp_stall_sq", "disp_stall_iq", "disp_stall_reg",
                     "disp_stall_llt"), key=lambda k: m[k][i])
            st.append(f"{k[11:].upper()} {m[k][i]:.2f}" if m[k][i] >= 0.05 else "-")
        L.append(f"| {p} | {m['group']} | {m['ipc'][0]:.3f} | {m['ipc'][1]:.3f} | {m['speedup'][0]:.3f} | "
                 f"{m['speedup'][1]:.3f} | {m['ws']:.3f} | {m['ws_ref']:.3f} | {m['fair']:.3f} | {m['throughput']:.3f} | "
                 f"{st[0]} / {st[1]} |")
    return "\n".join(L) + "\n"


def greedy_tables(res, key="greedy"):
    g = res[key]
    L = ["Start: " + fmt_sizes(g["start"]) + "\n"]
    for i, r in enumerate(g["rounds"], 1):
        L.append(f"**Round {i}** (WS_ref at 120 cycles {r['ws_ref_120']:.4f}; chosen: {r['chosen'] or 'none, stop'})\n")
        L.append("| Increment | Gain @120 | LUTs | LUT share | Gain / cost | Guards @30 / @250 |")
        L.append("|---|---|---|---|---|---|")
        for c in r["candidates"]:
            guards = f"{c['gain_30']:+.2f}% / {c['gain_250']:+.2f}%" if "gain_30" in c else ""
            L.append(f"| {c['increment']} | {c['gain_120']:+.2f}% | {c['lut']} ({c['scope']}) | {c['lut_share']:.2f}% | "
                     f"{c['ratio']:.2f} | {guards} |")
        L.append("")
    L.append("Final: " + fmt_sizes(g["final"]) + "\n")
    return "\n".join(L)


def overhead_table(res):
    lo, mid, hi = smt.smt_overhead()
    L = ["| Item | Low | Central | High | Basis |", "|---|---|---|---|---|"]
    for name, a, b, c, why in smt.SMT_OVERHEAD:
        L.append(f"| {name} | {a:,} | {b:,} | {c:,} | {why} |")
    core = res["core_luts"]
    L.append(f"| **Total** | **{lo:,}** ({lo / core:.1%}) | **{mid:,}** ({mid / core:.1%}) | **{hi:,}** ({hi / core:.1%}) | "
             f"of the ≈{core / 1000:.0f}K-LUT core |")
    return "\n".join(L) + "\n"


def time_shared(sets, lat):
    """A single-thread core running each pair one program at a time: per pair, the mean over the two programs
    of IPC_alone(config) / IPC_alone(v1_freeze) (half the time each), as WS_ref; geomean of group geomeans."""
    same = smt.alone(sets, lat)["ipc"]
    ref = smt.alone(smt.V1F, lat)["ipc"]
    per = {g: [] for g in smt.GROUPS}
    for g, a, b in smt.PAIRS:
        per[g].append((same[a] / ref[a] + same[b] / ref[b]) / 2)
    return tgrun.geomean([tgrun.geomean(v) for v in per.values()])


def core_row(res, label, sets=None, cname=None):
    """(label, WS_ref by latency, single-thread suite IPC at 120, core LUTs vs v1) for a single-thread core run one
    program at a time (sets) or a configuration of the study (cname)."""
    if cname:
        c = res["configs"][cname]
        return (label, {lt: c["by_lat"][lt]["ws_ref"] for lt in LATS}, c["by_lat"]["120"]["alone_suite_ipc"],
                config_luts(c["sets"])[0])
    return (label, {lt: time_shared(sets, int(lt)) for lt in LATS}, smt.alone(sets, 120)["suite_ipc"],
            config_luts(sets, smt_on=False)[0])


def order_rows(res):
    rows = {"v1": core_row(res, "v1 freeze (2-wide), one program at a time", sets={**smt.V1F}),
            "A": core_row(res, "A. SMT2 on the 2-wide core, v1 sizes", cname="v1_freeze, SMT2"),
            "B": core_row(res, "B. 3-wide single thread, v1 sizes", sets={**smt.V1F, **smt.W3}),
            "C": core_row(res, "C. SMT2 on the 3-wide core, v1 sizes", cname=SMT_3W_V1)}
    if SIZED_2W in res["configs"]:
        rows["A'"] = core_row(res, "A'. SMT2 on the 2-wide core, sized by the rule (v2)", cname=SIZED_2W)
    if SIZED_3W in res["configs"]:
        rows["C'"] = core_row(res, "C'. SMT2 on the 3-wide core, sized by the rule", cname=SIZED_3W)
        rows["B'"] = core_row(res, "B'. 3-wide single thread with C' sizes",
                              sets=smt.single(res["configs"][SIZED_3W]["sets"]))
    return rows


def order_tables(res):
    """The three cores at v1 sizes and sized by the rule, and the two-step paths between them."""
    rows = order_rows(res)
    v1_st = rows["v1"][2]
    L = ["| Core (per core, against the v1 freeze) | WS_ref @30 | @120 | @250 | Throughput gain @120 | "
         "Single-thread suite IPC @120 | Est. core LUTs vs v1 | Throughput gain per LUT % |",
         "|---|---|---|---|---|---|---|---|"]
    for k, (label, ws, st, core) in rows.items():
        gain = (ws["120"] - 1) * 100
        share = core / res["core_luts"] * 100
        per = f"{gain / share:.2f}" if share > 0 else "—"
        L.append(f"| {label} | {ws['30']:.3f} | {ws['120']:.3f} | {ws['250']:.3f} | {gain:+.1f}% | {st:.3f} "
                 f"({pct(st, v1_st):+.1f}%) | {core:+,} ({share:.1f}%) | {per} |")
    L.append("")
    if "A'" in rows and "C'" in rows:
        L += ["Two-step paths to the combined core C' (each step against the core before it; LUT shares of the "
              "≈41K-LUT core, as in the greedy passes):\n",
              "| Path | Step | Throughput @120 | Single-thread suite IPC @120 | LUTs | LUT share | "
              "Throughput gain per LUT % |", "|---|---|---|---|---|---|---|"]
        for path, steps in (("SMT2 first", (("v1", "A'"), ("A'", "C'"))), ("3-wide first", (("v1", "B"), ("B", "C'"))),
                            ("Both at once", (("v1", "C'"),))):
            for a, b in steps:
                (_, wa, sa, ca), (lb, wb, sb, cb) = rows[a], rows[b]
                g = pct(wb["120"], wa["120"])
                share = (cb - ca) / res["core_luts"] * 100
                L.append(f"| {path} | {a} → {b} | {wa['120']:.3f} → {wb['120']:.3f} ({g:+.1f}%) | {sa:.3f} → {sb:.3f} "
                         f"({pct(sb, sa):+.1f}%) | {cb - ca:+,} | {share:.1f}% | {g / share:.2f} |")
        L.append("")
    return "\n".join(L) + "\n"


def supplementary_tables(res):
    sup = res["supplementary"]
    grid = sup["sharing_by_iq_cap_120"]
    caps = list(next(iter(grid.values())))
    L = ["WS_ref at 120 cycles, v1 sizes:\n",
         "| Window | " + " | ".join(f"issue queues capped at {c}%" for c in caps) + " |",
         "|---|" + "---|" * len(caps)]
    for w, row in grid.items():
        L.append(f"| {w} | " + " | ".join(f"{row[c]:.4f}" for c in caps) + " |")
    L += ["", "| Whole-window bundles on v2 | WS_ref @30 | @120 | @250 | WS @120 | Single-thread suite IPC @120 | "
              "Est. core LUTs vs v1 |", "|---|---|---|---|---|---|---|"]
    for n, c in sup["bundles"].items():
        b = c["by_lat"]
        core, _ = config_luts(c["sets"])
        L.append(f"| {n} | {b['30']['ws_ref']:.3f} | {b['120']['ws_ref']:.3f} | {b['250']['ws_ref']:.3f} | "
                 f"{b['120']['ws']:.3f} | {b['120']['alone_suite_ipc']:.3f} | {core:+,} |")
    return "\n".join(L) + "\n"


def validation_tables(res):
    v = res["validation"]
    L = ["Next to a near-idle sibling (tests/idle.c), against a single thread with half the ROB, LQ, SQ and "
         "completion buffer (120 cycles):\n",
         "| Program | IPC, SMT2 with idle sibling | IPC, single thread with halves | Ratio | Sibling restarts |",
         "|---|---|---|---|---|"]
    for w, x in v["idle_sibling"].items():
        L.append(f"| {w} | {x['smt']:.3f} | {x['single_half']:.3f} | {x['ratio']:.3f} | {x['sibling_laps']} |")
    L += ["", "Thread order, (A, B) against (B, A):\n",
          "| Pair | IPC A, B as (A, B) | as (B, A) | WS_ref (A, B) | (B, A) |", "|---|---|---|---|---|"]
    for p, x in v["symmetry"].items():
        L.append(f"| {p} | {x['ipc_ab'][0]:.3f}, {x['ipc_ab'][1]:.3f} | {x['ipc_ba'][0]:.3f}, {x['ipc_ba'][1]:.3f} | "
                 f"{x['ws_ref_ab']:.3f} | {x['ws_ref_ba']:.3f} |")
    o = v["overlap_vs_region"]
    L += ["", f"- Shared window capped at 50% equals static halves on every pair: {v['cap50_equals_static']}.",
          f"- IPC over the overlap window against IPC over each first-run region ({o['threads']} threads): mean "
          f"difference {o['mean_abs_ipc_diff']:.2%}, largest {o['max_abs_ipc_diff']:.2%}; WS_ref {o['ws_ref_region']:.4f} "
          f"(regions) against {o['ws_ref_overlap']:.4f} (overlap windows).",
          f"- Highest summed IPC of any pair: {v['max_pair_throughput']:.3f} (decode width 2).", ""]
    return "\n".join(L)


def chart(res):
    """docs/perf/smt2_ws_vs_latency.svg: WS_ref against DRAM latency for the v2 directions."""
    import report  # noqa: PLC0415
    cfgs = res["configs"]
    xs = [int(x) for x in LATS]
    series = [("v1 (2-wide), one at a time", [1.0, 1.0, 1.0], "#7f7f7f", "7 4"),
              ("3-wide, one at a time", [time_shared({**smt.V1F, **smt.W3}, x) for x in xs], "#e67e22", "7 4")]
    for name, lab, col in (("v1_freeze, SMT2", "SMT2 2-wide, v1 sizes", "#9ecae1"),
                           (SIZED_2W, "SMT2 2-wide, sized (v2)", "#1f77b4"),
                           (SMT_3W_V1, "SMT2 3-wide, v1 sizes", "#fc9272"),
                           (SIZED_3W, "SMT2 3-wide, sized", "#d62728")):
        if name in cfgs:
            series.append((lab, [cfgs[name]["by_lat"][x]["ws_ref"] for x in LATS], col, ""))
    report.svg_chart(smt.DOCS / "smt2_ws_vs_latency.svg", "Throughput vs DRAM latency (rv64gc, 42 thread pairs)",
                     "L2-miss round trip to DRAM (core cycles)", "weighted speedup vs v1 (WS_ref)", xs, series,
                     ymin=0.9)


def main():
    res = json.loads(smt.OUT.read_text())
    chart(res)
    L = ["# SMT2 study tables (generated by perfmodel/scripts/smt_tables.py; do not edit)\n",
         "WS_ref: weighted speedup against each program alone on v1_freeze. WS: against each program alone on the "
         "same configuration (threads=1). Fairness: harmonic mean of the per-thread speedups (same configuration). "
         "Figures are geometric means of the three group geometric means; throughput is the mean over pairs of the "
         "summed IPC. LUT estimates: scripts/report.py per-entry costs, plus the SMT2 overhead (central estimate "
         f"{smt.smt_overhead()[1]:,} LUTs) for threads=2.\n",
         "## All configurations\n", summary_table(res), "## By pair group\n"]
    L += [group_table(res, n) for n in MAIN if n in res["configs"]]
    if "greedy" in res:
        L += ["## Greedy v2 sizing, single steps (acceptance rule on WS_ref at 120 cycles)\n", greedy_tables(res)]
    if "greedy_bundles" in res:
        L += ["## Greedy v2 sizing with whole-window steps\n", greedy_tables(res, "greedy_bundles")]
    if "greedy_w3" in res:
        L += ["## Greedy sizing of the 3-wide SMT2 core (plan rule 12), with whole-window steps\n",
              greedy_tables(res, "greedy_w3")]
    if "supplementary" in res:
        L += ["## Window sharing, issue-queue caps and window bundles\n", supplementary_tables(res)]
    L += ["## SMT2 overhead estimate (per core)\n", overhead_table(res)]
    L += ["## Order and combination: SMT2 and 3-wide\n", order_tables(res)]
    if "validation" in res:
        L += ["## SMT2 consistency checks\n", validation_tables(res)]
    for n in MAIN:
        if n in res["configs"]:
            L += [f"## Per pair: {n}\n"] + [pairs_table(res, n, lt) for lt in LATS]
    out = smt.DOCS / "smt2_tables.md"
    out.write_text("\n".join(L))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
