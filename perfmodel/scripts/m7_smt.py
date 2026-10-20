"""M7 (SMT2; docs/spec/m7-smt2-plan.md): the model's answers before the RTL, on the RTL-calibrated model.

The core is rtl_m2 revision 7 as the board's smt2 core: M6's set, ROB 80, LQ 24, SQ 20 and 24 long-latency tags,
and the store ownership prefetch (main's STORE_PF), on tg_vsim's flat memory at 30, 120 and 250 cycles. M7's policy
(the plan's D1, D7): static ROB/LQ/SQ halves, ICOUNT at fetch, decode, rename and commit alternating with idle slots
shared, 75% issue-queue caps, TID-hashed predictors. Pairs and their metrics are scripts/smt.py's (42 pairs; a
thread's IPC over its program's first run, the shorter program restarted so both threads stay busy).
  python3 scripts/m7_smt.py --policy    # D7: ICOUNT against round robin; the issue-queue cap level
  python3 scripts/m7_smt.py --exit2     # exit 2: weighted throughput against the same core running one program
  python3 scripts/m7_smt.py --deadlock  # D8: the store drain against the sibling's misses, with and without fairness
  python3 scripts/m7_smt.py --fp        # D3: FP-heavy pairs with per-thread free lists
  python3 scripts/m7_smt.py --lone      # D2: a lone thread with its sibling asleep: halves, merged, transitions
  python3 scripts/m7_smt.py --pair      # exit 2 blind on verif-2's pair runner: its programs, barrier and restarts
  python3 scripts/m7_smt.py --homes     # D4's alternatives for hart 1's register homes: a lone hart and pairs
  python3 scripts/m7_smt.py --calib     # the runner's programs alone against verif-2's RTL alone runs
  python3 scripts/m7_smt.py --final     # exit 2 blind on verif-2's final pair set (REPEAT builds), rtl_m2 revision 8
Results -> results/m7_smt_rv64gc.json (each section keeps the others' earlier results).
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dse  # noqa: E402
import smt  # noqa: E402
import tgrun  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "m7_smt_rv64gc.json"
CACHE7 = ROOT / "results" / "m7"   # runs that may deadlock (D3, D8) or use the D2 knobs, errors kept
M7_VERSION = 1
PRESET = "rtl_m2"
smt.PRESET = PRESET   # smt.py's runner and cache keys read it at call time
if os.environ.get("TG_TGSIM"):   # a tgsim built elsewhere (the M7 knobs before they reach this tree's build)
    tgrun.TGSIM = Path(os.environ["TG_TGSIM"])
ISA = "rv64gc"
for _m in ("extra", "ws", "m7"):
    if (ROOT / "build" / "bench" / ISA / f"{_m}.jsonl").exists():
        smt.WS.update({w["name"]: w for w in tgrun.manifest(ISA, _m)})
LATS = (30, 120, 250)
M6 = {"ras": 32, "m2_dir": 1, "dirpred": 2, "tage_log": 12, "m2_f2": 1, "m2_btage": 1, "btage_nt": 2, "btage_li": 11,
      "m2_cut": 1, "m2_f2_bubble": 2, "m2_ftq": 32, "m2_ras_f2": 1}
SMT2 = {"rob": 80, "lq": 24, "sq": 20, "llt": 24}
CORE = {**M6, **SMT2, "rfo_pf": 1}
POLICY = {"threads": 2, "smt_fetch": 0, "smt_part": 1, "smt_win_cap": 75, "smt_iq_cap": 75, "smt_mshr_cap": 100,
          "smt_llt_cap": 100, "smt_bp_hash": 1, "smt_mix": 1, "drain_guard": 1}
M7 = {**CORE, **POLICY}
GROUPS = smt.GROUPS


def single(sets):
    """The same core running one program: threads=1 gives the one thread every partition (D2's merged window)."""
    return smt.single(sets)


def alone(sets, lat, mname="manifest"):
    s = {**single(sets), "dram_lat": lat}
    rs = dse.collect([(PRESET, s)], ISA, mname=mname)[dse.key(f"{ISA}:{mname}" if mname != "manifest" else ISA,
                                                                 PRESET, s)[0]]
    return {r["workload"]["name"]: r["region"]["instr"] / max(1, r["region"]["cycles"]) for r in rs}


def evaluate(sets, lat, pairs=None, ref=None):
    """Weighted speedup per pair (IPC_smt / IPC_alone summed over the two threads), by group and overall (the
    geometric mean of the group means, as scripts/smt.py), against the same core running one program at a time."""
    pairs = pairs or smt.PAIRS
    s = {**sets, "dram_lat": lat}
    data = smt.collect([(s, a, b) for _, a, b in pairs])
    same = ref or alone(sets, lat)
    per = {}
    for g, a, b in pairs:
        r = data[smt.pair_key(s, a, b)[0]]
        ipc = [t["region"]["instr"] / max(1, t["region"]["cycles"]) for t in r["threads"]]
        sp = [ipc[0] / same[a], ipc[1] / same[b]]
        reg = [t["region"] for t in r["threads"]]
        per[smt.pname(a, b)] = {"group": g, "ipc": ipc, "speedup": sp, "ws": sum(sp),
                                "fair": 2.0 / sum(1.0 / max(1e-9, x) for x in sp),
                                "stall_iq": [x["disp_stall_iq"] / max(1, x["cycles"]) for x in reg],
                                "stall_reg": [x["disp_stall_reg"] / max(1, x["cycles"]) for x in reg]}
    out = {"pairs": per, "groups": {}}
    for g in GROUPS:
        ms = [m for m in per.values() if m["group"] == g]
        if ms:
            out["groups"][g] = {"ws": smt.gm(m["ws"] for m in ms), "fair": smt.gm(m["fair"] for m in ms),
                                "min_ws": min(m["ws"] for m in ms), "n": len(ms)}
    G = [out["groups"][g] for g in GROUPS if g in out["groups"]]
    out["ws"] = smt.gm(e["ws"] for e in G)
    out["fair"] = smt.gm(e["fair"] for e in G)
    out["min_ws"] = min(m["ws"] for m in per.values())
    return out


def line(name, e):
    return (f"| {name} | **{e['ws']:.3f}** | " + " | ".join(f"{e['groups'][g]['ws']:.3f}" for g in GROUPS) +
            f" | {e['min_ws']:.3f} | {e['fair']:.3f} |")


HEAD = ("| Configuration | WS, all pairs | memory + memory | compute + compute | mixed | Lowest pair | Fairness |\n"
        "|---|---|---|---|---|---|---|")


def policy(workers):
    """D7 and the cap: ICOUNT against round robin at fetch, and the issue-queue cap, at each latency."""
    var = {"M7 (ICOUNT, 75% caps)": M7, "round robin at fetch": {**M7, "smt_fetch": 1},
           "round robin, 50% caps": {**M7, "smt_fetch": 1, "smt_iq_cap": 50}}
    for cap in (25, 37, 50, 62, 87, 100):
        var[f"issue-queue cap {cap}%"] = {**M7, "smt_iq_cap": cap}
    for cap in (50, 62, 75):
        var[f"{cap}% caps, never a whole bank"] = {**M7, "smt_iq_cap": cap, "smt_iq_cap_bank": 2}
        var[f"{cap}% caps, last row kept on demand"] = {**M7, "smt_iq_cap": cap, "smt_iq_cap_bank": 3}
        var[f"{cap}% caps per bank"] = {**M7, "smt_iq_cap": cap, "smt_iq_cap_bank": 1}
    smt.collect([({**s, "dram_lat": lat}, a, b) for s in var.values() for lat in LATS for _, a, b in smt.PAIRS],
                workers)
    res = {}
    for lat in LATS:
        same = alone(M7, lat)
        print(f"\n**{lat} cycles**\n\n{HEAD}")
        res[lat] = {}
        for n, s in var.items():
            e = evaluate(s, lat, ref=same)
            res[lat][n] = e
            print(line(n, e))
    return res


def exit2(workers):
    """The prediction exit 2 is checked against: M7's configuration, the 42 pairs, 30/120/250 cycles."""
    smt.collect([({**M7, "dram_lat": lat}, a, b) for lat in LATS for _, a, b in smt.PAIRS], workers)
    res = {}
    for lat in LATS:
        res[lat] = evaluate(M7, lat)
    print(f"\n**Weighted throughput, M7's configuration** (against the same core running one program at a time)\n")
    print("| Pair | Group | " + " | ".join(f"WS at {lat}" for lat in LATS) + " |")
    print("|---|---|" + "---|" * len(LATS))
    for _, a, b in smt.PAIRS:
        p = smt.pname(a, b)
        print(f"| {p} | {res[LATS[0]]['pairs'][p]['group']} | " +
              " | ".join(f"{res[lat]['pairs'][p]['ws']:.3f}" for lat in LATS) + " |")
    print(f"\n{HEAD}")
    for lat in LATS:
        print(line(f"{lat} cycles", res[lat]))
    return res


# ---------------------------------------------------------------- runs that may deadlock (D3, D8) and D2's knobs


def run7(preset, sets, a, b=None):
    """One run, a single thread (b None) or a pair, cached in results/m7 with any error (a deadlock) kept."""
    key = [ISA, preset, sorted(sets.items()), a, b, dse.MODEL_VERSION, smt.SMT_VERSION, M7_VERSION]
    hs = [smt.WS[w]["hash"] for w in (a, b) if w and "hash" in smt.WS[w]]   # the pair runner's ELFs, by content
    raw = json.dumps(key + ([hs] if hs else []))
    f = CACHE7 / f"{hashlib.sha1(raw.encode()).hexdigest()[:16]}.json"
    if f.exists():
        return json.loads(f.read_text())
    if b is None:
        r = tgrun.run_one(smt.WS[a], preset, sets)
    else:
        w0, w1 = smt.WS[a], smt.WS[b]
        args = [str(tgrun.TGSIM), "--preset", preset, "--bench", a, "--bench2", b]
        cfg = dict(sets)
        if w0.get("ff"):
            cfg.setdefault("ff", 1)
        for k, v in cfg.items():
            args += ["--set", f"{k}={v}"]
        args += ["--stdin", w0["stdin"]] if w0.get("stdin") else []
        args += ["--stdin2", w1["stdin"]] if w1.get("stdin") else []
        args += ["--ff2", "1"] if w1.get("ff") else []
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tf:
            out = tf.name
        p = subprocess.run(args + ["--json", out, w0["elf"], w1["elf"]], capture_output=True, text=True)
        try:
            r = json.loads(Path(out).read_text())
        except Exception:  # noqa: BLE001
            r = {"error": f"no result (rc={p.returncode}) {p.stderr[-300:]}", "threads": []}
        finally:
            Path(out).unlink(missing_ok=True)
    r.pop("config", None)
    CACHE7.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps(r))
    return r


