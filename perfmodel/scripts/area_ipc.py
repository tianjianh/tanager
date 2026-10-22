#!/usr/bin/env python3
"""The IPC side of two of the user's area ideas (area_recovery.md §7.9), on rtl_m2 as built, its presets unchanged and
the new switches off by default:

--alu  ALU ports without the shifter/rotator, the bit-manipulation and the unary ops (alu_full names the full ones),
       steered as tg_rename does for any N_ALU: decode slot k's op takes port k mod N, else the next that can run it
       with a row and a register. The 3-wide, 3-ALU core (st_w3: rtl_m2 with three decode slots and ALU2) as 3 full,
       2 full + 1 simple (P2) and 1 full + 2 simple (P0 or P1 full); today's 2-wide core with one simple port beside.
       The suite on rv64gc and rv64gcb (Zba, Zbb, Zbs, Zicond) at 30 cycles, and the 42 pairs (step 7 as decided,
       with 5f) on the merged basis at 30, 120 and 250.
--pa   the LQ and SQ searched on the low N = 20, 16 or 12 address bits: a load's match the full address doesn't
       confirm replays it once, or makes it wait until that store leaves the SQ; a store's flushes the load. The suite,
       the working-set kernels and the page copies (bench/build_area.sh) at 30 and 120 cycles on today's core.

Single-thread runs use dse's cache (results/dse), pairs m7_smt's (results/m7). Results: results/area_ipc.json."""
import argparse
import json
from pathlib import Path

import dse
import m7_smt as m
import smt
import tgrun

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "area_ipc.json"
PRESET = "rtl_m2"
BASE2 = dict(m.CORE)   # today's core alone on its merged window, as rev 10's calibration ran it
W3 = {"decode_width": 3, "commit_width": 3, "alu3": 1}
BASE3 = {**BASE2, **W3}   # st_w3: three decode slots and three ALU ports, every size as st's
ALU3 = {"3 full": {"alu_full": 7},
        "2 full + 1 simple (P2 simple)": {"alu_full": 3},
        "1 full + 2 simple (P0 full)": {"alu_full": 1},
        "1 full + 2 simple (P1 full)": {"alu_full": 2},
        "3 full, the model's own steering": {}}
ALU2 = {"2 full": {"alu_full": 3},
        "1 full + 1 simple (P0 full)": {"alu_full": 1},
        "1 full + 1 simple (P1 full)": {"alu_full": 2},
        "2 full, the model's own steering": {}}
BIGQ = {"iq_a0": 15, "iq_a1": 15, "iq_a2": 15, "iq_ld": 9, "iq_sta": 6, "iq_fp": 15}   # st_w3's queues x1.5
S7 = {**m.S7_AB, **m.DEC5F}   # step 7 as decided, with 5f (smt2_report §13.21)
PA = {"full addresses": {},
      **{f"{n} bits, a false match replays once": {"lsq_pa_bits": n} for n in (20, 16, 12)},
      **{f"{n} bits, a false match waits for the store": {"lsq_pa_bits": n, "lsq_pa_wait": 1} for n in (20, 16, 12)}}
PA_LATS = (30, 120)
CALLOUT = ("embench_crc32", "embench_huffbench", "embench_nettle-sha256", "embench_nettle-aes", "embench_picojpeg",
           "embench_qrduino", "ms_hashprobe")   # shift- and bit-manipulation-heavy, listed first


def suite(configs, isa, mname, workers):
    """{config name: {program: region stats}} for configs {name: sets}, cached as dse caches its runs."""
    out = dse.collect([(PRESET, s) for s in configs.values()], isa=isa, workers=workers, mname=mname)
    kisa = isa if mname == "manifest" else f"{isa}:{mname}"
    return {n: {r["workload"]["name"]: r["region"] for r in out[dse.key(kisa, PRESET, s)[0]]}
            for n, s in configs.items()}


def ipc(g):
    return g.get("instr", 0) / max(1, g.get("cycles", 0))


def gm(xs):
    return tgrun.geomean([x for x in xs if x > 0])


