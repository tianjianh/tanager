"""SMT2 study for Tanager v2 (plan section 6): two programs on one core (tgsim threads=2).

Each run puts two rv64gc suite workloads on hardware threads 0 and 1. A thread's IPC is taken over the marked
region of its program's first run; a program that ends before the other thread's first run is complete is
restarted, so both threads stay active until both first runs are measured. Results are cached per
(configuration, pair) in results/smt/, keyed like scripts/dse.py plus SMT_VERSION.

  python3 scripts/smt.py              # the whole study -> results/smt2_rv64gc.json
  python3 scripts/smt.py --explore    # SMT policy and cap exploration at 120 cycles (chose SMT_BASE)
  python3 scripts/smt.py --greedy     # the v2 sizing pass only (also part of the whole study)
  python3 scripts/smt.py --tables     # docs/perf/smt2_tables.md from results/smt2_rv64gc.json
  python3 scripts/smt.py --supplementary  # window sharing x issue-queue cap; window bundles on the greedy result
  python3 scripts/smt.py --validate   # SMT2 consistency checks (needs bash tests/build_idle.sh)
  python3 scripts/smt.py --bundles    # the greedy pass with whole-window steps (the proposed v2)
  python3 scripts/smt.py --width3     # the same pass on a 3-wide, 3-ALU SMT2 core (plan rule 12)

Metrics per pair:
  throughput  the sum of the two threads' IPC
  WS          weighted speedup: the sum over the threads of IPC_smt / IPC_alone, where IPC_alone is the same
              program on the same configuration with threads=1 (one thread gets every partition)
  WS_ref      the same with IPC_alone taken on v1_freeze: throughput normalised to the v1 core running one
              program at a time; it compares configurations and drives the greedy sizing pass
  fairness    harmonic mean of the per-thread speedups IPC_smt / IPC_alone (same configuration)
Group figures are geometric means over the pairs of a group (memory+memory, compute+compute, mixed); the
overall figure is the geometric mean of the three group means, like the M1 suite IPC.
"""
import hashlib
import json
import math
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dse  # noqa: E402
import tgrun  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "results" / "smt"
OUT = ROOT / "results" / "smt2_rv64gc.json"
DOCS = ROOT.parent / "docs" / "perf"
ISA = "rv64gc"
LATS = (30, 120, 250)
PRESET = "tanager_v1"  # every configuration is tanager_v1 plus explicit settings, so single-thread runs reuse M1's cache
# Bump whenever a model change can alter threads=2 results (threads=1 results are covered by dse.MODEL_VERSION).
SMT_VERSION = 1

GROUPS = ("mem+mem", "compute+compute", "mixed")
MEM = ["ms_gather", "ms_stride", "ms_spmv", "ms_hashprobe", "ms_chase8", "ms_stream", "ms_copy"]
COMP = ["coremark_A", "dhrystone", "embench_nsichneu", "embench_huffbench", "embench_minver", "embench_matmult-int"]
SHORT = {"ms_gather": "gather", "ms_stride": "stride", "ms_spmv": "spmv", "ms_hashprobe": "hashprobe",
         "ms_chase8": "chase8", "ms_stream": "stream", "ms_copy": "copy", "coremark_A": "CoreMark",
         "dhrystone": "Dhrystone", "embench_nsichneu": "nsichneu", "embench_huffbench": "huffbench",
         "embench_minver": "minver", "embench_matmult-int": "matmult"}


def make_pairs():
    """42 pairs: within each set, every program with its next and second-next neighbour (each appears four
    times), one self pair per set, and each memory kernel with two compute programs."""
    pairs = []
    for d in (1, 2):
        pairs += [("mem+mem", MEM[i], MEM[(i + d) % len(MEM)]) for i in range(len(MEM))]
    pairs.append(("mem+mem", "ms_chase8", "ms_chase8"))
    for d in (1, 2):
        pairs += [("compute+compute", COMP[i], COMP[(i + d) % len(COMP)]) for i in range(len(COMP))]
    pairs.append(("compute+compute", "coremark_A", "coremark_A"))
    for i, m in enumerate(MEM):
        pairs += [("mixed", m, COMP[i % len(COMP)]), ("mixed", m, COMP[(i + 3) % len(COMP)])]
    return pairs


PAIRS = make_pairs()


def pname(a, b):
    return f"{SHORT.get(a, a)}+{SHORT.get(b, b)}"


def v1_freeze():
    """The approved M1 freeze (= preset v1_freeze), as settings on tanager_v1."""
    f = json.loads((ROOT / "results" / "freeze_rv64gc.json").read_text())
    return dict(f["candidates"]["final C: B + FP IQ 10"]["sets"])


