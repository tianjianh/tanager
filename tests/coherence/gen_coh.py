#!/usr/bin/env python3
"""gen_coh: two-hart programs that contend for cache lines with atomics (docs/spec/verification.md §6.5;
DR-149's two-core coherence soak, and the board's boot-lottery hang of 2026-10-16).

Every hart leaves the boot ROM in the same cycle and runs the same code; --harts names the ones that take
part (0,1 on two single-thread cores; 0,2 or 0,1,2,3 on two smt2 cores, where threads of one core share
its L1D), and the others park. The first thing each does, with no memory access before it, is an
OpenSBI-like lottery: amoswap.w on a zeroed word, the hart that swaps the 0 out wins. That is the
board's case when the harts are in step. Then, by mode:
  mix, amo, lrsc  rounds of AMOs and constrained LR/SC loops on words of that one line (amo: AMOs only;
                  lrsc: LR/SC only), a barrier, and hart 0's check of every final value;
  lottery         more lotteries, each on a line no hart has touched, so each starts with both harts
                  missing in the L1D and the L2; every lottery starts at a fixed mcycle, with the
                  harts in step or one of them up to 48 cycles later; AMOs of several kinds;
  lottery-lrsc    the same with LR/SC test-and-set lotteries among them;
  mp              rounds of message passing with plain loads and stores, as Linux's spin-waits do: the
                  first two harts take turns, one writing six data words, FENCE W,W and a flag, the other
                  spinning on the flag with plain loads, FENCE R,R, checking the data and answering with
                  a flag of its own; data and flags share a line or not (checked by lockstep with its
                  windows for other harts' writes, verification.md §3.7);
  race            a write race on one word, for lockstep alone: the first hart stores to it, the second
                  applies AMOs with rd = x0 and LR/SC increments to it, and after the barrier the first
                  hart loads it (its value is whichever write came last, so the program checks nothing).
In the other modes every read of a word another hart writes is an atomic. The barrier is on a line of its own: a hart spinning on the contended line with AMOs could starve
another's LR/SC loop, which the ISA allows (its forward-progress guarantee excludes other harts'
stores and AMOs to the reservation set). The first hart listed prints COH-PASS, or COH-FAIL and the slot
or lottery that is wrong (two hex digits), then COH-END. A hang prints neither.
  gen_coh.py --seed 1 [--mode mix] [--harts 0,1] -o prog.S
"""
import argparse
import random
import sys

UART = 0x10000000
SLOTS = 8             # 8-byte words in the contended line
MODES = ("mix", "amo", "lrsc", "lottery", "lottery-lrsc", "mp", "race")
T0, PERIOD = 3000, 600   # lottery k >= 1 starts at mcycle T0 + k * PERIOD (+ the hart's offset)


def delay_code(e, delay):
    """A busy wait for one hart, in instructions only (no memory access before the first lottery)."""
    if delay is None:
        return
    hart, n = delay
    e("  li t3, 0")
    e(f"  li t0, {hart}")
    e("  bne a0, t0, 2f")
    e(f"  li t3, {n}")
    e("2:")
    e("  beqz t3, 3f")
    e("  addi t3, t3, -1")
    e("  j 2b")
    e("3:")


def barrier(e, n):
    """Release, then an acquire spin read with an atomic, on the line `bar` (not a contended line)."""
    e("  la t1, bar")
    e("  li t2, 1")
    e("  amoadd.w.aqrl zero, t2, (t1)")
    e("5:")
    e("  amoor.w.aq t2, zero, (t1)")
    e(f"  li t3, {n}")
    e("  bne t2, t3, 5b")


