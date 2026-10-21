/* M7's issue-queue caps lifted while the sibling is parked in WFI (fpu-2's step 7, the coordinator's question of
   10-21): a task that wakes, does a burst of work and sleeps in WFI again, as an interrupt-driven kernel does. In
   tgsim, wfi_sleep sets how long each WFI sleeps (a timer's wake); the burst is about WORK x 7 instructions of loads
   and integer work. Without wfi_sleep a WFI is a no-op and the bursts run back to back. */
#include "memsuite.h"

#ifndef REPS
#define REPS 200
#endif
#ifndef WORK
#define WORK 64
#endif

static uint64_t buf[WORK];

int main(void) {
  for (int i = 0; i < WORK; i++) buf[i] = (uint64_t)i * 2654435761u + 1;
  uint64_t h = 0;
  tg_region_start();
  for (int r = 0; r < REPS; r++) {
    for (int i = 0; i < WORK; i++) h = (h ^ buf[i]) * 0x100000001b3ull + (h >> 7);
    __asm__ volatile("wfi" ::: "memory");
  }
  tg_region_stop();
  printf("wfiburst reps=%d check=%llu\n", REPS, (unsigned long long)(h & 0xffff));
  return 0;
}