V1F = v1_freeze()
# SMT policy defaults, always passed explicitly so cache keys capture them. --explore (120 cycles, v1_freeze sizes,
# issue queues uncapped) chose them: ICOUNT beats round robin by 0.5%; a 75% issue-queue cap is neutral (+0.05%;
# 50% loses 1.8%) and is the plan's "capped shared queues"; MSHR and LLT caps never bind (the per-thread LQ and
# completion-buffer halves already bound each thread's misses); slot mixing is worth 0.4%, TID hashing 0.06%.
# Static halves are the plan's partitioning (section 6.4). Uncapped queues made a shared window lose (75% cap -1.7%);
# with the 75% queue cap, a shared window with a 75% cap gains instead (report section 5).
SMT_BASE = {"threads": 2, "smt_fetch": 0, "smt_part": 1, "smt_win_cap": 75, "smt_iq_cap": 75, "smt_mshr_cap": 100,
            "smt_llt_cap": 100, "smt_bp_hash": 1, "smt_mix": 1}
BASE = {**V1F, **SMT_BASE}


def single(sets):
    """The single-thread configuration with the same structures (threads=1 recombines the partitions)."""
    return {k: v for k, v in sets.items() if k != "threads" and not k.startswith("smt_")}


# ---------------------------------------------------------------- running and caching


def pair_key(sets, a, b):
    parts = [ISA, "smt", PRESET, sorted(sets.items()), a, b, dse.MODEL_VERSION, dse.SUITE_VERSION, SMT_VERSION]
    if dse.PRESET_REV.get(PRESET, 0) >= 8:   # the preset's revision, from 8 on (earlier runs were cached without it)
        parts.append(["rev", dse.PRESET_REV[PRESET]])
    raw = json.dumps(parts)
    return hashlib.sha1(raw.encode()).hexdigest()[:16], raw


WS = {w["name"]: w for w in tgrun.manifest(ISA)}
# A sibling that barely loads the core (tests/idle.c: uncached MMIO loads at the ROB head), for --validate.
WS["idle"] = {"name": "idle", "elf": str(ROOT / "build" / "tests" / "idle_rv64gc.elf"), "stdin": "", "ff": 0}


def run_pair(sets, a, b):
    w0, w1 = WS[a], WS[b]
    args = [str(tgrun.TGSIM), "--preset", PRESET, "--bench", a, "--bench2", b]
    cfg = dict(sets)
    if w0.get("ff"):
        cfg.setdefault("ff", 1)
    for k, v in cfg.items():
        args += ["--set", f"{k}={v}"]
    if w0.get("stdin"):
        args += ["--stdin", w0["stdin"]]
    if w1.get("stdin"):
        args += ["--stdin2", w1["stdin"]]
    if w1.get("ff"):
        args += ["--ff2", "1"]
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tf:
        out = tf.name
    args += ["--json", out, w0["elf"], w1["elf"]]
    p = subprocess.run(args, capture_output=True, text=True)
    try:
        r = json.loads(Path(out).read_text())
    except Exception:  # noqa: BLE001
        r = {"error": f"no result (rc={p.returncode}) {p.stderr[-300:]}", "threads": []}
    finally:
        try:
            os.unlink(out)
        except OSError:
            pass
    r.pop("config", None)
    r["pair"] = [a, b]
    r["sets"] = sets
    return r


def check_pair(r):
    if r.get("error"):
        return r["error"]
    for t, w in zip(r["threads"], r["pair"]):
        why = tgrun.check({"error": "", "exit_code": t["exit_code"], "stdout": t["stdout"], "workload": WS[w]})
        if why:
            return f"{w}: {why}"
        if not t["marked"]:
            return f"{w}: no region"
    return ""


_est = {}


def estimate(a, b, lat):
    """Run-time estimate for scheduling: the longer program's single-thread region on v1_freeze."""
    if lat not in _est:
        k = dse.key(ISA, PRESET, {**V1F, "dram_lat": lat})[0]
        f = dse.CACHE / f"{k}.jsonl"
        _est[lat] = {}
        if f.exists():
            for line in f.read_text().splitlines():
                r = json.loads(line)
                _est[lat][r["workload"]["name"]] = r["total"]["cycles"]
    e = _est[lat]
    return max(e.get(a, 1e6), e.get(b, 1e6))


