/* Tanager simulation platform: console, exit and region markers (verification.md §2.6). */
#ifndef TG_SIM_H
#define TG_SIM_H

#define TG_UART_BASE 0x10000000ul  /* 16550: THR at +0, LSR at +5 (tg_map_pkg::UART_BASE) */

/* A store of 1 starts the region of interest and 2 ends it; tg_vsim reports its cycles and
   retired instructions. */
extern volatile unsigned long tg_marker;
static __inline__ void tg_region_start(void) { tg_marker = 1; }
static __inline__ void tg_region_stop(void) { tg_marker = 2; }

static __inline__ unsigned long tg_rdinstret(void) {
  unsigned long v;
  __asm__ volatile(".option push\n.option arch, +zicsr\ncsrr %0, instret\n.option pop" : "=r"(v));
  return v;
}

#endif
