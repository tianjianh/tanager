// tanager-lockstep: FPGA lockstep (plan §9 "FPGA lockstep"; docs/spec/verification.md §3.9). It checks the
// commit trace that the uncore streams into DDR (docs/spec/uncore-trace.md: 64-byte records) against
// Spike, record by record, with the simulation's checker (lockstep.cpp, §3). Spike starts at the boot ROM,
// with the images that `tanager-host load` copies into the carve-out at the same RISC-V addresses.
//
//   mkfifo /tmp/tg.trace; tanager-lockstep --fw F --kernel K --dtb D /tmp/tg.trace &
//   tanager-host boot --fw F --kernel K --dtb D --lossless --trace /tmp/tg.trace
//   tanager-lockstep --fw F --kernel K --dtb D TRACE     (a trace recorded with `tanager-host run --trace TRACE`)
//
// It never touches the hardware: tanager-host owns the board (overlay guard, ring, TRS_RP, console),
// and a checker that falls behind stalls the cores through the FIFO (uncore-trace.md, flow control). A
// FIFO rather than `--trace -` and a pipe: tanager-host's stdout carries its messages and the console.
// Records tanager-host inserts for its DMA writes into the RISC-V's memory (byte 63 = 0xE1) reach the
// checker as external writes (verification.md §3.10).
// Exit status: 0 when every record matched; 2 at the first mismatch, after its report; 5 for a usage or
// input error, an empty stream included (a bitstream without the commit trace, DR-146, streams nothing).
#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cinttypes>
#include <cstring>
#include <deque>
#include <functional>
#include <string>
#include <vector>

#include "common.h"
#include "lockstep.h"
#include "mem.h"
#include "tanager_bootrom.h"  // generated from rtl/uncore/bootrom/tg_bootrom_img_pkg.sv (sim/Makefile)

#ifndef TG_DEFAULT_ISA
#define TG_DEFAULT_ISA "rv64imafdc_zicsr_zicntr_zihpm_zifencei_zba_zbb_zbs_zicond_sstc_svinval_za64rs"
#endif
// The core's PMP entries in this tree's tg_core_pkg (DR-167; sim/Makefile's tg_pmp_default.h): the board's
// RTL, unless its bitstream was built with another PMP_ENTRIES, which --pmp then names
#ifndef TG_DEFAULT_PMP
#define TG_DEFAULT_PMP 16
#endif

using namespace tg;