def groups(names):
    """The suite's groups, as dse.summarize forms them."""
    return {"kernels": [n for n in names if n in ("coremark_A", "coremark_B", "dhrystone")],
            "embench": [n for n in names if n.startswith("embench_")],
            "memsuite": [n for n in names if n.startswith("ms_")]}


def suite_ipc(rs):
    gs = groups(list(rs))
    return gm(gm(ipc(rs[n]) for n in v) for v in gs.values() if v)


def alu_suite(width, cfgs, base, isa, workers):
    """The suite on one width: per-program IPC against the first configuration, the full-only share, steering."""
    rs = suite({n: {**base, **c} for n, c in cfgs.items()}, isa, "manifest", workers)
    ref = next(iter(cfgs))
    names = sorted(rs[ref])
    print(f"\n**{width}, {isa}, 30 cycles** (IPC against {ref}; the suite's score is the geometric mean of the "
          "kernels', Embench's and the memsuite's)\n")
    print("| Program | Ops needing a full port | " + " | ".join(cfgs) + " |\n|---|---|" + "---|" * len(cfgs))
    full_share = {}
    for p in names:
        g0 = rs[ref][p]
        full_share[p] = g0.get("alu_full_ops", 0) / max(1, g0.get("instr", 0))
    order = sorted(names, key=lambda p: (p not in CALLOUT, -full_share[p]))
    for p in order:
        b = ipc(rs[ref][p])
        cells = [f"{b:.3f}"] + [f"{ipc(rs[n][p]) / b - 1:+.2%}" for n in list(cfgs)[1:]]
        print(f"| {p} | {full_share[p]:.1%} | " + " | ".join(cells) + " |")
    out = {"ipc": {n: {p: ipc(g) for p, g in r.items()} for n, r in rs.items()}, "full_share": full_share}
    print("| **Suite score** | | " + " | ".join(
        f"**{suite_ipc(rs[n]):.3f}**" if n == ref else f"**{suite_ipc(rs[n]) / suite_ipc(rs[ref]) - 1:+.2%}**"
        for n in cfgs) + " |")
    for gname, v in groups(names).items():
        print(f"| {gname} | | " + " | ".join(
            f"{gm(ipc(rs[n][p]) for p in v):.3f}" if n == ref else
            f"{gm(ipc(rs[n][p]) for p in v) / gm(ipc(rs[ref][p]) for p in v) - 1:+.2%}" for n in cfgs) + " |")
    out["suite"] = {n: suite_ipc(rs[n]) for n in cfgs}
    # steering: the ALU ops' ports, the moves off a slot's port and why, and register stalls (the banks' pressure)
    print(f"\n*Steering, {width}, {isa}* (suite totals: ALU ops by port; moves off the slot's port per 1,000 ALU ops, "
          "for want of the unit, a row or a register; dispatch stalls for a register per 1,000 instructions)\n")
    print("| Configuration | P0 / P1 / P2 | Moves: unit / row / register | Register stalls |\n|---|---|---|---|")
    out["steer"] = {}
    for n in cfgs:
        tot = {k: sum(g.get(k, 0) for g in rs[n].values()) for k in
               ("alu_p0", "alu_p1", "alu_p2", "alu_cap_moves", "alu_row_moves", "alu_reg_moves", "disp_stall_reg",
                "instr")}
        alu = max(1, tot["alu_p0"] + tot["alu_p1"] + tot["alu_p2"])
        out["steer"][n] = tot
        if not tot["alu_p0"] + tot["alu_p1"] + tot["alu_p2"]:
            print(f"| {n} | – | – | {tot['disp_stall_reg'] * 1000 / max(1, tot['instr']):.2f} |")
            continue
        print(f"| {n} | " + " / ".join(f"{tot[k] / alu:.0%}" for k in ("alu_p0", "alu_p1", "alu_p2")) + " | " +
              " / ".join(f"{tot[k] * 1000 / alu:.1f}" for k in ("alu_cap_moves", "alu_row_moves", "alu_reg_moves")) +
              f" | {tot['disp_stall_reg'] * 1000 / max(1, tot['instr']):.2f} |")
    return out


