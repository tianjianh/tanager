// Core-internal types and constants (docs/spec/core-pipeline.md). Owned by the core track.
// Everything width-dependent derives from tg_pkg; nothing here is configuration.
package tg_core_pkg;
  import tg_pkg::*;
  import tg_alu_pkg::*;
  import tg_fpu_pkg::*;

  // ---- Core-local constants ----
  localparam int DIV_INFLIGHT = 4;        // divides between rename and the divider (input FIFO)
  localparam int FDIV_INFLIGHT = 4;       // FP divides/square roots between rename and the unit
  localparam int FPI_INFLIGHT  = 4;       // FP ops with an integer result, rename to bank B1

  // ISA beyond M2's RV64IM: on with the M3 ISA string (sim ISA=..., verification.md §3.2); misa
  // and the illegal encodings follow them, so Spike's configuration must match
  localparam bit EXT_SU     = 1'b1;      // S and U modes, Sv39, delegation, Sstc, Zihpm
  localparam bit EXT_A      = 1'b1;      // atomics
  localparam bit EXT_C      = 1'b1;      // compressed instructions
  localparam bit EXT_B      = 1'b1;      // Zba, Zbb, Zbs
  localparam bit EXT_ZICOND = 1'b1;
  localparam bit EXT_FD     = 1'b1;      // F and D: FP rename, IQ-FP and P4, fcsr (core-fp.md)

  // Timing cuts that cost cycles, as build switches (DR-140; core-pipeline §13). Each is an
  // elaboration parameter that selects generate branches, so a setting builds only its own logic.
  // Two profiles are verified (DR-140, as the user set it after DR-141's board runs):
  //   default:  #4, #5, #9, #10 and #11 on; #2 and #8 off (the shipping profile);
  //   fallback: #2, #4, #5, #8, #9, #10 and #11 off (TG_TIMING_CUTS=0: the core without them).
  // #2 and #8 are lint-only switches until the user turns one on: TG_ROB_STORE_REPORT_LATE=1 and
  // TG_DE_STAGE=1, each on top of the default. TG_LSU_AG_SPLIT, TG_DC_AMO_READ_REG,
  // TG_ROB_HEAD_TLB_LATE, TG_LSU_MMIO_PMP_REG and TG_DC_PORTB_WREG =0|1 override their profile
  // value; other combinations are not verified.
`ifdef TG_TIMING_CUTS
  localparam bit TIMING_CUTS = `TG_TIMING_CUTS;
`else
  localparam bit TIMING_CUTS = 1'b1;
`endif
  // #2: store completions and the ordering replay mark reach the ROB a cycle later
`ifdef TG_ROB_STORE_REPORT_LATE
  localparam bit ROB_STORE_REPORT_LATE = `TG_ROB_STORE_REPORT_LATE;
`else
  localparam bit ROB_STORE_REPORT_LATE = 1'b0;    // off in both profiles (DR-140)
`endif
  // #4: a new load's and a store address's DTLB, PMP and decisions in M1 (core-lsu.md)
`ifdef TG_LSU_AG_SPLIT
  localparam bit LSU_AG_SPLIT = `TG_LSU_AG_SPLIT;
`else
  localparam bit LSU_AG_SPLIT = TIMING_CUTS;
`endif
  // #5: an atomic's D$ read data is registered
`ifdef TG_DC_AMO_READ_REG
  localparam bit DC_AMO_READ_REG = `TG_DC_AMO_READ_REG;
`else
  localparam bit DC_AMO_READ_REG = TIMING_CUTS;
`endif
  // #9 (DR-144): the ROB head's DTLB check looks up the head's VA as registered a cycle earlier
  // (B3); off, a second lookup takes the committing store's VA beside the LQ head's, so the
  // check does not wait for the head's selection (B2, cycle-exact). On in the default, off in
  // the fallback; its own define is TG_ROB_HEAD_TLB_LATE=0|1.
`ifdef TG_ROB_HEAD_TLB_LATE
  localparam bit ROB_HEAD_TLB_LATE = `TG_ROB_HEAD_TLB_LATE;
