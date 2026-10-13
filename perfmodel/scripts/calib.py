"""Calibration of the NaxRiscv-like preset against NaxRiscv's published RV32 numbers.

Published (NaxRiscv RTD performance page, RV32 build A: 2 decode, 3 issue, 2 retire):
  IPC: Dhrystone 1.65, CoreMark 1.28, Embench 1.42; DMIPS/MHz 2.93, CoreMark/MHz 5.02, Embench 1.67.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tgrun  # noqa: E402

PUBLISHED = {"dhrystone_ipc": 1.65, "coremark_ipc": 1.28, "embench_ipc": 1.42}

# Interpretations of NaxRiscv's documentation that were tried; the last is the shipped nax preset.
NAIVE = {"btb_block": 0, "btb_sets": 512, "btb_ways": 1, "btb_slots": 1, "taken_bubble": 1, "ras_at_decode": 0}
VARIANTS = {
    "per_instr_btb+bubble1": NAIVE,
    "btb_word+bubble1": {**NAIVE, "btb_block": 1},
    "btb_word+bubble0": {**NAIVE, "btb_block": 1, "taken_bubble": 0},
    "btb_word+bubble0+ras_at_decode (preset)": {},
}


def evaluate(sets: dict, isa: str = "rv32im") -> dict:
    ws = [w for w in tgrun.manifest(isa) if w["group"] in ("coremark", "dhrystone", "embench")]
    res = tgrun.run_matrix([(w, "nax_cal", sets) for w in ws])
    bad = [(r["workload"]["name"], tgrun.check(r)) for r in res if tgrun.check(r)]
    if bad:
        raise SystemExit(f"failed runs: {bad}")
    by = {r["workload"]["name"]: tgrun.metrics(r) for r in res}
    emb = {n: m for n, m in by.items() if n.startswith("embench_")}
    out = {
        "dhrystone_ipc": by["dhrystone"]["ipc"],
        # The published CoreMark build's flags are not documented; average our two flag sets.
        "coremark_ipc": (by["coremark_A"]["ipc"] + by["coremark_B"]["ipc"]) / 2,
        "embench_ipc": tgrun.geomean([m["ipc"] for m in emb.values()]),
        # Alternative aggregation (total instructions over total cycles), shown for reference.
        "embench_ipc_total": sum(m["instr"] for m in emb.values()) / sum(m["cycles"] for m in emb.values()),
        "dmips_mhz": by["dhrystone"]["dmips_mhz"],
        "coremark_mhz": (by["coremark_A"]["coremark_mhz"] + by["coremark_B"]["coremark_mhz"]) / 2,
        "embench_score": tgrun.geomean([m["embench_rel"] for m in emb.values()]),
    }
    out["err"] = {k: out[k] / PUBLISHED[k] - 1 for k in PUBLISHED}
    out["max_abs_err"] = max(abs(v) for v in out["err"].values())
    return out


if __name__ == "__main__":
    rows = {}
    for name, sets in VARIANTS.items():
        rows[name] = evaluate(sets)
        e = rows[name]["err"]
        x = rows[name]
        print(f"{name:20s} dhry={x['dhrystone_ipc']:.3f} ({e['dhrystone_ipc']:+.1%})  "
              f"coremark={x['coremark_ipc']:.3f} ({e['coremark_ipc']:+.1%})  "
              f"embench={x['embench_ipc']:.3f} ({e['embench_ipc']:+.1%}; total {x['embench_ipc_total']:.3f})  "
              f"max|err|={x['max_abs_err']:.1%} | DMIPS/MHz {x['dmips_mhz']:.2f} (pub 2.93)  "
              f"CM/MHz {x['coremark_mhz']:.2f} (pub 5.02)  Embench {x['embench_score']:.2f} (pub 1.67)")
    out = Path(__file__).resolve().parent.parent / "results"
    out.mkdir(exist_ok=True)
    (out / "calibration.json").write_text(json.dumps({"published": PUBLISHED, "variants": VARIANTS, "results": rows},
                                                     indent=1))
