// State shared by the DPI functions (tb_dpi.cpp) and the tg_vsim main loop (main.cpp).
#pragma once

#include <string>
#include <vector>

#include "sig.h"
#include "tlmodels.h"
#include "trace.h"
#include "trace_sink.h"

namespace tg {

// Configuration of the compiled RTL, reported by tg_tb_top at time 0 (tg_dpi_config).
struct hw_cfg_t {
  bool known = false;
  std::string cfg_name;
  unsigned commit_width = 0, num_threads = 1, core_id = 0, hart_w = 1, wb_tag_w = 1;
  unsigned trace_wb_ports = 0, pa_w = 34, l1i_mshrs = 0, l1d_mshrs = 0;
  unsigned llt_entries = 0, trace_stall_headroom = 0;
  unsigned pmp_entries = 0;  // DR-167: Spike's PMP regions in lockstep
  bool hart1_on = false;     // M7's hart 1 (tg_core_pkg::HART1_ON): the core has mtgsmt (0x7C0)
};

struct tb_t {
  model_ctx_t ctx;
  l1d_model_t l1d{ctx};
  l1i_model_t l1i{ctx, &l1d};
  mmio_model_t mmio{ctx};
  hw_cfg_t hw;
  uint64_t boot_addr = 0x80000000ull;

  // Trace records and writebacks of the current cycle, in arrival order.
  std::vector<tr_rec_t> recs;
  std::vector<tr_wb_t> wbs;
  trace_sink_t sink;  // drives trace_stall_i and checks the core's side of it
  sig_t sig;          // --sig and --log-bus (verification.md §4.5)

  // Interrupt sources: random external-interrupt pulses end at these cycles (per hart index).
  std::vector<uint64_t> mei_until, sei_until;
  uint32_t merr_seen = 0;   // OR of every merr_o pulse
  uint64_t merr_pulses = 0;
};

tb_t& tb();

}  // namespace tg