namespace {

// docs/spec/soc.md §3 and tanager-host: where the images go, and the boot ROM (tg_map_pkg)
constexpr uint64_t DRAM_BASE = 0x80000000ull, OFF_FW = 0x0, OFF_KERNEL = 0x200000, OFF_DTB = 0x2200000;
constexpr uint64_t BOOTROM_BASE = 0x1000;
constexpr size_t REC = 64;  // bytes per record in the ring
// Byte 63 of a record tanager-host inserts for a host DMA write: address, up to 32 data bytes, the cycle
// of the L2's AccessAck and a byte mask (bytes 0-7, 8-39, 40-43, 44-47). Hardware records keep 44-63 zero.
constexpr uint8_t EXT_WRITE_MARK = 0xE1;

struct opts_t {
  std::string fw, kernel, dtb, input = "-";
  std::string isa = TG_DEFAULT_ISA, priv = "MSU";
  unsigned harts = 1, pmp = TG_DEFAULT_PMP, history = 64;
  uint64_t mem_mb = 768;          // the RISC-V window: the 1 GiB carve-out less tanager-host's 256 MiB ring
  int64_t plant = -1;             // self-test: corrupt the first compared value at or after this record
  double stats = 10;              // seconds between progress lines (0: none)
  uint64_t max = 0;               // stop after this many records (0: at the end of the input)
  uint64_t stale = 10000000;      // a deferred writeback pending this many cycles is a mismatch
  uint64_t reorder = 1024;        // records a hart may stay silent before it counts as idle (0: stream order)
  unsigned hart_window = 512;     // other harts' writes: records a hart may still read their old bytes (0: off)
  uint64_t early = ATOMIC_EARLY;  // cycles before its record another hart may read an atomic's write (0: none)
};

[[noreturn]] void usage() {
  fprintf(stderr,
          "usage: tanager-lockstep --fw F [--kernel K] [--dtb D] [options] [TRACE|-]\n"
          "  checks a commit-trace stream (64-byte records, uncore-trace.md) against Spike, which starts at the\n"
          "  boot ROM with the images at 0x8000_0000 (fw), +0x20_0000 (kernel) and +0x220_0000 (dtb)\n"
          "  --isa=STR --priv=STR --harts=N --pmp=N   Spike's configuration (default %s, MSU, 1, %d: the PMP\n"
          "                    entries of this tree's core, tg_core_pkg::PMP_ENTRIES; a bitstream built with\n"
          "                    another PMP_ENTRIES needs --pmp)\n"
          "  --mem-mb=N        the RISC-V DRAM window (default 768)\n"
          "  --stats=S         a progress line every S seconds on stderr (0: none; default 10)\n"
          "  --max=N           stop after N records\n"
          "  --stale=N         a deferred writeback still pending after N cycles is a mismatch (default 10M)\n"
          "  --reorder=N       several harts: apply records in cycle order, waiting for a silent hart until\n"
          "                    N more records have arrived (default 1024; 0: in arrival order)\n"
          "  --hart-window=N   several harts: a hart may read the bytes another hart's write replaced for N of\n"
          "                    its own records after it (store queue, early loads; default 512; 0: off)\n"
          "  --atomic-early=N  several harts: a read may return what another hart's AMO or SC wrote up to N\n"
          "                    cycles before the atomic's record (it performs before it retires; default %llu;\n"
          "                    0: never)\n"
          "  --plant=N         self-test: flip bit 0 of the first value the checker compares at or after\n"
          "                    record N (from 0): a register write or a deferred writeback, not a value it\n"
          "                    adopts (an MMIO load, a nondet CSR read); the run must stop there\n",
          TG_DEFAULT_ISA, TG_DEFAULT_PMP, (unsigned long long)ATOMIC_EARLY);
  exit(EXIT_HARNESS);
}

uint64_t num(const std::string& s, const char* what) {
  char* end = nullptr;
  errno = 0;
  uint64_t v = strtoull(s.c_str(), &end, 0);
  if (s.empty() || *end || errno) fatal("bad number for %s: '%s'", what, s.c_str());
  return v;
}

opts_t parse(int argc, char** argv) {
  opts_t o;
  bool input_set = false;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a.rfind("--", 0) != 0 || a == "-") {
      if (input_set) usage();
      o.input = a;
      input_set = true;
      continue;
    }
    std::string k = a.substr(2), v;
    size_t eq = k.find('=');
    bool has_v = eq != std::string::npos;
    if (has_v) { v = k.substr(eq + 1); k = k.substr(0, eq); }
    else if (k != "help" && i + 1 < argc) { v = argv[++i]; has_v = true; }  // "--fw F" as well as "--fw=F"
    if (k == "help") usage();
    else if (!has_v) fatal("--%s needs a value", k.c_str());
    else if (k == "fw") o.fw = v;
    else if (k == "kernel") o.kernel = v;
    else if (k == "dtb") o.dtb = v;
    else if (k == "isa") o.isa = v;
    else if (k == "priv") o.priv = v;
    else if (k == "harts") o.harts = unsigned(num(v, "--harts"));
    else if (k == "pmp") o.pmp = unsigned(num(v, "--pmp"));
    else if (k == "mem-mb") o.mem_mb = num(v, "--mem-mb");
    else if (k == "stats") o.stats = double(num(v, "--stats"));
    else if (k == "max") o.max = num(v, "--max");
    else if (k == "stale") o.stale = num(v, "--stale");
    else if (k == "plant") o.plant = int64_t(num(v, "--plant"));
    else if (k == "reorder") o.reorder = num(v, "--reorder");
    else if (k == "hart-window") o.hart_window = unsigned(num(v, "--hart-window"));
    else if (k == "atomic-early") o.early = num(v, "--atomic-early");
    else { fprintf(stderr, "tanager-lockstep: unknown option --%s\n", k.c_str()); usage(); }
  }
  if (o.fw.empty()) usage();
  if (o.harts < 1 || o.harts > 4) fatal("--harts must be 1..4 (the record's hart field is 2 bits)");
  return o;
}

