#!/usr/bin/env python3
"""M9's indirect-target predictor on the RTL beside tgsim (docs/perf/area_recovery.md §7.12): DR-190 takes the
256-entry path-hashed table if it gives at least 0.5% on the boot or the suite, else the 128-entry micro-BTB.

The RTL side: tg_vsim (one hart) and tb_boot (the board's shape: two cores, thread 0 of each), each built twice, the
smt2 core as on main (64-entry micro-BTB) and with UBTB_ENTRIES 128, with scripts/rtlprof/prof_itt.sv bound. That
bind prints every committed JALR other than a return: its PC, target, whether commit flushed it as a mispredict,
whether the micro-BTB predicted it, and the commit stall after it.
- (b), the micro-BTB at 128, is measured: the two builds' region IPC, and the boot's cycles to TANAGER-BOOT-OK.
- (a), the table, is estimated from each run's stream: the stream is replayed through a shadow table that works as
  tgsim's itt_entries does (consulted when the micro-BTB missed or was wrong last time; the PC xor the last four
  indirect targets; an 8-bit tag; trained with every target).
  - Each mispredict the table would have caught saves its measured stall, less the stall after a predicted jump and
    the F2 redirect's 2 cycles.
  - Each right micro-BTB target the table would have overridden wrongly costs a mean mispredict's stall.
The model side: tgsim on the same ELFs (the rtl_m2 preset with main's M6 set and the st sizes, 30 cycles, as
rtlcal.py), today, (a) and (b).

  python3 scripts/m9_rtl.py --elfs DIR --vsim64 DIR --vsim128 DIR [--boot64 LOG --boot128 LOG] [--workers N]
      the vsim directories hold <program>.log, tg_vsim's output for DIR's <program>.elf
-> results/m9_rtl.json"""
import argparse
import hashlib
import json
import re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import m7_smt as m
import tgrun

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "m9_rtl.json"
PRESET = "rtl_m2"
BASE = {**m.CORE, "m9_counts": 1, "dram_lat": 30}   # as m9_plan.py: the st sizes are the smt2 core's merged window
CFGS = {"today": {}, "(a) table": {"itt_entries": 256}, "(b) micro-BTB 128": {"ubtb": 128}}
F2 = 2   # the F2 redirect's bubble (m2_f2_bubble)
REC = re.compile(r"^smt2_itt: (\d+) (\d+) (\d+) ([0-9a-f]+) ([0-9a-f]+) (\d) (\d) (\d+) (\d+) (\d+)")
AT = re.compile(r"^smt2_itt_at: (.*)")
REGION = re.compile(r"^smt2_itt_region: (\d+) (\d) (\d+)")
KS = (1, 8, 32)   # the stall measured to a jump's 1st, 8th and 32nd younger retirement


def parse(path):
    """({(core, thread): records}, {core: every smt2_itt_at line's counters, in order}, tg_vsim's TG-RESULT fields,
    {core: [(1 start or 2 stop, cycle)]})"""
    recs, ats, res, regions = {}, {}, {}, {}
    with open(path, errors="replace") as f:
        for line in f:
            r = REC.match(line)
            if r:
                recs.setdefault((int(r[1]), int(r[2])), []).append(
                    (int(r[3]), int(r[4], 16), int(r[5], 16), int(r[6]), int(r[7]), int(r[8]), int(r[9]), int(r[10])))
                continue
            a = AT.match(line)
            if a:
                v = a[1].split()
                c = {v[i]: int(v[i + 1]) for i in range(0, len(v) - 1, 2)}
                ats.setdefault(c["core"], []).append(c)
                continue
            g = REGION.match(line)
            if g:
                regions.setdefault(int(g[1]), []).append((int(g[2]), int(g[3])))
            elif line.startswith("TG-RESULT"):
                res = dict(x.split("=", 1) for x in line.split()[1:] if "=" in x)
    for v in recs.values():
        v.sort()
    return recs, ats, res, regions


