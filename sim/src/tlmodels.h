// TileLink responder models for the core's l1i, l1d and mmio ports, with protocol monitors, the
// DRAM latency model and the UART and CLINT devices (docs/spec/verification.md §2.4–§2.5).
#pragma once

#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "common.h"
#include "mem.h"
#include "tl.h"

namespace tg {

struct model_cfg_t {
  // Latency and traffic shaping (§2.4, §2.5)
  unsigned lat = 30;          // request fire -> first response beat, l1i/l1d
  unsigned lat_jitter = 0;    // + uniform 0..N cycles per request
  unsigned mmio_lat = 2;      // device accesses
  unsigned ack_lat = 2;       // ReleaseAck after the last Release beat
  unsigned bp = 0;            // percent of cycles a_ready / c_ready / e_ready drop
  unsigned d_gap = 0;         // percent chance of an idle cycle before a D beat
  unsigned grant_b = 0;       // percent of AcquireBlock NtoB granted toB instead of toT
  unsigned probe_rate = 0;    // permille per cycle: random probe to a held line
  // percent of Acquires the manager answers with a probe first (DR-149): to the Acquire's own line when
  // the agent holds it (an AcquireBlock upgrade; the Grant waits for the ProbeAck), else to a held line
  // of its set (the likely victim of the refill)
  unsigned probe_miss = 0;
  // percent of GrantAcks after which the manager probes the line just granted, the first moment TL-C
  // allows (toN or toB): an agent must still make progress, so it holds the probe until its store or
  // atomic has used the line (the two-core boot lottery's livelock, 2026-10-16)
  unsigned probe_grant = 0;
  // percent of voluntary Releases whose line the manager probes while the Release is in flight (the
  // probe crosses it, before the ReleaseAck): the agent no longer has the line and answers NtoN without
  // data. With it on, random probes and --probe-miss may also pick a line being released (DR-149: the
  // 4-miss L1D releases its victim from a buffer at allocation, before the Grant)
  unsigned probe_release = 0;
  // which ready response the L1D's D channel sends next: 0 the oldest (in time order), 1 any at random,
  // 2 the youngest, so Grants for different Acquires come in any order (DR-149); a message's beats stay
  // together, and a ReleaseAck may come between Grants
  unsigned grant_order = 0;
  unsigned set_stride = 4096; // the L1D's sets x 64-byte lines, for same-set probes and the counters
  unsigned d_stall_max = 10000;
  // Memory map (tg_map_pkg)
  uint64_t dram_base = 0x80000000ull, dram_size = 1024ull << 20;  // the PMA's memory region (DR-151)
  uint64_t rom_base = 0x1000, rom_size = 0x1000;
  uint64_t uart_base = 0x10000000ull, uart_size = 0x1000;
  uint64_t clint_base = 0x02000000ull, clint_size = 0x10000;
  uint64_t sig_addr = 0x0C000004ull;  // simple interrupt generator (same register as Sail's)
  // --dbg-win (a TG_DEBUG core; core-priv.md "Debug mode"): the debug window is memory the program's ELF fills, fetched
  // by the L1I and read and written by mmio (the core lets only a hart in debug mode reach it), and a halt-request
  // register beside the interrupt generator drives the core's debug_req_i (a bit per hart; 32-bit accesses)
  bool dbg_win = false;
  uint64_t dbg_base = 0x11000000ull, dbg_size = 0x10000;
  uint64_t dbg_req_addr = 0x0C000008ull;   // (+4 reads 0x0DB6 with --dbg-win: a test's check that it runs with it)
  std::vector<std::pair<uint64_t, uint64_t>> dev_regions;  // every PMA_DEVICE region
  std::vector<std::pair<uint64_t, uint64_t>> deny;         // --deny ranges: answered with denied
  // Harts of this core and interrupts
  unsigned num_threads = 1, core_id = 0;
  unsigned mtime_div = 20;
  unsigned irq_rand = 0;      // permille per cycle: start a random MEI/SEI pulse
  uint64_t seed = 1;
};

// Shared state: memory, time, errors, statistics.
struct model_ctx_t {
  model_cfg_t cfg;
  mem_t* mem = nullptr;
  uint64_t now = 0;  // the cycle whose handshakes are being resolved
  rng_t rng{1};
  bool failed = false;
  std::string error;
  std::string console;  // UART output so far (also printed live unless quiet)
  bool quiet = false;
  void fail(const std::string& m) {
    if (!failed) { failed = true; error = m; }
  }
  bool in_dram(uint64_t a, uint64_t len = 1) const {
    return a >= cfg.dram_base && a - cfg.dram_base + len <= cfg.dram_size;
  }
  bool in_rom(uint64_t a, uint64_t len = 1) const {
    return cfg.rom_size && a >= cfg.rom_base && a - cfg.rom_base + len <= cfg.rom_size;
  }
  bool denied(uint64_t a) const {
    for (auto& r : cfg.deny) if (a >= r.first && a < r.first + r.second) return true;
    return false;
  }
  unsigned latency(unsigned base) { return base + (cfg.lat_jitter ? (unsigned)rng.below(cfg.lat_jitter + 1) : 0); }
};

// Inputs from / outputs to the core for one TL-UL port (A, D) in one cycle.
struct ul_in_t {
  bool a_valid = false; tl_a_t a; bool d_ready = false;
};
struct ul_out_t {
  bool a_ready = false; bool d_valid = false; tl_d_t d;
};
// The same for the TL-C port (A, B, C, D, E).
struct c_in_t {
  bool a_valid = false; tl_a_t a;
  bool b_ready = false;
  bool c_valid = false; tl_c_t c;
  bool d_ready = false;
  bool e_valid = false; uint32_t e_sink = 0;
};
struct c_out_t {
  bool a_ready = false;
  bool b_valid = false; tl_b_t b;
  bool c_ready = false;
  bool d_valid = false; tl_d_t d;
  bool e_ready = false;
};

// A D-channel message waiting to be sent, and the sender that keeps beats contiguous.
struct d_msg_t {
  uint64_t ready_at = 0, seq = 0;
  tl_d_t hdr;
  unsigned nbeats = 1;
  std::vector<beat_t> beats;
  std::function<bool()> blocked;           // not yet sendable (a coherent Get waiting for a probe)
  std::function<void(d_msg_t&)> on_start;  // fills beats when the first beat goes out
  std::function<void()> on_done;           // after the last beat fired
};

class d_sender_t {
 public:
  void push(d_msg_t m) { m.seq = seq_++; q_.push_back(std::move(m)); }
  unsigned pick = 0;  // among the ready messages: 0 the oldest, 1 any at random, 2 the youngest
  // Resolves the handshake of the cycle that ended, then chooses the beat for the next cycle.
  void cycle(model_ctx_t& ctx, bool d_ready, const char* port, bool& valid_out, tl_d_t& d_out);
  bool idle() const { return q_.empty() && !valid_; }
  size_t pending() const { return q_.size() + (cur_ ? 1 : 0); }