def run_all(jobs, workers):
    """jobs: [(preset, sets, a, b)] -> results in the same order."""
    with ThreadPoolExecutor(max_workers=workers) as ex:
        return list(ex.map(lambda j: run7(*j), jobs))


def dead(r):
    return "deadlock" in r.get("error", "")


def ipc1(r):
    g = r.get("region", {})
    return None if r.get("error") else g.get("instr", 0) / max(1, g.get("cycles", 0))


def ipc2(r):
    return None if r.get("error") else [t["region"]["instr"] / max(1, t["region"]["cycles"]) for t in r["threads"]]


WS_PAIRS = [("ws", f"ws_{a}_{k}", f"ws_{b}_{k}") for k in (512, 1024, 2048, 4096)
            for a, b in zip(("chase1", "chase8", "hash", "copy"), ("chase8", "hash", "copy", "chase1"))]


def deadlock(workers):
    """D8: the pairs that deadlock without the store drain's priority for a free L1D miss entry, with it, and with it
    but without the drain's alternation between the threads. (a) The study's runs of 10-16 that found the five
    (area_recovery.md §6.2: v1 as built on tanager_v1 with one L1D miss entry, the SoC's uncore at 94-150 MHz, both
    profiles); (b) M7's core at 30, 120 and 250 cycles. The priority is the model's drain_guard 1: a committed store
    that found no free entry gets the next one, ahead of load misses and prefetches."""
    import clock_low as cl
    pairs = smt.PAIRS + WS_PAIRS
    pts = [(f, p) for f in cl.CLOCKS for p in ("default", "fallback")]
    ca = {"no priority": 0, "D8 (priority)": 1}
    cb = {"no priority": {**M7, "drain_guard": 0}, "D8 (priority)": M7,
          "D8, the drain not alternating": {**M7, "smt_drain_rr": 0},
          "D8, caps per bank": {**M7, "smt_iq_cap_bank": 1},
          "D8, 50% caps per bank": {**M7, "smt_iq_cap": 50, "smt_iq_cap_bank": 1},
          "D8, 50% caps": {**M7, "smt_iq_cap": 50},
          "D8, 75% caps, never a whole bank": {**M7, "smt_iq_cap_bank": 2},
          "D8, 50% caps, never a whole bank": {**M7, "smt_iq_cap": 50, "smt_iq_cap_bank": 2},
          "D8, 50% caps, the last row kept for a waiting sibling": {**M7, "smt_iq_cap": 50, "smt_iq_cap_bank": 3},
          "D8, 75% caps, the last row kept for a waiting sibling": {**M7, "smt_iq_cap_bank": 3}}
    jobs = [("tanager_v1", {**cl.v1_share(f, p, 1), "drain_guard": g}, a, b)
            for f, p in pts for g in ca.values() for _, a, b in pairs]
    jobs += [(PRESET, {**c, "dram_lat": lat}, a, b) for lat in LATS for c in cb.values() for _, a, b in pairs]
    res = iter(run_all(jobs, workers))
    out = {"a": {}, "b": {}}
    print("\n**(a) The 10-16 runs (v1 as built, one L1D miss entry): deadlocked pairs**\n")
    print("| Clock, profile | " + " | ".join(ca) + " |\n|---|" + "---|" * len(ca))
    for f, p in pts:
        row = {n: [smt.pname(a, b) for _, a, b in pairs if dead(next(res))] for n in ca}
        out["a"][f"{f} {p}"] = row
        print(f"| {f} MHz, {p} | " + " | ".join(", ".join(v) or "none" for v in row.values()) + " |")
    print("\n**(b) M7's core: deadlocked pairs**\n")
    print("| Latency | " + " | ".join(cb) + " |\n|---|" + "---|" * len(cb))
    for lat in LATS:
        row = {}
        for n in cb:
            rs = [(a, b, next(res)) for _, a, b in pairs]
            row[n] = {"dead": [smt.pname(a, b) for a, b, r in rs if dead(r)],
                      "other_errors": [smt.pname(a, b) for a, b, r in rs if r.get("error") and not dead(r)],
                      "ipc": {smt.pname(a, b): ipc2(r) for a, b, r in rs}}
        out["b"][lat] = row
        print(f"| {lat} | " + " | ".join(", ".join(v["dead"]) or "none" for v in row.values()) + " |")
    return out


FP = ["embench_nbody", "embench_cubic", "embench_minver", "embench_st", "tk_dgemm"]
FP_PAIRS = ([("fp+fp", a, b) for i, a in enumerate(FP) for b in FP[i:]] +
            [("fp+int", a, c) for a in FP for c in ("coremark_A", "dhrystone")])
RESTORE = ["m7_fprestore", "m7_fprestore2"]
RESTORE_PAIRS = [("restore", "m7_fprestore", "m7_fprestore"), ("restore", "m7_fprestore2", "m7_fprestore2"),
                 ("restore", "m7_fprestore2", "embench_nbody"), ("restore", "coremark_A", "m7_fprestore")]
PRF = {"shared lists (today)": {}, "D3 as planned": {"prf_split": 1},
       "D3, steered by free list": {"prf_split": 1, "prf_steer": 1},
       "integer per thread, FP shared": {"prf_split": 2, "prf_steer": 1},
       "FP per thread, integer shared": {"prf_split": 3}}


