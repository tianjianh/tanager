/* Dense double-precision matrix multiply, L1-resident, 4x4 register-blocked: two FMAs for every load, the
   best case for FP issue width. Used for FPU decisions only; not part of the DSE suite. */
#include <stdint.h>
#include <stdio.h>

#include "tgsim.h"

#ifndef N
#define N 32
#endif
#ifndef REPS
#define REPS 30
#endif

static double A[N][N], B[N][N], C[N][N];

int main(void) {
  for (int i = 0; i < N; i++)
    for (int j = 0; j < N; j++) {
      A[i][j] = (double)((i + 2 * j) % 7 - 3);
      B[i][j] = (double)((3 * i + j) % 5 - 2);
      C[i][j] = 0.0;
    }
  tg_region_start();
  for (int r = 0; r < REPS; r++)
    for (int i = 0; i < N; i += 4)
      for (int j = 0; j < N; j += 4) {
        double c00 = C[i][j], c01 = C[i][j + 1], c02 = C[i][j + 2], c03 = C[i][j + 3];
        double c10 = C[i + 1][j], c11 = C[i + 1][j + 1], c12 = C[i + 1][j + 2], c13 = C[i + 1][j + 3];
        double c20 = C[i + 2][j], c21 = C[i + 2][j + 1], c22 = C[i + 2][j + 2], c23 = C[i + 2][j + 3];
        double c30 = C[i + 3][j], c31 = C[i + 3][j + 1], c32 = C[i + 3][j + 2], c33 = C[i + 3][j + 3];
        for (int k = 0; k < N; k++) {
          const double a0 = A[i][k], a1 = A[i + 1][k], a2 = A[i + 2][k], a3 = A[i + 3][k];
          const double b0 = B[k][j], b1 = B[k][j + 1], b2 = B[k][j + 2], b3 = B[k][j + 3];
          c00 += a0 * b0; c01 += a0 * b1; c02 += a0 * b2; c03 += a0 * b3;
          c10 += a1 * b0; c11 += a1 * b1; c12 += a1 * b2; c13 += a1 * b3;
          c20 += a2 * b0; c21 += a2 * b1; c22 += a2 * b2; c23 += a2 * b3;
          c30 += a3 * b0; c31 += a3 * b1; c32 += a3 * b2; c33 += a3 * b3;
        }
        C[i][j] = c00; C[i][j + 1] = c01; C[i][j + 2] = c02; C[i][j + 3] = c03;
        C[i + 1][j] = c10; C[i + 1][j + 1] = c11; C[i + 1][j + 2] = c12; C[i + 1][j + 3] = c13;
        C[i + 2][j] = c20; C[i + 2][j + 1] = c21; C[i + 2][j + 2] = c22; C[i + 2][j + 3] = c23;
        C[i + 3][j] = c30; C[i + 3][j + 1] = c31; C[i + 3][j + 2] = c32; C[i + 3][j + 3] = c33;
      }
  tg_region_stop();
  double sum = 0.0;
  for (int i = 0; i < N; i++)
    for (int j = 0; j < N; j++) sum += C[i][j] * (double)(i + j + 1);
  printf("dgemm n=%d reps=%d checksum=%.1f\n", N, REPS, sum);
  return 0;
}
