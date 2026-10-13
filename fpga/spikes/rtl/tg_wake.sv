// The woken vector W over wakeup IDs (plan §4.6), shared by all issue queues. Spike S2.
//
// Set:   by the selects of 1-cycle ops in the same cycle (wake_now, the protected loop),
//        and by registered sources (wake_reg): delay lines of fixed-latency ops,
//        speculative load wakeups and long-latency-tag completions.
// Clear: when an ID is allocated to a new producer (alloc, registered), and by the
//        speculative-wakeup shadow cancel (cancel, registered): every W bit set by a select
//        in the current cycle or the HIST cycles before it, plus cancel_ids (the missing
//        load's own ID and anything else the load pipe names).
// STALE = 1 (phase variant, see tg_iq): each ID has a phase bit that flips on allocation,
// and W keeps one vector per phase (w_q for phase 0, w1_q for phase 1). A wakeup sets the
// vector of the ID's current phase; an allocation clears the vector of the new phase only,
// so rows still waiting on the previous producer keep seeing it as done.
// The late input (wake_now) meets the register-derived terms in the last LUT level.
module tg_wake
  import tg_pkg::*;
#(
  parameter int NCOL  = 64,
  parameter int NNOW  = 2,     // same-cycle sources (ALU queues)
  parameter int STALE = 0,
  parameter int HIST  = 2
) (
  input  logic                      clk,
  input  logic                      rst,
  input  logic [NNOW-1:0][NCOL-1:0] wake_now,
  input  logic [NCOL-1:0]           wake_reg,
  input  logic [NCOL-1:0]           alloc,
  input  logic                      cancel,
  input  logic [NCOL-1:0]           cancel_ids,
  output logic [NCOL-1:0]           w_q,
  output logic [NCOL-1:0]           w1_q,
  output logic [NCOL-1:0]           phase_q
);
  logic [NCOL-1:0] set_now;
  always_comb begin
    set_now = '0;
    for (int k = 0; k < NNOW; k++) set_now |= wake_now[k];
  end

  // Wakeups from the selects of the last HIST cycles, which a cancel undoes
  logic [HIST-1:0][NCOL-1:0] hist_q;
  logic [NCOL-1:0] undo;
  always_comb begin
    undo = cancel_ids;
    for (int h = 0; h < HIST; h++) undo |= hist_q[h];
    if (!cancel) undo = '0;
  end
  always_ff @(posedge clk) begin
    if (rst || cancel) hist_q <= '0;
    else begin
      hist_q[0] <= set_now;
      for (int h = 1; h < HIST; h++) hist_q[h] <= hist_q[h-1];
    end
  end

  if (STALE != 1) begin : g_one
    logic [NCOL-1:0] base;
    assign base = (w_q & ~alloc & ~undo) | wake_reg;   // register-derived
    always_ff @(posedge clk) begin
      if (rst) w_q <= '0;
      else     w_q <= base | (set_now & {NCOL{!cancel}});
    end
    assign w1_q    = '0;
    assign phase_q = '0;
  end else begin : g_phase
    logic [NCOL-1:0] en0, en1, base0, base1;
    // A wakeup or a cancel acts on the vector of the ID's current phase; an allocation
    // flips the phase and clears the vector of the new phase.
    assign en0   = ~phase_q & {NCOL{!cancel}};
    assign en1   =  phase_q & {NCOL{!cancel}};
    assign base0 = (w_q  & ~(alloc &  phase_q) & ~(undo & ~phase_q)) | (wake_reg & ~phase_q);
    assign base1 = (w1_q & ~(alloc & ~phase_q) & ~(undo &  phase_q)) | (wake_reg &  phase_q);
    always_ff @(posedge clk) begin
      if (rst) begin
        w_q     <= '0;
        w1_q    <= '0;
        phase_q <= '0;
      end else begin
        w_q     <= base0 | (set_now & en0);
        w1_q    <= base1 | (set_now & en1);
        phase_q <= phase_q ^ alloc;
      end
    end
  end
endmodule