`else
  localparam bit ROB_HEAD_TLB_LATE = TIMING_CUTS;
`endif
  // #10 (DR-148): an MMIO load's PMP verdict is registered before its state takes it: the LQ
  // head's MMIO issue waits a cycle while its load checks (bare and M mode, or a page that a
  // region boundary splits; the fault still reports in the check's cycle)
`ifdef TG_LSU_MMIO_PMP_REG
  localparam bit LSU_MMIO_PMP_REG = `TG_LSU_MMIO_PMP_REG;
`else
  localparam bit LSU_MMIO_PMP_REG = TIMING_CUTS;
`endif
  // #11 (DR-148): the D$'s port-B block-RAM writes are registered: a grant beat's, a store's or an
  // atomic's write reaches the RAM a cycle later, port B's reads wait while one does, and a load
  // that reads the row in either cycle retries (the LSU's clash)
`ifdef TG_DC_PORTB_WREG
  localparam bit DC_PORTB_WREG = `TG_DC_PORTB_WREG;
`else
  localparam bit DC_PORTB_WREG = TIMING_CUTS;
`endif
  // DR-149: misses the L1D keeps in flight, 4 (four MSHRs, a request register for the loads' misses,
  // per-entry refill wakeups) in both profiles since DR-156 (the user, 10-17), or 1 (one MSHR, the L1D
  // as before, cycle for cycle): TG_DC_MSHRS=1
`ifdef TG_DC_MSHRS
  localparam int DC_MSHRS = `TG_DC_MSHRS;
`else
  localparam int DC_MSHRS = 4;
`endif
  // The L1D's Releases in flight, 1 or 2 (prototype, DR-171's follow-up): with 2 the release engine starts the
  // next eviction while the last one's ReleaseAck is on its way (a second source, N + 1). Needs DC_MSHRS > 1.
  // TG_DC_RELS=1 gives one, cycle for cycle as before
`ifdef TG_DC_RELS
  localparam int DC_RELS = `TG_DC_RELS;
`else
  localparam int DC_RELS = 1;
`endif
  // #8, one more decode stage: off in both profiles (DR-140)
`ifdef TG_DE_STAGE
  localparam bit DE_STAGE = `TG_DE_STAGE;
`else
  localparam bit DE_STAGE = 1'b0;
`endif
  // The instruction queue's decode bits (core-pipeline §12): each entry also carries illegal, a
  // decode-time exception and serialising, from a decoder per bank as it is written, and decode reads
  // them instead of decoding again (timing: the queue's take loop, decode -> rename; about +0.23K
  // LUTs st, +0.34K smt2). Cycle-exact either way. Off in both profiles until the user decides with
  // G7's full-chip numbers; TG_QUEUE_DECODE=1 turns it on
`ifdef TG_QUEUE_DECODE
  localparam bit QUEUE_DECODE = `TG_QUEUE_DECODE;
`else
  localparam bit QUEUE_DECODE = 1'b0;
`endif
  // Speculative load wakeup (plan §4.6, M6; the FPU track's tg_issue and tg_exec): a load IQ-LD
  // issues sets its LLT's W bit at AG, so its dependants issue in time for the M2 bypass; one that
  // does not complete in M2 cancels the shadow (spec_cancel). On by default (DR-154); TG_SPEC_WAKE=0
  // gives the wakeup on the confirmed result, cycle for cycle as before
`ifdef TG_SPEC_WAKE
  localparam bit SPEC_WAKE = `TG_SPEC_WAKE;
`else
  localparam bit SPEC_WAKE = 1'b1;
`endif
  // The return-address stack (plan §4.2, M6; tg_ras, RAS_ENTRIES of the configuration): decode
  // predicts returns from it, and a flush restores it exactly from commit's copy. On by default;
  // TG_RAS=0 turns it off: the front end without it, cycle for cycle
`ifdef TG_RAS
  localparam bit RAS_ON = `TG_RAS;
