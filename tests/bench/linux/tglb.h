/* Counters and the report line of the Linux workload set (DR-141; docs/spec/verification.md §4.6).
   Every measurement prints one line:
     TGLB <test> run=<k> cycles=<n|-> instret=<n|-> ticks=<n> ns=<n> ops=<n> [<key>=<value> ...]
   cycles and instret come from rdcycle and rdinstret. Linux lets user mode read them only with the
   SBI PMU driver and kernel.perf_user_access = 2 (legacy access); otherwise they trap. The driver also
   stops every counter at boot, so that perf can start them: pinned system-wide cycles and instructions
   events on every CPU, which legacy mode puts on the fixed mcycle and minstret, keep them counting
   while the program runs. A counter that traps or does not advance makes the line say "-". The counters
   are per hart, so a program pins itself, and the programs it starts, to the hart it first measures on.
   ticks come from rdtime, at the device tree's timebase-frequency; ns from CLOCK_MONOTONIC. */
#ifndef TGLB_H
#define TGLB_H

#include <errno.h>
#include <inttypes.h>
#include <linux/perf_event.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

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

/* Pinned system-wide cycles and instructions events on every CPU, so the counters run; the descriptors
   stay open until the program exits, and close on exec. The probe below decides; tg-lbench info
   reports how many opened and the first error. */
static int tglb_perf_opened, tglb_perf_errno;
static void tglb_start_counters(void) {  /* C89 too: Dhrystone builds as gnu89 */
  long ncpu = sysconf(_SC_NPROCESSORS_ONLN), c;
  int k;
  for (c = 0; c < ncpu; c++)
    for (k = 0; k < 2; k++) {
      struct perf_event_attr a;
      long fd;
      memset(&a, 0, sizeof a);
      a.type = PERF_TYPE_HARDWARE;
      a.size = sizeof a;
      a.config = k ? PERF_COUNT_HW_INSTRUCTIONS : PERF_COUNT_HW_CPU_CYCLES;
      a.pinned = 1; /* no exclude_* bits: the fixed counters cannot filter by mode on this core */
      fd = syscall(SYS_perf_event_open, &a, -1, (int)c, -1, PERF_FLAG_FD_CLOEXEC);
      if (fd >= 0) tglb_perf_opened++;
      else if (!tglb_perf_errno) tglb_perf_errno = errno;
    }
}

/* Each hart's counters start at their own time (perf sets them when it starts the event there), so a
   count is valid only on one hart. */
static void tglb_pin(void) {
  unsigned long mask[16]; /* up to 1,024 harts */
  unsigned cpu = 0, w = 8 * sizeof mask[0];
  if (syscall(SYS_getcpu, &cpu, NULL, NULL) != 0 || cpu >= 16 * w) return;
  memset(mask, 0, sizeof mask);
  mask[cpu / w] = 1UL << (cpu % w);
  syscall(SYS_sched_setaffinity, 0, sizeof mask, mask);
}

/* Whether user mode reads running cycle and instret counters, probed once: a read with SIGILL caught,
   then the counters started and checked to advance. */
static sigjmp_buf tglb_jb;
static void tglb_on_sigill(int s) {
  (void)s;
  siglongjmp(tglb_jb, 1);
}
static int tglb_has_cycle(void) {
  static int known = -1;
  struct sigaction sa, old;
  if (known >= 0) return known;
  tglb_pin();
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
  if (known) {
    uint64_t c0, i0;
    volatile int i;
    tglb_start_counters();
    c0 = tglb_rdcycle();
    i0 = tglb_rdinstret();
    for (i = 0; i < 1000; i++) {
    }
    known = tglb_rdcycle() != c0 && tglb_rdinstret() != i0;
  }
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
