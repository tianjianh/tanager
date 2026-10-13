// tgsim: RISC-V instruction set definitions (decoded form) shared by the ISS and the timing model.
#pragma once
#include <cstdint>
#include <string>

namespace tg {

enum class Op : uint16_t {
  ILLEGAL,
  // RV32I / RV64I
  LUI, AUIPC, JAL, JALR, BEQ, BNE, BLT, BGE, BLTU, BGEU,
  LB, LH, LW, LD, LBU, LHU, LWU, SB, SH, SW, SD,
  ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI,
  ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND,
  ADDIW, SLLIW, SRLIW, SRAIW, ADDW, SUBW, SLLW, SRLW, SRAW,
  FENCE, FENCE_I, ECALL, EBREAK, MRET, WFI, SFENCE_VMA,
  CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI,
  // M
  MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU, MULW, DIVW, DIVUW, REMW, REMUW,
  // A (width in msize)
  LR, SC, AMOSWAP, AMOADD, AMOXOR, AMOAND, AMOOR, AMOMIN, AMOMAX, AMOMINU, AMOMAXU,
  // F / D (precision in fmt; memory width in msize)
  FL, FS,
  FMADD, FMSUB, FNMSUB, FNMADD, FADD, FSUB, FMUL, FDIV, FSQRT,
  FSGNJ, FSGNJN, FSGNJX, FMIN, FMAX, FEQ, FLT, FLE, FCLASS,
  FCVT_W, FCVT_WU, FCVT_L, FCVT_LU,          // fp(fmt) -> int
  FCVT_F_W, FCVT_F_WU, FCVT_F_L, FCVT_F_LU,  // int -> fp(fmt)
  FCVT_S_D, FCVT_D_S, FMV_X, FMV_F,          // FMV_X: fp->int bits, FMV_F: int->fp bits
  // Zba
  SH1ADD, SH2ADD, SH3ADD, ADD_UW, SH1ADD_UW, SH2ADD_UW, SH3ADD_UW, SLLI_UW,
  // Zbb
  ANDN, ORN, XNOR, CLZ, CTZ, CPOP, CLZW, CTZW, CPOPW, MAX, MAXU, MIN, MINU,
  SEXT_B, SEXT_H, ZEXT_H, ROL, ROR, RORI, ROLW, RORW, RORIW, ORC_B, REV8,
  // Zbs
  BCLR, BCLRI, BEXT, BEXTI, BINV, BINVI, BSET, BSETI,
  // Zicond
  CZERO_EQZ, CZERO_NEZ,
  NUM_OPS
};

// Timing class of an instruction (what kind of unit executes it).
enum class Cls : uint8_t {
  ALU,    // single-cycle integer
  ALUX,   // complex Zbb (clz/ctz/cpop/rev8/orc.b): ALU1 only
  BR,     // conditional branch
  JAL,    // direct jump / call
  JALR,   // indirect jump / call / return
  MUL, DIV,
  LD, ST, AMO,
  CSR, FENCE, SYS,
  FMA, FDIV, FSQRT, FMISC,  // FP pipe
  FLD, FST,                 // FP memory
  FTOI,                     // fp -> int register (fmv.x, fcvt.w, feq, fclass)
  ITOF,                     // int -> fp register (fmv.f, fcvt.f.w)
  NUM
};

enum RegKind : uint8_t { RK_NONE = 0, RK_INT = 1, RK_FP = 2 };

struct Decoded {
  Op op = Op::ILLEGAL;
  Cls cls = Cls::ALU;
  uint8_t len = 4;            // bytes in the instruction stream (2 = compressed)
  uint8_t rd = 0, rs1 = 0, rs2 = 0, rs3 = 0;
  uint8_t rd_k = RK_NONE, rs1_k = RK_NONE, rs2_k = RK_NONE, rs3_k = RK_NONE;
  uint8_t fmt = 0;            // 0 = single, 1 = double
  uint8_t rm = 0;
  uint8_t msize = 0;          // memory access size in bytes
  bool msigned = false;
  bool is_w = false;          // 32-bit operation on RV64
  int64_t imm = 0;
  uint16_t csr = 0;
  uint32_t raw = 0;           // 32-bit (expanded) encoding

  bool writes_int() const { return rd_k == RK_INT && rd != 0; }
  bool writes_fp() const { return rd_k == RK_FP; }
  bool is_load() const { return cls == Cls::LD || cls == Cls::FLD; }
  bool is_store() const { return cls == Cls::ST || cls == Cls::FST; }
  bool is_ctrl() const { return cls == Cls::BR || cls == Cls::JAL || cls == Cls::JALR; }
  bool is_call() const { return (cls == Cls::JAL || cls == Cls::JALR) && (rd == 1 || rd == 5); }
  bool is_ret() const {
    return cls == Cls::JALR && rd == 0 && (rs1 == 1 || rs1 == 5) && imm == 0;
  }
};

// Expand a 16-bit compressed instruction into its 32-bit equivalent (0 if illegal).
uint32_t rvc_expand(uint16_t c, int xlen);
// Decode a 32-bit instruction. Returns false for illegal encodings.
bool decode32(uint32_t inst, int xlen, Decoded& d);
// Decode from a 16- or 32-bit parcel stream (lo = first 16 bits, hi = next 16 bits).
bool decode_at(uint16_t lo, uint16_t hi, int xlen, Decoded& d);
const char* op_name(Op op);
const char* cls_name(Cls c);

}  // namespace tg
