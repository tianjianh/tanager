// Unit test of tg_freelist (rtl/core/rename), the per-thread free lists of one register bank (M7's D3), against a
// model of each thread's list: the registers from its commit head to its tail, the first `spec` of them popped.
// Random legal traffic: pops from one thread a cycle up to its free count; commits of registers it popped; pushes of
// registers it holds (committed pops and its homes), one thread a cycle; flushes of either thread, while the other
// pops; transfer requests (want) for either thread. Checked every cycle: each pop slot's register, every thread's free
// count, and whether a transfer happens (the popping thread wants one, its sibling holds at least 2, no push, no
// flush), which moves the sibling's last entry to the taker's list; the init time.
// Merged mode (SPLIT_L = 0) runs the one thread RUN_TID, and never transfers; split mode runs both. DEPTH 96: the FP
// banks with hart 1 (pointers wrap at a non-power of two).
// Negatives (TB_FLUSH_TID0, TB_POP_TID0, TB_WANT_FLIP): the DUT gets thread 0 for the flush or the pops, or the other
// thread for a transfer; they must fail.
module tb_freelist
  import tg_pkg::*, tg_core_pkg::*;
#(
  parameter int DEPTH   = 64,
  parameter int FIRST   = 32,
  parameter bit SPLIT_L   = 1'b0,
  parameter int FIRST_S = 32,
  parameter int CYCLES  = 200000,
  parameter int SEED    = 1
);
  localparam int NT  = NUM_THREADS;
  localparam int NB  = FL_BANKS;
  localparam int W   = RENAME_WIDTH;
  localparam int CW  = COMMIT_WIDTH;
  localparam int IW  = idx_w(DEPTH);
  localparam int PW  = IW + 1;
  localparam int MID = FIRST_S + (DEPTH - FIRST_S) / 2;

  logic clk = 1'b0, rst = 1'b1;
  logic                     ready;
  logic [NT-1:0][PW-1:0]    count;
  tid_t                     pop_tid, push_tid, flush_tid, d_pop_tid, d_flush_tid;
  logic [W-1:0][IW-1:0]     pop_idx;
  logic [idx_w(W+1)-1:0]    pop_n;
  logic                     pop;
  logic [CW-1:0]            push_v;
  logic [CW-1:0][IW-1:0]    push_idx;
  logic [idx_w(CW+1)-1:0]   commit_n;
  logic                     flush;
  logic                     want, xfer;
  tid_t                     want_tid, d_want_tid;
`ifdef TB_WANT_FLIP
  assign d_want_tid = ~want_tid;
`else
  assign d_want_tid = want_tid;
`endif
`ifdef TB_FLUSH_TID0
  assign d_flush_tid = '0;
`else
  assign d_flush_tid = flush_tid;
`endif
`ifdef TB_POP_TID0
  assign d_pop_tid = '0;
`else
  assign d_pop_tid = pop_tid;
