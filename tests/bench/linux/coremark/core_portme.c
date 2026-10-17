/* CoreMark as a Linux user program (DR-141; docs/spec/verification.md §4.6).
     coremark-a|coremark-b [ITERATIONS] [RUN]
   ITERATIONS 0 (the default) lets CoreMark scale the run to at least 10 s, its own condition for a
   valid result, at any clock; the TGLB line reports the count it ran. RUN labels the line, and the
   build names the program (TGLB_NAME: coremark-a or coremark-b, plan §10.2's flag sets). The seeds
   are CoreMark's performance-run seeds. */
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#include "coremark.h"
#include "tglb.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = 0;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

static struct tglb_mark m_start, m_stop;
static int run_label = 1;

void start_time(void) { tglb_take(&m_start); }
void stop_time(void) { tglb_take(&m_stop); }
CORE_TICKS get_time(void) { return m_stop.ns - m_start.ns; }
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)ticks / 1e9; }

void portable_init(core_portable *p, int *argc, char *argv[]) {
  if (*argc > 1) seed4_volatile = (ee_s32)strtol(argv[1], NULL, 0);
  if (*argc > 2) run_label = (int)strtol(argv[2], NULL, 0);
  p->portable_id = 1;
}

#ifndef TGLB_NAME
#define TGLB_NAME "coremark"
#endif
#ifndef TGLB_MARCH
#define TGLB_MARCH "default"
#endif

void portable_fini(core_portable *p) {
  /* p is results[0].port: the results hold the iteration count CoreMark settled on. */
  const core_results *res = (const core_results *)((const char *)p - offsetof(core_results, port));
  char extra[96];
  snprintf(extra, sizeof extra, " iterations=%u crc=0x%04x march=%s", (unsigned)res->iterations, (unsigned)res->crc,
           TGLB_MARCH);
  tglb_report(TGLB_NAME, run_label, &m_start, &m_stop, (uint64_t)res->iterations, extra);
  p->portable_id = 0;
}