def replay(recs, entries=256, frm=0, until=None):
    """The stream through a shadow table as tgsim's itt_entries: today's and the table's mispredicts, and the cycles
    it would save (net of the overrides it would get wrong), for each K in KS: a fixed mispredict saves its stall to
    the K-th younger retirement less a predicted jump's mean and the F2 redirect's bubble; a wrong override costs a
    mispredict's mean less a predicted jump's."""
    mask = entries - 1
    tab, bad, path = {}, [False] * entries, 0
    out = dict(ijmp=0, misp=0, hit=0, used=0, right=0, fixes=0, breaks=0)
    gs = {k: {"misp": [0, 0], "ok": [0, 0], "fix": [0, 0]} for k in KS}   # [sum, count] of measured stalls
    for cyc, pc, tgt, misp, hit, g1, g8, g32 in recs:
        if cyc < frm:
            continue
        if until is not None and cyc >= until:
            break
        out["ijmp"] += 1
        out["misp"] += misp
        out["hit"] += hit
        g = dict(zip(KS, (g1, g8, g32)))
        for k in KS:
            if g[k]:
                s = gs[k]["misp" if misp else "ok"]
                s[0] += g[k]
                s[1] += 1
        p = pc >> 1
        i = (p ^ path ^ (path >> 8)) & mask
        tag = (p ^ (p >> 8)) & 0xff
        ub_ok = not misp   # a JALR the RTL got right had the micro-BTB's target (a miss falls through)
        if not hit or bad[p & mask]:
            e = tab.get(i)
            if e is not None and e[0] == tag:
                out["used"] += 1
                out["right"] += e[1] == tgt
                if ub_ok and hit and e[1] != tgt:
                    out["breaks"] += 1
                elif misp and e[1] == tgt:
                    out["fixes"] += 1
                    for k in KS:
                        if g[k]:
                            gs[k]["fix"][0] += g[k]
                            gs[k]["fix"][1] += 1
        bad[p & mask] = not (hit and ub_ok)
        tab[i] = (tag, tgt)
        path = ((path << 4) ^ (tgt >> 2)) & 0xffff
    for k in KS:
        mean = {n: s[0] / s[1] if s[1] else 0.0 for n, s in gs[k].items()}
        per_fix = max(0.0, mean["fix"] - mean["ok"] - F2)   # fixes with the stall unmeasured count at the mean
        out[f"g{k}_misp"], out[f"g{k}_ok"], out[f"g{k}_fix"] = mean["misp"], mean["ok"], mean["fix"]
        out[f"saved{k}"] = out["fixes"] * per_fix - out["breaks"] * max(0.0, mean["misp"] - mean["ok"])
    out["saved"] = out["saved32"]
    return out


def sha(path):
    return hashlib.sha1(Path(path).read_bytes()).hexdigest()[:16]


def model(elfs, workers, cache):
    """tgsim on each ELF in each configuration: {config: {program: region stats}}, cached by ELF content."""
    jobs = [(n, e) for n in CFGS for e in elfs]

    def one(j):
        n, e = j
        k = f"{sha(e)}|{json.dumps(sorted({**BASE, **CFGS[n]}.items()))}"
        if k not in cache:
            r = tgrun.run_one({"name": e.stem, "elf": str(e), "stdin": "", "ff": 0}, PRESET, {**BASE, **CFGS[n]})
            if r.get("error") or not r.get("region", {}).get("cycles"):
                raise SystemExit(f"tgsim failed on {e} ({n}): {r.get('error', '')}")
            cache[k] = r["region"]
        return n, e.stem, cache[k]

    out = {n: {} for n in CFGS}
    with ThreadPoolExecutor(max_workers=workers) as ex:
        for n, p, g in ex.map(one, jobs):
            out[n][p] = g
    return out


def ipc(g):
    return g.get("instr", 0) / max(1, g.get("cycles", 0))