 private:
  std::deque<d_msg_t> q_;
  std::unique_ptr<d_msg_t> cur_;
  unsigned beat_ = 0;
  bool valid_ = false;
  tl_d_t out_;
  uint64_t seq_ = 0, stall_ = 0;
};

// Checks that a channel's payload holds while valid && !ready (conventions §3, TileLink).
template <class T> struct stable_mon_t {
  bool pending = false; T last;
  void check(model_ctx_t& ctx, const char* what, bool valid, const T& p, bool ready) {
    if (pending) {
      if (!valid) ctx.fail(strfmt("%s: valid dropped while not ready", what));
      else if (!(p == last)) ctx.fail(strfmt("%s: payload changed while valid && !ready", what));
    }
    pending = valid && !ready;
    last = p;
  }
};

class l1d_model_t;

// l1i: Get only, from DRAM or ROM; coherent with the l1d agent's dirty lines (§2.4).
class l1i_model_t {
 public:
  l1i_model_t(model_ctx_t& ctx, l1d_model_t* l1d) : ctx_(ctx), l1d_(l1d) {}
  void cycle(const ul_in_t& in, ul_out_t& out);
  uint64_t requests = 0;

 private:
  model_ctx_t& ctx_;
  l1d_model_t* l1d_;
  d_sender_t d_;
  stable_mon_t<tl_a_t> a_mon_;
  bool a_ready_ = false;
  std::set<uint32_t> inflight_;
};

// UART (16550 subset) and CLINT devices behind the mmio port.
struct uart_t {
  uint8_t ier = 0, lcr = 0, mcr = 0, scr = 0, dll = 0, dlm = 0, fcr = 0;
  uint8_t read(model_ctx_t& ctx, unsigned off);
  void write(model_ctx_t& ctx, unsigned off, uint8_t v);
};

struct clint_t {
  std::vector<uint32_t> msip;
  std::vector<uint64_t> mtimecmp;
  uint64_t mtime = 0;
  unsigned div_count = 0;
  void init(unsigned harts) { msip.assign(harts, 0); mtimecmp.assign(harts, ~0ull); }
  void tick(unsigned div) { if (++div_count >= div) { div_count = 0; mtime++; } }
  uint64_t read(uint64_t off, unsigned size);
  void write(uint64_t off, unsigned size, uint64_t v);
};

// One read on the bus for each MMIO load that retires (DR-176; verification.md §2.4). A hart sends one MMIO read at a
// time, from its ROB head, and nothing flushes it once it is out, so the oldest read of a hart's source is the load's
// that retires next, and no other read of that source went out before it. While every read has had one source, the
// check covers one hart (whichever source) and stops once a second hart retires an MMIO load; once reads have come
// with several sources, hart h's source is h mod NUM_THREADS (interfaces.md §2.4: a distinct source per hart; from
// M7's step 5 the core sends thread ^ SOLO_TID, so a lone hart uses 0). The messages name the reads; "" means none.
class mmio_read_check_t {
 public:
  void read(uint32_t source, uint64_t cycle, uint64_t addr) {
    if (on) q_[source].emplace_back(cycle, addr);
  }
  std::string retire(uint32_t hart, uint64_t pc);
  std::string exit(uint32_t hart);   // the exiting hart's reads have all retired; another hart's may be out
  bool on = true;
  unsigned threads = 1;              // the core's harts (tg_dpi_config)