def fp(workers):
    """D3: free lists per thread in each register bank. A lone thread with its own lists (the suite, the dense GEMM
    and the FP restores), the FP-heavy pairs, and the restores in pairs; deadlocks counted, IPC against today's
    shared lists."""
    suite = [w["name"] for w in tgrun.manifest(ISA)] + ["tk_dgemm"] + RESTORE
    jobs = [(PRESET, {**single(M7), **v, "dram_lat": 30}, w, None) for v in PRF.values() for w in suite]
    jobs += [(PRESET, {**M7, **v, "dram_lat": lat}, a, b) for lat in (30, 120) for v in PRF.values()
             for _, a, b in FP_PAIRS + RESTORE_PAIRS]
    res = iter(run_all(jobs, workers))
    out = {"lone": {}, "pairs": {}}
    lone = {n: {w: next(res) for w in suite} for n in PRF}
    base = {w: ipc1(r) for w, r in lone["shared lists (today)"].items()}
    print("\n**One thread with its own free lists** (30 cycles; IPC against today's shared lists; † deadlock)\n")
    print("| Free lists | Deadlocks | Suite IPC (geomean of the runs that finish) | Largest losses |\n"
          "|---|---|---|---|")
    for n, rs in lone.items():
        ok = [w for w, r in rs.items() if ipc1(r) is not None and base.get(w)]
        d = [w for w, r in rs.items() if dead(r)]
        ch = {w: ipc1(rs[w]) / base[w] - 1 for w in ok}
        worst = sorted(ch.items(), key=lambda kv: kv[1])[:4]
        g = smt.gm(1 + ch[w] for w in ok) - 1 if ok else 0.0
        out["lone"][n] = {"dead": d, "change": ch, "geomean_change": g}
        print(f"| {n} | {', '.join(d) or 'none'} | {g:+.1%} over {len(ok)} | " +
              ", ".join(f"{w} {c:+.1%}" for w, c in worst) + " |")
    for lat in (30, 120):
        same = {**alone(M7, lat), **alone(M7, lat, "extra"),
                **{w: ipc1(run7(PRESET, {**single(M7), "dram_lat": lat}, w)) for w in RESTORE}}
        print(f"\n**Pairs at {lat} cycles** (weighted speedup against one thread on today's lists; † deadlock)\n")
        print("| Pair | " + " | ".join(PRF) + " |\n|---|" + "---|" * len(PRF))
        rows = {n: {} for n in PRF}
        for n in PRF:
            for g, a, b in FP_PAIRS + RESTORE_PAIRS:
                r = next(res)
                ip = ipc2(r)
                rows[n][smt.pname(a, b)] = ("deadlock" if dead(r) else r.get("error", "")[:60]) if ip is None else \
                    (ip[0] / same[a] + ip[1] / same[b] if same.get(a) and same.get(b) else None)
        out["pairs"][lat] = rows
        for g, a, b in FP_PAIRS + RESTORE_PAIRS:
            p = smt.pname(a, b)
            cell = lambda v: "†" if v == "deadlock" else (f"{v:.3f}" if isinstance(v, float) else (v or "–"))
            print(f"| {p} | " + " | ".join(cell(rows[n][p]) for n in PRF) + " |")
    return out


LONE = {"merged (today's core)": {},
        "static halves, caps": {"lone_sleep": 1, "lone_merge": -1},
        "static halves, no caps": {"lone_sleep": 1, "lone_merge": -1, "lone_caps": 0},
        "merged, caps never lifted": {"lone_caps": 2},
        "merged, 50% caps never lifted": {"lone_caps": 2, "smt_iq_cap": 50},
        "static halves, 50% caps": {"lone_sleep": 1, "lone_merge": -1, "smt_iq_cap": 50},
        "WFI timeout 4,096; awake 200; merge 64": {"lone_sleep": 4096, "lone_awake": 200, "lone_merge": 64},
        "... drain to the half": {"lone_sleep": 4096, "lone_awake": 200, "lone_merge": 64, "lone_split": 1},
        "... merge 1,024": {"lone_sleep": 4096, "lone_awake": 200, "lone_merge": 1024},
        "tick 100K (1 ms); awake 10K; merge 64": {"lone_sleep": 100000, "lone_awake": 10000, "lone_merge": 64},
        "tick 400K (HZ 250); awake 10K; merge 64": {"lone_sleep": 400000, "lone_awake": 10000, "lone_merge": 64}}


def lone(workers):
    """D2: one thread whose sibling sleeps in WFI: the merged window, static halves, and the merge and split at a
    wake schedule (the sibling itself not simulated: its wakes split the window). The suite at 30, 120, 250."""
    suite = [w["name"] for w in tgrun.manifest(ISA)]
    groups = {"CoreMark, Dhrystone": [w for w in suite if w.startswith(("coremark", "dhrystone"))],
              "Embench": [w for w in suite if w.startswith("embench")],
              "memsuite": [w for w in suite if w.startswith("ms_")]}
    jobs = [(PRESET, {**single(M7), **v, "dram_lat": lat}, w, None) for lat in LATS for v in LONE.values()
            for w in suite]
    res = iter(run_all(jobs, workers))
    out = {}
    for lat in LATS:
        rs = {n: {w: next(res) for w in suite} for n in LONE}
        base = {w: ipc1(r) for w, r in rs["merged (today's core)"].items()}
        print(f"\n**A lone thread at {lat} cycles** (IPC against the merged window; the drain at each split)\n")
        print("| Configuration | All | " + " | ".join(groups) + " | Splits a 1M cycles | Drain: mean / max cycles | "
              "Cycles in halves |\n|---|---|" + "---|" * (len(groups) + 3))
        out[lat] = {}
        for n, r in rs.items():
            ch = {w: ipc1(x) / base[w] - 1 for w, x in r.items() if ipc1(x) and base.get(w)}
            gm = lambda ws: smt.gm(1 + ch[w] for w in ws if w in ch) - 1
            lo = [x.get("lone") for x in r.values() if x.get("lone")]
            cyc = sum(sum(x["cycles"]) for x in lo)
            spl = sum(x["splits"] for x in lo)
            dsum = sum(x["drain_sum"] for x in lo)
            dmax = max([x["drain_max"] for x in lo], default=0)
            half = sum(x["cycles"][2] + x["cycles"][3] for x in lo)
            out[lat][n] = {"all": gm(ch), **{g: gm(ws) for g, ws in groups.items()}, "splits": spl,
                           "drain_mean": dsum / spl if spl else 0, "drain_max": dmax,
                           "half_share": half / cyc if cyc else 0, "dead": [w for w, x in r.items() if dead(x)]}
            e = out[lat][n]
            print(f"| {n} | {e['all']:+.2%} | " + " | ".join(f"{e[g]:+.2%}" for g in groups) +
                  (f" | {spl * 1e6 / cyc:.0f} | {e['drain_mean']:.0f} / {dmax} | {e['half_share']:.1%} |" if cyc
                   else " | – | – | – |"))
    return out


GROUP_CFGS = {"the plan (75% caps)": M7,
              "75% caps, never a whole bank": {**M7, "smt_iq_cap_bank": 2},
              "50% caps, last row kept on demand": {**M7, "smt_iq_cap": 50, "smt_iq_cap_bank": 3}}


def evaluate7(sets, lat, same, pairs=None):
    """As evaluate, from run7's cache (errors kept): a deadlocked pair is listed and left out of the means."""
    pairs = pairs or smt.PAIRS
    rs = run_all([(PRESET, {**sets, "dram_lat": lat}, a, b) for _, a, b in pairs], 16)
    per, dl = {}, []
    for (g, a, b), r in zip(pairs, rs):
        ip = ipc2(r)
        if ip is None:
            dl.append(smt.pname(a, b))
            continue
        per[smt.pname(a, b)] = {"group": g, "ipc": ip, "ws": ip[0] / same[a] + ip[1] / same[b]}
    out = {"pairs": per, "dead": dl, "groups": {}}
    for g in GROUPS:
        ms = [m["ws"] for m in per.values() if m["group"] == g]
        if ms:
            out["groups"][g] = {"ws": smt.gm(ms)}
    out["ws"] = smt.gm(e["ws"] for e in out["groups"].values())
    return out