def alu_pairs(width, cfgs, base_pair, alone, workers):
    """The 42 pairs on the second final set: WS against each program alone on the merged window of the all-full
    configuration of the same width (a fixed reference, so WS compares throughput); hangs over the 42."""
    names = m.pair_workloads(m.FINALDIR)
    jobs = [(m.PRESET, {**m.RUNNER, **base_pair, **c, "dram_lat": lat}, f"{a}.s0", f"{b}.s1")
            for c in cfgs.values() for lat in m.LATS for _, a, b in smt.PAIRS]
    jobs += [(m.PRESET, {**alone, "dram_lat": lat}, w, None) for lat in m.LATS for w in names]
    m.run_all(jobs, workers)
    al = {lat: {w: m.ipc1(m.run7(m.PRESET, {**alone, "dram_lat": lat}, w, None)) for w in names} for lat in m.LATS}
    ref = next(iter(cfgs))
    per = {n: {lat: {} for lat in m.LATS} for n in cfgs}   # the pairs each configuration completes: (group, WS)
    for n, c in cfgs.items():
        for lat in m.LATS:
            for g, a, b in smt.PAIRS:
                ip = m.ipc2(m.run7(m.PRESET, {**m.RUNNER, **base_pair, **c, "dram_lat": lat}, f"{a}.s0", f"{b}.s1"))
                if ip is not None:
                    per[n][lat][(a, b)] = (g, ip[0] / al[lat][f"{a}.s0"] + ip[1] / al[lat][f"{b}.s1"])
    both = {lat: set.intersection(*(set(per[n][lat]) for n in cfgs)) for lat in m.LATS}   # completed by every one
    print(f"\n**The 42 pairs, {width}** ({m.FINALDIR.name}; step 7 as decided with 5f; WS against each program alone "
          f"on {ref}'s merged window, over the {' / '.join(str(len(both[lat])) for lat in m.LATS)} pairs every "
          "configuration completes; 30 / 120 / 250 cycles)\n")
    print("| Configuration | WS | Against the first | memory + memory | compute + compute | mixed | Hung, of the 42 |\n"
          "|---|---|---|---|---|---|---|")
    out, first = {}, None
    for n in cfgs:
        row = {"ws": [], "groups": [], "hung": []}
        for lat in m.LATS:
            gs = {g: gm(w for ab, (gg, w) in per[n][lat].items() if gg == g and ab in both[lat]) for g in m.GROUPS}
            row["ws"].append(gm(gs.values()))
            row["groups"].append(gs)
            row["hung"].append([smt.pname(a, b) for _, a, b in smt.PAIRS if (a, b) not in per[n][lat]])
        out[n] = row
        first = first or row
        f3 = lambda xs: " / ".join(f"{x:.3f}" for x in xs)
        vs = " / ".join(f"{x / y - 1:+.2%}" for x, y in zip(row["ws"], first["ws"]))
        print(f"| {n} | **{f3(row['ws'])}** | {vs} | " + " | ".join(f3(gs[g] for gs in row["groups"]) for g in m.GROUPS)
              + " | " + " / ".join(str(len(d)) for d in row["hung"]) + " |")
    for n, row in out.items():
        for lat, d in zip(m.LATS, row["hung"]):
            if d:
                print(f"- {n}, {lat} cycles: {', '.join(d)} hung")
    # the banks' pressure with two harts, each holding half of each bank's registers (prf_split)
    print(f"\n*Steering in the pairs, {width}* (both threads' regions over the 42 at 30 / 120 / 250 cycles: ALU ops by "
          "port; moves off the slot's port per 1,000 ALU ops, for want of the unit, a row or a register; dispatch "
          "stalls for a register per 1,000 instructions)\n")
    print("| Configuration | P0 / P1 / P2 | Moves: unit / row / register | Register stalls |\n|---|---|---|---|")
    keys = ("alu_p0", "alu_p1", "alu_p2", "alu_cap_moves", "alu_row_moves", "alu_reg_moves", "disp_stall_reg", "instr")
    for n, c in cfgs.items():
        tot = dict.fromkeys(keys, 0)
        for lat in m.LATS:
            for _, a, b in smt.PAIRS:
                r = m.run7(m.PRESET, {**m.RUNNER, **base_pair, **c, "dram_lat": lat}, f"{a}.s0", f"{b}.s1")
                if r.get("error"):   # a hung run's regions never ended
                    continue
                for t in r.get("threads") or []:
                    for k in keys:
                        tot[k] += t["region"].get(k, 0)
        alu = max(1, tot["alu_p0"] + tot["alu_p1"] + tot["alu_p2"])
        out[n]["steer"] = tot
        print(f"| {n} | " + " / ".join(f"{tot[k] / alu:.0%}" for k in ("alu_p0", "alu_p1", "alu_p2")) + " | " +
              " / ".join(f"{tot[k] * 1000 / alu:.1f}" for k in ("alu_cap_moves", "alu_row_moves", "alu_reg_moves")) +
              f" | {tot['disp_stall_reg'] * 1000 / max(1, tot['instr']):.2f} |")
    return out


