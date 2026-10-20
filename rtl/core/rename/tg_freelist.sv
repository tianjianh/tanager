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
// keeps the registers it started with.
// After reset an init sequence writes the lists (NB entries per cycle); `ready` then rises:
//   merged mode (SPLIT_L = 0; the core runs one thread, RUN_TID): that thread's list holds FIRST .. DEPTH-1, as the one
//     list did before M7, and the other thread's is empty;
//   split mode (SPLIT_L, M7's step 3b): FIRST_S .. DEPTH-1 is divided, the lower half to thread 0 and the upper to thread 1.
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
  parameter bit SPLIT_L = SPLIT,   // the split mode (tg_core_pkg::SPLIT; the unit test sets it)
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
  input  tid_t                      flush_tid
);
  if (NB < NPOP || NB < NPUSH || (DEPTH % NB) != 0 || (NB & (NB - 1)) != 0) begin : g_bad
    $error("tg_freelist: NB must be a power of two >= NPOP, NPUSH and divide DEPTH");
  end
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

  // ---- Writes: the init sequence, or the pushes at the pushing thread's tail + rank ----
  logic [NB-1:0]               we;
  logic [NB-1:0][RW+TW-1:0]    wa;
  logic [NB-1:0][IW-1:0]       wd;
  logic [NUW-1:0]              npush;
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
          pe = tail_q[ut] + PW'(npush);
          we[pe[BW-1:0]] = 1'b1;
          wa[pe[BW-1:0]] = ram_a(ut, pe[IW-1:BW]);
          wd[pe[BW-1:0]] = push_idx[j];
          npush = npush + 1'b1;
        end
      end
    end
  end

  // ---- Reads: pop slot i reads the popping thread's entry head + i ----
  logic [PW-1:0]         ph;                      // the popping thread's spec head
  assign ph = head_q[pt];
  logic [NB-1:0][IW-1:0] rd;
  for (genvar b = 0; b < NB; b++) begin : g_bank
    logic [IW-1:0] e;
    assign e = IW'(ph + PW'(BW'(BW'(b) - ph[BW-1:0])));
    logic [0:0][RW+TW-1:0] r;
    logic [0:0][IW-1:0]    q;
    assign r[0] = ram_a(pt, e[IW-1:BW]);
    tg_ram_lut #(.DEPTH(ROWS * NT), .WIDTH(IW), .NR(1)) u_ram (
      .clk, .we(we[b]), .waddr(wa[b]), .wdata(wd[b]), .raddr(r), .rdata(q));
    assign rd[b] = q[0];
    logic unused;
    assign unused = ^e[BW-1:0];
  end
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
        tail_q[0]   <= PW'(N0);
        count_q[0]  <= PW'(N0);
        ccount_q[0] <= PW'(N0);
        if (NT > 1) begin
          tail_q[NT-1]   <= PW'(N1);
          count_q[NT-1]  <= PW'(N1);
          ccount_q[NT-1] <= PW'(N1);
        end
      end
    end else begin
      for (int t = 0; t < NT; t++) begin
        logic [NUW-1:0] np, nc;                   // this thread's pushes and commits
        np = (ut == tid_t'(t)) ? npush : '0;
        nc = (ut == tid_t'(t)) ? commit_n : '0;
        tail_q[t]   <= tail_q[t] + PW'(np);
        chead_q[t]  <= chead_q[t] + PW'(nc);
        ccount_q[t] <= ccount_q[t] + PW'(np) - PW'(nc);
        if (flush && ft == tid_t'(t)) begin
          head_q[t]  <= chead_q[t] + PW'(nc);
          count_q[t] <= ccount_q[t] + PW'(np) - PW'(nc);
        end else if (pt == tid_t'(t)) begin
          head_q[t]  <= pop ? head_q[t] + PW'(pop_n) : head_q[t];
          count_q[t] <= pop ? count_q[t] + PW'(np) - PW'(pop_n) : count_q[t] + PW'(np);
        end else begin
          count_q[t] <= count_q[t] + PW'(np);
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && ready) begin
      assert (!pop || PW'(pop_n) <= count[pt]) else $error("tg_freelist: pop beyond the free registers");
      for (int t = 0; t < NT; t++) begin
        assert (count_q[t] == PW'(tail_q[t] - head_q[t]) && ccount_q[t] == PW'(tail_q[t] - chead_q[t]))
          else $error("tg_freelist: thread %0d's free counts differ from its pointers", t);
        assert (int'(count[t]) + ((ut == tid_t'(t)) ? int'(npush) : 0) <= DEPTH)
          else $error("tg_freelist: thread %0d's list overflows", t);
      end
    end
  end
`endif
endmodule