def groups(workers):
    """Decode, rename and commit groups: mixed (a thread fills the slots its sibling leaves; smt_mix 1, M7's base)
    against one thread a group (smt_mix 0: each cycle's group from one thread, the first-served thread alternating,
    an idle thread skipped), for the plan's caps and §13's two bank rules; and §13.4's deadlock search with one
    thread a group."""
    run_all([(PRESET, {**c, "smt_mix": 0, "dram_lat": lat}, a, b) for c in GROUP_CFGS.values() for lat in LATS
             for _, a, b in smt.PAIRS + WS_PAIRS], workers)
    out = {}
    print("\n**Mixed groups against one thread a group** (WS over the 42 pairs against one program on the merged "
          "window; 30 / 120 / 250 cycles)\n")
    print("| Configuration | Mixed | One thread a group | Change | memory + memory, one a group | compute + "
          "compute | mixed pairs | Deadlocks (58 pairs), one a group |\n|---|---|---|---|---|---|---|---|")
    for n, c in GROUP_CFGS.items():
        out[n] = {}
        cells = {"mix": [], "one": [], "ch": [], "g": {g: [] for g in GROUPS}, "dead": []}
        for lat in LATS:
            same = alone(M7, lat)
            mx = evaluate(c, lat, ref=same)
            one = evaluate7({**c, "smt_mix": 0}, lat, same)
            dl = [smt.pname(a, b) for _, a, b in smt.PAIRS + WS_PAIRS
                  if dead(run7(PRESET, {**c, "smt_mix": 0, "dram_lat": lat}, a, b))]
            out[n][lat] = {"mixed": mx["ws"], "one": one["ws"], "one_groups": one["groups"], "dead_42": one["dead"],
                           "dead_58": dl, "pairs_one": {p: m["ws"] for p, m in one["pairs"].items()}}
            cells["mix"].append(f"{mx['ws']:.3f}")
            cells["one"].append(f"{one['ws']:.3f}")
            cells["ch"].append(f"{one['ws'] / mx['ws'] - 1:+.1%}")
            for g in GROUPS:
                cells["g"][g].append(f"{one['groups'][g]['ws']:.3f}" if g in one["groups"] else "–")
            cells["dead"].append(str(len(dl)))
        print(f"| {n} | " + " | ".join(" / ".join(cells[k]) for k in ("mix", "one", "ch")) + " | " +
              " | ".join(" / ".join(cells["g"][g]) for g in GROUPS) + " | " + " / ".join(cells["dead"]) + " |")
    return out


BASE7 = {**M7, "smt_iq_cap_bank": 2}   # §13's recommended M7: 75% caps, a hart never taking all of a slot bank
D3REV = {"shared lists, no walk": {"prf_fp_bank": 96},
         "shared lists, walk the half": {"prf_fp_bank": 96, "flush_walk": 1},
         "shared lists, walk the flushed entries": {"prf_fp_bank": 96, "flush_walk": 2},
         "per-hart lists, donor keeps 1, FP 96": {"prf_split": 1, "prf_xfer": 1, "prf_fp_bank": 96},
         "per-hart lists, donor keeps its own + 1, FP 96": {"prf_split": 1, "prf_xfer": 2, "prf_fp_bank": 96},
         "per-hart lists, donor keeps 1, FP 128": {"prf_split": 1, "prf_xfer": 1, "prf_fp_bank": 128},
         "per-hart lists, donor keeps its own + 1, FP 128": {"prf_split": 1, "prf_xfer": 2, "prf_fp_bank": 128}}
D3REV_64 = {"per-hart lists, donor keeps 1, FP 64": {"prf_split": 1, "prf_xfer": 1},
            "shared lists, FP 64 (today)": {}}


def d3rev(workers):
    """D3 as revised (core-2, the coordinator): per-hart free lists that take committed-free registers from the
    sibling's list when short (prf_xfer), FP banks of 96 or 128, against shared lists whose flush walks the thread's
    half 2 entries a cycle (flush_walk). On §13's recommended M7: weighted throughput over the 42 pairs, deadlocks over
    the 42, the working-set, FP and FP-restore pairs, a lone hart over the suite, and transfers a kilo-instruction."""
    extra_pairs = WS_PAIRS + FP_PAIRS + RESTORE_PAIRS
    suite = [w["name"] for w in tgrun.manifest(ISA)] + ["tk_dgemm"] + RESTORE
    jobs = [(PRESET, {**BASE7, **v, "dram_lat": lat}, a, b) for v in D3REV.values() for lat in LATS
            for _, a, b in smt.PAIRS + extra_pairs]
    jobs += [(PRESET, {**BASE7, **v, "dram_lat": 30}, a, b) for v in D3REV_64.values() for _, a, b in extra_pairs]
    jobs += [(PRESET, {**single(BASE7), **v, "dram_lat": lat}, w, None) for v in [{}] + list(D3REV.values())[3:]
             for lat in LATS for w in suite]
    run_all(jobs, workers)
    out = {"pairs": {}, "dead": {}, "lone": {}}
    print("\n**Pairs: weighted throughput over the 42 (30 / 120 / 250 cycles) and deadlocks over 87 pairs** "
          "(against one program on today's lists, the merged window)\n")
    print("| Free lists | WS | Change against shared lists without a walk | Deadlocked pairs (30 / 120 / 250) | "
          "Transfers a kilo-instruction |\n|---|---|---|---|---|")
    base_ws = {}
    for n, v in D3REV.items():
        row = {"ws": [], "dead": [], "xpki": []}
        for lat in LATS:
            same = alone(BASE7, lat)
            e = evaluate7({**BASE7, **v}, lat, same)
            dl = [smt.pname(a, b) for _, a, b in smt.PAIRS + extra_pairs
                  if dead(run7(PRESET, {**BASE7, **v, "dram_lat": lat}, a, b))]
            xs = [run7(PRESET, {**BASE7, **v, "dram_lat": lat}, a, b) for _, a, b in smt.PAIRS]
            xf = sum(t["region"].get("prf_xfers", 0) for r in xs if not r.get("error") for t in r["threads"])
            ins = sum(t["region"]["instr"] for r in xs if not r.get("error") for t in r["threads"])
            row["ws"].append(e["ws"])
            row["dead"].append(dl)
            row["xpki"].append(xf * 1000.0 / max(1, ins))
            if n == "shared lists, no walk":
                base_ws[lat] = e["ws"]
        out["pairs"][n] = row
        print(f"| {n} | " + " / ".join(f"{x:.3f}" for x in row["ws"]) + " | " +
              " / ".join(f"{x / base_ws[lat] - 1:+.1%}" for x, lat in zip(row["ws"], LATS)) + " | " +
              " / ".join(str(len(d)) for d in row["dead"]) + " | " + " / ".join(f"{x:.2f}" for x in row["xpki"]) +
              " |")
    for n, v in D3REV.items():
        for lat, dl in zip(LATS, out["pairs"][n]["dead"]):
            if dl:
                print(f"- {n}, {lat} cycles: {', '.join(dl)}")
    for n, v in D3REV_64.items():
        dl = [smt.pname(a, b) for _, a, b in extra_pairs if dead(run7(PRESET, {**BASE7, **v, "dram_lat": 30}, a, b))]
        out["dead"][n] = dl
        print(f"- {n}, 30 cycles, the {len(extra_pairs)} other pairs: {', '.join(dl) or 'none'} deadlocked")
    print("\n**A lone hart** (its sibling asleep, its spares taken by transfers; IPC against today's shared lists; "
          "30 / 120 / 250 cycles)\n")
    print("| Free lists | Suite | Largest losses at 120 | Deadlocks | Transfers a kilo-instruction |\n"
          "|---|---|---|---|---|")
    for n, v in list(D3REV.items())[3:]:
        row = {"geo": [], "dead": set(), "xpki": [], "worst": []}
        for lat in LATS:
            b = {w: ipc1(run7(PRESET, {**single(BASE7), "dram_lat": lat}, w, None)) for w in suite}
            rs = {w: run7(PRESET, {**single(BASE7), **v, "dram_lat": lat}, w, None) for w in suite}
            ch = {w: ipc1(r) / b[w] - 1 for w, r in rs.items() if ipc1(r) and b.get(w)}
            row["geo"].append(smt.gm(1 + c for c in ch.values()) - 1)
            row["dead"] |= {w for w, r in rs.items() if dead(r)}
            xf = sum(r["region"].get("prf_xfers", 0) for r in rs.values() if not r.get("error"))
            ins = sum(r["region"]["instr"] for r in rs.values() if not r.get("error"))
            row["xpki"].append(xf * 1000.0 / max(1, ins))
            if lat == 120:
                row["worst"] = sorted(ch.items(), key=lambda kv: kv[1])[:3]
        out["lone"][n] = {**row, "dead": sorted(row["dead"])}
        print(f"| {n} | " + " / ".join(f"{g:+.2%}" for g in row["geo"]) + " | " +
              ", ".join(f"{w} {c:+.1%}" for w, c in row["worst"]) + " | " + (", ".join(sorted(row["dead"])) or "none") +
              " | " + " / ".join(f"{x:.2f}" for x in row["xpki"]) + " |")
    return out