def rounds_body(r, e, mode, n):
    """The mix / amo / lrsc modes: rounds of operations on slots 1-7 of `line`; returns the checks."""
    rounds = r.choice([8, 16, 32, 64])
    amo_kinds = ["add_w", "add_d", "or_w", "maxu_d", "swap_w"]
    lrsc_kinds = ["lrsc_w", "lrsc_d"]
    if mode == "amo":
        ops = r.sample(amo_kinds, r.randrange(2, len(amo_kinds) + 1))
    elif mode == "lrsc":
        ops = r.sample(lrsc_kinds, r.randrange(1, 3))
    else:
        ops = r.sample(amo_kinds + lrsc_kinds, r.randrange(2, 8))
    slot = {k: 1 + i for i, k in enumerate(ops)}
    e("  la s0, line")
    e("  li s1, 1")
    e(f"  li s2, {rounds}")
    e("round:")
    for k in ops:
        off = slot[k] * 8
        e("  addi t1, s0, %d" % off)
        if k == "add_w":
            e("  amoadd.w zero, s1, (t1)")
        elif k == "add_d":
            e("  amoadd.d zero, s1, (t1)")
        elif k in ("lrsc_w", "lrsc_d"):   # a constrained LR/SC loop (ISA: eventual success)
            w = k[-1]
            e(f"lr{off}:")
            e(f"  lr.{w} t2, (t1)")
            e("  addi t2, t2, 1")
            e(f"  sc.{w} t3, t2, (t1)")
            e(f"  bnez t3, lr{off}")
        elif k == "or_w":
            e("  sll t2, s1, a4")
            e("  amoor.w zero, t2, (t1)")
        elif k == "maxu_d":
            e("  slli t2, a4, 16")
            e("  add t2, t2, s2")
            e("  amomaxu.d zero, t2, (t1)")
        elif k == "swap_w":
            e("  addi t2, a4, 1")
            e("  amoswap.w zero, t2, (t1)")
    e("  addi s2, s2, -1")
    e("  bnez s2, round")
    desc = "%d rounds, operations %s" % (rounds, " ".join(ops))

    def checks():
        e("  la s0, line")
        for k in ops:
            off = slot[k] * 8
            e(f"  li t4, {slot[k]}")
            if k in ("add_w", "lrsc_w"):
                e(f"  lw t3, {off}(s0)")
                e(f"  li t5, {n * rounds}")
            elif k in ("add_d", "lrsc_d"):
                e(f"  ld t3, {off}(s0)")
                e(f"  li t5, {n * rounds}")
            elif k == "or_w":
                e(f"  lw t3, {off}(s0)")
                e(f"  li t5, {(1 << n) - 1}")
            elif k == "maxu_d":
                e(f"  ld t3, {off}(s0)")
                e(f"  li t5, {((n - 1) << 16) + rounds}")
            elif k == "swap_w":   # the last swap wins: any hart's value
                e(f"  lw t3, {off}(s0)")
                e("  addi t3, t3, -1")
                e(f"  li t5, {n}")
                e("  bgeu t3, t5, fail")
                continue
            e("  bne t3, t5, fail")
    return desc, checks


