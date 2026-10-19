"""tgsim's M6 preset against the board's first M6 Linux numbers (docs/perf/area_recovery.md §6.12).

The board (fpga/kv260/board/d4s2, MR18): DR-141's Linux set on d4s2 (M6 with core-2's micro-BTB target check, smt2
cores, 100 MHz) against d2 (sc3's core with DR-156's four misses: no speculative wakeup, RAS, TAGE-lite or DR-169's
levers). Its CoreMark and Dhrystone are the set's static glibc builds (tests/bench/linux), not make perf's
bare-metal ELFs. The board's counts are the medians of 9 runs per bitstream (cmp_cycles.md, cmp_instret.md).
The model: rtl_m2 revision 7 as each board's core, on make perf's ELFs at native latency:
  st    the core as make perf builds it (tg_cfg_st)
  smt2  the core as the board builds it (tg_cfg_smt2, one thread: ROB 80, LQ 24, SQ 20, 24 LLTs; the per-thread
        halves and the 75% issue-queue caps come with M7: tg_issue leaves tg_iq's room unused)
  M6    main's M6 set (the RAS, TAGE-lite 2 x 2K, F2's returns and straddlers, DR-169's levers)
  d2    speculative wakeup off, the front end before TAGE-lite (no RAS), rename's steering by the flags of the cycle
        before, the store address with its data
Beside it, the RTL's make perf on both trees (tools/ci/perf.py's tables, one log per configuration: --rtl CFG=LOG,
base d2 and this side d4s2).
  python3 scripts/m6_board.py --bench DIR --rtl st=LOG --rtl smt2=LOG   # -> results/m6_board_rv64.json and tables
  python3 scripts/m6_board.py --init d2=LOG --init d4s2=LOG --init d4r1=LOG   # the boot to /init alone (§6.13)
"""
import argparse
import json
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dse  # noqa: E402
import m6_steps as m6  # noqa: E402
import tgrun  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results" / "m6_board_rv64.json"
M6 = {"ras": 32, "m2_dir": 1, "dirpred": 2, "tage_log": 12, "m2_f2": 1, "m2_btage": 1, "btage_nt": 2, "btage_li": 11,
      "m2_cut": 1, "m2_f2_bubble": 2, "m2_ftq": 32, "m2_ras_f2": 1}
D2 = {"spec_wakeup": 0, "spec_fwd": 0, "iq_steer_rn": 1, "sta_split": 0, "fwd_wait_cancel": 0, "m2_strad": 0}
SMT2 = {"rob": 80, "lq": 24, "sq": 20, "llt": 24}
CFGS = {"d2 st": D2, "d2 smt2": {**D2, **SMT2}, "M6 st": M6, "M6 smt2": {**M6, **SMT2}}
PROGS = [(p, m) for m in ("rv64gc", "rv64im") for p in ("coremark_A", "coremark_B", "dhrystone")]
OPS = {"coremark_A": 10, "coremark_B": 10, "dhrystone": 500}   # make perf's iterations and runs
# The board (MR18), rv64gc static glibc builds: (cycles, instructions) per CoreMark iteration or Dhrystone run
BOARD = {"coremark_A": {"d2": (361162, 340564), "d4s2": (216938, 339051)},
         "coremark_B": {"d2": (436527, 345469), "d4s2": (229159, 343303)},
         "dhrystone": {"d2": (405, 325), "d4s2": (202, 323)}}


def rtl_log(path):
    """perf.py's table: {(program, march): {"d2": (cycles, ipc), "d4s2": (cycles, ipc)}} at native latency."""
    out = {}
    for line in open(path):
        m = re.match(r"(coremark_A|coremark_B|dhrystone) (rv64\w+)( lat(\S+))?\s+([\d,]+)\s+([\d.]+)\s+([\d,]+)\s+"
                     r"([\d.]+)", line)
        if m and m.group(4) in (None, "native"):
            out[(m.group(1), m.group(2))] = {"d2": (int(m.group(5).replace(",", "")), float(m.group(6))),
                                             "d4s2": (int(m.group(7).replace(",", "")), float(m.group(8)))}
    return out


