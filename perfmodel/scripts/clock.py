"""Clock sweep: is 200 MHz the right target for v1? (the user's question, 2026-10-14; DR-137 keeps 200 MHz until
the user decides).

v1 (smt2, the release configuration, wakeup tags) runs the single-thread suite with SMT off (partitions merged),
at 150, 160, 170, 180 and 200 MHz, against the NaxRiscv-like control (`nax`, on the same uncore) at 137 MHz (its
published RV64 Fmax, Artix-7 -3) and 150 MHz. Each clock gets its own cycle latencies:
  DRAM latency    S1's idle 64-byte read, 184 ns (36.8 cycles at 200 MHz), as `dram_lat`;
  DRAM bandwidth  S1's 3.2 GB/s per HP port, 20 ns per 64-byte line, as `dram_line_cyc`;
  stress point    1,250 ns (the DSE's 250 cycles at 200 MHz), the same time at every clock;
  L2 hit          `l2_lat` 12 with DATA_LAT = 4 above 150 MHz, 10 with DATA_LAT = 2 at 150 MHz and below
                  (docs/spec/l2.md: about 11 cycles from L1 miss to first beat with the interconnect at
                  DATA_LAT = 4, 9 at DATA_LAT = 2, plus the fill).
Everything else stays fixed in cycles (the FMA's 4-cycle form misses 200 MHz by 1.88 ns, so it would close only
below about 145 MHz; the other 200 MHz pipelining is not recorded as clock-dependent).

  python3 scripts/clock.py           # -> results/clock_rv64gc.json, and the tables on stdout
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dse  # noqa: E402
import smt  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "clock_rv64gc.json"
ISA = "rv64gc"
V1 = {**smt.single(json.loads(smt.OUT.read_text())["greedy_bundles"]["final"]), "wake_tags": 16}
DRAM_NS, STRESS_NS, LINE_NS = 184.0, 1250.0, 20.0
CLOCKS = (150, 160, 170, 180, 200)
NAX_CLOCKS = (137, 150)
REFERENCE = 0.9910285736880217  # v1's single-thread suite IPC at dram_lat 120 (results/area_recovery.json)


def cyc(ns, mhz):
    return int(ns * mhz / 1000 + 0.5)


def uncore(mhz, ns):
    return {"dram_lat": cyc(ns, mhz), "dram_line_cyc": max(1, cyc(LINE_NS, mhz)), "l2_lat": 12 if mhz > 150 else 10}


def configs():
    out = {}
    for ns in (DRAM_NS, STRESS_NS):
        for f in CLOCKS:
            out[("v1", f, ns)] = ("tanager_v1", {**V1, **uncore(f, ns)})
        for f in NAX_CLOCKS:
            out[("nax", f, ns)] = ("nax", uncore(f, ns))
    return out


def main():
    ref = ("tanager_v1", {**V1, "dram_lat": 120})
    cs = configs()
    data = dse.collect([ref] + list(cs.values()), ISA)
    got = dse.summarize(data[dse.key(ISA, *ref)[0]])["suite_ipc"]
    if abs(got - REFERENCE) > 1e-12:
        raise SystemExit(f"model check failed: v1 at 120 cycles gives {got}, the area study had {REFERENCE}")
    res = {}
    for (core, f, ns), (preset, sets) in cs.items():
        s = dse.summarize(data[dse.key(ISA, preset, sets)[0]])
        res.setdefault(str(int(ns)), {})[f"{core}@{f}"] = {
            "mhz": f, "sets": sets, "suite_ipc": s["suite_ipc"], "coremark_A": s["coremark_A"],
            "coremark_B": s["coremark_B"], "kernels_ipc": s["kernels_ipc"], "embench_ipc": s["embench_ipc"],
            "memsuite_ipc": s["memsuite_ipc"]}
    OUT.write_text(json.dumps(res, indent=1) + "\n")
    for ns, rows in res.items():
        nax = {f: rows[f"nax@{f}"] for f in NAX_CLOCKS}
        print(f"\n### DRAM at {ns} ns\n")
        print("| Core | Clock | DRAM / L2 hit (cycles) | Suite IPC | Perf. (IPC × MHz) | ÷ NaxRiscv @137 | ÷ NaxRiscv @150 "
              "| CoreMark/MHz (A / B) | CoreMark/s (A) ÷ NaxRiscv @137 / @150 |")
        print("|---|---|---|---|---|---|---|---|---|")
        for key, r in rows.items():
            perf = r["suite_ipc"] * r["mhz"]
            cm = r["coremark_A"] * r["mhz"]
            rp = [perf / (nax[n]["suite_ipc"] * n) for n in NAX_CLOCKS]
            rc = [cm / (nax[n]["coremark_A"] * n) for n in NAX_CLOCKS]
            print(f"| {key.split('@')[0]} | {r['mhz']} | {r['sets']['dram_lat']} / {r['sets']['l2_lat']} "
                  f"| {r['suite_ipc']:.3f} | {perf:.0f} | {rp[0]:.2f} | {rp[1]:.2f} "
                  f"| {r['coremark_A']:.2f} / {r['coremark_B']:.2f} | {rc[0]:.2f} / {rc[1]:.2f} |")


if __name__ == "__main__":
    main()