def alu(workers):
    out = {}
    for isa in ("rv64gc", "rv64gcb"):
        out[f"3-wide {isa}"] = alu_suite("3-wide, 3 ALU ports", ALU3, BASE3, isa, workers)
        # st_w3 keeps st's queues, a third of each a slot bank: the same with half as many rows again
        out[f"3-wide, queues x1.5 {isa}"] = alu_suite("3-wide, 3 ALU ports, the issue queues x1.5",
                                                      {n: c for n, c in ALU3.items() if c}, {**BASE3, **BIGQ}, isa,
                                                      workers)
        out[f"2-wide {isa}"] = alu_suite("2-wide, 2 ALU ports (today's core)", ALU2, BASE2, isa, workers)
    pairs3 = {n: c for n, c in ALU3.items() if c}
    pairs2 = {n: c for n, c in ALU2.items() if c}
    out["pairs 3-wide"] = alu_pairs("3-wide, 3 ALU ports", pairs3, {**S7, **W3},
                                    {**m.ALONE, **m.REV8, **W3, **ALU3["3 full"]}, workers)
    # st_w3's queues split three ways leave IQ-STA one row a slot for slots 1 and 2: M7's policies hang pairs there
    out["pairs 3-wide, queues x1.5"] = alu_pairs("3-wide, 3 ALU ports, the issue queues x1.5", pairs3,
                                                 {**S7, **W3, **BIGQ},
                                                 {**m.ALONE, **m.REV8, **W3, **BIGQ, **ALU3["3 full"]}, workers)
    out["pairs 2-wide"] = alu_pairs("2-wide, 2 ALU ports", pairs2, S7, {**m.ALONE, **m.REV8, **ALU2["2 full"]},
                                    workers)
    return out


