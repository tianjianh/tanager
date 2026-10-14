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
    divides and square roots followed by dependents and a branch on their result.

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
STREAM_SIZE = 65536        # cache-miss stream region (bigger than a 32 KiB L1)
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
LD = {"lb": 0, "lbu": 0, "lh": 1, "lhu": 1, "lw": 2, "lwu": 2, "ld": 3}
ST = {"sb": 0, "sh": 1, "sw": 2, "sd": 3}


def x(r):
    return f"x{r}"


class Gen:
    def __init__(self, seed, isa, irq, length, group3):
        self.r = random.Random(seed)
        self.seed = seed
        self.isa = isa
        base = isa[4:].split("_")[0].replace("g", "imafd")
        self.has_m = "m" in base
        self.has_a = "a" in base
        self.has_fd = "f" in base and "d" in base
        self.irq = irq
        self.length = length
        self.group3 = group3
        self.lines = []
        self.nlabel = 0
        self.funcs = 0

    # ---- helpers ----
    def emit(self, s):
        self.lines.append("  " + s)

    def label(self, name=None):
        self.nlabel += 1
        return name or f".L{self.nlabel}"

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
        self.emit(f"la {x(ptr)}, stream")
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
        self.emit(f"la {x(v)}, stream")
        self.emit(f"sub {x(ptr)}, {x(ptr)}, {x(v)}")
        self.emit(f"li {x(v)}, {STREAM_SIZE - 64}")
        self.emit(f"and {x(ptr)}, {x(ptr)}, {x(v)}")
        self.emit(f"la {x(v)}, stream")
        self.emit(f"add {x(ptr)}, {x(ptr)}, {x(v)}")
        self.emit(f"addi {x(cnt)}, {x(cnt)}, -1")
        self.emit(f"bnez {x(cnt)}, {top}")

    def t_long_then_flush(self):
        """A long-latency result (divide or missing load), its consumers, and a data-dependent branch or a
        trap right behind it: flushes over pending (possibly early-retired) operations."""
        if self.has_m and self.r.randrange(2):
            v = self.muldiv()
        else:
            v = self.wr()
            self.emit(f"la {x(v)}, stream")
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
        """An exception the handler skips."""
        k = self.r.randrange(6)
        if k == 0:  # misaligned load or store
            sz = self.r.randrange(1, 4)
            off = (self.r.randrange(PTR_SLOTS * 8, 2000) & ~7) + self.r.randrange(1, 1 << sz)
            if self.r.randrange(2):
                self.emit(f"{self.r.choice([o for o, s in LD.items() if s == sz])} {x(self.wr())}, {off}(x3)")
            else:
                self.emit(f"{self.r.choice([o for o, s in ST.items() if s == sz])} {x(self.rd_any())}, {off}(x3)")
        elif k == 1:
            self.emit("unimp")
        elif k == 2:
            self.emit("ecall")
        elif k == 3:
            self.emit("ebreak")
        else:  # access fault: nothing is mapped below the boot ROM
            t = self.wr()
            self.emit(f"li {x(t)}, {self.r.randrange(0x40, 0x800, 8)}")
            if k == 4:
                self.emit(f"ld {x(self.wr())}, 0({x(t)})")
            else:
                self.emit(f"sd {x(self.rd_any())}, 0({x(t)})")

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
        if self.r.randrange(2):
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
        self.emit(f"jal x1, tg_func{self.r.randrange(4)}")
        if self.r.randrange(2):
            t = self.wr((1,))
            fwd = self.label()
            self.emit(f"la {x(t)}, {fwd}")
            self.emit(f"jalr {x(self.wr((t,)))}, 0({x(t)})")
            self.place(fwd)

    # ---- F and D ----
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
        out = [".section .data", ".balign 4096", "data:"]
        # Pointer table: offsets slot * PTR_STEP + 256 (t_late_store), then random bytes.
        for s in range(PTR_SLOTS):
            out.append(f"  .dword {s * PTR_STEP + 256}")
        words = (DATA_BYTES - PTR_SLOTS * 8) // 8
        for i in range(0, words, 4):
            vals = ", ".join(f"0x{self.r.getrandbits(64):016x}" for _ in range(min(4, words - i)))
            out.append(f"  .dword {vals}")
        out += [".section .bss", ".balign 4096", "stream:", f"  .space {STREAM_SIZE}",
                ".balign 4096", "stack:", "  .space 4096", "stack_top:"]
        return out

    def program(self):
        r = self.r
        out = [f"/* tg_rand seed={self.seed} isa={self.isa} irq={self.irq} length={self.length} "
               f"group3={self.group3} (tests/random/tg_rand.py) */",
               '#define CLINT_MTIMECMP 0x02004000', '#define CLINT_MTIME 0x0200bff8',
               ".option arch, +zicsr", ".section .text.init, \"ax\"", ".globl _start", "_start:"]
        self.lines = []
        self.emit("la x31, trap")
        self.emit("csrw mtvec, x31")
        self.emit("la x2, stack_top")
        self.emit("la x3, data")
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
            self.emit("li x30, CLINT_MTIMECMP")
            self.emit("sd x31, 0(x30)")
            self.emit("li x31, 0x80")
            self.emit("csrs mie, x31")
            self.emit("csrsi mstatus, 8")
        templates = [(self.t_alu_burst, 6), (self.t_forwarding, 5), (self.t_alias, 2), (self.t_late_store, 4),
                     (self.t_miss_stream, 2), (self.t_long_then_flush, 5), (self.t_trap, 2), (self.t_amo, 2),
                     (self.t_csr, 1), (self.t_call, 2)]
        if self.group3:
            templates.append((self.t_group3, 6))
        if self.has_fd:
            templates += [(self.t_fp_burst, 10), (self.t_fp_mem, 4), (self.t_fp_csr, 2), (self.t_fp_long, 6)]
        fns, weights = zip(*templates)
        for _ in range(self.length):
            r.choices(fns, weights)[0]()
        if self.irq:
            self.emit("csrci mstatus, 8")
        self.emit("li x31, 1")
        self.emit("la x30, tohost")
        self.emit("sd x31, 0(x30)")
        self.place("1")
        self.emit("j 1b")
        out += self.lines
        # Leaf functions for t_call: they may clobber temporaries but never x1.
        for i in range(4):
            out.append(f"tg_func{i}:")
            for _ in range(r.randrange(1, 5)):
                self.lines = []
                self.alu(rd=self.wr((1,)))
                out += self.lines
            out.append("  ret")
        # Trap handler: skip the faulting instruction (2 or 4 bytes); re-arm the timer on interrupts.
        out += [".balign 4", "trap:",
                "  csrr x31, mcause",
                "  bltz x31, trap_irq",
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
                "trap_irq:",
                "  li x31, CLINT_MTIME",
                "  ld x31, 0(x31)",
                f"  addi x31, x31, {self.irq or 100}",
                "  li x30, CLINT_MTIMECMP",
                "  sd x31, 0(x30)",
                "  mret"]
        out += self.data()
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
    ap.add_argument("-o", "--output", default="-")
    a = ap.parse_args()
    text = Gen(a.seed, a.isa, a.irq, a.length, not a.no_group3).program()
    if a.output == "-":
        sys.stdout.write(text)
    else:
        with open(a.output, "w") as f:
            f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