def collect(jobs, workers=None):
    """jobs: list of (sets, a, b). Simulates what is not cached; returns {(key): result}."""
    workers = workers or os.cpu_count() or 8
    CACHE.mkdir(parents=True, exist_ok=True)
    out, todo, seen = {}, [], set()
    for sets, a, b in jobs:
        k, _ = pair_key(sets, a, b)
        f = CACHE / f"{k}.json"
        if f.exists():
            out[k] = json.loads(f.read_text())
        elif k not in seen:
            seen.add(k)
            todo.append((k, sets, a, b))
    if todo:
        todo.sort(key=lambda j: -estimate(j[2], j[3], j[1].get("dram_lat", 120)))
        print(f"  simulating {len(todo)} pair runs", flush=True)
        bad = []
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futs = {ex.submit(run_pair, s, a, b): (k, s, a, b) for k, s, a, b in todo}
            for fu in as_completed(futs):
                k, s, a, b = futs[fu]
                r = fu.result()
                why = check_pair(r)
                if why:
                    bad.append((pname(a, b), s, why))
                    continue
                (CACHE / f"{k}.json").write_text(json.dumps(r))
                out[k] = r
        if bad:
            raise SystemExit(f"failed pair runs: {bad[:5]}")
    return out


def get(sets, a, b):
    return collect([(sets, a, b)])[pair_key(sets, a, b)[0]]


def prefetch(configs, lats, with_alone=True):
    """Simulates every pair run (and single-thread suite run) that a list of configurations needs, in one batch."""
    collect([({**s, "dram_lat": lat}, a, b) for s in configs for lat in lats for _, a, b in PAIRS])
    singles = [{**single(s), "dram_lat": lat} for s in ([V1F] + (list(configs) if with_alone else [])) for lat in lats]
    uniq = {dse.key(ISA, PRESET, s)[0]: s for s in singles}
    dse.collect([(PRESET, s) for s in uniq.values()], ISA)


# ---------------------------------------------------------------- metrics


def alone(sets, lat):
    """Single-thread region IPC of every suite workload on the configuration's single-thread equivalent."""
    s = {**single(sets), "dram_lat": lat}
    rs = dse.collect([(PRESET, s)], ISA)[dse.key(ISA, PRESET, s)[0]]
    return dse.summarize(rs)


def gm(xs):
    return tgrun.geomean(list(xs))


def pair_metrics(r, same, ref):
    th = r["threads"]
    names = r["pair"]
    ipc = [t["region"]["instr"] / max(1, t["region"]["cycles"]) for t in th]
    m = {"ipc": ipc, "throughput": sum(ipc)}
    m["speedup_ref"] = [ipc[i] / ref[names[i]] for i in range(2)]
    m["ws_ref"] = sum(m["speedup_ref"])
    if same is not None:
        m["speedup"] = [ipc[i] / same[names[i]] for i in range(2)]
        m["ws"] = sum(m["speedup"])
        m["fair"] = 2.0 / sum(1.0 / max(1e-9, s) for s in m["speedup"])
    ov = r.get("overlap", {})
    if ov.get("valid") and ov["end"] > ov["start"]:
        m["ipc_overlap"] = [i / (ov["end"] - ov["start"]) for i in ov["instr"]]
    reg = [t["region"] for t in th]
    m["mlp"] = [g["mlp_sum"] / g["mlp_cycles_nz"] if g["mlp_cycles_nz"] else 0.0 for g in reg]
    m["laps"] = [t["laps"] for t in th]
    for k in ("disp_stall_rob", "disp_stall_lq", "disp_stall_sq", "disp_stall_iq", "disp_stall_reg",
              "disp_stall_llt", "fetch_lost_smt"):
        m[k] = [g[k] / max(1, g["cycles"]) for g in reg]
    m["l1d_mpki"] = [g["l1d_miss"] * 1000.0 / max(1, g["instr"]) for g in reg]
    return m


def evaluate(sets, lat, with_alone=True, pairs=None):
    """Summary of one configuration at one latency over the pairs."""
    pairs = pairs or PAIRS
    s = {**sets, "dram_lat": lat}
    data = collect([(s, a, b) for _, a, b in pairs])
    ref = alone(V1F, lat)["ipc"]
    same_sum = alone(sets, lat) if with_alone else None
    same = same_sum["ipc"] if same_sum else None
    per = {}
    for g, a, b in pairs:
        per[pname(a, b)] = {"group": g, **pair_metrics(data[pair_key(s, a, b)[0]], same, ref)}
    out = {"pairs": per, "groups": {}}
    for g in GROUPS:
        ms = [m for m in per.values() if m["group"] == g]
        if not ms:
            continue
        e = {"ws_ref": gm(m["ws_ref"] for m in ms), "throughput": sum(m["throughput"] for m in ms) / len(ms),
             "n": len(ms)}
        if same is not None:
            e["ws"] = gm(m["ws"] for m in ms)
            e["fair"] = gm(m["fair"] for m in ms)
        out["groups"][g] = e
    G = [out["groups"][g] for g in GROUPS if g in out["groups"]]
    out["ws_ref"] = gm(e["ws_ref"] for e in G)
    out["throughput"] = sum(m["throughput"] for m in per.values()) / len(per)
    if same is not None:
        out["ws"] = gm(e["ws"] for e in G)
        out["fair"] = gm(e["fair"] for e in G)
        out["alone_suite_ipc"] = same_sum["suite_ipc"]
        out["alone"] = {k: same_sum[k] for k in ("suite_ipc", "kernels_ipc", "embench_ipc", "memsuite_ipc",
                                                  "coremark_A", "dmips")}
    return out


