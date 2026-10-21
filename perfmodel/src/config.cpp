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
    // one, each row held until two cycles after its select; and, until DR-169's STA_BASE below, a store's address
    // issuing only with its data, as rename made the store's IQ-STA row wait on the data register.
    ubtb = 64; fe_m2 = 1; ubtb_ways = 2; m2_ctr = 512; m2_wp_train = 2; ras = 0; fdip = 0;
    pf_i_nextline = 1;  // revision 8: the I$ next-line prefetch (IPF_ON), with its second refill engine (l1i_mshr 2)
    // From the front-end profile of core-2's TAGE build (area_recovery.md §6.7): a 32-bit instruction straddling two
    // blocks is decoded with the second, and the micro-BTB never predicts or trains it; training writes the way that
    // predicted the instruction, else a pseudo-random one (tg_exec's upd_way).
    m2_strad = 1; m2_ub_way = 1;
    // Revision 9 (area_recovery.md §6.16, §6.17): TAGE-lite (main's M6 set's m2_btage) allocates an invalid way
    // before a not-useful one, as tg_tage does since fpu-2's c1c21281.
    btage_alloc = 1;
    // From the rename-stall profile (area_recovery.md §6.8): rename picks an ALU op's queue a cycle before dispatch
    // and keeps it. DR-169's levers (§6.9): it reads flags that count the group in the dispatch stage (STEER_LA), and
    // a store's address issues on its base alone (STA_BASE).
    iq_steer_rn = 2;
    iq_slot_bank = 1; iq_hold = 3; sta_split = 1;
    // From the levers tree's load profile (§6.9): a load that finds its store's address without the data cancels the
    // speculative-wakeup shadow (the STQ verdict), and a committed store writes the D$ a cycle after its commit at the
    // earliest (the SQ's committed pointer is registered).
    fwd_wait_cancel = 1; drain_delay = 1;
    commit_redirect = 2; l1_fill_extra = 13; ld_fwd_lat = 5; ld_fwd_wait = 8; lat_mul = 5;
    fusion = 0; sfb = 0; fold = 0; mdp = 0; br_first = 0;
    rob = 48; iq_a0 = 10; iq_a1 = 10; iq_ld = 6; iq_fp = 10; iq_sta = 4; wake_tags = 16;
    lq = 16; sq = 12; lqcb = 0; llt = 16; ckpt = 0; early_retire = 0;
    // Speculative load wakeup (on in main since DR-154's flip, ce47115): an integer load's dependants issue three
    // cycles after it, with no hit predictor; a load that does not complete in M2 cancels the integer queues'
    // issues of the next three cycles; FP consumers wait for the confirmed result.
    spec_wakeup = 1; hit_pred = 0; shadow = 3; spec_int_only = 1;
    // From fpu-2's RTL profile of the cancels (§6.6): a forward that completes at M2 wakes as a hit does; a load
    // reading the D$ as a store to its 16-byte block drains (acked in its AG cycle or the one before) retries.
    spec_fwd = 1; dc_row_clash = 1;
    div_base = 4; div_bits_per_cycle = 1;
    lat_fdiv_s = 18; lat_fdiv_d = 23; lat_fsqrt_s = 20; lat_fsqrt_d = 26; fdiv_ii = 4;
    l1i_mshr = 2; l1d_mshr = 4; pf_stride = 0; pf_stream = 0;
    rfo_pf = 1; rfo_pf_reserve = 1;  // revision 8: STORE_PF (DR-171), an entry only while another stays free
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
