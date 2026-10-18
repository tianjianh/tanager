"""Design-space exploration for Tanager v1 (plan draft 0.3, section 10.1).

Runs, with results cached in results/dse/:
  * baseline: Tanager v1 and the calibrated NaxRiscv-like control at every latency point;
  * ablations: each Tanager feature switched off (or an option switched on) at 30/120/250 cycles;
  * sweeps: structure sizes at 30/120/250 cycles.
Writes results/dse_summary_<isa>.json (--baseline: baselines only), which scripts/report.py turns into docs/perf/*.md.

Suite IPC = geomean of three equally weighted group geomeans:
  kernels (CoreMark A, CoreMark B, Dhrystone), embench (19 programs), memsuite (memory kernels).
"""
import hashlib
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tgrun  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "results" / "dse"
LAT = {"native30": 30, "native60": 60, "fpga90": 90, "design120": 120, "stress250": 250}
DECISION = [30, 120, 250]

# Each ablation compares Tanager v1 with these settings applied.
ABLATIONS = {
    "TAGE-lite -> 4 KB gshare": {"dirpred": 1, "gshare_log": 14, "gshare_hist": 14},
    "micro-BTB off": {"ubtb": 0},
    "checkpoints off (recover at commit)": {"ckpt": 0},
    "SFB predication off": {"sfb": 0},
    "jump folding off": {"fold": 0},
    "fusion off": {"fusion": 0},
    "speculative load wakeup off": {"spec_wakeup": 0},
    "early retirement off": {"early_retire": 0},
    "memory-dependence wait table off": {"mdp": 0},
    "branch-first select off": {"br_first": 0},
    "ownership prefetch off": {"rfo_pf": 0},
    "L1D stride prefetcher off": {"pf_stride": 0},
    "L2 stream prefetcher off": {"pf_stream": 0},
    "I-side prefetch off (FDIP + next line)": {"fdip": 0, "pf_i_nextline": 0},
    "L1D MSHRs 12 -> 8": {"l1d_mshr": 8},
    "L1s 32 KiB -> 16 KiB": {"l1d_kb": 16, "l1d_ways": 4, "l1i_kb": 16, "l1i_ways": 4},
    "L2 1 MiB -> 512 KiB": {"l2_kb": 512},
    "+ALU+branch fusion": {"fuse_alubr": 1},
    "+micro-BTB 64 entries": {"ubtb": 64},
    "+second load pipe": {"ld_ports": 2},
    "+radix-16 FP divide/sqrt": {"lat_fdiv_s": 10, "lat_fdiv_d": 17, "lat_fsqrt_s": 10, "lat_fsqrt_d": 17},
    # Goldschmidt divide/sqrt on two dedicated DSP multipliers (56x56, 4-cycle pipelined): seed table (2 cycles),
    # iterations of 5 cycles (divide) or 6 (sqrt), each doubling precision, then remainder, correction and
    # rounding (6 cycles); pipelined, a new operation every 4 cycles (3 with the larger seed).
    "+Goldschmidt divide/sqrt, 10-bit seed": {"lat_fdiv_s": 18, "lat_fdiv_d": 23, "lat_fsqrt_s": 20,
                                              "lat_fsqrt_d": 26, "fdiv_ii": 4},
    "+Goldschmidt divide/sqrt, 14-bit seed": {"lat_fdiv_s": 13, "lat_fdiv_d": 18, "lat_fsqrt_s": 14,
                                              "lat_fsqrt_d": 20, "fdiv_ii": 3},
    "+second FMA pipe": {"fp_ports": 2},
}

SWEEPS = {
    "rob": [48, 64, 80, 96, 128],
    "iq": [6, 8, 10, 12, 16],          # A0/A1/LD/FP entries; STA = 2/3 of it
    "lq": [12, 16, 24, 32],
    "sq": [12, 16, 24],
    "lqcb": [0, 8, 16, 24],
    "l1d_mshr": [4, 8, 12, 16, 20, 24],
    "l2_mshr": [16, 32, 48],
    "l1i_mshr": [1, 2, 4],
    "ubtb": [0, 16, 32, 64, 128],
    "llt": [16, 24, 32, 48],
    "tage_log": [9, 10, 11, 12],
    "ckpt": [0, 4, 8, 12],
    "pf_stride_dist": [2, 4, 8, 16, 32],
    "pf_stream_dist": [4, 8, 16],
    "lat_fma": [4, 5, 6],
}


