/* Dhrystone (-DTIME) times its main loop with two time() calls; here they store tg_marker, so
   tg_vsim measures the loop's cycles. time() returns a call count, so the output is the same in
   RTL and in Spike (verification.md §4.2). */
#include <time.h>

#include "tg_sim.h"

static int time_calls;

time_t time(time_t *t) {
  if (time_calls == 0) tg_region_start();
  else tg_region_stop();
  time_calls++;
  if (t) *t = time_calls;
  return time_calls;
}

/* Dhrystone's K&R main() falls off its end, which under -std=gnu89 returns an undefined value.
   It is built as dhry_main (-Dmain=dhry_main on dhry_1.c only) and called from here. */
extern int dhry_main();

int main(void) {
  dhry_main();
  return 0;
}
