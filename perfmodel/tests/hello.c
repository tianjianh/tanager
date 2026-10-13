// tgsim sanity test: exercises integer, multiply/divide, FP, libc and the region markers. The printed
// values are compared against a native build of the same file (tests/run_sanity.sh).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef TG_NATIVE
static inline void tg_region_start(void) {}
static inline void tg_region_stop(void) {}
#else
#include "tgsim.h"
#endif

static int cmp_int(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }

int main(void) {
  printf("hello from tgsim\n");
  long long acc = 0;
  for (int i = 1; i <= 1000; i++) acc += (long long)i * i - (i / 3) + (i % 7);
  unsigned long long u = 0xfedcba9876543210ull;
  long long sdiv = -(long long)(u >> 9) / 77, srem = -(long long)(u >> 9) % 77;
  volatile double x = 1.0;
  for (int i = 0; i < 20; i++) x = x * 1.5 + 0.25;
  volatile float f = 3.0f;
  int v[64];
  for (int i = 0; i < 64; i++) v[i] = (i * 37) % 64;
  tg_region_start();
  for (int r = 0; r < 50; r++) {
    for (int i = 0; i < 64; i++) v[i] = (v[i] * 13 + r) % 101;
    qsort(v, 64, sizeof v[0], cmp_int);
  }
  tg_region_stop();
  int sum = 0;
  for (int i = 0; i < 64; i++) sum += v[i] * (i + 1);
  char buf[32];
  strcpy(buf, "tgsim");
  printf("acc=%lld udiv=%llx sdiv=%lld srem=%lld\n", acc, (u >> 7) / 13, sdiv, srem);
  printf("x=%lld f=%d sum=%d str=%d\n", (long long)(x * 1000), (int)(f / 7.0f * 1e6f), sum,
         (int)strlen(buf) + strcmp(buf, "tgsim"));
  return 0;
}
