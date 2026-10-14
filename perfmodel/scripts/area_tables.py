"""Markdown tables for docs/perf/area_recovery.md from results/area_recovery.json (scripts/area.py --tables)."""
import json

import area
import smt

LATS = ("30", "120", "250")
FMAX = (180, 185, 190, 195, 200)


def pct(a, b):
    return (a / b - 1) * 100


def k(x):
    return f"{x / 1000:.2f}K"


def base_table(res):
    L = ["| Configuration | WS_ref @30 | @120 | @250 | Single-thread suite IPC @30 | @120 | @250 | CoreMark/MHz @120 |",
         "|---|---|---|---|---|---|---|---|"]
    for tag, label in (("v1", "v1 (smt2)"), ("v2", "v2 (smt2_w3)"), ("st", "ST (bring-up, one program at a time)")):
        b = res["base"][tag]
        L.append(f"| {label} | " + " | ".join(f"{b[l]['ws_ref']:.3f}" for l in LATS) + " | "
                 + " | ".join(f"{b[l]['st_ipc']:.3f}" for l in LATS) + f" | {b['120']['st']['coremark_A']:.2f} |")
    return "\n".join(L) + "\n"


def verdict(r, base_luts):
    share = r["mid"] / base_luts * 100
    if r["mid"] <= 0:
        return "no saving"
    if r["loss"] <= 0.05:
        return "**free** (loss within ±0.05%)"
    return "passes" if share >= r["loss"] else "fails"


def lever_table(res, tag):
    """Levers ranked by IPC lost per 1K LUTs saved at 120 cycles."""
    base = res["base"][tag]
    core = res["core_base"][tag]
    L = [f"| Rank | Lever | Saves per core | Share of the {core / 1000:.1f}K core | Throughput (WS_ref) @30 / @120 / @250 | "
         "Single-thread IPC @30 / @120 / @250 | Loss per 1K LUTs @120 | Reverse rule @120 |",
         "|---|---|---|---|---|---|---|---|"]
    for i, r in enumerate(area.ranked(res, tag), 1):
        lev = res[f"levers_{tag}"][r["name"]]["by_lat"]
        ws = " / ".join(f"{pct(lev[l]['ws_ref'], base[l]['ws_ref']):+.2f}%" for l in LATS)
        st = " / ".join(f"{pct(lev[l]['st_ipc'], base[l]['st_ipc']):+.2f}%" for l in LATS)
        saves = k(r["lo"]) if abs(r["hi"] - r["lo"]) < 1 else f"{k(r['lo'])}–{k(r['hi'])}"
        per = f"{r['per_k']:.2f}%" if r["mid"] > 0 else "—"
        L.append(f"| {i} | {r['name']} | {saves} | {r['share']:.1f}% | {ws} | {st} | {per} | {verdict(r, core)} |")
    return "\n".join(L) + "\n"


def lever_groups(res, tag, names):
    """Throughput change by pair group at 120 cycles for chosen levers."""
    base = res["base"][tag]["120"]["groups"]
    L = ["| Lever | " + " | ".join(smt.GROUPS) + " |", "|---|" + "---|" * len(smt.GROUPS)]
    for n in names:
        g = res[f"levers_{tag}"][n]["by_lat"]["120"]["groups"]
        L.append(f"| {n} | " + " | ".join(f"{pct(g[x], base[x]):+.2f}%" for x in smt.GROUPS) + " |")
    return "\n".join(L) + "\n"


def worst_st(res, tag, name, n=6):
    """The single-thread workloads a lever hurts most at 120 cycles."""
    b = res["base"][tag]["120"]["st_ipc_by"]
    r = res[f"levers_{tag}"][name]["by_lat"]["120"]["st_ipc_by"]
    rows = sorted(((pct(r[w], b[w]), w) for w in b), key=lambda x: x[0])[:n]
    return ", ".join(f"{w} {d:+.1f}%" for d, w in rows)


def combo_table(res, tag):
    base = res["base"][tag]
    core = res["core_base"][tag]
    L = ["| Step | Lever added | Saves at this step | Saves in all, per core | Share | Throughput @30 / @120 / @250 | "
         "Single-thread IPC @30 / @120 / @250 |", "|---|---|---|---|---|---|---|"]

    def rng(lo, hi):
        return k(lo) if abs(hi - lo) < 1 else f"{k(lo)}–{k(hi)}"

    for i, c in enumerate(res["combos"][tag], 1):
        lo, hi = c["luts_saved"]
        ws = " / ".join(f"{pct(c['by_lat'][l]['ws_ref'], base[l]['ws_ref']):+.2f}%" for l in LATS)
        st = " / ".join(f"{pct(c['by_lat'][l]['st_ipc'], base[l]['st_ipc']):+.2f}%" for l in LATS)
        L.append(f"| {i} | {c['levers'][-1]} | {rng(*c['step_saved'])} | {rng(lo, hi)} | "
                 f"{(lo + hi) / 2 / core * 100:.1f}% | {ws} | {st} |")
    return "\n".join(L) + "\n"