 private:
  long source_of(uint32_t hart) const;
  std::map<uint32_t, std::deque<std::pair<uint64_t, uint64_t>>> q_;   // by source: (cycle, address), oldest first
  std::set<uint32_t> harts_;                                            // harts that retired an MMIO load
};

// mmio: Get / PutFullData / PutPartialData of up to 8 bytes to devices (§2.4).
class mmio_model_t {
 public:
  explicit mmio_model_t(model_ctx_t& ctx) : ctx_(ctx) {}
  void cycle(const ul_in_t& in, ul_out_t& out);
  uart_t uart;
  clint_t clint;
  // Simple interrupt generator (verification.md §2.4): a 32-bit write with bit 31 set raises the
  // interrupt lines named by bits 30:0 (1 SSI, 9 SEI, 11 MEI), without bit 31 it lowers them. The
  // lines are levels, for every hart of the core. Sail models the same register, so ACT4's
  // external-interrupt tests use it.
  uint32_t sig_lines = 0;
  uint32_t dbg_req = 0;   // --dbg-win: the halt requests, a bit per hart
  uint64_t requests = 0;
  mmio_read_check_t reads;   // every read answered without error, for main.cpp's retirements

 private:
  uint64_t dev_read(uint64_t addr, unsigned size, bool& ok);
  bool dev_write(uint64_t addr, unsigned size, uint64_t v);
  model_ctx_t& ctx_;
  d_sender_t d_;
  stable_mon_t<tl_a_t> a_mon_;
  bool a_ready_ = false;
  std::set<uint32_t> inflight_;
};

// l1d: a TL-C manager for a single agent, with a coherence monitor (§2.4).
class l1d_model_t {
 public:
  explicit l1d_model_t(model_ctx_t& ctx) : ctx_(ctx) {}
  void cycle(const c_in_t& in, c_out_t& out);

