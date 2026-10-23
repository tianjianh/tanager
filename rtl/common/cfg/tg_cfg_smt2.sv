// Configuration `smt2`: v1, the first release. SMT2, 2-wide, with the §6.5 window
// (plan §4.14, §6.5). Static per-thread halves of the ROB, LQ, LCB and SQ; 50% issue-queue caps.
// Exactly one tg_cfg_*.sv file is compiled per build (CFG=st|smt2|st_w3|smt2_w3).
/* verilator lint_off DECLFILENAME */
package tg_cfg_pkg;
  localparam string CFG_NAME = "smt2";

  // Threads and width
  localparam int TID_W        = 1;   // 2 harts per core
  localparam int DECODE_WIDTH = 2;   // rename, dispatch and commit widths follow it
  localparam int N_ALU        = 2;
  localparam int FETCH_BYTES  = 16;
  localparam int BTB_SLOTS    = 2;
  localparam int ROB_BANKS    = 2;
  localparam int FL_BANKS     = 2;

  // Window
  localparam int ROB_ENTRIES  = 80;  // total; split in static per-thread halves when TID_W = 1
  localparam int LLT_ENTRIES  = 24;  // long-latency tags, shared
  localparam int LQ_ENTRIES   = 24;  // CAM part
  localparam int LCB_ENTRIES  = 8;   // retired-load completion buffer
  localparam int SQ_ENTRIES   = 20;
  localparam int CHECKPOINTS  = 4;   // per thread

  // Issue queues (A2 exists only when N_ALU = 3)
  localparam int IQ_A0  = 10;
  localparam int IQ_A1  = 10;
  localparam int IQ_A2  = 10;
  localparam int IQ_LD  = 6;
  localparam int IQ_STA = 4;
  localparam int IQ_FP  = 10;
`ifdef TG_IQ_CAP_PCT
  localparam int IQ_CAP_PCT = `TG_IQ_CAP_PCT;   // per-thread cap (§6.5; M7 step 7)
`else
  localparam int IQ_CAP_PCT = 100;   // per-thread cap (§6.5): none, step 7's form is the bank rule (core-pipeline §5.4)
`endif

  // Registers: one integer bank per writer (N_ALU ALU banks + the load bank), two FP banks
  localparam int INT_PREGS_PER_BANK = 64;
  // FP banks of 64 with hart 1 too (DR-179, replacing DR-175's 96): an FP op whose own bank has no register left for
  // its hart renames into the other bank
`ifdef TG_FP_BANK96
  // TG_FP_BANK96=1: DR-175's banks of 96, each holding both harts' 32 and their spares, with no renaming across banks
  // (tg_rename's FXB): the way back from DR-179 for a bigger chip (docs/spec/area_switches.md)
  localparam int FP_PREGS_PER_BANK  = (`TG_FP_BANK96) ? 96 : 64;
`else
  localparam int FP_PREGS_PER_BANK  = 64;
`endif

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
