/* Sparse matrix-vector product (CSR) with random column indices: indirect gathers across a vector far
   larger than the L2. */
#include "memsuite.h"

#ifndef ROWS
#define ROWS 8192
#endif
#ifndef NNZ_PER_ROW
#define NNZ_PER_ROW 16
#endif
#ifndef COLS_LOG
#define COLS_LOG 21  /* 2M doubles = 16 MiB */
#endif

int main(void) {
  const uint32_t cols = 1u << COLS_LOG, nnz = ROWS * NNZ_PER_ROW;
  double *x = (double *)ms_alloc((size_t)cols * sizeof(double));
  double *val = (double *)ms_alloc((size_t)nnz * sizeof(double));
  uint32_t *col = (uint32_t *)ms_alloc((size_t)nnz * sizeof(uint32_t));
  uint32_t *rowp = (uint32_t *)ms_alloc((ROWS + 1) * sizeof(uint32_t));
  double *y = (double *)ms_alloc(ROWS * sizeof(double));
  for (uint32_t i = 0; i < cols; i += 8) x[i] = (double)(i & 1023);
  for (uint32_t r = 0; r <= ROWS; r++) rowp[r] = r * NNZ_PER_ROW;
  for (uint32_t k = 0; k < nnz; k++) { col[k] = (uint32_t)(ms_rand() & (cols - 1)); val[k] = (double)(k & 7); }
  tg_region_start();
  for (uint32_t r = 0; r < ROWS; r++) {
    double s = 0;
    for (uint32_t k = rowp[r]; k < rowp[r + 1]; k++) s += val[k] * x[col[k]];
    y[r] = s;
  }
  tg_region_stop();
#if REPEAT
  for (;;) {  /* the region again (memsuite.h) */
    for (uint32_t r = 0; r < ROWS; r++) {
      double s = 0;
      for (uint32_t k = rowp[r]; k < rowp[r + 1]; k++) s += val[k] * x[col[k]];
      y[r] = s;
    }
    MS_SINK(y);
  }
#endif
  double sum = 0;
  for (uint32_t r = 0; r < ROWS; r++) sum += y[r];
  printf("spmv rows=%d check=%ld\n", ROWS, (long)sum);
  return 0;
}
