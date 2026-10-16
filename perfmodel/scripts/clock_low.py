"""The DR-145 clocks: v1 (2 cores x SMT2) at 94, 100 and 125 MHz (150 for reference) against NaxRiscv at 135 and
150 MHz.

The user's decision DR-145 (10-16) makes 125 MHz the preferred target and 100 MHz the minimum, after a study; this
is the model's part of it. Every resulting change needs the user's approval.

v1 is calibrated to the RTL as built, not to the plan: one L1D miss in flight and one I-cache refill at a time
(core-lsu.md, core-pipeline.md; the plan's 16 and 4 MSHRs are M6), and no prefetcher (none in the L1s or the L2).
`l1d_mshr` 2 and 4, with the default profile, are the non-blocking-cache option.
With one L1D MSHR and SMT2 the model can starve a thread's store drain for good: loads book the MSHR at their access
time (issue + 3), the drain asks at the current cycle, and a sibling's stream of misses always gets there first.
`drain_guard` 16 gives a committed store that has waited 16 cycles the next MSHR. How the RTL arbitrates its MSHR
between the load pipe and the drain is not documented (core-lsu.md).

Each clock gets its own cycle latencies:
  DRAM latency    S1's idle 64-byte read from the PL port, 184 ns, as `dram_lat` (17 / 18 / 23 / 25 / 28 cycles
                  at 94 / 100 / 125 / 135 / 150 MHz); the whole 184 ns is taken as fixed in ns.
  DRAM bandwidth  each HP port moves 16 bytes per PL cycle (128 bits at the core clock; S1's 3.2 GB/s per port is
                  that rate at 200 MHz), so a 64-byte line takes 4 cycles per port at every clock here. The L2's
                  two banks (address bit 6) each have a port.
  L2 hit          `l2_lat` 10: DATA_LAT = 2, which the URAM cascade allows up to 150 MHz.
One core alone has the whole L2 and both ports (`dram_line_cyc` 2). With both cores busy, each core is modelled
with half the L2's ways, half its MSHRs and one port (`dram_line_cyc` 4): the model has one core, so this is the
second core's share to first order.

The profiles (DR-140, DR-144): the fallback is the model as it was. The default (#4 and #5 on, #2 off, B3) has one
model point, #4's extra cycle on a store's completion (`abl_st_done` 1). #5 (atomics) and B3 (the ROB head's TLB
lookup) have none, since the model has no atomics in its workloads and no TLBs.

Workloads:
  1 thread   the suite (kernels, Embench, memsuite) and the working-set kernels (bench/build_ws.sh, 0.5-4 MiB), on
             v1 with SMT off and on the NaxRiscv-like control (`nax`, on the same uncore, so without the L2
             prefetcher too).
  4 threads  v1 as two busy cores, each running SMT2 pairs: smt.py's 42 suite pairs and 16 working-set pairs (each
             kernel with the next one at the same size). NaxRiscv as two cores without SMT, each time-slicing the
             same pairs: a core's throughput on a pair is the mean of the two programs' IPC (equal time slices).
  Performance is IPC x MHz; a 4-thread figure is two cores' throughput x MHz. Group figures are geometric means,
  and the suite figure is the geometric mean of its three groups (as in the M1 suite IPC and smt.py).

At most WORKERS (8) runs at a time: the build host is shared. One process does everything, so a kill stops it all.
  python3 scripts/clock_low.py      # -> results/clock_low_rv64gc.json, tables on stdout
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dse  # noqa: E402
import smt  # noqa: E402
import tgrun  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "clock_low_rv64gc.json"
ISA = "rv64gc"
WORKERS = 8
V1_SMT = {**json.loads(smt.OUT.read_text())["greedy_bundles"]["final"], "wake_tags": 16}  # v1, plan 6.5
V1 = smt.single(V1_SMT)
REFERENCE = 0.9910285736880217  # v1's single-thread suite IPC at dram_lat 120 (results/area_recovery.json)
DRAM_NS = 184.0
CLOCKS = (94, 100, 125, 150)
NAX_CLOCKS = (135, 150)
L2_LAT = 10  # DATA_LAT = 2
RTL = {"l1i_mshr": 1, "fdip": 0, "pf_i_nextline": 0, "pf_stride": 0, "rfo_pf": 0, "pf_stream": 0, "drain_guard": 16}
MSHRS = (1, 2, 4)
PROFILES = {"fallback": {}, "default": {"abl_st_done": 1}}
L2 = {"l2_kb": V1.get("l2_kb", 1024), "l2_ways": V1.get("l2_ways", 8), "l2_mshr": V1.get("l2_mshr", 32)}
ALONE = {**L2, "dram_line_cyc": 2}
SHARE = {"l2_kb": L2["l2_kb"] // 2, "l2_ways": L2["l2_ways"] // 2, "l2_mshr": L2["l2_mshr"] // 2, "dram_line_cyc": 4}

WS_KIB = (512, 1024, 2048, 4096)
WS_KERN = ("chase1", "chase8", "hash", "copy")
smt.WS.update({w["name"]: w for w in tgrun.manifest(ISA, "ws")})
WS_PAIRS = [("ws", f"ws_{a}_{k}", f"ws_{b}_{k}") for k in WS_KIB
            for a, b in zip(WS_KERN, WS_KERN[1:] + WS_KERN[:1])]
COLS = [("one", "suite"), ("one", "memsuite"), ("one", "ws"), ("four", "suite"), ("four", "memsuite"),
        ("four", "ws")]


def cyc(ns, mhz):
    return int(ns * mhz / 1000 + 0.5)


def mem(mhz):
    return {"dram_lat": cyc(DRAM_NS, mhz), "l2_lat": L2_LAT}


def v1_alone(f, prof, m):
    return {**V1, **ALONE, **mem(f), **RTL, "l1d_mshr": m, **PROFILES[prof]}


def v1_share(f, prof, m):
    return {**V1_SMT, **SHARE, **mem(f), **RTL, "l1d_mshr": m, **PROFILES[prof]}


def nax(f, share):
    return {**(SHARE if share else ALONE), **mem(f), "pf_stream": 0}


def v1_points():
    """The default profile at every L1D MSHR count; the fallback at the RTL's one."""
    return [(f, p, m) for f in CLOCKS for p, m in [("default", m) for m in MSHRS] + [("fallback", 1)]]


