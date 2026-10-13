"""Runs tgsim over workload manifests in parallel and scores the results.

Library use:  from tgrun import run_matrix, score
CLI:          python3 scripts/tgrun.py --isa rv64gc --preset tanager_v1 --set dram_lat=120 --tag base
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TGSIM = ROOT / "build" / "tgsim"
EMBENCH_BASELINE = json.loads((ROOT / "third_party/embench-iot/baseline-data/speed.json").read_text())


def manifest(isa: str, name: str = "manifest") -> list[dict]:
    path = ROOT / "build" / "bench" / isa / f"{name}.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def run_one(w: dict, preset: str, sets: dict, iss_only: bool = False) -> dict:
    args = [str(TGSIM), "--preset", preset, "--bench", w["name"]]
    cfg = dict(sets)
    if w.get("ff") and not iss_only:
        cfg.setdefault("ff", 1)
    for k, v in cfg.items():
        args += ["--set", f"{k}={v}"]
    if w.get("stdin"):
        args += ["--stdin", w["stdin"]]
    if iss_only:
        args.append("--iss-only")
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tf:
        out = tf.name
    args += ["--json", out, w["elf"]]
    p = subprocess.run(args, capture_output=True, text=True)
    try:
        r = json.loads(Path(out).read_text())
    except Exception:  # noqa: BLE001
        r = {"bench": w["name"], "error": f"no result (rc={p.returncode}) {p.stderr[-300:]}"}
    finally:
        try:
            os.unlink(out)
        except OSError:
            pass
    r["workload"] = w
    r["preset"] = preset
    r["sets"] = sets
    if iss_only:
        r["stdout"] = p.stderr
    return r


def check(r: dict) -> str:
    """Returns '' if the run completed correctly, else a reason."""
    if r.get("error"):
        return r["error"]
    name = r["workload"]["name"]
    out = r.get("stdout", "")
    if name == "dhrystone":  # K&R main() returns no value, so its exit code is meaningless
        return "" if "Final values" in out else "Dhrystone output missing"
    if r.get("exit_code", 0) != 0:
        return f"exit code {r.get('exit_code')}"
    if name.startswith("coremark"):
        # EEMBC reference CRCs for the performance run (seeds 0, 0, 0x66). CoreMark also prints
        # "Errors detected" because a simulation cannot run the 10 s minimum; that is not a failure.
        for k, v in (("crclist", "0xe714"), ("crcmatrix", "0x1fd7"), ("crcstate", "0x8e3a")):
            if not re.search(rf"\[0\]{k}\s*:\s*{v}\b", out):
                return f"CoreMark {k} mismatch"
    return ""


def metrics(r: dict) -> dict:
    """Per-workload metrics from one result."""
    g = r.get("region", {})
    cyc, ins = max(1, g.get("cycles", 0)), g.get("instr", 0)
    m = {"ipc": ins / cyc, "cycles": cyc, "instr": ins}
    w = r["workload"]
    name, meta = w["name"], w.get("meta", {})
    if name.startswith("coremark"):
        m["coremark_mhz"] = meta["iterations"] * 1e6 / cyc
    elif name == "dhrystone":
        m["dmips_mhz"] = meta["runs"] * 1e6 / cyc / 1757.0
    elif name.startswith("embench_"):
        b = name[len("embench_"):]
        m["embench_rel"] = EMBENCH_BASELINE[b] * 1000.0 / cyc
    ki = max(1, ins) / 1000.0
    mp = g.get("mp_dir", 0) + g.get("mp_target", 0) + g.get("mp_ret", 0) + g.get("mp_cold", 0)
    m["mpki"] = mp / ki
    m["l1d_mpki"] = g.get("l1d_miss", 0) / ki
    m["l2_mpki"] = g.get("l2_miss", 0) / ki
    nz = g.get("mlp_cycles_nz", 0)
    m["mlp"] = g.get("mlp_sum", 0) / nz if nz else 0.0
    m["mlp_avg"] = g.get("mlp_sum", 0) / cyc
    return m


def geomean(xs):
    xs = [x for x in xs if x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else 0.0


def score(results: list[dict]) -> dict:
    """Suite-level scores from the results of one configuration on one ISA."""
    by = {r["workload"]["name"]: metrics(r) for r in results}
    s = {}
    for fs in ("A", "B"):
        if f"coremark_{fs}" in by:
            s[f"coremark_{fs}"] = by[f"coremark_{fs}"]["coremark_mhz"]
    if "dhrystone" in by:
        s["dmips"] = by["dhrystone"]["dmips_mhz"]
    emb = [m["embench_rel"] for n, m in by.items() if n.startswith("embench_")]
    if emb:
        s["embench"] = geomean(emb)
        # GCC 15 hoists nbody's pure bodies_energy() out of its 100-iteration loop, leaving ~800
        # timed instructions; the 18-program score excludes that distorted program.
        s["embench18"] = geomean([m["embench_rel"] for n, m in by.items()
                                  if n.startswith("embench_") and n != "embench_nbody"])
        s["embench_ipc"] = geomean([m["ipc"] for n, m in by.items() if n.startswith("embench_")])
    ms = [m["ipc"] for n, m in by.items() if n.startswith("ms_")]
    if ms:
        s["memsuite_ipc"] = geomean(ms)
    s["all_ipc"] = geomean([m["ipc"] for m in by.values()])
    if "ms_chase8" in by:
        s["mlp_chase8"] = by["ms_chase8"]["mlp"]
    if "ms_chase8f16" in by:
        s["mlp_chase8f16"] = by["ms_chase8f16"]["mlp"]
    s["per_bench"] = by
    return s


def run_matrix(jobs: list[tuple[dict, str, dict]], workers: int = 8, iss_only: bool = False) -> list[dict]:
    with ThreadPoolExecutor(max_workers=workers) as ex:
        return list(ex.map(lambda j: run_one(j[0], j[1], j[2], iss_only), jobs))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--isa", default="rv64gc")
    ap.add_argument("--preset", default="tanager_v1")
    ap.add_argument("--set", action="append", default=[])
    ap.add_argument("--bench", default=".*", help="regex on workload names")
    ap.add_argument("--tag", default="")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 8)
    ap.add_argument("--iss-only", action="store_true")
    ap.add_argument("--manifest", default="manifest", help="manifest name: manifest (the DSE suite) or extra")
    a = ap.parse_args()
    sets = dict(kv.split("=", 1) for kv in a.set)
    ws = [w for w in manifest(a.isa, a.manifest) if re.search(a.bench, w["name"])]
    res = run_matrix([(w, a.preset, sets) for w in ws], a.jobs, a.iss_only)
    bad = 0
    for r in res:
        why = check(r)
        name = r["workload"]["name"]
        if a.iss_only:
            print(f"{name:26s} instret={r.get('instret', 0):>11}  {'OK' if not why else 'FAIL: ' + why}")
        else:
            m = metrics(r)
            print(f"{name:26s} ipc={m['ipc']:.3f} instr={m['instr']:>9} mpki={m['mpki']:5.2f} "
                  f"l1d_mpki={m['l1d_mpki']:6.2f} mlp={m['mlp']:.2f} {'' if not why else 'FAIL: ' + why}")
        bad += bool(why)
    if not a.iss_only:
        s = score(res)
        print(json.dumps({k: (round(v, 4) if isinstance(v, float) else v) for k, v in s.items() if k != "per_bench"}))
    if a.tag:
        outdir = ROOT / "results"
        outdir.mkdir(exist_ok=True)
        with open(outdir / f"{a.tag}.jsonl", "w") as f:
            for r in res:
                f.write(json.dumps(r) + "\n")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
