"""Area-recovery study (plan section 8.5, D18): the IPC that each IPC-costing lever gives up on the two SMT2
release configurations, ranked by IPC lost per LUT saved, and the dependency census behind "readiness only over
the columns a queue can depend on".

  python3 scripts/area.py              # every lever alone, at 30/120/250 cycles -> results/area_recovery.json
  python3 scripts/area.py --combos     # cumulative combinations in rank order (after the single levers)
  python3 scripts/area.py --census     # dependency census on v1 and v2 (120 cycles)
  python3 scripts/area.py --tables     # docs/perf/area_tables.md (generated)

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
import smt  # noqa: E402
import tgrun  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "area_recovery.json"
LATS = (30, 120, 250)

_study = json.loads(smt.OUT.read_text())
V1 = dict(_study["greedy_bundles"]["final"])   # the release (plan section 6.5)
V2 = dict(_study["greedy_w3"]["final"])        # smt2_w3 (SMT2 study section 9)
assert (V1["rob"], V1["lq"], V1["sq"], V1["lqcb"], V1["llt"]) == (80, 24, 20, 8, 24), "v1 sizes moved"
assert (V2["rob"], V2["lq"], V2["sq"], V2["lqcb"], V2["llt"], V2["decode_width"]) == (96, 32, 20, 16, 24, 3)
ST = dict(smt.V1F)                             # the single-thread bring-up configuration
STW3 = {**smt.V1F, **smt.W3}                   # 3-wide without SMT2, ST sizes
# The radix-4 divide/sqrt as built (FPU track): 18 / 33 cycles single / double, unpipelined (D17's fallback).
R4DIV = {"lat_fdiv_s": 18, "lat_fdiv_d": 33, "lat_fsqrt_s": 18, "lat_fsqrt_d": 33, "fdiv_ii": 0}


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
        "thread-banked queues: rows read their thread's ROB half": {**b, "smt_iq_cap": 50},
        "thread-banked queues and LLTs": {**b, "smt_iq_cap": 50, "smt_llt_cap": 50},
        "radix-4 divide/sqrt (D17 fallback)": {**b, **R4DIV},
    }


def levers_v2(b):
    return {
        "ALU queues 8 rows": {**b, "iq_a0": 8, "iq_a1": 8},   # IQ-A2 follows IQ-A1
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
        "thread-banked queues: rows read their thread's ROB half": {**b, "smt_iq_cap": 50},
        "thread-banked queues and LLTs": {**b, "smt_iq_cap": 50, "smt_llt_cap": 50},
        "radix-4 divide/sqrt (D17 fallback)": {**b, **R4DIV},
    }


def st_w3_configs():
    """3-wide without SMT2 (st_w3), single thread: the v2 alternative the plan names."""
    return {
        "st_w3 (ST sizes)": STW3,
        "st_w3 with R11, R12, R13 and 8-row ALU queues": {**STW3, "rf_share_a2": 1, "dec_full": 2, "alu3_simple": 1,
                                                          "iq_a0": 8, "iq_a1": 8},
    }


# ---------------------------------------------------------------- LUT model (per core)

# Scheduler (every issue queue, the woken vector, wakeup delay lines) fitted to spike S2's four MX builds:
#   st 6.4K, smt2 8.9K, smt2_w3 12.5K, smt2_w3 with 8-row ALU queues 11.0K (each within 0.15K):
#   LUTs = 1.56 x rows x wakeup columns per row + 0.85 x rows x MX columns per row + 1.7K
# A thread-banked queue gives each row only its thread's columns: half the ROB columns, all LLTs or (with
# per-thread LLTs) half of them, and half the MX columns.
def sched_luts(s):
    a2 = (s.get("iq_a2") or s["iq_a1"]) if s.get("alu3") else 0
    alu_rows = s["iq_a0"] + s["iq_a1"] + a2
    rows = alu_rows + s["iq_ld"] + s["iq_sta"] + s["iq_fp"]
    banked = s.get("threads", 1) == 2 and s.get("smt_iq_cap", 100) <= 50
    rob_cols = s["rob"] / 2 if banked else s["rob"]
    llt_cols = s["llt"] / 2 if banked and s.get("smt_llt_cap", 100) <= 50 else s["llt"]
    mx_cols = alu_rows / 2 if banked else alu_rows
    return 1.56 * rows * (rob_cols + llt_cols) + 0.85 * rows * mx_cols + 1700


# Window storage outside the scheduler (scripts/report.py per-entry costs, without their scheduler column):
# ROB payload and completion bits ~10 LUTs per entry (estimate), LQ CAM 40, SQ 50, completion buffer 8,
# checkpoint 125 (both rename tables, free-list heads, LQ/SQ tails, in LUTRAM).
def window_luts(s):
    ckpts = s["ckpt"] * (1 if s.get("smt_ckpt_shared") else s.get("threads", 1))
    return 10 * s["rob"] + 40 * s["lq"] + 50 * s["sq"] + 8 * s["lqcb"] + 125 * ckpts


# Levers outside the scheduler and window model: per-core saving (low, high) and its source.
FIXED = {
    "fwd_strict": (200, 300, "plan section 8.5 estimate (R9)"),
    "rf_share_a2": (740, 740, "spike S3, measured: 8,713 -> 7,977 LUTs at st_w3 (R11)"),
    "dec_full": (150, 250, "plan section 8.5 estimate (R12)"),
    "alu3_simple": (300, 500, "plan section 8.5 estimate (R13)"),
    "fdiv": (1411, 1411, "FPU track, measured: Goldschmidt 3,125 vs radix-4 1,714 LUTs"),
}


def lut_saving(base, s):
    """(low, high, basis) estimated LUTs saved per core by going from base to s."""
    sched = sched_luts(base) - sched_luts(s)
    win = window_luts(base) - window_luts(s)
    lo = hi = sched + win
    basis = []
    if abs(sched) > 1:
        banked = s.get("smt_iq_cap", 100) <= 50 < base.get("smt_iq_cap", 100)
        if banked:  # a structural change: credit 60-100% of the modelled halving
            lo -= 0.4 * sched
        basis.append(f"scheduler {sched / 1000:+.2f}K (S2 fit{', 60-100%' if banked else ''})")
    if abs(win) > 1:
        basis.append(f"window storage {win / 1000:+.2f}K (per-entry estimates)")
    for k, (a, b, src) in FIXED.items():
        changed = (k == "fdiv" and s.get("fdiv_ii") == 0 and base.get("fdiv_ii") != 0) or \
                  (k != "fdiv" and s.get(k, 0) and not base.get(k, 0))
        if changed:
            lo += a
            hi += b
            basis.append(src)
    return lo, hi, "; ".join(basis)


# ---------------------------------------------------------------- evaluation


def evaluate_smt(sets):
    """SMT2 configuration: WS_ref over the pairs and single-thread (SMT off) suite IPC, at every latency."""
    out = {}
    for lat in LATS:
        e = smt.evaluate(sets, lat, with_alone=True)
        out[str(lat)] = {"ws_ref": e["ws_ref"], "ws": e["ws"], "fair": e["fair"],
                         "groups": {g: e["groups"][g]["ws_ref"] for g in smt.GROUPS},
                         "st_ipc": e["alone_suite_ipc"], "st": e["alone"],
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
                                                  "coremark_A", "dmips")}}
    return out


def run_singles():
    res = json.loads(OUT.read_text()) if OUT.exists() else {}
    res.update({"v1": V1, "v2": V2, "lats": LATS})
    l1, l2 = levers_v1(V1), levers_v2(V2)
    smt.prefetch([V1, V2] + list(l1.values()) + list(l2.values()), LATS)
    st_cfgs = st_w3_configs()
    import dse  # noqa: PLC0415
    singles = [(smt.PRESET, {**s, "dram_lat": lat}) for s in st_cfgs.values() for lat in LATS]
    dse.collect(singles, smt.ISA)
    res["base"] = {"v1": evaluate_smt(V1), "v2": evaluate_smt(V2), "st": evaluate_st(ST)}
    for tag, levers, base in (("v1", l1, V1), ("v2", l2, V2)):
        res[f"levers_{tag}"] = {}
        for name, s in levers.items():
            lo, hi, basis = lut_saving(base, s)
            res[f"levers_{tag}"][name] = {"sets": s, "luts_saved": [lo, hi], "basis": basis, "by_lat": evaluate_smt(s)}
            r = res[f"levers_{tag}"][name]["by_lat"]["120"]
            b = res["base"][tag]["120"]
            print(f"{tag} {name}: WS_ref {r['ws_ref'] / b['ws_ref'] * 100 - 100:+.2f}%  ST {r['st_ipc'] / b['st_ipc'] * 100 - 100:+.2f}%"
                  f"  saves {lo / 1000:.2f}-{hi / 1000:.2f}K", flush=True)
    res["st_w3"] = {}
    for name, s in st_cfgs.items():
        res["st_w3"][name] = {"sets": s, "by_lat": evaluate_st(s)}
    OUT.write_text(json.dumps(res, indent=1))
    print(f"wrote {OUT}")


def census():
    """Which wakeup columns each queue's rows actually wait on (census = 1 runs at 120 cycles)."""
    res = json.loads(OUT.read_text()) if OUT.exists() else {}
    out = {}
    for tag, base in (("v1", V1), ("v2", V2)):
        s = {**base, "census": 1, "dram_lat": 120}
        data = smt.collect([(s, a, b) for _, a, b in smt.PAIRS])
        tot = {}
        for _, a, b in smt.PAIRS:
            r = data[smt.pair_key(s, a, b)[0]]
            for q, c in r.get("census", {}).items():
                t = tot.setdefault(q, {})
                for k, v in c.items():
                    if k == "rob_from":
                        f = t.setdefault("rob_from", {})
                        for p, n in v.items():
                            f[p] = f.get(p, 0) + n
                    else:
                        t[k] = t.get(k, 0) + v
        out[tag] = tot
        print(tag, json.dumps(tot), flush=True)
    res["census"] = out
    OUT.write_text(json.dumps(res, indent=1))
    print(f"wrote {OUT}")


def main():
    if "--census" in sys.argv:
        return census()
    if "--tables" in sys.argv:
        import area_tables  # noqa: PLC0415
        return area_tables.main()
    return run_singles()


if __name__ == "__main__":
    main()
