"""Print every record of a commit trace file, one line each.

Usage: python3 trace_dump.py boot.trace

A record is 64 bytes (the SoC track's commit trace): header (kind [1:0], hart [3:2],
rvc [6], rd_we [7], rd [13:9]), insn, then pc, value, addr and store data, and the
cycle at byte 40. For short traces, such as a hang's last records; the checker reads
long ones.
"""
import struct
import sys

REGS = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"]

d = open(sys.argv[1], "rb").read()
for i in range(len(d) // 64):
    hdr, insn = struct.unpack_from("<II", d, i * 64)
    pc, val, addr, sdat = struct.unpack_from("<QQQQ", d, i * 64 + 8)
    cyc = struct.unpack_from("<I", d, i * 64 + 40)[0]
    hart = (hdr >> 2) & 3
    rd_we = (hdr >> 7) & 1
    rd = (hdr >> 9) & 31
    rvc = "c" if (hdr >> 6) & 1 else " "
    dest = "%4s <- %#018x" % (REGS[rd], val) if rd_we else "(no rd)"
    print("%3d h%d cyc=%6d pc=%#011x insn=%#010x %s %s" % (i, hart, cyc, pc, insn, rvc, dest))