def lottery_body(r, e, mode, nh, harts):
    """The lottery modes: lotteries 1..n-1 on lines 1..n-1 of `lines`, at fixed mcycles; returns checks."""
    n = r.choice([16, 32, 48, 64])
    kinds = ["swap_w", "swap_d", "add_w", "or_w"] + (["tas_w", "tas_d"] if mode == "lottery-lrsc" else [])
    plan = []
    for k in range(1, n):
        kind = r.choice(kinds)
        offs = [0] * nh
        if r.randrange(2):
            offs[r.randrange(nh)] = r.choice([1, 2, 3, 4, 5, 6, 8, 12, 16, 24, 32, 48])
        plan.append((k, kind, offs))
    e("  addi s5, a4, 1")       # the swap and test-and-set value, index + 1
    e("  li s6, 1")
    e("  sll s6, s6, a4")       # the OR value, 1 << index
    for k, kind, offs in plan:
        e(f"# lottery {k}: {kind}, offsets {offs}")
        e(f"  li t3, {T0 + k * PERIOD}")
        for i, o in enumerate(offs):
            if o:
                e(f"  li t0, {i}")
                e("  bne a4, t0, 1f")
                e(f"  li t3, {T0 + k * PERIOD + o}")
                e("1:")
        e("2:")
        e("  csrr t2, mcycle")
        e("  bltu t2, t3, 2b")
        e("  addi s0, s0, 64")
        w = kind[-1]
        if kind.startswith("swap"):
            e(f"  amoswap.{w} t1, s5, (s0)")
        elif kind == "add_w":
            e("  amoadd.w t1, s1, (s0)")
        elif kind == "or_w":
            e("  amoor.w t1, s6, (s0)")
        else:                    # test-and-set with a constrained LR/SC loop; a lost lottery skips the SC
            e("3:")
            e(f"  lr.{w} t1, (s0)")
            e("  bnez t1, 4f")
            e(f"  sc.{w} t2, s5, (s0)")
            e("  bnez t2, 3b")
            e("4:")
        e("  seqz t2, t1")
        e(f"  slli t2, t2, {k}")
        e("  or s7, s7, t2")
    desc = "%d lotteries, %d with offsets, kinds %s" % (
        n, sum(1 for p in plan if any(p[2])), " ".join(sorted({p[1] for p in plan})))
    masks = ["s8", "s9", "s10", "s11"][:nh]

    def checks():
        # The win masks: bit k of hart i's says it won lottery k; each lottery has exactly one winner
        e("  la t2, res")
        e("  li t4, 0xff")
        e("  li t5, 0")
        for i, m in enumerate(masks):
            e(f"  ld {m}, {8 * i}(t2)")
            e(f"  and t6, t5, {m}")
            e("  bnez t6, fail")
            e(f"  or t5, t5, {m}")
        e(f"  li t6, {(1 << n) - 1 if n < 64 else -1}")
        e("  bne t5, t6, fail")
        e("  la s0, lines")
        e("  addi s0, s0, -64")
        for k, kind in [(0, "first_w")] + [(p[0], p[1]) for p in plan]:
            e("  addi s0, s0, 64")
            e(f"  li t4, {k}")
            e(f"  l{kind[-1]} t3, 0(s0)")
            e("  li t6, 0")            # the winner's index
            for i, m in enumerate(masks[1:], 1):
                e(f"  srli t5, {m}, {k}")
                e("  andi t5, t5, 1")
                e("  beqz t5, 7f")
                e(f"  li t6, {i}")
                e("7:")
            if kind == "first_w":      # OpenSBI's: every hart swaps in 1
                e("  li t5, 1")
            elif kind.startswith("swap"):   # a loser swapped last: its index + 1, not the winner's
                e("  addi t5, t3, -1")
                e("  beq t5, t6, fail")
                e(f"  li t6, {nh}")
                e("  bgeu t5, t6, fail")
                continue
            elif kind == "add_w":
                e(f"  li t5, {nh}")
            elif kind == "or_w":
                e(f"  li t5, {(1 << nh) - 1}")
            else:
                e("  addi t5, t6, 1")  # only the winner stores: its index + 1
            e("  bne t3, t5, fail")
    return desc, checks


def mp_body(r, e, nh):
    """The mp mode: message passing with plain loads and stores between the first two harts."""
    rounds = r.choice([16, 32, 64])
    shared = r.randrange(2)          # the flags in the data's line, or each on a line of its own
    e("  la s0, mpdata")
    e("  addi s3, s0, 48" if shared else "  la s3, mpflag")
    e("  addi s4, s0, 56" if shared else "  la s4, mpack")
    e(f"  li s2, {rounds}")
    e("  li s5, 1")                  # the round, 1..rounds
    e("  li s6, 0")                  # data words the consumer found wrong
    e("  li t0, 1")
    e("  bgtu a4, t0, 9f")           # harts after the first two only meet the others at the barrier
    e("  bnez a4, 7f")
    e("6:")                          # the producer
    for j in range(6):
        e("  slli t1, s5, 8")
        e(f"  addi t1, t1, {j}")
        e(f"  sd t1, {8 * j}(s0)")
    e("  fence w, w")
    e("  sd s5, 0(s3)")
    e("5:")
    e("  ld t2, 0(s4)")
    e("  bne t2, s5, 5b")
    e("  addi s5, s5, 1")
    e("  bleu s5, s2, 6b")
    e("  j 9f")
    e("7:")                          # the consumer
    e("4:")
    e("  ld t2, 0(s3)")
    e("  bne t2, s5, 4b")
    e("  fence r, r")
    for j in range(6):
        e(f"  ld t1, {8 * j}(s0)")
        e("  slli t3, s5, 8")
        e(f"  addi t3, t3, {j}")
        e("  beq t1, t3, 3f")
        e("  addi s6, s6, 1")
        e("3:")
    e("  sd s5, 0(s4)")
    e("  addi s5, s5, 1")
    e("  bleu s5, s2, 4b")
    e("9:")
    e("  la t1, mperr")
    e("  slli t2, a4, 3")
    e("  add t1, t1, t2")
    e("  sd s6, 0(t1)")
    desc = "%d rounds of message passing, flags %s" % (rounds, "in the data's line" if shared else "on lines of their own")

    def checks():
        e("  la t2, mperr")
        e("  li t4, 9")                # the slot named in a failure: 9 for the message passing
        for i in range(nh):
            e(f"  ld t3, {8 * i}(t2)")
            e("  bnez t3, fail")
    return desc, checks