def brief(e):
    s = f"WS_ref {e['ws_ref']:.4f}"
    if "ws" in e:
        s += f"  WS {e['ws']:.4f}  fair {e['fair']:.4f}"
    s += "  [" + ", ".join(f"{g} {e['groups'][g]['ws_ref']:.3f}" for g in GROUPS if g in e["groups"]) + "]"
    return s


# ---------------------------------------------------------------- experiments

W3 = {"decode_width": 3, "commit_width": 3, "alu3": 1}


def policy_variants(b):
    """SMT policy and partitioning alternatives around a base configuration."""
    return {
        "round-robin fetch": {**b, "smt_fetch": 1},
        "shared ROB/LQ/SQ/CB, 75% cap": {**b, "smt_part": 0, "smt_win_cap": 75},
        "shared ROB/LQ/SQ/CB, 50% cap": {**b, "smt_part": 0, "smt_win_cap": 50},
        "shared ROB/LQ/SQ/CB, no cap": {**b, "smt_part": 0, "smt_win_cap": 100},
        "issue queues not capped": {**b, "smt_iq_cap": 100},
        "issue queues capped at 50%": {**b, "smt_iq_cap": 50},
        "L1D MSHRs capped at 75%": {**b, "smt_mshr_cap": 75},
        "long-latency tags capped at 75%": {**b, "smt_llt_cap": 75},
        "one thread per decode/rename/commit cycle": {**b, "smt_mix": 0},
        "predictor entries shared by PC (no TID hashing)": {**b, "smt_bp_hash": 0},
    }


def explore():
    """Policy and cap choices at 120 cycles on v1_freeze with threads=2 (static partitions)."""
    prefetch([BASE] + list(policy_variants(BASE).values()), (120,), with_alone=False)
    print("base:", brief(evaluate(BASE, 120, with_alone=False)))
    for name, s in policy_variants(BASE).items():
        print(f"{name}: {brief(evaluate(s, 120, with_alone=False))}", flush=True)


def size_variants(b):
    return {
        "ROB 64": {**b, "rob": 64},
        "ROB 96": {**b, "rob": 96},
        "LQ 24": {**b, "lq": 24},
        "LQ 32": {**b, "lq": 32},
        "SQ 16": {**b, "sq": 16},
        "SQ 24": {**b, "sq": 24},
        "completion buffer 16": {**b, "lqcb": 16},
        "L1D MSHRs 24": {**b, "l1d_mshr": 24},
        "L1D MSHRs 32": {**b, "l1d_mshr": 32},
        "long-latency tags 24": {**b, "llt": 24},
        "long-latency tags 32": {**b, "llt": 32},
        "L2 MSHRs 64": {**b, "l2_mshr": 64},
        "doubled window: ROB 96, LQ 32, SQ 24, CB 16": {**b, "rob": 96, "lq": 32, "sq": 24, "lqcb": 16},
        "doubled window + 32 L1D MSHRs + 32 LLTs": {**b, "rob": 96, "lq": 32, "sq": 24, "lqcb": 16, "l1d_mshr": 32,
                                                    "llt": 32},
    }


def option_variants(b):
    """The M1 width options under SMT2."""
    return {
        "+second load pipe": {**b, "ld_ports": 2},
        "+second FMA pipe": {**b, "fp_ports": 2},
        "+third ALU": {**b, "alu3": 1},
        "3-wide decode/rename/commit + third ALU": {**b, **W3},
    }


# ---------------------------------------------------------------- greedy v2 sizing

CORE_LUTS = dse.CORE_LUTS
SOC_LUTS = 94000.0  # scripts/report.py
# name: (next state, LUT cost of the step, scope, allowed). Costs per entry as scripts/report.py's SIZE_COST: ROB 30,
# issue-queue entry 80, LQ 40, SQ 50, completion buffer 8, L1D MSHR 75, long-latency tag 25, L2 MSHR 50 (SoC).
def alu_queues(s):
    """ALU issue queues that an "ALU IQs" step grows: A0, A1, and A2 when a third ALU follows A1's size."""
    return 3 if s.get("alu3", 0) and not s.get("iq_a2", 0) else 2


