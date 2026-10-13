"""Prints the region statistics of one tgsim run.  stats.py <isa> <workload> <preset> [k=v ...]"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tgrun  # noqa: E402

isa, name, preset = sys.argv[1:4]
sets = dict(kv.split("=", 1) for kv in sys.argv[4:])
w = next(w for m in ("manifest", "extra") for w in tgrun.manifest(isa, m) if w["name"] == name)
r = tgrun.run_one(w, preset, sets)
g = r["region"]
cyc, ins = max(1, g["cycles"]), max(1, g["instr"])
print(f"{name} {preset} {sets}: ipc={ins / cyc:.3f} cycles={cyc} instr={ins} uops={g['uops']} err={r.get('error')}")
for k, v in g.items():
    if v and k not in ("cycles", "instr", "uops"):
        print(f"  {k:22s} {v:>10}  ({v / cyc * 100:6.2f}% of cycles, {v / ins * 1000:8.2f} PKI)")