def prefetch():
    singles = [("tanager_v1", v1_alone(*pt)) for pt in v1_points()]
    singles += [("nax", nax(f, s)) for f in NAX_CLOCKS for s in (False, True)]
    dse.collect(singles, ISA, workers=WORKERS)
    dse.collect(singles, ISA, workers=WORKERS, mname="ws")
    smt.collect([(v1_share(*pt), a, b) for pt in v1_points() for _, a, b in smt.PAIRS + WS_PAIRS], workers=WORKERS)


def gm(xs):
    return tgrun.geomean(list(xs))


def single(preset, sets):
    """Single-thread IPC per workload (suite and working sets) and the group figures."""
    s = dse.summarize(dse.collect([(preset, sets)], ISA, workers=WORKERS)[dse.key(ISA, preset, sets)[0]])
    w = {r["workload"]["name"]: tgrun.metrics(r)["ipc"]
         for r in dse.collect([(preset, sets)], ISA, workers=WORKERS, mname="ws")[dse.key(f"{ISA}:ws", preset, sets)[0]]}
    return {"ipc": {**s["ipc"], **w}, "suite": s["suite_ipc"], "kernels": s["kernels_ipc"],
            "embench": s["embench_ipc"], "memsuite": s["memsuite_ipc"], "ws": gm(w.values()),
            "ws_kib": {k: gm(w[f"ws_{n}_{k}"] for n in WS_KERN) for k in WS_KIB},
            "coremark_A": s["coremark_A"], "coremark_B": s["coremark_B"], "dmips": s["dmips"]}


def groups(per_pair):
    """per_pair: {(group, a, b): throughput of one core} -> the group figures as in smt.py, and ws by size."""
    g = {grp: gm(v for (gg, _, _), v in per_pair.items() if gg == grp) for grp in smt.GROUPS + ("ws",)}
    return {"suite": gm(g[x] for x in smt.GROUPS), "memsuite": g["mem+mem"], "mixed": g["mixed"],
            "compute": g["compute+compute"], "ws": g["ws"],
            "ws_kib": {k: gm(v for (gg, a, _), v in per_pair.items() if gg == "ws" and a.endswith(f"_{k}"))
                       for k in WS_KIB}}