# Early-retirement go/no-go (plan section 4.5): early retirement must reach the 16-filler pointer-chase MLP
# more cheaply than a bigger ROB, or let the ROB shrink to 48. The bigger-ROB alternatives get the LQ and
# registers they need, so the comparison is against a window that is not starved elsewhere.
ER_STUDY = {
    "ER on, ROB 48": {"rob": 48},
    "ER off, ROB 48": {"early_retire": 0, "rob": 48},
    "ER off, ROB 64": {"early_retire": 0},
    "ER off, ROB 96, LQ 24": {"early_retire": 0, "rob": 96, "lq": 24},
    "ER off, ROB 128, LQ 32, 96 regs/bank": {"early_retire": 0, "rob": 128, "lq": 32, "bank_size": 96},
    "ER off, ROB 160, LQ 32, 96 regs/bank": {"early_retire": 0, "rob": 160, "lq": 32, "bank_size": 96},
}


# Targeted kernels (bench/build_extra.sh) for features the suite does not exercise: (preset, sets).
TARGETED = {
    "v1": ("tanager_v1", {}),
    "NaxRiscv-like": ("nax", {}),
    "I-side prefetch off": ("tanager_v1", {"fdip": 0, "pf_i_nextline": 0}),
    "next-line I-prefetch only": ("tanager_v1", {"fdip": 0}),
    "L1I MSHRs 2 -> 4": ("tanager_v1", {"l1i_mshr": 4}),
    "L1I 16 KiB": ("tanager_v1", {"l1i_kb": 16, "l1i_ways": 4}),
    "stride prefetcher off": ("tanager_v1", {"pf_stride": 0}),
    "wait table off": ("tanager_v1", {"mdp": 0}),
    "checkpoints off": ("tanager_v1", {"ckpt": 0}),
    "checkpoints 4": ("tanager_v1", {"ckpt": 4}),
    "early retirement off": ("tanager_v1", {"early_retire": 0}),
    "speculative wakeup off": ("tanager_v1", {"spec_wakeup": 0}),
}


def freeze_candidates():
    """v1 freeze candidates, settings on top of tanager_v1: the greedy result on rv64gc (results/greedy_rv64gc.json,
    the acceptance rule applied to the combined design) and that result with each exception or option added."""
    f = ROOT / "results" / "greedy_rv64gc.json"
    if not f.exists():
        raise SystemExit("run `dse.py rv64gc --greedy` first")
    g = json.loads(f.read_text())["final"]
    c = {"v1 (draft 0.3)": {}, "greedy freeze (rule only)": g}
    if g.get("ckpt", 8) < 4:
        c["greedy + 4 checkpoints"] = {**g, "ckpt": 4}
    c["greedy + L2 48 MSHRs, stream distance 16, degree 4"] = {**g, "l2_mshr": 48, "pf_stream_dist": 16,
                                                               "pf_stream_deg": 4}
    c["greedy + L2 64 MSHRs, stream distance 32"] = {**g, "l2_mshr": 64, "pf_stream_dist": 32}
    c["greedy + radix-16 FP divide/sqrt"] = {**g, "lat_fdiv_s": 10, "lat_fdiv_d": 17, "lat_fsqrt_s": 10,
                                             "lat_fsqrt_d": 17}
    c["greedy + pair-decode fusion"] = {**g, "fusion": 1, "fuse_alubr": 1, "fuse_1slot": 1}
    gs10 = {"lat_fdiv_s": 18, "lat_fdiv_d": 23, "lat_fsqrt_s": 20, "lat_fsqrt_d": 26, "fdiv_ii": 4}
    gs14 = {"lat_fdiv_s": 13, "lat_fdiv_d": 18, "lat_fsqrt_s": 14, "lat_fsqrt_d": 20, "fdiv_ii": 3}
    c["greedy + Goldschmidt, 10-bit seed"] = {**g, **gs10}
    c["greedy + Goldschmidt, 14-bit seed"] = {**g, **gs14}
    c["greedy + FP IQ 10"] = {**g, "iq_fp": 10}
    # Combined finals: the rule result plus the written exceptions (and the Goldschmidt unit).
    exc = {"ckpt": 4, "l2_mshr": 48, "pf_stream_dist": 16, "pf_stream_deg": 4}
    c["final A: greedy + exceptions"] = {**g, **exc}
    c["final B: A + Goldschmidt 10-bit"] = {**g, **exc, **gs10}
    c["final C: B + FP IQ 10"] = {**g, **exc, **gs10, "iq_fp": 10}
    return c


