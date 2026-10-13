/* Host interface of tgsim's simulated machine (see src/iss.h). */
#ifndef TGSIM_H
#define TGSIM_H

#define TG_PUTC   ((volatile unsigned int *)0x10000000u)
#define TG_GETC   ((volatile int *)0x10000004u)
#define TG_EXIT   ((volatile unsigned int *)0x10000008u)
#define TG_MARKER ((volatile unsigned int *)0x10000010u)

/* Region of interest: tgsim reports the cycles and instructions between marker 1 and marker 2. */
static __inline__ void tg_region_start(void) { *TG_MARKER = 1; }
static __inline__ void tg_region_stop(void) { *TG_MARKER = 2; }

#endif
