/* STREAM-style triad a[i] = b[i] + s * c[i] over arrays far larger than the L2. */
#include "memsuite.h"

#ifndef N_ELEMS
#define N_ELEMS (1u << 20)
#endif

int main(void) {
  double *a = (double *)ms_alloc(N_ELEMS * sizeof(double));
  double *b = (double *)ms_alloc(N_ELEMS * sizeof(double));
  double *c = (double *)ms_alloc(N_ELEMS * sizeof(double));
  for (uint32_t i = 0; i < N_ELEMS; i++) { b[i] = (double)i; c[i] = (double)(i & 255); }
  const double s = 3.0;
  tg_region_start();
  for (uint32_t i = 0; i < N_ELEMS; i++) a[i] = b[i] + s * c[i];
  tg_region_stop();
  double sum = 0;
  for (uint32_t i = 0; i < N_ELEMS; i += 4096) sum += a[i];
  printf("stream triad n=%u check=%ld\n", (unsigned)N_ELEMS, (long)sum);
  return 0;
}
