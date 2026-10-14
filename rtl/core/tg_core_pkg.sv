// Core-internal types and constants (docs/spec/core-pipeline.md). Owned by the core track.
// Everything width-dependent derives from tg_pkg; nothing here is configuration.
package tg_core_pkg;
  import tg_pkg::*;
  import tg_alu_pkg::*;

  // ---- Core-local constants ----
  localparam int DIV_INFLIGHT = 4;        // divides between rename and the divider (input FIFO)

  // ISA beyond M2's RV64IM, switched on with the M3 ISA string (sim ISA=..., verification.md §3.2)
  localparam bit EXT_SU     = 1'b0;      // S and U modes, Sv39, delegation, Sstc, Zihpm
  localparam bit EXT_A      = 1'b0;      // atomics
  localparam bit EXT_C      = 1'b0;      // compressed instructions
  localparam bit EXT_B      = 1'b0;      // Zba, Zbb, Zbs
  localparam bit EXT_ZICOND = 1'b0;
  localparam int BHT_ENTRIES  = 512;      // 2-bit direction counters
  localparam int NP           = FETCH_BYTES / 2;   // halfword parcels per fetch block
  localparam int SLOT_W       = idx_w(NP);

  // Wakeup IDs: ROB entries, then long-latency tags (dependency-vector columns)
  localparam int NCOL  = ROB_ENTRIES + LLT_ENTRIES;
  localparam int COL_W = idx_w(NCOL);
  localparam int ROBW  = ROB_IDX_W + 1;   // ROB index plus wrap bit
  localparam int LQW   = LQ_IDX_W + 1;
  localparam int SQW   = SQ_IDX_W + 1;

  // Integer physical registers: {bank, index}
  localparam int PIDX_W = idx_w(INT_PREGS_PER_BANK);
  localparam int BANK_W = idx_w(INT_BANKS);
  localparam int LD_BANK = N_ALU;         // the load pipe's bank

  // Issue queues: ALU queues 0..N_ALU-1, then LD and STA (FP arrives with M5)
  localparam int N_IQ  = N_ALU + 2;
  localparam int Q_LD  = N_ALU;
  localparam int Q_STA = N_ALU + 1;
  localparam int QW    = idx_w(N_IQ);

  typedef logic [BANK_W+PIDX_W-1:0] preg_t;
  typedef logic [ROBW-1:0]          robid_t;
  typedef logic [COL_W-1:0]         wid_t;
  typedef logic [LQW-1:0]           lqid_t;
  typedef logic [SQW-1:0]           sqid_t;
  typedef logic [LLT_IDX_W-1:0]     llt_t;

  function automatic logic [BANK_W-1:0] preg_bank(input preg_t p);
    return p[BANK_W+PIDX_W-1:PIDX_W];
  endfunction
  function automatic logic [PIDX_W-1:0] preg_idx(input preg_t p);
    return p[PIDX_W-1:0];
  endfunction
  function automatic preg_t mk_preg(input int b, input logic [PIDX_W-1:0] i);
    return {BANK_W'(b), i};
  endfunction

  // Age of two ROB IDs (index plus wrap bit): a older than b
  function automatic logic rob_older(input robid_t a, input robid_t b);
    if (a[ROBW-1] == b[ROBW-1]) return a[ROBW-2:0] < b[ROBW-2:0];
    return a[ROBW-2:0] > b[ROBW-2:0];
  endfunction

  // Circular pointers (index plus wrap bit) over sizes that need not be powers of two:
  // x_add(p, k) advances p by k < size; x_cnt(t, h) counts the entries in [h, t).
  function automatic robid_t rob_add(input robid_t p, input int k);
    int i;
    logic w;
    i = int'(p[ROBW-2:0]) + k;
    w = p[ROBW-1];
    if (i >= ROB_ENTRIES) begin i -= ROB_ENTRIES; w = !w; end
    return {w, (ROBW-1)'(i)};
  endfunction
  function automatic int rob_cnt(input robid_t t, input robid_t h);
    return (t[ROBW-1] == h[ROBW-1]) ? int'(t[ROBW-2:0]) - int'(h[ROBW-2:0])
                                    : int'(t[ROBW-2:0]) + ROB_ENTRIES - int'(h[ROBW-2:0]);
  endfunction
  function automatic lqid_t lq_add(input lqid_t p, input int k);
    int i;
    logic w;
    i = int'(p[LQW-2:0]) + k;
    w = p[LQW-1];
    if (i >= LQ_ENTRIES) begin i -= LQ_ENTRIES; w = !w; end
    return {w, (LQW-1)'(i)};
  endfunction
  function automatic int lq_cnt(input lqid_t t, input lqid_t h);
    return (t[LQW-1] == h[LQW-1]) ? int'(t[LQW-2:0]) - int'(h[LQW-2:0])
                                  : int'(t[LQW-2:0]) + LQ_ENTRIES - int'(h[LQW-2:0]);
  endfunction
  function automatic sqid_t sq_add(input sqid_t p, input int k);
    int i;
    logic w;
    i = int'(p[SQW-2:0]) + k;
    w = p[SQW-1];
    if (i >= SQ_ENTRIES) begin i -= SQ_ENTRIES; w = !w; end
    return {w, (SQW-1)'(i)};
  endfunction
  function automatic int sq_cnt(input sqid_t t, input sqid_t h);
    return (t[SQW-1] == h[SQW-1]) ? int'(t[SQW-2:0]) - int'(h[SQW-2:0])
                                  : int'(t[SQW-2:0]) + SQ_ENTRIES - int'(h[SQW-2:0]);
  endfunction

  // ---- Micro-op classes ----
  typedef enum logic [2:0] {
    C_ALU = 3'd0,   // 1-cycle ALU op on any ALU port
    C_BR  = 3'd1,   // branch, JAL, JALR: port 0
    C_MUL = 3'd2,   // port 1, 3 cycles
    C_DIV = 3'd3,   // port 1, iterative
    C_LD  = 3'd4,
    C_ST  = 3'd5,
    C_CSR = 3'd6,   // port 1, serialised
    C_SYS = 3'd7    // no execution: FENCE, FENCE.I, WFI, MRET, decode-time exceptions
  } uclass_e;

  typedef enum logic [1:0] { BR_COND = 2'd0, BR_JAL = 2'd1, BR_JALR = 2'd2 } br_kind_e;

  typedef enum logic [2:0] {
    SYS_NONE = 3'd0, SYS_FENCE = 3'd1, SYS_FENCEI = 3'd2, SYS_WFI = 3'd3, SYS_MRET = 3'd4,
    SYS_SRET = 3'd5, SYS_SFENCE = 3'd6     // SFENCE.VMA and the Svinval forms
  } sys_e;

  typedef enum logic [1:0] { MUL_LO = 2'd0, MUL_H = 2'd1, MUL_HSU = 2'd2, MUL_HU = 2'd3 } mul_op_e;
  typedef enum logic [1:0] { DIV_S = 2'd0, DIV_U = 2'd1, REM_S = 2'd2, REM_U = 2'd3 } div_op_e;
  typedef enum logic [1:0] { CSR_RW = 2'd1, CSR_RS = 2'd2, CSR_RC = 2'd3 } csr_op_e;

  // Atomics: funct5 of the AMO opcode
  localparam logic [4:0] AMO_ADD = 5'b00000, AMO_SWAP = 5'b00001, AMO_LR = 5'b00010,
                         AMO_SC = 5'b00011, AMO_XOR = 5'b00100, AMO_OR = 5'b01000,
                         AMO_AND = 5'b01100, AMO_MIN = 5'b10000, AMO_MAX = 5'b10100,
                         AMO_MINU = 5'b11000, AMO_MAXU = 5'b11100;

  // Exception causes (privileged spec)
  localparam logic [3:0] EXC_IMISALIGN = 4'd0, EXC_IACCESS = 4'd1, EXC_ILLEGAL = 4'd2,
                         EXC_BREAK = 4'd3, EXC_LMISALIGN = 4'd4, EXC_LACCESS = 4'd5,
                         EXC_SMISALIGN = 4'd6, EXC_SACCESS = 4'd7, EXC_ECALL_U = 4'd8,
                         EXC_ECALL_S = 4'd9, EXC_ECALL_M = 4'd11, EXC_IPAGE = 4'd12,
                         EXC_LPAGE = 4'd13, EXC_SPAGE = 4'd15;

  // ---- Front end -> decode: one instruction from the instruction queue ----
  typedef struct packed {
    logic [63:0]       pc;
    logic [31:0]       insn;        // [31:16] zero when rvc
    logic              rvc;
    logic              fault;       // fetch access fault at pc
    logic              pred_taken;  // the front end followed pred_target after this instruction
    logic [63:0]       pred_target;
    logic              pred_bogus;  // unused in M2 (F2 checks predictions against pre-decode)
    logic              ubtb_hit;    // the micro-BTB predicted taken at this instruction
    logic              ubtb_way;
    tid_t              tid;
  } fe_insn_t;

  // ---- Decoded micro-op ----
  typedef struct packed {
    uclass_e       cls;
    logic [4:0]    rs1, rs2, rd;
    logic          rs1_en, rs2_en, rd_en;   // rd_en is 0 for x0
    alu_ctl_t      alu;
    logic          b_imm;       // ALU operand b is imm
    logic [63:0]   imm;         // ALU operand b, memory offset, or the link value (PC + 4)
    br_kind_e      br_kind;
    logic [2:0]    br_f3;       // conditional branch funct3
    logic [63:0]   br_target;   // PC + imm (branches, JAL)
    logic [11:0]   jalr_off;
    logic [1:0]    mem_size;
    logic          mem_uns;
    logic          amo;         // LR, SC, AMO: a C_ST uop performed at the ROB head (core-lsu.md)
    logic [4:0]    amo_op;
    mul_op_e       mul_op;
    div_op_e       div_op;
    logic          word;        // MULW / DIV*W / REM*W / CLZW, CTZW, CPOPW
    logic          bcnt;        // C_MUL slot: clz/ctz/cpop (mul_op 0/1/2) instead of a multiply
    csr_op_e       csr_op;
    logic          csr_imm;     // CSRR*I: rs1 field is the zero-extended immediate
    logic          csr_wr;      // the instruction writes the CSR
    sys_e          sys;
    logic          serial;      // dispatched alone into an empty ROB; flush after commit
    logic          exc;         // decode-time exception
    logic [3:0]    exc_cause;
  } dec_t;

  // A micro-op in the RN / DS pipeline registers
  typedef struct packed {
    logic [63:0]   pc;
    logic [31:0]   insn;
    logic          rvc;
    logic [63:0]   pred_npc;    // next PC the front end followed
    logic          ubtb_hit;    // the micro-BTB predicted taken here
    logic          ubtb_way;
    logic          dfix;        // decode redirected here (the micro-BTB entry is wrong)
    tid_t          tid;
    dec_t          d;
  } uop_t;

  // Rename results for one slot
  typedef struct packed {
    logic [QW-1:0] q;           // issue queue (valid when has_q)
    logic          has_q;
    preg_t         dst;         // destination (valid when d.rd_en)
    preg_t         old;         // previous mapping of rd
    preg_t         src1, src2;
    logic          p1, p2;      // source pending
    wid_t          w1, w2;      // their producers' wakeup IDs
    wid_t          wid;         // own wakeup ID (ROB index or LLT column)
    logic          use_llt;
    llt_t          llt;
    robid_t        rob;
    lqid_t         lq;          // LQ entry (loads); SQ tail seen (all)
    sqid_t         sq;          // SQ entry (stores); SQ tail seen (loads)
  } ren_t;

  // ---- Issue-queue payload (one format for every queue) ----
  // The source tags are the last fields (the low bits): with EARLY_W they are the only payload
  // bits kept in flip-flops behind the grant mux; the rest is read from LUTRAM in RF.
  typedef struct packed {
    robid_t        rob;
    tid_t          tid;
    uclass_e       cls;
    alu_ctl_t      alu;
    logic          b_imm;
    logic [63:0]   imm;
    logic          dst_en;
    preg_t         dst;
    wid_t          wid;
    llt_t          llt;
    logic [63:0]   pc;
    br_kind_e      br_kind;
    logic [2:0]    br_f3;
    logic [63:0]   br_target;
    logic [11:0]   jalr_off;
    logic [63:0]   pred_npc;
    logic          ubtb_hit;
    logic          ubtb_way;
    logic          dfix;
    logic          rvc;
    mul_op_e       mul_op;
    div_op_e       div_op;
    logic          word;
    logic          bcnt;
    csr_op_e       csr_op;
    logic          csr_imm;
    logic          csr_wr;
    logic [11:0]   csr_addr;
    logic [4:0]    csr_zimm;
    logic [31:0]   insn;        // CSR: illegal-instruction tval
    lqid_t         lq;
    sqid_t         sq;
    logic [1:0]    mem_size;
    logic          mem_uns;
    preg_t         src1, src2;
  } iq_pl_t;
  localparam int IQ_PL_W = $bits(iq_pl_t);

  // ---- Scheduler options (spikes.md §4.2) ----
  localparam bit IQ_DUP_SEL = 1'b1;               // a second select copy drives the wakeup
  localparam int IQ_EARLY_W = 2 * $bits(preg_t);  // only the source tags in flip-flops
  localparam bit IQ_MX      = TID_W > 0;          // matrix wakeup: required for smt2 timing
  // ALU-queue rows, numbered across the queues (MX names producers by these rows)
  localparam int RA = IQ_A0 + IQ_A1 + ((N_ALU > 2) ? IQ_A2 : 0);
  localparam int RA_W = idx_w(RA);
  function automatic int alu_row_base(input int q);
    return (q == 0) ? 0 : (q == 1) ? IQ_A0 : IQ_A0 + IQ_A1;
  endfunction

  // ---- ROB payload, written at dispatch ----
  typedef struct packed {
    logic [63:0]   pc;
    logic [31:0]   insn;
    logic          rvc;
    tid_t          tid;
    logic          rd_en;
    logic [4:0]    rd;
    preg_t         dst;
    preg_t         old;
    logic          is_ld, is_st, is_br, is_csr;
    sys_e          sys;
    logic          serial;
    logic          dexc;        // decode-time exception
    logic [3:0]    dexc_cause;
    lqid_t         lq;
    sqid_t         sq;
  } rob_pl_t;
  localparam int ROB_PL_W = $bits(rob_pl_t);

  // CSRs whose reads the lockstep checker adopts (verification.md §3.4)
  function automatic logic csr_nondet(input logic [11:0] a);
    return a == 12'hB00 || a == 12'hC00 || a == 12'hC01 || a == 12'h344 || a == 12'h144 ||
           a == 12'hF11 || a == 12'hF12 || a == 12'hF13 ||
           (a >= 12'hB03 && a <= 12'hB1F) || (a >= 12'hC03 && a <= 12'hC1F);
  endfunction
endpackage