`else
  localparam bit RAS_ON = 1'b1;
`endif
  // TAGE-lite (plan §4.2, M6; tg_tage, core-pipeline.md §3.2): the direction predictor, read per
  // fetch block in F1 and deciding in F2, with the FTQ (FTQ_ENTRIES blocks) keeping what commit
  // trains it with. On by default; TG_TAGE=0 turns it off: the micro-BTB alone, cycle for cycle
`ifdef TG_TAGE
  localparam bit TAGE_ON = `TG_TAGE;
`else
  localparam bit TAGE_ON = 1'b1;
`endif
  localparam int FTQW = idx_w(FTQ_ENTRIES);   // the configuration's FTQ_ENTRIES
  localparam int RAS_PW = idx_w(RAS_ENTRIES);  // the return-address stack's pointer bits
  // Where the stack's speculative side moves: at decode, or with TAGE at fetch (F2, its exits)
  localparam bit RAS_DEC = RAS_ON && !TAGE_ON;
  localparam bit RAS_FE  = RAS_ON && TAGE_ON;
  localparam int GH_W = 64;               // the global history's bits (TAGE)
  // TAGE-lite's sizes (tg_tage): tagged tables (1..4), their index and tag bits, the base table's index
  // bits; two tables of 2K entries (DR-170). TG_TAGE_NT, TG_TAGE_LI, TG_TAGE_TW and TG_TAGE_BI override them
`ifdef TG_TAGE_NT
  localparam int TAGE_NT = `TG_TAGE_NT;
`else
  localparam int TAGE_NT = 2;
`endif
`ifdef TG_TAGE_LI
  localparam int TAGE_LI = `TG_TAGE_LI;
`else
  localparam int TAGE_LI = 11;
`endif
`ifdef TG_TAGE_TW
  localparam int TAGE_TW = `TG_TAGE_TW;
`else
  localparam int TAGE_TW = 9;
`endif
`ifdef TG_TAGE_BI
  localparam int TAGE_BI = `TG_TAGE_BI;
`else
  localparam int TAGE_BI = 11;
`endif
  localparam int TAGE_IXW = TAGE_NT * (TAGE_LI + TAGE_TW) + TAGE_BI;   // a block's indices and tags
  // An ownership prefetch for stores (M6, DR-171; smt2-study's area_recovery.md §6.11): when a
  // cacheable store's address decides, the L1D requests its line with T through a free miss entry
  // (never the last one), so the drain finds it owned instead of waiting for it one store at a time.
  // A cache-state change only: the drain still writes in order. Needs DC_MSHRS > 1. TG_STORE_PF=0
  // gives no prefetch, cycle for cycle as before
`ifdef TG_STORE_PF
  localparam bit STORE_PF = `TG_STORE_PF;
`else
  localparam bit STORE_PF = 1'b1;
`endif
  // How many of those prefetches may be in flight at once, 2 or 3 (DR-171's follow-up): SMT2's 20-entry
  // SQ holds about three lines of a store stream ahead of the drain, st's 12 about one and a half. A
  // prefetch still takes an entry only with another to spare. TG_STORE_PF_MAX=2 gives two, cycle for
  // cycle as before
`ifdef TG_STORE_PF_MAX
  localparam int STORE_PF_MAX = `TG_STORE_PF_MAX;
`else
  localparam int STORE_PF_MAX = 3;
`endif
  // A store's address op issues on its base register alone (M6, DR-169): rename
  // leaves the store's data register out of its IQ-STA row's wakeup columns and MX rows. The SQ
  // entry captures the data when its register is written (core-lsu.md, Stores), and a load that
  // finds the address without the data waits for it (STQ). TG_STA_BASE=0 gives the wait for both
  // registers, cycle for cycle as before
`ifdef TG_STA_BASE
  localparam bit STA_BASE = `TG_STA_BASE;
`else
  localparam bit STA_BASE = 1'b1;
`endif
  // Rename's ALU-queue steering looks a group ahead (M6, DR-169; smt2-study's
  // area_recovery.md §6.8): a bank's registered free flag misses the row the group in DS is taking,
  // so rename also reads "at least two rows free" and counts the DS op in its slot. TG_STEER_LA=0
  // steers on the one flag, cycle for cycle as before