V2_INCREMENTS = {
    "ROB +16": (lambda s: {**s, "rob": s["rob"] + 16}, 480, "core", lambda s: s["rob"] < 192),
    "ALU IQs +2": (lambda s: {**s, "iq_a0": s["iq_a0"] + 2, "iq_a1": s["iq_a1"] + 2},
                   lambda s: 160 * alu_queues(s), "core", lambda s: s["iq_a0"] < 20),
    "LD IQ +2": (lambda s: {**s, "iq_ld": s["iq_ld"] + 2}, 160, "core", lambda s: s["iq_ld"] < 20),
    "FP IQ +2": (lambda s: {**s, "iq_fp": s["iq_fp"] + 2}, 160, "core", lambda s: s["iq_fp"] < 20),
    "STA IQ +2": (lambda s: {**s, "iq_sta": s["iq_sta"] + 2}, 160, "core", lambda s: s["iq_sta"] < 16),
    "LQ +8": (lambda s: {**s, "lq": s["lq"] + 8}, 320, "core", lambda s: s["lq"] < 64),
    "SQ +4": (lambda s: {**s, "sq": s["sq"] + 4}, 200, "core", lambda s: s["sq"] < 48),
    "completion buffer +8": (lambda s: {**s, "lqcb": s["lqcb"] + 8}, 64, "core", lambda s: s["lqcb"] < 48),
    "L1D MSHRs +4": (lambda s: {**s, "l1d_mshr": s["l1d_mshr"] + 4}, 300, "core", lambda s: s["l1d_mshr"] < 48),
    "LLTs +8": (lambda s: {**s, "llt": s["llt"] + 8}, 200, "core", lambda s: s["llt"] < 64),
    "L2 MSHRs +16": (lambda s: {**s, "l2_mshr": s["l2_mshr"] + 16}, 800, "SoC", lambda s: s["l2_mshr"] < 128),
}
# With static halves the window grows per thread, and M1 found that the window must be sized as a whole: single
# steps can each sit below the line while the whole step is above it. The second pass also offers a per-thread
# window step (ROB, LQ and SQ together) and a double ROB step.
V2_BUNDLES = {
    **V2_INCREMENTS,
    "window step (ROB +16, LQ +8, SQ +4)": (lambda s: {**s, "rob": s["rob"] + 16, "lq": s["lq"] + 8, "sq": s["sq"] + 4},
                                            480 + 320 + 200, "core", lambda s: s["rob"] < 192),
    "ROB +32": (lambda s: {**s, "rob": s["rob"] + 32}, 960, "core", lambda s: s["rob"] < 176),
}
GUARD = -0.25  # percent, at 30 and 250 cycles


def greedy(start=None, increments=None):
    """The acceptance rule on SMT2 throughput: from v1_freeze with threads=2, add one size increment per round,
    the one with the best WS_ref gain per LUT at 120 cycles among those whose gain (%) is at least their LUT
    increase (%) and that lose no more than 0.25% at 30 or 250 cycles. Stops when none qualifies."""
    increments = increments or V2_INCREMENTS
    state, rounds = dict(start or BASE), []
    while True:
        cands = {n: (f(state), cost(state) if callable(cost) else cost, scope)
                 for n, (f, cost, scope, ok) in increments.items() if ok(state)}
        collect([({**s, "dram_lat": 120}, a, b) for s in [state] + [c for c, _, _ in cands.values()]
                 for _, a, b in PAIRS])
        base = evaluate(state, 120, with_alone=False)["ws_ref"]
        rows = []
        for n, (c, cost, scope) in cands.items():
            gain = (evaluate(c, 120, with_alone=False)["ws_ref"] / base - 1) * 100
            share = cost / (SOC_LUTS if scope == "SoC" else CORE_LUTS) * 100
            rows.append({"increment": n, "gain_120": gain, "lut": cost, "scope": scope, "lut_share": share,
                         "ratio": gain / share})
        rows.sort(key=lambda r: -r["ratio"])
        chosen = None
        for r in rows:
            if r["gain_120"] < r["lut_share"]:
                break
            c = cands[r["increment"]][0]
            for lat in (30, 250):
                b0 = evaluate(state, lat, with_alone=False)["ws_ref"]
                r[f"gain_{lat}"] = (evaluate(c, lat, with_alone=False)["ws_ref"] / b0 - 1) * 100
            if r["gain_30"] >= GUARD and r["gain_250"] >= GUARD:
                chosen = r
                break
        rounds.append({"state": {k: state[k] for k in sorted(state) if k in TRACKED}, "ws_ref_120": base,
                       "candidates": rows, "chosen": chosen["increment"] if chosen else None})
        print(f"round {len(rounds)}: WS_ref {base:.4f} -> {chosen['increment'] if chosen else 'stop'}", flush=True)
        if not chosen:
            break
        state = cands[chosen["increment"]][0]
    return {"start": {k: (start or BASE)[k] for k in TRACKED}, "final": state, "rounds": rounds}


TRACKED = ("rob", "iq_a0", "iq_a1", "iq_ld", "iq_fp", "iq_sta", "lq", "sq", "lqcb", "l1d_mshr", "llt", "l2_mshr")


