// FP back end, core side (docs/spec/fpu.md, "Core integration (P4 back end)"): the issue payload
// of port P4, the record handed to the core's bank-1 arbiter, and helpers for the load path and
// decode. FP register tags ({bank, index} in preg_t's low bits: FPIDX_W, fpreg_bank(),
// fpreg_idx(), mk_fpreg()) are the core's, in tg_core_pkg. Owned by the FPU track; compiled after
// tg_core_pkg (rtl/core/fpu/fpu_be.f).
package tg_fpcore_pkg;
  import tg_pkg::*;
  import tg_core_pkg::*;
  import tg_fpu_pkg::*;

  localparam int FPTAG_W = FPIDX_W + 1;               // {bank, index}; F0 = 0, F1 = 1

  // The P4 issue payload: the fields of the core's iq_pl_t that P4 uses.
  typedef struct packed {
    tid_t     tid;
    robid_t   rob;
    wid_t     wid;         // own wakeup column: a tag (FMA, FMISC FP result) or an LLT's
    llt_t     llt;         // FDIV and integer-destination operations
    logic     dst_en;      // 0 only for an integer destination x0
    preg_t    dst;         // FP tag (always F0) or, with fp_int, an integer preg in bank B1
    preg_t    src1, src2, src3;
    logic     src1_fp;     // 0: operand a is the integer source (FCVT.F.I, FMV.F.X)
    fop_e     fop;
    ffmt_e    fmt;
    ffmt_e    src_fmt;
    ifmt_e    ifmt;
    rm_e      rm;          // resolved: never DYN
    logic     fp_int;      // integer result, handed to bank B1
    logic     fp_div;      // divide/sqrt unit
  } fp_iss_t;

  // An integer result for the core's bank-1 write arbiter
  typedef struct packed {
    tid_t        tid;
    robid_t      rob;
    wid_t        wid;
    llt_t        llt;
    logic        dst_en;
    preg_t       dst;
    logic [63:0] data;
    logic [4:0]  fflags;
  } fpi_t;

  // Rounding mode of an instruction that rounds (Spike's RM rule): DYN (7) reads frm; 5 and 6,
  // and DYN while frm >= 5, are illegal.
  function automatic rm_e fp_rm_resolve(input logic [2:0] rm_field, input logic [2:0] frm);
    return rm_e'((rm_field == 3'd7) ? frm : rm_field);
  endfunction
  function automatic logic fp_rm_illegal(input logic [2:0] rm_field, input logic [2:0] frm);
    return ((rm_field == 3'd7) ? frm : rm_field) > 3'd4;
  endfunction

  // fcsr views, by the low bits of their CSR address (0x001, 0x002, 0x003)
  localparam logic [1:0] FCSR_A_FFLAGS = 2'd1;
  localparam logic [1:0] FCSR_A_FRM    = 2'd2;
  localparam logic [1:0] FCSR_A_FCSR   = 2'd3;
endpackage
