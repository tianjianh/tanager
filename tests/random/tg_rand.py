#!/usr/bin/env python3
"""tg_rand: constrained-random RISC-V test programs for lockstep runs (docs/spec/verification.md §6.2).

Every program is reproducible from (seed, options). It runs bare-metal in M-mode at 0x8000_0000 and
exits through tohost; correctness comes from Spike lockstep, so the generator never predicts
results. It aims at the plan's risk areas (§9, §4.5, §4.9, §4.15):
  - LSU: store-to-load forwarding with exact and partial overlaps, cross-page aliasing, late store
    addresses (ordering violations), cache-miss streams;
  - early retirement: DIV/REM and missing loads with dependents, followed by data-dependent branches
    (mispredict storms), traps and interrupts while they are pending;
  - width 3: 16-byte-aligned groups of three instructions with RAW/WAW/WAR dependencies and two
    branches per group;
  - traps (misaligned, illegal, ecall/ebreak, access fault) that the handler skips; timer interrupts;
  - F/D (ISAs with f and d, e.g. rv64gc): arithmetic and FMA in every rounding mode, conversions,
    compares, classify and moves on special values (signed zeros, infinities, quiet and signalling
    NaNs, subnormals, NaN-boxed and unboxed singles), FP loads and stores with FP/integer forwarding
    through memory, fflags/frm/fcsr (reserved rounding modes included) and mstatus.FS, and long
    divides and square roots followed by dependents and a branch on their result;
  - the structures the FPGA-friendly rewrites touch (verification.md §6.2, §6.4): register pressure
    on the rename maps (one register written twice in a group, flushes in between), store bursts
    past the store queue's depth, every completion port in the same cycle, CLINT loads (MMIO), more
    long-latency operations than the core has tags, more multiplies and FP-to-FP operations waiting
    on a missing load than rename has wakeup tags, WFI, runs of CSR accesses for timer interrupts to
    meet at the head, illegal CSR writes, fetch faults and accesses to a page the runs deny (--deny);
  - with --vm PCT, that share of the programs runs its body in S-mode under Sv39: an identity map in
    4 KiB pages (TLB misses and page walks on every template), plus page faults, SFENCE.VMA and
    SRET (staying in S).

  tg_rand.py --seed 42 --isa rv64im -o prog.S
"""
import argparse
import random
import sys

# Registers the random code never writes:
#   x2 sp (stack), x3 gp (data region base), x4 tp (alias base: the data region one page up),
#   x30/x31 (trap handler scratch).
RESERVED = {0, 2, 3, 4, 30, 31}
WRITABLE = [r for r in range(32) if r not in RESERVED]
DATA_SIZE = 16384          # main data region, at gp
ALIAS_PAGES = 4            # tp = gp + ALIAS_PAGES * 4 KiB: same page offsets, different pages
DATA_BYTES = ALIAS_PAGES * 4096 + 4096   # gp region plus the alias page tp addresses (offsets < 2 KiB)
STREAM_SIZE = 65536        # cache-miss stream region (bigger than a 32 KiB L1); four times that under --vm
SET_STRIDE = 4096          # lines this far apart share an L1D set (32 KiB, 8 ways, 64-byte lines: every configuration)
PTR_SLOTS = 32             # table of known offsets at gp + 0, for late store addresses
PTR_STEP = 48              # the table holds slot * PTR_STEP + 256 (all below 2 KiB)
SPECIAL = [0, 1, 2, -1, -2, 0x7FFFFFFFFFFFFFFF, -0x8000000000000000, 0xFFFFFFFF, 0x80000000, -0x80000000,
           0x7FFFFFFF, 0x100000000, 63, 64, 31, 32]
# FP values: doubles, and singles that get NaN-boxed (an unboxed single reads as the canonical NaN).
FP_D = [0x0, 0x8000000000000000, 0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000000,
        0x7FF4000000000000, 0x7FF0000000000001, 0xFFF8000000000001, 0x0000000000000001, 0x800FFFFFFFFFFFFF,
        0x0010000000000000, 0x7FEFFFFFFFFFFFFF, 0x3FF0000000000000, 0xBFF0000000000000, 0x3FE0000000000000,
        0x4340000000000000, 0x43E0000000000000, 0xC3E0000000000000, 0x41DFFFFFFFC00000, 0x3CB0000000000000]
FP_S = [0x00000000, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7FA00000, 0x7F800001, 0x00000001,
        0x807FFFFF, 0x00800000, 0x7F7FFFFF, 0x3F800000, 0xBF800000, 0x3F000000, 0x4B800000, 0x4F000000,
        0xCF000000, 0x34000000]
RM = ["", "", ", rne", ", rtz", ", rdn", ", rup", ", rmm", ", dyn"]
DENY_PAGE = 0x80F00000     # the runs deny this page (run_random's --deny): its loads and stores fault
DENY_IO = 0x10001000       # and this unused device page: an MMIO load there gets a denied response
NOMEM_PA = 0x800           # nothing below the boot ROM: access faults (data and fetch)
SHARED_LINES = 4           # several harts (--harts, --shared): the lines they contend for
ATOMIC_LINE = SHARED_LINES - 1   # of those, the one plain stores never write: atomics with rd = x0 go only there
UNMAPPED_VA = 0x40000000   # under --vm, nothing is mapped here: page faults
NONCANON_VA = 0x0000004000000000  # bit 38 set, bits 63..39 clear: not a Sv39 address
LD = {"lb": 0, "lbu": 0, "lh": 1, "lhu": 1, "lw": 2, "lwu": 2, "ld": 3}
ST = {"sb": 0, "sh": 1, "sw": 2, "sd": 3}


def x(r):
    return f"x{r}"