def pct(x):
    return f"{x:+.1%}"


# Linux's boot to /init, phase by phase: kernel log lines both runs print
MILESTONES = ["smp: Brought up", "devtmpfs: initialized", "clocksource: Switched", "Serial: 8250",
              "NET: Registered PF_PACKET", "clk: Disabling unused clocks", "Freeing unused kernel image",
              "Run /init as init process"]
BOARD_LOGS = {"d2": [f"d2-reg/d2_boot{i}.txt" for i in (1, 2, 3)],
              "d4s2": [f"d4s2/d4s2_boot{i}.txt" for i in (1, 2, 3)],
              "d4r1": [f"d4r1/d4r1_boot{i}.txt" for i in (1, 2, 3)]}   # MR23, measured after §6.13's prediction
PHASES = ["smp: Brought up", "clocksource: Switched", "NET: Registered PF_PACKET", "clk: Disabling unused clocks",
          "Freeing unused kernel image", "Run /init as init process"]


def kernel_times(path, serial):
    """Each milestone's CPU time from a kernel log: its timestamp, less, when the console is serial and synchronous
    (the board's: 115200 baud, 10 bits a character), the console time of the timestamped lines printed before it.
    tb_boot's console (host bridge) takes no time."""
    con, out = 0.0, {}
    for raw in open(path, errors="replace"):
        line = raw.rstrip("\r\n")
        m = re.match(r"\[\s*(\d+\.\d+)\] (.*)", line)
        if not m or float(m.group(1)) <= 0:
            continue
        for k in MILESTONES:
            if k not in out and m.group(2).startswith(k):
                out[k] = float(m.group(1)) - con
        if m.group(2).startswith("Run /init"):
            out["console"] = con   # the console time inside /init's timestamp
            break
        if serial:
            con += (len(line) + 2) * 10 / 115200
    return out