def pa(workers):
    """The false matches and their cost, per program, at 30 and 120 cycles."""
    out = {}
    for lat in PA_LATS:
        rs = {}
        for mn in ("pa", "ws", "manifest"):
            r = suite({n: {**BASE2, **c, "dram_lat": lat} for n, c in PA.items()}, "rv64gc", mn, workers)
            for n in PA:
                rs.setdefault(n, {}).update(r[n])
        ref = next(iter(PA))
        names = list(rs[ref])
        out[lat] = {n: {p: {k: g.get(k, 0) for k in ("instr", "cycles", "loads", "pa_ld_false", "pa_ld_retries",
                                                       "pa_viol_false", "violations", "violation_flushes")}
                        for p, g in r.items()} for n, r in rs.items()}
        print(f"\n**Partial-address search, {lat} cycles** (today's core alone; per program: IPC against full "
              "addresses, and per 1,000 loads the loads with a false match on a known store's address and the "
              "ordering flushes a false match on an unresolved one raises)\n")
        cfgs = list(PA)[1:]
        print("| Program | Loads / 1K instr. | Full addresses, IPC | " +
              " | ".join(c.replace(", a false match ", ": ") for c in cfgs) + " |\n|---|---|---|" + "---|" * len(cfgs))
        pick = [p for p in names if p.startswith(("pa_", "ws_copy", "ws_hash"))] + \
               [p for p in ("ms_stream", "ms_copy", "ms_hashprobe", "ms_gather", "ms_spmv", "coremark_A",
                            "dhrystone", "embench_crc32", "embench_huffbench") if p in names]
        for p in pick:
            b = rs[ref][p]
            lk = max(1, b.get("loads", 0)) / 1000
            cells = []
            for n in cfgs:
                g = rs[n][p]
                cells.append(f"{ipc(g) / ipc(b) - 1:+.2%} ({g.get('pa_ld_false', 0) / lk:.1f}, "
                             f"{g.get('pa_viol_false', 0) / lk:.1f})")
            print(f"| {p} | {b.get('loads', 0) * 1000 / max(1, b.get('instr', 0)):.0f} | {ipc(b):.3f} | " +
                  " | ".join(cells) + " |")
        suite_names = [p for p in names if p in out[lat][ref] and not p.startswith(("pa_", "ws_"))]
        sref = suite_ipc({p: rs[ref][p] for p in suite_names})
        print("| **Suite score** | | " + f"{sref:.3f} | " + " | ".join(
            f"{suite_ipc({p: rs[n][p] for p in suite_names}) / sref - 1:+.2%}" for n in cfgs) + " |")
        print("| Worst suite program | | | " + " | ".join(
            (lambda w: f"{w[1]} {w[0]:+.2%}")(min((ipc(rs[n][p]) / ipc(rs[ref][p]) - 1, p) for p in suite_names))
            for n in cfgs) + " |")
    return out


PA2 = {"full addresses": {},
       **{f"{n} bits, a false match replays once": {"lsq_pa_bits": n} for n in (20, 16, 12)},
       "12 bits, a false match waits for the store": {"lsq_pa_bits": 12, "lsq_pa_wait": 1}}


