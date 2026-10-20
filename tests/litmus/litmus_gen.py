#!/usr/bin/env python3
"""litmus_gen: RVWMO litmus tests (litmus-tests-riscv) as one bare-metal program (docs/spec/verification.md §6.6;
plan §9; the M7 plan's exit 4).

Each test's threads run on harts of their own (--harts: thread i on the i-th hart listed; harts not listed park), K
times each (--iters). Every iteration:
  - the first hart resets the test's locations (each on a cache line of its own, as herd assumes) to their initial
    values;
  - all harts meet at a barrier (an AMO count and a generation word);
  - each hart warms its lines as the test's Prefetch line asks (a load, or an AMO that changes nothing for a write),
    waits a random 0-63 loop turns or not at all, sets its registers (the test's initial values, every other register
    the code names to 0) and runs its thread's code;
  - its result registers go to the test's observation slots, the harts meet again, and the first hart reads the
    locations herd observes and looks the final state up in herd's list of the states RVWMO allows
    (model-results/herd.logs).
Every test skipped (stderr: litmus_gen: skip <path>: <reason>) leaves no program, and the exit status is 3.
The first hart prints one line per test, LIT <name> k=<K> bad=<n> s=<count of each allowed state>, and for a state
herd does not allow LIT-BAD <name> <var>=<value> ...; then LIT-END, and it writes tohost. A test is skipped (and
listed on stderr) when it has more threads than harts, an instruction outside the core's ISA (the load-acquire and
store-release forms lw.aq, sw.rl, ld.aq, sd.rl), a filter, a jalr, or no herd result.

The downloaded suite is data: this script only reads it (run it with python3 -I).
  litmus_gen.py --suite DIR --herd FILE --harts 0,1 --iters 200 --seed 1 -o prog.S TEST.litmus ...
"""
import argparse
import random
import re
import sys

UART = 0x10000000
ABI = {"zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4, "t0": 5, "t1": 6, "t2": 7, "s0": 8, "fp": 8, "s1": 9,
       **{f"a{i}": 10 + i for i in range(8)}, **{f"s{i}": 16 + i for i in range(2, 12)},
       **{f"t{i}": 25 + i for i in range(3, 7)}}
OPS = {"lw", "ld", "lb", "lh", "lbu", "lhu", "lwu", "sw", "sd", "sb", "sh", "add", "addi", "sub", "xor", "xori", "or",
       "ori", "and", "andi", "slli", "srli", "li", "mv", "nop", "fence", "fence.tso", "fence.i", "bne", "beq", "blt",
       "bge", "bltu", "bgeu", "j"}
ATOMIC = re.compile(r"^(lr|sc|amo(swap|add|and|or|xor|max|min|maxu|minu))\.[wd](\.aq|\.rl|\.aqrl|\.aq\.rl)?$")
WIDE = re.compile(r"^(ld|sd|lr\.d|sc\.d|amo\w+\.d)(\.|$)")


class Skip(Exception):
    pass


def reg(name):
    """A register name (x5, t0, s1, ...) as its number, or None."""
    m = re.fullmatch(r"x(\d+)", name)
    if m and int(m[1]) < 32:
        return int(m[1])
    return ABI.get(name)