  // The agent's permission on the line holding `addr`, as the manager knows it.
  perm_e perm(uint64_t addr) const;
  // For a coherent read of the line (l1i Get): true when memory is current. Otherwise starts a
  // probe to toB (once) and returns false; call again later.
  bool coherent_read_ready(uint64_t addr);
  // Queues a probe; it goes out when the TL-C rules allow (no Grant awaiting GrantAck).
  void probe(uint64_t addr, uint8_t cap, bool block = true);
  // Lines the agent holds with T (for end-of-run flushes).
  std::vector<uint64_t> held_lines() const;
  bool quiescent() const;

  uint64_t acquires = 0, releases = 0, probes_sent = 0, gets = 0, puts = 0;
  // DR-149 coverage (verification.md §2.4): Acquires by how many were in flight with them (1, 2, 3, 4+);
  // probes to a line with an Acquire in flight, or to another line of such a line's set; Releases, and
  // Acquires to a set, while an Acquire (to that set) was in flight.
  uint64_t acq_by_inflight[4] = {};
  uint64_t probes_on_acquire = 0, probes_same_set = 0, releases_during_acquire = 0, acquires_same_set = 0;
  uint64_t probes_on_grant = 0;
  // DR-149: Grants sent while an older Acquire's Grant was still to come, probes of a line whose Release
  // was in flight, A and C requests per source (core bits [5:0]; 8 and up counted together), and the
  // most sources in flight at once
  uint64_t grants_ooo = 0, probes_on_release = 0, src_req[9] = {};
  unsigned max_src_inflight = 0;
  unsigned max_inflight = 0;

 private:
  struct line_t {
    perm_e perm = PERM_N;
    bool acquire_inflight = false;  // Acquire accepted, GrantAck not yet received
    bool grant_unacked = false;     // Grant sent, GrantAck not yet received
    bool release_inflight = false;  // Release accepted, ReleaseAck not yet sent
    bool probe_inflight = false;    // Probe queued or sent, ProbeAck not yet received
    uint8_t probe_cap = CAP_TO_N;
  };
  bool same_set(uint64_t a, uint64_t b) const { return ((a ^ b) & (ctx_.cfg.set_stride / 64 - 1)) == 0; }
  void probe_for_miss(uint64_t idx, bool own_line_ok);
  std::set<uint64_t> acq_lines_;  // lines with an Acquire in flight
  uint64_t acq_order_ = 0;         // Acquires in arrival order, for the Grants' order
  std::set<uint64_t> grants_due_;  // the arrival numbers of Acquires whose Grant has not started
  void note_src(uint32_t src) {
    src_req[src < 8 ? src : 8]++;
    max_src_inflight = std::max(max_src_inflight, unsigned(inflight_src_.size()));
  }
  struct partial_t {  // a multi-beat A or C message being received
    bool active = false;
    unsigned beats = 0, got = 0;
    uint8_t opcode = 0, param = 0, size = 0;
    uint32_t source = 0;
    uint64_t address = 0;
    std::vector<beat_t> data;
    std::vector<uint16_t> mask;
    bool corrupt = false;
  };

  line_t& line(uint64_t addr) { return lines_[addr / LINE_BYTES]; }
  void accept_a(const tl_a_t& a);
  void accept_c(const tl_c_t& c);
  void finish_a(partial_t& p);
  void finish_c(partial_t& p);
  void accept_e(uint32_t sink);
  void send_grant(const partial_t& p, uint64_t order);
  void maybe_random_probe();

  model_ctx_t& ctx_;
  d_sender_t d_;
  stable_mon_t<tl_a_t> a_mon_;
  stable_mon_t<tl_c_t> c_mon_;
  stable_mon_t<uint32_t> e_mon_;
  bool a_ready_ = false, c_ready_ = false, e_ready_ = false;
  partial_t pa_, pc_;
  std::map<uint64_t, line_t> lines_;          // by line index
  std::set<uint32_t> inflight_src_;           // A requests and Releases awaiting D
  std::map<uint32_t, std::pair<uint64_t, bool>> sinks_;  // sink -> (line index, last beat sent)
  std::deque<tl_b_t> b_q_;                    // probes waiting to go out
  bool b_valid_ = false;
  tl_b_t b_out_;
  uint64_t b_stall_ = 0;
};

}  // namespace tg
