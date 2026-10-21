/* The pair runner's shared state (tests/bench/pair; docs/spec/verification.md §4.8; the M7 plan's exit 2).
   One image holds the dispatcher at 0x8000_0000 and two programs, each linked at its slot's base. A program's
   first region of interest (its markers 1 and 2) is timed on its own hart's mcycle and minstret; the two first
   regions start together, after a barrier; a program that ends runs again from the top, so both harts stay busy
   until both first regions are done, and the last to finish prints the results and writes tohost. */
#ifndef TG_PAIR_H
#define TG_PAIR_H

#include <stdint.h>

#define PAIR_SHARED 0x80080000ul   /* struct pair_shared, in the dispatcher's image */
#define PAIR_TOHOST 0x80001000ul   /* the dispatcher's tohost */

struct pair_slot {
  uint64_t c0, i0, c1, i1;         /* mcycle and minstret at the first region's start and end */
  uint64_t started, stopped, runs;
  uint64_t pad;
};

struct pair_shared {
  int64_t slot_of_hart[4];         /* the dispatcher's configuration: the slot each hart runs, -1 parks it */
  uint64_t active;                 /* slots that run */
  uint64_t at_start;               /* slots at their first region's start (the barrier) */
  uint64_t done;                   /* slots past their first region */
  uint64_t print_lock;             /* one hart prints at a time: two harts' lines would interleave on the UART */
  struct pair_slot s[2];
};

void tg_pair_mark(unsigned v);
static __inline__ void tg_region_start(void) { tg_pair_mark(1); }
static __inline__ void tg_region_stop(void) { tg_pair_mark(2); }

#endif
