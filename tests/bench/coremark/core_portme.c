/* CoreMark port for the Tanager simulation platform (verification.md §4.2). The timed region is
   bracketed by tg_marker stores; ticks are retired instructions (deterministic, so RTL and Spike
   print the same text). One tick counts as one second for CoreMark's own report, which keeps its
   10-second check satisfied; CoreMark/MHz comes from the cycles tg_vsim measures. These are not
   EEMBC-valid runs (plan §10.2): they check correctness and give model-correlation points. */
#include "coremark.h"
#include "tg_sim.h"

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
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

static CORE_TICKS start_ticks, stop_ticks;

void start_time(void) {
  tg_region_start();
  start_ticks = (CORE_TICKS)tg_rdinstret();
}

void stop_time(void) {
  stop_ticks = (CORE_TICKS)tg_rdinstret();
  tg_region_stop();
}

CORE_TICKS get_time(void) { return stop_ticks - start_ticks; }

secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)ticks; }

void portable_init(core_portable *p, int *argc, char *argv[]) {
  (void)argc;
  (void)argv;
  p->portable_id = 1;
}

void portable_fini(core_portable *p) { p->portable_id = 0; }
