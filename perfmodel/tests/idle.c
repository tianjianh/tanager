// tgsim SMT test: a sibling thread that barely loads the core. Each iteration is one uncached MMIO load, which
// executes alone at the ROB head, plus the loop counter and branch: about 3 instructions per 13 cycles, with no
// load-queue entry, long-latency tag, MSHR or cache line, and nothing left waiting in the issue queues.
// scripts/smt.py --validate pairs workloads with it (built by tests/build_idle.sh).
#include "tgsim.h"

int main(void) {
  tg_region_start();
  for (int i = 0; i < 4000; i++) (void)*TG_GETC;
  tg_region_stop();
  return 0;
}
