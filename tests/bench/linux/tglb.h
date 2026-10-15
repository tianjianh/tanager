/* Counters and the report line of the Linux workload set (DR-141; docs/spec/verification.md §4.6).
   Every measurement prints one line:
     TGLB <test> run=<k> cycles=<n|-> instret=<n|-> ticks=<n> ns=<n> ops=<n> [<key>=<value> ...]
   cycles and instret come from rdcycle and rdinstret. Linux lets user mode read them only with the
   SBI PMU driver and kernel.perf_user_access = 2; otherwise they trap, and the line says "-". ticks
   come from rdtime, at the device tree's timebase-frequency; ns from CLOCK_MONOTONIC. */
#ifndef TGLB_H
#define TGLB_H

#include <inttypes.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static inline uint64_t tglb_rdcycle(void) {
  uint64_t v;
  __asm__ volatile("rdcycle %0" : "=r"(v));
  return v;
}
static inline uint64_t tglb_rdinstret(void) {
  uint64_t v;
  __asm__ volatile("rdinstret %0" : "=r"(v));
  return v;
}
static inline uint64_t tglb_rdtime(void) {
  uint64_t v;
  __asm__ volatile("rdtime %0" : "=r"(v));
  return v;
}
static inline uint64_t tglb_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

/* Whether user mode may read cycle and instret, probed once with SIGILL caught. */
static sigjmp_buf tglb_jb;
static void tglb_on_sigill(int s) {
  (void)s;
  siglongjmp(tglb_jb, 1);
}
static int tglb_has_cycle(void) {
  static int known = -1;
  if (known >= 0) return known;
  struct sigaction sa, old;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = tglb_on_sigill;
  sigaction(SIGILL, &sa, &old);
  if (sigsetjmp(tglb_jb, 1) == 0) {
    (void)tglb_rdcycle();
    (void)tglb_rdinstret();
    known = 1;
  } else {
    known = 0;
  }
  sigaction(SIGILL, &old, NULL);
  return known;
}

struct tglb_mark {
  uint64_t cyc, ins, tick, ns;
};

static inline void tglb_take(struct tglb_mark *m) {
  int c = tglb_has_cycle();
  m->ns = tglb_ns();
  m->tick = tglb_rdtime();
  m->cyc = c ? tglb_rdcycle() : 0;
  m->ins = c ? tglb_rdinstret() : 0;
}

/* One report line; extra is "" or " key=value ..." */
static void tglb_report(const char *test, int run, const struct tglb_mark *a, const struct tglb_mark *b,
                        uint64_t ops, const char *extra) {
  char cyc[24] = "-", ins[24] = "-";
  if (tglb_has_cycle()) {
    snprintf(cyc, sizeof cyc, "%" PRIu64, b->cyc - a->cyc);
    snprintf(ins, sizeof ins, "%" PRIu64, b->ins - a->ins);
  }
  printf("TGLB %s run=%d cycles=%s instret=%s ticks=%" PRIu64 " ns=%" PRIu64 " ops=%" PRIu64 "%s\n", test, run,
         cyc, ins, b->tick - a->tick, b->ns - a->ns, ops, extra ? extra : "");
  fflush(stdout);
}

#endif