class Gen:
    def __init__(self, seed, isa, irq, length, group3, vm=0, miss=2, pfx="", hartid=0, multi=None, shared=0):
        self.r = random.Random(seed)
        # Several harts (--harts): each runs a program of its own, its labels prefixed (pfx), its timer at its
        # own mtimecmp (hartid); multi = (its index, the number of harts) for the exit's barrier; shared: the
        # weight of the templates on the region all harts share (multi_program)
        self.pfx = pfx
        self.hartid = hartid
        self.multi = multi
        self.shared = shared
        self.seed = seed
        self.isa = isa
        base = isa[4:].split("_")[0].replace("g", "imafd")
        self.has_m = "m" in base
        self.has_a = "a" in base
        self.has_fd = "f" in base and "d" in base
        self.irq = irq
        self.length = length
        self.miss = miss
        self.group3 = group3
        self.lines = []
        self.nlabel = 0
        self.funcs = 0
        # --vm PCT: this share of the programs runs in S-mode under Sv39 (drawn first, from the seed)
        self.vm = bool(vm) and self.r.randrange(100) < vm
        self.stream_size = STREAM_SIZE * 4 if self.vm else STREAM_SIZE

    # ---- helpers ----
    def emit(self, s):
        self.lines.append("  " + s)

    def label(self, name=None):
        self.nlabel += 1
        return name or f".L{self.pfx}{self.nlabel}"

    def s(self, name):
        """A label of this hart's program (its own data, stream, stack, page tables, trap handler, functions)."""
        return self.pfx + name

    def mtimecmp(self):
        return "CLINT_MTIMECMP" + (f" + {8 * self.hartid}" if self.hartid else "")

    def place(self, lab):
        self.lines.append(f"{lab}:")

    def wr(self, avoid=()):
        return self.r.choice([r for r in WRITABLE if r not in avoid])

    def rd_any(self):
        return self.r.randrange(32)

    def imm12(self):
        return self.r.choice([0, 1, -1, 2047, -2048, self.r.randrange(-2048, 2048)])

    def addr_reg(self, size, region=DATA_SIZE, base=3, avoid=()):
        """A register holding an aligned address inside a region (base + offset)."""
        t = self.wr(avoid)
        how = self.r.randrange(3)
        if how == 0:  # constant offset
            off = self.r.randrange(PTR_SLOTS * 8, region - 8) & ~((1 << size) - 1)
            self.emit(f"li {x(t)}, {off}")
        else:  # data-dependent offset, masked into the region and aligned
            self.emit(f"andi {x(t)}, {x(self.rd_any())}, {min(region, 2048) - (1 << size)}")
            if how == 2 and region > 2048:
                self.emit(f"slli {x(t)}, {x(t)}, {self.r.randrange(1, 4)}")
                self.emit(f"andi {x(t)}, {x(t)}, {-(1 << size)}")
                self.emit(f"li {x(self.wr((t,) + tuple(avoid)))}, 0")  # some noise in between
        if how:
            self.emit(f"ori {x(t)}, {x(t)}, 256")      # never the pointer table at offsets 0..255
        self.emit(f"add {x(t)}, {x(t)}, {x(base)}")
        return t

    # ---- instruction classes ----
    def alu(self, rd=None, rs1=None, rs2=None):
        rd = self.wr() if rd is None else rd
        rs1 = self.rd_any() if rs1 is None else rs1
        rs2 = self.rd_any() if rs2 is None else rs2
        k = self.r.randrange(4)
        if k == 0:
            op = self.r.choice(["add", "sub", "and", "or", "xor", "sll", "srl", "sra", "slt", "sltu",
                                "addw", "subw", "sllw", "srlw", "sraw"])
            self.emit(f"{op} {x(rd)}, {x(rs1)}, {x(rs2)}")
        elif k == 1:
            op = self.r.choice(["addi", "andi", "ori", "xori", "slti", "sltiu", "addiw"])
            self.emit(f"{op} {x(rd)}, {x(rs1)}, {self.imm12()}")
        elif k == 2:
            op, w = self.r.choice([("slli", 64), ("srli", 64), ("srai", 64), ("slliw", 32), ("srliw", 32),
                                   ("sraiw", 32)])
            self.emit(f"{op} {x(rd)}, {x(rs1)}, {self.r.randrange(w)}")
        else:
            self.emit(f"{self.r.choice(['lui', 'auipc'])} {x(rd)}, {self.r.randrange(1 << 20)}")

    def muldiv(self, rd=None, rs1=None, rs2=None):
        if not self.has_m:
            return self.alu(rd, rs1, rs2)
        rd = self.wr() if rd is None else rd
        rs1 = self.rd_any() if rs1 is None else rs1
        rs2 = self.rd_any() if rs2 is None else rs2
        op = self.r.choice(["mul", "mulh", "mulhsu", "mulhu", "mulw", "div", "divu", "rem", "remu",
                            "divw", "divuw", "remw", "remuw"])
        self.emit(f"{op} {x(rd)}, {x(rs1)}, {x(rs2)}")
        return rd

    def load(self, rd=None, size=None, base=3, region=DATA_SIZE, off=None):
        op = self.r.choice([o for o, s in LD.items() if size is None or s == size])
        sz = LD[op]
        rd = self.wr() if rd is None else rd
        if off is None:
            a = self.addr_reg(sz, region, base)
            self.emit(f"{op} {x(rd)}, 0({x(a)})")
        else:
            self.emit(f"{op} {x(rd)}, {off}({x(base)})")
        return rd

    def store(self, size=None, base=3, region=DATA_SIZE, off=None, src=None):
        op = self.r.choice([o for o, s in ST.items() if size is None or s == size])
        src = self.rd_any() if src is None else src
        if off is None:
            a = self.addr_reg(ST[op], region, base)
            self.emit(f"{op} {x(src)}, 0({x(a)})")
        else:
            self.emit(f"{op} {x(src)}, {off}({x(base)})")

    # ---- templates ----
    def t_alu_burst(self):
        for _ in range(self.r.randrange(3, 12)):
            self.r.choice([self.alu, self.alu, self.muldiv])()

    def t_forwarding(self):
        """Store then load to the same or overlapping bytes: exact, contained and partial overlaps."""
        base = self.r.choice([3, 4])
        off = self.r.randrange(PTR_SLOTS * 8, 2040) & ~7
        ssz = self.r.randrange(4)
        self.store(size=ssz, base=base, off=off + (self.r.randrange(8 >> ssz) << ssz if ssz < 3 else 0))
        for _ in range(self.r.randrange(0, 3)):
            self.alu()
        for _ in range(self.r.randrange(1, 3)):
            lsz = self.r.randrange(4)
            loff = off + ((self.r.randrange(8 >> lsz) << lsz) if lsz < 3 else 0)
            self.load(size=lsz, base=self.r.choice([base, base, 7 - base]), off=loff)

    def t_alias(self):
        """Same page offset through gp and tp (different pages): must not forward or alias."""
        off = self.r.randrange(PTR_SLOTS * 8, 2040) & ~7
        self.store(size=3, base=3, off=off)
        self.store(size=self.r.randrange(4), base=4, off=off)
        self.load(size=3, base=3, off=off)
        self.load(size=self.r.randrange(4), base=4, off=off)

    def t_late_store(self):
        """A store whose address comes from a slow load (or a divide) while younger loads to maybe the
        same address go ahead: ordering-violation flushes."""
        slot = self.r.randrange(PTR_SLOTS)
        t = self.wr()
        self.emit(f"ld {x(t)}, {slot * 8}(x3)")          # a known offset from the pointer table
        if self.has_m and self.r.randrange(2):
            d = self.wr((t,))
            self.emit(f"li {x(d)}, 1")
            self.emit(f"divu {x(t)}, {x(t)}, {x(d)}")       # the same value, later
        self.emit(f"add {x(t)}, {x(t)}, x3")
        self.emit(f"sd {x(self.rd_any())}, 0({x(t)})")
        for _ in range(self.r.randrange(1, 4)):
            # The table holds offsets slot * PTR_STEP + 256 (see data()); hit it half the time.
            off = (slot if self.r.randrange(2) else self.r.randrange(PTR_SLOTS)) * PTR_STEP + 256
            lsz = self.r.randrange(4)
            self.load(size=lsz, off=off + ((8 >> lsz) - 1 << lsz if lsz < 3 and self.r.randrange(2) else 0))

    def t_miss_stream(self):
        """Loads striding through a region bigger than the L1, with consumers and branches behind them."""
        cnt, ptr = self.wr(), None
        ptr = self.wr((cnt,))
        stride = self.r.choice([64, 128, 4096 + 64, 8192 + 128, 576])
        n = self.r.randrange(4, 16)
        self.emit(f"la {x(ptr)}, {self.s('stream')}")
        self.emit(f"li {x(cnt)}, {n}")
        self.emit(f"andi {x(self.wr((cnt, ptr)))}, {x(self.rd_any())}, 0")
        top = self.label()
        self.place(top)
        v = self.wr((cnt, ptr))
        self.emit(f"{self.r.choice(['ld', 'lw', 'lbu'])} {x(v)}, {self.r.randrange(0, 64, 8)}({x(ptr)})")
        if self.r.randrange(2):
            w = self.wr((cnt, ptr, v))
            self.emit(f"add {x(w)}, {x(v)}, {x(self.rd_any())}")
        if self.r.randrange(3) == 0:
            self.emit(f"sd {x(v)}, {self.r.randrange(0, 64, 8)}({x(ptr)})")
        self.emit(f"addi {x(ptr)}, {x(ptr)}, {stride % 2048}")
        if stride >= 2048:
            self.emit(f"li {x(v)}, {stride - stride % 2048}")
            self.emit(f"add {x(ptr)}, {x(ptr)}, {x(v)}")
        # keep the pointer inside the stream region
        self.emit(f"la {x(v)}, {self.s('stream')}")
        self.emit(f"sub {x(ptr)}, {x(ptr)}, {x(v)}")
        self.emit(f"li {x(v)}, {self.stream_size - 64}")
        self.emit(f"and {x(ptr)}, {x(ptr)}, {x(v)}")
        self.emit(f"la {x(v)}, {self.s('stream')}")
        self.emit(f"add {x(ptr)}, {x(ptr)}, {x(v)}")
        self.emit(f"addi {x(cnt)}, {x(cnt)}, -1")
        self.emit(f"bnez {x(cnt)}, {top}")

    def t_miss_burst(self):
        """Back-to-back accesses to distinct lines of the stream region, none waiting on another's data, so that
        a core with several L1D MSHRs keeps 2-4 misses in flight (DR-149): lines in different sets; lines of
        one set (up to 12, past the 8 ways: evictions inside the burst); two accesses to one line (an MSHR
        merge); store misses among the loads; and stores that dirty lines of a set followed by loads that evict
        them (a Release beside new Acquires). Each address is a cheap ALU step from a base."""
        kind = self.r.choice(["spread", "same_set", "merge", "dirty_evict", "mixed"])
        per_set = self.stream_size // SET_STRIDE          # lines of the region in one set
        b = self.wr()
        p = self.wr((b,))
        t = self.wr((b, p))
        acc = self.wr((b, p, t))
        fixed = (b, p, t, acc)
        self.emit(f"la {x(b)}, {self.s('stream')}")
        self.emit(f"andi {x(acc)}, {x(self.rd_any())}, 0")
        loads = ["ld", "lw", "lwu", "lh", "lbu"]
        stores = ["sd", "sw", "sh", "sb"]
        if kind in ("same_set", "dirty_evict"):
            st = self.r.randrange(SET_STRIDE // 64) * 64
            picks = self.r.sample(range(per_set), self.r.randrange(4, min(per_set, 12) + 1))
            offs = [k * SET_STRIDE + st for k in picks]
        else:
            offs = [l * 64 for l in self.r.sample(range(self.stream_size // 64), self.r.randrange(2, 7))]
        ops = []
        for i, off in enumerate(offs):
            if kind == "dirty_evict":
                op = self.r.choice(stores) if i < max(1, len(offs) // 3) else self.r.choice(loads)
            elif kind == "mixed":
                op = self.r.choice(loads + stores)
            else:
                op = self.r.choice(loads)
            ops.append((off, op))
            if kind == "merge" and i == 0:
                ops.append((off, self.r.choice(loads)))      # the same line again: an MSHR merge
        vals = []
        for off, op in ops:
            self.emit(f"li {x(t)}, {off}")
            self.emit(f"add {x(p)}, {x(b)}, {x(t)}")
            imm = self.r.randrange(0, 64, 8)
            if op in stores:
                self.emit(f"{op} {x(self.rd_any())}, {imm}({x(p)})")
            else:
                v = self.wr(fixed)
                self.emit(f"{op} {x(v)}, {imm}({x(p)})")
                vals.append(v)
        for v in vals[-3:]:                                   # consumers behind the misses, and a branch on them
            self.emit(f"add {x(acc)}, {x(acc)}, {x(v)}")
        if vals and self.r.randrange(2):
            skip = self.label()
            self.emit(f"bnez {x(acc)}, {skip}")
            self.emit(f"addi {x(self.wr(fixed))}, {x(acc)}, 1")
            self.place(skip)

    def t_long_then_flush(self):
        """A long-latency result (divide or missing load), its consumers, and a data-dependent branch or a
        trap right behind it: flushes over pending (possibly early-retired) operations."""
        if self.has_m and self.r.randrange(2):
            v = self.muldiv()
        else:
            v = self.wr()
            self.emit(f"la {x(v)}, {self.s('stream')}")
            self.emit(f"ld {x(v)}, {self.r.randrange(0, 2040, 8)}({x(v)})")
        for _ in range(self.r.randrange(0, 3)):
            self.alu(rs1=v)
        t = self.wr((v,))
        self.emit(f"andi {x(t)}, {x(self.r.choice([v, self.rd_any()]))}, {self.r.choice([1, 2, 4, 3])}")
        skip = self.label()
        self.emit(f"{self.r.choice(['beqz', 'bnez'])} {x(t)}, {skip}")
        for _ in range(self.r.randrange(1, 4)):
            self.r.choice([self.alu, self.muldiv, self.load, self.store])()
        if self.r.randrange(3) == 0:
            self.t_trap()
        self.place(skip)

    def t_trap(self):
        """An exception the handler skips (a fetch fault returns through x1)."""
        k = self.r.randrange(9)
        if k == 0:  # misaligned load or store (or LR, SC, AMO: they fault too)
            sz = self.r.randrange(1, 4)
            off = (self.r.randrange(PTR_SLOTS * 8, 2000) & ~7) + self.r.randrange(1, 1 << sz)
            if self.has_a and self.r.randrange(4) == 0:
                t = self.wr()
                self.emit(f"addi {x(t)}, x3, {(off & ~3) + 2}")   # 2 bytes off a word boundary
                w = self.r.choice([".w", ".d"])
                self.emit(self.r.choice([f"lr{w} {x(self.wr((t,)))}, ({x(t)})",
                                         f"sc{w} {x(self.wr((t,)))}, {x(self.rd_any())}, ({x(t)})",
                                         f"amoswap{w} {x(self.wr((t,)))}, {x(self.rd_any())}, ({x(t)})"]))
            elif self.r.randrange(2):
                self.emit(f"{self.r.choice([o for o, s in LD.items() if s == sz])} {x(self.wr())}, {off}(x3)")
            else:
                self.emit(f"{self.r.choice([o for o, s in ST.items() if s == sz])} {x(self.rd_any())}, {off}(x3)")
        elif k == 1:
            self.emit("unimp")
        elif k == 2:
            self.emit("ecall")
        elif k == 3:
            self.emit("ebreak")
        elif k < 6:  # access fault: nothing is mapped below the boot ROM
            t = self.wr()
            self.emit(f"li {x(t)}, {self.r.randrange(0x40, 0x800, 8)}")
            if k == 4:
                self.emit(f"ld {x(self.wr())}, 0({x(t)})")
            else:
                self.emit(f"sd {x(self.rd_any())}, 0({x(t)})")
        elif k == 6:  # a write to a read-only CSR: illegal (reported by the CSR unit's port)
            csr = self.r.choice(["cycle", "instret", "time", "mvendorid", "marchid", "mimpid", "mhartid"])
            self.emit(self.r.choice([f"csrw {csr}, {x(self.rd_any())}", f"csrrs {x(self.wr())}, {csr}, {x(self.wr())}",
                                     f"csrrwi {x(self.wr())}, {csr}, {self.r.randrange(32)}"]))
        elif k == 7:  # a fetch from no memory (or, under --vm, from no mapping): the handler returns to x1
            t = self.wr((1,))
            self.emit(f"li {x(t)}, {self.r.choice([NOMEM_PA, NOMEM_PA + 0x100, UNMAPPED_VA])}")
            self.emit(f"jalr x1, 0({x(t)})")
        else:  # the denied page: a bus error where the run denies it (--deny), plain memory where not.
            # Loads and atomics only: a denied fill for a committed store cannot be precise (core-lsu.md).
            t = self.wr()
            if not self.vm and self.r.randrange(4) == 0:  # a device load (untranslated: see t_mmio)
                self.emit(f"li {x(t)}, {DENY_IO + self.r.randrange(0, 4096, 8)}")
                self.emit(f"ld {x(self.wr((t,)))}, 0({x(t)})")
                return
            self.emit(f"li {x(t)}, {DENY_PAGE + self.r.randrange(0, 4096, 8)}")
            if self.has_a and self.r.randrange(3) == 0:
                self.emit(self.r.choice([f"amoadd.d {x(self.wr((t,)))}, {x(self.rd_any())}, ({x(t)})",
                                         f"lr.d {x(self.wr((t,)))}, ({x(t)})",
                                         f"sc.d {x(self.wr((t,)))}, {x(self.rd_any())}, ({x(t)})"]))
            else:
                self.emit(f"{self.r.choice(['ld', 'lw', 'lbu'])} {x(self.wr((t,)))}, 0({x(t)})")

    def t_group3(self):
        """Three instructions in one 16-byte fetch block, with dependencies inside the group and up to
        two branches (plan §4.15)."""
        self.emit(".balign 16")
        a, b, c = self.wr(), self.wr(), self.wr()
        kind = self.r.randrange(6 if self.has_fd else 5)
        end = self.label()
        if kind == 0:  # RAW chain
            self.alu(rd=a)
            self.alu(rd=b, rs1=a)
            self.r.choice([self.alu, self.muldiv])(rd=c, rs1=b, rs2=a)
        elif kind == 1:  # WAW
            self.alu(rd=a)
            self.alu(rd=a, rs1=self.rd_any())
            self.alu(rd=b, rs1=a)
        elif kind == 2:  # WAR
            self.alu(rd=a, rs1=b)
            self.alu(rd=b, rs1=c)
            self.alu(rd=c, rs1=a)
        elif kind == 3:  # two branches in the group
            l1 = self.label()
            self.emit(f"{self.r.choice(['beq', 'bne', 'blt', 'bgeu'])} {x(self.rd_any())}, {x(self.rd_any())}, {l1}")
            self.alu(rd=a)
            self.emit(f"{self.r.choice(['beq', 'bne', 'bltu', 'bge'])} {x(a)}, {x(self.rd_any())}, {end}")
            self.alu(rd=b, rs1=a)
            self.place(l1)
        elif kind == 4:  # load-use and store in a group
            self.emit(f"ld {x(a)}, {self.r.randrange(PTR_SLOTS * 8, 2040, 8)}(x3)")
            self.alu(rd=b, rs1=a)
            self.emit(f"sd {x(b)}, {self.r.randrange(PTR_SLOTS * 8, 2040, 8)}(x3)")
        else:  # FP: an operation, a dependent one, and a store of the result
            fa, fb, w = self.fr(), self.fr(), self.r.choice([".s", ".d"])
            self.emit(f"fmul{w} {fa}, {self.fr()}, {self.fr()}")
            self.emit(f"fadd{w} {fb}, {fa}, {self.fr()}")
            self.emit(f"fsd {fb}, {self.r.randrange(PTR_SLOTS * 8, 2040, 8)}(x3)")
        self.place(end)

    def t_amo(self):
        if not self.has_a:
            return self.t_forwarding()
        a = self.addr_reg(3)
        k = self.r.randrange(3)
        if k == 2:  # one LR/SC pair, the SC with rd = x0: nothing sees whether it succeeded
            w = self.r.choice([".d", ".w"])
            self.emit(f"lr{w} {x(self.wr((a,)))}, ({x(a)})")
            self.emit(f"sc{w} x0, {x(self.rd_any())}, ({x(a)})")
        elif k == 1:
            op = self.r.choice(["amoadd", "amoswap", "amoand", "amoor", "amoxor", "amomin", "amomax",
                                "amominu", "amomaxu"]) + self.r.choice([".d", ".w"]) + self.r.choice(["", ".aq", ".rl", ".aqrl"])
            self.emit(f"{op} {x(self.wr((a,)))}, {x(self.rd_any())}, ({x(a)})")
        else:  # bounded LR/SC retry loop (SC may fail spuriously in the RTL: the checker adopts it)
            n = self.wr((a,))
            v = self.wr((a, n))
            f = self.wr((a, n, v))
            self.emit(f"li {x(n)}, 8")
            top, done = self.label(), self.label()
            self.place(top)
            w = self.r.choice([".d", ".w"])
            self.emit(f"lr{w} {x(v)}, ({x(a)})")
            self.emit(f"addi {x(v)}, {x(v)}, {self.r.randrange(-8, 8)}")
            self.emit(f"sc{w} {x(f)}, {x(v)}, ({x(a)})")
            self.emit(f"beqz {x(f)}, {done}")
            self.emit(f"addi {x(n)}, {x(n)}, -1")
            self.emit(f"bnez {x(n)}, {top}")
            self.place(done)

    def t_csr(self):
        k = self.r.randrange(4)
        if k == 0:
            self.emit(f"csrr {x(self.wr())}, {self.r.choice(['cycle', 'instret', 'mcycle', 'minstret', 'time'])}")
        elif k == 1:
            self.emit(f"csrw mscratch, {x(self.rd_any())}")
            self.emit(f"csrr {x(self.wr())}, mscratch")
        elif k == 2:
            self.emit(f"csrr {x(self.wr())}, mstatus")
        else:
            self.emit(self.r.choice(["fence", "fence rw, rw", "fence r, r", "fence w, w", "fence.i",
                                     "fence iorw, iorw"]))

    def t_call(self):
        """Calls and returns through the return-address stack."""
        self.funcs += 1
        self.emit(f"jal x1, {self.s('tg_func')}{self.r.randrange(4)}")
        if self.r.randrange(2):
            t = self.wr((1,))
            fwd = self.label()
            self.emit(f"la {x(t)}, {fwd}")
            self.emit(f"jalr {x(self.wr((t,)))}, 0({x(t)})")
            self.place(fwd)

    # ---- structures the FPGA-friendly rewrites touch (verification.md §6.2, §6.4) ----
    def t_reg_pressure(self):
        """A few registers written over and over: rename groups that write one register twice (the
        later slot wins in the XOR-banked map) and read it in the same group, late completions, and
        flushes in between, after which the committed mappings answer."""
        if self.has_fd and self.r.randrange(3) == 0:
            return self.t_fp_pressure()
        pool = self.r.sample(WRITABLE, self.r.randrange(2, 5))

        def pick():
            return self.r.choice(pool)

        for _ in range(self.r.randrange(8, 24)):
            k = self.r.randrange(12)
            rd = 0 if self.r.randrange(10) == 0 else pick()  # x0 renames nothing
            if k < 6:
                self.alu(rd=rd, rs1=pick(), rs2=pick())
            elif k < 8:
                self.muldiv(rd=rd, rs1=pick(), rs2=pick())   # completes late
            elif k == 8:
                self.emit(f"ld {x(pick())}, {self.r.randrange(PTR_SLOTS * 8, 2040, 8)}(x3)")
            elif k == 9:
                self.emit(f"sd {x(pick())}, {self.r.randrange(PTR_SLOTS * 8, 2040, 8)}(x3)")
            elif k == 10:  # a data-dependent branch over writes to the same registers
                skip = self.label()
                self.emit(f"{self.r.choice(['beq', 'bne', 'blt', 'bgeu'])} {x(pick())}, {x(pick())}, {skip}")
                for _ in range(self.r.randrange(1, 4)):
                    self.alu(rd=pick(), rs1=pick(), rs2=pick())
                self.place(skip)
            else:  # an exception: the flush restores the committed mappings
                self.emit(self.r.choice(["ecall", "ebreak", "unimp"]))

    def t_fp_pressure(self):
        """The same on the FP map: two or three FP registers, with moves, loads, stores, a long divide
        and a branch on an FP compare."""
        pool = [f"f{i}" for i in self.r.sample(range(32), self.r.randrange(2, 4))]

        def pick():
            return self.r.choice(pool)

        for _ in range(self.r.randrange(8, 20)):
            k = self.r.randrange(10)
            w = self.r.choice([".s", ".d"])
            if k < 4:
                op = self.r.choice(["fadd", "fsub", "fmul", "fsgnj", "fsgnjx", "fmin", "fmax"])
                rm = self.r.choice(RM) if op in ("fadd", "fsub", "fmul") else ""
                self.emit(f"{op}{w} {pick()}, {pick()}, {pick()}{rm}")
            elif k == 4:
                self.emit(f"fmadd{w} {pick()}, {pick()}, {pick()}, {pick()}{self.r.choice(RM)}")
            elif k == 5:
                self.emit(f"fdiv{w} {pick()}, {pick()}, {pick()}{self.r.choice(RM)}")
            elif k == 6:
                self.emit(f"fmv.d.x {pick()}, {x(self.rd_any())}")
            elif k == 7:
                self.emit(f"fld {pick()}, {self.r.randrange(PTR_SLOTS * 8, 2040, 8)}(x3)")
            elif k == 8:
                self.emit(f"fsd {pick()}, {self.r.randrange(PTR_SLOTS * 8, 2040, 8)}(x3)")
            else:
                t = self.wr()
                skip = self.label()
                self.emit(f"{self.r.choice(['flt', 'fle', 'feq'])}{w} {x(t)}, {pick()}, {pick()}")
                self.emit(f"{self.r.choice(['beqz', 'bnez'])} {x(t)}, {skip}")
                self.emit(f"fadd{w} {pick()}, {pick()}, {pick()}")
                self.place(skip)

    def t_store_burst(self):
        """More stores than the store queue holds, in a 64-byte window: sizes and offsets overlap, some
        data arrives late, loads in between forward from deep entries, and a branch may squash the
        youngest (the queue's payload in LUTRAM is read by index: data, address, size, ROB index)."""
        base = self.r.choice([3, 3, 4])
        win = self.r.randrange(PTR_SLOTS * 8, 2040 - 64) & ~7
        late = self.muldiv() if self.has_m and self.r.randrange(2) else None
        n = self.r.randrange(8, 25)
        cut = self.r.randrange(n) if self.r.randrange(3) == 0 else -1
        skip = None
        for i in range(n):
            if i == cut:
                t = self.wr()
                self.emit(f"andi {x(t)}, {x(self.rd_any())}, 1")
                skip = self.label()
                self.emit(f"bnez {x(t)}, {skip}")
            sz = self.r.randrange(4)
            off = win + (self.r.randrange(64 >> sz) << sz)
            if self.has_fd and sz >= 2 and self.r.randrange(5) == 0:
                self.emit(f"{'fsw' if sz == 2 else 'fsd'} {self.fr()}, {off}({x(base)})")
            else:
                src = late if late is not None and self.r.randrange(3) == 0 else self.rd_any()
                self.store(size=sz, base=base, off=off, src=src)
            if self.r.randrange(3) == 0:
                lsz = self.r.randrange(4)
                self.load(size=lsz, base=base, off=win + (self.r.randrange(64 >> lsz) << lsz))
        if skip:
            self.place(skip)
        if self.r.randrange(4) == 0:
            self.emit(self.r.choice(["fence", "fence rw, rw", "fence w, w"]))

    def t_all_ports(self):
        """Independent operations for every completion port, a few groups in a row, so that several
        ports report to the ROB in one cycle (its flags are one LUTRAM table per reporting port)."""
        def branch():
            lab = self.label()
            self.emit(f"{self.r.choice(['beq', 'bne'])} x0, x0, {lab}")  # predictable either way
            self.place(lab)

        for _ in range(self.r.randrange(2, 5)):
            ops = [self.alu, self.alu, self.muldiv, branch,
                   lambda: self.load(size=3, off=self.r.randrange(PTR_SLOTS * 8, 2040, 8)),
                   lambda: self.store(size=3, off=self.r.randrange(PTR_SLOTS * 8, 2040, 8))]
            if self.has_fd:
                ops += [self.fp_op, self.fp_to_int]
            self.r.shuffle(ops)
            for op in ops:
                op()

    def t_mmio(self):
        """A load from the CLINT (a device region; performed at the ROB head, its value adopted in
        lockstep), its dependents, and a branch on the value."""
        t = self.wr()
        self.emit(f"li {x(t)}, {self.r.choice(['CLINT_MTIME', self.mtimecmp()])}")
        v = self.wr((t,))
        self.emit(f"ld {x(v)}, 0({x(t)})")
        if self.r.randrange(2):
            self.alu(rs1=v)
        if self.r.randrange(2):
            skip = self.label()
            self.emit(f"andi {x(t)}, {x(v)}, 1")
            self.emit(f"beqz {x(t)}, {skip}")
            self.alu()
            self.place(skip)

    def t_long_burst(self):
        """More long-latency operations in flight than the core has tags (LLT_ENTRIES = 16):
        independent divides, FP divides and square roots, and loads that miss, so rename waits for a
        tag."""
        p = self.wr()
        self.emit(f"la {x(p)}, {self.s('stream')}")
        self.emit(f"li {x(self.wr((p,)))}, {self.r.randrange(4) * 2048}")
        for i in range(self.r.randrange(12, 28)):
            k = self.r.randrange(3 if self.has_fd else 2)
            if k == 0 and self.has_m:
                op = self.r.choice(["div", "divu", "rem", "remu", "divw", "remuw"])
                self.emit(f"{op} {x(self.wr((p,)))}, {x(self.rd_any())}, {x(self.rd_any())}")
            elif k == 2:
                w = self.r.choice([".s", ".d"])
                self.emit(f"fdiv{w} {self.fr()}, {self.fr()}, {self.fr()}" if self.r.randrange(2) else
                          f"fsqrt{w} {self.fr()}, {self.fr()}")
            else:  # a new line of the stream region each time: misses
                self.emit(f"ld {x(self.wr((p,)))}, {(i * 64) % 2048}({x(p)})")

    def t_tag_burst(self):
        """More operations waiting than rename has wakeup tags (16): a load that misses feeds integer
        multiplies and, with F/D, FP-to-FP operations on its value moved to an FP register, all with
        distinct destinations. They wait in IQ_A1 and IQ_FP (ten rows each) while the load is
        outstanding, so rename runs out of tags (tg_rename's tag_short; verification.md §6.4). Integer
        multiplies alone fill IQ_A1 first, so it needs F/D."""
        if not self.has_m:
            return self.t_long_burst()
        p = self.wr((1,))
        t = self.wr((1, p))
        self.emit(f"la {x(p)}, {self.s('stream')}")
        self.emit(f"li {x(t)}, {self.r.randrange(self.stream_size // 64) * 64}")
        self.emit(f"add {x(p)}, {x(p)}, {x(t)}")
        src = self.wr((1, p))
        self.emit(f"ld {x(src)}, 0({x(p)})")              # a line of the stream region: likely a miss
        ints = self.r.sample([r for r in WRITABLE if r not in (1, p, src)], self.r.randrange(8, 12))
        fps, fsrc = [], None
        if self.has_fd:
            fsrc = self.r.randrange(32)
            self.emit(f"fmv.d.x f{fsrc}, {x(src)}")
            fps = self.r.sample([f for f in range(32) if f != fsrc], self.r.randrange(8, 12))
        for i in range(max(len(ints), len(fps))):
            if i < len(ints):
                op = self.r.choice(["mul", "mulw", "mulh", "mulhu", "mulhsu"])
                self.emit(f"{op} {x(ints[i])}, {x(src)}, {x(self.r.choice([src, self.rd_any()]))}")
            if i < len(fps):
                w = self.r.choice([".s", ".d"])
                a, b = f"f{fsrc}", self.r.choice([f"f{fsrc}", self.fr()])
                self.emit(self.r.choice([f"fmul{w} f{fps[i]}, {a}, {b}", f"fadd{w} f{fps[i]}, {a}, {b}",
                                         f"fmadd{w} f{fps[i]}, {a}, {b}, {self.fr()}",
                                         f"fsgnjx{w} f{fps[i]}, {a}, {b}", f"fmax{w} f{fps[i]}, {a}, {b}"]))

    def t_sret(self):
        """Under --vm (S-mode): SRET to the next instruction, staying in S (sstatus.SPP = S). The ROB's
        head takes the same next-PC path (xepc) as for MRET, which every trap handler retires."""
        t = self.wr((1,))
        lab = self.label()
        self.emit(f"la {x(t)}, {lab}")
        self.emit(f"csrw sepc, {x(t)}")
        self.emit(f"li {x(t)}, 0x100")
        self.emit(f"csrs sstatus, {x(t)}")
        if self.r.randrange(2):
            self.alu()
        self.emit("sret")
        self.place(lab)

    def t_csr_burst(self):
        """Programs with --irq: a run of CSR accesses. They execute one at a time at the ROB's head, so a
        timer interrupt taken meanwhile meets a CSR instruction there, usually still in EX. That is when
        trap entry's writes of xepc, xcause and xtval to the CSR unit's cold registers (written over
        three cycles) meet the instruction's own access (the core track's fn2). The scratch register is
        the only one written; the trap handler never uses it."""
        scratch = "sscratch" if self.vm else "mscratch"
        reads = ["sstatus", "sie", "sscratch", "stvec", "sepc"] if self.vm else \
                ["mstatus", "mie", "mscratch", "mtvec", "mcause", "mepc", "mtval"]
        for _ in range(self.r.randrange(8, 25)):
            k = self.r.randrange(6)
            if k == 0:
                self.emit(f"csrw {scratch}, {x(self.rd_any())}")
            elif k == 1:
                self.emit(f"csrrs {x(self.wr())}, {scratch}, {x(self.rd_any())}")
            elif k == 2:
                self.emit(f"csrrc {x(self.wr())}, {scratch}, {x(self.rd_any())}")
            elif k == 3:
                self.emit(f"csrrwi {x(self.wr())}, {scratch}, {self.r.randrange(32)}")
            else:
                self.emit(f"csrr {x(self.wr())}, {self.r.choice(reads)}")

    def t_wfi(self):
        """WFI: wakes on the timer interrupt (programs with --irq), else retires after the core's
        time-out."""
        self.emit("wfi")
        if self.r.randrange(2):
            self.alu()

    def t_vm(self):
        """Under --vm: page faults (an unmapped address, a non-canonical one, a fetch from an unmapped
        page), SFENCE.VMA, and loads one page apart through the stream region (TLB misses)."""
        k = self.r.randrange(6)
        t = self.wr((1,))
        if k < 2:
            self.emit(f"li {x(t)}, {UNMAPPED_VA if k == 0 else NONCANON_VA:#x}")
            if self.has_a and self.r.randrange(4) == 0:
                self.emit(self.r.choice([f"lr.d {x(self.wr((t,)))}, ({x(t)})",
                                         f"sc.d {x(self.wr((t,)))}, {x(self.rd_any())}, ({x(t)})",
                                         f"amoor.d {x(self.wr((t,)))}, {x(self.rd_any())}, ({x(t)})"]))
            elif self.r.randrange(2):
                self.emit(f"{self.r.choice(['ld', 'lw', 'lbu'])} {x(self.wr((t,)))}, {self.r.randrange(0, 2040, 8)}({x(t)})")
            else:
                self.emit(f"{self.r.choice(['sd', 'sw', 'sb'])} {x(self.rd_any())}, {self.r.randrange(0, 2040, 8)}({x(t)})")
        elif k == 2:
            self.emit(f"li {x(t)}, {UNMAPPED_VA + self.r.randrange(0, 4096, 4):#x}")
            self.emit(f"jalr x1, 0({x(t)})")   # instruction page fault: the handler returns to x1
        elif k == 3:
            if self.r.randrange(2):
                self.emit("sfence.vma")
            else:
                self.emit(f"la {x(t)}, {self.s('stream')}")
                self.emit(f"sfence.vma {x(t)}, x0")
        else:
            self.emit(f"la {x(t)}, {self.s('stream')}")
            v = self.wr((t,))
            self.emit(f"li {x(v)}, {self.r.randrange(self.stream_size // 4096) * 4096}")
            self.emit(f"add {x(t)}, {x(t)}, {x(v)}")
            for _ in range(self.r.randrange(3, 10)):
                self.emit(f"{self.r.choice(['ld', 'lw', 'sd'])} {x(v)}, {self.r.randrange(0, 2040, 8)}({x(t)})")
                self.emit(f"li {x(v)}, {4096 + 64 * self.r.randrange(8)}")
                self.emit(f"add {x(t)}, {x(t)}, {x(v)}")
                # stay inside the stream region
                self.emit(f"la {x(v)}, {self.s('stream')}")
                self.emit(f"sub {x(t)}, {x(t)}, {x(v)}")
                self.emit(f"li {x(v)}, {self.stream_size - 4096}")
                self.emit(f"and {x(t)}, {x(t)}, {x(v)}")
                self.emit(f"la {x(v)}, {self.s('stream')}")
                self.emit(f"add {x(t)}, {x(t)}, {x(v)}")

    # ---- F and D ----
    # ---- several harts (--harts with --shared): the region all of them share ----
    def sh_addr(self, size, avoid=(), lines=range(SHARED_LINES)):
        """A register holding an aligned address in the shared lines (in `lines` of them)."""
        t = self.wr(avoid)
        self.emit(f"la {x(t)}, shared")
        off = self.r.choice(list(lines)) * 64 + self.r.randrange(0, 64, 1 << size)
        if off:
            self.emit(f"addi {x(t)}, {x(t)}, {off}")
        return t

    def sh_own(self, size, avoid=()):
        """A register holding an aligned address in one of this hart's doublewords of the plain stores' lines: hart
        i of n owns doublewords i, i + n, ... of each. Two harts' plain stores to the same bytes may reach memory
        in either order, whatever their commit order, and a load that shows which can come far past lockstep's
        windows (verification.md §3.7); so plain stores never share bytes, and the races are loads against stores
        and atomics against both."""
        i, n = self.multi
        t = self.wr(avoid)
        self.emit(f"la {x(t)}, shared")
        dw = self.r.choice(range(i % n, 8, n))
        off = self.r.randrange(ATOMIC_LINE) * 64 + dw * 8 + self.r.randrange(0, 8, 1 << size)
        if off:
            self.emit(f"addi {x(t)}, {x(t)}, {off}")
        return t

    def t_sh_amo(self):
        """AMOs on the shared words, some with rd = x0 (as Linux's amoadd and amoor) and some ordered. One with
        rd = x0 reads nothing lockstep can see: a plain store of another hart that the core lands after it could
        not be told from one before (verification.md §3.7), so those go to the line plain stores never write,
        where they race only other atomics (which the core never reorders)."""
        for _ in range(self.r.randrange(1, 4)):
            w = self.r.choice("wd")
            unseen = self.r.randrange(3) == 0
            a = self.sh_addr(2 if w == "w" else 3, lines=[ATOMIC_LINE] if unseen else range(SHARED_LINES))
            op = self.r.choice(["add", "swap", "or", "and", "xor", "max", "min", "maxu", "minu"])
            rd = 0 if unseen else self.wr((a,))
            self.emit(f"amo{op}.{w}{self.r.choice(['', '.aq', '.rl', '.aqrl'])} {x(rd)}, {x(self.rd_any())}, ({x(a)})")

    def t_sh_lrsc(self):
        """A constrained LR/SC loop on a shared word, at most eight tries: its forward progress is not
        guaranteed against other harts' stores and AMOs, so the bound keeps the program finite."""
        w = self.r.choice("wd")
        a = self.sh_addr(2 if w == "w" else 3)
        v = self.wr((a,))
        f = self.wr((a, v))
        n = self.wr((a, v, f))
        retry, done = self.label(), self.label()
        self.emit(f"li {x(n)}, 8")
        self.place(retry)
        self.emit(f"lr.{w}{self.r.choice(['', '.aq'])} {x(v)}, ({x(a)})")
        self.emit(f"{self.r.choice(['addi', 'xori', 'ori'])} {x(v)}, {x(v)}, {self.r.randrange(1, 2048)}")
        self.emit(f"sc.{w}{self.r.choice(['', '.rl'])} {x(f)}, {x(v)}, ({x(a)})")
        self.emit(f"beqz {x(f)}, {done}")
        self.emit(f"addi {x(n)}, {x(n)}, -1")
        self.emit(f"bnez {x(n)}, {retry}")
        self.place(done)

    def t_sh_plain(self):
        """Plain loads and stores of the shared words: racy, so lockstep takes a load's value from another
        hart's write where one could still be seen (verification.md §3.7)."""
        for _ in range(self.r.randrange(2, 6)):
            size = self.r.randrange(4)
            load = self.r.randrange(2)
            a = self.sh_addr(size) if load else self.sh_own(size)   # stores: this hart's bytes, not the atomics' line
            if load:
                op = ["lb", "lh", "lw", "ld"][size] if size == 3 or self.r.randrange(2) else ["lbu", "lhu", "lwu"][size]
                self.emit(f"{op} {x(self.wr((a,)))}, 0({x(a)})")
            else:
                self.emit(f"{['sb', 'sh', 'sw', 'sd'][size]} {x(self.rd_any())}, 0({x(a)})")

    def t_sh_fence(self):
        """Shared accesses on both sides of a fence."""
        self.t_sh_plain()
        self.emit(self.r.choice(["fence rw, rw", "fence r, r", "fence w, w", "fence r, rw", "fence rw, w", "fence w, r",
                                 "fence.tso"]))
        self.r.choice([self.t_sh_plain, self.t_sh_amo])()

    def t_sh_line(self):
        """Stores of this hart to its own word of a shared line, loads of the others' (false sharing)."""
        a = self.wr()
        self.emit(f"la {x(a)}, shared")
        line = self.r.randrange(ATOMIC_LINE)   # not the atomics' line
        if line:
            self.emit(f"addi {x(a)}, {x(a)}, {line * 64}")
        own = 8 * (self.multi[0] % 8)
        for _ in range(self.r.randrange(1, 4)):
            self.emit(f"sd {x(self.rd_any())}, {own}({x(a)})")
            self.emit(f"ld {x(self.wr((a,)))}, {8 * self.r.randrange(8)}({x(a)})")

    def multi_exit(self):
        """The end of one hart's program under multi_program: it counts itself done with an AMO; the first hart
        reads the count atomically until every hart has, then writes tohost; the others park in WFI."""
        i, n = self.multi
        e = self.emit
        e("li x5, 1")
        e("la x6, done_count")
        e("amoadd.w x0, x5, (x6)")
        if i == 0:
            e(f"li x7, {n}")
            self.place(self.s("wait_done"))
            e("amoor.w x5, x0, (x6)")
            e(f"bne x5, x7, {self.s('wait_done')}")
            e("li x5, 1")
            e("la x6, tohost")
            e("sd x5, 0(x6)")
            self.place("1")
            e("j 1b")
        else:
            self.place("1")
            e("wfi")
            e("j 1b")

    def fr(self):
        return f"f{self.r.randrange(32)}"

    def fp_value(self):
        """A 64-bit FP register image: a special or random double, or a (usually NaN-boxed) single."""
        k = self.r.randrange(6)
        if k < 2:
            return self.r.choice(FP_D)
        if k == 2:
            return self.r.getrandbits(64)
        single = self.r.choice(FP_S) if k == 3 else self.r.getrandbits(32)
        return single | (0xFFFFFFFF00000000 if self.r.randrange(8) else self.r.getrandbits(32) << 32)

    def fp_op(self, rd=None):
        """An FP instruction writing an FP register."""
        rd = self.fr() if rd is None else rd
        w = self.r.choice([".s", ".d"])
        rm = self.r.choice(RM)
        k = self.r.randrange(11)
        if k < 4:
            op = self.r.choice(["fadd", "fsub", "fmul", "fdiv"])
            self.emit(f"{op}{w} {rd}, {self.fr()}, {self.fr()}{rm}")
        elif k == 4:
            self.emit(f"fsqrt{w} {rd}, {self.fr()}{rm}")
        elif k == 5:
            op = self.r.choice(["fmin", "fmax", "fsgnj", "fsgnjn", "fsgnjx"])
            self.emit(f"{op}{w} {rd}, {self.fr()}, {self.fr()}")
        elif k < 8:
            op = self.r.choice(["fmadd", "fmsub", "fnmadd", "fnmsub"])
            self.emit(f"{op}{w} {rd}, {self.fr()}, {self.fr()}, {self.fr()}{rm}")
        elif k == 8:
            self.emit(f"fcvt.s.d {rd}, {self.fr()}{rm}" if w == ".s" else f"fcvt.d.s {rd}, {self.fr()}")
        elif k == 9:  # from an integer register (to double, 32-bit sources convert exactly)
            src = x(self.rd_any())
            t = self.r.choice(["w", "wu", "l", "lu"])
            exact = w == ".d" and t in ("w", "wu")
            self.emit(f"fcvt{w}.{t} {rd}, {src}{'' if exact else rm}")
        else:
            self.emit(f"fmv{'.w.x' if w == '.s' else '.d.x'} {rd}, {x(self.rd_any())}")
        return rd

    def fp_to_int(self, rd=None):
        """An FP instruction writing an integer register: compare, classify, convert, move."""
        rd = self.wr() if rd is None else rd
        w = self.r.choice([".s", ".d"])
        k = self.r.randrange(4)
        if k == 0:
            self.emit(f"{self.r.choice(['feq', 'flt', 'fle'])}{w} {x(rd)}, {self.fr()}, {self.fr()}")
        elif k == 1:
            self.emit(f"fclass{w} {x(rd)}, {self.fr()}")
        elif k == 2:
            self.emit(f"fcvt.{self.r.choice(['w', 'wu', 'l', 'lu'])}{w} {x(rd)}, {self.fr()}{self.r.choice(RM)}")
        else:
            self.emit(f"fmv.x{'.w' if w == '.s' else '.d'} {x(rd)}, {self.fr()}")
        return rd

    def t_fp_burst(self):
        for _ in range(self.r.randrange(2, 7)):
            self.r.choice([self.fp_op, self.fp_op, self.fp_to_int, self.alu])()

    def t_fp_mem(self):
        k = self.r.randrange(5)
        if k == 0:  # FP store, then an integer load of the same bytes, or the other way round
            off = self.r.randrange(PTR_SLOTS * 8, 2040, 8)
            if self.r.randrange(2):
                self.emit(f"{self.r.choice(['fsd', 'fsw'])} {self.fr()}, {off}(x3)")
                self.emit(f"{self.r.choice(['ld', 'lw', 'lwu', 'lh'])} {x(self.wr())}, {off}(x3)")
            else:
                self.emit(f"{self.r.choice(['sd', 'sw'])} {x(self.rd_any())}, {off}(x3)")
                self.emit(f"{self.r.choice(['fld', 'flw'])} {self.fr()}, {off}(x3)")
        elif k == 1:  # fsw then flw: the load NaN-boxes
            off = self.r.randrange(PTR_SLOTS * 8, 2044, 4)
            self.emit(f"fsw {self.fr()}, {off}(x3)")
            self.emit(f"flw {self.fr()}, {off}(x3)")
        elif k < 4:  # any aligned address; registers f8-f15 with x8-x15 bases may compress
            sz = self.r.choice([2, 3])
            a = self.addr_reg(sz)
            op = self.r.choice(["flw", "fsw"] if sz == 2 else ["fld", "fsd"])
            self.emit(f"{op} {self.fr()}, 0({x(a)})")
        else:  # misaligned: traps, the handler skips it
            off = (self.r.randrange(PTR_SLOTS * 8, 2000) & ~7) + self.r.randrange(1, 4)
            self.emit(f"{self.r.choice(['flw', 'fld', 'fsw', 'fsd'])} {self.fr()}, {off}(x3)")

    def t_fp_csr(self):
        k = self.r.randrange(9)
        if k == 0:
            self.emit(f"csrr {x(self.wr())}, {self.r.choice(['fflags', 'frm', 'fcsr'])}")
        elif k == 1:
            self.emit(f"csrw fflags, {x(self.rd_any())}")
        elif k == 2:  # 5..7 are reserved: dynamic-rounding instructions then trap until frm is rewritten
            self.emit(f"csrwi frm, {self.r.randrange(8) if self.r.randrange(4) == 0 else self.r.randrange(5)}")
        elif k == 3:
            self.emit(f"csrrw {x(self.wr())}, fcsr, {x(self.rd_any())}")
        elif k == 4:
            self.emit(f"csrrci {x(self.wr())}, fflags, {self.r.randrange(32)}")
        elif k == 5:  # FS off for a moment: FP instructions trap; then Initial again
            t = self.wr()
            self.emit(f"li {x(t)}, 0x6000")
            self.emit(f"csrc mstatus, {x(t)}")
            self.r.choice([self.fp_op, self.fp_to_int])()
            self.emit(f"li {x(t)}, 0x2000")
            self.emit(f"csrs mstatus, {x(t)}")
        else:
            self.emit(f"csrr {x(self.wr())}, mstatus")  # FS and SD follow the FP writes

    def t_fp_long(self):
        """A divide or square root (long latency: a deferred writeback in the core), dependents, and
        a branch on an FP compare of the result."""
        w = self.r.choice([".s", ".d"])
        a, b = self.fr(), self.fr()
        if self.r.randrange(2):
            self.emit(f"fdiv{w} {a}, {self.fr()}, {self.fr()}{self.r.choice(RM)}")
        else:
            self.emit(f"fsqrt{w} {a}, {self.fr()}{self.r.choice(RM)}")
        self.emit(f"fadd{w} {b}, {a}, {self.fr()}{self.r.choice(RM)}")
        t = self.wr()
        self.emit(f"{self.r.choice(['flt', 'fle', 'feq'])}{w} {x(t)}, {b}, {self.fr()}")
        skip = self.label()
        self.emit(f"{self.r.choice(['beqz', 'bnez'])} {x(t)}, {skip}")
        for _ in range(self.r.randrange(1, 4)):
            self.r.choice([self.fp_op, self.alu, self.fp_to_int])()
        if self.r.randrange(4) == 0:
            self.t_trap()
        self.place(skip)

    # ---- program ----
    def data(self):
        out = [".section .data", ".balign 4096", f"{self.s('data')}:"]
        # Pointer table: offsets slot * PTR_STEP + 256 (t_late_store), then random bytes.
        for s in range(PTR_SLOTS):
            out.append(f"  .dword {s * PTR_STEP + 256}")
        words = (DATA_BYTES - PTR_SLOTS * 8) // 8
        for i in range(0, words, 4):
            vals = ", ".join(f"0x{self.r.getrandbits(64):016x}" for _ in range(min(4, words - i)))
            out.append(f"  .dword {vals}")
        out += [".section .bss", ".balign 4096", f"{self.s('stream')}:", f"  .space {self.stream_size}",
                ".balign 4096", f"{self.s('stack')}:", "  .space 4096", f"{self.s('stack_top')}:"]
        if self.vm:  # Sv39 tables: the root, the level-1 tables for 0..1 GiB and 2..3 GiB, the image's level 0
            out += [".balign 4096", f"{self.s('pt_root')}:", "  .space 4096", f"{self.s('pt_l1lo')}:", "  .space 4096",
                    f"{self.s('pt_l1')}:", "  .space 4096", f"{self.s('pt_l0')}:", "  .space 4096"]
        return out

    def vm_setup(self):
        """M-mode: an Sv39 identity map, then S-mode for the body. The first 2 MiB from 0x8000_0000 (the
        whole image) in 4 KiB pages; the CLINT and the denied page in 2 MiB pages; nothing else, so
        UNMAPPED_VA and NONCANON_VA fault. Every leaf has A and D set (the core faults on clear ones)."""
        e = self.emit
        for t in (self.s("pt_root"), self.s("pt_l1lo"), self.s("pt_l1")):  # the loader zeroes .bss; make sure
            e(f"la x30, {t}")
            e("li x31, 512")
            self.place(f"{t}_z")
            e("sd x0, 0(x30)")
            e("addi x30, x30, 8")
            e("addi x31, x31, -1")
            e(f"bnez x31, {t}_z")
        e(f"la x30, {self.s('pt_l0')}")  # level 0: 512 pages from 0x8000_0000, RWX, A, D
        e("li x31, 0x200000CF")
        e("li x5, 512")
        self.place(self.s("pt_l0_fill"))
        e("sd x31, 0(x30)")
        e("addi x30, x30, 8")
        e("addi x31, x31, 0x400")
        e("addi x5, x5, -1")
        e(f"bnez x5, {self.s('pt_l0_fill')}")

        def link(table, index, target):  # table[index] = non-leaf -> target
            e(f"la x30, {target}")
            e("srli x30, x30, 12")
            e("slli x30, x30, 10")
            e("ori x30, x30, 1")
            e(f"la x31, {table}")
            e(f"li x5, {index * 8}")
            e("add x31, x31, x5")
            e("sd x30, 0(x31)")

        def leaf(table, index, pte):
            e(f"la x31, {table}")
            e(f"li x5, {index * 8}")
            e("add x31, x31, x5")
            e(f"li x30, {pte:#x}")
            e("sd x30, 0(x31)")

        link(self.s("pt_root"), 0, self.s("pt_l1lo"))
        link(self.s("pt_root"), 2, self.s("pt_l1"))
        link(self.s("pt_l1"), 0, self.s("pt_l0"))                  # 0x8000_0000: the image
        leaf(self.s("pt_l1"), (DENY_PAGE >> 21) & 0x1FF, ((DENY_PAGE >> 21 << 9) << 10) | 0xC7)   # 2 MiB, RW
        leaf(self.s("pt_l1lo"), (0x02000000 >> 21) & 0x1FF, ((0x02000000 >> 12) << 10) | 0xC7)   # the CLINT, RW
        e(f"la x30, {self.s('pt_root')}")
        e("srli x30, x30, 12")
        e("li x31, 8")
        e("slli x31, x31, 60")
        e("or x30, x30, x31")
        e("csrw satp, x30")
        e("sfence.vma")
        e("li x30, 0x1800")
        e("csrc mstatus, x30")
        e("li x30, 0x0800")
        e("csrs mstatus, x30")         # MPP = S
        e(f"la x30, {self.s('vm_body')}")
        e("csrw mepc, x30")
        e("mret")
        self.place(self.s("vm_body"))

    def program(self):
        r = self.r
        if self.multi:   # one hart's program in multi_program, which writes the file's header and _start
            out = [f"/* hart {self.hartid}: seed={self.seed} vm={int(self.vm)} */", ".section .text", f"{self.s('_start')}:"]
        else:
            out = [f"/* tg_rand seed={self.seed} isa={self.isa} irq={self.irq} length={self.length} "
                   f"group3={self.group3} vm={int(self.vm)} (tests/random/tg_rand.py) */",
                   '#define CLINT_MTIMECMP 0x02004000', '#define CLINT_MTIME 0x0200bff8',
                   ".option arch, +zicsr", ".section .text.init, \"ax\"", ".globl _start", "_start:"]
        self.lines = []
        if not self.multi:   # M7 (DR-175): hart 0 runs the program; a sibling thread that fetches from reset parks
            self.emit("csrr x5, mhartid")
            self.emit("bnez x5, park")
        self.emit(f"la x31, {self.s('trap')}")
        self.emit("csrw mtvec, x31")
        self.emit(f"la x2, {self.s('stack_top')}")
        self.emit(f"la x3, {self.s('data')}")
        self.emit(f"li x4, {ALIAS_PAGES * 4096}")
        self.emit("add x4, x4, x3")
        if self.has_fd:
            self.emit("li x5, 0x2000")
            self.emit("csrs mstatus, x5")  # FS = Initial: the first FP write makes it Dirty
            self.emit(f"csrwi frm, {r.randrange(5)}")
            for i in range(32):
                self.emit(f"li x5, {self.fp_value():#x}")
                self.emit(f"fmv.d.x f{i}, x5")
        for reg in WRITABLE:
            v = r.choice(SPECIAL) if r.randrange(4) == 0 else r.getrandbits(64)
            self.emit(f"li {x(reg)}, {v & 0xFFFFFFFFFFFFFFFF:#x}")
        if self.irq:
            self.emit("li x31, CLINT_MTIME")
            self.emit("ld x31, 0(x31)")
            self.emit(f"addi x31, x31, {self.irq}")
            self.emit(f"li x30, {self.mtimecmp()}")
            self.emit("sd x31, 0(x30)")
            self.emit("li x31, 0x80")
            self.emit("csrs mie, x31")
            if not self.vm:  # in S-mode, M-level interrupts are taken whatever mstatus.MIE says; leaving it
                self.emit("csrsi mstatus, 8")  # clear keeps the tables' setup and the switch to S uninterrupted
        if self.vm:  # from here on S-mode under Sv39; the registers keep their values
            self.vm_setup()
        templates = [(self.t_alu_burst, 6), (self.t_forwarding, 5), (self.t_alias, 2), (self.t_late_store, 4),
                     (self.t_miss_stream, 2), (self.t_miss_burst, self.miss), (self.t_long_then_flush, 5), (self.t_trap, 2), (self.t_amo, 2),
                     (self.t_csr, 1), (self.t_call, 2), (self.t_reg_pressure, 5), (self.t_store_burst, 4),
                     (self.t_all_ports, 3), (self.t_long_burst, 2)]
        if not self.vm:  # tg_replay's pre-check adopts device loads only untranslated (verification.md §9)
            templates.append((self.t_mmio, 1))
        if self.irq:
            templates += [(self.t_wfi, 1), (self.t_csr_burst, 6)]
        if self.vm:
            templates += [(self.t_vm, 4), (self.t_sret, 1)]
        if self.has_m:
            templates.append((self.t_tag_burst, 2))
        if self.group3:
            templates.append((self.t_group3, 6))
        if self.has_fd:
            templates += [(self.t_fp_burst, 10), (self.t_fp_mem, 4), (self.t_fp_csr, 2), (self.t_fp_long, 6)]
        if self.multi and self.shared:   # the shared region's templates, together weighing --shared
            templates += [(self.t_sh_amo, 3 * self.shared), (self.t_sh_lrsc, 2 * self.shared), (self.t_sh_plain, 3 * self.shared),
                          (self.t_sh_fence, self.shared), (self.t_sh_line, self.shared)]
        fns, weights = zip(*templates)
        for _ in range(self.length):
            r.choices(fns, weights)[0]()
        if self.irq:
            self.emit("csrci mstatus, 8")
        # The exit through registers the trap handler never touches: in S-mode (--vm) M-level interrupts
        # stay enabled, and one between these instructions must not change the value or the address.
        if self.multi:
            self.multi_exit()
        else:
            self.emit("li x5, 1")
            self.emit("la x6, tohost")
            self.emit("sd x5, 0(x6)")
            self.place("1")
            self.emit("j 1b")
        out += self.lines
        # Leaf functions for t_call: they may clobber temporaries but never x1.
        for i in range(4):
            out.append(f"{self.s('tg_func')}{i}:")
            for _ in range(r.randrange(1, 5)):
                self.lines = []
                self.alu(rd=self.wr((1,)))
                out += self.lines
            out.append("  ret")
        # Trap handler: skip the faulting instruction (2 or 4 bytes); re-arm the timer on interrupts.
        # A fetch fault (access 1, page 12) cannot skip its instruction: it returns to x1, which the
        # jalr into the faulting address set.
        out += [".balign 4", f"{self.s('trap')}:",
                "  csrr x31, mcause",
                f"  bltz x31, {self.s('trap_irq')}",
                "  addi x30, x31, -1",
                f"  beqz x30, {self.s('trap_ra')}",
                "  addi x30, x31, -12",
                f"  beqz x30, {self.s('trap_ra')}",
                "  csrr x31, mepc",
                "  lhu x30, 0(x31)",
                "  andi x30, x30, 3",
                "  addi x31, x31, 2",
                "  addi x30, x30, -3",
                "  bnez x30, 1f",
                "  addi x31, x31, 2",
                "1:",
                "  csrw mepc, x31",
                "  mret",
                f"{self.s('trap_ra')}:",
                "  csrw mepc, x1",
                "  mret",
                f"{self.s('trap_irq')}:",
                "  li x31, CLINT_MTIME",
                "  ld x31, 0(x31)",
                f"  addi x31, x31, {self.irq or 100}",
                f"  li x30, {self.mtimecmp()}",
                "  sd x31, 0(x30)",
                "  mret"]
        if not self.multi:
            out += ["park:", "  wfi", "  j park"]
        out += self.data()
        if not self.multi:
            out += [".section .tohost, \"aw\", @progbits", ".balign 64", ".globl tohost", "tohost: .dword 0",
                    ".balign 64", ".globl fromhost", "fromhost: .dword 0"]
        return "\n".join(out) + "\n"


def multi_program(seed, isa, irq, length, group3, vm, miss, harts, shared):
    """Several harts (M7: siblings in one core, or harts of two cores), each running a program of its own:
    _start sends each listed hart to its program and parks every other in WFI. Each program has its own
    labels, data, stream, stack, page tables (--vm draws for each), trap handler and timer; they share
    done_count, the exit's barrier, and with --shared the lines at shared. The first hart listed writes
    tohost once every hart has finished."""
    r = random.Random(seed)
    n = len(harts)
    gens = [Gen(r.getrandbits(32), isa, irq, length, group3, vm, miss, pfx=f"h{i}_", hartid=h, multi=(i, n),
                shared=shared) for i, h in enumerate(harts)]
    out = [f"/* tg_rand seed={seed} isa={isa} irq={irq} length={length} group3={group3} vm={vm}% "
           f"harts={','.join(map(str, harts))} shared={shared} (tests/random/tg_rand.py) */",
           "#define CLINT_MTIMECMP 0x02004000", "#define CLINT_MTIME 0x0200bff8",
           ".option arch, +zicsr", ".section .text.init, \"ax\"", ".globl _start", "_start:", "  csrr x10, mhartid"]
    for i, h in enumerate(harts):
        out += [f"  li x5, {h}", "  bne x10, x5, 1f", f"  j h{i}__start", "1:"]
    out += ["2:", "  wfi", "  j 2b"]
    for g in gens:
        out.append(g.program())
    out += [".section .data", ".balign 64", "done_count: .dword 0", ".balign 64", "shared:"]
    for _ in range(SHARED_LINES * 2):
        out.append("  .dword " + ", ".join(f"0x{r.getrandbits(64):016x}" for _ in range(4)))
    out += [".section .tohost, \"aw\", @progbits", ".balign 64", ".globl tohost", "tohost: .dword 0",
            ".balign 64", ".globl fromhost", "fromhost: .dword 0"]
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--isa", default="rv64im", help="rv64i, rv64im, rv64ima, rv64imac, rv64gc ...")
    ap.add_argument("--irq", type=int, default=0, help="timer interrupt period in mtime ticks (0: none)")
    ap.add_argument("--length", type=int, default=200, help="number of templates")
    ap.add_argument("--no-group3", action="store_true", help="leave out the width-3 groups")
    ap.add_argument("--miss", type=int, default=2, help="weight of the miss-burst template (DR-149; the default "
                    "mix weighs the others 1-6): 12 makes misses in flight the program's main business")
    ap.add_argument("--vm", type=int, default=0, help="percentage of programs that run in S-mode under Sv39 "
                                                      "(needs S-mode and Sv39: Spike --priv=MSU)")
    ap.add_argument("--harts", default="0", help="the harts that run, each a program of its own (M7): 0,1 the two "
                    "threads of one core, 0,2 one thread of each of two cores, 0,1,2,3 all four; needs the A extension")
    ap.add_argument("--shared", type=int, default=0, help="with several harts: the weight of the templates on the "
                    "lines they share (AMOs, LR/SC, plain loads and stores, fences, false sharing); 0: none")
    ap.add_argument("-o", "--output", default="-")
    a = ap.parse_args()
    harts = [int(h) for h in a.harts.split(",")]
    if len(harts) > 1:
        if "a" not in a.isa[4:].split("_")[0].replace("g", "imafd"):
            ap.error("--harts needs the A extension (the exit's barrier is an AMO)")
        text = multi_program(a.seed, a.isa, a.irq, a.length, not a.no_group3, a.vm, a.miss, harts, a.shared)
    else:
        text = Gen(a.seed, a.isa, a.irq, a.length, not a.no_group3, a.vm, a.miss).program()
    if a.output == "-":
        sys.stdout.write(text)
    else:
        with open(a.output, "w") as f:
            f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