def v2_table(res):
    """The v2 re-plan options against v2 as planned: per-core LUTs and performance."""
    b2 = res["base"]["v2"]
    b1 = res["base"]["v1"]
    L = ["| Option | LUTs per core vs v2 | WS_ref @30 / @120 / @250 | vs v1 @120 | Single-thread IPC @120 | vs v1 @120 |",
         "|---|---|---|---|---|---|"]

    def row(label, saved, by):
        ws = " / ".join(f"{by[l]['ws_ref']:.3f}" for l in LATS)
        L.append(f"| {label} | {saved} | {ws} | {pct(by['120']['ws_ref'], b1['120']['ws_ref']):+.1f}% | "
                 f"{by['120']['st_ipc']:.3f} | {pct(by['120']['st_ipc'], b1['120']['st_ipc']):+.1f}% |")

    row("v2 as planned (smt2_w3)", "0", b2)
    for name, o in res["combos"].get("v2_options", {}).items():
        lo, hi = o["luts_saved"]
        row(name, f"−{k(lo)}–{k(hi)}" if abs(hi - lo) >= 1 else f"−{k(lo)}", o["by_lat"])
    for name, o in res["st_w3"].items():
        lo, hi, mid = o["luts_saved_vs_v2"]
        row(name + " (no SMT2; throughput runs one program at a time)", f"−{k(lo)}–{k(hi)} (central −{k(mid)})",
            o["by_lat"])
    row("v1 (smt2, 2-wide)", f"−{k(area.sched_luts(area.V2) - area.sched_luts(area.V1) + area.window_luts(area.V2) - area.window_luts(area.V1))} "
        "in the scheduler and window, plus the 3-wide logic (≈3.5K in S3 and ≈6–8K in all)", b1)
    return "\n".join(L) + "\n"


def freq_table(res, tag):
    """IPC x Fmax: full structures at 180-200 MHz against the cumulative trims at 200 MHz (120 cycles), with the
    clock below which each trim gives more performance than full structures."""
    b = res["base"][tag]["120"]
    L = ["| Option | Saves per SoC | Clock | Throughput × clock vs full @200 | Single-thread IPC × clock vs full @200 | "
         "Full structures fall behind below |", "|---|---|---|---|---|---|"]
    for f in FMAX:
        L.append(f"| full structures | — | {f} MHz | {(f / 200 - 1) * 100:+.1f}% | {(f / 200 - 1) * 100:+.1f}% | — |")
    for i, c in enumerate(res["combos"][tag], 1):
        dw = pct(c["by_lat"]["120"]["ws_ref"], b["ws_ref"])
        ds = pct(c["by_lat"]["120"]["st_ipc"], b["st_ipc"])
        lo, hi = c["luts_saved"]
        L.append(f"| step {i}: + {c['levers'][-1]} | {k(2 * lo)}–{k(2 * hi)} | 200 MHz | {dw:+.2f}% | {ds:+.2f}% | "
                 f"{200 * (1 + dw / 100):.1f} MHz (throughput), {200 * (1 + ds / 100):.1f} MHz (single thread) |")
    return "\n".join(L) + "\n"


DEVICE = 117120
CEIL_200 = 103000  # S6: v1 holds 200 MHz to about 88% fill


def cheapest(res, tag, need):
    """The first cumulative step (rank order) whose low-end saving per core covers `need`: (step, levers)."""
    if need <= 0:
        return None
    for c in res["combos"][tag]:
        if c["luts_saved"][0] >= need:
            return c
    return "none"


def fit_table(res, tag, socs, limits):
    """Per SoC outcome (after the planned levers): the IPC-costing levers needed to fit each fill limit, taken
    in rank order, with their cost at 120 cycles. limits: (label, LUT limit)."""
    base = res["base"][tag]["120"]
    L = ["| SoC after the planned levers | " + " | ".join(f"Fit {lab} ({lim / 1000:.1f}K)" for lab, lim in limits) + " |",
         "|---|" + "---|" * len(limits)]
    for soc in socs:
        cells = []
        for _, lim in limits:
            need = (soc - lim) / 2
            c = cheapest(res, tag, need)
            if c is None:
                cells.append("fits as is")
            elif c == "none":
                cells.append(f"needs {k(need)}/core: more than the passing levers give")
            else:
                cells.append(f"{k(need)}/core: {len(c['levers'])} lever(s), throughput "
                             f"{pct(c['by_lat']['120']['ws_ref'], base['ws_ref']):+.2f}%, single thread "
                             f"{pct(c['by_lat']['120']['st_ipc'], base['st_ipc']):+.2f}%")
        L.append(f"| {soc / 1000:.0f}K ({soc / DEVICE * 100:.0f}%) | " + " | ".join(cells) + " |")
    return "\n".join(L) + "\n"


