#!/usr/bin/env python3
"""Where the scheduler's LUTs go (area-recovery study, plan §8.5 D18): synthesises the whole
S2 scheduler (tg_s2_sched_top) once as is and once per ablation, each a temporary copy of the
RTL with one function removed, and reports the LUTs each function costs (the difference).
The copies are not functional designs; they exist only to be counted.

  python3 -I fpga/spikes/scripts/s2_ablate.py [--cfg smt2] [--only a,b] [--out DIR]

Runs fpga/budget/tcl/unit_synth.tcl through tools/vivado_run.sh (synthesis + opt_design,
about 2 minutes each), one at a time. Prints a Markdown table.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
RTL = os.path.join(ROOT, "fpga", "spikes", "rtl")
FILES = ["tg_iq.sv", "tg_wake.sv", "tg_s2_sched_top.sv"]
GENERICS = ["STALE=0", "WAKE_ENC=1", "DUP_SEL=1", "EARLY_W=24", "MX=1"]

# name: (description, [(file, old, new), ...])
ABLATIONS = {
    "busy": ("guard's busy vector (OR of every row's dependency bits per column)",
             [("tg_iq.sv", "      for (int r = 0; r < ROWS; r++) busy |= dep_q[r];\n", "")]),
    "ready_id": ("readiness over the wakeup-ID columns (dependency AND-OR against W)",
                 [("tg_iq.sv", "      assign pend = |(dep_q[r] & ~w);", "      assign pend = 1'b0;")]),
    "mx": ("MX: row-dependency matrix, its per-column clear and its readiness term",
           [("tg_iq.sv", "      assign mpend = |(mdep_q[r] & ~mx_issued);", "      assign mpend = 1'b0;")]),
    "mx_clear": ("MX: only the per-column clear of the row-dependency bits",
                 [("tg_iq.sv", "(we[r] ? disp_mdep[bank_of(r)] : mdep_q[r]) & ~mx_free;",
                   "(we[r] ? disp_mdep[bank_of(r)] : mdep_q[r]);")]),
    "flush": ("flush by ROB age (per-row younger-than compare)",
              [("tg_iq.sv",
                "    assign kill[r] = flush_valid && tid_q[r] == flush_tid && (flush_all || younger);",
                "    assign kill[r] = 1'b0;")]),
    "room": ("per-thread caps (row counts and room counters)",
             [("tg_iq.sv",
               "      else if (cnt >= CAP)      room_q[t] <= '0;\n"
               "      else if (CAP - cnt >= DW) room_q[t] <= RMW'(DW);\n"
               "      else                      room_q[t] <= RMW'(CAP - cnt);\n",
               "      else                      room_q[t] <= RMW'(DW);\n")]),
    "wake_enc": ("wakeup-ID encode at select (ALU queues) into W",
                 [("tg_iq.sv", "  assign wake_now = wake_c;", "  assign wake_now = '0;")]),
    "delay_dec": ("harness: decode of the delay lines' wakeup IDs into W (10 sources x 104 columns)",
                  [("tg_s2_sched_top.sv",
                    "        if (dl_v_q[q][0] && !dl_long_q[q][0] && dl_id_q[q][0] == COL_W'(c)) wake_reg_d[c] = 1'b1;\n"
                    "        if (dl_v_q[q][3] &&  dl_long_q[q][3] && dl_id_q[q][3] == COL_W'(c)) wake_reg_d[c] = 1'b1;\n",
                    "")]),
}


def implicit_nets(rd):
    """Synth 8-11241 and 8-605 (implicit nets: a name used in a generate block before its declaration
    is a new, undriven net in Vivado only) about our sources: any file outside the run directory and
    the Xilinx installation (fpga/spikes/tcl/synth_check.tcl)."""
    run = os.path.realpath(rd) + "/"
    hits = set()
    try:
        with open(os.path.join(rd, "vivado.log"), errors="replace") as f:
            for line in f:
                if not re.search(r"\[Synth 8-(11241|605)\]", line):
                    continue
                m = re.search(r"\[([^\[\]]+):[0-9]+\]\s*$", line)
                if m and (os.path.realpath(m.group(1)).startswith(run) or "/Xilinx/" in m.group(1)):
                    continue
                hits.add(line.rstrip())
    except OSError:
        pass
    return sorted(hits)


def synth(name, cfg, files, out, flatten="rebuilt"):
    rd = os.path.join(out, "runs", name)
    shutil.rmtree(rd, ignore_errors=True)
    cmd = ["bash", os.path.join(ROOT, "tools", "vivado_run.sh"), rd,
           os.path.join(ROOT, "fpga", "budget", "tcl", "unit_synth.tcl"), ROOT, cfg,
           "tg_s2_sched_top", "-flatten", flatten]
    for g in GENERICS:
        cmd += ["-g", g]
    for f in files:
        cmd += ["-file", f]
    subprocess.run(cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    imp = implicit_nets(rd)
    if imp:
        # fails the variant and keeps its run directory for the diagnosis
        print(f"{name}: implicit nets in our sources (declare each signal before its first use):",
              *imp, sep="\n  ", file=sys.stderr)
        return None
    vals = {}
    try:
        with open(os.path.join(rd, "summary.txt")) as f:
            for line in f:
                k, _, v = line.strip().partition(" ")
                vals[k] = v.strip()
    except OSError:
        return None
    keep = os.path.join(out, "reports", name)
    os.makedirs(keep, exist_ok=True)
    for f in ("summary.txt", "util_hier.rpt"):
        if os.path.exists(os.path.join(rd, f)):
            shutil.copy(os.path.join(rd, f), keep)
    shutil.rmtree(rd, ignore_errors=True)
    return vals


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cfg", default="smt2")
    ap.add_argument("--only", default="")
    ap.add_argument("--out", default=os.path.join(
        os.environ.get("TANAGER_BUILD", os.path.expanduser("~/tanager-build")),
        os.path.basename(ROOT), "s2_ablate"))
    a = ap.parse_args()
    only = set(filter(None, a.only.split(",")))
    src = {f: open(os.path.join(RTL, f)).read() for f in FILES}
    rows = []
    base = synth("base", a.cfg, [os.path.join(RTL, f) for f in FILES], a.out)
    if base is None:
        sys.exit("baseline synthesis failed")
    flat = synth("base_none", a.cfg, [os.path.join(RTL, f) for f in FILES], a.out, "none")
    b = int(base["opt_lut"])
    print(f"baseline {a.cfg}: {b} LUTs, {base['opt_ff']} FFs, {base['opt_lut_dram']} LUTRAM"
          f" (flatten none: {flat['opt_lut'] if flat else '?'})", flush=True)
    for name, (desc, edits) in ABLATIONS.items():
        if only and name not in only:
            continue
        d = os.path.join(a.out, "src", name)
        os.makedirs(d, exist_ok=True)
        files = []
        for f in FILES:
            text = src[f]
            for ef, old, new in edits:
                if ef == f:
                    if old not in text:
                        sys.exit(f"{name}: anchor not found in {f}")
                    text = text.replace(old, new, 1)
            with open(os.path.join(d, f), "w") as fh:
                fh.write(text)
            files.append(os.path.join(d, f))
        v = synth(name, a.cfg, files, a.out)
        lut = int(v["opt_lut"]) if v else None
        rows.append((name, desc, lut, None if lut is None else b - lut))
        print(f"  {name:10s} {lut} LUTs ({'' if lut is None else b - lut} saved)", flush=True)
    print(f"\n| Function removed | LUTs left | Its cost |\n|---|---|---|")
    for name, desc, lut, d in rows:
        print(f"| {desc} | {lut if lut is not None else 'failed'} | {d if d is not None else ''} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