def pct(x):
    return f"{x:+.2%}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--elfs", required=True)
    ap.add_argument("--vsim64", required=True)
    ap.add_argument("--vsim128", required=True)
    ap.add_argument("--boot64")
    ap.add_argument("--boot128")
    ap.add_argument("--workers", type=int, default=14)
    a = ap.parse_args()
    res = json.loads(OUT.read_text()) if OUT.exists() else {}
    cache = res.get("model_cache", {})
    elfs = sorted(Path(a.elfs).glob("*.elf"))
    mo = model(elfs, a.workers, cache)
    res["model_cache"] = cache
    rows, out = [], {}
    for e in elfs:
        p = e.stem
        r64, a64, t64, g64 = parse(Path(a.vsim64) / f"{p}.log")
        r128, _, t128, g128 = parse(Path(a.vsim128) / f"{p}.log")
        if t64.get("status") != "PASS" or t128.get("status") != "PASS":
            print(f"skipped {p}: tg_vsim {t64.get('status')} / {t128.get('status')}")
            continue
        i64 = int(t64["region_instret"]) / int(t64["region_cycles"])
        i128 = int(t128["region_instret"]) / int(t128["region_cycles"])
        # the stream within the region (its markers), else the whole run
        w64, w128 = dict(g64.get(0, [])), dict(g128.get(0, []))
        s64 = replay(r64.get((0, 0), []), frm=w64.get(1, 0), until=w64.get(2))
        s128 = replay(r128.get((0, 0), []), frm=w128.get(1, 0), until=w128.get(2))
        at64 = a64.get(0, [{}])[-1]
        base = int(t64["region_cycles"]) if 2 in w64 else at64.get("cycles", 1)
        ki = max(1, int(t64["region_instret"]) if 2 in w64 else at64.get("instret", 0)) / 1000
        g = {n: ipc(mo[n][p]) for n in CFGS}
        out[p] = {"rtl_ipc": i64, "rtl_ipc_128": i128, "rtl_b": i128 / i64 - 1, "region": 2 in w64,
                  "rtl_a_est": s64["saved32"] / max(1, base - s64["saved32"]),
                  "rtl_a_est1": s64["saved1"] / max(1, base - s64["saved1"]),
                  "rtl_ijmp_k": s64["ijmp"] / ki, "rtl_misp_k": s64["misp"] / ki,
                  "rtl_misp_a_k": (s64["misp"] - s64["fixes"] + s64["breaks"]) / ki,
                  "model_ipc": g["today"], "model_a": g["(a) table"] / g["today"] - 1,
                  "model_b": g["(b) micro-BTB 128"] / g["today"] - 1,
                  "model_ijmp_k": mo["today"][p].get("br_jalr", 0) * 1000 / max(1, mo["today"][p]["instr"]),
                  "model_misp_k": mo["today"][p].get("mp_target", 0) * 1000 / max(1, mo["today"][p]["instr"]),
                  "stream64": s64, "stream128": s128}
        rows.append(p)
    print("\n**The suite and the interpreters on the RTL (smt2, one hart, 30 cycles) beside tgsim** (region IPC "
          "today; with (b) the micro-BTB at 128, measured on the RTL; with (a) the 256-entry table, estimated from the "
          "RTL's own stream in the region, each fixed mispredict costed to its 32nd younger retirement (to the 1st in "
          "parentheses), and modelled; indirect jumps and their mispredicts per 1,000 instructions, RTL / model)\n")
    print("| Program | IPC: RTL / model | (b): RTL measured / model | (a): RTL estimate / model | Indirect jumps / 1K |"
          " Their mispredicts / 1K: today, with (a) |\n|---|---|---|---|---|---|")
    for p in sorted(rows, key=lambda p: -out[p]["rtl_ijmp_k"]):
        o = out[p]
        print(f"| {p} | {o['rtl_ipc']:.3f} / {o['model_ipc']:.3f} | {pct(o['rtl_b'])} / {pct(o['model_b'])} | "
              f"{pct(o['rtl_a_est'])} ({pct(o['rtl_a_est1'])}) / {pct(o['model_a'])} | "
              f"{o['rtl_ijmp_k']:.2f} / {o['model_ijmp_k']:.2f} | "
              f"{o['rtl_misp_k']:.2f} → {o['rtl_misp_a_k']:.2f} (model today {o['model_misp_k']:.2f}) |")
    suite = [p for p in rows if not p.startswith("m9_")]
    if suite:
        def gm(xs):
            return tgrun.geomean([1 + x for x in xs]) - 1
        print(f"| **Geometric mean, the {len(suite)} suite programs** | | "
              f"{pct(gm([out[p]['rtl_b'] for p in suite]))} / {pct(gm([out[p]['model_b'] for p in suite]))} | "
              f"{pct(gm([out[p]['rtl_a_est'] for p in suite]))} ({pct(gm([out[p]['rtl_a_est1'] for p in suite]))})"
              f" / {pct(gm([out[p]['model_a'] for p in suite]))} | | |")
    res["programs"] = out
    if a.boot64 and a.boot128:
        runs = {"micro-BTB 64 (today)": parse(a.boot64), "micro-BTB 128 (b)": parse(a.boot128)}
        boot = {}
        print("\n**The Linux boot to TANAGER-BOOT-OK on the RTL** (per core; board timing; busy = cycles without a WFI "
              "at the committing hart's ROB head)\n")
        print("| Run | Core | Cycles | Busy cycles | Instructions | Indirect jumps / 1K | Their mispredicts / 1K | "
              "All mispredicts / 1K | (a)'s estimate on busy cycles: to the 32nd (1st) | ... on all cycles | "
              "(a)'s mispredicts / 1K |\n|---|---|---|---|---|---|---|---|---|---|---|")
        for n, (recs, ats, _, _) in runs.items():
            boot[n] = {}
            for c in sorted(ats):
                at = ats[c][-1]
                ss = [replay(v) for (cc, _t), v in sorted(recs.items()) if cc == c]
                ks = ("ijmp", "misp", "fixes", "breaks", "saved", "saved1")
                s = {k: sum(x[k] for x in ss) for k in ks} if ss else dict.fromkeys(ks, 0)
                busy = at["cycles"] - at["wfi"]
                ki = max(1, at["instret"]) / 1000
                boot[n][c] = {**at, "busy": busy, "streams": ss, "a_est": s["saved"] / max(1, busy - s["saved"]),
                              "a_est1": s["saved1"] / max(1, busy - s["saved1"]),
                              "a_est_total": s["saved"] / max(1, at["cycles"] - s["saved"])}
                print(f"| {n} | {c} | {at['cycles']:,} | {busy:,} | {at['instret']:,} | {s['ijmp'] / ki:.2f} | "
                      f"{s['misp'] / ki:.2f} | {at['misp'] / ki:.2f} | {pct(boot[n][c]['a_est'])} "
                      f"({pct(boot[n][c]['a_est1'])}) | {pct(boot[n][c]['a_est_total'])} | "
                      f"{(s['misp'] - s['fixes'] + s['breaks']) / ki:.2f} |")
        b64, b128 = boot["micro-BTB 64 (today)"], boot["micro-BTB 128 (b)"]
        # (b) measured: the boot's cycles, and busy cycles per instruction over the cores (the two runs' instruction
        # counts differ by their idle loops)
        cpi64 = sum(x["busy"] for x in b64.values()) / sum(x["instret"] for x in b64.values())
        cpi128 = sum(x["busy"] for x in b128.values()) / sum(x["instret"] for x in b128.values())
        boot["b_measured_busy"] = cpi64 / cpi128 - 1
        boot["b_measured_total"] = b64[0]["cycles"] / b128[0]["cycles"] - 1
        print(f"\n(b) measured: {pct(boot['b_measured_busy'])} on busy cycles per instruction, "
              f"{pct(boot['b_measured_total'])} on the boot's cycles to TANAGER-BOOT-OK.")
        # the first 20M cycles, as area_recovery §6.10-§6.11 (core 0, which runs the early boot alone)
        recs64, ats64, _, _ = runs["micro-BTB 64 (today)"]
        w = next((x for x in ats64.get(0, []) if x["cycles"] == 20_000_000), None)
        if w:
            s = replay(recs64.get((0, 0), []), until=20_000_000)
            busy = w["cycles"] - w["wfi"]
            boot["first20M"] = {**w, "stream": s, "a_est": s["saved"] / max(1, busy - s["saved"])}
            ki = w["instret"] / 1000
            print(f"First 20M cycles, core 0 (§6.11's window): {w['instret']:,} instructions, indirect jumps "
                  f"{s['ijmp'] / ki:.2f} / 1K, their mispredicts {s['misp'] / ki:.2f} / 1K of all "
                  f"{w['misp'] / ki:.2f}; (a)'s estimate {pct(boot['first20M']['a_est'])}")
        res["boot"] = boot
    OUT.write_text(json.dumps(res, indent=1) + "\n")


if __name__ == "__main__":
    main()
