// Configuration `st_w3`: single-thread, 3-wide, 3-ALU build (the 3-wide reserve, §4.15).
// ST sizes until v2's own freeze; kept building and passing lockstep in CI from M2.
// Exactly one tg_cfg_*.sv file is compiled per build (CFG=st|smt2|st_w3|smt2_w3).
/* verilator lint_off DECLFILENAME */
package tg_cfg_pkg;
  localparam string CFG_NAME = "st_w3";

  // Threads and width
  localparam int TID_W        = 0;   // 0: no SMT hardware; hooks reduce to constants
  localparam int DECODE_WIDTH = 3;   // rename, dispatch and commit widths follow it
  localparam int N_ALU        = 3;
  localparam int FETCH_BYTES  = 16;
  localparam int BTB_SLOTS    = 2;
  localparam int ROB_BANKS    = 4;
  localparam int FL_BANKS     = 4;

  // Window
  localparam int ROB_ENTRIES  = 48;  // total; split in static per-thread halves when TID_W = 1
  localparam int LLT_ENTRIES  = 16;  // long-latency tags, shared
  localparam int LQ_ENTRIES   = 16;  // CAM part
  localparam int LCB_ENTRIES  = 8;   // retired-load completion buffer
  localparam int SQ_ENTRIES   = 12;
  localparam int CHECKPOINTS  = 4;   // per thread

  // Issue queues (A2 exists only when N_ALU = 3)
  localparam int IQ_A0  = 10;
  localparam int IQ_A1  = 10;
  localparam int IQ_A2  = 10;
  localparam int IQ_LD  = 6;
  localparam int IQ_STA = 4;
  localparam int IQ_FP  = 10;
  localparam int IQ_CAP_PCT = 100;   // per-thread cap; 75 in SMT2 builds (§6.5)

  // Registers: one integer bank per writer (N_ALU ALU banks + the load bank), two FP banks
  localparam int INT_PREGS_PER_BANK = 64;
  localparam int FP_PREGS_PER_BANK  = 64;

  // Front end
  localparam int UBTB_ENTRIES = 64;  // 2-way LUTRAM
  localparam int BTB_SETS     = 256; // x4 ways = 1K entries
  localparam int TAGE_LOG     = 12;  // 4 tagged tables of 2^12 entries
  localparam int RAS_ENTRIES  = 32;
  localparam int FTQ_ENTRIES  = 32;
  localparam int IBUF_ENTRIES = 16;

  // Memory
  localparam int L1I_KIB      = 32;
  localparam int L1D_KIB      = 32;
  localparam int L1_WAYS      = 8;
  localparam int L1I_MSHRS    = 4;
  localparam int L1D_MSHRS    = 16;
  localparam int ITLB_ENTRIES = 16;
  localparam int DTLB_ENTRIES = 32;
  localparam int L2TLB_ENTRIES = 512;
  localparam int PWC_ENTRIES  = 8;

  // SoC
  localparam int NUM_CORES    = 2;
  localparam int PA_W         = 34;
endpackage
/* verilator lint_on DECLFILENAME */