def init_table(sim, board_dir):
    """The boot's CPU time at each milestone: the board (the median of its three boots) and tb_boot."""
    med = lambda v: sorted(v)[len(v) // 2]
    brd = {}
    for n, files in BOARD_LOGS.items():
        runs = [kernel_times(Path(board_dir) / f, True) for f in files]
        brd[n] = {k: med([r[k] for r in runs]) for k in MILESTONES + ["console"] if all(k in r for r in runs)}
    tbs = {n: kernel_times(p, False) for n, p in sim.items()}
    print("\n**Linux to /init: CPU time at each milestone** (the board's less its serial console; tb_boot's own)\n")
    print("| Milestone | Board d2 | Board d4s2 | Change | tb_boot d2 | tb_boot d4s2 | Change | tb_boot against the "
          "board: d2 / d4s2 |")
    print("|---|---|---|---|---|---|---|---|")
    for k in MILESTONES:
        b2, b4 = brd["d2"].get(k), brd["d4s2"].get(k)
        s2, s4 = tbs.get("d2", {}).get(k), tbs.get("d4s2", {}).get(k)
        f = lambda x: f"{x:.4f} s" if x is not None else "–"
        ch = lambda a, b: pct(b / a - 1) if a and b else "–"
        vs = f"{ch(b2, s2)} / {ch(b4, s4)}"
        print(f"| {k} | {f(b2)} | {f(b4)} | {ch(b2, b4)} | {f(s2)} | {f(s4)} | {ch(s2, s4)} | {vs} |")
    if "d4r1" in tbs:   # §6.13: the board's d4r1, predicted as d4s2's board time scaled by the simulation's ratio
        b5 = brd.get("d4r1", {})
        f = lambda x: f"{x:.4f} s" if x is not None else "–"
        ch = lambda a, b: pct(b / a - 1) if a and b else "–"
        print("\n**d4r1, predicted (§6.13) and measured (MR23)** (the prediction: the board's d4s2 time × the "
              "simulation's d4r1 / d4s2)\n")
        print("| Milestone | Simulation d4s2 | Simulation d4r1 | Change | Board d4s2 | Predicted board d4r1 | "
              "Board d4r1 | Change | Measured against predicted |")
        print("|---|---|---|---|---|---|---|---|---|")
        for k in MILESTONES:
            s4, s5, b4, m5 = tbs["d4s2"].get(k), tbs["d4r1"].get(k), brd["d4s2"].get(k), b5.get(k)
            pr = b4 * s5 / s4 if s4 and s5 and b4 else None
            print(f"| {k} | {f(s4)} | {f(s5)} | {ch(s4, s5)} | {f(b4)} | {f(pr)} | {f(m5)} | {ch(b4, m5)} | "
                  f"{ch(pr, m5)} |")
        if all(k in b5 for k in PHASES):   # where the board's gain came from, against the simulation's
            print("\n**d4s2 → d4r1, phase by phase** (the CPU time between milestones)\n")
            print("| Phase, to | Simulation | Change | Board | Change |")
            print("|---|---|---|---|---|")
            last = (0.0, 0.0, 0.0, 0.0)
            for k in PHASES:
                cur = (tbs["d4s2"][k], tbs["d4r1"][k], brd["d4s2"][k], b5[k])
                d = [c - p for c, p in zip(cur, last)]
                print(f"| {k} | {d[0]:.4f} → {d[1]:.4f} s | {ch(d[0], d[1])} | {d[2]:.4f} → {d[3]:.4f} s | "
                      f"{ch(d[2], d[3])} |")
                last = cur
            print(f"\nThe board's console before /init: {brd['d4s2']['console']:.4f} s (d4s2), "
                  f"{b5['console']:.4f} s (d4r1).")
    return brd, tbs


def layout_table(ldir, workers):
    """Code layout against d2's and M6's IPC: make perf's programs relinked PAD bytes later (scripts/rtlprof's
    layout.sh builds them and runs both trees' smt2 RTL into DIR/rtl.txt), and the model on the same ELFs."""
    rtl = {}
    for line in open(Path(ldir) / "rtl.txt"):
        f = line.split()
        if len(f) == 6 and f[0] == "rtl":
            rtl[(f[1], f[2], f[3])] = int(f[5]) / int(f[4])
    pads = sorted({k[1] for k in rtl}, key=lambda s: int(s[3:]))
    progs = ("coremark_A", "coremark_B", "dhrystone")
    jobs = [(c, pd, p) for c in ("d2 smt2", "M6 smt2") for pd in pads for p in progs]

    def one(j):
        c, pd, p = j
        w = {"name": p, "elf": str(Path(ldir) / pd / f"{p}.elf"), "stdin": "", "ff": 0}
        r = tgrun.run_one(w, "rtl_m2", {**CFGS[c], "dram_lat": 30})
        return j, r["region"]["instr"] / r["region"]["cycles"]

    with ThreadPoolExecutor(max_workers=workers) as ex:
        mod = dict(ex.map(one, jobs))
    print("\n**Code layout: IPC with the code PAD bytes later** (rv64gc; smt2; RTL / model)\n")
    print("| Program | Pad | d2: RTL / model | d4s2 (M6): RTL / model |")
    print("|---|---|---|---|")
    out = {}
    for p in progs:
        for pd in pads:
            print(f"| {p} | {pd[3:]} | {rtl[('d2', pd, p)]:.3f} / {mod[('d2 smt2', pd, p)]:.3f} | "
                  f"{rtl[('d4s2', pd, p)]:.3f} / {mod[('M6 smt2', pd, p)]:.3f} |")
        sp = lambda v: f"{min(v):.3f}-{max(v):.3f} ({max(v) / min(v) - 1:.1%})"
        print(f"| {p} | spread | {sp([rtl[('d2', pd, p)] for pd in pads])} / "
              f"{sp([mod[('d2 smt2', pd, p)] for pd in pads])} | {sp([rtl[('d4s2', pd, p)] for pd in pads])} / "
              f"{sp([mod[('M6 smt2', pd, p)] for pd in pads])} |")
        out[p] = {pd: {"rtl_d2": rtl[("d2", pd, p)], "rtl_d4s2": rtl[("d4s2", pd, p)],
                       "model_d2": mod[("d2 smt2", pd, p)], "model_m6": mod[("M6 smt2", pd, p)]} for pd in pads}
    return out


def predict_table(bench, workers):
    """d4r1 (main c072fff: M6, FENCE.I by generation, the store ownership prefetch) in the board's shape, and what
    M7's static halves would cost a lone thread: the model on make perf's ELFs (rv64gc and rv64im, native)."""
    cfgs = {"M6 smt2": CFGS["M6 smt2"], "d4r1 smt2": {**CFGS["M6 smt2"], "rfo_pf": 1},
            "M6 smt2, halves": {**M6, "rob": 40, "lq": 12, "sq": 10, "llt": 24}}
    jobs = [(c, p, m) for c in cfgs for (p, m) in PROGS]

    def one(j):
        c, p, m = j
        w = {"name": p, "elf": f"{bench}/{m}-i10-r500/{p}.elf", "stdin": "", "ff": 0}
        r = tgrun.run_one(w, "rtl_m2", {**cfgs[c], "dram_lat": 30})
        return j, r["region"]

    with ThreadPoolExecutor(max_workers=workers) as ex:
        mod = dict(ex.map(one, jobs))
    print("\n**The model for d4r1 in the board's shape, and a lone thread under M7's static halves** (IPC)\n")
    print("| Program | M6 smt2 (d4s2) | d4r1 smt2 (+ ownership prefetch) | Change | Static halves (ROB 40, LQ 12, "
          "SQ 10) | Change |")
    print("|---|---|---|---|---|---|")
    out = {}
    for p, m in PROGS:
        v = {c: mod[(c, p, m)]["instr"] / mod[(c, p, m)]["cycles"] for c in cfgs}
        print(f"| {p} {m} | {v['M6 smt2']:.3f} | {v['d4r1 smt2']:.3f} | {pct(v['d4r1 smt2'] / v['M6 smt2'] - 1)} | "
              f"{v['M6 smt2, halves']:.3f} | {pct(v['M6 smt2, halves'] / v['M6 smt2'] - 1)} |")
        out[f"{p}|{m}"] = v
    # the suite on the SoC's uncore at 100 MHz (as §6.5): the whole smt2 window against M7's static halves
    sc = [("rtl_m2", {**m6.soc(100), **cfgs[c]}) for c in ("M6 smt2", "M6 smt2, halves")]
    data = dse.collect(sc, "rv64gc", workers=workers)
    s = [dse.summarize(data[dse.key("rv64gc", *c)[0]]) for c in sc]
    print(f"\nThe suite (rv64gc, the SoC's uncore): IPC {s[0]['suite_ipc']:.3f} with the whole smt2 window, "
          f"{s[1]['suite_ipc']:.3f} with static halves ({pct(s[1]['suite_ipc'] / s[0]['suite_ipc'] - 1)}).")
    out["suite"] = {"whole": s[0], "halves": s[1]}
    return out


COPY_BOARD = (1235609, 809078, 487947, 483772)   # MR23 memcpy-1048576: cycles d4s2, d4r1; instructions d4s2, d4r1


def copy_table(workers):
    """The model's ownership prefetch (rfo_pf) on its copy kernels in the board's shape (M6 smt2 on the SoC's uncore
    at 100 MHz), against the board's memcpy of 1 MiB (MR23: glibc's, d4s2 and d4r1). ws_copy_<k> copies k/2 KiB with
    newlib's memcpy, REPS = 4096 / k times; ws_copy_2048 is the board's case (1 MiB from a 1 MiB source)."""
    base = {**m6.soc(100), **CFGS["M6 smt2"]}
    cfgs = {"d4s2": base, "d4r1": {**base, "rfo_pf": 1}}
    sizes = (512, 1024, 2048, 4096)
    jobs = [(c, k) for c in cfgs for k in sizes]

    def one(j):
        c, k = j
        w = {"name": f"ws_copy_{k}", "elf": str(ROOT / "build" / "bench" / "rv64gc" / f"ws_copy_{k}.elf"),
             "stdin": "", "ff": 0}
        r = tgrun.run_one(w, "rtl_m2", cfgs[c])
        if r.get("error") or not r.get("region", {}).get("cycles"):
            raise SystemExit(f"tgsim failed on {w['elf']} ({c}): {r.get('error', '')}")
        return j, r["region"]

    with ThreadPoolExecutor(max_workers=workers) as ex:
        mod = dict(ex.map(one, jobs))
    print("\n**The store ownership prefetch on a large copy: the model against the board** (cycles a byte; the "
          "model's rename held by a full SQ, share of cycles)\n")
    print("| Copy | Instructions a byte | d4s2 | d4r1 (ownership prefetch) | Change | SQ full: d4s2 / d4r1 |")
    print("|---|---|---|---|---|---|")
    out = {}
    for k in sizes:
        n = k * 512 * (4096 // k)
        b, p = mod[("d4s2", k)], mod[("d4r1", k)]
        print(f"| model ws_copy_{k} ({k // 2} KiB) | {b['instr'] / n:.3f} | {b['cycles'] / n:.3f} | "
              f"{p['cycles'] / n:.3f} | {pct(p['cycles'] / b['cycles'] - 1)} | "
              f"{b.get('held_sq', 0) / b['cycles']:.1%} / {p.get('held_sq', 0) / p['cycles']:.1%} |")
        out[f"ws_copy_{k}"] = {"d4s2": b, "d4r1": p}
    c4, c5, i4, i5 = COPY_BOARD
    print(f"| board memcpy 1 MiB (glibc) | {i4 / 2 ** 20:.3f} | {c4 / 2 ** 20:.3f} | {c5 / 2 ** 20:.3f} | "
          f"{pct(c5 / c4 - 1)} | – |")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bench", help="make perf's ELFs: DIR/<march>-i10-r500/<program>.elf (without it the model's "
                    "tables are skipped and the JSON keeps their earlier results)")
    ap.add_argument("--rtl", action="append", default=[], help="CFG=LOG: perf.py's output, base d2, this side d4s2")
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--init", action="append", default=[],
                    help="NAME=LOG (d2, d4s2, d4r1): tb_boot's boot to /init")
    ap.add_argument("--board-logs", default=str(ROOT.parent / "fpga" / "kv260" / "board"))
    ap.add_argument("--layout", help="DIR of scripts/rtlprof/layout.sh's padded ELFs and RTL results")
    ap.add_argument("--predict", action="store_true", help="d4r1's model prediction (area_recovery.md §6.13)")
    ap.add_argument("--copy", action="store_true", help="the ownership prefetch on ws_copy against the board's memcpy")
    a = ap.parse_args()
    if a.predict and not a.bench:
        ap.error("--predict needs --bench")
    # the sections a run does not redo keep their earlier results
    res = json.loads(OUT.read_text()) if OUT.exists() else {}
    if a.bench:
        res.update(model_tables(a.bench, {r.split("=", 1)[0]: rtl_log(r.split("=", 1)[1]) for r in a.rtl},
                                a.workers))
    if a.predict:
        res["predict_d4r1"] = predict_table(a.bench, a.workers)
    if a.layout:
        res["layout"] = layout_table(a.layout, a.workers)
    if a.copy:
        res["copy"] = copy_table(a.workers)
    if a.init:
        brd, tbs = init_table({i.split("=", 1)[0]: i.split("=", 1)[1] for i in a.init}, a.board_logs)
        res["init"] = {"board": brd, "tb_boot": tbs}
    OUT.write_text(json.dumps(res, indent=1) + "\n")