def lut_delta(sets, base=None):
    """Estimated LUT change of a configuration's sizes against v1_freeze (scripts/report.py per-entry costs):
    (core LUTs, SoC LUTs)."""
    base = base or V1F
    d = lambda k: sets.get(k, base[k]) - base[k]  # noqa: E731
    alu = d("iq_a0") + d("iq_a1") * (alu_queues(sets) - 1)
    core = (30 * d("rob") + 80 * (alu + d("iq_ld") + d("iq_fp") + d("iq_sta")) + 40 * d("lq")
            + 50 * d("sq") + 8 * d("lqcb") + 75 * d("l1d_mshr") + 25 * d("llt"))
    soc = 50 * d("l2_mshr")
    return core, soc


# SMT2 overhead per core in LUTs, beyond v1's thread hooks (plan section 6.3): (item, low, central, high, basis).
SMT_OVERHEAD = [
    ("Second rename map and committed map", 500, 800, 1100,
     "2 x (32 x 8 + 32 x 7) flip-flops; every rename read port selects from 64 entries instead of 32; restore paths"),
    ("Second set of 4 rename checkpoints", 400, 500, 600, "~125 LUTs per checkpoint, as in the M1 cost model"),
    ("Second FTQ, global history, RAS and fetch PC", 500, 700, 950,
     "32-entry FTQ and RAS in LUTRAM with their read ports, history register and repair, redirect muxing"),
    ("Per-thread instruction queue and decode-to-rename queue", 150, 300, 450,
     "the 16-entry instruction queue already sits in 32-deep LUTRAM (pointers only); a 6-uop holding queue per thread"),
    ("ICOUNT fetch arbitration, per-thread occupancy counters and caps", 200, 300, 450,
     "pre-issue uop counters, comparators, cap checks on the issue queues, MSHRs and long-latency tags"),
    ("TID tags and partitions in the ROB, LQ, SQ and completion buffer", 300, 500, 700,
     "per-partition head/tail pointers, TID match in the forwarding and ordering CAMs, TID-qualified kill"),
    ("Sibling stores on the snoop path; per-hart LR reservation (rule 4)", 50, 100, 150,
     "a committing store checks the sibling's executed loads through the existing snoop port"),
    ("Second CSR file, trap, interrupt, timer and debug state", 1500, 2000, 2800,
     "M/S CSRs, fcsr and 16 PMP entries per hart (PMP check logic shared), per-hart trap sequencing, mip/mie, debug"),
    ("Second set of performance counters", 600, 1000, 1300, "mcycle, minstret and 16 HPM counters per hart"),
    ("MMU: TID in TLB and walk-cache tags, per-thread walk requests", 100, 200, 300,
     "tags already sized for the TID in v1 (plan 4.10); a request queue per thread"),
]


# At 3-wide decode, 1.5 times as many rename read ports select between the two maps, and each thread's
# decode-to-rename queue holds 9 uops instead of 6 (low, central, high).
SMT_OVERHEAD_W3 = (200, 350, 500)


def smt_overhead(width=2):
    lo = sum(x[1] for x in SMT_OVERHEAD)
    mid = sum(x[2] for x in SMT_OVERHEAD)
    hi = sum(x[3] for x in SMT_OVERHEAD)
    if width >= 3:
        lo, mid, hi = lo + SMT_OVERHEAD_W3[0], mid + SMT_OVERHEAD_W3[1], hi + SMT_OVERHEAD_W3[2]
    return lo, mid, hi


# ---------------------------------------------------------------- the whole study


def study():
    res = json.loads(OUT.read_text()) if OUT.exists() else {}
    res.update({"isa": ISA, "pairs": [{"group": g, "a": a, "b": b, "name": pname(a, b)} for g, a, b in PAIRS],
                "v1_freeze": V1F, "smt_base": SMT_BASE, "core_luts": CORE_LUTS, "soc_luts": SOC_LUTS,
                "smt_overhead": {"items": SMT_OVERHEAD, "total": smt_overhead()}})
    configs = {}
    first = {"v1_freeze, SMT2": BASE, **policy_variants(BASE), **size_variants(BASE), **option_variants(BASE)}
    prefetch(list(first.values()), LATS)

    def run(name, sets, lats=LATS, with_alone=True):
        print(f"== {name}", flush=True)
        c = {"sets": sets, "by_lat": {}}
        for lat in lats:
            c["by_lat"][str(lat)] = evaluate(sets, lat, with_alone)
            print(f"   {lat}: {brief(c['by_lat'][str(lat)])}", flush=True)
        configs[name] = c

    for name, s in first.items():
        run(name, s)
    res["configs"] = configs
    OUT.write_text(json.dumps(res, indent=1))
    g = greedy()
    res["greedy"] = g
    OUT.write_text(json.dumps(res, indent=1))
    v2 = g["final"]
    second = {"v2 (greedy)": v2}
    second.update({f"v2, {n}": s for n, s in policy_variants(v2).items()
                   if n in ("round-robin fetch", "shared ROB/LQ/SQ/CB, 75% cap", "shared ROB/LQ/SQ/CB, no cap")})
    second.update({f"v2 {n}": s for n, s in option_variants(v2).items()})
    prefetch(list(second.values()), LATS)
    for name, s in second.items():
        run(name, s)
    res["configs"] = configs
    OUT.write_text(json.dumps(res, indent=1))
    print(f"wrote {OUT}")