def pa2(workers):
    """§7.10: the copies a set distance apart and the scattered counter updates (pa2.jsonl), alone at 30 cycles; then
    the 42 pairs on the product (step 7 as decided, with 5f) at 30, 120 and 250 cycles."""
    out = {}
    rs = suite({n: {**BASE2, **c, "dram_lat": 30} for n, c in PA2.items()}, "rv64gc", "pa2", workers)
    ref = next(iter(PA2))
    cfgs = list(PA2)[1:]
    print("\n**Copies a set distance apart, and scattered counter updates** (today's core alone, 30 cycles; IPC "
          "against full addresses; per 1,000 loads, the loads with a false match on a known store's address and the "
          "ordering flushes a false match on an unresolved store raises; true ordering flushes per 1,000 loads with "
          "full addresses)\n")
    heads = " | ".join(c.replace(", a false match ", ": ") for c in cfgs)
    print(f"| Program | True flushes | Full addresses, IPC | {heads} |\n|---|---|---|" + "---|" * len(cfgs))
    for p in sorted(rs[ref], key=lambda p: (p.rstrip("0123456789"), int("".join(ch for ch in p if ch.isdigit()) or 0))):
        b = rs[ref][p]
        lk = max(1, b.get("loads", 0)) / 1000
        cells = [f"{ipc(rs[n][p]) / ipc(b) - 1:+.2%} ({rs[n][p].get('pa_ld_false', 0) / lk:.0f}, "
                 f"{rs[n][p].get('pa_viol_false', 0) / lk:.1f})" for n in cfgs]
        print(f"| {p} | {b.get('violations', 0) / lk:.1f} | {ipc(b):.3f} | " + " | ".join(cells) + " |")
    out["single"] = {n: {p: {k: g.get(k, 0) for k in ("instr", "cycles", "loads", "pa_ld_false", "pa_ld_retries",
                                                     "pa_viol_false", "violations", "violation_flushes")}
                         for p, g in r.items()} for n, r in rs.items()}
    # the product: two harts, the LQ and SQ in static halves; each load and store searches its own hart's entries
    names = m.pair_workloads(m.FINALDIR)
    pcfg = {n: c for n, c in PA2.items() if "waits" not in n}
    alone = {**m.ALONE, **m.REV8}
    jobs = [(m.PRESET, {**m.RUNNER, **S7, **c, "dram_lat": lat}, f"{a}.s0", f"{b}.s1")
            for c in pcfg.values() for lat in m.LATS for _, a, b in smt.PAIRS]
    jobs += [(m.PRESET, {**alone, "dram_lat": lat}, w, None) for lat in m.LATS for w in names]
    m.run_all(jobs, workers)
    al = {lat: {w: m.ipc1(m.run7(m.PRESET, {**alone, "dram_lat": lat}, w, None)) for w in names} for lat in m.LATS}
    print(f"\n**The 42 pairs on the product** ({m.FINALDIR.name}; step 7 as decided with 5f; WS against each program "
          "alone on its merged window, over the pairs every configuration completes; false matches per 1,000 loads "
          "over both threads; 30 / 120 / 250 cycles)\n")
    print("| Configuration | WS | Against full addresses | memory + memory | compute + compute | mixed | "
          "False matches, false flushes | Hung |\n|---|---|---|---|---|---|---|---|")
    per = {n: {lat: {} for lat in m.LATS} for n in pcfg}
    cnt = {n: [[0, 0, 0] for _ in m.LATS] for n in pcfg}   # loads, false matches, false flushes
    for n, c in pcfg.items():
        for i, lat in enumerate(m.LATS):
            for g, a, b in smt.PAIRS:
                r = m.run7(m.PRESET, {**m.RUNNER, **S7, **c, "dram_lat": lat}, f"{a}.s0", f"{b}.s1")
                ip = m.ipc2(r)
                if ip is None:
                    continue
                per[n][lat][(a, b)] = (g, ip[0] / al[lat][f"{a}.s0"] + ip[1] / al[lat][f"{b}.s1"])
                for t in r["threads"]:
                    cnt[n][i][0] += t["region"].get("loads", 0)
                    cnt[n][i][1] += t["region"].get("pa_ld_false", 0)
                    cnt[n][i][2] += t["region"].get("pa_viol_false", 0)
    both = {lat: set.intersection(*(set(per[n][lat]) for n in pcfg)) for lat in m.LATS}
    first = None
    out["pairs"] = {}
    for n in pcfg:
        ws, gss = [], []
        for lat in m.LATS:
            gs = {g: gm(w for ab, (gg, w) in per[n][lat].items() if gg == g and ab in both[lat]) for g in m.GROUPS}
            ws.append(gm(gs.values()))
            gss.append(gs)
        first = first or ws
        hung = [42 - len(per[n][lat]) for lat in m.LATS]
        out["pairs"][n] = {"ws": ws, "groups": gss, "hung": hung, "counts": cnt[n]}
        f3 = lambda xs: " / ".join(f"{x:.3f}" for x in xs)
        fm = " / ".join(f"{c[1] * 1000 / max(1, c[0]):.2f}, {c[2] * 1000 / max(1, c[0]):.3f}" for c in cnt[n])
        print(f"| {n} | **{f3(ws)}** | " + " / ".join(f"{x / y - 1:+.2%}" for x, y in zip(ws, first)) + " | " +
              " | ".join(f3(gs[g] for gs in gss) for g in m.GROUPS) + f" | {fm} | " +
              " / ".join(map(str, hung)) + " |")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--alu", action="store_true", help="asymmetric ALU ports")
    ap.add_argument("--pa", action="store_true", help="partial-address LQ/SQ search")
    ap.add_argument("--pa2", action="store_true", help="the same: copies a set distance apart, scatters, the pairs")
    ap.add_argument("--workers", type=int, default=14)
    a = ap.parse_args()
    res = json.loads(OUT.read_text()) if OUT.exists() else {}
    for name, fn in (("alu", alu), ("pa", pa), ("pa2", pa2)):
        if getattr(a, name):
            res[name] = fn(a.workers)
            OUT.write_text(json.dumps(res, indent=1) + "\n")


if __name__ == "__main__":
    main()