PRED = {"75% caps (the plan)": ("exit2", None),
        "75% caps, never a whole bank": ("policy", "75% caps, never a whole bank"),
        "50% caps, the last row kept": ("policy", "50% caps, last row kept on demand"),
        "50% caps, never a whole bank": ("policy", "50% caps, never a whole bank"),
        "75% caps per bank": ("policy", "75% caps per bank"),
        "50% caps (whole queue)": ("policy", "issue-queue cap 50%")}


def prediction(workers):
    """Exit 2's blind prediction, from --exit2's and --policy's results: weighted throughput at 30, 120 and 250 cycles
    against the same core running one program on the merged window (D2), for the plan's 75% issue-queue caps and the
    caps per slot bank that D8 needs; and, for the plan's, against one program on static halves (D2 not yet built)."""
    res = json.loads(OUT.read_text())
    ev = {n: {lat: (res[s][str(lat)] if k is None else res[s][str(lat)][k]) for lat in LATS}
          for n, (s, k) in PRED.items()}
    progs = sorted({p for _, a, b in smt.PAIRS for p in (a, b)})
    jobs = [(PRESET, {**single(M7), **LONE["static halves, caps"], "dram_lat": lat}, w, None)
            for lat in LATS for w in progs]
    rs = iter(run_all(jobs, workers))
    halves = {lat: {w: ipc1(next(rs)) for w in progs} for lat in LATS}
    plan = ev["75% caps (the plan)"]
    wsh = {lat: {smt.pname(a, b): plan[lat]["pairs"][smt.pname(a, b)]["ipc"][0] / halves[lat][a] +
                 plan[lat]["pairs"][smt.pname(a, b)]["ipc"][1] / halves[lat][b] for _, a, b in smt.PAIRS}
           for lat in LATS}
    hg = {lat: {g: smt.gm(wsh[lat][smt.pname(a, b)] for gg, a, b in smt.PAIRS if gg == g) for g in GROUPS}
          for lat in LATS}
    for lat in LATS:
        hg[lat]["all"] = smt.gm(hg[lat][g] for g in GROUPS)
    print("\n**Exit 2: weighted throughput** (geometric means; 30 / 120 / 250 cycles; against one program on the "
          "merged window)\n")
    print("| Configuration | All pairs | memory + memory | compute + compute | mixed | Lowest pair |\n"
          "|---|---|---|---|---|---|")
    for n, e in ev.items():
        f = lambda g: " / ".join(f"{(e[lat]['ws'] if g == 'all' else e[lat]['groups'][g]['ws']):.3f}" for lat in LATS)
        print(f"| {n} | {f('all')} | " + " | ".join(f(g) for g in GROUPS) + " | " +
              " / ".join(f"{e[lat]['min_ws']:.3f}" for lat in LATS) + " |")
    print("| 75% caps (the plan), against static halves | " + " | ".join(
        " / ".join(f"{hg[lat][g]:.3f}" for lat in LATS) for g in ("all",) + GROUPS) + " | – |")
    print("\n**Per pair** (30 / 120 / 250 cycles)\n")
    print("| Pair | Group | " + " | ".join(PRED) + " |\n|---|---|" + "---|" * len(PRED))
    for g, a, b in smt.PAIRS:
        p = smt.pname(a, b)
        print(f"| {p} | {g} | " + " | ".join(" / ".join(f"{e[lat]['pairs'][p]['ws']:.2f}" for lat in LATS)
                                           for e in ev.values()) + " |")
    return {"halves_ws": hg, "configs": list(PRED)}


PAIRDIR = Path(os.environ.get("TG_PAIRDIR", str(Path.home() / "tanager-build" / "track-verif-79d5d8" / "pair")))
RUNNER = {"smt_align": 1, "smt_pa_flat": 1, "stop_regions": 1}   # the runner's barrier, addresses and finish
D3R = {"prf_split": 1, "prf_xfer": 1, "prf_fp_bank": 96}   # D3 as revised (DR-175, amended 10-20)
STEP5 = {**M7, "smt_iq_cap": 100, "smt_mix": 0, "drain_guard": 0, **D3R}   # core-2's step 5: the caps come at step 7
PAIR_CFGS = {"step 5 as planned (no caps; D8 alternation only)": STEP5,
             "step 5 + the drain's priority for a miss entry": {**STEP5, "drain_guard": 1},
             "step 7 as planned (75% caps)": {**STEP5, "smt_iq_cap": 75},
             "step 7: 75% caps + the drain's priority": {**STEP5, "smt_iq_cap": 75, "drain_guard": 1},
             "step 7 recommended (75% caps never a whole bank, the drain's priority)":
                 {**STEP5, "smt_iq_cap": 75, "smt_iq_cap_bank": 2, "drain_guard": 1},
             "step 7: 50% caps, a bank's last row kept while the sibling waits, the drain's priority":
                 {**STEP5, "smt_iq_cap": 50, "smt_iq_cap_bank": 3, "drain_guard": 1}}
PAIR_CHECKS = {"step 5 + the drain's priority, thread 1 in its own address space (§13.2's method)":
                   {**STEP5, "drain_guard": 1, "smt_pa_flat": 0}}
ALONE = {**CORE, "stop_regions": 1}   # a runner program alone ends at its region's end, as the runner's alone run
ALONE_CFGS = {"today's core": ALONE, "with the drain's priority": {**ALONE, "drain_guard": 1}}
METHOD_CFGS = ["step 5 + the drain's priority for a miss entry",
               "step 7 recommended (75% caps never a whole bank, the drain's priority)",
               "step 7: 50% caps, a bank's last row kept while the sibling waits, the drain's priority"]


def repeat_mask(a, b):
    """smt_restart_ff for a pair whose memory kernels repeat their region instead of restarting with their set-up."""
    m = (a in smt.MEM) + 2 * (b in smt.MEM)
    return {"smt_restart_ff": m} if m else {}


def pair_workloads(d=None):
    """verif-2's programs (build_pair.sh), each linked at slot 0 (0x8010_0000) and slot 1 (0x8810_0000): no
    fast-forward (the RTL runs the set-up), stdin built in; each also as `<name>.ff`, fast-forwarded to its region
    and restarted straight into it (§13.2's method)."""
    names = []
    for p in smt.MEM + smt.COMP:
        for s in (0, 1):
            f = (d or PAIRDIR) / "prog" / f"{p}.s{s}.elf"
            smt.WS[f"{p}.s{s}"] = {"name": f"{p}.s{s}", "elf": str(f), "stdin": "", "ff": 0,
                                   "hash": hashlib.sha1(f.read_bytes()).hexdigest()[:16]}
            names.append(f"{p}.s{s}")
            smt.WS[f"{p}.s{s}.ff"] = {**smt.WS[f"{p}.s{s}"], "name": f"{p}.s{s}.ff", "ff": 1}
    return names


