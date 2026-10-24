/* Zkt (M9 §10, DR-194; docs/spec/m9-isa-check.md): the listed instructions' latency must not depend on their operands'
   values. For each listed instruction a 64-long dependent chain (each instruction takes the last one's result in its
   first operand) is timed with mcycle under each operand class: 0, 1, -1, the sign bit alone, small, large, mixed signs,
   and for shifts and rotates the amounts 0, 1, 31, 32 and 63 (in the second operand, or the immediate). A run before
   the timed ones warms the I$. Within an instruction every class must take the same cycles: the simulation is cycle-
   exact. The listed set: the base integer ALU ops with their W and immediate forms, LUI and AUIPC, the multiplies, and
   Zbkb's share of Zbb (ANDN, ORN, XNOR, ROL, ROR, RORI, ROLW, RORW, RORIW, REV8); the compressed forms run as these.
   Fails with code k, the k-th instruction tested, at the first class that differs from the first class's count, and
   with 46 on any trap but the probe's. Without Zbb (the test core) the probe traps and the Zbkb part is skipped, as in
   zbb.S; lockstep catches a core that has Zbb and traps. Trace back-pressure and random wakes change the counts by
   design, so those runs leave it out (tests/isa/exclude/directed-timing.txt). */
#include "tg_test.h"
  .option arch, +zbb
#define NPAIRS  8
#define NVALS   8
#define NSHIFTS 8

/* the timed chain, one copy per use, 64-byte aligned: a0 = s2, a1 = s3, then 64 x (op a0, a0, a1), timed into t1 */
.macro CHAIN op
  mv a0, s2
  mv a1, s3
  .balign 64
  csrr t0, mcycle
  .rept 64
  \op a0, a0, a1
  .endr
  csrr t1, mcycle
  sub t1, t1, t0
.endm
.macro CHAINI op, imm
  mv a0, s2
  .balign 64
  csrr t0, mcycle
  .rept 64
  \op a0, a0, \imm
  .endr
  csrr t1, mcycle
  sub t1, t1, t0
.endm
.macro CHAIN1 op
  mv a0, s2
  .balign 64
  csrr t0, mcycle
  .rept 64
  \op a0, a0
  .endr
  csrr t1, mcycle
  sub t1, t1, t0
.endm
.macro CHAINU op, imm
  .balign 64
  csrr t0, mcycle
  .rept 64
  \op a0, \imm
  .endr
  csrr t1, mcycle
  sub t1, t1, t0
.endm
/* CMP: in the measuring pass (s7 = 1), the instruction's first count is its reference (s4 < 0 until then); every
   later count must equal it */
.macro CMP
  li t2, 1
  bne s7, t2, 8f
  bgez s4, 7f
  mv s4, t1
  j 8f
7:
  bne t1, s4, fail
8:
.endm
/* TESTRR op, code, table, n: the register form over the table's n pairs (s2, s3), one chain, two passes */
.macro TESTRR op, code, table, n
  li a7, \code
  li s4, -1
  li s7, 2
4:
  la s5, \table
  li s6, \n
1:
  ld s2, 0(s5)
  ld s3, 8(s5)
  CHAIN \op
  CMP
  addi s5, s5, 16
  addi s6, s6, -1
  bnez s6, 1b
  addi s7, s7, -1
  bnez s7, 4b
.endm
/* ONEI op, imm: an immediate form with one immediate over the first operands in vals, one chain, two passes */
.macro ONEI op, imm
  li s7, 2
4:
  la s5, vals
  li s6, NVALS
1:
  ld s2, 0(s5)
  CHAINI \op, \imm
  CMP
  addi s5, s5, 8
  addi s6, s6, -1
  bnez s6, 1b
  addi s7, s7, -1
  bnez s7, 4b
.endm
/* TESTRI op, code: immediates 0, 1, -1, 2047 and -2048 */
.macro TESTRI op, code
  li a7, \code
  li s4, -1
  ONEI \op, 0
  ONEI \op, 1
  ONEI \op, -1
  ONEI \op, 2047
  ONEI \op, -2048
.endm
/* TESTSI op, code, max: a shift or rotate by immediate, amounts 0, 1, 31, and 32 and 63 when max is 63 */
.macro TESTSI op, code, max
  li a7, \code
  li s4, -1
  ONEI \op, 0
  ONEI \op, 1
  ONEI \op, 31
  .if \max == 63
  ONEI \op, 32
  ONEI \op, 63
  .endif
.endm
/* TEST1 op, code: a unary op over vals */
.macro TEST1 op, code
  li a7, \code
  li s4, -1
  li s7, 2
4:
  la s5, vals
  li s6, NVALS
