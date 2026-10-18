// tgsim: functional RISC-V simulator.
#include "iss.h"

#include <sys/mman.h>

#include <bit>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>

namespace tg {

// ---------------------------------------------------------------- memory

Memory::Memory(uint64_t base, uint64_t size) : base_(base), size_(size) {
  void* p = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (p == MAP_FAILED) { perror("mmap"); std::abort(); }
  mem_ = static_cast<uint8_t*>(p);
}
Memory::~Memory() { munmap(mem_, size_); }

// ---------------------------------------------------------------- helpers

namespace {

constexpr uint32_t F32_QNAN = 0x7fc00000u;
constexpr uint64_t F64_QNAN = 0x7ff8000000000000ull;

inline int64_t sext32(uint64_t v) { return (int64_t)(int32_t)(uint32_t)v; }
inline uint64_t zext32(uint64_t v) { return v & 0xffffffffull; }

inline float unbox_s(uint64_t r) {
  uint32_t b = ((r >> 32) == 0xffffffffull) ? (uint32_t)r : F32_QNAN;
  float f;
  std::memcpy(&f, &b, 4);
  return f;
}
inline uint32_t unbox_s_bits(uint64_t r) { return ((r >> 32) == 0xffffffffull) ? (uint32_t)r : F32_QNAN; }
inline uint64_t box_s(float f) {
  uint32_t b;
  std::memcpy(&b, &f, 4);
  if (std::isnan(f)) b = F32_QNAN;
  return 0xffffffff00000000ull | b;
}
inline uint64_t box_s_bits(uint32_t b) { return 0xffffffff00000000ull | b; }
inline double as_d(uint64_t r) {
  double d;
  std::memcpy(&d, &r, 8);
  return d;
}
inline uint64_t d_bits(double d) {
  uint64_t r;
  std::memcpy(&r, &d, 8);
  if (std::isnan(d)) r = F64_QNAN;
  return r;
}

double round_rm(double v, int rm) {
  switch (rm) {
    case 1: return std::trunc(v);          // RTZ
    case 2: return std::floor(v);          // RDN
    case 3: return std::ceil(v);           // RUP
    case 4: return std::round(v);          // RMM
    default: return std::nearbyint(v);     // RNE (host default rounding)
  }
}

template <class I>
I cvt_to_int(double v, int rm) {
  if (std::isnan(v)) return std::numeric_limits<I>::max();
  const double r = round_rm(v, rm);
  if (r <= (double)std::numeric_limits<I>::min()) return std::numeric_limits<I>::min();
  if (r >= (double)std::numeric_limits<I>::max()) return std::numeric_limits<I>::max();
  return (I)r;
}

template <class F>
uint64_t fclass(F v, bool sign) {
  if (std::isinf(v)) return sign ? 1u << 0 : 1u << 7;
  if (std::isnan(v)) {
    // Quiet vs signalling cannot be told apart reliably after a host round trip; report quiet NaN.
    return 1u << 9;
  }
  if (v == 0) return sign ? 1u << 3 : 1u << 4;
  if (std::fpclassify(v) == FP_SUBNORMAL) return sign ? 1u << 2 : 1u << 5;
  return sign ? 1u << 1 : 1u << 6;
}

template <class F>
F fminmax(F a, F b, bool is_max) {
  if (std::isnan(a) && std::isnan(b)) return std::numeric_limits<F>::quiet_NaN();
  if (std::isnan(a)) return b;
  if (std::isnan(b)) return a;
  if (a == 0 && b == 0) {
    const bool sa = std::signbit(a), sb = std::signbit(b);
    if (is_max) return sa && !sb ? b : a;
    return !sa && sb ? b : a;
  }
  return is_max ? (a > b ? a : b) : (a < b ? a : b);
}

}  // namespace

// ---------------------------------------------------------------- ISS

Iss::Iss(uint64_t ram_base, uint64_t ram_size) : mem_(ram_base, ram_size) {}

bool Iss::load_elf(const std::string& path, std::string& err) {
  std::ifstream f(path, std::ios::binary);
  if (!f) { err = "cannot open " + path; return false; }
  std::vector<uint8_t> img((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
  if (img.size() < 52 || std::memcmp(img.data(), "\x7f" "ELF", 4) != 0) { err = "not an ELF file"; return false; }
  const bool is64 = img[4] == 2;
  if (img[5] != 1) { err = "not little-endian"; return false; }
  auto rd16 = [&](size_t o) { uint16_t v; std::memcpy(&v, &img[o], 2); return v; };
  auto rd32 = [&](size_t o) { uint32_t v; std::memcpy(&v, &img[o], 4); return v; };
  auto rd64 = [&](size_t o) { uint64_t v; std::memcpy(&v, &img[o], 8); return v; };
  if (rd16(18) != 243) { err = "not a RISC-V ELF"; return false; }
  xlen_ = is64 ? 64 : 32;
  const uint64_t entry = is64 ? rd64(24) : rd32(24);
  const uint64_t phoff = is64 ? rd64(32) : rd32(28);
  const uint16_t phentsize = rd16(is64 ? 54 : 42), phnum = rd16(is64 ? 56 : 44);
  for (unsigned i = 0; i < phnum; i++) {
    const size_t ph = phoff + (size_t)i * phentsize;
    const uint32_t type = rd32(ph);
    if (type != 1) continue;  // PT_LOAD
    uint64_t off, paddr, filesz, memsz;
    if (is64) { off = rd64(ph + 8); paddr = rd64(ph + 24); filesz = rd64(ph + 32); memsz = rd64(ph + 40); }
    else { off = rd32(ph + 4); paddr = rd32(ph + 12); filesz = rd32(ph + 16); memsz = rd32(ph + 20); }
    if (!memsz) continue;
    if (!mem_.contains(paddr, (unsigned)memsz)) { err = "segment outside RAM"; return false; }
    if (off + filesz > img.size()) { err = "truncated segment"; return false; }
    std::memcpy(mem_.ptr(paddr), &img[off], filesz);
    std::memset(mem_.ptr(paddr) + filesz, 0, memsz - filesz);
  }
  // The RTL platform's symbols, from the symbol table (absent in bsp/ builds).
  if (is64) {
    const uint64_t shoff = rd64(40);
    const uint16_t shentsize = rd16(58), shnum = rd16(60);
    for (unsigned i = 0; i < shnum && shoff + (size_t)(i + 1) * shentsize <= img.size(); i++) {
      const size_t sh = shoff + (size_t)i * shentsize;
      if (rd32(sh + 4) != 2) continue;  // SHT_SYMTAB
      const uint64_t off = rd64(sh + 24), size = rd64(sh + 32), entsize = rd64(sh + 56);
      const size_t strsh = shoff + (size_t)rd32(sh + 40) * shentsize;
      if (!entsize || off + size > img.size() || strsh + shentsize > img.size()) break;
      const uint64_t stroff = rd64(strsh + 24), strsize = rd64(strsh + 32);
      for (uint64_t s = off; s + entsize <= off + size; s += entsize) {
        const uint32_t name = rd32(s);
        if (name >= strsize || stroff + name >= img.size()) continue;
        const char* nm = reinterpret_cast<const char*>(&img[stroff + name]);
        if (std::strcmp(nm, "tohost") == 0) tohost_ = rd64(s + 8);
        else if (std::strcmp(nm, "tg_marker") == 0) marker_ = rd64(s + 8);
      }
      break;
    }
  }
  pc_ = entry;
  csr_[0x301] = (xlen_ == 64 ? (2ull << 62) : (1ull << 30)) | 0x14112d;  // misa: IMAFDC (+S/U bits)
  return true;
}

void Iss::fault(const char* what, uint64_t pc, uint64_t a) {
  char buf[160];
  std::snprintf(buf, sizeof buf, "%s at pc=0x%llx addr=0x%llx", what, (unsigned long long)pc, (unsigned long long)a);
  error_ = buf;
  exited_ = true;
  exit_code_ = -1;
}

const Decoded* Iss::fetch_decode(uint64_t pc) {
  auto it = dcache_.find(pc);
  if (it != dcache_.end()) return &it->second;
  if (!mem_.contains(pc, 2)) return nullptr;
  uint16_t lo, hi = 0;
  std::memcpy(&lo, mem_.ptr(pc), 2);
  if ((lo & 3) == 3) {
    if (!mem_.contains(pc, 4)) return nullptr;
    std::memcpy(&hi, mem_.ptr(pc + 2), 2);
  }
  Decoded d;
  if (!decode_at(lo, hi, xlen_, d)) return nullptr;
  return &dcache_.emplace(pc, d).first->second;
}

const Decoded* Iss::decode_static(uint64_t pc) { return fetch_decode(pc); }

template <class T>
bool Iss::ld(uint64_t a, T& v, DynInst& di) {
  di.addr = a;
  if (a >= MMIO_BASE && a < MMIO_BASE + MMIO_SIZE) {
    di.mmio = true;
    if (a == MMIO_GETC) v = (T)(in_pos_ < in_.size() ? (int64_t)(uint8_t)in_[in_pos_++] : -1);
    else if (a == UART_LSR) v = (T)0x60;  // THR and transmitter empty
    else v = 0;
    return true;
  }
  if (!mem_.contains(a, sizeof(T))) { fault("load access fault", di.pc, a); return false; }
  std::memcpy(&v, mem_.ptr(a), sizeof(T));
  return true;
}

template <class T>
bool Iss::st(uint64_t a, T v, DynInst& di) {
  di.addr = a;
  if (a >= MMIO_BASE && a < MMIO_BASE + MMIO_SIZE) {
    di.mmio = true;
    if (a == MMIO_PUTC) out_.push_back((char)v);
    else if (a == MMIO_EXIT) { exited_ = true; exit_code_ = (int)(int64_t)v; }
    else if (a == MMIO_MARKER) di.marker = (uint8_t)v;
    return true;
  }
  if (!mem_.contains(a, sizeof(T))) { fault("store access fault", di.pc, a); return false; }
  std::memcpy(mem_.ptr(a), &v, sizeof(T));
  if (marker_ && a == marker_) di.marker = (uint8_t)v;
  if (tohost_ && a == tohost_ && ((uint64_t)v & 1)) { exited_ = true; exit_code_ = (int)((uint64_t)v >> 1); }
  // Any store to a reserved granule breaks the reservation (single hart: only our own stores).
  if (resv_valid_ && (a & ~63ull) == (resv_addr_ & ~63ull)) resv_valid_ = false;
  return true;
}

uint64_t Iss::read_csr(uint16_t c) {
  switch (c) {
    case 0x001: return fcsr_ & 0x1f;
    case 0x002: return (fcsr_ >> 5) & 7;
    case 0x003: return fcsr_ & 0xff;
    case 0xc00: case 0xc01: case 0xc02: case 0xb00: case 0xb02: return wr(instret_);
    case 0xc80: case 0xc81: case 0xc82: case 0xb80: case 0xb82: return xlen_ == 32 ? (instret_ >> 32) : 0;
    case 0xf14: return 0;
    default: {
      auto it = csr_.find(c);
      return it == csr_.end() ? 0 : it->second;
    }
  }
}

void Iss::write_csr(uint16_t c, uint64_t v) {
  switch (c) {
    case 0x001: fcsr_ = (fcsr_ & ~0x1fu) | (uint32_t)(v & 0x1f); break;
    case 0x002: fcsr_ = (fcsr_ & ~0xe0u) | (uint32_t)((v & 7) << 5); break;
    case 0x003: fcsr_ = (uint32_t)(v & 0xff); break;
    default: csr_[c] = wr(v); break;
  }
}

bool Iss::step(DynInst& di) {
  if (exited_) return false;
  const Decoded* d = fetch_decode(pc_);
  if (!d) { fault("illegal instruction", pc_, pc_); return false; }
  di = DynInst{};
  di.seq = instret_;
  di.pc = pc_;
  di.d = d;
  uint64_t npc = wr(pc_ + d->len);
  const uint64_t a = x_[d->rs1], b = x_[d->rs2];
  const unsigned shm = (unsigned)xlen_ - 1;
  const bool rv64 = xlen_ == 64;
  auto setx = [&](uint64_t v) { if (d->rd) x_[d->rd] = wr(v); };
  auto setf = [&](uint64_t v) { f_[d->rd] = v; };
  auto ea = [&]() { return wr(a + (uint64_t)d->imm); };
  const int rm = d->rm == 7 ? (int)((fcsr_ >> 5) & 7) : d->rm;

  switch (d->op) {
    case Op::LUI: setx((uint64_t)d->imm); break;
    case Op::AUIPC: setx(pc_ + (uint64_t)d->imm); break;
    case Op::JAL: setx(pc_ + d->len); npc = wr(pc_ + (uint64_t)d->imm); di.taken = true; break;
    case Op::JALR: { const uint64_t t = wr(a + (uint64_t)d->imm) & ~1ull; setx(pc_ + d->len); npc = t;
                     di.taken = true; break; }
    case Op::BEQ: di.taken = a == b; break;
    case Op::BNE: di.taken = a != b; break;
    case Op::BLT: di.taken = sx(a) < sx(b); break;
    case Op::BGE: di.taken = sx(a) >= sx(b); break;
    case Op::BLTU: di.taken = a < b; break;
    case Op::BGEU: di.taken = a >= b; break;
    case Op::LB: { int8_t v; if (!ld(ea(), v, di)) return false; setx((uint64_t)(int64_t)v); break; }
    case Op::LH: { int16_t v; if (!ld(ea(), v, di)) return false; setx((uint64_t)(int64_t)v); break; }
    case Op::LW: { int32_t v; if (!ld(ea(), v, di)) return false; setx((uint64_t)(int64_t)v); break; }
    case Op::LD: { uint64_t v; if (!ld(ea(), v, di)) return false; setx(v); break; }
    case Op::LBU: { uint8_t v; if (!ld(ea(), v, di)) return false; setx(v); break; }
    case Op::LHU: { uint16_t v; if (!ld(ea(), v, di)) return false; setx(v); break; }
    case Op::LWU: { uint32_t v; if (!ld(ea(), v, di)) return false; setx(v); break; }
    case Op::SB: if (!st(ea(), (uint8_t)b, di)) return false; break;
    case Op::SH: if (!st(ea(), (uint16_t)b, di)) return false; break;
    case Op::SW: if (!st(ea(), (uint32_t)b, di)) return false; break;
    case Op::SD: if (!st(ea(), (uint64_t)b, di)) return false; break;
    case Op::ADDI: setx(a + (uint64_t)d->imm); break;
    case Op::SLTI: setx(sx(a) < d->imm); break;
    case Op::SLTIU: setx(a < wr((uint64_t)d->imm)); break;
    case Op::XORI: setx(a ^ (uint64_t)d->imm); break;
    case Op::ORI: setx(a | (uint64_t)d->imm); break;
    case Op::ANDI: setx(a & (uint64_t)d->imm); break;
    case Op::SLLI: setx(a << (d->imm & shm)); break;
    case Op::SRLI: setx(a >> (d->imm & shm)); break;
    case Op::SRAI: setx((uint64_t)(sx(a) >> (d->imm & shm))); break;
    case Op::ADD: setx(a + b); break;
    case Op::SUB: setx(a - b); break;
    case Op::SLL: setx(a << (b & shm)); break;
    case Op::SLT: setx(sx(a) < sx(b)); break;
    case Op::SLTU: setx(a < b); break;
    case Op::XOR: setx(a ^ b); break;
    case Op::SRL: setx(a >> (b & shm)); break;
    case Op::SRA: setx((uint64_t)(sx(a) >> (b & shm))); break;
    case Op::OR: setx(a | b); break;
    case Op::AND: setx(a & b); break;
    case Op::ADDIW: setx((uint64_t)sext32(a + (uint64_t)d->imm)); break;
    case Op::SLLIW: setx((uint64_t)sext32(a << (d->imm & 31))); break;
    case Op::SRLIW: setx((uint64_t)sext32(zext32(a) >> (d->imm & 31))); break;
    case Op::SRAIW: setx((uint64_t)(int64_t)((int32_t)a >> (d->imm & 31))); break;
    case Op::ADDW: setx((uint64_t)sext32(a + b)); break;
    case Op::SUBW: setx((uint64_t)sext32(a - b)); break;
    case Op::SLLW: setx((uint64_t)sext32(a << (b & 31))); break;
    case Op::SRLW: setx((uint64_t)sext32(zext32(a) >> (b & 31))); break;
    case Op::SRAW: setx((uint64_t)(int64_t)((int32_t)a >> (b & 31))); break;
    case Op::FENCE: case Op::FENCE_I: case Op::SFENCE_VMA: case Op::WFI: break;
    case Op::ECALL: {
      const uint64_t n = x_[17];
      if (n == 93) { exited_ = true; exit_code_ = (int)x_[10]; }
      else if (n == 64) {
        for (uint64_t i = 0; i < x_[12]; i++)
          if (mem_.contains(x_[11] + i, 1)) out_.push_back((char)*mem_.ptr(x_[11] + i));
        x_[10] = x_[12];
      } else x_[10] = wr((uint64_t)-1);
      break;
    }
    case Op::EBREAK: fault("ebreak", pc_); return false;
    case Op::MRET: npc = read_csr(0x341); break;
    case Op::CSRRW: case Op::CSRRS: case Op::CSRRC: case Op::CSRRWI: case Op::CSRRSI: case Op::CSRRCI: {
      const uint64_t old = read_csr(d->csr);
      const bool imm = d->op == Op::CSRRWI || d->op == Op::CSRRSI || d->op == Op::CSRRCI;
      const uint64_t src = imm ? (uint64_t)d->imm : a;
      const bool do_write = (d->op == Op::CSRRW || d->op == Op::CSRRWI) || (imm ? d->imm != 0 : d->rs1 != 0);
      if (do_write) {
        if (d->op == Op::CSRRW || d->op == Op::CSRRWI) write_csr(d->csr, src);
        else if (d->op == Op::CSRRS || d->op == Op::CSRRSI) write_csr(d->csr, old | src);
        else write_csr(d->csr, old & ~src);
      }
      setx(old);
      break;
    }
    // ---------------------------------------------------------------- M
    case Op::MUL: setx(a * b); break;
    case Op::MULH:
      if (rv64) setx((uint64_t)(((__int128)(int64_t)a * (__int128)(int64_t)b) >> 64));
      else setx((uint64_t)(((int64_t)(int32_t)a * (int64_t)(int32_t)b) >> 32));
      break;
    case Op::MULHSU:
      if (rv64) setx((uint64_t)(((__int128)(int64_t)a * (__int128)(unsigned __int128)b) >> 64));
      else setx((uint64_t)(((int64_t)(int32_t)a * (int64_t)(uint32_t)b) >> 32));
      break;
    case Op::MULHU:
      if (rv64) setx((uint64_t)(((unsigned __int128)a * (unsigned __int128)b) >> 64));
      else setx((zext32(a) * zext32(b)) >> 32);
      break;
    case Op::MULW: setx((uint64_t)sext32(a * b)); break;
    case Op::DIV: case Op::DIVU: case Op::REM: case Op::REMU: {
      const bool sgn = d->op == Op::DIV || d->op == Op::REM, rem = d->op == Op::REM || d->op == Op::REMU;
      uint64_t res;
      if (rv64) {
        if (sgn) {
          const int64_t x = (int64_t)a, y = (int64_t)b;
          if (y == 0) res = rem ? (uint64_t)x : ~0ull;
          else if (x == INT64_MIN && y == -1) res = rem ? 0 : (uint64_t)x;
          else res = rem ? (uint64_t)(x % y) : (uint64_t)(x / y);
        } else res = b == 0 ? (rem ? a : ~0ull) : (rem ? a % b : a / b);
        const uint64_t mag = (sgn && (int64_t)a < 0) ? 0 - a : a;
        di.lat_hint = (uint8_t)(64 - std::countl_zero(mag | 1));
      } else {
        if (sgn) {
          const int32_t x = (int32_t)a, y = (int32_t)b;
          if (y == 0) res = rem ? (uint64_t)(int64_t)x : ~0ull;
          else if (x == INT32_MIN && y == -1) res = rem ? 0 : (uint64_t)(int64_t)x;
          else res = rem ? (uint64_t)(int64_t)(x % y) : (uint64_t)(int64_t)(x / y);
        } else {
          const uint32_t x = (uint32_t)a, y = (uint32_t)b;
          res = y == 0 ? (rem ? x : ~0ull) : (rem ? x % y : x / y);
        }
        const uint32_t mag = (sgn && (int32_t)a < 0) ? 0u - (uint32_t)a : (uint32_t)a;
        di.lat_hint = (uint8_t)(32 - std::countl_zero(mag | 1));
      }
      setx(res);
      break;
    }
    case Op::DIVW: case Op::DIVUW: case Op::REMW: case Op::REMUW: {
      const bool sgn = d->op == Op::DIVW || d->op == Op::REMW, rem = d->op == Op::REMW || d->op == Op::REMUW;
      int64_t res;
      if (sgn) {
        const int32_t x = (int32_t)a, y = (int32_t)b;
        if (y == 0) res = rem ? x : -1;
        else if (x == INT32_MIN && y == -1) res = rem ? 0 : x;
        else res = rem ? x % y : x / y;
      } else {
        const uint32_t x = (uint32_t)a, y = (uint32_t)b;
        res = y == 0 ? (rem ? (int32_t)x : -1) : (int32_t)(rem ? x % y : x / y);
      }
      const uint32_t mag = (sgn && (int32_t)a < 0) ? 0u - (uint32_t)a : (uint32_t)a;
      di.lat_hint = (uint8_t)(32 - std::countl_zero(mag | 1));
      setx((uint64_t)sext32((uint64_t)res));
      break;
    }
    // ---------------------------------------------------------------- A
    case Op::LR: {
      di.addr = a;
      if (d->msize == 4) { int32_t v; if (!ld(a, v, di)) return false; setx((uint64_t)(int64_t)v); }
      else { uint64_t v; if (!ld(a, v, di)) return false; setx(v); }
      resv_addr_ = a; resv_valid_ = true;
      break;
    }
    case Op::SC: {
      di.addr = a;
      const bool ok = resv_valid_ && resv_addr_ == a;
      resv_valid_ = false;
      if (ok) {
        if (d->msize == 4) { if (!st(a, (uint32_t)b, di)) return false; }
        else if (!st(a, (uint64_t)b, di)) return false;
      }
      setx(ok ? 0 : 1);
      break;
    }
    case Op::AMOSWAP: case Op::AMOADD: case Op::AMOXOR: case Op::AMOAND: case Op::AMOOR: case Op::AMOMIN:
    case Op::AMOMAX: case Op::AMOMINU: case Op::AMOMAXU: {
      uint64_t old;
      if (d->msize == 4) { int32_t v; if (!ld(a, v, di)) return false; old = (uint64_t)(int64_t)v; }
      else { uint64_t v; if (!ld(a, v, di)) return false; old = v; }
      const bool w = d->msize == 4;
      const int64_t so = w ? sext32(old) : (int64_t)old, sb = w ? sext32(b) : (int64_t)b;
      const uint64_t uo = w ? zext32(old) : old, ub = w ? zext32(b) : b;
      uint64_t nv = 0;
      switch (d->op) {
        case Op::AMOSWAP: nv = b; break;
        case Op::AMOADD: nv = old + b; break;
        case Op::AMOXOR: nv = old ^ b; break;
        case Op::AMOAND: nv = old & b; break;
        case Op::AMOOR: nv = old | b; break;
        case Op::AMOMIN: nv = so < sb ? old : b; break;
        case Op::AMOMAX: nv = so > sb ? old : b; break;
        case Op::AMOMINU: nv = uo < ub ? old : b; break;
        case Op::AMOMAXU: nv = uo > ub ? old : b; break;
        default: break;
      }
      if (w) { if (!st(a, (uint32_t)nv, di)) return false; }
      else if (!st(a, nv, di)) return false;
      setx(old);
      break;
    }
    // ---------------------------------------------------------------- F / D
    case Op::FL:
      if (d->msize == 4) { uint32_t v; if (!ld(ea(), v, di)) return false; setf(box_s_bits(v)); }
      else { uint64_t v; if (!ld(ea(), v, di)) return false; setf(v); }
      break;
    case Op::FS:
      if (d->msize == 4) { if (!st(ea(), (uint32_t)f_[d->rs2], di)) return false; }
      else if (!st(ea(), f_[d->rs2], di)) return false;
      break;
    case Op::FMADD: case Op::FMSUB: case Op::FNMSUB: case Op::FNMADD: case Op::FADD: case Op::FSUB:
    case Op::FMUL: case Op::FDIV: case Op::FSQRT: case Op::FMIN: case Op::FMAX: {
      if (d->fmt == 0) {
        const float x = unbox_s(f_[d->rs1]), y = unbox_s(f_[d->rs2]), z = unbox_s(f_[d->rs3]);
        float r = 0;
        switch (d->op) {
          case Op::FMADD: r = std::fmaf(x, y, z); break;
          case Op::FMSUB: r = std::fmaf(x, y, -z); break;
          case Op::FNMSUB: r = std::fmaf(-x, y, z); break;
          case Op::FNMADD: r = std::fmaf(-x, y, -z); break;
          case Op::FADD: r = x + y; break;
          case Op::FSUB: r = x - y; break;
          case Op::FMUL: r = x * y; break;
          case Op::FDIV: r = x / y; break;
          case Op::FSQRT: r = std::sqrt(x); break;
          case Op::FMIN: r = fminmax(x, y, false); break;
          case Op::FMAX: r = fminmax(x, y, true); break;
          default: break;
        }
        setf(box_s(r));
      } else {
        const double x = as_d(f_[d->rs1]), y = as_d(f_[d->rs2]), z = as_d(f_[d->rs3]);
        double r = 0;
        switch (d->op) {
          case Op::FMADD: r = std::fma(x, y, z); break;
          case Op::FMSUB: r = std::fma(x, y, -z); break;
          case Op::FNMSUB: r = std::fma(-x, y, z); break;
          case Op::FNMADD: r = std::fma(-x, y, -z); break;
          case Op::FADD: r = x + y; break;
          case Op::FSUB: r = x - y; break;
          case Op::FMUL: r = x * y; break;
          case Op::FDIV: r = x / y; break;
          case Op::FSQRT: r = std::sqrt(x); break;
          case Op::FMIN: r = fminmax(x, y, false); break;
          case Op::FMAX: r = fminmax(x, y, true); break;
          default: break;
        }
        setf(d_bits(r));
      }
      break;
    }
    case Op::FSGNJ: case Op::FSGNJN: case Op::FSGNJX: {
      if (d->fmt == 0) {
        const uint32_t x = unbox_s_bits(f_[d->rs1]), y = unbox_s_bits(f_[d->rs2]);
        uint32_t s = d->op == Op::FSGNJ ? (y & 0x80000000u) : d->op == Op::FSGNJN ? (~y & 0x80000000u)
                                                                                 : ((x ^ y) & 0x80000000u);
        setf(box_s_bits((x & 0x7fffffffu) | s));
      } else {
        const uint64_t x = f_[d->rs1], y = f_[d->rs2], m = 1ull << 63;
        const uint64_t s = d->op == Op::FSGNJ ? (y & m) : d->op == Op::FSGNJN ? (~y & m) : ((x ^ y) & m);
        setf((x & ~m) | s);
      }
      break;
    }
    case Op::FEQ: case Op::FLT: case Op::FLE: {
      bool r;
      if (d->fmt == 0) {
        const float x = unbox_s(f_[d->rs1]), y = unbox_s(f_[d->rs2]);
        r = d->op == Op::FEQ ? x == y : d->op == Op::FLT ? x < y : x <= y;
      } else {
        const double x = as_d(f_[d->rs1]), y = as_d(f_[d->rs2]);
        r = d->op == Op::FEQ ? x == y : d->op == Op::FLT ? x < y : x <= y;
      }
      setx(r);
      break;
    }
    case Op::FCLASS:
      if (d->fmt == 0) { const float x = unbox_s(f_[d->rs1]); setx(fclass(x, std::signbit(x))); }
      else { const double x = as_d(f_[d->rs1]); setx(fclass(x, std::signbit(x))); }
      break;
    case Op::FCVT_W: case Op::FCVT_WU: case Op::FCVT_L: case Op::FCVT_LU: {
      const double v = d->fmt == 0 ? (double)unbox_s(f_[d->rs1]) : as_d(f_[d->rs1]);
      uint64_t r;
      switch (d->op) {
        case Op::FCVT_W: r = (uint64_t)(int64_t)cvt_to_int<int32_t>(v, rm); break;
        case Op::FCVT_WU: r = (uint64_t)(int64_t)(int32_t)cvt_to_int<uint32_t>(v, rm); break;
        case Op::FCVT_L: r = (uint64_t)cvt_to_int<int64_t>(v, rm); break;
        default: r = cvt_to_int<uint64_t>(v, rm); break;
      }
      setx(r);
      break;
    }
    case Op::FCVT_F_W: case Op::FCVT_F_WU: case Op::FCVT_F_L: case Op::FCVT_F_LU: {
      if (d->fmt == 0) {
        float r = d->op == Op::FCVT_F_W ? (float)(int32_t)a : d->op == Op::FCVT_F_WU ? (float)(uint32_t)a
                  : d->op == Op::FCVT_F_L ? (float)(int64_t)a : (float)a;
        setf(box_s(r));
      } else {
        double r = d->op == Op::FCVT_F_W ? (double)(int32_t)a : d->op == Op::FCVT_F_WU ? (double)(uint32_t)a
                   : d->op == Op::FCVT_F_L ? (double)(int64_t)a : (double)a;
        setf(d_bits(r));
      }
      break;
    }
    case Op::FCVT_S_D: setf(box_s((float)as_d(f_[d->rs1]))); break;
    case Op::FCVT_D_S: setf(d_bits((double)unbox_s(f_[d->rs1]))); break;
    case Op::FMV_X: setx(d->fmt == 0 ? (uint64_t)sext32(f_[d->rs1]) : f_[d->rs1]); break;
    case Op::FMV_F: setf(d->fmt == 0 ? box_s_bits((uint32_t)a) : a); break;
    // ---------------------------------------------------------------- Zba / Zbb / Zbs / Zicond
    case Op::SH1ADD: setx((a << 1) + b); break;
    case Op::SH2ADD: setx((a << 2) + b); break;
    case Op::SH3ADD: setx((a << 3) + b); break;
    case Op::ADD_UW: setx(zext32(a) + b); break;
    case Op::SH1ADD_UW: setx((zext32(a) << 1) + b); break;
    case Op::SH2ADD_UW: setx((zext32(a) << 2) + b); break;
    case Op::SH3ADD_UW: setx((zext32(a) << 3) + b); break;
    case Op::SLLI_UW: setx(zext32(a) << (d->imm & 63)); break;
    case Op::ANDN: setx(a & ~b); break;
    case Op::ORN: setx(a | ~b); break;
    case Op::XNOR: setx(~(a ^ b)); break;
    case Op::CLZ: setx(rv64 ? (uint64_t)std::countl_zero(a) : (uint64_t)std::countl_zero((uint32_t)a)); break;
    case Op::CTZ: setx(rv64 ? (uint64_t)std::countr_zero(a) : (uint64_t)std::countr_zero((uint32_t)a)); break;
    case Op::CPOP: setx((uint64_t)std::popcount(a)); break;
    case Op::CLZW: setx((uint64_t)std::countl_zero((uint32_t)a)); break;
    case Op::CTZW: setx((uint64_t)std::countr_zero((uint32_t)a)); break;
    case Op::CPOPW: setx((uint64_t)std::popcount((uint32_t)a)); break;
    case Op::MAX: setx(sx(a) > sx(b) ? a : b); break;
    case Op::MAXU: setx(a > b ? a : b); break;
    case Op::MIN: setx(sx(a) < sx(b) ? a : b); break;
    case Op::MINU: setx(a < b ? a : b); break;
    case Op::SEXT_B: setx((uint64_t)(int64_t)(int8_t)a); break;
    case Op::SEXT_H: setx((uint64_t)(int64_t)(int16_t)a); break;
    case Op::ZEXT_H: setx(a & 0xffff); break;
    case Op::ROL: setx(rv64 ? std::rotl(a, (int)(b & 63)) : std::rotl((uint32_t)a, (int)(b & 31))); break;
    case Op::ROR: setx(rv64 ? std::rotr(a, (int)(b & 63)) : std::rotr((uint32_t)a, (int)(b & 31))); break;
    case Op::RORI: setx(rv64 ? std::rotr(a, (int)(d->imm & 63)) : std::rotr((uint32_t)a, (int)(d->imm & 31))); break;
    case Op::ROLW: setx((uint64_t)sext32(std::rotl((uint32_t)a, (int)(b & 31)))); break;
    case Op::RORW: setx((uint64_t)sext32(std::rotr((uint32_t)a, (int)(b & 31)))); break;
    case Op::RORIW: setx((uint64_t)sext32(std::rotr((uint32_t)a, (int)(d->imm & 31)))); break;
    case Op::ORC_B: {
      uint64_t r = 0;
      for (int i = 0; i < xlen_ / 8; i++) if ((a >> (8 * i)) & 0xff) r |= 0xffull << (8 * i);
      setx(r);
      break;
    }
    case Op::REV8: setx(rv64 ? std::byteswap(a) : (uint64_t)std::byteswap((uint32_t)a)); break;
    case Op::BCLR: setx(a & ~(1ull << (b & shm))); break;
    case Op::BCLRI: setx(a & ~(1ull << (d->imm & shm))); break;
    case Op::BEXT: setx((a >> (b & shm)) & 1); break;
    case Op::BEXTI: setx((a >> (d->imm & shm)) & 1); break;
    case Op::BINV: setx(a ^ (1ull << (b & shm))); break;
    case Op::BINVI: setx(a ^ (1ull << (d->imm & shm))); break;
    case Op::BSET: setx(a | (1ull << (b & shm))); break;
    case Op::BSETI: setx(a | (1ull << (d->imm & shm))); break;
    case Op::CZERO_EQZ: setx(b == 0 ? 0 : a); break;
    case Op::CZERO_NEZ: setx(b != 0 ? 0 : a); break;
    default: fault("unimplemented instruction", pc_, d->raw); return false;
  }
  if (d->cls == Cls::BR && di.taken) npc = wr(pc_ + (uint64_t)d->imm);
  x_[0] = 0;
  di.next_pc = npc;
  pc_ = npc;
  instret_++;
  return true;
}

}  // namespace tg
