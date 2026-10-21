// Free lists of one register bank (docs/spec/core-pipeline.md §5.2), one list per thread (M7's D3, RAM form): each
// thread's circular list of free register indices lives in NB interleaved LUTRAMs at {tid, row} (entry e of a list in
// sub-bank e mod NB), so NPOP pops and NPUSH pushes per cycle each touch a sub-bank at most once (plan §4.4, §4.15
// rule 3). The pops of a cycle come from one thread's list (the rename group's, pop_tid), and the pushes and the commit
// count go to one thread's (the commit group's, push_tid).
//   spec head:   pops at rename;
//   commit head: advanced at commit by the registers retiring instructions allocated;
//   tail:        pushes of freed registers at commit.
// A flush returns every register the flushed thread's squashed instructions allocated: its spec head <- its commit head.
// A register returns to the list of the thread that frees it, which is the thread that allocated it, so each thread
// keeps the registers it started with, but for transfers (below).
// After reset an init sequence writes the lists (NB entries per cycle); `ready` then rises:
//   merged mode (SPLIT_L = 0; the core runs one thread, RUN_TID): that thread's list holds FIRST .. DEPTH-1, as the one
//     list did before M7, and the other thread's is empty;
//   divided (SPLIT_L, with two threads: M7's step 5): FIRST_S .. DEPTH-1 is divided, the lower half to thread 0 and
//     the upper to thread 1.
// Transfers (divided lists, D3 revised): a static division alone deadlocks (writer-sharded banks: a thread can need all
// its architectural registers plus one in one bank), so a thread whose rename group waits for this bank's registers
// (`want`, registered by rename, with its thread) takes one a cycle from the tail of its sibling's list, the sibling
// keeping 1 (its free count at least 2): the sibling's entry at tail - 1 is free both speculatively and after any flush
// (count >= 1 implies commit count >= 1). It leaves the sibling's list (its tail and both counts - 1) and joins the
// taker's at its tail, as a committed push (tail and both counts + 1). A transfer runs only while the taker's group is
// at rename (pop_tid), so the sibling does not pop, and in a cycle with no push to this bank and no flush, so the write
// port and both tails are its own; it reads the sibling's entry on a second read port of each sub-bank. A sibling
// asleep in WFI gives up its spares this way. With `give_last` the giver gives its last one too (count >= 1 is all the
// entry needs): rename sets it for the integer lists, since a two-wide group can need two registers in a bank that
// both harts' 62 architectural registers fill to two short of full (a trap return restores every register with loads,
// into the load bank), and a giver keeping 1 then left each hart one short for good (soc-2's one-core boot, 10-21).
// The pointers wrap at DEPTH, a multiple of NB (FP banks of 96 with two threads, D3 revised): each is an index below
// DEPTH and a lap bit, which is the plain binary pointer when DEPTH is a power of two.
// The free counts (tail - spec head) are registers, kept with the commit counts (tail - commit head) that they take on
// a flush, so rename's resource checks start from flip-flops rather than a subtraction (timing; the same values,
// asserted). Rename's fire (`pop`) arrives last, after its own resource checks: the next head and count are formed
// with and without the pops, and `pop` picks one (timing: the add leaves rename's count -> fire -> count loop).
module tg_freelist
  import tg_pkg::*, tg_core_pkg::*;