1:
  ld s2, 0(s5)
  CHAIN1 \op
  CMP
  addi s5, s5, 8
  addi s6, s6, -1
  bnez s6, 1b
  addi s7, s7, -1
  bnez s7, 4b
.endm
/* ONEU op, imm: LUI or AUIPC with one immediate, 64 in a row (no register operand), two passes */
.macro ONEU op, imm
  li s7, 2
4:
  CHAINU \op, \imm
  CMP
  addi s7, s7, -1
  bnez s7, 4b
.endm
.macro TESTU op, code
  li a7, \code
  li s4, -1
  ONEU \op, 0
  ONEU \op, 1
  ONEU \op, 0x80000
  ONEU \op, 0xfffff
.endm

  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  la t0, trap
  csrw mtvec, t0
  li s8, 1
zprobe:
  andn t1, t1, t1                   /* the Zbb probe (zbb.S's rule): without Zbb it traps and s8 = 0 */
  TESTRR add,    1, pairs,  NPAIRS
  TESTRR sub,    2, pairs,  NPAIRS
  TESTRR and,    3, pairs,  NPAIRS
  TESTRR or,     4, pairs,  NPAIRS
  TESTRR xor,    5, pairs,  NPAIRS
  TESTRR slt,    6, pairs,  NPAIRS
  TESTRR sltu,   7, pairs,  NPAIRS
  TESTRR sll,    8, shifts, NSHIFTS
  TESTRR srl,    9, shifts, NSHIFTS
  TESTRR sra,   10, shifts, NSHIFTS
  TESTRR addw,  11, pairs,  NPAIRS
  TESTRR subw,  12, pairs,  NPAIRS
  TESTRR sllw,  13, shifts, NSHIFTS
  TESTRR srlw,  14, shifts, NSHIFTS
  TESTRR sraw,  15, shifts, NSHIFTS
  TESTRR mul,   16, pairs,  NPAIRS
  TESTRR mulh,  17, pairs,  NPAIRS
  TESTRR mulhsu,18, pairs,  NPAIRS
  TESTRR mulhu, 19, pairs,  NPAIRS
  TESTRR mulw,  20, pairs,  NPAIRS
  TESTRI addi,  21
  TESTRI andi,  22
  TESTRI ori,   23
  TESTRI xori,  24
  TESTRI slti,  25
  TESTRI sltiu, 26
  TESTRI addiw, 27
  TESTSI slli,  28, 63
  TESTSI srli,  29, 63
  TESTSI srai,  30, 63
  TESTSI slliw, 31, 31
  TESTSI srliw, 32, 31
  TESTSI sraiw, 33, 31
  TESTU  lui,   34
  TESTU  auipc, 35
  beqz s8, zdone
  TESTRR andn,  36, pairs,  NPAIRS
  TESTRR orn,   37, pairs,  NPAIRS
  TESTRR xnor,  38, pairs,  NPAIRS
  TESTRR rol,   39, shifts, NSHIFTS
  TESTRR ror,   40, shifts, NSHIFTS
  TESTRR rolw,  41, shifts, NSHIFTS
  TESTRR rorw,  42, shifts, NSHIFTS
  TESTSI rori,  43, 63
  TESTSI roriw, 44, 31
  TEST1  rev8,  45
zdone:
  TEST_PASS
/* only the probe may trap (an illegal instruction: no Zbb); it resumes after the probe with s8 = 0 */
trap:
  csrr t0, mcause
  li t1, 2
  bne t0, t1, 1f
  csrr t0, mepc
  la t1, zprobe
  bne t0, t1, 1f
  li s8, 0
  addi t0, t0, 4
  csrw mepc, t0
  mret
1:
  li a7, 46
fail:
  slli a7, a7, 1
  ori a7, a7, 1
  la a1, tohost
  sd a7, 0(a1)
9: j 9b

  .data
  .align 3
/* operand classes: (first, second) */
pairs:
  .dword 0, 0
  .dword 1, 1
  .dword -1, -1
  .dword 0x8000000000000000, 0x8000000000000000
  .dword 5, 3
  .dword 0x7fffffffffffffff, 0x123456789abcdef1
  .dword -5, 0x7fffffffffffffff
  .dword 0x123456789abcdef0, -3
/* shift amounts in the second operand, first operands of each class */
shifts:
  .dword 0x8000000000000001, 0
  .dword -1, 1
  .dword 0x123456789abcdef0, 31
  .dword 0, 32
  .dword 1, 63
  .dword 0x8000000000000000, 63
  .dword -5, 32
  .dword 5, 0
vals:
  .dword 0, 1, -1, 0x8000000000000000, 5, 0x7fffffffffffffff, -5, 0x123456789abcdef0
  TOHOST_DATA
