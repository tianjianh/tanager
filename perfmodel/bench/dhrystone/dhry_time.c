/* Dhrystone (-DTIME) times its main loop with two time() calls: they open and close tgsim's region. */
#include <time.h>

#include "tgsim.h"

static int time_calls;

time_t time(time_t *t) {
  *TG_MARKER = time_calls == 0 ? 1u : 2u;
  time_calls++;
  if (t) *t = time_calls;
  return time_calls;
}
