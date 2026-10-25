/* Debug mode (Sdext, TG_DEBUG; core-priv.md "Debug mode"), hart 0, run with tg_vsim's --dbg-win and --no-lockstep
   (Spike sees none of debug mode). Passes at once unless tg_vsim announces --dbg-win (0x0DB6 at 0x0C00_000C), so the
   directed suite runs it under lockstep as a pass.
   Outside debug mode: dcsr and dret are illegal, and a load or store to the debug window faults. Then the program
   raises its own halt request (tg_vsim's register at 0x0C00_0008) and runs straight-line nops; this test's ROM at the
   window's entry (0x1100_0800) plays the debugger, with a phase in the window's RAM:
     1. the halt: cause 3; mcycle and minstret stand still; the request dropped; dcsr.step set; dret
     2. the step: cause 4, dpc one instruction on; dcsr.step cleared, dcsr.ebreakm set; dret
     3. the program's ebreak: cause 1, dpc at it; dpc moved past it; ebreakm cleared; then in debug mode an illegal
        instruction goes to 0x808 with mepc and mcause unchanged, an ebreak re-enters 0x800 with dpc unchanged, and a
        wfi is a nop; dret
     4. a second halt (part D): the ROM steps the jalr at d_jmp, whose target is outside Sv39's range
     5. that step: dpc holds the target in full (pc40: DR-195, core-pipeline.md §8.6); step cleared; dret, and the
        resume faults in M with mepc and mtval in full (the fifth trap)
   The ROM keeps s0 and s1 in dscratch0/1 and t0/t1 in the window's RAM. A failed check writes its code to tohost. */
#include "tg_test.h"
  .option norvc
#define DBGW      0x11000000
#define V_PHASE   0x400
#define V_DPC     0x408
#define V_T0      0x410
#define V_T1      0x418
#define V_EXC     0x420
#define V_MEPC    0x428
#define V_SUB     0x430
#define HALT_REG  0x0C000008
#define DCSR      0x7b0
#define DPC       0x7b1
#define DSCRATCH0 0x7b2
#define DSCRATCH1 0x7b3

  .section .text.init, "ax"
  .globl _start
_start:
  TG_PARK_HARTS
  li t0, HALT_REG + 4             /* --dbg-win (and so a TG_DEBUG core) or nothing to test */
  lw t1, 0(t0)
  li t2, 0x0DB6
  bne t1, t2, pass
  la t0, trap
  csrw mtvec, t0
  li s10, 0                       /* traps seen outside debug mode */
  /* A. outside debug mode */
a_dcsr:
  csrr t1, DCSR                   /* illegal (or absent: the trap handler passes the test when it finds no TG_DEBUG) */
a_dret:
  .word 0x7b200073                /* dret: illegal */
  li t0, DBGW
a_ld:
  lw t1, 0(t0)                    /* load access fault */
a_st:
  sw zero, 0(t0)                  /* store access fault */
  li t1, 4
  bne s10, t1, f_a
  /* B. the halt request, then straight-line nops (the ROM's phases 1 and 2 land in them) */
  li t0, HALT_REG
  li t1, 1
  sw t1, 0(t0)
  .rept 400
  nop
  .endr
  /* C. phase 3 */
b_ebk:
  ebreak
  /* D. phases 4 and 5: the halt again, then a step into a bad pc */
  li s2, 0x8000000000001234
  la s3, d_after
  li t0, HALT_REG
  li t1, 1
  sw t1, 0(t0)
  .rept 400
  nop
  .endr
  j f_d                           /* the halt never came */
d_jmp:
  jalr x0, 0(s2)
d_after:
  li t1, 5
  bne s10, t1, f_d
pass:
  TEST_PASS

trap:                             /* outside debug mode: the four expected traps, in order */
  csrr t2, mcause
  csrr t3, mepc
  addi s10, s10, 1
  li t4, 1
  bne s10, t4, 1f
  la t5, a_dcsr                   /* 1: csrr dcsr, illegal */
  bne t3, t5, f_t
  li t4, 2
  bne t2, t4, f_t
  j 9f
1:li t4, 2
  bne s10, t4, 2f
  la t5, a_dret                   /* 2: dret, illegal */
  bne t3, t5, f_t
  li t4, 2
  bne t2, t4, f_t
  j 9f
2:li t4, 3
  bne s10, t4, 3f
  la t5, a_ld                     /* 3: load access fault */
  bne t3, t5, f_t
  li t4, 5
  bne t2, t4, f_t
  j 9f
3:li t4, 4
  bne s10, t4, 4f
  la t5, a_st                     /* 4: store access fault */
  bne t3, t5, f_t
  li t4, 7
  bne t2, t4, f_t
9:addi t3, t3, 4
  csrw mepc, t3
  mret
4:li t4, 5
  bne s10, t4, f_t
  li t4, 1                        /* 5: the resume at the bad dpc: an access fault, mepc and mtval in full */
  bne t2, t4, f_t
  bne t3, s2, f_t
  csrr t4, mtval
  bne t4, s2, f_t
  csrw mepc, s3
  mret

f_a: TEST_FAIL(1)
f_t: TEST_FAIL(2)
f_d: TEST_FAIL(3)

/* ---- The debug ROM: 0x800 the entry (halt, step, ebreak), 0x808 an exception in debug mode ---- */
  .section .dbgrom, "ax"
rom:
  j rom_entry
  nop
