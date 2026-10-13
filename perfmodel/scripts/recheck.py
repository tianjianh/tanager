"""Re-simulates cached DSE configurations and reports any workload whose region cycles or instructions changed.
Use after rebuilding tgsim (new compiler, refactoring) to show the DSE cache is still valid.

  python3 scripts/recheck.py [isa] [N]   # N cached configurations, baselines first (default 4)
  python3 scripts/recheck.py --freeze    # preset v1_freeze at 30/120/250 cycles against the cached freeze
                                         # ("final C" in results/freeze_rv64gc.json, run as tanager_v1 + settings)
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dse  # noqa: E402
import tgrun  # noqa: E402


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    isa = args[0] if args else "rv64gc"
    n = int(args[1]) if len(args) > 1 else 4
    # (preset to run, settings to run with, preset and settings of the cache entry to compare with)
    picks = []
    if "--freeze" in sys.argv:
        fz = json.loads((dse.ROOT / "results" / f"freeze_{isa}.json").read_text())
        final = fz["candidates"]["final C: B + FP IQ 10"]["sets"]
        for lat in (30, 120, 250):
            picks.append(("v1_freeze", {"dram_lat": lat}, "tanager_v1", {**final, "dram_lat": lat}))
    else:
        for lat in (120, 30):
            picks += [(p, {"dram_lat": lat}, p, {"dram_lat": lat}) for p in ("tanager_v1", "nax")]
        picks = picks[:n]
    ws = {w["name"]: w for w in tgrun.manifest(isa)}
    jobs, old = [], {}
    for preset, sets, cpreset, csets in picks:
        k, raw = dse.key(isa, cpreset, csets)
        f = dse.CACHE / f"{k}.jsonl"
        if not f.exists():
            print(f"not cached: {raw}")
            continue
        for r in (json.loads(line) for line in f.read_text().splitlines()):
            old[(k, r["workload"]["name"])] = r["region"]
            jobs.append((k, ws[r["workload"]["name"]], preset, sets))
    res = tgrun.run_matrix([(w, p, s) for _, w, p, s in jobs])
    diffs = 0
    for (k, w, _, _), r in zip(jobs, res):
        a, b = old[(k, w["name"])], r.get("region", {})
        if (a.get("cycles"), a.get("instr")) != (b.get("cycles"), b.get("instr")):
            diffs += 1
            print(f"DIFF {k} {w['name']}: cycles {a.get('cycles')} -> {b.get('cycles')}, "
                  f"instr {a.get('instr')} -> {b.get('instr')}")
        elif a != {key: v for key, v in b.items() if key in a}:
            diffs += 1
            print(f"DIFF {k} {w['name']}: region statistics differ")
    print(f"{len(jobs)} runs re-simulated, {diffs} differ")
    sys.exit(1 if diffs else 0)


if __name__ == "__main__":
    main()
