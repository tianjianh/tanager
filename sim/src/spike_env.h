// Spike as a library: our platform for it (simif_t) and the analysis of one step's commit log.
// Used by the lockstep checker and by tg_replay (docs/spec/verification.md §3.1, §3.8).
#pragma once

#include <riscv/cfg.h>
#include <riscv/disasm.h>
#include <riscv/encoding.h>
#include <riscv/mmu.h>
#include <riscv/processor.h>
#include <riscv/simif.h>
#include <sys/mman.h>

#include <algorithm>
#include <cstring>
#include <functional>
#include <map>
#include <ostream>
#include <string>
#include <utility>
#include <vector>

#include "common.h"
#include "mem.h"

namespace tg {

struct spike_platform_t {
  std::string isa = "rv64im_zicsr_zifencei";
  std::string priv = "M";
  std::vector<uint32_t> hartids = {0};
  uint64_t boot_pc = 0x80000000ull;
  unsigned pmp_regions = 16, pmp_granularity = 4;
  bool pmp_reset_off = false;
  unsigned vaddr_bits = 39;  // Sv39 when S-mode exists (plan §4.1); Spike otherwise takes it from a DTS
  uint64_t dram_base = 0x80000000ull, dram_size = 2048ull << 20;
  uint64_t rom_base = 0x1000, rom_size = 0x1000;
  std::vector<std::pair<uint64_t, uint64_t>> dev_regions;
  std::vector<std::pair<uint64_t, uint64_t>> deny;  // --deny: accesses fault, as the RTL's do
};

inline bool in_range(uint64_t a, uint64_t base, uint64_t size) { return size && a >= base && a - base < size; }

// DRAM as one host mapping, the boot ROM read- and fetch-only, device regions (loads return what
// dev_load gives, zero by default; stores go to dev_store), access faults everywhere else (§3.1).
class spike_env_t final : public simif_t {
 public:
  spike_env_t(const spike_platform_t& c, const mem_t& image) : c_(c) {
    cfg_.isa = c_.isa.c_str();
    cfg_.priv = c_.priv.c_str();
    cfg_.pmpregions = c.pmp_regions;
    cfg_.pmpgranularity = c.pmp_granularity;
    cfg_.hartids.assign(c.hartids.begin(), c.hartids.end());
    cfg_.explicit_hartids = true;
    cfg_.trigger_count = 0;
    cfg_.wfi_as_nop = true;
    cfg_.mem_layout = {mem_cfg_t(c.dram_base, c.dram_size)};
    cfg_.start_pc.set_global(c.boot_pc);
    debug_mmu = nullptr;

    void* m = mmap(nullptr, c.dram_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (m == MAP_FAILED) fatal("Spike: cannot map %llu MiB of memory", (unsigned long long)(c.dram_size >> 20));
    madvise(m, c.dram_size, MADV_DONTDUMP);  // a crash must not write gigabytes of core (WSL pipes it)
    dram_ = static_cast<uint8_t*>(m);
    rom_.assign(c.rom_size, 0);
    auto copy = [](uint64_t base, const uint8_t* p, uint64_t rbase, uint64_t rsize, uint8_t* dst) {
      uint64_t lo = std::max(base, rbase), hi = std::min(base + mem_t::CHUNK, rbase + rsize);
      if (lo < hi) memcpy(dst + (lo - rbase), p + (lo - base), hi - lo);
    };
    image.for_each_chunk([&](uint64_t base, const uint8_t* p) {
      copy(base, p, c.dram_base, c.dram_size, dram_);
      if (c.rom_size) copy(base, p, c.rom_base, c.rom_size, rom_.data());
    });

    // Spike formats a commit-log line into this file at every step (about ten fprintf calls). Nothing reads
    // it, so it is opened read-only: glibc's and musl's fprintf then return at once, which halves the
    // checker's time per record (verification.md §3.9).
    log_ = fopen("/dev/null", "r");
    if (!log_) fatal("Spike: cannot open /dev/null");
    for (uint32_t id : c.hartids) {
      auto* p = new processor_t(cfg_.isa, cfg_.priv, &cfg_, this, id, false, log_, null_os_);
      // The MMU mode must be known before reset: CSR write masks (mstatus.SUM, MXR) depend on it.
      if (c_.priv.find('S') != std::string::npos && c.vaddr_bits) {
        p->set_max_vaddr_bits(c.vaddr_bits);
        p->reset();
      }
      p->enable_log_commits();
      p->get_state()->pc = c.boot_pc;
      if (c.pmp_reset_off && c.pmp_regions) {
        p->put_csr(CSR_PMPCFG0, 0);
        p->put_csr(CSR_PMPADDR0, 0);
      }
      procs.push_back(p);
      harts_[id] = p;
    }
  }

  ~spike_env_t() override {
    for (auto* p : procs) delete p;
    munmap(dram_, c_.dram_size);
    if (log_) fclose(log_);
  }

  char* addr_to_mem(reg_t paddr) override {
    if (denied(paddr)) return nullptr;
    return in_range(paddr, c_.dram_base, c_.dram_size) ? reinterpret_cast<char*>(dram_ + (paddr - c_.dram_base)) : nullptr;
  }
  // A denied range is a bus error, which only an access meets: it stays reservable, so an SC that fails for
  // want of a reservation (no access) does not fault, as in the core; LR and AMOs still fault there.
  bool reservable(reg_t paddr) override { return in_range(paddr, c_.dram_base, c_.dram_size); }
  bool mmio_fetch(reg_t paddr, size_t len, uint8_t* bytes) override {
    if (denied(paddr)) return false;
    if (!in_range(paddr, c_.rom_base, c_.rom_size) || paddr + len > c_.rom_base + c_.rom_size) return false;
    memcpy(bytes, rom_.data() + (paddr - c_.rom_base), len);
    return true;
  }
  bool mmio_load(reg_t paddr, size_t len, uint8_t* bytes) override {
    if (amo_step || denied(paddr)) return false;  // AMOs outside main memory fault (interfaces.md §2.4)
    if (in_range(paddr, c_.rom_base, c_.rom_size)) return mmio_fetch(paddr, len, bytes);
    if (!is_device(paddr)) return false;
    memset(bytes, 0, len);
    if (dev_load) dev_load(paddr, len, bytes);
    return true;
  }
  bool mmio_store(reg_t paddr, size_t len, const uint8_t* bytes) override {
    if (amo_step || denied(paddr) || !is_device(paddr)) return false;
    if (dev_store) dev_store(paddr, len, bytes);
    return true;
  }
  void proc_reset(unsigned) override {}
  const cfg_t& get_cfg() const override { return cfg_; }
  const std::map<size_t, processor_t*>& get_harts() const override { return harts_; }
  const char* get_symbol(uint64_t) override { return nullptr; }

  bool is_device(uint64_t a) const {
    for (auto& r : c_.dev_regions)
      if (in_range(a, r.first, r.second)) return true;
    return false;
  }
  bool in_dram(uint64_t a) const { return in_range(a, c_.dram_base, c_.dram_size); }
  bool denied(uint64_t a) const {
    for (auto& r : c_.deny)
      if (in_range(a, r.first, r.second)) return true;
    return false;
  }
  uint64_t read64(uint64_t pa) const {
    uint64_t v = 0;
    if (in_range(pa, c_.dram_base, c_.dram_size) && pa + 8 <= c_.dram_base + c_.dram_size)
      memcpy(&v, dram_ + (pa - c_.dram_base), 8);
    else if (in_range(pa, c_.rom_base, c_.rom_size) && pa + 8 <= c_.rom_base + c_.rom_size)
      memcpy(&v, rom_.data() + (pa - c_.rom_base), 8);
    return v;
  }

  std::vector<processor_t*> procs;
  bool amo_step = false;  // set while stepping an AMO: device accesses then fault
  std::function<void(uint64_t, size_t, uint8_t*)> dev_load;
  std::function<void(uint64_t, size_t, const uint8_t*)> dev_store;

 private:
  spike_platform_t c_;
  cfg_t cfg_;
  std::ostream null_os_{nullptr};
  std::map<size_t, processor_t*> harts_;
  uint8_t* dram_ = nullptr;
  std::vector<uint8_t> rom_;
  FILE* log_ = nullptr;
};

// What one Spike step did, from its commit log (§3.3).
struct spike_step_t {
  uint64_t pc = 0;
  uint32_t insn = 0;
  uint8_t priv = 0;
  bool trapped = false, interrupt = false;
  uint64_t cause = 0, epc = 0, tval = 0;
  int nwr = 0;  // integer and FP register writes (x0 excluded)
  bool rd_fp = false;
  unsigned rd = 0;
  uint64_t rd_value = 0;
  bool adopted = false;
  int nst = 0;
  uint64_t st_addr = 0, st_val = 0;
  unsigned st_size = 0;
  int nld = 0;
  uint64_t ld_addr = 0;  // virtual
  unsigned ld_size = 0;
};

// Steps one hart by one instruction or one trap and reads back what happened.
inline spike_step_t spike_step(processor_t* p, uint32_t insn) {
  state_t* s = p->get_state();
  spike_step_t st;
  st.pc = s->pc;
  st.priv = uint8_t(s->prv);
  st.insn = insn;
  s->log_reg_write.clear();
  s->log_mem_read.clear();
  s->log_mem_write.clear();
  p->step(1);
  bool has_cause = false, has_epc = false;
  for (auto& [key, val] : s->log_reg_write) {
    unsigned type = key & 0xf;
    reg_t idx = key >> 4;
    uint64_t v = val.v[0];
    if (type == 0) {
      if (idx) { st.nwr++; st.rd = unsigned(idx); st.rd_fp = false; st.rd_value = v; }
    } else if (type == 1) {
      st.nwr++; st.rd = unsigned(idx); st.rd_fp = true; st.rd_value = v;
    } else if (type == 4) {
      if (idx == CSR_MCAUSE || idx == CSR_SCAUSE) { has_cause = true; st.cause = v; }
      else if (idx == CSR_MEPC || idx == CSR_SEPC) { has_epc = true; st.epc = v; }
      else if (idx == CSR_MTVAL || idx == CSR_STVAL) st.tval = v;
    }
  }
  // A trap writes the cause and EPC CSRs together; no single instruction does.
  st.trapped = has_cause && has_epc;
  st.interrupt = st.trapped && (st.cause >> 63);
  if (st.trapped) st.nwr = 0;
  for (auto& [addr, val, size] : s->log_mem_write) {
    st.nst++; st.st_addr = addr; st.st_val = val; st.st_size = size;
  }
  for (auto& e : s->log_mem_read) { st.nld++; st.ld_addr = std::get<0>(e); st.ld_size = std::get<2>(e); }
  return st;
}

// The physical address of a data access (or, with fetch, an instruction fetch) at `va` by hart p as its state stands: Spike's translation
// (MPRV, Sv39/48/57 and superpages), read-only (no A/D updates) and without permission checks, which
// the instruction's own step made (verification.md §3.10).
inline bool spike_data_paddr(processor_t* p, const spike_env_t& env, uint64_t va, uint64_t& pa, bool fetch = false) {
  state_t* s = p->get_state();
  reg_t prv = s->prv;
  const reg_t ms = s->mstatus->read();
  if (!fetch && prv == PRV_M && (ms & MSTATUS_MPRV)) prv = get_field(ms, MSTATUS_MPP);  // fetches ignore MPRV
  const uint64_t satp = p->extension_enabled('S') ? p->get_csr(CSR_SATP) : 0;
  const unsigned mode = unsigned(satp >> 60);
  if (prv == PRV_M || mode == 0) { pa = va; return true; }
  const int levels = mode == 8 ? 3 : mode == 9 ? 4 : mode == 10 ? 5 : 0;
  if (!levels) return false;
  const uint64_t ppn_mask = (1ull << 44) - 1;
  uint64_t a = (satp & ppn_mask) << 12;
  for (int i = levels - 1; i >= 0; i--) {
    const uint64_t pte = env.read64(a + ((va >> (12 + 9 * i)) & 0x1ff) * 8);
    if (!(pte & 1)) return false;
    const uint64_t ppn = (pte >> 10) & ppn_mask;
    if (pte & 0xa) {  // R or X: a leaf, perhaps a superpage
      const uint64_t off = (1ull << (12 + 9 * i)) - 1;
      pa = ((ppn << 12) & ~off) | (va & off);
      return true;
    }
    a = ppn << 12;
  }
  return false;
}

// Instruction bits at pc as Spike fetches them, or false if the fetch faults. By default through Spike's
// instruction cache: Spike's own fetch refills it at every step, and it is flushed with Spike's TLB (traps,
// xRET, satp, mstatus and PMP writes, SFENCE.VMA) and at FENCE.I. fresh = true translates and reads again.
inline bool spike_fetch(processor_t* p, uint64_t pc, uint32_t& bits, bool fresh = false) {
  try {
    mmu_t* m = p->get_mmu();
    bits = uint32_t((fresh ? m->load_insn(pc) : m->access_icache(pc)->data).insn.bits());
  } catch (trap_t&) {
    return false;
  }
  if ((bits & 3) != 3) bits &= 0xffff;
  return true;
}

// Instruction classes the checker needs.
inline bool is_csr_insn(uint32_t insn) {
  unsigned f3 = (insn >> 12) & 7;
  return (insn & 0x7f) == 0x73 && f3 != 0 && f3 != 4;
}
inline bool is_amo_insn(uint32_t insn) { return (insn & 0x7f) == 0x2f; }
inline bool is_load_insn(uint32_t insn, bool rvc) {
  if (!rvc) return (insn & 0x7f) == 0x03 || (insn & 0x7f) == 0x07;
  unsigned q = insn & 3, f3 = (insn >> 13) & 7;
  return (q == 0 || q == 2) && f3 >= 1 && f3 <= 3;  // c.fld c.lw c.ld / c.fldsp c.lwsp c.ldsp
}
// CSRs whose reads the checker adopts (verification.md §3.4).
inline bool adopted_csr(unsigned csr) {
  return csr == 0xC00 || csr == 0xC01 || (csr >= 0xC03 && csr <= 0xC1F) || csr == 0xB00 ||
         (csr >= 0xB03 && csr <= 0xB1F) || csr == 0x344 || csr == 0x144 || csr == 0xF11 ||
         csr == 0xF12 || csr == 0xF13;
}

}  // namespace tg
