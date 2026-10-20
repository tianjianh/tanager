// Commit-trace records for Spike lockstep in simulation and for FPGA trace streaming
// (docs/spec/interfaces.md §5).
package tg_trace_pkg;
  import tg_pkg::*;

  typedef enum logic [1:0] {
    TR_RETIRE = 2'd0,  // an instruction retired
    TR_TRAP   = 2'd1,  // an instruction raised an exception instead of retiring
    TR_IRQ    = 2'd2   // an interrupt was taken before the instruction at `pc`
  } tr_kind_e;

  typedef struct packed {
    tr_kind_e              kind;
    hart_t                 hart;         // mhartid
    priv_e                 priv;         // privilege mode the instruction ran in (before a trap)
    logic [63:0]           pc;
    logic [31:0]           insn;         // raw encoding; [31:16] zero when rvc
    logic                  rvc;
    logic                  rd_we;        // wrote an architectural register (x0 excluded)
    logic                  rd_fp;
    logic [4:0]            rd;
    logic                  rd_deferred;  // value follows in a tr_wb_t with the same (hart, wb_tag)
    logic [WB_TAG_W-1:0]   wb_tag;
    logic [63:0]           rd_value;     // when rd_we && !rd_deferred
    logic                  mem_st;       // a store, SC or AMO wrote memory
    logic                  mem_ld;       // v1.5: a load, LR or AMO read memory (interfaces.md §5, Reads)
    logic [63:0]           mem_vaddr;    // the write's, or with mem_ld the read's (an AMO's are one)
    logic [63:0]           mem_wdata;    // right-aligned
    logic [1:0]            mem_size;     // log2(bytes), of the write or the read
    logic                  mmio_ld;      // load from a device region: the checker adopts rd_value
    logic                  nondet;       // non-deterministic CSR read: the checker adopts rd_value
    logic [63:0]           cause;        // TR_TRAP / TR_IRQ: the cause written to mcause/scause
    logic [63:0]           tval;         // TR_TRAP
  } tr_rec_t;

  typedef struct packed {
    hart_t                 hart;
    logic [WB_TAG_W-1:0]   wb_tag;
    logic                  rd_fp;
    logic [4:0]            rd;
    logic [63:0]           value;
  } tr_wb_t;

  // Free space, in records, below which a trace sink must assert trace_stall_i
  // (interfaces.md §5): one cycle of retirement after the stall plus one in flight, and every
  // deferred writeback that can still arrive.
  localparam int TRACE_STALL_HEADROOM = 2 * COMMIT_WIDTH + LLT_ENTRIES;

  // The commit trace as a build switch (DR-146; interfaces.md §5): on by default, as lockstep, the
  // cycle-identical check and board lockstep need it. TG_COMMIT_TRACE=0 builds the core and the SoC
  // without it (timing, fit and performance builds): commit behaviour is the same, the trace outputs
  // stay idle, and the testbenches refuse to run such a model.
`ifdef TG_COMMIT_TRACE
  localparam bit COMMIT_TRACE = `TG_COMMIT_TRACE;
`else
  localparam bit COMMIT_TRACE = 1'b1;
`endif
endpackage