size_t load(mem_t& mem, const std::string& path, uint64_t addr, uint64_t room) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) fatal("cannot open %s: %s", path.c_str(), strerror(errno));
  std::vector<uint8_t> buf(1 << 20);
  size_t done = 0, n;
  while ((n = fread(buf.data(), 1, buf.size(), f)) > 0) {
    if (done + n > room) fatal("%s does not fit its slot (%llu bytes)", path.c_str(), (unsigned long long)room);
    mem.write(addr + done, n, buf.data());
    done += n;
  }
  fclose(f);
  return done;
}

// One 64-byte record (uncore-trace.md §Records in DDR; host.md §Commit trace for the fields).
struct decoded_t {
  bool wb = false;
  tr_rec_t r;
  tr_wb_t w;
  uint32_t cycle32 = 0;
};

decoded_t decode(const uint8_t* p) {
  uint64_t q[6];
  memcpy(q, p, sizeof q);  // little-endian on both ends
  uint32_t h = uint32_t(q[0]);
  decoded_t d;
  d.cycle32 = uint32_t(q[5]);
  unsigned kind = h & 3;
  uint32_t hart = (h >> 2) & 3;
  bool rd_fp = (h >> 8) & 1;
  uint8_t rd = uint8_t((h >> 9) & 31);
  uint32_t tag = (h >> 15) & 31;
  if (kind == 3) {
    d.wb = true;
    d.w.hart = hart;
    d.w.wb_tag = tag;
    d.w.rd_fp = rd_fp;
    d.w.rd = rd;
    d.w.value = q[2];
    return d;
  }
  tr_rec_t& r = d.r;
  r.kind = uint8_t(kind);
  r.hart = hart;
  r.priv = uint8_t((h >> 4) & 3);
  r.rvc = (h >> 6) & 1;
  r.rd_we = (h >> 7) & 1;
  r.rd_fp = rd_fp;
  r.rd = rd;
  r.rd_deferred = (h >> 14) & 1;
  r.wb_tag = tag;
  r.mem_st = (h >> 20) & 1;
  r.mem_size = uint8_t((h >> 21) & 3);
  r.mmio_ld = (h >> 23) & 1;
  r.nondet = (h >> 24) & 1;
  r.mem_ld = (h >> 25) & 1;        // v1.5: a read of memory, its address in mem_vaddr
  r.insn = uint32_t(q[0] >> 32);
  r.pc = q[1];
  if (kind == TR_RETIRE) {
    r.rd_value = q[2];
    r.mem_vaddr = q[3];
    r.mem_wdata = q[4];
  } else {
    r.cause = q[2];
    r.tval = q[3];
  }
  return d;
}

// The records carry the low 32 bits of the core-clock cycle. The stream is in arrival order: each hart's
// records in its own order, but the uncore's trace interleaves the harts' FIFOs, so a hart that retires
// more per cycle than another falls behind it in the stream, by 200 cycles in tb_boot's two-core runs.
struct cycle_clock_t {
  uint64_t last = 0;
  uint64_t full(uint32_t c32) {
    uint64_t c = (last & ~0xffffffffull) | c32;
    if (c + 0x80000000ull < last) c += 1ull << 32;                           // wrapped
    else if (c > last + 0x80000000ull && c >= (1ull << 32)) c -= 1ull << 32;  // just before a wrap
    if (c > last) last = c;
    return c;
  }
};

