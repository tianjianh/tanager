// Global parameters and types derived from the build's configuration package (tg_cfg_pkg).
// Owned by the coordinator; tracks request changes (docs/spec/conventions.md §7).
// Every configuration value is re-declared here by name (SystemVerilog imports do not chain),
// so RTL imports tg_pkg only. A new configuration parameter goes into all four
// rtl/common/cfg/tg_cfg_*.sv files and into the list below.
package tg_pkg;

  // Width of an index into n entries; never 0, so it is safe for n = 1.
  function automatic int idx_w(input int n);
    return (n > 1) ? $clog2(n) : 1;
  endfunction

  // ---- Configuration (tg_cfg_pkg) ----
  localparam string CFG_NAME      = tg_cfg_pkg::CFG_NAME;
  localparam int TID_W            = tg_cfg_pkg::TID_W;
  localparam int DECODE_WIDTH     = tg_cfg_pkg::DECODE_WIDTH;
  localparam int N_ALU            = tg_cfg_pkg::N_ALU;
  localparam int FETCH_BYTES      = tg_cfg_pkg::FETCH_BYTES;
  localparam int BTB_SLOTS        = tg_cfg_pkg::BTB_SLOTS;
  localparam int ROB_BANKS        = tg_cfg_pkg::ROB_BANKS;
  localparam int FL_BANKS         = tg_cfg_pkg::FL_BANKS;
  localparam int ROB_ENTRIES      = tg_cfg_pkg::ROB_ENTRIES;
  localparam int LLT_ENTRIES      = tg_cfg_pkg::LLT_ENTRIES;
  localparam int LQ_ENTRIES       = tg_cfg_pkg::LQ_ENTRIES;
  localparam int LCB_ENTRIES      = tg_cfg_pkg::LCB_ENTRIES;
  localparam int SQ_ENTRIES       = tg_cfg_pkg::SQ_ENTRIES;
  localparam int CHECKPOINTS      = tg_cfg_pkg::CHECKPOINTS;
  localparam int IQ_A0            = tg_cfg_pkg::IQ_A0;
  localparam int IQ_A1            = tg_cfg_pkg::IQ_A1;
  localparam int IQ_A2            = tg_cfg_pkg::IQ_A2;
  localparam int IQ_LD            = tg_cfg_pkg::IQ_LD;
  localparam int IQ_STA           = tg_cfg_pkg::IQ_STA;
  localparam int IQ_FP            = tg_cfg_pkg::IQ_FP;
  localparam int IQ_CAP_PCT       = tg_cfg_pkg::IQ_CAP_PCT;
  localparam int INT_PREGS_PER_BANK = tg_cfg_pkg::INT_PREGS_PER_BANK;
  localparam int FP_PREGS_PER_BANK  = tg_cfg_pkg::FP_PREGS_PER_BANK;
  localparam int UBTB_ENTRIES     = tg_cfg_pkg::UBTB_ENTRIES;
  localparam int BTB_SETS         = tg_cfg_pkg::BTB_SETS;
  localparam int TAGE_LOG         = tg_cfg_pkg::TAGE_LOG;
  localparam int RAS_ENTRIES      = tg_cfg_pkg::RAS_ENTRIES;
  localparam int FTQ_ENTRIES      = tg_cfg_pkg::FTQ_ENTRIES;
  localparam int IBUF_ENTRIES     = tg_cfg_pkg::IBUF_ENTRIES;
  localparam int L1I_KIB          = tg_cfg_pkg::L1I_KIB;
  localparam int L1D_KIB          = tg_cfg_pkg::L1D_KIB;
  localparam int L1_WAYS          = tg_cfg_pkg::L1_WAYS;
  localparam int L1I_MSHRS        = tg_cfg_pkg::L1I_MSHRS;
  localparam int L1D_MSHRS        = tg_cfg_pkg::L1D_MSHRS;
  localparam int ITLB_ENTRIES     = tg_cfg_pkg::ITLB_ENTRIES;
  localparam int DTLB_ENTRIES     = tg_cfg_pkg::DTLB_ENTRIES;
  localparam int L2TLB_ENTRIES    = tg_cfg_pkg::L2TLB_ENTRIES;
  localparam int PWC_ENTRIES      = tg_cfg_pkg::PWC_ENTRIES;
  localparam int NUM_CORES        = tg_cfg_pkg::NUM_CORES;
  localparam int PA_W             = tg_cfg_pkg::PA_W;

  // ---- Derived ----
  localparam int XLEN = 64;

  // Threads. TID_W = 0 builds no SMT hardware: tid signals keep one bit, tied to 0.
  localparam int NUM_THREADS = 1 << TID_W;
  localparam int TID_BITS    = (TID_W > 0) ? TID_W : 1;
  localparam int NUM_HARTS   = NUM_CORES * NUM_THREADS;
  localparam int HART_W      = idx_w(NUM_HARTS);

  // Widths (plan §4.15): everything per-instruction-per-cycle comes from these.
  localparam int RENAME_WIDTH   = DECODE_WIDTH;
  localparam int DISPATCH_WIDTH = DECODE_WIDTH;
  localparam int COMMIT_WIDTH   = DECODE_WIDTH;

  // Window indices
  localparam int ROB_IDX_W = idx_w(ROB_ENTRIES);
  localparam int LLT_IDX_W = idx_w(LLT_ENTRIES);
  localparam int LQ_IDX_W  = idx_w(LQ_ENTRIES);
  localparam int SQ_IDX_W  = idx_w(SQ_ENTRIES);

  // Physical registers: integer banks B0..B(N_ALU-1) for the ALU ports, B(N_ALU) for loads;
  // FP banks F0 (FP pipe) and F1 (FP loads). Tags are {bank, index}.
  localparam int INT_BANKS  = N_ALU + 1;
  localparam int FP_BANKS   = 2;
  localparam int INT_PREG_W = idx_w(INT_BANKS * INT_PREGS_PER_BANK);
  localparam int FP_PREG_W  = idx_w(FP_BANKS * FP_PREGS_PER_BANK);

  // Lockstep and trace (docs/spec/interfaces.md §5)
  localparam int WB_TAG_W       = LLT_IDX_W;  // names a deferred writeback while it is pending
  localparam int TRACE_WB_PORTS = 2;          // deferred writebacks reported per cycle

  // Opaque tag the core attaches to FPU operations; the FPU returns it unchanged.
  localparam int FPU_TAG_W = 32;

  typedef logic [TID_BITS-1:0]  tid_t;
  typedef logic [HART_W-1:0]    hart_t;
  typedef logic [PA_W-1:0]      paddr_t;
  typedef logic [XLEN-1:0]      xlen_t;

  // Privilege levels (encoding of mstatus.MPP)
  typedef enum logic [1:0] { PRIV_U = 2'd0, PRIV_S = 2'd1, PRIV_M = 2'd3 } priv_e;
endpackage