`endif
  tg_freelist #(.DEPTH(DEPTH), .NB(NB), .NPOP(W), .NPUSH(CW), .FIRST(FIRST), .SPLIT_L(SPLIT_L), .FIRST_S(FIRST_S)) dut (
    .clk, .rst, .ready, .count, .pop_tid(d_pop_tid), .pop_idx, .pop_n, .pop, .push_tid, .push_v, .push_idx,
    .commit_n, .flush, .flush_tid(d_flush_tid), .want, .want_tid(d_want_tid), .xfer);

  // ---- The model ----
  int unsigned fq[NT][$];        // each thread's list from its commit head
  int          spec[NT];         // the first spec[t] of fq[t] are popped, not committed
  int unsigned held[NT][$];      // registers a thread holds (committed pops, homes): what it may push
  int          mism, npops, npush_tot, nflush, ncommit, nxfer;
  function automatic bit live(input int t);
    return SPLIT_L || t == int'(RUN_TID);
  endfunction
  initial begin
    for (int t = 0; t < NT; t++) begin
      spec[t] = 0;
      if (SPLIT_L) begin
        for (int r = (t == 0 ? FIRST_S : MID); r < (t == 0 ? MID : DEPTH); r++) fq[t].push_back(r);
        if (t == 0) for (int r = 0; r < FIRST_S; r++) held[t].push_back(r);
      end else if (t == int'(RUN_TID)) begin
        for (int r = FIRST; r < DEPTH; r++) fq[t].push_back(r);
        for (int r = 0; r < FIRST; r++) held[t].push_back(r);
      end
    end
  end

  always #5 clk = !clk;
  int cyc;
  int init_cycles;
  initial begin
    void'($urandom(SEED));
    mism = 0; npops = 0; npush_tot = 0; nflush = 0; ncommit = 0; nxfer = 0;
    pop = 1'b0; pop_n = '0; pop_tid = '0; push_tid = '0; push_v = '0; push_idx = '0; commit_n = '0;
    flush = 1'b0; flush_tid = '0; want = 1'b0; want_tid = '0;
    // Inputs change and outputs are sampled at the falling edge, away from the DUT's rising edge
    repeat (3) @(posedge clk);
    @(negedge clk) rst = 1'b0;
    init_cycles = 0;
    while (!ready) begin @(negedge clk); init_cycles++; end
    begin
      int ninit;
      ninit = 0;
      for (int t = 0; t < NT; t++) ninit += fq[t].size();
      if (init_cycles != (ninit + NB - 1) / NB) begin
        $display("MISMATCH init took %0d cycles, expected %0d", init_cycles, (ninit + NB - 1) / NB);
        mism++;
      end
    end
    for (cyc = 0; cyc < CYCLES; cyc++) begin
      int pt, ut, ft, k, c, np, wt, gt;
      bit fl, xe;
      // Choose this cycle's operations (legal for the core's protocol)
      pt = SPLIT_L ? $urandom_range(0, NT - 1) : int'(RUN_TID);
      ut = SPLIT_L ? $urandom_range(0, NT - 1) : int'(RUN_TID);
      fl = ($urandom_range(0, 99) < 4);
      ft = SPLIT_L ? $urandom_range(0, NT - 1) : int'(RUN_TID);
      // commits: of popped registers of ut
      c = (spec[ut] > 0) ? $urandom_range(0, (spec[ut] < CW) ? spec[ut] : CW) : 0;
      // pushes: registers ut holds
      np = $urandom_range(0, CW);
      if (np > held[ut].size()) np = held[ut].size();
      // pops: none from the thread being flushed (rename does not fire for it)
      k = $urandom_range(0, W);
      if (fl && ft == pt) k = 0;
      if (k > fq[pt].size() - spec[pt]) k = fq[pt].size() - spec[pt];
      // Drive
      pop_tid  = tid_t'(pt);
      push_tid = tid_t'(ut);
      flush_tid = tid_t'(ft);
      flush    = fl;
      pop      = (k > 0) || ($urandom_range(0, 1) == 1);
      pop_n    = pop ? (idx_w(W+1))'(k) : (idx_w(W+1))'($urandom_range(0, W));   // ignored without pop
      if (!pop) k = 0;
      // a transfer request: mostly for the popping thread (the only one that may take)
      wt = ($urandom_range(0, 9) < 8) ? pt : ((NT > 1) ? 1 - pt : 0);
      gt = (NT > 1) ? 1 - wt : 0;
      want     = ($urandom_range(0, 99) < 30);
      want_tid = tid_t'(wt);
      xe = SPLIT_L && NT > 1 && want && wt == pt && fq[gt].size() - spec[gt] >= 2 && np == 0 && !fl;
      commit_n = (idx_w(CW+1))'(c);
      push_v   = '0;
      for (int j = 0; j < np; j++) begin
        int s;
        s = $urandom_range(0, held[ut].size() - 1);
        push_v[j]   = 1'b1;
        push_idx[j] = IW'(held[ut][s]);
        held[ut].delete(s);
      end
      #1;
      // Check (combinational outputs from this cycle's registered state)
      for (int t = 0; t < NT; t++) begin
        if (int'(count[t]) != fq[t].size() - spec[t]) begin
          if (mism < 10) $display("MISMATCH cycle %0d thread %0d: count %0d, model %0d", cyc, t, count[t],
                                  fq[t].size() - spec[t]);
          mism++;
        end
      end
      if (xfer !== xe) begin
        if (mism < 10) $display("MISMATCH cycle %0d: transfer %0b, model %0b (want %0b for thread %0d)", cyc, xfer, xe,
                                want, wt);
        mism++;
      end
      for (int i = 0; i < W; i++) begin
        if (i < fq[pt].size() - spec[pt] && int'(pop_idx[i]) != fq[pt][spec[pt] + i]) begin
          if (mism < 10) $display("MISMATCH cycle %0d thread %0d pop slot %0d: %0d, model %0d", cyc, pt, i,
                                  pop_idx[i], fq[pt][spec[pt] + i]);
          mism++;
        end
      end
      @(posedge clk);
      // Update the model as the DUT does at this edge: commits and pushes of ut, the pops of pt, the flush of ft
      for (int j = 0; j < c; j++) begin
        held[ut].push_back(fq[ut].pop_front());
      end
      spec[ut] -= c;
      for (int j = 0; j < np; j++) fq[ut].push_back(int'(push_idx[j]));
      if (k > 0) begin spec[pt] += k; npops += k; end
      if (fl) begin spec[ft] = 0; nflush++; end
      if (xe) begin fq[wt].push_back(fq[gt].pop_back()); nxfer++; end
      ncommit += c;
      npush_tot += np;
      // A thread never holds more registers than the list can take back
      for (int t = 0; t < NT; t++)
        if (fq[t].size() > DEPTH) begin $display("MISMATCH thread %0d's model list overflows", t); mism++; end
      @(negedge clk);
    end
    if (mism == 0)
      $display("TB_FREELIST PASS: %0d cycles, %0d pops, %0d commits, %0d pushes, %0d flushes, %0d transfers, init %0d cycles",
               CYCLES, npops, ncommit, npush_tot, nflush, nxfer, init_cycles);
    else
      $display("TB_FREELIST FAIL: %0d mismatches", mism);
    $finish;
  end
endmodule