def race_body(r, e, nh):
    """The race mode: plain stores against AMOs (rd = x0) and LR/SC on one word."""
    rounds = r.choice([16, 32, 64])
    e("  la s0, line")
    e("  addi s0, s0, 8")             # slot 1 of the line
    e(f"  li s2, {rounds}")
    e("  li t0, 1")
    e("  bgtu a4, t0, 9f")
    e("  bnez a4, 7f")
    e("6:")                           # the first hart: plain stores
    e("  slli t1, s2, 32")
    e("  sd t1, 0(s0)")
    e("  addi s2, s2, -1")
    e("  bnez s2, 6b")
    e("  j 9f")
    e("7:")                           # the second: AMOs with rd = x0 and an LR/SC increment
    e("  li t1, 1")
    e("  amoadd.d zero, t1, (s0)")
    e("  slli t2, t1, 20")
    e("  amoor.d zero, t2, (s0)")
    e("5:")
    e("  lr.d t2, (s0)")
    e("  addi t2, t2, 1")
    e("  sc.d t3, t2, (s0)")
    e("  bnez t3, 5b")
    e("  addi s2, s2, -1")
    e("  bnez s2, 7b")
    e("9:")
    desc = "%d rounds of plain stores against amoadd/amoor (rd = x0) and LR/SC on one word" % rounds

    def checks():
        e("  la s0, line")
        e("  ld t3, 8(s0)")           # whatever came last; lockstep checks the value against Spike's
    return desc, checks


