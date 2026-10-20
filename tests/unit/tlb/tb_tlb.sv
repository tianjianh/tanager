// Unit test of tg_tlb (rtl/core/mmu) with two threads' entries (M7's step 4): random lookups by either thread, fills
// by either thread and flushes of either hart, against a model of what each thread may hit: the pages it filled since
// its last flush, a newer fill of its own replacing the pages it overlaps.
// Checked every cycle at every port:
//   soundness: a hit returns the model's translation for that thread (the superpage bits from the VA), and never a page
//     the thread has not filled (the other thread's entries are invisible to it);
//   liveness: a lookup of the page just filled, by its thread, in the next cycle hits (eviction cannot have taken it).
// A miss is otherwise allowed (capacity). Fills come at least 6 cycles apart (tg_tlb's CAM needs it).
// Negatives (they must fail): TB_LKTID0 (every lookup given thread 0), TB_FILLTID0 (every fill given thread 0).
module tb_tlb
  import tg_pkg::*, tg_core_pkg::*;
#(
  parameter int NE      = 32,
  parameter int NR      = 3,
  parameter bit CAM     = 1'b1,
  parameter int EARLYN  = 3,            // EARLY as an integer bit mask
  parameter int CYCLES  = 100000,
  parameter int SEED    = 1
);
  localparam int NT = NUM_THREADS;
  localparam logic [NR-1:0] EARLY = NR'(EARLYN);
  logic clk = 1'b0, rst = 1'b1;
  logic [NR-1:0][26:0] vpn, vpn_e, vpn_next;
  tid_t [NR-1:0]       lk_tid, d_lk_tid;
  logic [NR-1:0]       hit;
  tlb_pte_t [NR-1:0]   pte;
  logic                fill, flush;
  logic [26:0]         fill_vpn;
  logic [1:0]          fill_lvl;
  tlb_pte_t            fill_pte;
  tid_t                fill_tid, d_fill_tid, flush_tid;
`ifdef TB_LKTID0
  always_comb for (int r = 0; r < NR; r++) d_lk_tid[r] = '0;
`else
  assign d_lk_tid = lk_tid;
`endif
`ifdef TB_FILLTID0
  assign d_fill_tid = '0;