def supplementary():
    """After the study: how window sharing interacts with the issue-queue cap (120 cycles, v1 sizes), and the
    greedy result's sensitivity to whole-window bundles and to sharing (all three latencies)."""
    res = json.loads(OUT.read_text())
    v2 = res["greedy"]["final"]
    grid = {}
    shapes = {"static halves": {"smt_part": 1}, "shared, 75% cap": {"smt_part": 0, "smt_win_cap": 75},
              "shared, no cap": {"smt_part": 0, "smt_win_cap": 100}}
    cfgs = [{**BASE, **w, "smt_iq_cap": c} for w in shapes.values() for c in (50, 75, 100)]
    prefetch(cfgs, (120,), with_alone=False)
    for wn, w in shapes.items():
        grid[wn] = {str(c): evaluate({**BASE, **w, "smt_iq_cap": c}, 120, with_alone=False)["ws_ref"]
                    for c in (50, 75, 100)}
    print(json.dumps(grid, indent=1))
    step = lambda s, k: {**s, "rob": s["rob"] + 16 * k, "lq": s["lq"] + 8 * k, "sq": s["sq"] + 4 * k}  # noqa: E731
    bundles = {
        "v2 + one window step (ROB +16, LQ +8, SQ +4)": step(v2, 1),
        "v2 + two window steps": step(v2, 2),
        "v2 + three window steps": step(v2, 3),
        "v2 + three window steps, 32 L1D MSHRs, 32 LLTs": {**step(v2, 3), "l1d_mshr": 32, "llt": 32},
    }
    prefetch(list(bundles.values()), LATS)
    out = {}
    for n, s in bundles.items():
        out[n] = {"sets": s, "by_lat": {str(lat): evaluate(s, lat) for lat in LATS}}
        print(n, {lat: round(out[n]["by_lat"][str(lat)]["ws_ref"], 4) for lat in LATS}, flush=True)
    res = json.loads(OUT.read_text())
    res["supplementary"] = {"sharing_by_iq_cap_120": grid, "bundles": out}
    OUT.write_text(json.dumps(res, indent=1))
    print(f"wrote {OUT}")


