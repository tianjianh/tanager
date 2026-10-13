// Core <-> FPU execution interface (docs/spec/interfaces.md §4).
// The latency constants belong to the FPU track; the core must use them by name.
package tg_fpu_pkg;
  import tg_pkg::*;

  localparam int FMA_LAT    = 5;   // fixed, fully pipelined (plan §4.12; 4 if synthesis allows)
  localparam int FMISC_LAT  = 2;   // fixed, fully pipelined
  localparam int FDIV_LAT_S = 18;  // Goldschmidt, plan §4.12
  localparam int FDIV_LAT_D = 23;
  localparam int FSQRT_LAT_S = 20;
  localparam int FSQRT_LAT_D = 26;
  localparam int FDIV_II    = 4;   // a new divide/sqrt may start every FDIV_II cycles

  typedef enum logic [4:0] {
    // FMA pipe
    FOP_FADD, FOP_FSUB, FOP_FMUL, FOP_FMADD, FOP_FMSUB, FOP_FNMSUB, FOP_FNMADD,
    // Divide/sqrt unit
    FOP_FDIV, FOP_FSQRT,
    // FMISC unit
    FOP_FSGNJ, FOP_FSGNJN, FOP_FSGNJX, FOP_FMIN, FOP_FMAX,
    FOP_FEQ, FOP_FLT, FOP_FLE, FOP_FCLASS,
    FOP_FCVT_F_F,   // between FP formats: src_fmt -> fmt
    FOP_FCVT_I_F,   // FP (fmt) -> integer (ifmt)
    FOP_FCVT_F_I,   // integer (ifmt) -> FP (fmt)
    FOP_FMV_X_F,    // FMV.X.W / FMV.X.D
    FOP_FMV_F_X     // FMV.W.X / FMV.D.X
  } fop_e;

  // RISC-V fmt field encoding; H is for Zfhmin later.
  typedef enum logic [1:0] { FMT_S = 2'd0, FMT_D = 2'd1, FMT_H = 2'd2 } ffmt_e;
  typedef enum logic [1:0] { IFMT_W = 2'd0, IFMT_WU = 2'd1, IFMT_L = 2'd2, IFMT_LU = 2'd3 } ifmt_e;

  // Resolved rounding mode: never DYN. The core substitutes frm and traps reserved values.
  typedef enum logic [2:0] { RM_RNE = 3'd0, RM_RTZ = 3'd1, RM_RDN = 3'd2, RM_RUP = 3'd3, RM_RMM = 3'd4 } rm_e;

  typedef struct packed {
    fop_e                 op;
    ffmt_e                fmt;      // result format; operand format for compares, FCLASS, FMV.X, FCVT.I.F
    ffmt_e                src_fmt;  // FCVT.F.F only
    ifmt_e                ifmt;     // FCVT.I.F / FCVT.F.I only
    rm_e                  rm;
    logic [63:0]          a;        // FP operands as held in the 64-bit FP registers (S NaN-boxed);
    logic [63:0]          b;        //   FCVT.F.I and FMV.F.X take the integer source in `a`
    logic [63:0]          c;
    logic [FPU_TAG_W-1:0] tag;      // opaque; returned unchanged
  } fpu_req_t;

  typedef struct packed {
    logic [63:0]          result;   // FP results NaN-boxed when S; integer results sign-extended per RV64
    logic [4:0]           fflags;   // NV DZ OF UF NX
    logic                 int_dest; // result goes to the integer register file
    logic [FPU_TAG_W-1:0] tag;
  } fpu_resp_t;
endpackage