#(
  parameter int DEPTH   = INT_PREGS_PER_BANK,
  parameter int NB      = FL_BANKS,
  parameter int NPOP    = RENAME_WIDTH,
  parameter int NPUSH   = COMMIT_WIDTH,
  parameter int FIRST   = 0,
  parameter bit SPLIT_L = 1'b0,    // divided lists: with two threads (M7's step 5; D3 needs transfers too)
  parameter int FIRST_S = FIRST,
  localparam int NT     = NUM_THREADS,
  localparam int IW     = idx_w(DEPTH),
  localparam int PW     = IW + 1,
  localparam int ROWS   = DEPTH / NB,
  localparam int RW     = idx_w(ROWS),
  localparam int BW     = idx_w(NB),
  localparam int NPW    = idx_w(NPOP + 1),
  localparam int NUW    = idx_w(NPUSH + 1)
) (
  input  logic                      clk,
  input  logic                      rst,
  output logic                      ready,
  output logic [NT-1:0][PW-1:0]     count,      // each thread's free registers after its spec head
  input  tid_t                      pop_tid,    // the thread whose list the pops take
  output logic [NPOP-1:0][IW-1:0]   pop_idx,    // its next NPOP free registers
  input  logic [NPW-1:0]            pop_n,      // the pops, taken when `pop`
  input  logic                      pop,
  input  tid_t                      push_tid,   // the thread whose list the pushes and commit_n go to
  input  logic [NPUSH-1:0]          push_v,     // any subset; written in slot order
  input  logic [NPUSH-1:0][IW-1:0]  push_idx,
  input  logic [NUW-1:0]            commit_n,
  input  logic                      flush,
  input  tid_t                      flush_tid,
  input  logic                      want,       // divided lists: want_tid's group waits for this bank's registers
  input  tid_t                      want_tid,
  input  logic                      give_last,  // the giver may give its last free register (else it keeps 1)
  output logic                      xfer        // a register moves to want_tid's list from its sibling's this cycle
);
  if (NB < NPOP || NB < NPUSH || (DEPTH % NB) != 0 || (NB & (NB - 1)) != 0) begin : g_bad
    $error("tg_freelist: NB must be a power of two >= NPOP, NPUSH and divide DEPTH");
  end
  // Pointers: {lap, index below DEPTH}; with DEPTH a power of two, the binary pointer
  localparam bit POW2 = (DEPTH & (DEPTH - 1)) == 0;
  function automatic logic [PW-1:0] padd(input logic [PW-1:0] p, input logic [PW-1:0] n);   // p + n, n <= DEPTH
    logic [IW:0] s;
    if (POW2) return p + n;
    s = {1'b0, p[IW-1:0]} + n;
    if (int'(s) >= DEPTH) return {~p[IW], IW'(int'(s) - DEPTH)};
    return {p[IW], IW'(s)};
  endfunction
  function automatic logic [PW-1:0] pdec(input logic [PW-1:0] p);               // p - 1
    if (POW2) return p - 1'b1;
    if (p[IW-1:0] == '0) return {~p[IW], IW'(DEPTH - 1)};
    return {p[IW], p[IW-1:0] - 1'b1};
  endfunction
  function automatic logic [PW-1:0] pinit(input logic [PW-1:0] n);               // n entries from 0
    return (int'(n) >= DEPTH) ? {1'b1, IW'(int'(n) - DEPTH)} : {1'b0, n[IW-1:0]};
  endfunction
  // The lists' initial contents: thread t's list holds LO[t] .. LO[t] + N[t] - 1
  localparam int MID   = FIRST_S + (DEPTH - FIRST_S) / 2;
  localparam int N0    = SPLIT_L ? MID - FIRST_S : ((NT == 1 || RUN_TID == 0) ? DEPTH - FIRST : 0);
  localparam int N1    = SPLIT_L ? DEPTH - MID   : ((NT > 1 && RUN_TID == 1) ? DEPTH - FIRST : 0);
  localparam int LO0   = SPLIT_L ? FIRST_S : FIRST;
  localparam int LO1   = SPLIT_L ? MID : FIRST;
  localparam int NINIT = N0 + ((NT > 1) ? N1 : 0);
  if (SPLIT_L && (NT == 1 || (N0 % NB) != 0)) begin : g_bad_split
    $error("tg_freelist: split mode needs two threads and thread 0's share a multiple of NB");
  end
  localparam int TW = (NT > 1) ? 1 : 0;           // the tid's bit in the LUTRAMs' address
  // The threads that pop, push and flush (without SMT thread 0, whatever the tid bits hold)
  tid_t pt, ut, ft;
  assign pt = (NT > 1) ? pop_tid : tid_t'(0);
  assign ut = (NT > 1) ? push_tid : tid_t'(0);
  assign ft = (NT > 1) ? flush_tid : tid_t'(0);

  logic [NT-1:0][PW-1:0] head_q, chead_q, tail_q;
  logic [NT-1:0][PW-1:0] count_q, ccount_q;       // tail - head, tail - commit head
  logic [PW-1:0]         init_q;
  assign ready = init_q >= PW'(NINIT);
  assign count = count_q;

  // ---- Transfers (divided lists): the taker want_tid, its sibling the giver ----
  localparam bit XF = SPLIT_L && NT > 1;
  tid_t          xt, xg;                           // taker, giver
  logic          xgo;
  logic [PW-1:0] xge;                              // the giver's last entry (tail - 1)
  assign xt  = (NT > 1) ? want_tid : tid_t'(0);
  assign xg  = (NT > 1) ? ~want_tid : tid_t'(0);
  assign xge = pdec(tail_q[xg]);
  assign xgo = XF && ready && want && pt == xt && int'(count_q[xg]) >= (give_last ? 1 : 2) && !(|push_v) && !flush;
  assign xfer = xgo;

  // ---- Writes: the init sequence, the pushes at the pushing thread's tail + rank, or a transfer at the taker's ----
  logic [NB-1:0]               we;
  logic [NB-1:0][RW+TW-1:0]    wa;
  logic [NB-1:0][IW-1:0]       wd;
  logic [NUW-1:0]              npush;
  logic [IW-1:0]               xd;               // the transferred register (the giver's entry, read on port 1)
  function automatic logic [RW+TW-1:0] ram_a(input tid_t t, input logic [RW-1:0] row);
    return (RW+TW)'({t, row});                    // without SMT the tid's bit falls off
  endfunction
  always_comb begin
    logic [PW-1:0] ie;                            // the init entry: thread 0's list, then thread 1's
    logic [PW-1:0] pe;
    tid_t          it;
    we = '0; wa = '0; wd = '0;
    npush = '0;
    ie = '0; pe = '0; it = '0;
    if (!ready) begin
      for (int b = 0; b < NB; b++) begin
        ie = init_q + PW'(b);
        if (int'(ie) < NINIT) begin
          // merged mode: the running thread's list alone; split: thread 0's N0 entries, then thread 1's
          it = SPLIT_L ? ((int'(ie) < N0) ? tid_t'(0) : tid_t'(1)) : RUN_TID;
          pe = (SPLIT_L && int'(ie) >= N0) ? PW'(int'(ie) - N0) : ie;
          we[pe[BW-1:0]] = 1'b1;
          wa[pe[BW-1:0]] = ram_a(it, pe[IW-1:BW]);
          wd[pe[BW-1:0]] = IW'(int'(pe) + ((it == tid_t'(1)) ? LO1 : LO0));
        end
      end
    end else begin
      for (int j = 0; j < NPUSH; j++) begin
        if (push_v[j]) begin
          pe = padd(tail_q[ut], PW'(npush));
          we[pe[BW-1:0]] = 1'b1;
          wa[pe[BW-1:0]] = ram_a(ut, pe[IW-1:BW]);
          wd[pe[BW-1:0]] = push_idx[j];
          npush = npush + 1'b1;
        end
      end
      if (xgo) begin                              // (no push this cycle)
        pe = tail_q[xt];
        we[pe[BW-1:0]] = 1'b1;
        wa[pe[BW-1:0]] = ram_a(xt, pe[IW-1:BW]);
        wd[pe[BW-1:0]] = xd;
      end
    end
  end

  // ---- Reads: pop slot i reads the popping thread's entry head + i; port 1, the giver's last entry ----
  localparam int NRP = XF ? 2 : 1;
  logic [PW-1:0]         ph;                      // the popping thread's spec head
  assign ph = head_q[pt];
  logic [NB-1:0][IW-1:0] rd, rd1;
  for (genvar b = 0; b < NB; b++) begin : g_bank
    logic [PW-1:0] e;
    assign e = padd(ph, PW'(BW'(BW'(b) - ph[BW-1:0])));
    logic [NRP-1:0][RW+TW-1:0] r;
    logic [NRP-1:0][IW-1:0]    q;
    assign r[0] = ram_a(pt, e[IW-1:BW]);
    if (XF) begin : g_x
      assign r[1]   = ram_a(xg, xge[IW-1:BW]);
      assign rd1[b] = q[1];
    end else begin : g_nx
      assign rd1[b] = '0;
    end
    tg_ram_lut #(.DEPTH(NT << RW), .WIDTH(IW), .NR(NRP)) u_ram (
      .clk, .we(we[b]), .waddr(wa[b]), .wdata(wd[b]), .raddr(r), .rdata(q));
    assign rd[b] = q[0];
    logic unused;
    assign unused = ^{e[BW-1:0], e[IW]};
  end
  assign xd = rd1[xge[BW-1:0]];
  for (genvar i = 0; i < NPOP; i++) begin : g_pop
    logic [BW-1:0] b;
    assign b = BW'(ph[BW-1:0] + BW'(i));
    assign pop_idx[i] = rd[b];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      head_q   <= '0;
      chead_q  <= '0;
      tail_q   <= '0;
      count_q  <= '0;
      ccount_q <= '0;
      init_q   <= '0;
    end else if (!ready) begin
      init_q <= init_q + PW'(NB);
      if (int'(init_q) + NB >= NINIT) begin
        tail_q[0]   <= pinit(PW'(N0));
        count_q[0]  <= PW'(N0);
        ccount_q[0] <= PW'(N0);
        if (NT > 1) begin
          tail_q[NT-1]   <= pinit(PW'(N1));
          count_q[NT-1]  <= PW'(N1);
          ccount_q[NT-1] <= PW'(N1);
        end
      end
    end else begin
      for (int t = 0; t < NT; t++) begin
        logic [NUW-1:0] np, nc;                   // this thread's pushes and commits
        logic           xi, xo;                   // a transfer to it, from it (no push and no flush then)
        np = (ut == tid_t'(t)) ? npush : '0;
        nc = (ut == tid_t'(t)) ? commit_n : '0;
        xi = xgo && xt == tid_t'(t);
        xo = xgo && xg == tid_t'(t);
        tail_q[t]   <= xi ? padd(tail_q[t], PW'(1)) : xo ? xge : padd(tail_q[t], PW'(np));
        chead_q[t]  <= padd(chead_q[t], PW'(nc));
        ccount_q[t] <= ccount_q[t] + PW'(np) - PW'(nc) + PW'(xi) - PW'(xo);
        if (flush && ft == tid_t'(t)) begin
          head_q[t]  <= padd(chead_q[t], PW'(nc));
          count_q[t] <= ccount_q[t] + PW'(np) - PW'(nc);
        end else if (pt == tid_t'(t)) begin
          head_q[t]  <= pop ? padd(head_q[t], PW'(pop_n)) : head_q[t];
          count_q[t] <= pop ? count_q[t] + PW'(np) + PW'(xi) - PW'(pop_n) : count_q[t] + PW'(np) + PW'(xi);
        end else begin
          count_q[t] <= count_q[t] + PW'(np) - PW'(xo);
        end
      end
    end
  end

`ifndef SYNTHESIS
  function automatic int pdist(input logic [PW-1:0] a, input logic [PW-1:0] b);   // a - b, entries
    if (POW2) return int'(PW'(a - b));
    return (a[IW] == b[IW]) ? int'(a[IW-1:0]) - int'(b[IW-1:0]) : DEPTH + int'(a[IW-1:0]) - int'(b[IW-1:0]);
  endfunction
  always_ff @(posedge clk) begin
    if (!rst && ready) begin
      assert (!pop || PW'(pop_n) <= count[pt]) else $error("tg_freelist: pop beyond the free registers");
      for (int t = 0; t < NT; t++) begin
        assert (int'(count_q[t]) == pdist(tail_q[t], head_q[t]) && int'(ccount_q[t]) == pdist(tail_q[t], chead_q[t]))
          else $error("tg_freelist: thread %0d's free counts differ from its pointers", t);
        assert (int'(tail_q[t][IW-1:0]) < DEPTH && int'(head_q[t][IW-1:0]) < DEPTH && int'(chead_q[t][IW-1:0]) < DEPTH)
          else $error("tg_freelist: thread %0d's pointer beyond the list", t);
        assert (int'(count[t]) + ((ut == tid_t'(t)) ? int'(npush) : 0) + ((xgo && xt == tid_t'(t)) ? 1 : 0) <= DEPTH)
          else $error("tg_freelist: thread %0d's list overflows", t);
      end
      // a transfer leaves the giver at least one register and comes with no pop of the giver's
      if (xgo) assert (int'(count_q[xg]) >= (give_last ? 1 : 2) && pt != xg) else $error("tg_freelist: a transfer from a short list");
    end
  end
`endif
endmodule
