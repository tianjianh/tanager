/* CoreMark port for tgsim. The timed region is bracketed by tgsim's region markers; tgsim reports
   its cycles, from which CoreMark/MHz = iterations * 1e6 / cycles. CoreMark's own time printout is
   meaningless here (the functional simulator has no clock). */
#include "coremark.h"
#include "tgsim.h"

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

static CORE_TICKS read_ticks(void) {
  unsigned long v;
  __asm__ volatile(".option push\n.option arch, +zicsr\ncsrr %0, instret\n.option pop" : "=r"(v));
  return (CORE_TICKS)v;
}

void start_time(void) {
  tg_region_start();
  start_ticks = read_ticks();
}

void stop_time(void) {
  stop_ticks = read_ticks();
  tg_region_stop();
}

CORE_TICKS get_time(void) { return stop_ticks - start_ticks; }

secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)(ticks / 1000000u); }

void portable_init(core_portable *p, int *argc, char *argv[]) {
  (void)argc;
  (void)argv;
  p->portable_id = 1;
}

void portable_fini(core_portable *p) { p->portable_id = 0; }