def pairrun(workers):
    """Exit 2 blind, on verif-2's pair runner (tests/bench/pair): its programs as built, the pair's first at slot 0 on
    thread 0 and its second at slot 1 on thread 1; set-up timed; the two first regions start together (the runner's
    barrier, smt_align); one physical address space (smt_pa_flat); a program that ends runs again from the top. Against
    each program alone on today's core (one thread on the whole smt2 window), as verif-2's RTL alone runs. M7 as
    core-2's step 5 builds it (no issue-queue caps), and step 7's caps."""
    names = pair_workloads()
    cfgs = {**PAIR_CFGS, **PAIR_CHECKS}
    jobs = [(PRESET, {**RUNNER, **c, "dram_lat": lat}, f"{a}.s0", f"{b}.s1") for c in cfgs.values()
            for lat in LATS for _, a, b in smt.PAIRS]
    jobs += [(PRESET, {**c, "dram_lat": lat}, w, None) for c in ALONE_CFGS.values() for lat in LATS for w in names]
    jobs += [(PRESET, {**c, "dram_lat": lat}, a, b) for c in PAIR_CFGS.values() for lat in LATS
             for _, a, b in WS_PAIRS]   # §13.4's working-set pairs (the model's own builds): deadlocks only
    jobs += [(PRESET, {**PAIR_CFGS[n], "smt_pa_flat": 1, "stop_regions": 1, "dram_lat": lat}, f"{a}.s0.ff",
              f"{b}.s1.ff") for n in METHOD_CFGS for lat in LATS for _, a, b in smt.PAIRS]   # §13.2's method
    jobs += [(PRESET, {**ALONE, "dram_lat": lat}, f"{w}.ff", None) for lat in LATS for w in names]
    jobs += [(PRESET, {**RUNNER, **PAIR_CFGS[n], **repeat_mask(a, b), "dram_lat": lat}, f"{a}.s0", f"{b}.s1")
             for n in METHOD_CFGS for lat in LATS for _, a, b in smt.PAIRS]   # the memory kernels repeating
    run_all(jobs, workers)
    out = {"alone": {}, "configs": {}, "ws_dead": {}}
    for n, c in ALONE_CFGS.items():
        out["alone"][n] = {}
        for lat in LATS:
            rs = {w: run7(PRESET, {**c, "dram_lat": lat}, w, None) for w in names}
            out["alone"][n][lat] = {w: {"ipc": ipc1(r), "instr": r.get("region", {}).get("instr"),
                                        "cycles": r.get("region", {}).get("cycles"), "error": r.get("error", "")}
                                    for w, r in rs.items()}
    same = {lat: {w: e["ipc"] for w, e in out["alone"]["today's core"][lat].items()} for lat in LATS}

    def ev(c):
        e = {}
        for lat in LATS:
            per, dl = {}, []
            for g, a, b in smt.PAIRS:
                r = run7(PRESET, {**RUNNER, **c, "dram_lat": lat}, f"{a}.s0", f"{b}.s1")
                ip = ipc2(r)
                if ip is None:
                    dl.append(smt.pname(a, b))
                    continue
                sp = [ip[0] / same[lat][f"{a}.s0"], ip[1] / same[lat][f"{b}.s1"]]
                per[smt.pname(a, b)] = {"group": g, "ipc": ip, "speedup": sp, "ws": sum(sp),
                                        "cycles": [t["region"]["cycles"] for t in r["threads"]],
                                        "instr": [t["region"]["instr"] for t in r["threads"]],
                                        "laps": [t["laps"] for t in r["threads"]]}
            gs = {g: smt.gm(m["ws"] for m in per.values() if m["group"] == g) for g in GROUPS}
            e[lat] = {"ws": smt.gm(gs.values()), "groups": gs, "min_ws": min(m["ws"] for m in per.values()),
                      "dead": dl, "pairs": per}
        return e

    print("\n**Exit 2 on verif-2's pair runner, blind** (WS over the 42 pairs against each program alone on today's "
          "core; geometric means over the pairs that run; 30 / 120 / 250 cycles)\n")
    print("| Configuration | All pairs | memory + memory | compute + compute | mixed | Lowest pair | Deadlocked "
          "pairs of 42 | Deadlocks, §13.4's 16 working-set pairs |\n|---|---|---|---|---|---|---|---|")
    for n, c in cfgs.items():
        e = ev(c)
        out["configs"][n] = e
        wsd = None
        if n in PAIR_CFGS:
            wsd = [[smt.pname(a, b) for _, a, b in WS_PAIRS if dead(run7(PRESET, {**c, "dram_lat": lat}, a, b))]
                   for lat in LATS]
            out["ws_dead"][n] = wsd
        f = lambda v: " / ".join(f"{v(lat):.3f}" for lat in LATS)
        print(f"| {n} | **{f(lambda lat: e[lat]['ws'])}** | " +
              " | ".join(f(lambda lat, g=g: e[lat]["groups"][g]) for g in GROUPS) +
              f" | {f(lambda lat: e[lat]['min_ws'])} | " + " / ".join(str(len(e[lat]["dead"])) for lat in LATS) +
              " | " + (" / ".join(str(len(d)) for d in wsd) if wsd else "–") + " |")
    for n, e in out["configs"].items():
        for lat in LATS:
            if e[lat]["dead"]:
                print(f"- {n}, {lat} cycles: {', '.join(e[lat]['dead'])} deadlocked")
    for n, wsd in out["ws_dead"].items():
        for lat, d in zip(LATS, wsd):
            if d:
                print(f"- {n}, {lat} cycles, working-set pairs: {', '.join(d)} deadlocked")
    print("\n**The method** (the same programs and configurations; WS by group, 30 / 120 / 250 cycles): the runner's; "
          "the runner's with the memory kernels repeating their region rather than restarting with their set-up; "
          "§13.2's (each program fast-forwarded to its region, cold, and restarted straight into it; alone the same "
          "way)\n")
    print("| Configuration | Method | All pairs | memory + memory | compute + compute | mixed |\n"
          "|---|---|---|---|---|---|")
    ff_same = {lat: {w: ipc1(run7(PRESET, {**ALONE, "dram_lat": lat}, f"{w}.ff", None)) for w in names} for lat in LATS}

    def evm(sets_of, wl, base):
        e = {}
        for lat in LATS:
            per = {}
            for g, a, b in smt.PAIRS:
                ip = ipc2(run7(PRESET, {**sets_of(a, b), "dram_lat": lat}, *wl(a, b)))
                if ip is not None:
                    per[smt.pname(a, b)] = {"group": g,
                                            "ws": ip[0] / base[lat][f"{a}.s0"] + ip[1] / base[lat][f"{b}.s1"]}
            gs = {g: smt.gm(m["ws"] for m in per.values() if m["group"] == g) for g in GROUPS}
            e[lat] = {"ws": smt.gm(gs.values()), "groups": gs, "pairs": {p: m["ws"] for p, m in per.items()},
                      "n": len(per)}
        return e

    out["method"] = {}
    for n in METHOD_CFGS:
        c = PAIR_CFGS[n]
        e13 = evm(lambda a, b: {**c, "smt_pa_flat": 1, "stop_regions": 1}, lambda a, b: (f"{a}.s0.ff", f"{b}.s1.ff"),
                  ff_same)
        erp = evm(lambda a, b: {**RUNNER, **c, **repeat_mask(a, b)}, lambda a, b: (f"{a}.s0", f"{b}.s1"), same)
        out["method"][n] = {"repeat": erp, "s13_2": e13}
        for meth, ee in (("the runner's", out["configs"][n]), ("the runner's, memory kernels repeating", erp),
                         ("§13.2's", e13)):
            f = lambda v: " / ".join(f"{v(lat):.3f}" for lat in LATS)
            print(f"| {n} | {meth} | {f(lambda lat: ee[lat]['ws'])} | " +
                  " | ".join(f(lambda lat, g=g: ee[lat]["groups"][g]) for g in GROUPS) + " |")
    ref = "step 5 + the drain's priority for a miss entry"
    print("\n**Per pair** (WS, 30 / 120 / 250 cycles; then each thread's share of its alone IPC at 120)\n")
    print("| Pair | Group | " + " | ".join(PAIR_CFGS) + f" | Shares at 120, {ref} |\n|---|---|" +
          "---|" * (len(PAIR_CFGS) + 1))
    for g, a, b in smt.PAIRS:
        p = smt.pname(a, b)
        cell = lambda e, lat: f"{e[lat]['pairs'][p]['ws']:.2f}" if p in e[lat]["pairs"] else "dead"
        s5 = out["configs"][ref][120]["pairs"].get(p)
        print(f"| {p} | {g} | " + " | ".join(" / ".join(cell(out["configs"][n], lat) for lat in LATS)
                                           for n in PAIR_CFGS) +
              " | " + (" + ".join(f"{x:.2f}" for x in s5["speedup"]) if s5 else "dead") + " |")
    print("\n**Alone** (IPC over the first region on today's core, slot 0 / slot 1; 30 / 120 / 250 cycles; the "
          "drain's priority's change at 120)\n")
    print("| Program | 30 | 120 | 250 | Region instructions | The drain's priority, 120 |\n|---|---|---|---|---|---|")
    for p in smt.MEM + smt.COMP:
        a0 = out["alone"]["today's core"]
        cells = [" / ".join(f"{a0[lat][f'{p}.s{s}']['ipc']:.3f}" for s in (0, 1)) for lat in LATS]
        g1 = out["alone"]["with the drain's priority"][120][f"{p}.s0"]["ipc"]
        print(f"| {p} | " + " | ".join(cells) + f" | {a0[120][f'{p}.s0']['instr']:,} | "
              f"{g1 / a0[120][f'{p}.s0']['ipc'] - 1:+.2%} |")
    return out


RTL_ALONE = Path(os.environ.get("TG_RTL_ALONE", str(PAIRDIR / "ws-alone-rtl-1020.json")))   # on the same ELFs
CALIB = {"rtl_m2 revision 7": {},
         "the RTL's ownership prefetch (an entry while another stays free)": {"rfo_pf_reserve": 1},
         "the same, at most 3 in flight (STORE_PF_MAX)": {"rfo_pf_reserve": 1, "rfo_pf_max": 3}}


