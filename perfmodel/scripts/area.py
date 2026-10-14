"""Area-recovery study (plan section 8.5, D18): the IPC that each IPC-costing lever gives up on the two SMT2
release configurations, ranked by IPC lost per LUT saved, and the dependency census behind "readiness only over
the columns a queue can depend on".

  python3 scripts/area.py              # every lever alone, at 30/120/250 cycles -> results/area_recovery.json
  python3 scripts/area.py --combos     # cumulative combinations in rank order, and the v2 re-plan options
  python3 scripts/area.py --census     # dependency census on v1 and v2 (120 cycles)
  python3 scripts/area.py --tables     # results/area_tables.md (generated tables for docs/perf/area_recovery.md)

Configurations (sizes from results/smt2_rv64gc.json, the SMT2 study):
  v1  smt2, the first release: ROB 80, LQ 24 + completion buffer 8, SQ 20 (static halves), 24 LLTs, issue queues
      10/10/6/4/10 shared with a 75% per-thread cap, ICOUNT fetch.
  v2  smt2_w3: v1 with 3-wide decode/rename/commit and a third ALU, sized by the same rule (ROB 96, LQ 32 +
      completion buffer 16, SQ 20, 24 LLTs).
Metrics, at 30, 120 and 250 cycles (120 decides):
  WS_ref  weighted speedup on the SMT2 study's 42 pairs, against ST running one program at a time (throughput);
  ST IPC  suite IPC of the same core with SMT off (one thread, partitions merged).
Every configuration is tanager_v1 plus explicit settings, so results share the SMT2 study's caches.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dse  # noqa: E402
import smt  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "area_recovery.json"
TABLES = ROOT / "results" / "area_tables.md"
LATS = (30, 120, 250)

_study = json.loads(smt.OUT.read_text())
V1 = dict(_study["greedy_bundles"]["final"])   # the release (plan section 6.5)
V2 = dict(_study["greedy_w3"]["final"])        # smt2_w3 (SMT2 study section 9)
assert (V1["rob"], V1["lq"], V1["sq"], V1["lqcb"], V1["llt"]) == (80, 24, 20, 8, 24), "v1 sizes moved"
assert (V2["rob"], V2["lq"], V2["sq"], V2["lqcb"], V2["llt"], V2["decode_width"]) == (96, 32, 20, 16, 24, 3)
# The radix-4 divide/sqrt as built (FPU track): 18 / 33 cycles, unpipelined (the D17 fallback).
R4DIV = {"lat_fdiv_s": 18, "lat_fdiv_d": 33, "lat_fsqrt_s": 18, "lat_fsqrt_d": 33, "fdiv_ii": 0}

# Per-core LUTs that percentages are taken against: the midpoint of each SoC's projection after the planned
# levers (v1 99-110K, v2 113-128K; spikes section 10), less the uncore (13.3K), over two cores.
UNCORE = 13300
CORE_BASE = {"v1": ((99000 + 110000) / 2 - UNCORE) / 2, "v2": ((113000 + 128000) / 2 - UNCORE) / 2}


def levers_v1(b):
    return {
        "ALU queues 8 rows": {**b, "iq_a0": 8, "iq_a1": 8},
        "ALU queues 6 rows": {**b, "iq_a0": 6, "iq_a1": 6},
        "FP queue 8 rows": {**b, "iq_fp": 8},
        "FP queue 6 rows": {**b, "iq_fp": 6},
        "LD queue 4 rows": {**b, "iq_ld": 4},
        "STA queue 2 rows": {**b, "iq_sta": 2},
        "ROB 64 (halves of 32)": {**b, "rob": 64},
        "LQ 16 (halves of 8)": {**b, "lq": 16},
        "SQ 16 (halves of 8)": {**b, "sq": 16},
        "SQ 12 (halves of 6)": {**b, "sq": 12},
        "LLTs 16": {**b, "llt": 16},
        "R10: 4 checkpoints shared by the threads": {**b, "smt_ckpt_shared": 1},
        "checkpoints 2 per thread": {**b, "ckpt": 2},
        "R9: forwarding only from same-address, same-size stores": {**b, "fwd_strict": 1},
        "banked queues: rows see one ROB half": {**b, "iq_bank": 1},
        "banked queues and LLTs": {**b, "iq_bank": 1, "iq_bank_llt": 1},
        "radix-4 divide/sqrt (D17 fallback)": {**b, **R4DIV},
        **wake_tag_levers(b),
    }


TAGS = 16  # the pool size the combinations use (12 and 24 are measured as sensitivity)


def wake_tag_levers(b):
    """Rows wake on F tags for multi-cycle fixed-latency producers instead of one column per ROB entry."""
    return {f"wakeup tags: {f} instead of {b['rob']} ROB columns": {**b, "wake_tags": f} for f in (12, 16, 24)}


def levers_v2(b):
    return {
        "ALU queues 8 rows": {**b, "iq_a0": 8, "iq_a1": 8},   # IQ-A2 follows IQ-A1
        "ALU queues 6 rows": {**b, "iq_a0": 6, "iq_a1": 6},
        "FP queue 8 rows": {**b, "iq_fp": 8},
        "ROB 80 (halves of 40)": {**b, "rob": 80},
        "ROB 64 (halves of 32)": {**b, "rob": 64},
        "LQ 24 (halves of 12)": {**b, "lq": 24},
        "completion buffer 8": {**b, "lqcb": 8},
        "LLTs 16": {**b, "llt": 16},
        "v1's window (ROB 80, LQ 24, completion buffer 8)": {**b, "rob": 80, "lq": 24, "lqcb": 8},
        "R11: ALU2 reads through the STA and shared ports": {**b, "rf_share_a2": 1},
        "R12: third decoder for the common subset only": {**b, "dec_full": 2},
        "R13: simple third ALU": {**b, "alu3_simple": 1},
        "R10: 4 checkpoints shared by the threads": {**b, "smt_ckpt_shared": 1},
        "R9: forwarding only from same-address, same-size stores": {**b, "fwd_strict": 1},
        "banked queues: rows see one ROB half": {**b, "iq_bank": 1},
        "radix-4 divide/sqrt (D17 fallback)": {**b, **R4DIV},
        **wake_tag_levers(b),
    }


# Mutually exclusive levers: a combination takes at most one of each group.
EXCLUSIVE = [("ALU queues 8 rows", "ALU queues 6 rows"), ("FP queue 8 rows", "FP queue 6 rows"),
             ("SQ 16 (halves of 8)", "SQ 12 (halves of 6)"), ("ROB 80 (halves of 40)", "ROB 64 (halves of 32)",
                                                              "v1's window (ROB 80, LQ 24, completion buffer 8)"),
             ("LQ 24 (halves of 12)", "v1's window (ROB 80, LQ 24, completion buffer 8)"),
             ("completion buffer 8", "v1's window (ROB 80, LQ 24, completion buffer 8)"),
             ("banked queues: rows see one ROB half", "banked queues and LLTs"),
             ("R10: 4 checkpoints shared by the threads", "checkpoints 2 per thread")]


def exclusive(a, b):
    """Whether two levers cannot be combined: an EXCLUSIVE group, or two ways to cut the scheduler's columns
    (wakeup tags of any size, banked queues), which the model does not combine."""
    cut = lambda n: n.startswith("wakeup tags") or n.startswith("banked queues")  # noqa: E731
    return any(a in g and b in g for g in EXCLUSIVE) or (cut(a) and cut(b))


def st_w3_configs():
    """3-wide without SMT2 (st_w3), single thread: the v2 alternative the plan names."""
    return {
        "st_w3, v1 freeze sizes (ROB 48)": {**smt.V1F, **smt.W3},
        "st_w3, v1's window (ROB 80)": smt.single({**V1, **smt.W3}),
        "st_w3, v2's window (ROB 96)": smt.single(V2),
    }


# ---------------------------------------------------------------- LUT model (per core)

# Scheduler (every issue queue, the woken vector, wakeup delay lines) fitted to five MX builds, spike S2's
# st 6,425, smt2 8,895, smt2_w3 12,515 and smt2_w3 with 8-row ALU queues 10,986, and the nightly budget run's
# st_w3 8,842 (docs/perf/budgets.md), each within 0.14K:
#   LUTs = 1.369 x rows x wakeup columns + 1.404 x rows x MX columns + 338 x ALU queues + 1.26K
# with rows = every queue's rows (40 at smt2, 50 at smt2_w3: tg_cfg_smt2_w3.sv), wakeup columns = ROB entries +
# LLTs and MX columns = ALU-queue rows. Six other forms fitted to the same builds put the wakeup tags' saving
# 0-16% above this one at smt2 and within 3% at smt2_w3. A banked queue gives each row only its bank's columns:
# half the ROB, all LLTs (or half with iq_bank_llt) and half the MX columns.
def sched_luts(s):
    a2 = (s.get("iq_a2") or s["iq_a1"]) if s.get("alu3") else 0
    alu_rows = s["iq_a0"] + s["iq_a1"] + a2
    rows = alu_rows + s["iq_ld"] + s["iq_sta"] + s["iq_fp"]
    banked = s.get("iq_bank", 0)
    rob_cols = s["rob"] / 2 if banked else s["rob"]
    if s.get("wake_tags", 0):  # the tag pool's columns replace the ROB columns
        rob_cols = s["wake_tags"]
    llt_cols = s["llt"] / 2 if banked and s.get("iq_bank_llt") else s["llt"]
    mx_cols = alu_rows / 2 if banked else alu_rows
    return 1.369 * rows * (rob_cols + llt_cols) + 1.404 * rows * mx_cols + 338 * (3 if a2 else 2) + 1261


# Window storage outside the scheduler: ROB status and payload ~10 LUTs per entry (estimate; the commit-time
# payload is in BRAM by R7), LLT pool ~10 per tag (estimate), and scripts/report.py's per-entry costs for the LQ
# CAM 40, SQ 50, completion buffer 8 and checkpoint 125 (rename tables, free-list heads, LQ/SQ tails).
def window_luts(s, threads=None):
    threads = threads or s.get("threads", 1)
    ckpts = s["ckpt"] * (1 if s.get("smt_ckpt_shared") else threads)
    return 10 * s["rob"] + 10 * s["llt"] + 40 * s["lq"] + 50 * s["sq"] + 8 * s["lqcb"] + 125 * ckpts


# Levers outside the scheduler and window model: per-core saving (low, high) and its source.
FIXED = {
    "fwd_strict": (200, 300, "R9: plan section 8.5 estimate"),
    "rf_share_a2": (740, 740, "R11: spike S3, measured (8,713 -> 7,977 LUTs at st_w3)"),
    "dec_full": (150, 250, "R12: plan section 8.5 estimate"),
    "alu3_simple": (300, 500, "R13: plan section 8.5 estimate"),
    "fdiv": (1411, 1411, "radix-4: FPU track, measured (Goldschmidt 3,125 vs radix-4 1,714 LUTs)"),
    # wakeup tags: the pool's free list, a tag field in the producer table, the tag columns' clear on release
    # (~4 LUTs per column per queue, spike S2 section 4.1) and the W bits: 0.5-0.8K of added logic (estimate)
    "wake_tags": (-800, -500, "wakeup tags: tag pool, producer-table field and column clear, +0.5-0.8K (estimate)"),
}


def lut_saving(base, s):
    """(low, high, basis): estimated LUTs saved per core by going from base to s."""
    sched = sched_luts(base) - sched_luts(s)
    win = window_luts(base) - window_luts(s)
    lo = hi = sched + win
    basis = []
    if abs(sched) > 1:
        banked = s.get("iq_bank", 0) and not base.get("iq_bank", 0)
        if banked:  # a structural change with its own steering logic: credit 60-100% of the modelled halving
            lo -= 0.4 * sched
        basis.append(f"scheduler {sched / 1000:.2f}K (S2 fit{', credited 60-100%' if banked else ''})")
    if abs(win) > 1:
        basis.append(f"window storage {win / 1000:.2f}K (per-entry estimates)")
    for k, (a, b, src) in FIXED.items():
        if k == "fdiv":
            changed = s.get("fdiv_ii") == 0 and base.get("fdiv_ii") != 0
        else:
            changed = bool(s.get(k, 0)) and not base.get(k, 0)
        if changed:
            lo += a
            hi += b
            basis.append(src)
    return lo, hi, "; ".join(basis)


def st_w3_saving(s):
    """LUTs per core that a 3-wide single-thread core saves against v2: scheduler and window, plus the SMT2
    overhead at 3-wide (scripts/smt.py: second rename maps and checkpoints, FTQ/RAS, CSR file, counters ...)."""
    olo, omid, ohi = smt.smt_overhead(3)
    sched = sched_luts(V2) - sched_luts(s)
    win = window_luts({**V2, "ckpt": 0}) - window_luts({**s, "ckpt": 0}, threads=1)  # checkpoints: in the overhead
    return sched + win + olo, sched + win + ohi, sched + win + omid


# ---------------------------------------------------------------- evaluation


def evaluate_smt(sets):
    """SMT2 configuration: WS_ref over the pairs and single-thread (SMT off) suite IPC, at every latency."""
    out = {}
    for lat in LATS:
        e = smt.evaluate(sets, lat, with_alone=True)
        out[str(lat)] = {"ws_ref": e["ws_ref"], "ws": e["ws"], "fair": e["fair"],
                         "groups": {g: e["groups"][g]["ws_ref"] for g in smt.GROUPS},
                         "st_ipc": e["alone_suite_ipc"], "st": e["alone"],
                         "st_ipc_by": smt.alone(sets, lat)["ipc"],
                         "pairs": {p: {"ws_ref": m["ws_ref"], "ipc": m["ipc"]} for p, m in e["pairs"].items()}}
    return out


def evaluate_st(sets):
    """Single-thread configuration: suite IPC, and throughput running each pair one program at a time."""
    import smt_tables  # noqa: PLC0415
    out = {}
    for lat in LATS:
        a = smt.alone(sets, lat)
        out[str(lat)] = {"ws_ref": smt_tables.time_shared(sets, lat), "st_ipc": a["suite_ipc"],
                         "st": {k: a[k] for k in ("suite_ipc", "kernels_ipc", "embench_ipc", "memsuite_ipc",
                                                  "coremark_A", "dmips")}, "st_ipc_by": a["ipc"]}
    return out


def collect_st(configs):
    singles = [{**smt.single(s), "dram_lat": lat} for s in configs for lat in LATS]
    uniq = {dse.key(smt.ISA, smt.PRESET, s)[0]: s for s in singles}
    dse.collect([(smt.PRESET, s) for s in uniq.values()], smt.ISA)


def load():
    return json.loads(OUT.read_text()) if OUT.exists() else {}


def save(res):
    OUT.write_text(json.dumps(res, indent=1))
    print(f"wrote {OUT}", flush=True)


def delta(r, b, lat="120"):
    """(throughput change %, single-thread change %) of a result against its base."""
    return (r[lat]["ws_ref"] / b[lat]["ws_ref"] * 100 - 100, r[lat]["st_ipc"] / b[lat]["st_ipc"] * 100 - 100)


def run_singles():
    res = load()
    res.update({"v1": V1, "v2": V2, "lats": LATS, "core_base": CORE_BASE})
    l1, l2 = levers_v1(V1), levers_v2(V2)
    st_cfgs = st_w3_configs()
    smt.prefetch([V1, V2] + list(l1.values()) + list(l2.values()), LATS)
    collect_st(list(st_cfgs.values()) + [smt.V1F])
    res["base"] = {"v1": evaluate_smt(V1), "v2": evaluate_smt(V2), "st": evaluate_st(smt.V1F)}
    for tag, levers, base in (("v1", l1, V1), ("v2", l2, V2)):
        res[f"levers_{tag}"] = {}
        for name, s in levers.items():
            lo, hi, basis = lut_saving(base, s)
            r = evaluate_smt(s)
            res[f"levers_{tag}"][name] = {"sets": s, "luts_saved": [lo, hi], "basis": basis, "by_lat": r}
            dw, ds = delta(r, res["base"][tag])
            print(f"{tag} {name}: WS_ref {dw:+.2f}%  ST {ds:+.2f}%  saves {lo / 1000:.2f}-{hi / 1000:.2f}K", flush=True)
    res["st_w3"] = {}
    for name, s in st_cfgs.items():
        lo, hi, mid = st_w3_saving(s)
        res["st_w3"][name] = {"sets": s, "luts_saved_vs_v2": [lo, hi, mid], "by_lat": evaluate_st(s)}
    save(res)


# ---------------------------------------------------------------- ranking and combinations


def ranked(res, tag):
    """Levers of one configuration ranked by IPC lost per 1K LUTs saved (the larger of the throughput and the
    single-thread loss at 120 cycles, against the midpoint of the saving)."""
    base = res["base"][tag]
    rows = []
    for name, L in res[f"levers_{tag}"].items():
        dw, ds = delta(L["by_lat"], base)
        lo, hi = L["luts_saved"]
        mid = (lo + hi) / 2
        loss = max(0.0, -dw, -ds)
        rows.append({"name": name, "dws": dw, "dst": ds, "lo": lo, "hi": hi, "mid": mid, "loss": loss,
                     "per_k": loss / (mid / 1000) if mid > 0 else float("inf"),
                     "share": mid / CORE_BASE[tag] * 100})
    rows.sort(key=lambda r: (r["per_k"], -r["mid"]))
    return rows


def exclusive_ok(chosen, name):
    return not any(exclusive(name, c) for c in chosen)


def cumulative(res, tag, levers, limit):
    """Greedy combination: each step adds the lever with the least IPC lost per 1K LUTs saved, its saving taken
    against the configuration so far (so a lever whose columns the wakeup tags already removed saves less), while
    that ratio stays at or below `limit`. The loss is each lever's own, measured alone. Returns the steps as
    (levers, configuration, incremental saving (lo, hi))."""
    cfg = {"v1": V1, "v2": V2}[tag]
    base = res["base"][tag]
    chosen, steps, state = [], [], dict(cfg)
    while True:
        best = None
        for name, L in res[f"levers_{tag}"].items():
            if name in chosen or not exclusive_ok(chosen, name):
                continue
            if name.startswith("wakeup tags") and f" {TAGS} " not in name:
                continue
            dw, ds = delta(L["by_lat"], base)
            loss = max(0.0, -dw, -ds)
            nxt = {**state, **{k: v for k, v in levers[name].items() if cfg.get(k) != v}}
            lo, hi, _ = lut_saving(state, nxt)
            mid = (lo + hi) / 2
            if mid <= 50 or loss / (mid / 1000) > limit:
                continue
            key = (loss / (mid / 1000), -mid)
            if best is None or key < best[0]:
                best = (key, name, nxt, (lo, hi))
        if best is None:
            return steps
        chosen.append(best[1])
        state = best[2]
        steps.append((list(chosen), dict(state), best[3]))


# The v2 re-plan options (per core): smt2_w3 with wakeup tags and the levers with the largest saving per IPC,
# without the tags for comparison, and st_w3 (st_w3_configs).
def v2_options():
    r = {**V2, "rf_share_a2": 1, "dec_full": 2, "alu3_simple": 1}
    t = {**r, "wake_tags": 16}
    return {
        "smt2_w3, wakeup tags (16)": {**V2, "wake_tags": 16},
        "smt2_w3, wakeup tags, R11-R13": t,
        "smt2_w3, wakeup tags, R11-R13, 8-row ALU queues": {**t, "iq_a0": 8, "iq_a1": 8},
        "smt2_w3, wakeup tags, R11-R13, 8-row ALU queues, v1's window": {**t, "iq_a0": 8, "iq_a1": 8, "rob": 80,
                                                                           "lq": 24, "lqcb": 8},
        "smt2_w3 without tags: R11-R13, 8-row ALU queues": {**r, "iq_a0": 8, "iq_a1": 8},
        "smt2_w3 without tags: R11-R13, 8-row ALU queues, ROB 64 / LQ 24 / CB 8": {**r, "iq_a0": 8, "iq_a1": 8,
                                                                                    "rob": 64, "lq": 24, "lqcb": 8},
    }


# Banked queues need a single-thread mode. iq_bank models steering by producer half; the alternative confines
# one thread to one ROB half (all rows switched to that half's columns by a 2:1 mux per bank column).
def st_alternatives():
    return {"v1 banked, single thread on half the ROB (40)": {**smt.single(V1), "rob": V1["rob"] // 2},
            "v2 banked, single thread on half the ROB (48)": {**smt.single(V2), "rob": V2["rob"] // 2}}


def run_combos():
    res = load()
    alts = st_alternatives()
    st_tags = {f"ST with {f} wakeup tags": {**smt.V1F, "wake_tags": f} for f in (12, 16)}
    collect_st(list(alts.values()) + list(st_tags.values()))
    res["st_alt"] = {name: {"sets": s, "by_lat": evaluate_st(s)} for name, s in alts.items()}
    res["st_tags"] = {name: {"sets": s, "by_lat": evaluate_st(s),
                             "luts_saved": sched_luts(smt.V1F) - sched_luts(s)} for name, s in st_tags.items()}
    out = {}
    for tag, base, levers in (("v1", V1, levers_v1(V1)), ("v2", V2, levers_v2(V2))):
        steps = cumulative(res, tag, levers, limit=100000 / CORE_BASE[tag])  # the reverse rule
        smt.prefetch([s for _, s, _ in steps], LATS)
        out[tag] = []
        for names, s, inc in steps:
            lo, hi, basis = lut_saving(base, s)
            r = evaluate_smt(s)
            out[tag].append({"levers": names, "sets": s, "luts_saved": [lo, hi], "step_saved": list(inc),
                             "basis": basis, "by_lat": r})
            dw, ds = delta(r, res["base"][tag])
            print(f"{tag} +{names[-1]}: WS_ref {dw:+.2f}%  ST {ds:+.2f}%  saves {lo / 1000:.2f}-{hi / 1000:.2f}K",
                  flush=True)
    # IPC first: with wakeup tags a ROB entry costs only its storage, so the window steps the SMT2 study rejected
    # at ~1K LUTs (its last round: ROB +16 +0.79%, the window step +1.84%) cost far less.
    ipc = {"v1, wakeup tags, ROB 96 (halves of 48)": {**V1, "wake_tags": TAGS, "rob": 96},
           "v1, wakeup tags, window step (ROB 96, LQ 32, SQ 24)": {**V1, "wake_tags": TAGS, "rob": 96, "lq": 32,
                                                                    "sq": 24}}
    smt.prefetch(list(ipc.values()), LATS)
    out["ipc_first"] = {}
    for name, s in ipc.items():
        lo, hi, basis = lut_saving(V1, s)
        out["ipc_first"][name] = {"sets": s, "luts_saved": [lo, hi], "basis": basis, "by_lat": evaluate_smt(s)}
    opts = v2_options()
    smt.prefetch(list(opts.values()), LATS)
    out["v2_options"] = {}
    for name, s in opts.items():
        lo, hi, basis = lut_saving(V2, s)
        out["v2_options"][name] = {"sets": s, "luts_saved": [lo, hi], "basis": basis, "by_lat": evaluate_smt(s)}
        dw, ds = delta(out["v2_options"][name]["by_lat"], res["base"]["v2"])
        print(f"v2 option {name}: WS_ref {dw:+.2f}%  ST {ds:+.2f}%  saves {lo / 1000:.2f}-{hi / 1000:.2f}K", flush=True)
    res["combos"] = out
    save(res)


# ---------------------------------------------------------------- dependency census


def census():
    """Which wakeup columns each queue's rows actually wait on (census = 1, 120 cycles): over the 42 pairs
    (SMT2) and over the single-thread suite on the same core with SMT off."""
    res = load()
    out = {}

    def add(tot, cen):
        for q, c in cen.items():
            t = tot.setdefault(q, {})
            for k, v in c.items():
                if k == "rob_from":
                    f = t.setdefault("rob_from", {})
                    for p, n in v.items():
                        f[p] = f.get(p, 0) + n
                else:
                    t[k] = t.get(k, 0) + v

    for tag, base in (("v1", V1), ("v2", V2)):
        s = {**base, "census": 1, "dram_lat": 120}
        data = smt.collect([(s, a, b) for _, a, b in smt.PAIRS])
        tot = {}
        for _, a, b in smt.PAIRS:
            add(tot, data[smt.pair_key(s, a, b)[0]].get("census", {}))
        st = {**smt.single(base), "census": 1, "dram_lat": 120}
        rs = dse.collect([(smt.PRESET, st)], smt.ISA)[dse.key(smt.ISA, smt.PRESET, st)[0]]
        tot_st = {}
        for r in rs:
            add(tot_st, r.get("census", {}))
        out[tag] = {"smt2_pairs": tot, "single_thread": tot_st}
        print(tag, json.dumps(out[tag]), flush=True)
    res["census"] = out
    save(res)


def main():
    if "--census" in sys.argv:
        return census()
    if "--combos" in sys.argv:
        return run_combos()
    if "--tables" in sys.argv:
        import area_tables  # noqa: PLC0415
        return area_tables.main()
    return run_singles()


if __name__ == "__main__":
    main()
