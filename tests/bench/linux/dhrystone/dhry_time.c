/* Dhrystone as a Linux user program (DR-141; docs/spec/verification.md §4.6).
     dhrystone [RUNS] [RUN]
   Dhrystone (-DTIME) times its main loop with two time() calls; here they take the TGLB counters,
   and the run prints one TGLB line for the loop. RUNS (2,000,000) reaches Dhrystone's scanf through
   stdin; its own printout goes to /dev/null, since its rates rest on time()'s whole seconds. RUN
   labels the line. The bare-metal port is tests/bench/dhrystone. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "tglb.h"
#ifndef TGLB_NAME
#define TGLB_NAME "dhrystone"
#endif
#ifndef TGLB_MARCH
#define TGLB_MARCH "default"
#endif

static int time_calls;
static struct tglb_mark m_start, m_stop;

time_t time(time_t *t) {
  if (time_calls == 0) tglb_take(&m_start);
  else tglb_take(&m_stop);
  time_calls++;
  time_t v = (time_t)(tglb_ns() / 1000000000u);
  if (t) *t = v;
  return v;
}

/* Dhrystone's K&R main() falls off its end, which under -std=gnu89 returns an undefined value.
   It is built as dhry_main (-Dmain=dhry_main on dhry_1.c only) and called from here. */
extern int dhry_main();

int main(int argc, char **argv) {
  long runs = argc > 1 ? atol(argv[1]) : 2000000;
  int run = argc > 2 ? atoi(argv[2]) : 1;
  int in[2], out = dup(1), null = open("/dev/null", O_WRONLY);
  if (pipe(in) < 0 || out < 0 || null < 0) return 2;
  dprintf(in[1], "%ld\n", runs);
  close(in[1]);
  dup2(in[0], 0);
  fflush(stdout);
  dup2(null, 1);
  dhry_main();
  fflush(stdout);
  dup2(out, 1);
  if (time_calls != 2) {
    fprintf(stderr, "dhrystone: the main loop was not timed\n");
    return 1;
  }
  tglb_report(TGLB_NAME, run, &m_start, &m_stop, (uint64_t)runs, " march=" TGLB_MARCH);
  return 0;
}
