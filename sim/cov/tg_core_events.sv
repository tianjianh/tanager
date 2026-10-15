// Event points for the coverage build (make -C sim COV=1; docs/spec/verification.md §6.4). Some
// questions about the core concern conditions that none of its own expressions shows, so each one is
// a branch here, counted by tg_vsim --cov and tools/ci/cov_report.py like any other point. Bound into
// tg_rob below; the connections are evaluated in tg_rob's scope. Only coverage builds of the product
// core read this file (sim/Makefile). +tg_events prints the counts at the end of a run.
module tg_rob_events #(
  parameter int AW = 6,          // ROB index bits that address the flag tables
  parameter int DW = 3           // dispatch slots
) (
  input logic                  clk,
  input logic                  rst,
  input logic [2:0]            set_v,    // the replay flag's setters: replay, DTLB miss on LD, on STA
  input logic [2:0][AW-1:0]    set_a,
  input logic [DW-1:0]         clr_v,    // dispatch slots, which clear their entry's flag
  input logic [DW-1:0][AW-1:0] clr_a,
  input logic                  irq,      // an interrupt taken at the head
  input logic                  hd_csr,   // the head is a CSR instruction
  input logic                  hd_cmp    // that has completed (else it is still in EX)
);
  // The replay flag's XOR-banked tables (core track, fn2): two valid setters at one entry in one
  // cycle (only the first writes); the guard's own condition, which does not check the second
  // setter's valid, met with that setter invalid; a dispatch clear meeting a valid set at one entry
  // (the clear yields). The core track expects the first and the third never to happen.
  logic two_set, stale_match, clr_meets_set;
  always_comb begin
    two_set = 1'b0;
    stale_match = 1'b0;
    clr_meets_set = 1'b0;
    for (int i = 1; i < 3; i++)
      for (int t = 0; t < i; t++)
        if (set_v[t] && set_a[t] == set_a[i]) begin
          if (set_v[i]) two_set = 1'b1;
          else stale_match = 1'b1;
        end
    for (int i = 0; i < 3; i++)
      for (int k = 0; k < DW; k++)
        if (set_v[i] && clr_v[k] && set_a[i] == clr_a[k]) clr_meets_set = 1'b1;
  end

  // The CSR unit's cold registers (fn2): trap entry writes xepc, xcause and xtval over the three
  // cycles after the trap; the case to reach is an interrupt taken while a CSR instruction is at the
  // head, above all while it is still in EX.
  int unsigned n_two_set, n_stale, n_clr_set, n_irq_csr, n_irq_csr_ex;
  always_ff @(posedge clk) begin
    if (rst) begin
      n_two_set <= 0;
      n_stale <= 0;
      n_clr_set <= 0;
      n_irq_csr <= 0;
      n_irq_csr_ex <= 0;
    end else begin
      if (two_set) n_two_set <= n_two_set + 1;
      if (stale_match) n_stale <= n_stale + 1;
      if (clr_meets_set) n_clr_set <= n_clr_set + 1;
      if (irq && hd_csr) n_irq_csr <= n_irq_csr + 1;
      if (irq && hd_csr && !hd_cmp) n_irq_csr_ex <= n_irq_csr_ex + 1;
    end
  end

  final
    if ($test$plusargs("tg_events"))
      $display("tg_rob_events: replay flag: two setters %0d, stale match %0d, clear meets set %0d; interrupt at a CSR head %0d (in EX %0d)",
               n_two_set, n_stale, n_clr_set, n_irq_csr, n_irq_csr_ex);
endmodule

bind tg_rob tg_rob_events #(.AW(RIW), .DW(DISPATCH_WIDTH)) u_tg_rob_events (
  .clk, .rst,
  .set_v({tlbm_valid[1], tlbm_valid[0], replay_valid}),
  .set_a(rw_a[DISPATCH_WIDTH +: 3]),
  .clr_v({DISPATCH_WIDTH{ds_fire}} & ds_valid),
  .clr_a(rw_a[0 +: DISPATCH_WIDTH]),
  .irq(do_irq),
  .hd_csr(hp[0].is_csr),
  .hd_cmp(cmp_h[0])
);