class Test:
    def __init__(self, path):
        self.path = path
        txt = open(path, errors="replace").read()
        lines = txt.splitlines()
        if not lines or not lines[0].startswith("RISCV "):
            raise Skip("not a RISCV test")
        self.name = lines[0].split()[1]
        self.prefetch = {}
        m = re.search(r"^Prefetch=(.*)$", txt, re.M)
        if m:
            for item in m[1].split(","):
                pm = re.fullmatch(r"\s*(\d+):(\w+)=([FWT])\s*", item)
                if pm:
                    self.prefetch.setdefault(int(pm[1]), []).append((pm[2], pm[3]))
        if "{" not in txt or "}" not in txt:
            raise Skip("no initial state")
        init = txt.split("{", 1)[1].split("}", 1)[0]
        body = txt.split("}", 1)[1]
        if re.search(r"^\s*filter", body, re.M):
            raise Skip("filter")
        self.locs = []          # location names, in first-seen order
        self.reg_init = {}      # (thread, reg) -> int or ("loc", name)
        self.mem_init = {}      # loc -> int or ("loc", name)
        for item in init.replace("\n", " ").split(";"):
            item = item.strip()
            if not item:
                continue
            item = re.sub(r"^(u?int(8|16|32|64)_t|int|long)\s+", "", item).lstrip("*")
            mm = re.fullmatch(r"(?:(\d+):)?(\*?\w+)\s*=\s*(&?-?\w+)", item)
            if not mm:
                if re.fullmatch(r"\w+", item):      # a declaration without a value: a location, 0
                    self.loc(item)
                    continue
                if re.fullmatch(r"\d+:\w+", item) and reg(item.split(":")[1]) is not None:
                    continue                          # a register's declaration: 0, as every register the code names
                raise Skip(f"initial state '{item}'")
            th, lhs, rhs = mm[1], mm[2], mm[3]
            val = self.value(rhs)
            if th is not None:
                r = reg(lhs)
                if r is None:
                    raise Skip(f"register '{lhs}'")
                self.reg_init[(int(th), r)] = val
            else:
                self.mem_init[self.loc(lhs)] = val
        code = re.split(r"^\s*(?:exists|forall|~exists|locations)", body, flags=re.M)[0]
        code = re.sub(r"\(\*.*?\*\)", "", code, flags=re.S)       # herd's comments, (*W x=1*)
        rows = [l.strip() for l in code.splitlines() if l.strip().endswith(";")]
        if not rows:
            raise Skip("no code")
        heads = [c.strip() for c in rows[0].rstrip(";").split("|")]
        if any(not re.fullmatch(r"P\d+", h) for h in heads):
            raise Skip("thread header")
        self.n = len(heads)
        self.code = [[] for _ in range(self.n)]
        for row in rows[1:]:
            cells = row.rstrip(";").split("|")
            if len(cells) != self.n:
                raise Skip("ragged code row")
            for t, c in enumerate(cells):
                c = c.strip()
                if c:
                    self.code[t].append(c)
        self.wide = False
        for t in range(self.n):
            for c in self.code[t]:
                ins = re.sub(r"^\w+:\s*", "", c)
                if not ins:
                    continue
                op = ins.split()[0]
                if op not in OPS and not ATOMIC.match(op):
                    raise Skip(f"instruction '{op}'")
                if WIDE.match(op):
                    self.wide = True
        # Pointer values live in 64-bit words
        if any(isinstance(v, tuple) for v in self.mem_init.values()):
            self.wide = True

    def loc(self, name):
        name = name.lstrip("*")
        if not re.fullmatch(r"[A-Za-z_]\w*", name) or reg(name) is not None:
            raise Skip(f"location '{name}'")
        if name not in self.locs:
            self.locs.append(name)
        return name

    def value(self, s):
        s = s.lstrip("&")
        if re.fullmatch(r"-?\d+", s):
            return int(s)
        if re.fullmatch(r"-?0x[0-9a-fA-F]+", s):
            return int(s, 16)
        return ("loc", self.loc(s))

    def regs_used(self, t):
        used = set()
        for c in self.code[t]:
            ins = re.sub(r"^\w+:\s*", "", c)
            for tok in re.findall(r"[A-Za-z_]\w*", ins.split(None, 1)[1] if " " in ins else ""):
                r = reg(tok)
                if r is not None:
                    used.add(r)
        return used


def parse_herd(path, names):
    """herd.logs: for each wanted test, the variables its States lines give and the allowed tuples."""
    out = {}
    txt = open(path, errors="replace").read()
    for block in re.split(r"^(?=Test \S+ )", txt, flags=re.M):
        m = re.match(r"Test (\S+) ", block)
        if not m or m[1] not in names:
            continue
        sm = re.search(r"^States (\d+)\n((?:.*\n){0,4096})", block, re.M)
        if not sm:
            continue
        n = int(sm[1])
        rows = sm[2].splitlines()[:n]
        vars_, states = None, []
        for row in rows:
            pairs = [p.strip() for p in row.split(";") if p.strip()]
            kv = []
            for p in pairs:
                k, _, v = p.partition("=")
                kv.append((k.strip(), v.strip()))
            keys = [k for k, _ in kv]
            if vars_ is None:
                vars_ = keys
            if keys != vars_:
                vars_ = None
                break
            states.append([v for _, v in kv])
        if vars_ is not None:
            out[m[1]] = (vars_, states)
    return out