def model_tables(bench, rtl, workers):
    """The model on make perf's ELFs in the four configurations, beside the RTL's make perf and the board (§6.12)."""
    jobs = [(c, p, m) for c in CFGS for (p, m) in PROGS]

    def one(j):
        c, p, m = j
        w = {"name": p, "elf": f"{bench}/{m}-i10-r500/{p}.elf", "stdin": "", "ff": 0}
        r = tgrun.run_one(w, "rtl_m2", {**CFGS[c], "dram_lat": 30})
        if r.get("error") or not r.get("region", {}).get("cycles"):
            raise SystemExit(f"tgsim failed on {w['elf']} ({c}): {r.get('error', '')}")
        return j, r["region"]

    with ThreadPoolExecutor(max_workers=workers) as ex:
        mod = dict(ex.map(one, jobs))
    res = {"cfgs": CFGS, "board": BOARD,
           "rtl": {c: {f"{p}|{m}": v for (p, m), v in t.items()} for c, t in rtl.items()},
           "model": {f"{c}|{p}|{m}": r for (c, p, m), r in mod.items()}}

    ipc = lambda r: r["instr"] / r["cycles"]
    print("**IPC: the board, the RTL (make perf) and the model** (rv64gc; the board runs the Linux set's builds)\n")
    print("| Program | Instructions per op: board / make perf's ELF | Board d2 / d4s2 | RTL smt2 d2 / d4s2 | "
          "Model smt2 d2 / M6 | Model vs RTL (smt2) | Model vs board | RTL st d2 / d4s2 | Model st d2 / M6 | "
          "Model vs RTL (st) |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for p, m in PROGS:
        b = BOARD.get(p) if m == "rv64gc" else None
        r_s, r_t = rtl.get("smt2", {}).get((p, m)), rtl.get("st", {}).get((p, m))
        ms = {k: ipc(mod[(k, p, m)]) for k in CFGS}
        inst = mod[("M6 st", p, m)]["instr"] / OPS[p]
        err = lambda x, y: f"{pct(x / y - 1)}"
        cells = [f"{b['d4s2'][1]:,} / {inst:,.0f}" if b else f"– / {inst:,.0f}",
                 f"{b['d2'][1] / b['d2'][0]:.3f} / {b['d4s2'][1] / b['d4s2'][0]:.3f}" if b else "–",
                 f"{r_s['d2'][1]:.3f} / {r_s['d4s2'][1]:.3f}" if r_s else "–",
                 f"{ms['d2 smt2']:.3f} / {ms['M6 smt2']:.3f}",
                 f"{err(ms['d2 smt2'], r_s['d2'][1])} / {err(ms['M6 smt2'], r_s['d4s2'][1])}" if r_s else "–",
                 (f"{pct(ms['d2 smt2'] / (b['d2'][1] / b['d2'][0]) - 1)} / "
                  f"{pct(ms['M6 smt2'] / (b['d4s2'][1] / b['d4s2'][0]) - 1)}") if b else "–",
                 f"{r_t['d2'][1]:.3f} / {r_t['d4s2'][1]:.3f}" if r_t else "–",
                 f"{ms['d2 st']:.3f} / {ms['M6 st']:.3f}",
                 f"{pct(ms['d2 st'] / r_t['d2'][1] - 1)} / {pct(ms['M6 st'] / r_t['d4s2'][1] - 1)}" if r_t else "–"]
        print(f"| {p} {m} | " + " | ".join(cells) + " |")
    print("\n**d2 to d4s2: the change in cycles per op** (minus is faster)\n")
    print("| Program | Board | RTL smt2 | Model smt2 | RTL st | Model st |")
    print("|---|---|---|---|---|---|")
    for p, m in PROGS:
        b = BOARD.get(p) if m == "rv64gc" else None
        r_s, r_t = rtl.get("smt2", {}).get((p, m)), rtl.get("st", {}).get((p, m))
        mc = {k: mod[(k, p, m)]["cycles"] for k in CFGS}
        cells = [pct(b["d4s2"][0] / b["d2"][0] - 1) if b else "–",
                 pct(r_s["d4s2"][0] / r_s["d2"][0] - 1) if r_s else "–", pct(mc["M6 smt2"] / mc["d2 smt2"] - 1),
                 pct(r_t["d4s2"][0] / r_t["d2"][0] - 1) if r_t else "–", pct(mc["M6 st"] / mc["d2 st"] - 1)]
        print(f"| {p} {m} | " + " | ".join(cells) + " |")
    return res


if __name__ == "__main__":
    main()
