// tgsim: parameter handling and presets.
#include "config.h"

#include <cstdlib>
#include <sstream>

namespace tg {

bool Config::set(const std::string& name, const std::string& value) {
  char* end = nullptr;
  const long long v = std::strtoll(value.c_str(), &end, 0);
  if (end == value.c_str() || *end != '\0') return false;
#define TG_SET(n, d, s) if (name == #n) { n = v; return true; }
  TG_PARAMS(TG_SET)
#undef TG_SET
  return false;
}

// Presets. "tanager_v1" is the plan's v1 baseline (all defaults). The NaxRiscv presets follow its
// documentation (research_notes/.../naxriscv_family.md and the NaxRiscv RTD pages): 64-bit fetch, a
// 512-entry direct-mapped BTB per fetch word in LUTRAM (zero-bubble taken branches) with GShare, returns
// predicted from the BTB at fetch and corrected by the RAS at decode, one unified 32-slot IQ filled by
// rows, 3 issue ports with one shared LSU/MUL/DIV pipe, recovery at commit, hit prediction with a full
// flush on a wrong guess, same-size forwarding only, 16 KB L1s with 2 refill slots, no prefetcher.
// Calibrated against NaxRiscv's published RV32 IPCs (scripts/calib.py, results/calibration.json):
// Dhrystone +0.2%, CoreMark +8.9%, Embench -5.7%.
bool Config::apply_preset(const std::string& name) {
  *this = Config{};
  preset = name;
  if (name == "tanager_v1") return true;
  if (name == "v1_freeze") {
    // The approved M1 freeze (docs/perf/feature_ledger.md, 2026-10-13; "final C" in results/freeze_rv64gc.json):
    // the greedy acceptance-rule result plus exceptions E1-E5 and the Goldschmidt divide/sqrt unit.
    ubtb = 64; tage_log = 12;
    fusion = 0; sfb = 0; fold = 0; mdp = 0; br_first = 0;
    l1i_mshr = 4;
    rob = 48; iq_a0 = 10; iq_a1 = 10; iq_ld = 6; iq_fp = 10; iq_sta = 4;
    lq = 16; sq = 12; lqcb = 8; llt = 16; l1d_mshr = 16; ckpt = 4;
    l2_mshr = 48; pf_stream_dist = 16; pf_stream_deg = 4;
    lat_fdiv_s = 18; lat_fdiv_d = 23; lat_fsqrt_s = 20; lat_fsqrt_d = 26; fdiv_ii = 4;
    return true;
  }
  if (name == "rtl_m2") {
    // The core as built (core-pipeline.md §1, the plan's M2 row), with the v1 freeze's sizes that the RTL's `st`
    // build uses (tg_cfg_st.sv) and DR-140's default profile, on tg_vsim's memory: no L2 and a flat latency
    // (`native` = 30 cycles; --set dram_lat=120 for the other point).
    // Calibrated against tg_vsim on the same ELFs (scripts/rtlcal.py, area_recovery.md §6.3): the flush acts the
    // cycle after commit (commit_redirect 2); the wrong path past a loop's exit trains its branch twice more; an
    // L1 refill costs 13 cycles beyond the memory's latency (request, beats, install, replay); a forwarded load
    // completes at M2 like a hit (5) and one waiting for the store's data replays (8); MUL-to-use is 5 (the RTL
    // wakes a MUL's dependants through a tag delay line, with no MUL bypass).
    // Since the first M6 stack's check (area_recovery.md §6.4), from an RTL profile: four L1D misses in flight
    // (main's default since DR-156); the issue queues' rows in banks by dispatch slot, a decode group dispatching as
    // one, each row held until two cycles after its select; and a store's address issuing only with its data, as
    // rename makes the store's IQ-STA row wait on the data register (younger loads to its address then replay).
    ubtb = 64; fe_m2 = 1; ubtb_ways = 2; m2_ctr = 512; m2_wp_train = 2; ras = 0; fdip = 0; pf_i_nextline = 0;
    iq_slot_bank = 1; iq_hold = 3; sta_split = 0;
    commit_redirect = 2; l1_fill_extra = 13; ld_fwd_lat = 5; ld_fwd_wait = 8; lat_mul = 5;
    fusion = 0; sfb = 0; fold = 0; mdp = 0; br_first = 0;
    rob = 48; iq_a0 = 10; iq_a1 = 10; iq_ld = 6; iq_fp = 10; iq_sta = 4; wake_tags = 16;
    lq = 16; sq = 12; lqcb = 0; llt = 16; ckpt = 0; early_retire = 0;
    spec_wakeup = 0; hit_pred = 0; shadow = 0;
    div_base = 4; div_bits_per_cycle = 1;
    lat_fdiv_s = 18; lat_fdiv_d = 23; lat_fsqrt_s = 20; lat_fsqrt_d = 26; fdiv_ii = 4;
    l1i_mshr = 1; l1d_mshr = 4; pf_stride = 0; pf_stream = 0; rfo_pf = 0;
    abl_st_done = 1;
    l2_kb = 0; dram_lat = 30; dram_line_cyc = 4;
    return true;
  }
  if (name == "nax" || name == "nax_cal") {
    fetch_bytes = 8; fetchq = 8; if_stages = 3; decode_width = 2; dec_to_disp = 2;
    ubtb = 0; btb_block = 1; btb_sets = 512; btb_ways = 1; btb_slots = 1;
    taken_bubble = 0; predecode_bubble = 3;
    dirpred = 1; gshare_log = 14; gshare_hist = 14; ras = 32; ras_at_decode = 1;
    fdip = 0; pf_i_nextline = 0; fusion = 0; sfb = 0; fold = 0;
    rob = 64; commit_width = 2;
    iq_unified = 1; iq_size = 32; iq_rows = 1;
    prf_banked = 0; prf_int = 64; prf_fp = 64;
    ckpt = 0; llt = 0; br_first = 0;
    spec_wakeup = 1; hit_pred = 1; hitmiss_flush = 1; shadow = 0;
    lat_mul = 3; div_base = 2; div_bits_per_cycle = 1; lat_fma = 7;
    lq = 16; lqcb = 0; sq = 16; early_retire = 0; mdp = 1; fwd_strict = 1; sta_split = 0; rfo_pf = 0;
    l1i_kb = 16; l1i_ways = 4; l1i_mshr = 1; l1d_kb = 16; l1d_ways = 4; l1d_mshr = 2;
    pf_stride = 0;
    if (name == "nax_cal") {  // calibration against NaxRiscv's published numbers: plain memory, no L2
      l2_kb = 0; pf_stream = 0; dram_lat = 30;
    }
    return true;
  }
  return false;
}

std::string Config::to_json() const {
  std::ostringstream o;
  o << "{\"preset\":\"" << preset << "\"";
#define TG_JSON(n, d, s) o << ",\"" #n "\":" << n;
  TG_PARAMS(TG_JSON)
#undef TG_JSON
  o << "}";
  return o.str();
}

std::string Config::help() {
  std::ostringstream o;
#define TG_HELP(n, d, s) o << "  " #n " (default " << d << "): " << s << "\n";
  TG_PARAMS(TG_HELP)
#undef TG_HELP
  return o.str();
}

}  // namespace tg