# Greedy freeze (--greedy). Feature decisions come from the ablations (features below the line removed; the
# I-side exception kept); every structure starts at the bottom of its sweep range and grows only by increments
# that pass the acceptance rule in the combined design. LUT costs as in scripts/report.py.
CORE_LUTS = 41000.0
LEAN = {
    "ubtb": 64, "tage_log": 12,
    "fusion": 0, "sfb": 0, "fold": 0, "mdp": 0, "br_first": 0,
    "l1i_mshr": 4,
    "rob": 48, "iq_a0": 6, "iq_a1": 6, "iq_ld": 6, "iq_fp": 6, "iq_sta": 4,
    "lq": 16, "sq": 12, "lqcb": 8, "llt": 16, "l1d_mshr": 12, "ckpt": 0,
}
INCREMENTS = {  # name: (next state, LUT cost of the step, allowed)
    "ROB +16": (lambda s: {**s, "rob": s["rob"] + 16}, lambda s: 480, lambda s: s["rob"] < 128),
    "ALU IQs +2": (lambda s: {**s, "iq_a0": s["iq_a0"] + 2, "iq_a1": s["iq_a1"] + 2}, lambda s: 320,
                   lambda s: s["iq_a0"] < 16),
    "LD IQ +2": (lambda s: {**s, "iq_ld": s["iq_ld"] + 2}, lambda s: 160, lambda s: s["iq_ld"] < 16),
    "FP IQ +2": (lambda s: {**s, "iq_fp": s["iq_fp"] + 2}, lambda s: 160, lambda s: s["iq_fp"] < 16),
    "STA IQ +2": (lambda s: {**s, "iq_sta": s["iq_sta"] + 2}, lambda s: 160, lambda s: s["iq_sta"] < 12),
    "LQ +8": (lambda s: {**s, "lq": s["lq"] + 8}, lambda s: 320, lambda s: s["lq"] < 32),
    "SQ +4": (lambda s: {**s, "sq": s["sq"] + 4}, lambda s: 200, lambda s: s["sq"] < 24),
    "L1D MSHRs +4": (lambda s: {**s, "l1d_mshr": s["l1d_mshr"] + 4}, lambda s: 300, lambda s: s["l1d_mshr"] < 24),
    "LLTs +8": (lambda s: {**s, "llt": s["llt"] + 8}, lambda s: 200, lambda s: s["llt"] < 48),
    "completion buffer +8": (lambda s: {**s, "lqcb": s["lqcb"] + 8}, lambda s: 64, lambda s: s["lqcb"] < 24),
    "checkpoints +4": (lambda s: {**s, "ckpt": s["ckpt"] + 4}, lambda s: 500, lambda s: s["ckpt"] < 12),
}
UNCORE_KEYS = {"l2_kb", "l2_ways", "l2_lat", "l2_mshr", "pf_stream", "pf_stream_dist", "pf_stream_deg",
               "dram_line_cyc"}


