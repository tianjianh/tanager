#include "tlmodels.h"

#include <algorithm>
#include <cstring>

namespace tg {

// ---------------------------------------------------------------------------------------------
// Helpers

static beat_t read_beat(const mem_t& mem, uint64_t addr) {
  beat_t b;
  mem.read(addr & ~uint64_t(BEAT_BYTES - 1), BEAT_BYTES, b.d);
  return b;
}

// The byte-lane mask TileLink requires for an access of `size` (log2 bytes) at `addr` on a
// 16-byte beat.
static uint16_t lane_mask(uint64_t addr, unsigned size) {
  if (size >= 4) return 0xffff;
  unsigned n = 1u << size, lane = addr & (BEAT_BYTES - 1);
  return uint16_t(((1u << n) - 1) << lane);
}

static uint64_t beat_bytes(const beat_t& b, unsigned lane, unsigned n) {
  uint8_t tmp[BEAT_BYTES];
  memcpy(tmp, b.d, BEAT_BYTES);
  uint64_t v = 0;
  memcpy(&v, tmp + lane, n);
  return v;
}

static beat_t beat_with(uint64_t v, unsigned lane, unsigned n) {
  beat_t b;
  uint8_t tmp[BEAT_BYTES] = {};
  memcpy(tmp + lane, &v, n);
  memcpy(b.d, tmp, BEAT_BYTES);
  return b;
}

// Checks shared by every A channel: alignment, size range, mask, source range.
static bool check_a_common(model_ctx_t& ctx, const char* port, const tl_a_t& a, unsigned max_size) {
  if (a.size > max_size) {
    ctx.fail(strfmt("%s A: %s size %u exceeds %u", port, a_op_name(a.opcode), a.size, max_size));
    return false;
  }
  if (a.address & ((1ull << a.size) - 1)) {
    ctx.fail(strfmt("%s A: %s address 0x%llx not aligned to size %u", port, a_op_name(a.opcode),
                    (unsigned long long)a.address, a.size));
    return false;
  }
  if (a.source >> 6) {
    ctx.fail(strfmt("%s A: source 0x%x uses bits the interconnect owns ([9:6] must be 0)", port, a.source));
    return false;
  }
  bool needs_full_mask = a.opcode != A_PUT_PARTIAL;
  uint16_t lm = lane_mask(a.address, a.size);
  if (needs_full_mask && a.opcode != A_ACQUIRE_BLOCK && a.opcode != A_ACQUIRE_PERM && a.mask != lm) {
    ctx.fail(strfmt("%s A: %s mask 0x%04x, expected 0x%04x for address 0x%llx size %u", port,
                    a_op_name(a.opcode), a.mask, lm, (unsigned long long)a.address, a.size));
    return false;
  }
  if (!needs_full_mask && (a.mask & ~lm)) {
    ctx.fail(strfmt("%s A: PutPartialData mask 0x%04x outside the access (0x%04x)", port, a.mask, lm));
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------------------------
// D-channel sender

void d_sender_t::cycle(model_ctx_t& ctx, bool d_ready, const char* port, bool& valid_out, tl_d_t& d_out) {
  if (valid_) {
    if (d_ready) {
      stall_ = 0;
      valid_ = false;
      if (++beat_ == cur_->nbeats) {
        auto done = std::move(cur_->on_done);
        cur_.reset();
        beat_ = 0;
        if (done) done();
      }
    } else if (++stall_ > ctx.cfg.d_stall_max) {
      ctx.fail(strfmt("%s: response not accepted for %u cycles (d_ready low)", port, ctx.cfg.d_stall_max));
    }
  }
  if (!valid_) {
    uint64_t next = ctx.now + 1;
    if (!cur_) {
      auto best = q_.end();
      for (auto it = q_.begin(); it != q_.end(); ++it) {
        if (it->ready_at > next) continue;
        if (best != q_.end() && (it->ready_at > best->ready_at ||
                                 (it->ready_at == best->ready_at && it->seq > best->seq)))
          continue;
        if (it->blocked && it->blocked()) continue;
        best = it;
      }
      if (best != q_.end()) {
        cur_ = std::make_unique<d_msg_t>(std::move(*best));
        q_.erase(best);
        beat_ = 0;
        if (cur_->on_start) cur_->on_start(*cur_);
      }
    }
    if (cur_ && !(ctx.cfg.d_gap && ctx.rng.percent(ctx.cfg.d_gap))) {
      valid_ = true;
      out_ = cur_->hdr;
      out_.data = beat_ < cur_->beats.size() ? cur_->beats[beat_] : beat_t{};
    }
  }
  valid_out = valid_;
  d_out = out_;
}

// ---------------------------------------------------------------------------------------------
// l1i

void l1i_model_t::cycle(const ul_in_t& in, ul_out_t& out) {
  a_mon_.check(ctx_, "l1i A", in.a_valid, in.a, a_ready_);
  if (in.a_valid && a_ready_) {
    const tl_a_t& a = in.a;
    requests++;
    if (a.opcode != A_GET) {
      ctx_.fail(strfmt("l1i A: %s not allowed (Get only)", a_op_name(a.opcode)));
    } else if (check_a_common(ctx_, "l1i", a, 6)) {
      if (!inflight_.insert(a.source).second)
        ctx_.fail(strfmt("l1i A: source %u already in flight", a.source));
      d_msg_t m;
      m.ready_at = ctx_.now + ctx_.latency(ctx_.cfg.lat);
      bool ok = (ctx_.in_dram(a.address, 1ull << a.size) || ctx_.in_rom(a.address, 1ull << a.size)) &&
                !ctx_.denied(a.address);
      m.hdr.opcode = D_ACCESS_ACK_DATA;
      m.hdr.size = a.size;
      m.hdr.source = a.source;
      m.hdr.denied = !ok;
      m.hdr.corrupt = !ok;
      m.nbeats = beats_of(a.size);
      uint64_t addr = a.address;
      if (ok && ctx_.in_dram(addr)) m.blocked = [this, addr] { return !l1d_->coherent_read_ready(addr); };
      m.on_start = [this, addr, ok](d_msg_t& msg) {
        msg.beats.resize(msg.nbeats);
        for (unsigned i = 0; i < msg.nbeats; i++)
          msg.beats[i] = ok ? read_beat(*ctx_.mem, addr + i * BEAT_BYTES) : beat_t{};
      };
      uint32_t src = a.source;
      m.on_done = [this, src] { inflight_.erase(src); };
      d_.push(std::move(m));
    }
  }
  d_.cycle(ctx_, in.d_ready, "l1i D", out.d_valid, out.d);
  a_ready_ = !ctx_.rng.percent(ctx_.cfg.bp);
  out.a_ready = a_ready_;
}

// ---------------------------------------------------------------------------------------------
// Devices

uint8_t uart_t::read(model_ctx_t&, unsigned off) {
  bool dlab = lcr & 0x80;
  switch (off & 7) {
    case 0: return dlab ? dll : 0;                  // RBR: no input
    case 1: return dlab ? dlm : ier;
    case 2: return (fcr & 1) ? 0xc1 : 0x01;         // IIR: no interrupt pending
    case 3: return lcr;
    case 4: return mcr;
    case 5: return 0x60;                            // LSR: THR empty, transmitter empty
    case 6: return 0;                               // MSR
    default: return scr;
  }
}

void uart_t::write(model_ctx_t& ctx, unsigned off, uint8_t v) {
  bool dlab = lcr & 0x80;
  switch (off & 7) {
    case 0:
      if (dlab) { dll = v; break; }
      ctx.console.push_back(char(v));
      if (!ctx.quiet) {
        fputc(v, stdout);
        if (v == '\n') fflush(stdout);
      }
      break;
    case 1: if (dlab) dlm = v; else ier = v; break;
    case 2: fcr = v; break;
    case 3: lcr = v; break;
    case 4: mcr = v; break;
    case 7: scr = v; break;
    default: break;                                 // LSR, MSR: read-only
  }
}

uint64_t clint_t::read(uint64_t off, unsigned size) {
  uint64_t v = 0;
  if (off < 0x4000) {
    unsigned h = off / 4;
    if (h < msip.size()) v = msip[h] & 1;
  } else if (off >= 0x4000 && off < 0xbff8) {
    unsigned h = (off - 0x4000) / 8;
    if (h < mtimecmp.size()) v = mtimecmp[h] >> ((off & 4) * 8);
  } else if (off >= 0xbff8 && off < 0xc000) {
    v = mtime >> ((off & 4) * 8);
  }
  return v & size_mask(size);
}

void clint_t::write(uint64_t off, unsigned size, uint64_t v) {
  uint64_t m = size_mask(size);
  if (off < 0x4000) {
    unsigned h = off / 4;
    if (h < msip.size()) msip[h] = v & 1;
  } else if (off >= 0x4000 && off < 0xbff8) {
    unsigned h = (off - 0x4000) / 8;
    if (h < mtimecmp.size()) {
      unsigned sh = (off & 4) * 8;
      mtimecmp[h] = (mtimecmp[h] & ~(m << sh)) | ((v & m) << sh);
    }
  } else if (off >= 0xbff8 && off < 0xc000) {
    unsigned sh = (off & 4) * 8;
    mtime = (mtime & ~(m << sh)) | ((v & m) << sh);
  }
}

// ---------------------------------------------------------------------------------------------
// mmio

uint64_t mmio_model_t::dev_read(uint64_t addr, unsigned size, bool& ok) {
  ok = true;
  const auto& c = ctx_.cfg;
  if (addr >= c.uart_base && addr < c.uart_base + c.uart_size) {
    uint64_t v = 0;
    for (unsigned i = 0; i < (1u << size); i++) v |= uint64_t(uart.read(ctx_, (addr + i) - c.uart_base)) << (8 * i);
    return v;
  }
  if (addr >= c.clint_base && addr < c.clint_base + c.clint_size) return clint.read(addr - c.clint_base, size);
  if (ctx_.in_rom(addr, 1ull << size)) {
    uint64_t v = 0;
    ctx_.mem->read(addr, 1u << size, &v);
    return v;
  }
  for (auto& r : c.dev_regions)
    if (addr >= r.first && addr < r.first + r.second) return 0;
  ok = false;
  return 0;
}

bool mmio_model_t::dev_write(uint64_t addr, unsigned size, uint64_t v) {
  const auto& c = ctx_.cfg;
  if (addr >= c.uart_base && addr < c.uart_base + c.uart_size) {
    for (unsigned i = 0; i < (1u << size); i++) uart.write(ctx_, (addr + i) - c.uart_base, uint8_t(v >> (8 * i)));
    return true;
  }
  if (addr >= c.clint_base && addr < c.clint_base + c.clint_size) {
    clint.write(addr - c.clint_base, size, v);
    return true;
  }
  for (auto& r : c.dev_regions)
    if (addr >= r.first && addr < r.first + r.second) return true;
  return false;  // ROM, main memory and unmapped space
}

void mmio_model_t::cycle(const ul_in_t& in, ul_out_t& out) {
  a_mon_.check(ctx_, "mmio A", in.a_valid, in.a, a_ready_);
  if (in.a_valid && a_ready_) {
    const tl_a_t& a = in.a;
    requests++;
    if (a.opcode != A_GET && a.opcode != A_PUT_FULL && a.opcode != A_PUT_PARTIAL) {
      ctx_.fail(strfmt("mmio A: %s not allowed", a_op_name(a.opcode)));
    } else if (check_a_common(ctx_, "mmio", a, 3)) {
      if (!inflight_.insert(a.source).second)
        ctx_.fail(strfmt("mmio A: source %u already in flight", a.source));
      if (ctx_.in_dram(a.address))
        ctx_.fail(strfmt("mmio A: %s to main memory 0x%llx (PMA_MEM goes through l1d)",
                         a_op_name(a.opcode), (unsigned long long)a.address));
      unsigned lane = a.address & (BEAT_BYTES - 1), n = 1u << a.size;
      d_msg_t m;
      m.ready_at = ctx_.now + ctx_.cfg.mmio_lat;
      m.hdr.size = a.size;
      m.hdr.source = a.source;
      bool ok;
      if (a.opcode == A_GET) {
        uint64_t v = ctx_.denied(a.address) ? (ok = false, 0) : dev_read(a.address, a.size, ok);
        m.hdr.opcode = D_ACCESS_ACK_DATA;
        m.beats.push_back(beat_with(v, lane, n));
        m.hdr.corrupt = !ok;
      } else {
        uint64_t v = beat_bytes(a.data, lane, n);
        if (a.opcode == A_PUT_PARTIAL) {
          // Apply only the masked bytes: read, merge, write (devices are byte-addressed here).
          ok = !ctx_.denied(a.address);
          for (unsigned i = 0; ok && i < n; i++)
            if ((a.mask >> (lane + i)) & 1) ok = dev_write(a.address + i, 0, (v >> (8 * i)) & 0xff);
        } else {
          ok = !ctx_.denied(a.address) && dev_write(a.address, a.size, v);
        }
        m.hdr.opcode = D_ACCESS_ACK;
      }
      m.hdr.denied = !ok;
      uint32_t src = a.source;
      m.on_done = [this, src] { inflight_.erase(src); };
      d_.push(std::move(m));
    }
  }
  d_.cycle(ctx_, in.d_ready, "mmio D", out.d_valid, out.d);
  a_ready_ = !ctx_.rng.percent(ctx_.cfg.bp);
  out.a_ready = a_ready_;
}

// ---------------------------------------------------------------------------------------------
// l1d: TL-C manager

perm_e l1d_model_t::perm(uint64_t addr) const {
  auto it = lines_.find(addr / LINE_BYTES);
  return it == lines_.end() ? PERM_N : it->second.perm;
}

bool l1d_model_t::coherent_read_ready(uint64_t addr) {
  auto it = lines_.find(addr / LINE_BYTES);
  if (it == lines_.end()) return true;
  line_t& l = it->second;
  if (l.probe_inflight || l.grant_unacked) return false;
  if (l.perm == PERM_T) {
    probe(addr, CAP_TO_B);
    return false;
  }
  return true;
}

void l1d_model_t::probe(uint64_t addr, uint8_t cap, bool block) {
  line_t& l = line(addr);
  if (l.probe_inflight) return;
  l.probe_inflight = true;
  l.probe_cap = cap;
  tl_b_t b;
  b.opcode = block ? B_PROBE_BLOCK : B_PROBE_PERM;
  b.param = cap;
  b.size = 6;
  b.source = 0;
  b.address = addr & ~uint64_t(LINE_BYTES - 1);
  b_q_.push_back(b);
}

std::vector<uint64_t> l1d_model_t::held_lines() const {
  std::vector<uint64_t> v;
  for (auto& [idx, l] : lines_)
    if (l.perm != PERM_N) v.push_back(idx * LINE_BYTES);
  return v;
}

bool l1d_model_t::quiescent() const {
  if (!d_.idle() || !b_q_.empty() || b_valid_ || pa_.active || pc_.active || !sinks_.empty()) return false;
  for (auto& [idx, l] : lines_)
    if (l.acquire_inflight || l.release_inflight || l.probe_inflight || l.grant_unacked) return false;
  return true;
}

void l1d_model_t::maybe_random_probe() {
  if (!ctx_.rng.permille(ctx_.cfg.probe_rate) || lines_.empty()) return;
  // Pick a random held line that may be probed now.
  std::vector<uint64_t> cands;
  for (auto& [idx, l] : lines_)
    if (l.perm != PERM_N && !l.probe_inflight && !l.grant_unacked) cands.push_back(idx);
  if (cands.empty()) return;
  uint64_t idx = cands[ctx_.rng.below(cands.size())];
  // ProbeBlock only: ProbePerm tells the agent it may drop dirty data, which only an L2 that is
  // about to overwrite the whole line can say.
  static const uint8_t caps[] = {CAP_TO_N, CAP_TO_B, CAP_TO_T};
  probe(idx * LINE_BYTES, caps[ctx_.rng.below(3)]);
}

void l1d_model_t::accept_e(uint32_t sink) {
  auto it = sinks_.find(sink);
  if (it == sinks_.end()) {
    ctx_.fail(strfmt("l1d E: GrantAck with sink %u, which has no Grant outstanding", sink));
    return;
  }
  if (!it->second.second) {
    ctx_.fail(strfmt("l1d E: GrantAck (sink %u) before the last beat of its Grant", sink));
    return;
  }
  line_t& l = lines_[it->second.first];
  l.grant_unacked = false;
  l.acquire_inflight = false;
  sinks_.erase(it);
}

void l1d_model_t::send_grant(const partial_t& p) {
  uint64_t addr = p.address, idx = addr / LINE_BYTES;
  bool block = p.opcode == A_ACQUIRE_BLOCK;
  uint8_t cap = CAP_TO_T;
  if (p.param == GROW_N_TO_B && ctx_.rng.percent(ctx_.cfg.grant_b)) cap = CAP_TO_B;
  // Sink: the lowest one not awaiting GrantAck.
  uint32_t sink = 0;
  while (sinks_.count(sink)) sink++;
  if (sink >= 64) { ctx_.fail("l1d: more than 64 Grants await GrantAck"); return; }
  sinks_[sink] = {idx, false};
  bool ok = ctx_.in_dram(addr, LINE_BYTES) && !ctx_.denied(addr);

  d_msg_t m;
  m.ready_at = ctx_.now + ctx_.latency(ctx_.cfg.lat);
  m.hdr.opcode = block ? D_GRANT_DATA : D_GRANT;
  m.hdr.param = cap;
  m.hdr.size = 6;
  m.hdr.source = p.source;
  m.hdr.sink = sink;
  m.hdr.denied = !ok;
  m.hdr.corrupt = block && !ok;
  m.nbeats = block ? LINE_BEATS : 1;
  // A real L2 holds a Grant back while it probes the same line; so does this one.
  m.blocked = [this, idx] { return lines_[idx].probe_inflight; };
  m.on_start = [this, idx, addr, cap, block, ok](d_msg_t& msg) {
    line_t& l = lines_[idx];
    l.perm = cap == CAP_TO_T ? PERM_T : PERM_B;
    l.grant_unacked = true;
    if (block) {
      msg.beats.resize(LINE_BEATS);
      for (unsigned i = 0; i < LINE_BEATS; i++)
        msg.beats[i] = ok ? read_beat(*ctx_.mem, addr + i * BEAT_BYTES) : beat_t{};
    }
  };
  uint32_t src = p.source;
  m.on_done = [this, src, sink] {
    inflight_src_.erase(src);
    auto it = sinks_.find(sink);
    if (it != sinks_.end()) it->second.second = true;
  };
  d_.push(std::move(m));
}

void l1d_model_t::finish_a(partial_t& p) {
  switch (p.opcode) {
    case A_ACQUIRE_BLOCK:
    case A_ACQUIRE_PERM: {
      if (p.size != 6) { ctx_.fail(strfmt("l1d A: %s of size %u (lines are size 6)", a_op_name(p.opcode), p.size)); return; }
      if (p.param > GROW_B_TO_T || (p.opcode == A_ACQUIRE_PERM && p.param == GROW_N_TO_B)) {
        ctx_.fail(strfmt("l1d A: %s with param %u not allowed", a_op_name(p.opcode), p.param));
        return;
      }
      line_t& l = line(p.address);
      if (l.acquire_inflight) {
        ctx_.fail(strfmt("l1d A: second Acquire for line 0x%llx while one is outstanding (TL-C rule 1)",
                         (unsigned long long)p.address));
        return;
      }
      if (l.release_inflight) {
        ctx_.fail(strfmt("l1d A: Acquire for line 0x%llx before its ReleaseAck (TL-C rule 2)",
                         (unsigned long long)p.address));
        return;
      }
      if (l.perm == PERM_T) {
        ctx_.fail(strfmt("l1d A: Acquire for line 0x%llx, which the agent already holds with T",
                         (unsigned long long)p.address));
        return;
      }
      if (p.param != GROW_B_TO_T && l.perm == PERM_B) {
        ctx_.fail(strfmt("l1d A: %s %s for line 0x%llx, which the agent holds with B (use BtoT)",
                         a_op_name(p.opcode), p.param == GROW_N_TO_B ? "NtoB" : "NtoT",
                         (unsigned long long)p.address));
        return;
      }
      if (p.opcode == A_ACQUIRE_PERM && p.param == GROW_B_TO_T && l.perm == PERM_N)
        fprintf(stderr, "tg: warning: l1d AcquirePerm BtoT for line 0x%llx after a probe took it to N: "
                "the agent gets T without data\n", (unsigned long long)p.address);
      l.acquire_inflight = true;
      acquires++;
      send_grant(p);
      break;
    }
    case A_GET: {
      gets++;
      bool ok = ctx_.in_dram(p.address, 1ull << p.size) && !ctx_.denied(p.address);
      d_msg_t m;
      m.ready_at = ctx_.now + ctx_.latency(ctx_.cfg.lat);
      m.hdr.opcode = D_ACCESS_ACK_DATA;
      m.hdr.size = p.size;
      m.hdr.source = p.source;
      m.hdr.denied = !ok;
      m.hdr.corrupt = !ok;
      m.nbeats = beats_of(p.size);
      uint64_t addr = p.address;
      m.on_start = [this, addr, ok](d_msg_t& msg) {
        msg.beats.resize(msg.nbeats);
        for (unsigned i = 0; i < msg.nbeats; i++)
          msg.beats[i] = ok ? read_beat(*ctx_.mem, addr + i * BEAT_BYTES) : beat_t{};
      };
      uint32_t src = p.source;
      m.on_done = [this, src] { inflight_src_.erase(src); };
      d_.push(std::move(m));
      break;
    }
    case A_PUT_FULL:
    case A_PUT_PARTIAL: {
      puts++;
      bool ok = ctx_.in_dram(p.address, 1ull << p.size) && !ctx_.denied(p.address);
      if (ok) {
        uint64_t base = p.address & ~uint64_t(BEAT_BYTES - 1);
        for (unsigned i = 0; i < p.beats; i++)
          ctx_.mem->write_masked(base + i * BEAT_BYTES, BEAT_BYTES, p.data[i].d, p.mask[i]);
      }
      d_msg_t m;
      m.ready_at = ctx_.now + ctx_.latency(ctx_.cfg.lat);
      m.hdr.opcode = D_ACCESS_ACK;
      m.hdr.size = p.size;
      m.hdr.source = p.source;
      m.hdr.denied = !ok;
      uint32_t src = p.source;
      m.on_done = [this, src] { inflight_src_.erase(src); };
      d_.push(std::move(m));
      break;
    }
    default:
      ctx_.fail(strfmt("l1d A: %s not allowed", a_op_name(p.opcode)));
  }
}

void l1d_model_t::accept_a(const tl_a_t& a) {
  if (pa_.active) {
    if (a.opcode != pa_.opcode || a.param != pa_.param || a.size != pa_.size || a.source != pa_.source ||
        a.address != pa_.address) {
      ctx_.fail(strfmt("l1d A: beat %u of a %s changed its header", pa_.got, a_op_name(pa_.opcode)));
      pa_.active = false;
      return;
    }
    pa_.data[pa_.got] = a.data;
    pa_.mask[pa_.got] = a.mask;
    if (++pa_.got == pa_.beats) { pa_.active = false; finish_a(pa_); }
    return;
  }
  bool is_put = a.opcode == A_PUT_FULL || a.opcode == A_PUT_PARTIAL;
  if (!is_put && a.opcode != A_GET && a.opcode != A_ACQUIRE_BLOCK && a.opcode != A_ACQUIRE_PERM) {
    ctx_.fail(strfmt("l1d A: %s not allowed", a_op_name(a.opcode)));
    return;
  }
  if (!check_a_common(ctx_, "l1d", a, 6)) return;
  if (!inflight_src_.insert(a.source).second) {
    ctx_.fail(strfmt("l1d A: source %u already in flight", a.source));
    return;
  }
  pa_ = partial_t{};
  pa_.opcode = a.opcode; pa_.param = a.param; pa_.size = a.size; pa_.source = a.source;
  pa_.address = a.address;
  pa_.beats = is_put ? beats_of(a.size) : 1;
  pa_.data.assign(pa_.beats, beat_t{});
  pa_.mask.assign(pa_.beats, 0);
  pa_.data[0] = a.data;
  pa_.mask[0] = a.mask;
  pa_.got = 1;
  if (pa_.got == pa_.beats) finish_a(pa_);
  else pa_.active = true;
}

void l1d_model_t::finish_c(partial_t& p) {
  line_t& l = line(p.address);
  bool data = p.opcode == C_RELEASE_DATA || p.opcode == C_PROBE_ACK_DATA;
  auto addr_s = [&] { return strfmt("0x%llx", (unsigned long long)p.address); };
  // Shrink and report parameters: the permission before and after.
  perm_e from, to;
  switch (p.param) {
    case SHRINK_T_TO_B: from = PERM_T; to = PERM_B; break;
    case SHRINK_T_TO_N: from = PERM_T; to = PERM_N; break;
    case SHRINK_B_TO_N: from = PERM_B; to = PERM_N; break;
    case REPORT_T_TO_T: from = PERM_T; to = PERM_T; break;
    case REPORT_B_TO_B: from = PERM_B; to = PERM_B; break;
    case REPORT_N_TO_N: from = PERM_N; to = PERM_N; break;
    default:
      ctx_.fail(strfmt("l1d C: %s with param %u", c_op_name(p.opcode), p.param));
      return;
  }
  if (data && from != PERM_T) {
    ctx_.fail(strfmt("l1d C: %s for line %s from %s: only a T line can carry dirty data",
                     c_op_name(p.opcode), addr_s().c_str(), perm_name(from)));
    return;
  }
  if (from != l.perm) {
    ctx_.fail(strfmt("l1d C: %s %s->%s for line %s, but the agent holds %s", c_op_name(p.opcode),
                     perm_name(from), perm_name(to), addr_s().c_str(), perm_name(l.perm)));
    return;
  }
  if (data) {
    for (unsigned i = 0; i < p.beats; i++)
      ctx_.mem->write(p.address + i * BEAT_BYTES, BEAT_BYTES, p.data[i].d);
  }
  if (p.opcode == C_RELEASE || p.opcode == C_RELEASE_DATA) {
    if (p.param > SHRINK_B_TO_N) {
      ctx_.fail(strfmt("l1d C: %s uses a report parameter", c_op_name(p.opcode)));
      return;
    }
    if (l.grant_unacked) {
      ctx_.fail(strfmt("l1d C: Release of line %s whose Grant awaits GrantAck", addr_s().c_str()));
      return;
    }
    if (l.release_inflight) {
      ctx_.fail(strfmt("l1d C: second Release of line %s before its ReleaseAck", addr_s().c_str()));
      return;
    }
    if (!inflight_src_.insert(p.source).second) {
      ctx_.fail(strfmt("l1d C: Release source %u already in flight", p.source));
      return;
    }
    releases++;
    l.perm = to;
    l.release_inflight = true;
    d_msg_t m;
    m.ready_at = ctx_.now + ctx_.cfg.ack_lat;
    m.hdr.opcode = D_RELEASE_ACK;
    m.hdr.size = 6;
    m.hdr.source = p.source;
    uint64_t idx = p.address / LINE_BYTES;
    uint32_t src = p.source;
    m.on_done = [this, idx, src] {
      lines_[idx].release_inflight = false;
      inflight_src_.erase(src);
    };
    d_.push(std::move(m));
  } else {
    if (!l.probe_inflight) {
      ctx_.fail(strfmt("l1d C: %s for line %s, which was not probed", c_op_name(p.opcode), addr_s().c_str()));
      return;
    }
    perm_e cap_perm = l.probe_cap == CAP_TO_N ? PERM_N : l.probe_cap == CAP_TO_B ? PERM_B : PERM_T;
    if (to > cap_perm) {
      ctx_.fail(strfmt("l1d C: %s leaves line %s at %s, above the probe's cap %s", c_op_name(p.opcode),
                       addr_s().c_str(), perm_name(to), perm_name(cap_perm)));
      return;
    }
    l.perm = to;
    l.probe_inflight = false;
  }
}

void l1d_model_t::accept_c(const tl_c_t& c) {
  if (pc_.active) {
    if (c.opcode != pc_.opcode || c.param != pc_.param || c.size != pc_.size || c.source != pc_.source ||
        c.address != pc_.address) {
      ctx_.fail(strfmt("l1d C: beat %u of a %s changed its header", pc_.got, c_op_name(pc_.opcode)));
      pc_.active = false;
      return;
    }
    pc_.data[pc_.got] = c.data;
    if (++pc_.got == pc_.beats) { pc_.active = false; finish_c(pc_); }
    return;
  }
  if (c.opcode < C_PROBE_ACK) {
    ctx_.fail(strfmt("l1d C: opcode %u not allowed", c.opcode));
    return;
  }
  if (c.size != 6 || (c.address & (LINE_BYTES - 1))) {
    ctx_.fail(strfmt("l1d C: %s with size %u at 0x%llx (whole aligned lines only)", c_op_name(c.opcode), c.size,
                     (unsigned long long)c.address));
    return;
  }
  bool data = c.opcode == C_RELEASE_DATA || c.opcode == C_PROBE_ACK_DATA;
  pc_ = partial_t{};
  pc_.opcode = c.opcode; pc_.param = c.param; pc_.size = c.size; pc_.source = c.source;
  pc_.address = c.address;
  pc_.beats = data ? LINE_BEATS : 1;
  pc_.data.assign(pc_.beats, beat_t{});
  pc_.data[0] = c.data;
  pc_.got = 1;
  if (pc_.got == pc_.beats) finish_c(pc_);
  else pc_.active = true;
}

void l1d_model_t::cycle(const c_in_t& in, c_out_t& out) {
  a_mon_.check(ctx_, "l1d A", in.a_valid, in.a, a_ready_);
  c_mon_.check(ctx_, "l1d C", in.c_valid, in.c, c_ready_);
  e_mon_.check(ctx_, "l1d E", in.e_valid, in.e_sink, e_ready_);

  if (b_valid_) {
    if (in.b_ready) {
      b_valid_ = false;
      b_stall_ = 0;
      probes_sent++;
    } else if (++b_stall_ > ctx_.cfg.d_stall_max) {
      ctx_.fail(strfmt("l1d B: probe not accepted for %u cycles", ctx_.cfg.d_stall_max));
    }
  }
  // E, then C, then A: a GrantAck and a Release of the same line in one cycle are legal in that
  // order; an Acquire in the same cycle as its line's Release is not (TL-C rule 2).
  if (in.e_valid && e_ready_) accept_e(in.e_sink);
  if (in.c_valid && c_ready_) accept_c(in.c);
  if (in.a_valid && a_ready_) accept_a(in.a);
  maybe_random_probe();

  d_.cycle(ctx_, in.d_ready, "l1d D", out.d_valid, out.d);

  if (!b_valid_) {
    for (auto it = b_q_.begin(); it != b_q_.end(); ++it) {
      if (lines_[it->address / LINE_BYTES].grant_unacked) continue;  // TL-C rule 3
      b_out_ = *it;
      b_valid_ = true;
      b_q_.erase(it);
      break;
    }
  }
  out.b_valid = b_valid_;
  out.b = b_out_;
  a_ready_ = !ctx_.rng.percent(ctx_.cfg.bp);
  c_ready_ = !ctx_.rng.percent(ctx_.cfg.bp);
  e_ready_ = !ctx_.rng.percent(ctx_.cfg.bp);
  out.a_ready = a_ready_;
  out.c_ready = c_ready_;
  out.e_ready = e_ready_;
}

}  // namespace tg