rom_exc:                          /* 0x808: an exception in debug mode (s0 still holds the window's base) */
  li s1, 1
  sd s1, V_EXC(s0)
  la s1, rom_after_exc
  jr s1
rom_entry:
  csrw DSCRATCH0, s0
  csrw DSCRATCH1, s1
  li s0, DBGW
  sd t0, V_T0(s0)
  sd t1, V_T1(s0)
  ld s1, V_SUB(s0)                /* a re-entry by the ROM's own ebreak (phase 3) */
  bnez s1, rom_after_ebk
  ld t0, V_PHASE(s0)
  addi t0, t0, 1
  sd t0, V_PHASE(s0)
  csrr t1, DCSR
  srli t1, t1, 6
  andi t1, t1, 7                  /* cause */
  li s1, 1
  beq t0, s1, ph1
  li s1, 2
  beq t0, s1, ph2
  li s1, 3
  beq t0, s1, ph3
  li s1, 4
  beq t0, s1, ph4
  li s1, 5
  beq t0, s1, ph5
  li a0, (20 << 1) | 1            /* an unexpected entry */
  j rom_fail
ph1:                              /* the halt request */
  li s1, 3
  li a0, (21 << 1) | 1
  bne t1, s1, rom_fail
  csrr t0, mcycle                 /* counters stand still in debug mode (dcsr.stopcount 1) */
  csrr t1, minstret
  nop
  nop
  csrr s1, mcycle
  li a0, (22 << 1) | 1
  bne t0, s1, rom_fail
  csrr s1, minstret
  li a0, (23 << 1) | 1
  bne t1, s1, rom_fail
  li t0, HALT_REG                 /* the request dropped */
  sw zero, 0(t0)
  csrr t0, DPC
  sd t0, V_DPC(s0)
  csrr t0, DCSR
  ori t0, t0, 4                   /* step */
  csrw DCSR, t0
  j rom_exit
ph2:                              /* the step */
  li s1, 4
  li a0, (24 << 1) | 1
  bne t1, s1, rom_fail
  csrr t0, DPC
  ld t1, V_DPC(s0)
  addi t1, t1, 4
  li a0, (25 << 1) | 1
  bne t0, t1, rom_fail
  csrr t0, DCSR
  andi t0, t0, -5                 /* step off */
  li t1, 1 << 15                  /* ebreakm on */
  or t0, t0, t1
  csrw DCSR, t0
  j rom_exit
ph3:                              /* the program's ebreak */
  li s1, 1
  li a0, (26 << 1) | 1
  bne t1, s1, rom_fail
  csrr t0, DPC
  la t1, b_ebk
  li a0, (27 << 1) | 1
  bne t0, t1, rom_fail
  addi t0, t0, 4                  /* resume past it */
  csrw DPC, t0
  csrr t0, DCSR
  li t1, ~(1 << 15)               /* ebreakm off */
  and t0, t0, t1
  csrw DCSR, t0
  csrr t0, mepc                   /* an exception in debug mode: 0x808, mepc and mcause unchanged */
  sd t0, V_MEPC(s0)
  csrr t1, mcause
  sd zero, V_EXC(s0)
  .word 0xfff02073                /* csrr x0, 0xfff: no such CSR, illegal */
rom_after_exc:
  ld s1, V_EXC(s0)
  li a0, (28 << 1) | 1
  beqz s1, rom_fail
  csrr s1, mepc
  ld t0, V_MEPC(s0)
  li a0, (29 << 1) | 1
  bne s1, t0, rom_fail
  csrr s1, mcause
  li a0, (30 << 1) | 1
  bne s1, t1, rom_fail
  csrr t0, DPC                    /* an ebreak in debug mode re-enters 0x800 with dpc unchanged; the entry saves */
  sd t0, V_DPC(s0)                /* the registers again, so they go back to the program's first */
  li s1, 1
  sd s1, V_SUB(s0)
  ld t0, V_T0(s0)
  ld t1, V_T1(s0)
  csrr s1, DSCRATCH1
  csrr s0, DSCRATCH0
  ebreak
rom_after_ebk:
  sd zero, V_SUB(s0)
  csrr t0, DPC
  ld t1, V_DPC(s0)
  li a0, (31 << 1) | 1
  bne t0, t1, rom_fail
  wfi                             /* a nop in debug mode */
  j rom_exit
ph4:                              /* the second halt: step the jalr at d_jmp */
  li s1, 3
  li a0, (32 << 1) | 1
  bne t1, s1, rom_fail
  li t0, HALT_REG
  sw zero, 0(t0)
  la t0, d_jmp
  csrw DPC, t0
  csrr t0, DCSR
  ori t0, t0, 4                   /* step */
  csrw DCSR, t0
  j rom_exit
ph5:                              /* the step into a bad pc: dpc is the jalr's target (s2) in full */
  li s1, 4
  li a0, (33 << 1) | 1
  bne t1, s1, rom_fail
  csrr t0, DPC
  li a0, (34 << 1) | 1
  bne t0, s2, rom_fail
  csrr t0, DCSR
  andi t0, t0, -5                 /* step off; dret to the bad pc */
  csrw DCSR, t0
  j rom_exit
rom_exit:
  ld t0, V_T0(s0)
  ld t1, V_T1(s0)
  csrr s1, DSCRATCH1
  csrr s0, DSCRATCH0
  .word 0x7b200073                /* dret */
rom_fail:
  la s1, tohost
  sd a0, 0(s1)
1:j 1b

  TOHOST_DATA
