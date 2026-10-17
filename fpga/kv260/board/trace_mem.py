"""Print the last N records of one hart with the memory fields: python3 trace_mem.py TRACE HART N"""
import struct, sys
REGS = ["zero","ra","sp","gp","tp","t0","t1","t2","s0","s1","a0","a1","a2","a3","a4","a5","a6","a7",
        "s2","s3","s4","s5","s6","s7","s8","s9","s10","s11","t3","t4","t5","t6"]
d = open(sys.argv[1], "rb").read(); want = int(sys.argv[2]); n = int(sys.argv[3])
recs = []
for i in range(len(d) // 64):
    hdr, insn = struct.unpack_from("<II", d, i * 64)
    if ((hdr >> 2) & 3) != want: continue
    pc, val, addr, sdat = struct.unpack_from("<QQQQ", d, i * 64 + 8)
    cyc = struct.unpack_from("<I", d, i * 64 + 40)[0]
    recs.append((i, hdr, insn, pc, val, addr, sdat, cyc))
for (i, hdr, insn, pc, val, addr, sdat, cyc) in recs[-n:]:
    kind = hdr & 3; rd_we = (hdr >> 7) & 1; rd = (hdr >> 9) & 31; st = (hdr >> 20) & 1
    op = insn & 0x7f
    tag = {0x03: "LOAD", 0x23: "STORE", 0x2f: "AMO"}.get(op, "")
    if op == 0x2f:
        f5 = insn >> 27
        tag = {2: "LR", 3: "SC", 1: "AMOSWAP", 0: "AMOADD", 4: "AMOXOR", 12: "AMOAND", 8: "AMOOR"}.get(f5, "AMO%d" % f5)
    if (insn & 3) != 3:  # compressed: c.lw/c.ld/c.sw/c.sd and the sp forms
        q, f3 = insn & 3, (insn >> 13) & 7
        if q == 0 and f3 in (2, 3): tag = "c.LOAD"
        if q == 0 and f3 in (6, 7): tag = "c.STORE"
        if q == 2 and f3 in (2, 3): tag = "c.LOADsp"
        if q == 2 and f3 in (6, 7): tag = "c.STOREsp"
    dest = "%s<-%#x" % (REGS[rd], val) if rd_we else ""
    mem = ("addr=%#x" % addr if (tag and addr) else "") + (" sd=%#x" % sdat if st else "")
    print("%6d k%d cyc=%10d pc=%#x insn=%08x %-8s %-28s %s" % (i, kind, cyc, pc, insn, tag, dest, mem))