`ifdef TG_STEER_LA
  localparam bit STEER_LA = `TG_STEER_LA;
`else
  localparam bit STEER_LA = 1'b1;
`endif
  // PMP entries (core-mmu.md §PMP; DR-167, the user's area reserve): 8, entries 8 to 15 read-only
  // zero (every PMP field is WARL and software probes the count; OpenSBI's Domain0 uses 6), or 16
  // with TG_PMP_ENTRIES=16, cycle for cycle as before. Each checker scales with it (three a core)
`ifdef TG_PMP_ENTRIES
  localparam int PMP_ENTRIES = `TG_PMP_ENTRIES;
`else
  localparam int PMP_ENTRIES = 8;
`endif
  // I$ next-line prefetch (area_recovery.md §6.11-6.12): a demand miss of line L also fetches L+1 (same page)
  // through a second Get into an invalid way, validated by its own demand miss (core-pipeline.md §3.1). On by
  // default; TG_IPF=0 turns it off, cycle for cycle.
`ifdef TG_IPF
  localparam bit IPF_ON = `TG_IPF;
`else
  localparam bit IPF_ON = 1'b1;
`endif
  // DR-174 (the user, the area reserve): the integer register file in UltraRAM, double-pumped at clk2x (twice the
  // core clock, from the board's MMCM; spikes.md §8.14's "edge" plan). Off by default; TG_URF=1 turns it on, with
  // the same cycles. The core then needs clk2x.
`ifdef TG_URF
  localparam bit URF = `TG_URF;