def v1_four(f, prof, m):
    s = v1_share(f, prof, m)
    pairs = smt.PAIRS + WS_PAIRS
    data = smt.collect([(s, a, b) for _, a, b in pairs], workers=WORKERS)
    per = {}
    for grp, a, b in pairs:
        r = data[smt.pair_key(s, a, b)[0]]
        per[(grp, a, b)] = sum(t["region"]["instr"] / max(1, t["region"]["cycles"]) for t in r["threads"])
    return groups(per)


def nax_four(f):
    ipc = single("nax", nax(f, True))["ipc"]
    return groups({(grp, a, b): (ipc[a] + ipc[b]) / 2 for grp, a, b in smt.PAIRS + WS_PAIRS})


def perf(e, mode, k):
    x = e[mode][k] * e["mhz"]
    return x * 2 if mode == "four" else x


def main():
    ref = ("tanager_v1", {**V1, "dram_lat": 120})
    got = dse.summarize(dse.collect([ref], ISA, workers=WORKERS)[dse.key(ISA, *ref)[0]])["suite_ipc"]
    if abs(got - REFERENCE) > 1e-12:
        raise SystemExit(f"model check failed: v1 at 120 cycles gives {got}, the area study had {REFERENCE}")
    prefetch()
    res = {"v1": {}, "nax": {}}
    for f, p, m in v1_points():
        res["v1"][f"{f}/{p}/{m}"] = {"mhz": f, "profile": p, "l1d_mshr": m, "one": single("tanager_v1", v1_alone(f, p, m)),
                                     "four": v1_four(f, p, m)}
    for f in NAX_CLOCKS:
        res["nax"][str(f)] = {"mhz": f, "one": single("nax", nax(f, False)), "four": nax_four(f)}
    OUT.write_text(json.dumps(res, indent=1) + "\n")

    nx = [res["nax"][str(n)] for n in NAX_CLOCKS]
    print("\n| Clock | L1D misses in flight | 1 thread: suite | 1 thread: memsuite | 1 thread: 0.5-4 MiB "
          "| 4 threads: suite | 4 threads: memsuite | 4 threads: 0.5-4 MiB |")
    print("|---|---|---|---|---|---|---|---|")
    rows = [(f"{e['mhz']} MHz", f"{e['l1d_mshr']}" + (" (RTL)" if e["l1d_mshr"] == 1 else ""), e)
            for e in res["v1"].values() if e["profile"] == "default"]
    rows += [(f"NaxRiscv {e['mhz']} MHz", "2", e) for e in nx]
    for c0, c1, e in rows:
        cells = [" / ".join(f"{perf(e, m, k) / perf(n, m, k):.2f}" for n in nx) for m, k in COLS]
        print(f"| {c0} | {c1} | " + " | ".join(cells) + " |")
    print("\nThe fallback profile against the default (RTL, 1 miss), change in performance:")
    print("| Clock | " + " | ".join(f"{m}: {k}" for m, k in COLS) + " |")
    print("|---|" + "---|" * len(COLS))
    for f in CLOCKS:
        d, b = res["v1"][f"{f}/default/1"], res["v1"][f"{f}/fallback/1"]
        print(f"| {f} MHz | " + " | ".join(f"{perf(b, m, k) / perf(d, m, k) - 1:+.2%}" for m, k in COLS) + " |")
    print("\nAbsolute (IPC x MHz; 4 threads: both cores), default profile:")
    print("| Configuration | " + " | ".join(f"{m}: {k}" for m, k in COLS)
          + " | CoreMark/MHz A | 1-thread IPC at 0.5 / 1 / 2 / 4 MiB |")
    print("|---|" + "---|" * (len(COLS) + 2))
    for c0, c1, e in rows:
        wk = " / ".join(f"{e['one']['ws_kib'][k]:.3f}" for k in WS_KIB)
        print(f"| {c0}, {c1} | " + " | ".join(f"{perf(e, m, k):.0f}" for m, k in COLS)
              + f" | {e['one']['coremark_A']:.2f} | {wk} |")


if __name__ == "__main__":
    main()