def calib(workers):
    """The pair runner's programs alone, against verif-2's RTL alone runs (TG_RTL_ALONE, run on TG_PAIRDIR's ELFs):
    IPC over the first region at 30, 120 and 250 cycles, for revision 7's ownership prefetch (an L1D miss entry only
    while 2 others stay free) and the RTL's (DR-171: while 1 stays free, at most 3 in flight)."""
    names = pair_workloads()
    progs = [w[:-3] for w in names if w.endswith(".s0")]
    run_all([(PRESET, {**ALONE, **v, "dram_lat": lat}, f"{p}.s0", None) for v in CALIB.values() for lat in LATS
             for p in progs], workers)
    rtl = json.loads(RTL_ALONE.read_text())["alone"]
    out = {}
    print("\n**Alone against the RTL** (model IPC / RTL IPC − 1 over the first region; 30 / 120 / 250 cycles)\n")
    print("| Program | RTL IPC | " + " | ".join(CALIB) + " |\n|---|---|" + "---|" * len(CALIB))
    for p in progs:
        out[p] = {n: [ipc1(run7(PRESET, {**ALONE, **v, "dram_lat": lat}, f"{p}.s0", None)) /
                      rtl[f"{p}@s0@{lat}"]["ipc"] - 1 for lat in LATS] for n, v in CALIB.items()}
        print(f"| {p} | " + " / ".join(f"{rtl[f'{p}@s0@{lat}']['ipc']:.3f}" for lat in LATS) + " | " +
              " | ".join(" / ".join(f"{x:+.1%}" for x in out[p][n]) for n in CALIB) + " |")
    return out


FINALDIR = Path(os.environ.get("TG_FINALDIR", str(Path.home() / "tanager-build" / "track-verif-79d5d8" /
                                                   "pair-final-b7db3e16")))
REV8 = {"rfo_pf_reserve": 1}   # rtl_m2 revision 8: the ownership prefetch as the RTL's (DR-171; section 13.10)
FINAL_REF = "step 5 + the drain's priority for a miss entry"   # run on revision 7 as well
FINAL_BEST = "step 7: 50% caps, a bank's last row kept while the sibling waits, the drain's priority"
FINAL_LEVERS = {"+ a hart at most 3 of the 4 L1D miss entries": {"smt_mshr_cap": 75},
                "+ a hart at most 75% of the long-latency tags": {"smt_llt_cap": 75},
                "+ both": {"smt_mshr_cap": 75, "smt_llt_cap": 75}}   # step 7's tuning, on the best


def final(workers):
    """Exit 2's blind prediction on verif-2's final pair set (TG_FINALDIR, checked against its manifest; the memory
    kernels built with REPEAT=1), the ELFs step 5's pairs and alone runs use, on rtl_m2 revision 8. As --pair
    otherwise: the runner's barrier, addresses and finish; WS against each program alone on today's core (revision 8
    too); hangs over the 42 and §13.4's 16 working-set pairs; one configuration on revision 7 as well."""
    names = pair_workloads(FINALDIR)
    cfgs = {n: {**c, **REV8} for n, c in PAIR_CFGS.items()}
    cfgs.update({f"50% caps, last row kept, priority {n}": {**PAIR_CFGS[FINAL_BEST], **REV8, **v}
                 for n, v in FINAL_LEVERS.items()})
    ref7 = f"{FINAL_REF}, revision 7"
    alone8 = {**ALONE, **REV8}
    jobs = [(PRESET, {**RUNNER, **c, "dram_lat": lat}, f"{a}.s0", f"{b}.s1") for c in cfgs.values() for lat in LATS
            for _, a, b in smt.PAIRS]
    jobs += [(PRESET, {**RUNNER, **PAIR_CFGS[FINAL_REF], "dram_lat": lat}, f"{a}.s0", f"{b}.s1") for lat in LATS
             for _, a, b in smt.PAIRS]
    jobs += [(PRESET, {**c, "dram_lat": lat}, w, None) for c in (alone8, ALONE) for lat in LATS for w in names]
    jobs += [(PRESET, {**c, "dram_lat": lat}, a, b) for c in cfgs.values() for lat in LATS for _, a, b in WS_PAIRS]
    run_all(jobs, workers)
    al = {k: {lat: {w: run7(PRESET, {**c, "dram_lat": lat}, w, None) for w in names} for lat in LATS}
          for k, c in (("rev8", alone8), ("rev7", ALONE))}
    out = {"dir": str(FINALDIR), "alone": {k: {lat: {w: {"ipc": ipc1(r), "instr": r["region"]["instr"],
                                                         "cycles": r["region"]["cycles"]} for w, r in v[lat].items()}
                                                for lat in LATS} for k, v in al.items()}, "configs": {}, "ws_dead": {}}

    def ev(c, base):
        e = {}
        for lat in LATS:
            per, dl = {}, []
            for g, a, b in smt.PAIRS:
                r = run7(PRESET, {**RUNNER, **c, "dram_lat": lat}, f"{a}.s0", f"{b}.s1")
                ip = ipc2(r)
                if ip is None:
                    dl.append(smt.pname(a, b))
                    continue
                sp = [ip[0] / ipc1(base[lat][f"{a}.s0"]), ip[1] / ipc1(base[lat][f"{b}.s1"])]
                per[smt.pname(a, b)] = {"group": g, "ipc": ip, "speedup": sp, "ws": sum(sp),
                                        "cycles": [t["region"]["cycles"] for t in r["threads"]],
                                        "laps": [t["laps"] for t in r["threads"]]}
            gs = {g: smt.gm(m["ws"] for m in per.values() if m["group"] == g) for g in GROUPS}
            e[lat] = {"ws": smt.gm(gs.values()), "groups": gs, "min_ws": min(m["ws"] for m in per.values()),
                      "dead": dl, "pairs": per}
        return e

    print(f"\n**Exit 2 on the final pair set, blind** ({FINALDIR.name}; rtl_m2 revision 8; WS over the 42 pairs "
          "against each program alone on today's core; geometric means over the pairs that run; 30 / 120 / 250 "
          "cycles)\n")
    print("| Configuration | All pairs | memory + memory | compute + compute | mixed | Lowest pair | Hung, of the 42 | "
          "Hung, of the 16 working-set pairs |\n|---|---|---|---|---|---|---|---|")
    rows = [(n, c, al["rev8"]) for n, c in cfgs.items()] + [(ref7, PAIR_CFGS[FINAL_REF], al["rev7"])]
    for n, c, base in rows:
        e = ev(c, base)
        out["configs"][n] = e
        wsd = None
        if n in cfgs:
            wsd = [[smt.pname(a, b) for _, a, b in WS_PAIRS if dead(run7(PRESET, {**c, "dram_lat": lat}, a, b))]
                   for lat in LATS]
            out["ws_dead"][n] = wsd
        f = lambda v: " / ".join(f"{v(lat):.3f}" for lat in LATS)
        print(f"| {n} | **{f(lambda lat: e[lat]['ws'])}** | " +
              " | ".join(f(lambda lat, g=g: e[lat]["groups"][g]) for g in GROUPS) +
              f" | {f(lambda lat: e[lat]['min_ws'])} | " + " / ".join(str(len(e[lat]["dead"])) for lat in LATS) +
              " | " + (" / ".join(str(len(d)) for d in wsd) if wsd else "–") + " |")
    for n, e in out["configs"].items():
        for lat in LATS:
            if e[lat]["dead"]:
                print(f"- {n}, {lat} cycles: {', '.join(e[lat]['dead'])} hung")
    for n, wsd in out["ws_dead"].items():
        for lat, d in zip(LATS, wsd):
            if d:
                print(f"- {n}, {lat} cycles, working-set pairs: {', '.join(d)} hung")
    ref = FINAL_REF
    print("\n**Per pair** (WS, 30 / 120 / 250 cycles; then each thread's share of its alone IPC at 120)\n")
    print("| Pair | Group | " + " | ".join(cfgs) + f" | {ref7} | Shares at 120, {ref} |\n|---|---|" +
          "---|" * (len(cfgs) + 2))
    for g, a, b in smt.PAIRS:
        p = smt.pname(a, b)
        cell = lambda e, lat: f"{e[lat]['pairs'][p]['ws']:.2f}" if p in e[lat]["pairs"] else "hung"
        s5 = out["configs"][ref][120]["pairs"].get(p)
        print(f"| {p} | {g} | " + " | ".join(" / ".join(cell(out["configs"][n], lat) for lat in LATS)
                                           for n in list(cfgs) + [ref7]) +
              " | " + (" + ".join(f"{x:.2f}" for x in s5["speedup"]) if s5 else "hung") + " |")
    print("\n**Alone** (revision 8; IPC over the first region, slot 0 / slot 1; region instructions; cycles at 30 / "
          "120 / 250; revision 7's IPC change at 120)\n")
    print("| Program | IPC, 30 | 120 | 250 | Instructions | Cycles, 30 / 120 / 250 | Revision 7, 120 |\n"
          "|---|---|---|---|---|---|---|")
    for p in smt.MEM + smt.COMP:
        a8, a7 = al["rev8"], al["rev7"]
        cells = [" / ".join(f"{ipc1(a8[lat][f'{p}.s{s}']):.3f}" for s in (0, 1)) for lat in LATS]
        print(f"| {p} | " + " | ".join(cells) + f" | {a8[120][f'{p}.s0']['region']['instr']:,} | " +
              " / ".join(f"{a8[lat][f'{p}.s0']['region']['cycles']:,}" for lat in LATS) +
              f" | {ipc1(a7[120][f'{p}.s0']) / ipc1(a8[120][f'{p}.s0']) - 1:+.2%} |")
    return out