`else
  localparam bit URF = 1'b0;
`endif
  localparam int BHT_ENTRIES  = 512;      // 2-bit direction counters
  localparam int NP           = FETCH_BYTES / 2;   // halfword parcels per fetch block
  localparam int SLOT_W       = idx_w(NP);

  // Wakeup columns (dependency-vector columns, plan §4.6, AR-1): IQ_TAGS wakeup tags for the
  // multi-cycle fixed-latency producers (MUL and the bit counts on P1), then the long-latency
  // tags (loads, atomics, divides). 1-cycle producers take no column: MX names them by row
  // while they hold it, and once the row is freed their value is in the register file or the
  // bypass by the time a consumer can issue. Serialised producers end in a flush.
  localparam int IQ_TAGS = 16;            // wakeup tags (24: the margin option)
  localparam int NCOL    = IQ_TAGS + LLT_ENTRIES;
  localparam int COL_W   = idx_w(NCOL);
  localparam int WTAG_W  = idx_w(IQ_TAGS);
  localparam int ROBW    = ROB_IDX_W + 1;  // ROB index plus wrap bit
  // A producer as rename records it: its column, or for a 1-cycle op its ROB index (MX)
  localparam int PID_W   = (COL_W > ROB_IDX_W) ? COL_W : ROB_IDX_W;
  localparam int LQW   = LQ_IDX_W + 1;
  localparam int SQW   = SQ_IDX_W + 1;

  // Integer physical registers: {bank, index}
  localparam int PIDX_W = idx_w(INT_PREGS_PER_BANK);
  localparam int BANK_W = idx_w(INT_BANKS);
  localparam int LD_BANK = N_ALU;         // the load pipe's bank

  // FP physical registers {bank, index}: F0 takes P4 results, F1 FP loads. FP tags travel in
  // preg_t-wide fields next to a flag that says which file they name.
  localparam int FPIDX_W = idx_w(FP_PREGS_PER_BANK);
  localparam int FPB_F0  = 0;
  localparam int FPB_F1  = 1;

  // Issue queues: ALU queues 0..N_ALU-1, then LD and STA, then FP (with EXT_FD)
  localparam int N_IQ  = N_ALU + 2 + int'(EXT_FD);
  localparam int Q_LD  = N_ALU;
  localparam int Q_STA = N_ALU + 1;
  localparam int Q_FP  = N_ALU + 2;
  localparam int N_XQ  = N_ALU + 2;       // queues that issue to tg_exec (ALU, LD, STA)
  localparam int QW    = idx_w(N_IQ);

  typedef logic [BANK_W+PIDX_W-1:0] preg_t;
  typedef logic [ROBW-1:0]          robid_t;
  typedef logic [COL_W-1:0]         wid_t;
  typedef logic [PID_W-1:0]         pid_t;
  // The column of long-latency tag t
  function automatic wid_t llt_col(input int t);
    return wid_t'(IQ_TAGS + t);
  endfunction
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
  function automatic logic fpreg_bank(input preg_t p);
    return p[FPIDX_W];
  endfunction
  function automatic logic [FPIDX_W-1:0] fpreg_idx(input preg_t p);
    return p[FPIDX_W-1:0];
  endfunction
  function automatic preg_t mk_fpreg(input int b, input logic [FPIDX_W-1:0] i);
    return preg_t'({1'(b), i});
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
  typedef enum logic [3:0] {
    C_ALU = 4'd0,   // 1-cycle ALU op on any ALU port
    C_BR  = 4'd1,   // branch, JAL, JALR: port 0
    C_MUL = 4'd2,   // port 1, 3 cycles
    C_DIV = 4'd3,   // port 1, iterative
    C_LD  = 4'd4,
    C_ST  = 4'd5,
    C_CSR = 4'd6,   // port 1, serialised
    C_SYS = 4'd7,   // no execution: FENCE, FENCE.I, WFI, MRET, decode-time exceptions
    C_FP  = 4'd8    // port 4: the FPU's units (EXT_FD)
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

  // ---- Sv39 and PMP (core-mmu.md) ----
  typedef enum logic [1:0] { ACC_R = 2'd0, ACC_W = 2'd1, ACC_X = 2'd2 } acc_e;
  localparam int PPN_W = PA_W - 12;       // physical page number bits the TLBs keep
  // A leaf PTE as the TLBs hold it; a lookup returns the PPN with the superpage bits from the
  // VA. `big`: the PPN has bits above PA_W (every access faults). PMP results are cached with
  // the entry (plan §4.10): ph = the page is PMP-homogeneous, pr/pw/px its permissions in S/U.
  typedef struct packed {
    logic [PPN_W-1:0] ppn;
    logic             big;
    logic             g, d, a, u, x, w, r;
    logic             ph, pr, pw, px;
  } tlb_pte_t;

  // PMP region descriptors, precomputed in tg_csr from pmpcfg/pmpaddr (core-mmu.md §PMP).
  // Addresses are in 4-byte granules; `a` is pmpaddr's low PMP_GW bits.
  localparam int PMP_GW = PA_W - 2;
  typedef struct packed {
    logic              tor, nap;          // mode (neither: off); nap covers NA4 and NAPOT
    logic              l, x, w, r;
    logic              hi;                // pmpaddr has bits above PMP_GW: TOR top above every PA
    logic              above;              // NAPOT region above the physical address space
    logic [PMP_GW-1:0] mask;              // NAPOT: 1 = compared bit
    logic [PMP_GW-1:0] a;
  } pmp_d_t;
  function automatic logic va_canon(input logic [63:0] va);     // bits 63:39 equal bit 38
    return va[63:38] == '0 || va[63:38] == '1;
  endfunction
  // Does a cached leaf allow the access in mode S or U? Spike's walk checks: the U rule (SUM;
  // S never executes U pages), R (or X with MXR) / W / X, and Svade: A set, D set for stores.
  function automatic logic pte_ok(input tlb_pte_t p, input acc_e acc, input priv_e mode,
                                  input logic sum, input logic mxr);
    logic uok, pok;
    uok = p.u ? (mode == PRIV_U || (acc != ACC_X && sum)) : (mode != PRIV_U);
    unique case (acc)
      ACC_X:   pok = p.x;
      ACC_R:   pok = p.r || (mxr && p.x);
      default: pok = p.w && p.d;
    endcase
    return uok && pok && p.a;
  endfunction

  // ---- Front end -> decode: one instruction from the instruction queue ----
  typedef struct packed {
    logic [63:0]       pc;          // {blk, pc[3:0]}, or blk's address - 2 when strad
    logic [63:4]       blk;         // the fetch block's address
    logic              strad;       // a 32-bit instruction straddling in from the previous block
    logic [31:0]       insn;        // [31:16] zero when rvc
    logic              rvc;
    logic              fault;       // fetch fault at pc (access, or page with fault_pf)
    logic              fault_pf;
    logic              fault_hi;    // ... on the second half: tval = pc + 2
    logic              pred_taken;  // the front end followed pred_target after this instruction
    logic [63:0]       pred_target;
    logic              pred_bogus;  // unused in M2 (F2 checks predictions against pre-decode)
    logic              ubtb_hit;    // the micro-BTB predicted taken at this instruction
    logic              ubtb_way;
    logic              pred_tsrc;   // TAGE_ON: the front end took this branch or JAL to its own
                                    // target (PC + imm), which pred_target does not carry
    logic [FTQW-1:0]   ftq;         // its fetch block's FTQ entry (TAGE_ON)
    tid_t              tid;
    logic [2:0]        marks;       // pre-decode: {conditional branch, JAL, JALR}; decode's class
                                    // unless decode raises an exception
    logic              q_ill;       // decode bits the queue wrote with it (tg_fetch_compact):
    logic              q_exc;       //   illegal; a decode-time exception (illegal, ECALL, EBREAK;
    logic              q_ser;       //   not a fetch fault); serialising
  } fe_insn_t;

  // The state the decoders read (CSRs): the queue's write-side decoders and decode get the same
  typedef struct packed {
    logic        misa_m, misa_b, misa_c, misa_a, misa_f, misa_d;
    logic [1:0]  fs;
    logic [2:0]  frm;
    priv_e       priv;
    logic        tvm, tw, tsr;
  } dec_state_t;

  // ---- Decoded micro-op ----
  typedef struct packed {
    uclass_e       cls;
    logic [4:0]    rs1, rs2, rd;
    logic          rs1_en, rs2_en, rd_en;   // rd_en is 0 for x0 (never for an FP rd)
    logic          rs1_fp, rs2_fp, rd_fp;   // the register is an FP register
    logic          rs3_en;                  // FMA forms: rs3 (always FP)
    logic [4:0]    rs3;
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
    logic          exc_hi;      // fetch fault on the second half: tval = pc + 2
    fop_e          fop;         // C_FP: the FPU operation and its formats
    ffmt_e         fmt;
    ffmt_e         src_fmt;
    ifmt_e         ifmt;
    rm_e           rm;          // resolved: frm substituted for DYN
    logic          fp_int;      // C_FP with an integer result (bank B1)
    logic          fp_div;      // C_FP on the divide/sqrt unit
  } dec_t;
  // A conditional branch's or JAL's offset from its raw encoding (B or J; RVC's CB or CJ), bits 20:0
  function automatic logic [20:0] br_imm(input logic [31:0] x, input logic jal);
    if (x[1:0] == 2'b11)
      return jal ? {x[31], x[19:12], x[20], x[30:21], 1'b0}
                 : {{8{x[31]}}, x[31], x[7], x[30:25], x[11:8], 1'b0};
    else
      return jal ? {{9{x[12]}}, x[12], x[8], x[10:9], x[6], x[7], x[2], x[11], x[5:3], 1'b0}
                 : {{12{x[12]}}, x[12], x[6:5], x[2], x[11:10], x[4:3], 1'b0};
  endfunction
  // The return-address stack's operation for a decoded instruction (tg_ras): {push, pop}, by the
  // RISC-V hints with x1 and x5 as links. A JAL or JALR with a link rd pushes; a JALR with a link rs1
  // pops, unless rd is the same register; with two different links it does both (pop, then push)
  function automatic logic [1:0] ras_op(input dec_t d);
    logic rdl, rsl;
    rdl = d.rd_en && (d.rd == 5'd1 || d.rd == 5'd5);
    rsl = d.rs1 == 5'd1 || d.rs1 == 5'd5;
    if (!RAS_ON || d.exc || d.cls != C_BR) return 2'b00;
    if (d.br_kind == BR_JAL)  return {rdl, 1'b0};
    if (d.br_kind == BR_JALR) return {rdl, rsl && !(rdl && d.rd == d.rs1)};
    return 2'b00;
  endfunction

  // A micro-op in the RN / DS pipeline registers
  typedef struct packed {
    logic [63:0]   pc;
    logic [31:0]   insn;
    logic          rvc;
    logic [63:0]   pred_npc;    // next PC the front end followed
    logic          ubtb_hit;    // the micro-BTB predicted taken here
    logic          ubtb_way;
    logic          dfix;        // decode redirected here (the micro-BTB entry is wrong)
    logic          ptk;         // the front end followed a taken prediction here
    logic [FTQW-1:0] ftq;       // the fetch block's FTQ entry (TAGE_ON)
    tid_t          tid;
    dec_t          d;
  } uop_t;

  // Rename results for one slot
  typedef struct packed {
    logic [QW-1:0] q;           // issue queue (valid when has_q)
    logic          has_q;
    preg_t         dst;         // destination (valid when d.rd_en)
    preg_t         old;         // previous mapping of rd
    preg_t         src1, src2, src3;
    logic          p1, p2, p3;  // source pending
    pid_t          w1, w2, w3;  // their producers: column (c*), or ROB index (l1/l2)
    logic          c1, c2, c3;  // ... has a wakeup column (tag or LLT)
    logic          l1, l2;      // ... a 1-cycle op (MX naming at DS); rs3 is always FP
    logic [idx_w(RENAME_WIDTH)-1:0] ks1, ks2;   // ... renamed in this slot of its group
    wid_t          wid;         // own wakeup column (valid with use_tag or use_llt)
    logic          use_tag;
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
    fop_e          fop;         // C_FP
    ffmt_e         fmt;
    ffmt_e         src_fmt;
    ifmt_e         ifmt;
    rm_e           rm;
    logic          fp_int;
    logic          fp_div;
    logic          src1_fp;     // C_FP: operand a from the FP file (else the integer file)
    logic          dst_fp;
    preg_t         src1, src2, src3;
  } iq_pl_t;
  localparam int IQ_PL_W = $bits(iq_pl_t);

  // ---- Scheduler options (spikes.md §4.2) ----
  localparam bit IQ_DUP_SEL = 1'b1;               // a second select copy drives the wakeup
  localparam int IQ_EARLY_W = 3 * $bits(preg_t);  // only the source tags in flip-flops
  localparam bit IQ_MX      = 1'b1;               // matrix wakeup: in every configuration (S6)
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
    logic          rd_fp;
    logic [4:0]    rd;
    preg_t         dst;
    preg_t         old;
    logic          is_ld, is_st, is_br, is_csr, is_fp;
    sys_e          sys;
    logic          serial;
    logic          dexc;        // decode-time exception
    logic [3:0]    dexc_cause;
    logic          dexc_hi;
    lqid_t         lq;
    sqid_t         sq;
    logic          ras_push;    // the return-address stack's operation at commit (ras_op)
    logic          ras_pop;
    logic          cbr;         // TAGE_ON: a conditional branch TAGE trains on (not a straddler)
    logic          ptk;         // ... its fetch-time direction
    logic [FTQW-1:0] ftq;       // ... its block's FTQ entry
    // Flags at dispatch: each is the parity of its reporting ports' toggle tables then, XOR the
    // flag's initial value (tg_rob)
    logic          f_cmp, f_exc, f_misp, f_mmio;
  } rob_pl_t;
  localparam int ROB_PL_W = $bits(rob_pl_t);

  // CSRs whose reads the lockstep checker adopts (verification.md §3.4)
  function automatic logic csr_nondet(input logic [11:0] a);
    return a == 12'hB00 || a == 12'hC00 || a == 12'hC01 || a == 12'h344 || a == 12'h144 ||
           a == 12'hF11 || a == 12'hF12 || a == 12'hF13 ||
           (a >= 12'hB03 && a <= 12'hB1F) || (a >= 12'hC03 && a <= 12'hC1F);
  endfunction
endpackage