double now_s() {
  using namespace std::chrono;
  return duration<double>(steady_clock::now().time_since_epoch()).count();
}

std::string hex_record(const uint8_t* p) {
  std::string s;
  for (size_t i = 0; i < 48; i += 8) {
    uint64_t v;
    memcpy(&v, p + i, 8);
    s += strfmt("%s%016llx", i ? " " : "", (unsigned long long)v);
  }
  return s;
}

}  // namespace

int main(int argc, char** argv) {
  opts_t o = parse(argc, argv);

  // ---- Spike's memory: the boot ROM and the images, as tanager-host loads them ----
  mem_t mem;
  mem.write(BOOTROM_BASE, sizeof TANAGER_BOOTROM, TANAGER_BOOTROM);
  size_t n_fw = load(mem, o.fw, DRAM_BASE + OFF_FW, OFF_KERNEL - OFF_FW);
  size_t n_k = o.kernel.empty() ? 0 : load(mem, o.kernel, DRAM_BASE + OFF_KERNEL, OFF_DTB - OFF_KERNEL);
  size_t n_d = o.dtb.empty() ? 0 : load(mem, o.dtb, DRAM_BASE + OFF_DTB, 0x10000);

  lockstep_cfg_t lc;
  lc.isa = o.isa;
  lc.priv = o.priv;
  lc.hartids.clear();
  for (unsigned i = 0; i < o.harts; i++) lc.hartids.push_back(i);
  lc.boot_pc = BOOTROM_BASE;
  lc.pmp_regions = o.pmp;
  lc.history = o.history;
  lc.hart_window = o.hart_window;
  lc.dram_base = DRAM_BASE;
  lc.dram_size = o.mem_mb << 20;
  lc.rom_base = BOOTROM_BASE;
  lc.rom_size = 0x1000;
  // Device regions of tg_map_pkg (PMA_DEVICE), as in tg_vsim
  lc.dev_regions = {{0x02000000ull, 0x10000}, {0x0C000000ull, 0x4000000}, {0x10000000ull, 0x1000},
                    {0x10001000ull, 0x1000},  {0x10010000ull, 0x4000},    {0x11000000ull, 0x10000}};
  lockstep_t ls(lc, mem, nullptr);
  fprintf(stderr, "tanager-lockstep: Spike %s, %s, %u hart(s), %llu MiB; fw %zu B, kernel %zu B, dtb %zu B; "
                  "reading %s\n", o.isa.c_str(), o.priv.c_str(), o.harts, (unsigned long long)o.mem_mb, n_fw, n_k,
          n_d, o.input == "-" ? "stdin" : o.input.c_str());

  int fd = o.input == "-" ? 0 : open(o.input.c_str(), O_RDONLY);
  if (fd < 0) fatal("cannot open %s: %s", o.input.c_str(), strerror(errno));

  std::vector<uint8_t> buf(REC * 4096);
  size_t have = 0;                 // bytes in buf, from its start
  std::vector<tr_rec_t> recs;
  std::vector<tr_wb_t> wbs;
  recs.reserve(1);
  wbs.reserve(1);
  cycle_clock_t clk;
  uint64_t n = 0, retired = 0, traps = 0, irqs = 0, nwb = 0, n_ext = 0, n_applied = 0, n_late = 0;
  uint64_t n_early = 0, early_max = 0;  // reads that took an atomic queued with a later cycle; its largest lead
  bool planted = false;
  double t0 = now_s(), t_last = t0;
  uint64_t n_last = 0;
  int status = EXIT_PASS;
  bool eof = false;

  // Several harts share Spike's memory, so their records are applied in cycle order (§3.7): each hart's
  // wait in a queue of their own, and the earliest head goes once no hart can still send an earlier
  // record, because every hart has one waiting or has sent none in the last --reorder records (it is
  // idle: in WFI, parked, or a thread that never runs). One hart's records go straight through, as
  // before. External writes are registered as they arrive, not at their cycle: each carries its own
  // visibility (from 256 cycles before its AccessAck, §3.10), and a load the L2 served that early has a
  // cycle before the AccessAck's; the producer puts the record ahead of every trace record that could
  // have read the write (it holds the trace while the write is in flight).
  // An AMO or SC performs before it retires, so another hart may read what it wrote a few cycles before its
  // record (§3.7): a read that nothing else explains takes the first such atomic queued for another hart up to
  // --atomic-early cycles later, which goes first with the records of its hart before it. While the read is
  // unexplained, it waits until every hart that is not idle has sent a record past that horizon.
  struct pending_t {
    uint64_t idx, cyc;  // stream position; full cycle
    bool ext;
    decoded_t d;
    uint8_t raw[REC];
  };
  std::vector<std::deque<pending_t>> q(o.harts);  // one per hart
  std::vector<uint64_t> last_seen(o.harts, 0);        // stream position + 1 of each hart's last record
  uint64_t applied_cyc = 0;

  auto apply = [&](pending_t& pr) -> bool {
    if (pr.ext) {
      uint64_t pa;
      uint32_t mask;
      memcpy(&pa, pr.raw, 8);
      memcpy(&mask, pr.raw + 44, 4);
      unsigned len = 32;
      while (len && !(mask >> (len - 1) & 1)) len--;
      if (len && !ls.external_write(pa, pr.raw + 8, mask, len, pr.cyc)) {
        fprintf(stderr, "tanager-lockstep: MISMATCH at record %llu: %s\n  raw record: %s\n",
                (unsigned long long)pr.idx, ls.error().c_str(), hex_record(pr.raw).c_str());
        return false;
      }
      n_ext++;
      return true;
    }
    recs.clear();
    wbs.clear();
    decoded_t& d = pr.d;
    if (d.wb) {
      d.w.cycle = pr.cyc;
      wbs.push_back(d.w);
      nwb++;
    } else {
      d.r.cycle = pr.cyc;
      recs.push_back(d.r);
      if (d.r.kind == TR_RETIRE) retired++;
      else if (d.r.kind == TR_TRAP) traps++;
      else irqs++;
    }
    if (!ls.cycle(recs, wbs) || ((++n_applied & 4095) == 0 && !ls.check_stale(pr.cyc, o.stale))) {
      fprintf(stderr, "tanager-lockstep: MISMATCH at record %llu (cycle %llu): %s\n  raw record: %s\n",
              (unsigned long long)pr.idx, (unsigned long long)pr.cyc, ls.error().c_str(), hex_record(pr.raw).c_str());
      ls.report(stderr);
      return false;
    }
    return true;
  };
  // Applies the record at the head of hart b's queue: 1, or 0 to wait for more records, or -1 at a mismatch.
  // Its read may need another hart's atomic queued with a later cycle (above): that one goes first, with the
  // records of its hart before it, each the same way (its read may need a third hart's), from harts not
  // already waiting for one (`busy`, a mask).
  std::function<int(size_t, bool, unsigned)> head = [&](size_t b, bool flush, unsigned busy) -> int {
    busy |= 1u << b;
    if (o.harts > 1 && o.early) {
      const pending_t& hd = q[b].front();
      std::vector<const tr_rec_t*> later;
      std::vector<std::pair<size_t, size_t>> at;  // hart, place in its queue
      for (size_t h = 0; h < q.size(); h++)
        for (size_t k = 0; !(busy >> h & 1) && k < q[h].size() && q[h][k].cyc <= hd.cyc + o.early; k++)
          if (!q[h][k].d.wb && q[h][k].d.r.mem_st) {
            later.push_back(&q[h][k].d.r);
            at.push_back({h, k});
          }
      const int e = hd.d.wb ? ls.early_atomic(hd.d.w, later) : ls.early_atomic(hd.d.r, later);
      if (e == -2 && !flush)
        for (unsigned h = 0; h < o.harts; h++)
          if (h != b && n - last_seen[h] < o.reorder && (q[h].empty() || q[h].back().cyc <= hd.cyc + o.early))
            return 0;  // h may still send the atomic
      if (e >= 0) {
        const auto [h, k] = at[size_t(e)];
        early_max = std::max(early_max, q[h][k].cyc - hd.cyc);
        n_early++;
        for (size_t j = 0; j <= k; j++)
          if (int r = head(h, flush, busy); r <= 0) return r;
      }
    }
    pending_t pr = std::move(q[b].front());
    q[b].pop_front();
    if (pr.cyc > applied_cyc) applied_cyc = pr.cyc;
    return apply(pr) ? 1 : -1;
  };
  // Applies every record that may go (all of them with `flush`); false at a mismatch
  auto drain = [&](bool flush) -> bool {
    for (;;) {
      int best = -1;
      for (size_t i = 0; i < q.size(); i++)
        if (!q[i].empty() && (best < 0 || q[i].front().cyc < q[size_t(best)].front().cyc ||
                              (q[i].front().cyc == q[size_t(best)].front().cyc &&
                               q[i].front().idx < q[size_t(best)].front().idx)))
          best = int(i);
      if (best < 0) return true;
      if (!flush && o.harts > 1)
        for (unsigned h = 0; h < o.harts; h++)
          if (q[h].empty() && n - last_seen[h] < o.reorder) return true;  // h may still send an earlier one
      if (int r = head(size_t(best), flush, 0); r <= 0) return r == 0;
    }
  };

  while (!eof && (!o.max || n < o.max)) {
    ssize_t got = read(fd, buf.data() + have, buf.size() - have);
    if (got < 0) {
      if (errno == EINTR) continue;
      fatal("read: %s", strerror(errno));
    }
    if (got == 0) eof = true;
    have += size_t(got);
    size_t off = 0;
    for (; off + REC <= have && (!o.max || n < o.max); off += REC) {
      uint8_t* p = buf.data() + off;
      pending_t pr;
      pr.idx = n;
      memcpy(pr.raw, p, REC);
      size_t qi;
      if (p[63] == EXT_WRITE_MARK) {  // tanager-host's record of a host DMA write (verification.md §3.10)
        uint32_t c32;
        memcpy(&c32, p + 40, 4);
        pr.ext = true;
        pr.cyc = clk.full(c32);
        n++;
        if (!apply(pr)) {  // registered now (see above)
          status = EXIT_MISMATCH;
          break;
        }
        continue;
      } else {
        decoded_t d = decode(p);
        // Only a value the checker compares: one it adopts (an MMIO load polling a UART, say) would
        // never show, and the self-test would pass without testing anything.
        if (o.plant >= 0 && !planted && n >= uint64_t(o.plant) && (d.wb || lockstep_t::compares_value(d.r))) {
          std::string what;
          if (d.wb) {
            d.w.value ^= 1;
            what = strfmt("the writeback of %c%u (tag %u)", d.w.rd_fp ? 'f' : 'x', d.w.rd, d.w.wb_tag);
          } else {
            d.r.rd_value ^= 1;
            what = strfmt("%c%u of %s at %016llx", d.r.rd_fp ? 'f' : 'x', d.r.rd, ls.disasm(d.r.insn).c_str(),
                          (unsigned long long)d.r.pc);
          }
          planted = true;
          fprintf(stderr, "tanager-lockstep: planted a wrong value (bit 0 flipped) in record %llu: %s\n",
                  (unsigned long long)n, what.c_str());
        }
        unsigned hart = d.wb ? d.w.hart : d.r.hart;
        pr.ext = false;
        pr.cyc = clk.full(d.cycle32);
        pr.d = d;
        pr.d.r.cycle = pr.cyc;  // for the lookahead (lockstep_t::early_atomic)
        if (hart >= o.harts) {  // the checker reports a hart Spike lacks, after the records before it
          n++;
          if (!drain(true) || !apply(pr)) {
            status = EXIT_MISMATCH;
            break;
          }
          continue;
        }
        qi = hart;
        last_seen[hart] = n + 1;
      }
      if (o.harts > 1 && pr.cyc < applied_cyc && n_late++ == 0 && o.reorder)
        fprintf(stderr, "tanager-lockstep: record %llu (cycle %llu) came after records up to cycle %llu were "
                        "checked; a larger --reorder keeps the cycle order\n",
                (unsigned long long)n, (unsigned long long)pr.cyc, (unsigned long long)applied_cyc);
      q[qi].push_back(std::move(pr));
      n++;
      if (!drain(false)) {
        status = EXIT_MISMATCH;
        break;
      }
    }
    if (status != EXIT_PASS) break;
    memmove(buf.data(), buf.data() + off, have - off);  // a partial record waits for the rest
    have -= off;
    if (o.stats > 0 && now_s() - t_last >= o.stats) {
      double t = now_s();
      fprintf(stderr, "tanager-lockstep: %llu records (%.0f/s; %.0f/s overall), %llu retired, %llu traps, "
                      "%llu interrupts, %zu writebacks pending\n",
              (unsigned long long)n, (n - n_last) / (t - t_last), n / (t - t0), (unsigned long long)retired,
              (unsigned long long)traps, (unsigned long long)irqs, ls.pending_wbs());
      t_last = t;
      n_last = n;
    }
  }
  if (status == EXIT_PASS && !drain(true)) status = EXIT_MISMATCH;  // the records still queued
  if (status == EXIT_PASS && have % REC && eof)
    fprintf(stderr, "tanager-lockstep: the stream ended inside a record (%zu bytes left over)\n", have % REC);
  if (status == EXIT_PASS && eof && !ls.finish()) {
    fprintf(stderr, "tanager-lockstep: MISMATCH at the end: %s\n", ls.error().c_str());
    ls.report(stderr);
    status = EXIT_MISMATCH;
  }
  if (status == EXIT_PASS && n == 0) {  // nothing was checked, which is not a pass
    fprintf(stderr, "tanager-lockstep: the stream held no records, so nothing was checked. A bitstream built "
                    "without the commit trace (DR-146, TG_COMMIT_TRACE=0) streams none; lockstep needs it on.\n");
    status = EXIT_HARNESS;
  }
  double t = now_s() - t0;
  if (n_ext)
    fprintf(stderr, "tanager-lockstep: %llu external writes; %llu loads returned their new bytes\n",
            (unsigned long long)n_ext, (unsigned long long)ls.ext_loads_new());
  if (n_late)
    fprintf(stderr, "tanager-lockstep: %llu records came after later cycles had been checked\n",
            (unsigned long long)n_late);
  if (ls.hart_loads_old())
    fprintf(stderr, "tanager-lockstep: %llu loads read bytes another hart's recent write had replaced; %llu "
                    "atomics read past a store, which then followed them\n",
            (unsigned long long)ls.hart_loads_old(), (unsigned long long)ls.hart_reapplied());
  if (ls.hart_late())
    fprintf(stderr, "tanager-lockstep: %llu reads showed a plain store that reached memory after a later write of "
                    "another hart to its bytes\n", (unsigned long long)ls.hart_late());
  if (n_early)
    fprintf(stderr, "tanager-lockstep: %llu reads returned what another hart's AMO or SC wrote before its record "
                    "(up to %llu cycles before)\n", (unsigned long long)n_early, (unsigned long long)early_max);
  fprintf(stderr, "tanager-lockstep: %s after %llu records (%llu retired, %llu traps, %llu interrupts, %llu "
                  "writebacks) in %.1f s, %.0f records/s%s\n",
          status == EXIT_PASS ? "PASS" : status == EXIT_MISMATCH ? "MISMATCH" : "NOTHING CHECKED",
          (unsigned long long)n, (unsigned long long)retired,
          (unsigned long long)traps, (unsigned long long)irqs, (unsigned long long)nwb, t, t > 0 ? n / t : 0.0,
          o.plant >= 0 && !planted ? "; nothing was planted (no compared value from there on)" : "");
  return status;
}
