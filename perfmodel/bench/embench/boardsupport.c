/* Embench-IoT board support for tgsim: the triggers bracket the timed region with tgsim's markers. */
#include <support.h>

#include "tgsim.h"

void initialise_board(void) {}

void __attribute__((noinline)) __attribute__((externally_visible)) start_trigger(void) { tg_region_start(); }

void __attribute__((noinline)) __attribute__((externally_visible)) stop_trigger(void) { tg_region_stop(); }
