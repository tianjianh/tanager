/* Tanager's ACT4 platform macros for tg_vsim (docs/spec/verification.md §2.4, §2.6, §6.1). Each
   configuration's rvmodel_macros.h includes this file. For the Sail reference runs the framework
   replaces these with its own (tests/env/sail_macros.h); they run only on the DUT. */
#ifndef TANAGER_RVMODEL_H
#define TANAGER_RVMODEL_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .balign 64; .global tohost; tohost: .dword 0;        \
        .balign 64; .global fromhost; fromhost: .dword 0;    \
        .popsection;

#define STANDARD_SM_SUPPORTED

/* M7 (DR-175): hart 0 runs the test; another hart (a sibling thread that fetches from reset) parks in WFI.
   The framework puts this in .text.rvmodel, so the test's own addresses don't move. */
#define RVMODEL_BOOT              \
  csrr t0, mhartid               ;\
  beqz t0, 9001f                 ;\
9000:                            ;\
  wfi                            ;\
  j 9000b                        ;\
9001:

/* Termination: tohost = 1 passes, 3 fails (tg_vsim's exit code 1). */
#define RVMODEL_HALT_PASS  \
  li x1, 1                ;\
  la t0, tohost           ;\
  write_tohost_pass:      ;\
    sw x1, 0(t0)          ;\
    sw x0, 4(t0)          ;\
    j write_tohost_pass   ;

#define RVMODEL_HALT_FAIL \
  li x1, 3                ;\
  la t0, tohost           ;\
  write_tohost_fail:      ;\
    sw x1, 0(t0)          ;\
    sw x0, 4(t0)          ;\
    j write_tohost_fail   ;

/* Console: the 16550 at UART_BASE (THR +0, LCR +3, LSR +5). */
#define TANAGER_UART_BASE 0x10000000

#define RVMODEL_IO_INIT(_R1, _R2, _R3) \
    li _R1, TANAGER_UART_BASE    ;\
    li _R2, 3                    ;/* 8 data bits, 1 stop bit, no parity */ \
    sb _R2, 3(_R1)               ;

#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR) \
1:                               ;\
  lbu _R1, 0(_STR_PTR)           ;\
  beqz _R1, 3f                   ;\
  li _R2, TANAGER_UART_BASE      ;\
2:                               ;\
  lbu _R3, 5(_R2)                ;/* LSR: wait for THR empty */ \
  andi _R3, _R3, 0x20            ;\
  beqz _R3, 2b                   ;\
  sb _R1, 0(_R2)                 ;\
  addi _STR_PTR, _STR_PTR, 1     ;\
  j 1b                           ;\
3:

/* Nothing is mapped below the boot ROM (tg_map_pkg): an access there faults. */
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000

/* CLINT (tg_map_pkg::ACLINT_BASE). mtime advances once per --mtime-div cycles (20 by default). */
#define TANAGER_CLINT_BASE 0x02000000
#define RVMODEL_MTIME_ADDRESS    (TANAGER_CLINT_BASE + 0xBFF8)
#define RVMODEL_MTIMECMP_ADDRESS (TANAGER_CLINT_BASE + 0x4000)
#define RVMODEL_MSIP_ADDRESS     (TANAGER_CLINT_BASE + 0x0)
#define RVMODEL_MAX_CYCLES_PER_TIMER_TICK 20
/* Ticks until a "soon" timer interrupt. The *_INT_SOON_U macros reach M-mode through ecalls (T-SBI)
   to read mtime and write mtimecmp; on the multi-cycle test core that round trip takes about 5,000
   cycles (250 ticks), and the interrupt must not fire before the test samples its trap count. */
#define RVMODEL_TIMER_INT_SOON_DELAY 2000
/* Loop iterations to wait for an interrupt raised by a store: generous for the multi-cycle test core. */
#define RVMODEL_INTERRUPT_LATENCY 200

/* External and supervisor software interrupts: tg_vsim's simple interrupt generator, the same
   register Sail models (verification.md §2.4). Bit 31 set raises the named lines, clear lowers them. */
#define TANAGER_SIG_ADDRESS 0x0C000004

#define RVMODEL_SET_MEXT_INT(_R1, _R2) \
  li _R1, (1 << 31) | (1 << 11) ;\
  li _R2, TANAGER_SIG_ADDRESS   ;\
  sw _R1, 0(_R2)                ;

#define RVMODEL_CLR_MEXT_INT(_R1, _R2) \
  li _R1, (1 << 11)             ;\
  li _R2, TANAGER_SIG_ADDRESS   ;\
  sw _R1, 0(_R2)                ;

#define RVMODEL_SET_SEXT_INT(_R1, _R2) \
  li _R1, (1 << 31) | (1 << 9)  ;\
  li _R2, TANAGER_SIG_ADDRESS   ;\
  sw _R1, 0(_R2)                ;

#define RVMODEL_CLR_SEXT_INT(_R1, _R2) \
  li _R1, (1 << 9)              ;\
  li _R2, TANAGER_SIG_ADDRESS   ;\
  sw _R1, 0(_R2)                ;

#define RVMODEL_SET_SSW_INT(_R1, _R2) \
  li _R1, (1 << 31) | (1 << 1)  ;\
  li _R2, TANAGER_SIG_ADDRESS   ;\
  sw _R1, 0(_R2)                ;

#define RVMODEL_CLR_SSW_INT(_R1, _R2) \
  li _R1, (1 << 1)              ;\
  li _R2, TANAGER_SIG_ADDRESS   ;\
  sw _R1, 0(_R2)                ;

#endif /* TANAGER_RVMODEL_H */