def program(seed, mode, harts):
    nh = len(harts)
    r = random.Random(seed * 1000003 + 11 + 7919 * MODES.index(mode) + 104729 * sum(1 << h for h in harts))
    # Most programs keep the harts in step (the board's case); some delay one of them a little.
    delay = None if r.randrange(4) else (r.choice(harts), r.choice([1, 2, 3, 5, 8, 13, 40, 200]))
    L = []
    e = L.append
    e("  .section .text.init, \"ax\"")
    e("  .globl _start")
    e("_start:")
    e("  csrr a0, mhartid")
    e(f"  li t0, {sum(1 << h for h in harts):#x}")   # the same instructions on every hart that takes part
    e("  srl t0, t0, a0")
    e("  andi t0, t0, 1")
    e("  beqz t0, park")
    delay_code(e, delay)
    # The lottery, as OpenSBI's: no memory access before it
    e("  la s0, line" if not mode.startswith("lottery") else "  la s0, lines")
    e("  li s1, 1")
    e("  amoswap.w t1, s1, (s0)")
    e("  seqz s7, t1")           # bit 0 of the win mask
    # This hart's index among those taking part, in a4
    for i, h in enumerate(harts):
        e(f"  li a4, {i}")
        e(f"  li t0, {h}")
        e("  beq a0, t0, 8f")
    e("  j park")
    e("8:")
    if mode.startswith("lottery"):
        desc, checks = lottery_body(r, e, mode, nh, harts)
    elif mode == "mp":
        desc, checks = mp_body(r, e, nh)
    elif mode == "race":
        desc, checks = race_body(r, e, nh)
    else:
        desc, checks = rounds_body(r, e, mode, nh)
    # Each hart's win mask to its slot of `res`, then the barrier
    e("  la t1, res")
    e("  slli t2, a4, 3")
    e("  add t1, t1, t2")
    e("  sd s7, 0(t1)")
    barrier(e, nh)
    e("  bnez a4, park")
    # The first hart checks; t4 holds the slot or lottery being checked, for the failure message
    if not mode.startswith("lottery"):
        e("  la t2, res")
        e("  li t3, 0")
        for i in range(nh):
            e(f"  ld t5, {8 * i}(t2)")
            e("  add t3, t3, t5")    # one winner
        e("  li t4, 0")
        e("  li t5, 1")
        e("  bne t3, t5, fail")
        e("  la s0, line")
        e("  lw t3, 0(s0)")
        e("  bne t3, t5, fail")  # the lottery word ends at 1
    checks()
    e("  la a1, msg_pass")
    e("  j print")
    e("fail:")
    e("  la a1, msg_fail")
    e("  call puts")
    e(f"  li t0, {UART:#x}")
    for sh in (4, 0):
        e(f"  srli a2, t4, {sh}")
        e("  andi a2, a2, 15")
        e("  addi a2, a2, '0'")
        e("  li a3, '9'")
        e("  ble a2, a3, 6f")
        e("  addi a2, a2, 'a' - '9' - 1")
        e("6:")
        e("  sb a2, 0(t0)")
    e("  la a1, msg_nl")
    e("print:")
    e("  call puts")
    e("  la a1, msg_end")           # tb_boot stops at +expect=COH-END, after the verdict
    e("  call puts")
    e("park:")
    e("  wfi")
    e("  j park")
    e("puts:")
    e(f"  li t0, {UART:#x}")
    e("3:")
    e("  lbu t1, 0(a1)")
    e("  beqz t1, 4f")
    e("  sb t1, 0(t0)")
    e("  addi a1, a1, 1")
    e("  j 3b")
    e("4:")
    e("  ret")
    e("  .section .data")
    if mode.startswith("lottery"):
        e("  .balign 64")
        e("lines:")
        e("  .zero %d" % (64 * 64))
    else:
        e("  .balign 64")
        e("line:")
        e(f"  .zero {SLOTS * 8}")
    if mode == "mp":
        e("  .balign 64")
        e("mpdata:")
        e("  .zero 64")
        e("mpflag:")
        e("  .zero 64")
        e("mpack:")
        e("  .zero 64")
        e("mperr:")
        e(f"  .zero {nh * 8}")
    e("  .balign 64")
    e("bar:")
    e("  .zero 64")
    e("res:")
    e(f"  .zero {nh * 8}")
    e("  .balign 64")
    e("msg_pass: .string \"COH-PASS\\n\"")
    e("msg_fail: .string \"COH-FAIL slot \"")
    e("msg_nl: .string \"\\n\"")
    e("msg_end: .string \"COH-END\\n\"")
    head = "# gen_coh seed %d, mode %s, harts %s: %s, %s" % (
        seed, mode, ",".join(map(str, harts)), desc, "delay of hart %d: %d" % delay if delay else "no delay")
    return head + "\n" + "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--mode", choices=MODES, default="mix")
    ap.add_argument("--harts", default="0,1", help="the harts that take part (2 to 4 mhartids)")
    ap.add_argument("-o", "--output", default="-")
    a = ap.parse_args()
    harts = [int(h) for h in a.harts.split(",")]
    if not 2 <= len(harts) <= 4 or len(set(harts)) != len(harts) or not all(0 <= h < 64 for h in harts):
        ap.error("--harts: 2 to 4 distinct mhartids")
    text = program(a.seed, a.mode, harts)
    if a.output == "-":
        sys.stdout.write(text)
    else:
        with open(a.output, "w") as f:
            f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
