// Free list of one register bank (docs/spec/core-pipeline.md §5.2): a circular list of free
// register indices in NB interleaved LUTRAMs (entry e in sub-bank e mod NB), so NPOP pops and
// NPUSH pushes per cycle each touch a sub-bank at most once (plan §4.4, §4.15 rule 3).
//   spec head:   pops at rename;
//   commit head: advanced at commit by the registers retiring instructions allocated;
//   tail:        pushes of freed registers at commit.
// A flush returns every register allocated by squashed instructions: spec head <- commit head.
// After reset an init sequence writes FIRST .. DEPTH-1 (NB entries per cycle); `ready` then rises.
module tg_freelist
  import tg_pkg::*;
#(
  parameter int DEPTH = INT_PREGS_PER_BANK,
  parameter int NB    = FL_BANKS,
  parameter int NPOP  = RENAME_WIDTH,
  parameter int NPUSH = COMMIT_WIDTH,
  parameter int FIRST = 0,
  localparam int IW   = idx_w(DEPTH),
  localparam int PW   = IW + 1,
  localparam int ROWS = DEPTH / NB,
  localparam int RW   = idx_w(ROWS),
  localparam int BW   = idx_w(NB),
  localparam int NPW  = idx_w(NPOP + 1),
  localparam int NUW  = idx_w(NPUSH + 1)
) (
  input  logic                      clk,
  input  logic                      rst,
  output logic                      ready,
  output logic [PW-1:0]             count,      // free registers after the spec head
  output logic [NPOP-1:0][IW-1:0]   pop_idx,    // the next NPOP free registers
  input  logic [NPW-1:0]            pop_n,
  input  logic [NPUSH-1:0]          push_v,     // any subset; written in slot order
  input  logic [NPUSH-1:0][IW-1:0]  push_idx,
  input  logic [NUW-1:0]            commit_n,
  input  logic                      flush
);
  if (NB < NPOP || NB < NPUSH || (DEPTH % NB) != 0 || (NB & (NB - 1)) != 0) begin : g_bad
    $error("tg_freelist: NB must be a power of two >= NPOP, NPUSH and divide DEPTH");
  end

  logic [PW-1:0] head_q, chead_q, tail_q;
  logic [PW-1:0] init_q;
  localparam logic [PW-1:0] NINIT = PW'(DEPTH - FIRST);
  assign ready = init_q >= NINIT;
  assign count = tail_q - head_q;

  // ---- Writes: init sequence or pushes, at tail + rank ----
  logic [NB-1:0]          we;
  logic [NB-1:0][RW-1:0]  wa;
  logic [NB-1:0][IW-1:0]  wd;
  logic [NUW-1:0]         npush;
  logic [PW-1:0] ie;
  logic [IW-1:0] pe;
  always_comb begin
    we = '0; wa = '0; wd = '0;
    npush = '0;
    ie = '0;
    pe = '0;
    if (!ready) begin
      for (int b = 0; b < NB; b++) begin
        ie = init_q + PW'(b);
        if (ie < NINIT) begin
          we[ie[BW-1:0]] = 1'b1;
          wa[ie[BW-1:0]] = ie[IW-1:BW];
          wd[ie[BW-1:0]] = IW'(int'(ie) + FIRST);
        end
      end
    end else begin
      for (int j = 0; j < NPUSH; j++) begin
        if (push_v[j]) begin
          pe = IW'(tail_q + PW'(npush));
          we[pe[BW-1:0]] = 1'b1;
          wa[pe[BW-1:0]] = pe[IW-1:BW];
          wd[pe[BW-1:0]] = push_idx[j];
          npush = npush + 1'b1;
        end
      end
    end
  end

  // ---- Reads: pop slot i reads entry head + i ----
  logic [NB-1:0][RW-1:0] ra;
  logic [NB-1:0][IW-1:0] rd;
  for (genvar b = 0; b < NB; b++) begin : g_bank
    logic [IW-1:0] e;
    assign e = IW'(head_q + PW'(BW'(BW'(b) - head_q[BW-1:0])));
    assign ra[b] = e[IW-1:BW];
    logic [0:0][RW-1:0] r;
    logic [0:0][IW-1:0] q;
    assign r[0] = ra[b];
    tg_ram_lut #(.DEPTH(ROWS), .WIDTH(IW), .NR(1)) u_ram (
      .clk, .we(we[b]), .waddr(wa[b]), .wdata(wd[b]), .raddr(r), .rdata(q));
    assign rd[b] = q[0];
    logic unused;
    assign unused = ^e[BW-1:0];
  end
  for (genvar i = 0; i < NPOP; i++) begin : g_pop
    logic [BW-1:0] b;
    assign b = BW'(head_q[BW-1:0] + BW'(i));
    assign pop_idx[i] = rd[b];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      head_q  <= '0;
      chead_q <= '0;
      tail_q  <= '0;
      init_q  <= '0;
    end else if (!ready) begin
      init_q <= init_q + PW'(NB);
      if (init_q + PW'(NB) >= NINIT) tail_q <= NINIT;
    end else begin
      tail_q  <= tail_q + PW'(npush);
      chead_q <= chead_q + PW'(commit_n);
      if (flush) head_q <= chead_q + PW'(commit_n);
      else       head_q <= head_q + PW'(pop_n);
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && ready) begin
      assert (PW'(pop_n) <= count) else $error("tg_freelist: pop beyond the free registers");
      assert (int'(count) + int'(npush) <= DEPTH) else $error("tg_freelist: overflow");
    end
  end
`endif
endmodule
