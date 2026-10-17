"""Calibration of tgsim against the RTL as built: the same ELFs in both simulators, region cycles compared.

The RTL side is tg_vsim (sim/, the core on TileLink memory models with a flat latency and no L2), running the
RTL bench's own ELFs (tests/bench: CoreMark A/B with ITER iterations and Dhrystone with RUNS runs, rv64im and
rv64gcb), or any other ELF built with tests/bench/bsp. tgsim runs the same ELFs (its ISS knows the RTL platform's
UART, tohost and tg_marker) with the `rtl_m2` preset, at the same memory latency. RTL results are cached in
results/rtlcal_rtl.json by ELF content and latency, so model iterations do not rerun the RTL.

  python3 scripts/rtlcal.py --vsim <tg_vsim> [--lat native,120] [--set k=v ...] ELF...
      -> a per-program table: RTL and model region cycles and the model's error
At most --jobs (8) runs at a time: the build host is shared.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tgrun  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "results" / "rtlcal_rtl.json"
LATS = {"native": 30}


def sha(path):
    return hashlib.sha1(Path(path).read_bytes()).hexdigest()[:16]


def rtl_run(vsim, elf, lat, timeout):
    p = subprocess.run([vsim, "--quiet", f"--lat={lat}", "--timeout=2000000000", elf], capture_output=True,
                       text=True, errors="replace", timeout=timeout)
    kv = {}
    for line in p.stdout.splitlines():
        if line.startswith("TG-RESULT"):
            kv = dict(x.split("=", 1) for x in line.split()[1:] if "=" in x)
    if kv.get("status") != "PASS":
        raise SystemExit(f"tg_vsim failed on {elf} at lat={lat}: {p.stderr.strip()[-300:]}")
    return {"region_cycles": int(kv["region_cycles"]), "region_instret": int(kv.get("region_instret", 0) or 0),
            "cycles": int(kv.get("cycles", 0) or 0)}


def model_run(elf, lat, sets):
    w = {"name": Path(elf).stem, "elf": str(elf), "stdin": "", "ff": 0}
    cyc = LATS.get(lat, None) or int(lat)
    r = tgrun.run_one(w, "rtl_m2", {**sets, "dram_lat": cyc})
    if r.get("error") or not r.get("region", {}).get("cycles"):  # Dhrystone's K&R main exits with no code
        raise SystemExit(f"tgsim failed on {elf} at lat={lat}: {r.get('error', '')} exit={r.get('exit_code')}")
    return {"region_cycles": r["region"]["cycles"], "region_instr": r["region"]["instr"], "stats": r.get("region")}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vsim", required=True)
    ap.add_argument("--lat", default="native,120")
    ap.add_argument("--set", action="append", default=[])
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=7200)
    ap.add_argument("--json")
    ap.add_argument("elfs", nargs="+")
    a = ap.parse_args()
    sets = dict(s.split("=", 1) for s in a.set)
    lats = a.lat.split(",")
    cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
    vkey = sha(a.vsim)
    jobs = [(e, l) for e in a.elfs for l in lats]
    todo = [(e, l) for e, l in jobs if f"{vkey}:{sha(e)}:{l}" not in cache]
    with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        for (e, l), r in zip(todo, ex.map(lambda j: rtl_run(a.vsim, j[0], j[1], a.timeout), todo)):
            cache[f"{vkey}:{sha(e)}:{l}"] = {"elf": str(e), "lat": l, **r}
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(cache, indent=1) + "\n")
    with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        model = list(ex.map(lambda j: model_run(j[0], j[1], sets), jobs))
    rows = []
    print(f"\n| Program | Latency | RTL region cycles | Model region cycles | Model error | RTL IPC | Model IPC |")
    print("|---|---|---|---|---|---|---|")
    for (e, l), m in zip(jobs, model):
        r = cache[f"{vkey}:{sha(e)}:{l}"]
        err = m["region_cycles"] / r["region_cycles"] - 1
        name = f"{Path(e).parent.name}/{Path(e).stem}"
        ipc_r = r["region_instret"] / r["region_cycles"] if r["region_instret"] else 0.0
        ipc_m = m["region_instr"] / m["region_cycles"]
        rows.append({"program": name, "lat": l, "rtl": r, "model": m["region_cycles"], "error": err,
                     "ipc_rtl": ipc_r, "ipc_model": ipc_m, "model_stats": m["stats"]})
        print(f"| {name} | {l} | {r['region_cycles']:,} | {m['region_cycles']:,} | {err:+.1%} | {ipc_r:.3f} | {ipc_m:.3f} |")
    if a.json:
        Path(a.json).write_text(json.dumps({"sets": sets, "rows": rows}, indent=1) + "\n")


if __name__ == "__main__":
    main()
