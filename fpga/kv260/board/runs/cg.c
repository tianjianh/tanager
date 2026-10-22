/* cg.c: the cost of clock_gettime (the vDSO, reading the time CSR) and of a bare rdtime, in ns per call, timed by
 * CLOCK_MONOTONIC over N calls (the board track, s21's memory gap, 10-20). */
#include <stdio.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }
static inline unsigned long rdtime(void) { unsigned long c; __asm__ volatile("rdtime %0" : "=r"(c)); return c; }
int main(void) {
  struct timespec ts; volatile unsigned long s = 0; int i, n = 200000; double a, b;
  a = now(); for (i = 0; i < n; i++) clock_gettime(CLOCK_MONOTONIC, &ts); b = now();
  printf("clock_gettime: %.1f ns per call\n", (b - a) / n);
  a = now(); for (i = 0; i < n; i++) s += rdtime(); b = now();
  printf("rdtime: %.1f ns per read\n", (b - a) / n);
  return 0;
}