def census_table(res, tag, which):
    c = res["census"][tag][which]
    L = ["| Queue (consumer) | Sources | Value ready | MX (1-cycle producer in its row) | ROB column | LLT column | "
         "Other thread | ROB column on a 1-cycle producer | Other ROB half (MX or ROB column) | "
         "ROB-column waits by producer queue |", "|---|---|---|---|---|---|---|---|---|---|"]
    for q in ("A0", "A1", "A2", "LD", "STA", "FP"):
        if q not in c:
            continue
        x = c[q]
        tot = sum(x[kk] for kk in ("ready", "mx", "rob", "llt", "xthread"))
        rf = x.get("rob_from", {})
        rft = sum(rf.values()) or 1
        rfs = ", ".join(f"{p} {n / rft * 100:.0f}%" for p, n in sorted(rf.items(), key=lambda t: -t[1]) if n / rft >= 0.005)
        L.append(f"| {q} | {tot:,} | " + " | ".join(f"{x[kk] / tot * 100:.1f}%" for kk in ("ready", "mx", "rob", "llt"))
                 + f" | {x['xthread']:,} | {x.get('rob_1cycle', 0):,} | {x.get('cross_half', 0) / tot * 100:.1f}% | {rfs} |")
    return "\n".join(L) + "\n"


def main():
    res = area.load()
    out = ["# Area-recovery tables (generated by `scripts/area.py --tables`)\n", "## Base\n", base_table(res)]
    for tag in ("v1", "v2"):
        out += [f"## Levers on {tag}\n", lever_table(res, tag)]
        if f"levers_{tag}" in res:
            names = [r["name"] for r in area.ranked(res, tag)]
            out += [f"### By pair group ({tag}, 120 cycles)\n", lever_groups(res, tag, names)]
            bank = "banked queues: rows see one ROB half"
            if bank in res[f"levers_{tag}"]:
                out.append(f"Banked queues, single thread, worst workloads @120: {worst_st(res, tag, bank)}\n")
        if "combos" in res and tag in res["combos"]:
            out += [f"### Cumulative, in rank order ({tag})\n", combo_table(res, tag)]
    if "combos" in res:
        if "ipc_first" in res["combos"]:
            b = res["base"]["v1"]
            L = ["| Configuration | Saves per core vs v1 as planned | Throughput @30 / @120 / @250 | "
                 "Single-thread IPC @30 / @120 / @250 |", "|---|---|---|---|"]
            for name, o in res["combos"]["ipc_first"].items():
                lo, hi = o["luts_saved"]
                L.append(f"| {name} | {k(lo)}–{k(hi)} | "
                         + " / ".join(f"{pct(o['by_lat'][l]['ws_ref'], b[l]['ws_ref']):+.2f}%" for l in LATS) + " | "
                         + " / ".join(f"{pct(o['by_lat'][l]['st_ipc'], b[l]['st_ipc']):+.2f}%" for l in LATS) + " |")
            out += ["## IPC first: window growth with wakeup tags (v1)\n", "\n".join(L) + "\n"]
        out += ["## v2 re-plan options\n", v2_table(res)]
        limits = [("200 MHz, 88%", CEIL_200), ("180 MHz if 90%", 0.90 * DEVICE), ("180 MHz if 92%", 0.92 * DEVICE),
                  ("180 MHz if 94%", 0.94 * DEVICE)]
        out += ["## Frequency trade, v1\n", freq_table(res, "v1"), "## Frequency trade, v2\n", freq_table(res, "v2")]
        out += ["## Fit, v1\n", fit_table(res, "v1", (99000, 103000, 106000, 110000), limits),
                "## Fit, v2\n", fit_table(res, "v2", (113000, 120000, 128000), limits)]
        if "st_alt" in res:
            L = ["| Single-thread mode | Suite IPC @30 / @120 / @250 | vs the merged window @120 |", "|---|---|---|"]
            for name, a in res["st_alt"].items():
                tag = name[:2]
                b = res["base"][tag]
                L.append(f"| {name} | " + " / ".join(f"{a['by_lat'][l]['st_ipc']:.3f}" for l in LATS)
                         + f" | {pct(a['by_lat']['120']['st_ipc'], b['120']['st_ipc']):+.2f}% |")
            out += ["## Banked queues: the half-ROB single-thread alternative\n", "\n".join(L) + "\n"]
        if "st_tags" in res:
            b = res["base"]["st"]
            L = ["| ST (bring-up) | Scheduler saving (S2 fit, before the pool's logic) | Suite IPC @30 / @120 / @250 | "
                 "vs ST @30 / @120 / @250 |", "|---|---|---|---|"]
            for name, a in res["st_tags"].items():
                L.append(f"| {name} | {k(a['luts_saved'])} | " + " / ".join(f"{a['by_lat'][l]['st_ipc']:.3f}" for l in LATS)
                         + " | " + " / ".join(f"{pct(a['by_lat'][l]['st_ipc'], b[l]['st_ipc']):+.2f}%" for l in LATS) + " |")
            out += ["## Wakeup tags on ST\n", "\n".join(L) + "\n"]
    if "census" in res:
        for tag in ("v1", "v2"):
            for which in ("smt2_pairs", "single_thread"):
                out += [f"## Dependency census, {tag}, {which.replace('_', ' ')} (120 cycles)\n",
                        census_table(res, tag, which)]
    area.TABLES.write_text("\n".join(out))
    print(f"wrote {area.TABLES}")


if __name__ == "__main__":
    main()