`else
  assign d_fill_tid = fill_tid;
`endif
  tg_tlb #(.NE(NE), .NR(NR), .CAM(CAM), .EARLY(EARLY)) dut (
    .clk, .rst, .vpn, .vpn_e, .lk_tid(d_lk_tid), .hit, .pte, .fill, .fill_vpn, .fill_lvl, .fill_pte,
    .fill_tid(d_fill_tid), .flush, .flush_tid);

  // ---- The model: each thread's pages ----
  typedef struct { logic [26:0] vpn; logic [1:0] lvl; tlb_pte_t pte; } ent_t;
  ent_t model[NT][$];
  function automatic logic covers(input logic [26:0] k, input logic [1:0] l, input logic [26:0] a);
    return a[26:18] == k[26:18] && (l == 2'd2 || a[17:9] == k[17:9]) && (l != 2'd0 || a[8:0] == k[8:0]);
  endfunction
  function automatic logic overlap(input logic [26:0] a, input logic [1:0] la, input logic [26:0] b, input logic [1:0] lb);
    return covers(a, la, b) || covers(b, lb, a);
  endfunction

  // A pool of pages so lookups hit often: 24 base VPNs, offsets inside them for the superpages
  logic [26:0] pool [24];
  function automatic logic [26:0] pick_vpn();
    logic [26:0] b;
    b = pool[$urandom_range(0, 23)];
    if ($urandom_range(0, 3) == 0) b[8:0] = 9'($urandom);
    if ($urandom_range(0, 7) == 0) b[17:9] = 9'($urandom);
    return b;
  endfunction

  always #5 clk = !clk;
  int mism, nhit, nlk, nfill, nflush, nlive;
  int gap;
  logic        live_v;                   // check the page filled at the last edge
  logic [26:0] live_vpn;
  tid_t        live_t;
  logic        nx_live;                  // port 0's next lookup is this cycle's fill (its VPN went out as vpn_e)
  tid_t        nx_t;
  initial begin
    void'($urandom(SEED));
    for (int i = 0; i < 24; i++) pool[i] = 27'($urandom);
    mism = 0; nhit = 0; nlk = 0; nfill = 0; nflush = 0; nlive = 0;
    fill = 1'b0; flush = 1'b0; fill_vpn = '0; fill_lvl = '0; fill_pte = '0; fill_tid = '0; flush_tid = '0;
    for (int r = 0; r < NR; r++) begin vpn[r] = pick_vpn(); vpn_next[r] = pick_vpn(); lk_tid[r] = '0; end
    vpn_e = vpn_next;
    live_v = 1'b0;
    nx_live = 1'b0;
    nx_t = '0;
    gap = 8;
    repeat (3) @(posedge clk);
    @(negedge clk) rst = 1'b0;
    repeat (40) @(negedge clk);           // the CAM's table sweep (32 cycles)
    for (int cyc = 0; cyc < CYCLES; cyc++) begin
      // This cycle's lookups: last cycle's next VPNs (an EARLY port saw them a cycle ahead)
      vpn = vpn_next;
      for (int r = 0; r < NR; r++) begin
        lk_tid[r]   = tid_t'($urandom_range(0, NT - 1));
        vpn_next[r] = pick_vpn();
      end
      if (nx_live) lk_tid[0] = nx_t;       // port 0 looks up the page filled at the last edge, by its thread
      // Fill: at least 6 cycles apart
      fill = 1'b0;
      if (gap > 0) gap--;
      else if ($urandom_range(0, 3) == 0) begin
        fill     = 1'b1;
        fill_tid = tid_t'($urandom_range(0, NT - 1));
        fill_lvl = 2'($urandom_range(0, 2));
        fill_vpn = pick_vpn();
        fill_pte = tlb_pte_t'({$urandom, $urandom});
        gap = 6 + $urandom_range(0, 6);
      end
      flush = ($urandom_range(0, 99) < 2);
      flush_tid = tid_t'($urandom_range(0, NT - 1));
      nx_live = fill;                     // next cycle, port 0 looks up this fill's page (a cycle ahead: vpn_e)
      if (fill) begin vpn_next[0] = fill_vpn; nx_t = fill_tid; end
      vpn_e = vpn_next;
      #1;
      // ---- Checks at every port ----
      for (int r = 0; r < NR; r++) begin
        int found;
        ent_t e;
        found = 0;
        foreach (model[int'(lk_tid[r])][i])
          if (covers(model[int'(lk_tid[r])][i].vpn, model[int'(lk_tid[r])][i].lvl, vpn[r])) begin
            found++; e = model[int'(lk_tid[r])][i];
          end
        nlk++;
        if (hit[r]) begin
          tlb_pte_t x;
          nhit++;
          if (found != 1) begin
            if (mism < 10) $display("MISMATCH cycle %0d port %0d thread %0d: a hit at VPN %h with %0d model pages",
                                    cyc, r, lk_tid[r], vpn[r], found);
            mism++;
          end else begin
            x = e.pte;
            if (e.lvl != 2'd0) x.ppn[8:0]  = vpn[r][8:0];
            if (e.lvl == 2'd2) x.ppn[17:9] = vpn[r][17:9];
            if (pte[r] != x) begin
              if (mism < 10) $display("MISMATCH cycle %0d port %0d thread %0d VPN %h: pte %h, model %h", cyc, r,
                                      lk_tid[r], vpn[r], pte[r], x);
              mism++;
            end
          end
        end else if (r == 0 && live_v) begin
          if (mism < 10) $display("MISMATCH cycle %0d: thread %0d's page %h, filled at the last edge, misses", cyc,
                                  live_t, live_vpn);
          mism++;
        end
        if (r == 0 && live_v) nlive++;
      end
      @(posedge clk);
      // ---- The model follows the edge: the flush of its hart, then the fill unless the flush took its thread ----
      live_v = 1'b0;
      if (flush) begin model[int'(flush_tid)].delete(); nflush++; end
      if (fill && !(flush && flush_tid == fill_tid)) begin
        for (int i = model[int'(fill_tid)].size() - 1; i >= 0; i--)
          if (overlap(model[int'(fill_tid)][i].vpn, model[int'(fill_tid)][i].lvl, fill_vpn, fill_lvl))
            model[int'(fill_tid)].delete(i);
        model[int'(fill_tid)].push_back('{vpn: fill_vpn, lvl: fill_lvl, pte: fill_pte});
        nfill++;
        live_v   = 1'b1;
        live_vpn = fill_vpn;
        live_t   = fill_tid;
      end
      @(negedge clk);
    end
    if (mism == 0)
      $display("TB_TLB PASS: %0d cycles, %0d lookups, %0d hits, %0d fills, %0d flushes, %0d liveness checks", CYCLES,
               nlk, nhit, nfill, nflush, nlive);
    else
      $display("TB_TLB FAIL: %0d mismatches", mism);
    $finish;
  end
endmodule
