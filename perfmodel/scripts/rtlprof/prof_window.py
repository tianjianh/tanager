"""A window of the boot profile: prof_m6.sv's counters between two of its snapshots, per core, as shares of the
window's cycles (area_recovery.md §6.14). Run tb_boot with prof_m6.sv bound and +prof_snap=N; each core then prints
smt2_prof_m6@CYCLE [INSTANCE] key value ... every N cycles. FROM and TO are cycles, multiples of N (1e6 steps: 84e6).
  python3 scripts/rtlprof/prof_window.py LOG FROM TO
"""
import re
import sys

ROWS = [  # (key, what it counts); shares are of the window's cycles unless marked as a count
    ("zc_fe_icmiss", "nothing commits, the ROB empty: fetch waits on an I$ miss"),
    ("zc_fe_misp", "... the refill after a mispredict"),
    ("zc_fe_flush", "... the refill after another flush"),
    ("zc_fe_other", "... other (fetch, decode, rename)"),
    ("zc_fe_sweep", "... the I$ sweep after FENCE.I"),
    ("zc_dtlb", "nothing commits: the head's DTLB retry"),
    ("zc_ld_miss", "... the head a load waiting on a D$ miss"),
    ("zc_ld_stq", "... the head a load waiting on a store"),
    ("zc_ld_other", "... the head another incomplete load"),
    ("zc_st", "... the head a store"),
    ("zc_serial", "... the head a serializing op (wfi when idle)"),
    ("zc_exec", "... the head another incomplete op"),
    ("zc_held", "... the head complete, held"),
    ("dr_wait", "the store drain waits on the D$"),
    ("dr_line", "... on a line (miss or ownership)"),
    ("sq_full", "rename held by a full SQ"),
    ("sq_full_stmiss", "... while the drain waits on a store's line"),
    ("rob_full", "rename held by a full ROB"),
    ("rob_full_ldmiss", "... the head a load waiting on a miss"),
    ("occ0", "D$ miss entries busy: none"),
    ("occ1", "... one"),
    ("occ2", "... two"),
    ("occ3", "... three"),
    ("occ4", "... four"),
    ("park_seqref", "fetch parked on a refill: the line after the previous refill's"),
    ("park_seqdl", "... the line after the last block delivered"),
    ("park_other", "... another line"),
]
COUNTS = [("misp", "mispredicts (count)"), ("rt_ld", "DTLB retries, loads (count)"),
          ("rt_st", "DTLB retries, stores (count)"), ("fencei", "FENCE.Is (count)"), ("rq", "D$ load requests (count)")]


def snaps(path):
    """{instance: {cycle: {key: value}}} from the smt2_prof_m6@ lines."""
    out = {}
    for line in open(path, errors="replace"):
        m = re.search(r"smt2_prof_m6@(\d+) \[(\S+)\] (.*)", line)
        if m:
            t = m.group(3).split()
            out.setdefault(m.group(2), {})[int(m.group(1))] = {t[i]: int(t[i + 1]) for i in range(0, len(t) - 1, 2)}
    return out


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    path, a, b = sys.argv[1], int(float(sys.argv[2])), int(float(sys.argv[3]))
    s = snaps(path)
    if not s:
        raise SystemExit(f"{path}: no smt2_prof_m6@ lines (run with +prof_snap=N)")
    win = {}
    for inst, by in sorted(s.items()):
        if a not in by or b not in by:
            raise SystemExit(f"{inst}: no snapshot at {a} or {b} (snapshots from {min(by)} to {max(by)})")
        win[inst] = {k: by[b][k] - by[a].get(k, 0) for k in by[b]}
    names = []
    for i, inst in enumerate(win):   # the SoC's core index from the instance path (tb_boot.dut.g_core[N]...)
        c = re.search(r"g_core\[(\d+)\]", inst)
        names.append(f"core {c.group(1)}" if c else f"core {i}")
    print(f"**{path}: cycles {a:,} to {b:,}**\n")
    print("| Counter | " + " | ".join(names) + " |")
    print("|---|" + "---|" * len(names))
    print("| instructions (IPC) | " + " | ".join(f"{w['instret']:,} ({w['instret'] / w['cycles']:.3f})"
                                               for w in win.values()) + " |")
    for k, what in ROWS:
        print(f"| {what} | " + " | ".join(f"{w.get(k, 0) / w['cycles']:.1%}" for w in win.values()) + " |")
    for k, what in COUNTS:
        print(f"| {what} | " + " | ".join(f"{w.get(k, 0):,}" for w in win.values()) + " |")


if __name__ == "__main__":
    main()