HOME_BASE = {**BASE7, "smt_mix": 0, **D3R}   # §13.10's step 7: 75% caps never a whole bank, one thread a group, D3
HOMES = {"D4 as planned (hart t's x1-x31 in bank t)": {},
         "(a) every integer home in B0, ALU ops steering around it": {"prf_homes": 1, "prf_steer": 1},
         "(a) every integer home in B0, no steering": {"prf_homes": 1},
         "(b) hart 1's x1-x16 in B1, x17-x31 in B2": {"prf_homes": 2}}
HOMES_PAIRS = ["D4 as planned (hart t's x1-x31 in bank t)", "(a) every integer home in B0, ALU ops steering around it",
               "(b) hart 1's x1-x16 in B1, x17-x31 in B2"]


def homes(workers):
    """D4's alternatives (core-2): where hart 1's integer registers live at reset. A lone hart (its sibling asleep, its
    homes held) over the suite against today's one-hart core, and pairs (the 42's WS, deadlocks over the 87) against
    D4 as planned, on §13.10's step-7 configuration with D3 as revised. FP homes as planned (F1 at 96)."""
    extra = WS_PAIRS + FP_PAIRS + RESTORE_PAIRS
    suite = [w["name"] for w in tgrun.manifest(ISA)] + ["tk_dgemm"] + RESTORE
    jobs = [(PRESET, {**HOME_BASE, **HOMES[n], "dram_lat": lat}, a, b) for n in HOMES_PAIRS for lat in LATS
            for _, a, b in smt.PAIRS + extra]
    jobs += [(PRESET, {**single(HOME_BASE), **v, "dram_lat": lat}, w, None) for v in HOMES.values() for lat in LATS
             for w in suite]
    jobs += [(PRESET, {**single(BASE7), "dram_lat": lat}, w, None) for lat in LATS for w in suite]
    run_all(jobs, workers)
    out = {"lone": {}, "pairs": {}}
    print("\n**A lone hart** (its sibling asleep with its registers at their homes; IPC against today's one-hart core; "
          "30 / 120 / 250 cycles)\n")
    print("| Homes | Suite | Largest losses at 120 | Deadlocks | Transfers a kilo-instruction |\n|---|---|---|---|---|")
    for n, v in HOMES.items():
        row = {"geo": [], "dead": set(), "xpki": [], "worst": []}
        for lat in LATS:
            b = {w: ipc1(run7(PRESET, {**single(BASE7), "dram_lat": lat}, w, None)) for w in suite}
            rs = {w: run7(PRESET, {**single(HOME_BASE), **v, "dram_lat": lat}, w, None) for w in suite}
            ch = {w: ipc1(r) / b[w] - 1 for w, r in rs.items() if ipc1(r) and b.get(w)}
            row["geo"].append(smt.gm(1 + c for c in ch.values()) - 1)
            row["dead"] |= {w for w, r in rs.items() if dead(r)}
            xf = sum(r["region"].get("prf_xfers", 0) for r in rs.values() if not r.get("error"))
            ins = sum(r["region"]["instr"] for r in rs.values() if not r.get("error"))
            row["xpki"].append(xf * 1000.0 / max(1, ins))
            if lat == 120:
                row["worst"] = sorted(ch.items(), key=lambda kv: kv[1])[:3]
                row["all_120"] = ch
        out["lone"][n] = {**row, "dead": sorted(row["dead"])}
        print(f"| {n} | " + " / ".join(f"{g:+.2%}" for g in row["geo"]) + " | " +
              ", ".join(f"{w} {c:+.1%}" for w, c in row["worst"]) + " | " + (", ".join(sorted(row["dead"])) or "none") +
              " | " + " / ".join(f"{x:.2f}" for x in row["xpki"]) + " |")
    print("\n**Pairs** (WS over the 42 against one program on today's core; deadlocks over the 87; 30 / 120 / 250 "
          "cycles)\n")
    print("| Homes | WS | Against D4 as planned | memory + memory | compute + compute | mixed | Deadlocked pairs |\n"
          "|---|---|---|---|---|---|---|")
    base_ws = {}
    for n in HOMES_PAIRS:
        row = {"ws": [], "groups": [], "dead": []}
        for lat in LATS:
            e = evaluate7({**HOME_BASE, **HOMES[n]}, lat, alone(BASE7, lat))
            row["ws"].append(e["ws"])
            row["groups"].append(e["groups"])
            row["dead"].append([smt.pname(a, b) for _, a, b in smt.PAIRS + extra
                                if dead(run7(PRESET, {**HOME_BASE, **HOMES[n], "dram_lat": lat}, a, b))])
            if n == HOMES_PAIRS[0]:
                base_ws[lat] = e["ws"]
        out["pairs"][n] = row
        print(f"| {n} | " + " / ".join(f"{x:.3f}" for x in row["ws"]) + " | " +
              " / ".join(f"{x / base_ws[lat] - 1:+.1%}" for x, lat in zip(row["ws"], LATS)) + " | " +
              " | ".join(" / ".join(f"{g[k]['ws']:.3f}" for g in row["groups"]) for k in GROUPS) + " | " +
              " / ".join(str(len(d)) for d in row["dead"]) + " |")
    for n in HOMES_PAIRS:
        for lat, dl in zip(LATS, out["pairs"][n]["dead"]):
            if dl:
                print(f"- {n}, {lat} cycles: {', '.join(dl)}")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--policy", action="store_true")
    ap.add_argument("--exit2", action="store_true")
    ap.add_argument("--deadlock", action="store_true")
    ap.add_argument("--fp", action="store_true")
    ap.add_argument("--lone", action="store_true")
    ap.add_argument("--prediction", action="store_true", help="exit 2's table from --exit2 and --policy")
    ap.add_argument("--groups", action="store_true", help="mixed decode/rename/commit groups against one a thread")
    ap.add_argument("--d3rev", action="store_true", help="per-hart free lists with transfers against shared + walk")
    ap.add_argument("--pair", action="store_true", help="exit 2 blind on verif-2's pair runner (TG_PAIRDIR)")
    ap.add_argument("--homes", action="store_true", help="D4's alternatives: where hart 1's registers live at reset")
    ap.add_argument("--calib", action="store_true", help="the runner's programs alone against verif-2's RTL alone runs")
    ap.add_argument("--final", action="store_true", help="exit 2 blind on the final pair set (TG_FINALDIR), revision 8")
    ap.add_argument("--workers", type=int, default=16)
    a = ap.parse_args()
    res = json.loads(OUT.read_text()) if OUT.exists() else {}
    res["config"] = {"preset": PRESET, "core": CORE, "policy": POLICY}
    for name, fn in (("policy", policy), ("exit2", exit2), ("deadlock", deadlock), ("fp", fp), ("lone", lone),
                     ("prediction", prediction), ("groups", groups), ("d3rev", d3rev), ("pair", pairrun),
                     ("homes", homes), ("calib", calib), ("final", final)):
        if getattr(a, name):
            res[name] = fn(a.workers)
            OUT.write_text(json.dumps(res, indent=1) + "\n")


if __name__ == "__main__":
    main()