def sweep_sets(param, v):
    if param == "iq":
        return {"iq_a0": v, "iq_a1": v, "iq_ld": v, "iq_fp": v, "iq_sta": max(4, (2 * v) // 3)}
    return {param: v}


# Bump whenever a model change can alter results, so cached runs of the old model are not reused.
# 2: I-side prefetches may use the last free L1I MSHR while a demand miss is outstanding.
# 3: FP divide/sqrt latencies follow the plan's radix-4 iterative unit (17/31 cycles single/double; were 12-24).
MODEL_VERSION = 3
# Bump whenever the workload set changes.
# 2: memsuite gains ms_stride and ms_gather (independent misses whose consumers wait in the window).
SUITE_VERSION = 2


# Presets redefined since their results were cached: the revision joins their key only, so other presets' caches
# stay valid. rtl_m2 2: §6.4's recalibration (four misses in flight, the RTL's issue queues and store address);
# 3: speculative load wakeup on, as main has it (§6.5); 4: its cancels at a D$ row clash, fast forwards (§6.6);
# 5: straddlers decoded with their second block, the micro-BTB trained in the way that predicted (§6.7); 6: ALU ops
# steered at rename from the queues' flags of the cycle before (§6.8).
PRESET_REV = {"rtl_m2": 6}


def key(isa, preset, sets):
    parts = [isa, preset, sorted(sets.items()), MODEL_VERSION, SUITE_VERSION]
    if PRESET_REV.get(preset):
        parts.append(PRESET_REV[preset])
    raw = json.dumps(parts)
    return hashlib.sha1(raw.encode()).hexdigest()[:16], raw


def collect(configs, isa="rv64gc", workers=None, mname="manifest"):
    """configs: list of (preset, sets). Runs whatever is not cached; returns {key: results}.
    Runs on another manifest (mname) are cached under the key of "<isa>:<mname>"."""
    workers = workers or os.cpu_count() or 8
    CACHE.mkdir(parents=True, exist_ok=True)
    ws = tgrun.manifest(isa, mname)
    kisa = isa if mname == "manifest" else f"{isa}:{mname}"
    todo, out = [], {}
    for preset, sets in configs:
        k, raw = key(kisa, preset, sets)
        f = CACHE / f"{k}.jsonl"
        if f.exists():
            out[k] = [json.loads(l) for l in f.read_text().splitlines()]
        else:
            todo.extend((k, raw, w, preset, sets) for w in ws)
    if todo:
        with ThreadPoolExecutor(max_workers=workers) as ex:
            res = list(ex.map(lambda j: (j[0], j[1], tgrun.run_one(j[2], j[3], j[4])), todo))
        grouped = {}
        for k, raw, r in res:
            grouped.setdefault(k, (raw, []))[1].append(r)
        for k, (raw, rs) in grouped.items():
            bad = [(r["workload"]["name"], tgrun.check(r)) for r in rs if tgrun.check(r)]
            if bad:
                raise SystemExit(f"failed runs for {raw}: {bad}")
            (CACHE / f"{k}.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rs))
            out[k] = rs
    return out


def summarize(rs):
    by = {r["workload"]["name"]: tgrun.metrics(r) for r in rs}
    g = tgrun.geomean
    kernels = g([by[n]["ipc"] for n in ("coremark_A", "coremark_B", "dhrystone")])
    emb = g([m["ipc"] for n, m in by.items() if n.startswith("embench_")])
    mem = g([m["ipc"] for n, m in by.items() if n.startswith("ms_")])
    s = tgrun.score(rs)
    out = {
        "suite_ipc": g([kernels, emb, mem]),
        "kernels_ipc": kernels, "embench_ipc": emb, "memsuite_ipc": mem,
        "coremark_A": s["coremark_A"], "coremark_B": s["coremark_B"], "dmips": s["dmips"],
        "embench": s["embench"], "embench18": s["embench18"],
        "mlp_chase8": by["ms_chase8"]["mlp"], "mlp_chase16": by["ms_chase16"]["mlp"],
        "mlp_chase8f16": by["ms_chase8f16"]["mlp"],
        "ipc": {n: m["ipc"] for n, m in by.items()},
    }
    return out


def targeted(isa):
    """Targeted kernels (build/bench/<isa>/extra.jsonl) under the TARGETED configurations at DECISION latencies."""
    configs = [(p, {**s, "dram_lat": lat}) for p, s in TARGETED.values() for lat in DECISION]
    data = collect(configs, isa, mname="extra")
    kisa = f"{isa}:extra"
    out = {"isa": isa, "configs": {}}
    for name, (p, s) in TARGETED.items():
        out["configs"][name] = {"preset": p, "sets": s, "by_lat": {}}
        for lat in DECISION:
            rs = data[key(kisa, p, {**s, "dram_lat": lat})[0]]
            per = {}
            for r in rs:
                m, g = tgrun.metrics(r), r["region"]
                per[r["workload"]["name"]] = {
                    "ipc": m["ipc"], "mpki": m["mpki"], "l1d_mpki": m["l1d_mpki"], "mlp": m["mlp"],
                    "l1i_mpki": g.get("l1i_miss", 0) / max(1, g["instr"]) * 1000,
                    **{c: g.get(c, 0) for c in ("violation_flushes", "mdp_waits", "mp_resolved_commit",
                                                "fetch_stall_icache", "cycles", "instr")}}
            out["configs"][name]["by_lat"][str(lat)] = per
    f = ROOT / "results" / f"targeted_{isa}.json"
    f.write_text(json.dumps(out, indent=1))
    print(f"wrote {f}")


def uncore(sets):
    """The shared-memory-system part of a configuration: the control always runs with the same uncore."""
    return {k: v for k, v in sets.items() if k in UNCORE_KEYS}


def freeze(isa):
    """Freeze candidates at every latency point on the suite, plus the targeted kernels at DECISION latencies.
    Each candidate's ratio is taken against the NaxRiscv-like control with the candidate's uncore settings."""
    FREEZE = freeze_candidates()
    configs = [("tanager_v1", {**s, "dram_lat": lat}) for s in FREEZE.values() for lat in LAT.values()]
    configs += [("nax", {**uncore(s), "dram_lat": lat}) for s in FREEZE.values() for lat in LAT.values()]
    # Sensitivity of the control to its assumed FP latency (7 cycles; NaxRiscv documents none).
    configs += [("nax", {"dram_lat": 120, "lat_fma": 5})]
    data = collect(configs, isa)
    tconf = [("tanager_v1", {**s, "dram_lat": lat}) for s in FREEZE.values() for lat in DECISION]
    tdata = collect(tconf, isa, mname="extra")
    out = {"isa": isa, "latencies": LAT, "nax": {}, "candidates": {}}
    for lname, lat in LAT.items():
        out["nax"][lname] = summarize(data[key(isa, "nax", {"dram_lat": lat})[0]])
    out["nax_fma5_120"] = summarize(data[key(isa, "nax", {"dram_lat": 120, "lat_fma": 5})[0]])
    for name, s in FREEZE.items():
        c = {"sets": s, "by_lat": {}, "nax_by_lat": {}, "targeted": {}}
        for lname, lat in LAT.items():
            c["by_lat"][lname] = summarize(data[key(isa, "tanager_v1", {**s, "dram_lat": lat})[0]])
            c["nax_by_lat"][lname] = summarize(data[key(isa, "nax", {**uncore(s), "dram_lat": lat})[0]])
        for lat in DECISION:
            rs = tdata[key(f"{isa}:extra", "tanager_v1", {**s, "dram_lat": lat})[0]]
            c["targeted"][str(lat)] = {r["workload"]["name"]: tgrun.metrics(r)["ipc"] for r in rs}
        out["candidates"][name] = c
    f = ROOT / "results" / f"freeze_{isa}.json"
    f.write_text(json.dumps(out, indent=1))
    print(f"wrote {f}")


def width_study(isa):
    """Front-end width questions at DECISION latencies: 3-wide decode/rename/commit, a third ALU, and an upper bound
    for a micro-op cache at 2-wide (no taken-branch bubbles, one fewer stage between fetch and dispatch)."""
    g = json.loads((ROOT / "results" / "greedy_rv64gc.json").read_text())["final"]
    w3 = {"decode_width": 3, "commit_width": 3}
    study = {
        "v1 (draft 0.3), 2-wide": {},
        "v1, 3-wide, 2 ALUs": w3,
        "greedy freeze, 2-wide": g,
        "greedy, 3-wide, 2 ALUs": {**g, **w3},
        "greedy, micro-op cache upper bound (2-wide)": {**g, "taken_bubble": 0, "dec_to_disp": 1},
    }
    if "--alu3" in sys.argv:  # needs a tgsim with the alu3 parameter
        study["greedy, 2-wide, 3 ALUs"] = {**g, "alu3": 1}
        study["greedy, 3-wide, 3 ALUs"] = {**g, **w3, "alu3": 1}
        study["greedy, 3-wide, 3 ALUs, ROB 64, ALU IQs 12"] = {**g, **w3, "alu3": 1, "rob": 64,
                                                               "iq_a0": 12, "iq_a1": 12}
    configs = [("tanager_v1", {**s, "dram_lat": lat}) for s in study.values() for lat in DECISION]
    data = collect(configs, isa)
    out = {"isa": isa, "configs": {}}
    for name, s in study.items():
        out["configs"][name] = {"sets": s, "by_lat": {str(lat): summarize(data[key(isa, "tanager_v1",
                                                                                    {**s, "dram_lat": lat})[0]])
                                                      for lat in DECISION}}
    f = ROOT / "results" / f"width_{isa}.json"
    f.write_text(json.dumps(out, indent=1))
    print(f"wrote {f}")


def greedy(isa):
    """The acceptance rule applied to the combined design: from LEAN, add one size increment per round, the one
    with the best suite-IPC gain per LUT at 120 cycles among those whose gain (%) is at least their LUT cost (%)
    and that pass the guards (no loss worse than 0.25% at 30 or 250 cycles). Stops when none qualifies."""
    state, rounds = dict(LEAN), []

    def ipc(sets, lat):
        k = key(isa, "tanager_v1", {**sets, "dram_lat": lat})[0]
        return summarize(collect([("tanager_v1", {**sets, "dram_lat": lat})], isa)[k])["suite_ipc"]

    while True:
        cands = {n: (f(state), cost(state)) for n, (f, cost, ok) in INCREMENTS.items() if ok(state)}
        collect([("tanager_v1", {**s, "dram_lat": 120}) for s in [state] + [c for c, _ in cands.values()]], isa)
        base = ipc(state, 120)
        rows = []
        for n, (c, cost) in cands.items():
            gain = (ipc(c, 120) / base - 1) * 100
            share = cost / CORE_LUTS * 100
            rows.append({"increment": n, "gain_120": gain, "lut": cost, "lut_share": share, "ratio": gain / share})
        rows.sort(key=lambda r: -r["ratio"])
        chosen = None
        for r in rows:
            if r["gain_120"] < r["lut_share"]:
                break
            c = cands[r["increment"]][0]
            collect([("tanager_v1", {**s, "dram_lat": lat}) for s in (state, c) for lat in (30, 250)], isa)
            r["gain_30"] = (ipc(c, 30) / ipc(state, 30) - 1) * 100
            r["gain_250"] = (ipc(c, 250) / ipc(state, 250) - 1) * 100
            if r["gain_30"] >= -0.25 and r["gain_250"] >= -0.25:
                chosen = r
                break
        rounds.append({"state": dict(state), "suite_ipc_120": base, "candidates": rows,
                       "chosen": chosen["increment"] if chosen else None})
        print(f"round {len(rounds)}: ipc {base:.4f} -> {chosen['increment'] if chosen else 'stop'}", flush=True)
        if not chosen:
            break
        state = cands[chosen["increment"]][0]
    f = ROOT / "results" / f"greedy_{isa}.json"
    f.write_text(json.dumps({"isa": isa, "lean": LEAN, "final": state, "rounds": rounds}, indent=1))
    print(f"wrote {f}")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    isa = args[0] if args else "rv64gc"
    if "--targeted" in sys.argv:
        return targeted(isa)
    if "--freeze" in sys.argv:
        return freeze(isa)
    if "--greedy" in sys.argv:
        return greedy(isa)
    if "--width" in sys.argv:
        return width_study(isa)
    baseline_only = "--baseline" in sys.argv  # Tanager v1 and the control at every latency point only
    ablations = {} if baseline_only else ABLATIONS
    er_study = {} if baseline_only else ER_STUDY
    sweeps = {} if baseline_only else SWEEPS
    configs = []
    for lat in LAT.values():
        configs += [("tanager_v1", {"dram_lat": lat}), ("nax", {"dram_lat": lat})]
    for name, sets in {**ablations, **er_study}.items():
        configs += [("tanager_v1", {**sets, "dram_lat": lat}) for lat in DECISION]
    for param, vals in sweeps.items():
        for v in vals:
            configs += [("tanager_v1", {**sweep_sets(param, v), "dram_lat": lat}) for lat in DECISION]
    # unique
    seen, uniq = set(), []
    for c in configs:
        k = key(isa, *c)[0]
        if k not in seen:
            seen.add(k)
            uniq.append(c)
    print(f"{len(uniq)} configurations on {isa}", flush=True)
    data = collect(uniq, isa)

    def get(preset, sets):
        return summarize(data[key(isa, preset, sets)[0]])

    summary = {"isa": isa, "latencies": LAT, "baseline": {}, "ablations": {}, "er_study": {}, "sweeps": {}}
    for name, lat in LAT.items():
        summary["baseline"][name] = {p: get(p, {"dram_lat": lat}) for p in ("tanager_v1", "nax")}
    for part, items in (("ablations", ablations), ("er_study", er_study)):
        for name, sets in items.items():
            summary[part][name] = {"sets": sets, "by_lat": {str(lat): get("tanager_v1", {**sets, "dram_lat": lat})
                                                            for lat in DECISION}}
    for param, vals in sweeps.items():
        summary["sweeps"][param] = {str(v): {str(lat): get("tanager_v1", {**sweep_sets(param, v), "dram_lat": lat})
                                             for lat in DECISION} for v in vals}
    out = ROOT / "results" / f"dse_summary_{isa}.json"
    out.write_text(json.dumps(summary, indent=1))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