class Prog:
    def __init__(self, harts, iters, seed):
        self.harts, self.iters = harts, iters
        self.r = random.Random(seed)
        self.text, self.data = [], []

    def e(self, s):
        self.text.append("  " + s)

    def lab(self, s):
        self.text.append(f"{s}:")

    def li_val(self, rd, v, j):
        if isinstance(v, tuple):
            self.e(f"la {rd}, L{j}_{v[1]}")
        else:
            self.e(f"li {rd}, {v}")

    def test(self, j, t, herd):
        vars_, states = herd
        e, n = self.e, len(self.harts)
        P = f"L{j}"
        # Variables: (thread, reg) or a location, in herd's order; each gets an 8-byte observation slot
        var = []
        for v in vars_:
            m = re.fullmatch(r"(\d+):(\w+)", v)
            if m:
                r = reg(m[2])
                if r is None or int(m[1]) >= t.n:
                    raise Skip(f"herd variable '{v}'")
                var.append(("reg", int(m[1]), r))
            else:
                var.append(("mem", t.loc(v)))
        def val(s):
            if re.fullmatch(r"-?\d+", s):
                return int(s)
            if re.fullmatch(r"-?0x[0-9a-fA-F]+", s):
                return int(s, 16)
            return ("loc", t.loc(s))
        tuples = [[val(s) for s in st] for st in states]
        # Data: the locations (a line each), the observation slots, the counts
        for loc in t.locs:
            self.data += [".balign 64", f"{P}_{loc}: .dword 0", ".balign 64"]
        self.data += [".balign 64", f"{P}_obs: .space {8 * max(1, len(var))}", ".balign 8",
                      f"{P}_cnt: .space {8 * (len(tuples) + 2)}",           # each state's count, bad, first bad's flag
                      f"{P}_first: .space {8 * max(1, len(var))}",
                      f'{P}_name: .asciz "{t.name}"', ".balign 8"]
        size = "d" if t.wide else "w"
        free = {}
        for th in range(t.n):
            used = t.regs_used(th) | {r for (tt, r) in t.reg_init if tt == th} | {v[2] for v in var if v[0] == "reg" and v[1] == th}
            cand = [r for r in range(31, 4, -1) if r not in used]
            if not cand:
                raise Skip("no free register")
            free[th] = cand[0]
        self.text.append(f"/* {t.name}: {t.n} threads, {len(tuples)} allowed states, {'64' if t.wide else '32'}-bit */")
        e("csrr s1, mscratch")
        e("sd zero, 24(s1)")
        self.lab(f"{P}_iter")
        e("csrr s1, mscratch")
        e("ld s0, 0(s1)")
        e(f"bnez s0, {P}_reset_done")
        for loc in t.locs:                            # the first hart resets the locations
            self.li_val("a0", t.mem_init.get(loc, 0), j)
            e(f"la a1, {P}_{loc}")
            e(f"s{'d' if t.wide else 'w'} a0, 0(a1)")
        self.lab(f"{P}_reset_done")
        e("call barrier")
        e("csrr s1, mscratch")
        e("ld a0, 16(s1)")                            # the hart's LFSR: x ^= x << 13; x ^= x >> 7; x ^= x << 17
        e("slli a1, a0, 13")
        e("xor a0, a0, a1")
        e("srli a1, a0, 7")
        e("xor a0, a0, a1")
        e("slli a1, a0, 17")
        e("xor a0, a0, a1")
        e("sd a0, 16(s1)")
        e("andi a1, a0, 3")
        e(f"beqz a1, {P}_go")                         # a quarter of the iterations start at once
        e("srli a1, a0, 2")
        e("andi a1, a1, 63")
        self.lab(f"{P}_delay")
        e(f"beqz a1, {P}_go")
        e("addi a1, a1, -1")
        e(f"j {P}_delay")
        self.lab(f"{P}_go")
        e("ld s0, 0(s1)")
        for th in range(t.n):
            e(f"li a1, {th}")
            e(f"beq s0, a1, {P}_t{th}")
        e(f"j {P}_after")                             # harts beyond the test's threads
        for th in range(t.n):
            self.lab(f"{P}_t{th}")
            for loc, how in t.prefetch.get(th, []):  # warm the lines: a load, or an AMO that leaves the value
                if loc not in t.locs:
                    continue
                e(f"la a1, {P}_{loc}")
                e(f"amoor.{size} x0, x0, (a1)" if how == "W" else f"l{size} a2, 0(a1)")
            regs = t.regs_used(th) | {r for (tt, r) in t.reg_init if tt == th}
            for r in sorted(regs):
                if r == 0:
                    continue
                v = t.reg_init.get((th, r), 0)
                if isinstance(v, tuple):
                    e(f"la x{r}, {P}_{v[1]}")
                else:
                    e(f"li x{r}, {v}")
            labels = set()
            for c in t.code[th]:
                m = re.match(r"^(\w+):", c)
                if m:
                    labels.add(m[1])
            for c in t.code[th]:
                m = re.match(r"^(\w+):\s*(.*)$", c)
                if m:
                    self.lab(f"{P}_t{th}_{m[1]}")
                    c = m[2]
                    if not c:
                        continue
                for lb in labels:
                    c = re.sub(rf"\b{lb}\b", f"{P}_t{th}_{lb}", c)
                e(re.sub(r"\.aq\.rl\b", ".aqrl", c))        # herd's amoswap.w.aq.rl is the assembler's .aqrl
            f = free[th]
            e(f"la x{f}, {P}_obs")
            for k, v in enumerate(var):
                if v[0] == "reg" and v[1] == th:
                    e(f"sd x{v[2]}, {8 * k}(x{f})")
            e(f"j {P}_after")
        self.lab(f"{P}_after")
        e("call barrier")
        e("csrr s1, mscratch")
        e("ld s0, 0(s1)")
        e(f"bnez s0, {P}_next")
        e(f"la s2, {P}_obs")                          # the first hart: the locations herd observes, then the lookup
        for k, v in enumerate(var):
            if v[0] == "mem":
                e(f"la a1, {P}_{v[1]}")
                e(f"l{size} a0, 0(a1)")
                e(f"sd a0, {8 * k}(s2)")
        e(f"la s3, {P}_cnt")
        for si, tup in enumerate(tuples):
            for k, v in enumerate(tup):
                e(f"ld a0, {8 * k}(s2)")
                if isinstance(v, tuple):
                    e(f"la a1, {P}_{v[1]}")
                else:
                    e(f"li a1, {v}")
                e(f"bne a0, a1, {P}_s{si}_no")
            e(f"ld a0, {8 * si}(s3)")
            e("addi a0, a0, 1")
            e(f"sd a0, {8 * si}(s3)")
            e(f"j {P}_next")
            self.lab(f"{P}_s{si}_no")
        nb = 8 * len(tuples)
        e(f"ld a0, {nb}(s3)")                          # a state herd does not allow
        e("addi a0, a0, 1")
        e(f"sd a0, {nb}(s3)")
        e("li a1, 1")
        e(f"bne a0, a1, {P}_next")
        e(f"la a2, {P}_first")
        for k in range(len(var)):
            e(f"ld a0, {8 * k}(s2)")
            e(f"sd a0, {8 * k}(a2)")
        self.lab(f"{P}_next")
        e("csrr s1, mscratch")
        e("ld a0, 24(s1)")
        e("addi a0, a0, 1")
        e("sd a0, 24(s1)")
        e(f"li a1, {self.iters}")
        e(f"blt a0, a1, {P}_iter")
        e("ld s0, 0(s1)")
        e(f"bnez s0, {P}_done")
        # The first hart's report: LIT <name> k=<K> bad=<n> s=<c0>,<c1>,...
        e("la a0, str_lit")
        e("call puts")
        e(f"la a0, {P}_name")
        e("call puts")
        e("la a0, str_k")
        e("call puts")
        e(f"li a0, {self.iters}")
        e("call putu")
        e("la a0, str_bad")
        e("call puts")
        e(f"la s3, {P}_cnt")
        e(f"ld a0, {nb}(s3)")
        e("call putu")
        e("la a0, str_s")
        e("call puts")
        for si in range(len(tuples)):
            if si:
                e("li a0, ','")
                e("call putc")
            e(f"ld a0, {8 * si}(s3)")
            e("call putu")
        e("li a0, '\\n'")
        e("call putc")
        e(f"ld a0, {nb}(s3)")
        e(f"beqz a0, {P}_done")
        e("la a0, str_litbad")                        # LIT-BAD <name> <var>=<value> ... (the first such state)
        e("call puts")
        e(f"la a0, {P}_name")
        e("call puts")
        e(f"la s2, {P}_first")
        for k, v in enumerate(vars_):
            self.data.append(f'{P}_v{k}: .asciz " {v}="')
            e(f"la a0, {P}_v{k}")
            e("call puts")
            e(f"ld a0, {8 * k}(s2)")
            e("call putx")
        e("li a0, '\\n'")
        e("call putc")
        self.lab(f"{P}_done")

    def program(self, tests, herd):
        e, n = self.e, len(self.harts)
        out = [f"/* litmus_gen: {len(tests)} tests on harts {','.join(map(str, self.harts))}, {self.iters} iterations "
               "each (tests/litmus/litmus_gen.py) */", ".option arch, +zicsr, +a", ".section .text.init, \"ax\"",
               ".globl _start", "_start:"]
        e("csrr a0, mhartid")
        for i, h in enumerate(self.harts):
            e(f"li a1, {h}")
            e(f"bne a0, a1, 1f")
            e(f"li s0, {i}")
            e("j have_index")
            self.text.append("1:")
        self.lab("park")
        e("wfi")
        e("j park")
        self.lab("have_index")
        e("la a2, ctxs")                               # this hart's context: index, barrier generation, LFSR, iteration
        e("slli a3, s0, 6")
        e("add a2, a2, a3")
        e("csrw mscratch, a2")
        e("sd s0, 0(a2)")
        e("sd zero, 8(a2)")
        e(f"li a3, {self.r.getrandbits(62) | 1}")
        e("add a3, a3, s0")
        e("sd a3, 16(a2)")
        e("la sp, stacks")
        e("addi a3, s0, 1")
        e("slli a3, a3, 12")
        e("add sp, sp, a3")
        e("call barrier")
        for j, t in enumerate(tests):
            self.test(j, t, herd[t.name])
        e("csrr s1, mscratch")
        e("ld s0, 0(s1)")
        e("bnez s0, park")
        e("la a0, str_end")
        e("call puts")
        e("li a0, 1")
        e("la a1, tohost")
        e("sd a0, 0(a1)")
        e("j park")
        # barrier: an AMO count and a generation word; uses a0-a5 and returns through ra
        self.lab("barrier")
        e("csrr a5, mscratch")
        e("ld a4, 8(a5)")
        e("la a0, bar_count")
        e("li a1, 1")
        e("amoadd.w.aqrl a2, a1, (a0)")
        e(f"li a3, {n - 1}")
        e("bne a2, a3, 2f")
        e("sw zero, 0(a0)")
        e("fence w, w")
        e("addi a3, a4, 1")
        e("la a0, bar_gen")
        e("sd a3, 0(a0)")
        e("j 3f")
        self.text.append("2:")
        e("la a0, bar_gen")
        self.text.append("4:")
        e("ld a3, 0(a0)")
        e("beq a3, a4, 4b")
        self.text.append("3:")
        e("addi a4, a4, 1")
        e("sd a4, 8(a5)")
        e("fence rw, rw")
        e("ret")
        # putc (a0), puts (a0 = string), putu (decimal), putx (hex): the 16550 at UART, polling LSR.THRE
        self.lab("putc")
        e(f"li a5, {UART:#x}")
        self.text.append("1:")
        e("lbu a4, 5(a5)")
        e("andi a4, a4, 0x20")
        e("beqz a4, 1b")
        e("sb a0, 0(a5)")
        e("ret")
        self.lab("puts")
        e("mv t0, ra")
        e("mv t1, a0")
        self.text.append("1:")
        e("lbu a0, 0(t1)")
        e("beqz a0, 2f")
        e("call putc")
        e("addi t1, t1, 1")
        e("j 1b")
        self.text.append("2:")
        e("mv ra, t0")
        e("ret")
        self.lab("putu")
        e("mv t0, ra")
        e("la t1, numbuf + 24")
        e("li t2, 10")
        self.text.append("1:")
        e("remu a1, a0, t2")
        e("divu a0, a0, t2")
        e("addi a1, a1, '0'")
        e("addi t1, t1, -1")
        e("sb a1, 0(t1)")
        e("bnez a0, 1b")
        self.text.append("2:")
        e("lbu a0, 0(t1)")
        e("beqz a0, 3f")
        e("call putc")
        e("addi t1, t1, 1")
        e("j 2b")
        self.text.append("3:")
        e("mv ra, t0")
        e("ret")
        self.lab("putx")
        e("mv t0, ra")
        e("mv t1, a0")
        e("li t2, 60")
        e("li a0, '0'")
        e("call putc")
        e("li a0, 'x'")
        e("call putc")
        self.text.append("1:")
        e("srl a0, t1, t2")
        e("andi a0, a0, 15")
        e("li a1, 10")
        e("blt a0, a1, 2f")
        e("addi a0, a0, 'a' - 10")
        e("j 3f")
        self.text.append("2:")
        e("addi a0, a0, '0'")
        self.text.append("3:")
        e("call putc")
        e("addi t2, t2, -4")
        e("bgez t2, 1b")
        e("mv ra, t0")
        e("ret")
        out += self.text
        out += [".section .data", ".balign 64", "bar_count: .dword 0", ".balign 64", "bar_gen: .dword 0",
                ".balign 64", f"ctxs: .space {64 * n}", 'str_lit: .asciz "LIT "', 'str_k: .asciz " k="',
                'str_bad: .asciz " bad="', 'str_s: .asciz " s="', 'str_litbad: .asciz "LIT-BAD "',
                'str_end: .asciz "LIT-END\\n"', ".balign 8", "numbuf: .space 24", ".byte 0", ".balign 8"]
        out += self.data
        out += [".section .bss", ".balign 4096", f"stacks: .space {4096 * n}",
                ".section .tohost, \"aw\", @progbits", ".balign 64", ".globl tohost", "tohost: .dword 0",
                ".balign 64", ".globl fromhost", "fromhost: .dword 0"]
        return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--herd", required=True, help="litmus-tests-riscv's model-results/herd.logs")
    ap.add_argument("--harts", default="0,1", help="the harts that run the threads, in thread order")
    ap.add_argument("--iters", type=int, default=200)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("tests", nargs="+")
    a = ap.parse_args()
    harts = [int(h) for h in a.harts.split(",")]
    parsed = []
    for path in a.tests:
        try:
            t = Test(path)
            if t.n > len(harts):
                raise Skip(f"{t.n} threads")
            parsed.append(t)
        except Skip as s:
            print(f"litmus_gen: skip {path}: {s}", file=sys.stderr)
    herd = parse_herd(a.herd, {t.name for t in parsed})
    tests = []
    for t in parsed:
        if t.name not in herd:
            print(f"litmus_gen: skip {t.path}: no herd states", file=sys.stderr)
            continue
        tests.append(t)
    prog = Prog(harts, a.iters, a.seed)
    good = []
    for t in tests:   # a test whose herd variables don't fit is skipped without leaving half its code behind
        mark_t, mark_d = len(prog.text), len(prog.data)
        try:
            prog.test(len(good), t, herd[t.name])
            good.append(t)
        except Skip as s:
            del prog.text[mark_t:], prog.data[mark_d:]
            print(f"litmus_gen: skip {t.path}: {s}", file=sys.stderr)
    prog.text, prog.data = [], []
    text = Prog(harts, a.iters, a.seed).program(good, herd) if good else None
    if text is None:
        print("litmus_gen: no test to run", file=sys.stderr)
        return 3
    with open(a.output, "w") as f:
        f.write(text)
    print(f"litmus_gen: {len(good)} tests", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
