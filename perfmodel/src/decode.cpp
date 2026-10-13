// tgsim: RV32/RV64 IMAFDC + Zicsr + Zba/Zbb/Zbs/Zicond decoder, including RVC expansion.
#include "isa.h"

namespace tg {

namespace {

inline uint32_t bits(uint32_t v, int hi, int lo) { return (v >> lo) & ((1u << (hi - lo + 1)) - 1); }
inline uint32_t bit(uint32_t v, int b) { return (v >> b) & 1u; }
inline int64_t sext(uint64_t v, int nbits) {
  const uint64_t m = 1ull << (nbits - 1);
  v &= (nbits == 64) ? ~0ull : ((1ull << nbits) - 1);
  return (int64_t)((v ^ m) - m);
}

// 32-bit encoders used by the RVC expander.
uint32_t enc_r(uint32_t op, uint32_t rd, uint32_t f3, uint32_t rs1, uint32_t rs2, uint32_t f7) {
  return op | (rd << 7) | (f3 << 12) | (rs1 << 15) | (rs2 << 20) | (f7 << 25);
}
uint32_t enc_i(uint32_t op, uint32_t rd, uint32_t f3, uint32_t rs1, int32_t imm) {
  return op | (rd << 7) | (f3 << 12) | (rs1 << 15) | ((uint32_t)(imm & 0xfff) << 20);
}
uint32_t enc_s(uint32_t op, uint32_t f3, uint32_t rs1, uint32_t rs2, int32_t imm) {
  const uint32_t u = (uint32_t)imm;
  return op | ((u & 0x1f) << 7) | (f3 << 12) | (rs1 << 15) | (rs2 << 20) | (((u >> 5) & 0x7f) << 25);
}
uint32_t enc_b(uint32_t f3, uint32_t rs1, uint32_t rs2, int32_t imm) {
  const uint32_t u = (uint32_t)imm;
  return 0x63 | (bit(u, 11) << 7) | (bits(u, 4, 1) << 8) | (f3 << 12) | (rs1 << 15) | (rs2 << 20) |
         (bits(u, 10, 5) << 25) | (bit(u, 12) << 31);
}
uint32_t enc_u(uint32_t op, uint32_t rd, int32_t imm20) {
  return op | (rd << 7) | (((uint32_t)imm20 & 0xfffff) << 12);
}
uint32_t enc_j(uint32_t rd, int32_t imm) {
  const uint32_t u = (uint32_t)imm;
  return 0x6f | (rd << 7) | (bits(u, 19, 12) << 12) | (bit(u, 11) << 20) | (bits(u, 10, 1) << 21) |
         (bit(u, 20) << 31);
}

}  // namespace

uint32_t rvc_expand(uint16_t c16, int xlen) {
  const uint32_t c = c16;
  const uint32_t q = c & 3, f3 = bits(c, 15, 13);
  const uint32_t rdp = 8 + bits(c, 4, 2), rs1p = 8 + bits(c, 9, 7);
  const uint32_t rd = bits(c, 11, 7), rs2 = bits(c, 6, 2);
  if (c == 0) return 0;
  if (q == 0) {
    switch (f3) {
      case 0: {  // C.ADDI4SPN
        const uint32_t imm = (bits(c, 12, 11) << 4) | (bits(c, 10, 7) << 6) | (bit(c, 6) << 2) | (bit(c, 5) << 3);
        if (!imm) return 0;
        return enc_i(0x13, rdp, 0, 2, (int32_t)imm);
      }
      case 1: {  // C.FLD
        const uint32_t imm = (bits(c, 12, 10) << 3) | (bits(c, 6, 5) << 6);
        return enc_i(0x07, rdp, 3, rs1p, (int32_t)imm);
      }
      case 2: {  // C.LW
        const uint32_t imm = (bits(c, 12, 10) << 3) | (bit(c, 6) << 2) | (bit(c, 5) << 6);
        return enc_i(0x03, rdp, 2, rs1p, (int32_t)imm);
      }
      case 3: {
        if (xlen == 32) {  // C.FLW
          const uint32_t imm = (bits(c, 12, 10) << 3) | (bit(c, 6) << 2) | (bit(c, 5) << 6);
          return enc_i(0x07, rdp, 2, rs1p, (int32_t)imm);
        }
        const uint32_t imm = (bits(c, 12, 10) << 3) | (bits(c, 6, 5) << 6);  // C.LD
        return enc_i(0x03, rdp, 3, rs1p, (int32_t)imm);
      }
      case 5: {  // C.FSD
        const uint32_t imm = (bits(c, 12, 10) << 3) | (bits(c, 6, 5) << 6);
        return enc_s(0x27, 3, rs1p, rdp, (int32_t)imm);
      }
      case 6: {  // C.SW
        const uint32_t imm = (bits(c, 12, 10) << 3) | (bit(c, 6) << 2) | (bit(c, 5) << 6);
        return enc_s(0x23, 2, rs1p, rdp, (int32_t)imm);
      }
      case 7: {
        if (xlen == 32) {  // C.FSW
          const uint32_t imm = (bits(c, 12, 10) << 3) | (bit(c, 6) << 2) | (bit(c, 5) << 6);
          return enc_s(0x27, 2, rs1p, rdp, (int32_t)imm);
        }
        const uint32_t imm = (bits(c, 12, 10) << 3) | (bits(c, 6, 5) << 6);  // C.SD
        return enc_s(0x23, 3, rs1p, rdp, (int32_t)imm);
      }
      default: return 0;
    }
  }
  if (q == 1) {
    const int32_t imm6 = (int32_t)sext((bit(c, 12) << 5) | bits(c, 6, 2), 6);
    switch (f3) {
      case 0: return enc_i(0x13, rd, 0, rd, imm6);  // C.ADDI / C.NOP
      case 1: {
        if (xlen == 32) {  // C.JAL
          const uint32_t u = (bit(c, 12) << 11) | (bit(c, 11) << 4) | (bits(c, 10, 9) << 8) | (bit(c, 8) << 10) |
                             (bit(c, 7) << 6) | (bit(c, 6) << 7) | (bits(c, 5, 3) << 1) | (bit(c, 2) << 5);
          return enc_j(1, (int32_t)sext(u, 12));
        }
        if (rd == 0) return 0;
        return enc_i(0x1b, rd, 0, rd, imm6);  // C.ADDIW
      }
      case 2: return enc_i(0x13, rd, 0, 0, imm6);  // C.LI
      case 3: {
        if (rd == 2) {  // C.ADDI16SP
          const uint32_t u = (bit(c, 12) << 9) | (bit(c, 6) << 4) | (bit(c, 5) << 6) | (bits(c, 4, 3) << 7) |
                             (bit(c, 2) << 5);
          if (!u) return 0;
          return enc_i(0x13, 2, 0, 2, (int32_t)sext(u, 10));
        }
        const int32_t nz = (int32_t)sext((bit(c, 12) << 5) | bits(c, 6, 2), 6);  // C.LUI
        if (!nz) return 0;
        return enc_u(0x37, rd, nz);
      }
      case 4: {
        const uint32_t f2 = bits(c, 11, 10);
        const uint32_t sh = (bit(c, 12) << 5) | bits(c, 6, 2);
        if (f2 == 0) return enc_i(0x13, rs1p, 5, rs1p, (int32_t)sh);            // C.SRLI
        if (f2 == 1) return enc_i(0x13, rs1p, 5, rs1p, (int32_t)(sh | 0x400));  // C.SRAI
        if (f2 == 2) return enc_i(0x13, rs1p, 7, rs1p, imm6);                   // C.ANDI
        const uint32_t f = bits(c, 6, 5);
        const uint32_t r2 = 8 + bits(c, 4, 2);
        if (!bit(c, 12)) {
          if (f == 0) return enc_r(0x33, rs1p, 0, rs1p, r2, 0x20);  // C.SUB
          if (f == 1) return enc_r(0x33, rs1p, 4, rs1p, r2, 0);     // C.XOR
          if (f == 2) return enc_r(0x33, rs1p, 6, rs1p, r2, 0);     // C.OR
          return enc_r(0x33, rs1p, 7, rs1p, r2, 0);                 // C.AND
        }
        if (xlen == 64) {
          if (f == 0) return enc_r(0x3b, rs1p, 0, rs1p, r2, 0x20);  // C.SUBW
          if (f == 1) return enc_r(0x3b, rs1p, 0, rs1p, r2, 0);     // C.ADDW
        }
        return 0;
      }
      case 5: {  // C.J
        const uint32_t u = (bit(c, 12) << 11) | (bit(c, 11) << 4) | (bits(c, 10, 9) << 8) | (bit(c, 8) << 10) |
                           (bit(c, 7) << 6) | (bit(c, 6) << 7) | (bits(c, 5, 3) << 1) | (bit(c, 2) << 5);
        return enc_j(0, (int32_t)sext(u, 12));
      }
      case 6:
      case 7: {  // C.BEQZ / C.BNEZ
        const uint32_t u = (bit(c, 12) << 8) | (bits(c, 11, 10) << 3) | (bits(c, 6, 5) << 6) | (bits(c, 4, 3) << 1) |
                           (bit(c, 2) << 5);
        return enc_b(f3 == 6 ? 0 : 1, rs1p, 0, (int32_t)sext(u, 9));
      }
    }
    return 0;
  }
  if (q == 2) {
    switch (f3) {
      case 0: {  // C.SLLI
        const uint32_t sh = (bit(c, 12) << 5) | bits(c, 6, 2);
        return enc_i(0x13, rd, 1, rd, (int32_t)sh);
      }
      case 1: {  // C.FLDSP
        const uint32_t imm = (bit(c, 12) << 5) | (bits(c, 6, 5) << 3) | (bits(c, 4, 2) << 6);
        return enc_i(0x07, rd, 3, 2, (int32_t)imm);
      }
      case 2: {  // C.LWSP
        if (rd == 0) return 0;
        const uint32_t imm = (bit(c, 12) << 5) | (bits(c, 6, 4) << 2) | (bits(c, 3, 2) << 6);
        return enc_i(0x03, rd, 2, 2, (int32_t)imm);
      }
      case 3: {
        if (xlen == 32) {  // C.FLWSP
          const uint32_t imm = (bit(c, 12) << 5) | (bits(c, 6, 4) << 2) | (bits(c, 3, 2) << 6);
          return enc_i(0x07, rd, 2, 2, (int32_t)imm);
        }
        if (rd == 0) return 0;  // C.LDSP
        const uint32_t imm = (bit(c, 12) << 5) | (bits(c, 6, 5) << 3) | (bits(c, 4, 2) << 6);
        return enc_i(0x03, rd, 3, 2, (int32_t)imm);
      }
      case 4: {
        if (!bit(c, 12)) {
          if (rs2 == 0) {  // C.JR
            if (rd == 0) return 0;
            return enc_i(0x67, 0, 0, rd, 0);
          }
          return enc_r(0x33, rd, 0, 0, rs2, 0);  // C.MV
        }
        if (rd == 0 && rs2 == 0) return 0x00100073;      // C.EBREAK
        if (rs2 == 0) return enc_i(0x67, 1, 0, rd, 0);   // C.JALR
        return enc_r(0x33, rd, 0, rd, rs2, 0);           // C.ADD
      }
      case 5: {  // C.FSDSP
        const uint32_t imm = (bits(c, 12, 10) << 3) | (bits(c, 9, 7) << 6);
        return enc_s(0x27, 3, 2, rs2, (int32_t)imm);
      }
      case 6: {  // C.SWSP
        const uint32_t imm = (bits(c, 12, 9) << 2) | (bits(c, 8, 7) << 6);
        return enc_s(0x23, 2, 2, rs2, (int32_t)imm);
      }
      case 7: {
        if (xlen == 32) {  // C.FSWSP
          const uint32_t imm = (bits(c, 12, 9) << 2) | (bits(c, 8, 7) << 6);
          return enc_s(0x27, 2, 2, rs2, (int32_t)imm);
        }
        const uint32_t imm = (bits(c, 12, 10) << 3) | (bits(c, 9, 7) << 6);  // C.SDSP
        return enc_s(0x23, 3, 2, rs2, (int32_t)imm);
      }
    }
  }
  return 0;
}

namespace {

void set_int_rrr(Decoded& d, Op op, uint32_t rd, uint32_t rs1, uint32_t rs2) {
  d.op = op; d.rd = (uint8_t)rd; d.rs1 = (uint8_t)rs1; d.rs2 = (uint8_t)rs2;
  d.rd_k = RK_INT; d.rs1_k = RK_INT; d.rs2_k = RK_INT;
}
void set_int_rri(Decoded& d, Op op, uint32_t rd, uint32_t rs1, int64_t imm) {
  d.op = op; d.rd = (uint8_t)rd; d.rs1 = (uint8_t)rs1; d.imm = imm;
  d.rd_k = RK_INT; d.rs1_k = RK_INT;
}

Cls classify(const Decoded& d) {
  switch (d.op) {
    case Op::JAL: return Cls::JAL;
    case Op::JALR: return Cls::JALR;
    case Op::BEQ: case Op::BNE: case Op::BLT: case Op::BGE: case Op::BLTU: case Op::BGEU: return Cls::BR;
    case Op::LB: case Op::LH: case Op::LW: case Op::LD: case Op::LBU: case Op::LHU: case Op::LWU: return Cls::LD;
    case Op::SB: case Op::SH: case Op::SW: case Op::SD: return Cls::ST;
    case Op::FENCE: case Op::FENCE_I: case Op::SFENCE_VMA: return Cls::FENCE;
    case Op::ECALL: case Op::EBREAK: case Op::MRET: case Op::WFI: return Cls::SYS;
    case Op::CSRRW: case Op::CSRRS: case Op::CSRRC: case Op::CSRRWI: case Op::CSRRSI: case Op::CSRRCI: return Cls::CSR;
    case Op::MUL: case Op::MULH: case Op::MULHSU: case Op::MULHU: case Op::MULW: return Cls::MUL;
    case Op::DIV: case Op::DIVU: case Op::REM: case Op::REMU: case Op::DIVW: case Op::DIVUW: case Op::REMW:
    case Op::REMUW: return Cls::DIV;
    case Op::LR: case Op::SC: case Op::AMOSWAP: case Op::AMOADD: case Op::AMOXOR: case Op::AMOAND: case Op::AMOOR:
    case Op::AMOMIN: case Op::AMOMAX: case Op::AMOMINU: case Op::AMOMAXU: return Cls::AMO;
    case Op::FL: return Cls::FLD;
    case Op::FS: return Cls::FST;
    case Op::FMADD: case Op::FMSUB: case Op::FNMSUB: case Op::FNMADD: case Op::FADD: case Op::FSUB:
    case Op::FMUL: return Cls::FMA;
    case Op::FDIV: return Cls::FDIV;
    case Op::FSQRT: return Cls::FSQRT;
    case Op::FSGNJ: case Op::FSGNJN: case Op::FSGNJX: case Op::FMIN: case Op::FMAX: case Op::FCVT_S_D:
    case Op::FCVT_D_S: return Cls::FMISC;
    case Op::FEQ: case Op::FLT: case Op::FLE: case Op::FCLASS: case Op::FCVT_W: case Op::FCVT_WU: case Op::FCVT_L:
    case Op::FCVT_LU: case Op::FMV_X: return Cls::FTOI;
    case Op::FCVT_F_W: case Op::FCVT_F_WU: case Op::FCVT_F_L: case Op::FCVT_F_LU: case Op::FMV_F: return Cls::ITOF;
    case Op::CLZ: case Op::CTZ: case Op::CPOP: case Op::CLZW: case Op::CTZW: case Op::CPOPW: case Op::ORC_B:
    case Op::REV8: return Cls::ALUX;
    default: return Cls::ALU;
  }
}

}  // namespace

bool decode32(uint32_t inst, int xlen, Decoded& d) {
  d = Decoded{};
  d.raw = inst;
  d.len = 4;
  const uint32_t opc = inst & 0x7f, rd = bits(inst, 11, 7), f3 = bits(inst, 14, 12), rs1 = bits(inst, 19, 15),
                 rs2 = bits(inst, 24, 20), f7 = bits(inst, 31, 25);
  const int64_t imm_i = sext(bits(inst, 31, 20), 12);
  const int64_t imm_s = sext((bits(inst, 31, 25) << 5) | bits(inst, 11, 7), 12);
  const int64_t imm_b =
      sext((bit(inst, 31) << 12) | (bit(inst, 7) << 11) | (bits(inst, 30, 25) << 5) | (bits(inst, 11, 8) << 1), 13);
  const int64_t imm_u = sext(inst & 0xfffff000u, 32);
  const int64_t imm_j =
      sext((bit(inst, 31) << 20) | (bits(inst, 19, 12) << 12) | (bit(inst, 20) << 11) | (bits(inst, 30, 21) << 1), 21);
  const bool rv64 = xlen == 64;
  const uint32_t shmask = rv64 ? 0x3f : 0x1f;
  const uint32_t f6 = bits(inst, 31, 26);

  switch (opc) {
    case 0x37: d.op = Op::LUI; d.rd = (uint8_t)rd; d.rd_k = RK_INT; d.imm = imm_u; break;
    case 0x17: d.op = Op::AUIPC; d.rd = (uint8_t)rd; d.rd_k = RK_INT; d.imm = imm_u; break;
    case 0x6f: d.op = Op::JAL; d.rd = (uint8_t)rd; d.rd_k = RK_INT; d.imm = imm_j; break;
    case 0x67:
      if (f3 != 0) return false;
      set_int_rri(d, Op::JALR, rd, rs1, imm_i);
      break;
    case 0x63: {
      static const Op m[8] = {Op::BEQ, Op::BNE, Op::ILLEGAL, Op::ILLEGAL, Op::BLT, Op::BGE, Op::BLTU, Op::BGEU};
      if (m[f3] == Op::ILLEGAL) return false;
      d.op = m[f3]; d.rs1 = (uint8_t)rs1; d.rs2 = (uint8_t)rs2; d.rs1_k = RK_INT; d.rs2_k = RK_INT; d.imm = imm_b;
      break;
    }
    case 0x03: {
      static const Op m[8] = {Op::LB, Op::LH, Op::LW, Op::LD, Op::LBU, Op::LHU, Op::LWU, Op::ILLEGAL};
      static const uint8_t sz[8] = {1, 2, 4, 8, 1, 2, 4, 0};
      if (m[f3] == Op::ILLEGAL || (!rv64 && (f3 == 3 || f3 == 6))) return false;
      set_int_rri(d, m[f3], rd, rs1, imm_i);
      d.msize = sz[f3]; d.msigned = f3 < 4;
      break;
    }
    case 0x23: {
      static const Op m[4] = {Op::SB, Op::SH, Op::SW, Op::SD};
      if (f3 > 3 || (!rv64 && f3 == 3)) return false;
      d.op = m[f3]; d.rs1 = (uint8_t)rs1; d.rs2 = (uint8_t)rs2; d.rs1_k = RK_INT; d.rs2_k = RK_INT; d.imm = imm_s;
      d.msize = (uint8_t)(1u << f3);
      break;
    }
    case 0x13: {
      const uint32_t sh = bits(inst, 25, 20) & shmask;
      switch (f3) {
        case 0: set_int_rri(d, Op::ADDI, rd, rs1, imm_i); break;
        case 2: set_int_rri(d, Op::SLTI, rd, rs1, imm_i); break;
        case 3: set_int_rri(d, Op::SLTIU, rd, rs1, imm_i); break;
        case 4: set_int_rri(d, Op::XORI, rd, rs1, imm_i); break;
        case 6: set_int_rri(d, Op::ORI, rd, rs1, imm_i); break;
        case 7: set_int_rri(d, Op::ANDI, rd, rs1, imm_i); break;
        case 1: {
          const uint32_t imm12 = bits(inst, 31, 20);
          if (imm12 == 0x600) { set_int_rri(d, Op::CLZ, rd, rs1, 0); break; }
          if (imm12 == 0x601) { set_int_rri(d, Op::CTZ, rd, rs1, 0); break; }
          if (imm12 == 0x602) { set_int_rri(d, Op::CPOP, rd, rs1, 0); break; }
          if (imm12 == 0x604) { set_int_rri(d, Op::SEXT_B, rd, rs1, 0); break; }
          if (imm12 == 0x605) { set_int_rri(d, Op::SEXT_H, rd, rs1, 0); break; }
          const uint32_t hi = rv64 ? f6 : f7;
          if (hi == 0) { set_int_rri(d, Op::SLLI, rd, rs1, sh); break; }
          if ((rv64 ? f6 : (f7 >> 1)) == 0x12) { set_int_rri(d, Op::BCLRI, rd, rs1, sh); break; }
          if ((rv64 ? f6 : (f7 >> 1)) == 0x1a) { set_int_rri(d, Op::BINVI, rd, rs1, sh); break; }
          if ((rv64 ? f6 : (f7 >> 1)) == 0x0a) { set_int_rri(d, Op::BSETI, rd, rs1, sh); break; }
          return false;
        }
        case 5: {
          const uint32_t imm12 = bits(inst, 31, 20);
          if (imm12 == 0x287) { set_int_rri(d, Op::ORC_B, rd, rs1, 0); break; }
          if ((rv64 && imm12 == 0x6b8) || (!rv64 && imm12 == 0x698)) { set_int_rri(d, Op::REV8, rd, rs1, 0); break; }
          const uint32_t top = rv64 ? f6 : (f7 >> 1);
          if (top == 0x00 && (rv64 || bit(inst, 25) == 0)) { set_int_rri(d, Op::SRLI, rd, rs1, sh); break; }
          if (top == 0x10 && (rv64 || bit(inst, 25) == 0)) { set_int_rri(d, Op::SRAI, rd, rs1, sh); break; }
          if (top == 0x18) { set_int_rri(d, Op::RORI, rd, rs1, sh); break; }
          if (top == 0x12) { set_int_rri(d, Op::BEXTI, rd, rs1, sh); break; }
          return false;
        }
      }
      break;
    }
    case 0x1b: {
      if (!rv64) return false;
      d.is_w = true;
      const uint32_t sh5 = bits(inst, 24, 20);
      if (f3 == 0) { set_int_rri(d, Op::ADDIW, rd, rs1, imm_i); break; }
      if (f3 == 1) {
        const uint32_t imm12 = bits(inst, 31, 20);
        if (f7 == 0) { set_int_rri(d, Op::SLLIW, rd, rs1, sh5); break; }
        if (f6 == 0x02) { d.is_w = false; set_int_rri(d, Op::SLLI_UW, rd, rs1, bits(inst, 25, 20)); break; }
        if (imm12 == 0x600) { set_int_rri(d, Op::CLZW, rd, rs1, 0); break; }
        if (imm12 == 0x601) { set_int_rri(d, Op::CTZW, rd, rs1, 0); break; }
        if (imm12 == 0x602) { set_int_rri(d, Op::CPOPW, rd, rs1, 0); break; }
        return false;
      }
      if (f3 == 5) {
        if (f7 == 0x00) { set_int_rri(d, Op::SRLIW, rd, rs1, sh5); break; }
        if (f7 == 0x20) { set_int_rri(d, Op::SRAIW, rd, rs1, sh5); break; }
        if (f7 == 0x30) { set_int_rri(d, Op::RORIW, rd, rs1, sh5); break; }
      }
      return false;
    }
    case 0x33: {
      Op op = Op::ILLEGAL;
      switch (f7) {
        case 0x00: { static const Op m[8] = {Op::ADD, Op::SLL, Op::SLT, Op::SLTU, Op::XOR, Op::SRL, Op::OR, Op::AND};
                     op = m[f3]; break; }
        case 0x20: if (f3 == 0) op = Op::SUB; else if (f3 == 5) op = Op::SRA; else if (f3 == 7) op = Op::ANDN;
                   else if (f3 == 6) op = Op::ORN; else if (f3 == 4) op = Op::XNOR; break;
        case 0x01: { static const Op m[8] = {Op::MUL, Op::MULH, Op::MULHSU, Op::MULHU, Op::DIV, Op::DIVU, Op::REM,
                                             Op::REMU};
                     op = m[f3]; break; }
        case 0x10: if (f3 == 2) op = Op::SH1ADD; else if (f3 == 4) op = Op::SH2ADD; else if (f3 == 6) op = Op::SH3ADD;
                   break;
        case 0x05: if (f3 == 4) op = Op::MIN; else if (f3 == 5) op = Op::MINU; else if (f3 == 6) op = Op::MAX;
                   else if (f3 == 7) op = Op::MAXU; break;
        case 0x30: if (f3 == 1) op = Op::ROL; else if (f3 == 5) op = Op::ROR; break;
        case 0x24: if (f3 == 1) op = Op::BCLR; else if (f3 == 5) op = Op::BEXT; break;
        case 0x34: if (f3 == 1) op = Op::BINV; break;
        case 0x14: if (f3 == 1) op = Op::BSET; break;
        case 0x07: if (f3 == 5) op = Op::CZERO_EQZ; else if (f3 == 7) op = Op::CZERO_NEZ; break;
        case 0x04: if (!rv64 && f3 == 4 && rs2 == 0) op = Op::ZEXT_H; break;
      }
      if (op == Op::ILLEGAL) return false;
      set_int_rrr(d, op, rd, rs1, rs2);
      if (op == Op::ZEXT_H) d.rs2_k = RK_NONE;
      break;
    }
    case 0x3b: {
      if (!rv64) return false;
      Op op = Op::ILLEGAL;
      d.is_w = true;
      switch (f7) {
        case 0x00: if (f3 == 0) op = Op::ADDW; else if (f3 == 1) op = Op::SLLW; else if (f3 == 5) op = Op::SRLW; break;
        case 0x20: if (f3 == 0) op = Op::SUBW; else if (f3 == 5) op = Op::SRAW; break;
        case 0x01: if (f3 == 0) op = Op::MULW; else if (f3 == 4) op = Op::DIVW; else if (f3 == 5) op = Op::DIVUW;
                   else if (f3 == 6) op = Op::REMW; else if (f3 == 7) op = Op::REMUW; break;
        case 0x04: if (f3 == 0) { op = Op::ADD_UW; d.is_w = false; }
                   else if (f3 == 4 && rs2 == 0) { op = Op::ZEXT_H; d.is_w = false; } break;
        case 0x10: d.is_w = false;
                   if (f3 == 2) op = Op::SH1ADD_UW; else if (f3 == 4) op = Op::SH2ADD_UW;
                   else if (f3 == 6) op = Op::SH3ADD_UW; break;
        case 0x30: if (f3 == 1) op = Op::ROLW; else if (f3 == 5) op = Op::RORW; break;
      }
      if (op == Op::ILLEGAL) return false;
      set_int_rrr(d, op, rd, rs1, rs2);
      if (op == Op::ZEXT_H) d.rs2_k = RK_NONE;
      break;
    }
    case 0x0f:
      if (f3 == 0) d.op = Op::FENCE;
      else if (f3 == 1) d.op = Op::FENCE_I;
      else return false;
      break;
    case 0x73: {
      if (f3 == 0) {
        const uint32_t imm12 = bits(inst, 31, 20);
        if (f7 == 0x09) { d.op = Op::SFENCE_VMA; d.rs1 = (uint8_t)rs1; d.rs2 = (uint8_t)rs2;
                          d.rs1_k = RK_INT; d.rs2_k = RK_INT; break; }
        if (imm12 == 0) d.op = Op::ECALL;
        else if (imm12 == 1) d.op = Op::EBREAK;
        else if (imm12 == 0x302) d.op = Op::MRET;
        else if (imm12 == 0x105) d.op = Op::WFI;
        else return false;
        break;
      }
      static const Op m[8] = {Op::ILLEGAL, Op::CSRRW, Op::CSRRS, Op::CSRRC, Op::ILLEGAL, Op::CSRRWI, Op::CSRRSI,
                              Op::CSRRCI};
      if (m[f3] == Op::ILLEGAL) return false;
      d.op = m[f3]; d.rd = (uint8_t)rd; d.rd_k = RK_INT; d.csr = (uint16_t)bits(inst, 31, 20);
      if (f3 < 4) { d.rs1 = (uint8_t)rs1; d.rs1_k = RK_INT; } else { d.imm = rs1; }
      break;
    }
    case 0x2f: {
      if (f3 != 2 && !(rv64 && f3 == 3)) return false;
      static const struct { uint32_t f5; Op op; } m[] = {
          {0x02, Op::LR}, {0x03, Op::SC}, {0x01, Op::AMOSWAP}, {0x00, Op::AMOADD}, {0x04, Op::AMOXOR},
          {0x0c, Op::AMOAND}, {0x08, Op::AMOOR}, {0x10, Op::AMOMIN}, {0x14, Op::AMOMAX}, {0x18, Op::AMOMINU},
          {0x1c, Op::AMOMAXU}};
      const uint32_t f5 = bits(inst, 31, 27);
      Op op = Op::ILLEGAL;
      for (auto& e : m) if (e.f5 == f5) op = e.op;
      if (op == Op::ILLEGAL) return false;
      set_int_rrr(d, op, rd, rs1, rs2);
      if (op == Op::LR) d.rs2_k = RK_NONE;
      d.msize = f3 == 2 ? 4 : 8; d.msigned = true;
      break;
    }
    case 0x07:
      if (f3 != 2 && f3 != 3) return false;
      d.op = Op::FL; d.rd = (uint8_t)rd; d.rd_k = RK_FP; d.rs1 = (uint8_t)rs1; d.rs1_k = RK_INT; d.imm = imm_i;
      d.msize = f3 == 2 ? 4 : 8; d.fmt = f3 == 3;
      break;
    case 0x27:
      if (f3 != 2 && f3 != 3) return false;
      d.op = Op::FS; d.rs1 = (uint8_t)rs1; d.rs1_k = RK_INT; d.rs2 = (uint8_t)rs2; d.rs2_k = RK_FP; d.imm = imm_s;
      d.msize = f3 == 2 ? 4 : 8; d.fmt = f3 == 3;
      break;
    case 0x43: case 0x47: case 0x4b: case 0x4f: {
      const uint32_t fmt = bits(inst, 26, 25);
      if (fmt > 1) return false;
      d.op = opc == 0x43 ? Op::FMADD : opc == 0x47 ? Op::FMSUB : opc == 0x4b ? Op::FNMSUB : Op::FNMADD;
      d.fmt = (uint8_t)fmt; d.rm = (uint8_t)f3;
      d.rd = (uint8_t)rd; d.rs1 = (uint8_t)rs1; d.rs2 = (uint8_t)rs2; d.rs3 = (uint8_t)bits(inst, 31, 27);
      d.rd_k = d.rs1_k = d.rs2_k = d.rs3_k = RK_FP;
      break;
    }
    case 0x53: {
      d.rd = (uint8_t)rd; d.rs1 = (uint8_t)rs1; d.rs2 = (uint8_t)rs2; d.rm = (uint8_t)f3;
      const uint32_t fmt = f7 & 3;
      if (fmt > 1) return false;
      d.fmt = (uint8_t)fmt;
      const uint32_t f5 = f7 >> 2;
      auto fff = [&](Op op) { d.op = op; d.rd_k = RK_FP; d.rs1_k = RK_FP; d.rs2_k = RK_FP; };
      switch (f5) {
        case 0x00: fff(Op::FADD); break;
        case 0x01: fff(Op::FSUB); break;
        case 0x02: fff(Op::FMUL); break;
        case 0x03: fff(Op::FDIV); break;
        case 0x0b: if (rs2) return false; fff(Op::FSQRT); d.rs2_k = RK_NONE; break;
        case 0x04: if (f3 > 2) return false; fff(f3 == 0 ? Op::FSGNJ : f3 == 1 ? Op::FSGNJN : Op::FSGNJX); break;
        case 0x05: if (f3 > 1) return false; fff(f3 == 0 ? Op::FMIN : Op::FMAX); break;
        case 0x08:  // FCVT.S.D (fmt=0, rs2=1) / FCVT.D.S (fmt=1, rs2=0)
          if (fmt == 0 && rs2 == 1) d.op = Op::FCVT_S_D;
          else if (fmt == 1 && rs2 == 0) d.op = Op::FCVT_D_S;
          else return false;
          d.rd_k = RK_FP; d.rs1_k = RK_FP;
          break;
        case 0x14:
          if (f3 > 2) return false;
          d.op = f3 == 0 ? Op::FLE : f3 == 1 ? Op::FLT : Op::FEQ;
          d.rd_k = RK_INT; d.rs1_k = RK_FP; d.rs2_k = RK_FP;
          break;
        case 0x18: {
          static const Op m[4] = {Op::FCVT_W, Op::FCVT_WU, Op::FCVT_L, Op::FCVT_LU};
          if (rs2 > 3 || (!rv64 && rs2 > 1)) return false;
          d.op = m[rs2]; d.rd_k = RK_INT; d.rs1_k = RK_FP;
          break;
        }
        case 0x1a: {
          static const Op m[4] = {Op::FCVT_F_W, Op::FCVT_F_WU, Op::FCVT_F_L, Op::FCVT_F_LU};
          if (rs2 > 3 || (!rv64 && rs2 > 1)) return false;
          d.op = m[rs2]; d.rd_k = RK_FP; d.rs1_k = RK_INT;
          break;
        }
        case 0x1c:
          if (rs2) return false;
          if (f3 == 0) { if (fmt == 1 && !rv64) return false; d.op = Op::FMV_X; }
          else if (f3 == 1) d.op = Op::FCLASS;
          else return false;
          d.rd_k = RK_INT; d.rs1_k = RK_FP;
          break;
        case 0x1e:
          if (rs2 || f3) return false;
          if (fmt == 1 && !rv64) return false;
          d.op = Op::FMV_F; d.rd_k = RK_FP; d.rs1_k = RK_INT;
          break;
        default: return false;
      }
      break;
    }
    default: return false;
  }
  if (d.rd_k == RK_INT && d.rd == 0) d.rd_k = RK_INT;  // x0 writes are discarded by consumers of writes_int()
  d.cls = classify(d);
  return true;
}

bool decode_at(uint16_t lo, uint16_t hi, int xlen, Decoded& d) {
  if ((lo & 3) != 3) {
    const uint32_t x = rvc_expand(lo, xlen);
    if (!x) { d = Decoded{}; d.len = 2; return false; }
    const bool ok = decode32(x, xlen, d);
    d.len = 2;
    return ok;
  }
  return decode32((uint32_t)lo | ((uint32_t)hi << 16), xlen, d);
}

const char* cls_name(Cls c) {
  static const char* n[] = {"ALU", "ALUX", "BR", "JAL", "JALR", "MUL", "DIV", "LD", "ST", "AMO", "CSR", "FENCE",
                            "SYS", "FMA", "FDIV", "FSQRT", "FMISC", "FLD", "FST", "FTOI", "ITOF"};
  return (unsigned)c < (unsigned)Cls::NUM ? n[(unsigned)c] : "?";
}

const char* op_name(Op op) {
  switch (op) {
#define N(x) case Op::x: return #x;
    N(ILLEGAL) N(LUI) N(AUIPC) N(JAL) N(JALR) N(BEQ) N(BNE) N(BLT) N(BGE) N(BLTU) N(BGEU) N(LB) N(LH) N(LW) N(LD)
    N(LBU) N(LHU) N(LWU) N(SB) N(SH) N(SW) N(SD) N(ADDI) N(SLTI) N(SLTIU) N(XORI) N(ORI) N(ANDI) N(SLLI) N(SRLI)
    N(SRAI) N(ADD) N(SUB) N(SLL) N(SLT) N(SLTU) N(XOR) N(SRL) N(SRA) N(OR) N(AND) N(ADDIW) N(SLLIW) N(SRLIW)
    N(SRAIW) N(ADDW) N(SUBW) N(SLLW) N(SRLW) N(SRAW) N(FENCE) N(FENCE_I) N(ECALL) N(EBREAK) N(MRET) N(WFI)
    N(SFENCE_VMA) N(CSRRW) N(CSRRS) N(CSRRC) N(CSRRWI) N(CSRRSI) N(CSRRCI) N(MUL) N(MULH) N(MULHSU) N(MULHU)
    N(DIV) N(DIVU) N(REM) N(REMU) N(MULW) N(DIVW) N(DIVUW) N(REMW) N(REMUW) N(LR) N(SC) N(AMOSWAP) N(AMOADD)
    N(AMOXOR) N(AMOAND) N(AMOOR) N(AMOMIN) N(AMOMAX) N(AMOMINU) N(AMOMAXU) N(FL) N(FS) N(FMADD) N(FMSUB)
    N(FNMSUB) N(FNMADD) N(FADD) N(FSUB) N(FMUL) N(FDIV) N(FSQRT) N(FSGNJ) N(FSGNJN) N(FSGNJX) N(FMIN) N(FMAX)
    N(FEQ) N(FLT) N(FLE) N(FCLASS) N(FCVT_W) N(FCVT_WU) N(FCVT_L) N(FCVT_LU) N(FCVT_F_W) N(FCVT_F_WU)
    N(FCVT_F_L) N(FCVT_F_LU) N(FCVT_S_D) N(FCVT_D_S) N(FMV_X) N(FMV_F) N(SH1ADD) N(SH2ADD) N(SH3ADD) N(ADD_UW)
    N(SH1ADD_UW) N(SH2ADD_UW) N(SH3ADD_UW) N(SLLI_UW) N(ANDN) N(ORN) N(XNOR) N(CLZ) N(CTZ) N(CPOP) N(CLZW)
    N(CTZW) N(CPOPW) N(MAX) N(MAXU) N(MIN) N(MINU) N(SEXT_B) N(SEXT_H) N(ZEXT_H) N(ROL) N(ROR) N(RORI) N(ROLW)
    N(RORW) N(RORIW) N(ORC_B) N(REV8) N(BCLR) N(BCLRI) N(BEXT) N(BEXTI) N(BINV) N(BINVI) N(BSET) N(BSETI)
    N(CZERO_EQZ) N(CZERO_NEZ)
#undef N
    default: return "?";
  }
}

}  // namespace tg