def validate():
    """SMT2 consistency checks at 120 cycles (report section 3) -> the "validation" section of the results."""
    s = {**BASE, "dram_lat": 120}
    out = {}
    # 1. Next to a sibling that barely loads the core (tests/idle.c, restarted over and over), a program should run
    #    like a single thread with half the partitioned structures (issue queues uncapped, as in a single thread).
    half = {k: V1F[k] // 2 for k in ("rob", "lq", "sq", "lqcb")}
    progs = ["ms_gather", "ms_stride", "ms_spmv", "ms_chase8", "ms_copy", "coremark_A", "embench_huffbench"]
    s_idle = {**s, "smt_iq_cap": 100}
    collect([(s_idle, w, "idle") for w in progs])
    st = alone({**V1F, **half}, 120)["ipc"]
    out["idle_sibling"] = {}
    for w in progs:
        r = get(s_idle, w, "idle")
        g = r["threads"][0]["region"]
        ipc = g["instr"] / g["cycles"]
        out["idle_sibling"][w] = {"smt": ipc, "single_half": st[w], "ratio": ipc / st[w],
                                  "sibling_laps": r["threads"][1]["laps"]}
    # 2. Thread order: (A, B) against (B, A).
    sym = [("ms_gather", "coremark_A"), ("ms_chase8", "ms_stream"), ("dhrystone", "embench_huffbench"),
           ("ms_spmv", "ms_stride"), ("ms_copy", "embench_minver")]
    collect([(s, a, b) for a, b in sym] + [(s, b, a) for a, b in sym])
    ref = alone(V1F, 120)["ipc"]
    out["symmetry"] = {}
    for a, b in sym:
        m1, m2 = pair_metrics(get(s, a, b), None, ref), pair_metrics(get(s, b, a), None, ref)
        out["symmetry"][pname(a, b)] = {"ipc_ab": m1["ipc"], "ipc_ba": m2["ipc"][::-1], "ws_ref_ab": m1["ws_ref"],
                                        "ws_ref_ba": m2["ws_ref"]}
    # 3. Shared windows capped at 50% must equal static halves (same limits, different code path).
    b50 = {**BASE, "smt_part": 0, "smt_win_cap": 50}
    e0, e50 = evaluate(BASE, 120, with_alone=False), evaluate(b50, 120, with_alone=False)
    out["cap50_equals_static"] = all(e0["pairs"][p]["ipc"] == e50["pairs"][p]["ipc"] for p in e0["pairs"])
    # 4. IPC over the overlap window (both first-run regions open) against IPC over each first-run region.
    d = [abs(m["ipc_overlap"][i] / m["ipc"][i] - 1) for m in e0["pairs"].values() if "ipc_overlap" in m
         for i in range(2)]
    ws_ov = []
    for p, m in e0["pairs"].items():
        g, a, b = next(x for x in PAIRS if pname(x[1], x[2]) == p)
        if "ipc_overlap" in m:
            ws_ov.append((p, m["ws_ref"], m["ipc_overlap"][0] / ref[a] + m["ipc_overlap"][1] / ref[b]))
    out["overlap_vs_region"] = {"threads": len(d), "mean_abs_ipc_diff": sum(d) / len(d), "max_abs_ipc_diff": max(d),
                                "ws_ref_region": gm(x[1] for x in ws_ov), "ws_ref_overlap": gm(x[2] for x in ws_ov)}
    # 5. Two threads never exceed the decode width.
    out["max_pair_throughput"] = max(m["throughput"] for m in e0["pairs"].values())
    res = json.loads(OUT.read_text()) if OUT.exists() else {}
    res["validation"] = out
    OUT.write_text(json.dumps(res, indent=1))
    print(json.dumps(out, indent=1))


def bundles_pass():
    """The greedy pass again with whole-window steps; its result is evaluated like the first pass's."""
    g = greedy(increments=V2_BUNDLES)
    res = json.loads(OUT.read_text())
    res["greedy_bundles"] = g
    OUT.write_text(json.dumps(res, indent=1))
    v2 = g["final"]
    named = {"v2b (greedy with window steps)": v2}
    named.update({f"v2b, {n}": s for n, s in policy_variants(v2).items()
                  if n in ("round-robin fetch", "shared ROB/LQ/SQ/CB, 75% cap", "shared ROB/LQ/SQ/CB, no cap")})
    named.update({f"v2b {n}": s for n, s in option_variants(v2).items()})
    prefetch(list(named.values()), LATS)
    res = json.loads(OUT.read_text())
    for n, s in named.items():
        res["configs"][n] = {"sets": s, "by_lat": {str(lat): evaluate(s, lat) for lat in LATS}}
        print(n, {lat: round(res["configs"][n]["by_lat"][str(lat)]["ws_ref"], 4) for lat in LATS}, flush=True)
    OUT.write_text(json.dumps(res, indent=1))
    print(f"wrote {OUT}")


def width3_pass():
    """Plan section 6.2 rule 12: a 2-thread, 3-wide core stays a valid configuration, with its per-thread structures
    sized for both. The same greedy pass with whole-window steps, from the v1 freeze with 3-wide decode/rename/commit,
    a third ALU and threads=2; then that core at all three latencies."""
    g = greedy(start={**BASE, **W3}, increments=V2_BUNDLES)
    res = json.loads(OUT.read_text())
    res["greedy_w3"] = g
    OUT.write_text(json.dumps(res, indent=1))
    v3 = g["final"]
    named = {"3-wide SMT2 (greedy with window steps)": v3}
    prefetch(list(named.values()), LATS)
    res = json.loads(OUT.read_text())
    for n, s in named.items():
        res["configs"][n] = {"sets": s, "by_lat": {str(lat): evaluate(s, lat) for lat in LATS}}
        print(n, {lat: round(res["configs"][n]["by_lat"][str(lat)]["ws_ref"], 4) for lat in LATS}, flush=True)
    OUT.write_text(json.dumps(res, indent=1))
    print(f"wrote {OUT}")


def main():
    if "--width3" in sys.argv:
        return width3_pass()
    if "--validate" in sys.argv:
        return validate()
    if "--supplementary" in sys.argv:
        return supplementary()
    if "--bundles" in sys.argv:
        return bundles_pass()
    if "--explore" in sys.argv:
        return explore()
    if "--greedy" in sys.argv:
        g = greedy()
        res = json.loads(OUT.read_text()) if OUT.exists() else {}
        res["greedy"] = g
        OUT.write_text(json.dumps(res, indent=1))
        return print(f"wrote {OUT}")
    if "--tables" in sys.argv:
        import smt_tables  # noqa: PLC0415
        return smt_tables.main()
    return study()


if __name__ == "__main__":
    main()
