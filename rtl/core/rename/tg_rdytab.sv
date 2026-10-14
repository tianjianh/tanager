// Ready table of one register file in LUTRAM (docs/spec/core-pipeline.md §5.2, plan §8.5;
// FPGA-friendly form T2, docs/perf/fpga_friendly.md): one bit per physical register, set when
// the register is written and cleared when rename allocates it. It replaces a flip-flop vector
// with a set port per bank and a clear port per rename slot, and reads the same in every cycle.
// Each register is two phase bits, ready = (A == S):
//   S, the set phase: one table per bank, written only by that bank's register-file port.
//   A, the allocation phase: any rename slot may allocate in any bank, so A is XOR-banked by
//      slot: A = A^0 ^ ... ^ A^(W-1), and slot k writes only A^k (LaForest et al., "Multi-ported
//      memories for FPGAs via XOR", FPGA 2012).
// A set of p writes S[p] := A[p]; a clear of p writes A^c[p] := !S'[p] ^ (the other A^j[p]),
// where S' is S after this cycle's set, so a set and a clear of p in one cycle leave p not ready
// (the clear wins, as when a flip-flop table applies the clear last).
// The clears do not wait for rename: every cycle, each bank's next W free registers (cand_i,
// from its free list's head; cand_v: the list holds that many) are cleared, candidate c through
// A^c, whether or not rename takes them. A free register's ready bit is never read (no map holds
// it, and every reader of its last value read it before it was freed), so clearing it early is
// invisible, and the register is cleared again in the cycle rename allocates it, as before.
// Reads are asynchronous and see the table as it was before this cycle's writes, as flip-flops
// would. A table can't be reset: after reset a sweep writes zeros (every register ready) in
// DEPTH cycles, and `ready` rises when it is done; the D$ sweep after reset takes as long.
// Read ports per bank: S has NR + W (the reads, and the candidates), every A^k NR + 1 + W (the
// reads, the bank's set, and the candidates).
module tg_rdytab
  import tg_pkg::*;
#(
  parameter int NB    = 3,          // banks (one set port each)
  parameter int DEPTH = 64,         // registers per bank
  parameter int W     = 2,          // clear ports (rename slots), and candidates per bank
  parameter int NR    = 6,          // read ports
  localparam int BW   = (NB > 1) ? idx_w(NB) : 1,
  localparam int IW   = idx_w(DEPTH)
) (
  input  logic                      clk,
  input  logic                      rst,
  output logic                      ready,
  input  logic [NB-1:0]             set_v,
  input  logic [NB-1:0][IW-1:0]     set_i,
  input  logic [NB-1:0][W-1:0]      cand_v,     // each bank's next W free registers: cleared
  input  logic [NB-1:0][W-1:0][IW-1:0] cand_i,
  input  logic [NR-1:0][BW-1:0]     rd_b,
  input  logic [NR-1:0][IW-1:0]     rd_i,
  output logic [NR-1:0]             rdy
);
  localparam int NRA = NR + 1 + W;   // A read ports: reads, the bank's set, the candidates
  localparam int NRS = NR + W;       // S read ports: reads, the candidates

  logic [IW:0] sw_q;                 // reset sweep: entry written this cycle
  assign ready = sw_q[IW];
  always_ff @(posedge clk) begin
    if (rst)         sw_q <= '0;
    else if (!ready) sw_q <= sw_q + 1'b1;
  end

  logic [NB-1:0][NR-1:0] b_rdy;      // per bank: ready at each read address

  for (genvar b = 0; b < NB; b++) begin : g_bank
    logic [W-1:0][NRA-1:0] a_rd;
    logic [NRS-1:0]        s_rd;

    // ---- Read addresses ----
    logic [NRA-1:0][IW-1:0] ara;
    logic [NRS-1:0][IW-1:0] sra;
    for (genvar r = 0; r < NR; r++) begin : g_rra
      assign ara[r] = rd_i[r];
      assign sra[r] = rd_i[r];
    end
    assign ara[NR] = set_i[b];
    for (genvar c = 0; c < W; c++) begin : g_cra
      assign ara[NR + 1 + c] = cand_i[b][c];
      assign sra[NR + c]     = cand_i[b][c];
    end

    // ---- Old values at the candidates: A, and S after this cycle's set ----
    logic [W-1:0] c_a, c_s;
    always_comb begin
      for (int c = 0; c < W; c++) begin
        c_a[c] = 1'b0;
        for (int j = 0; j < W; j++) c_a[c] ^= a_rd[j][NR + 1 + c];
        c_s[c] = (set_v[b] && set_i[b] == cand_i[b][c]) ? c_a[c] : s_rd[NR + c];
      end
    end

    // ---- S: set phase, written by the bank's port: S[i] := A[i] ----
    logic aset;
    always_comb begin
      aset = 1'b0;
      for (int k = 0; k < W; k++) aset ^= a_rd[k][NR];
    end
    logic          s_we, s_wd;
    logic [IW-1:0] s_wa;
    assign s_we = !ready || set_v[b];
    assign s_wa = ready ? set_i[b] : sw_q[IW-1:0];
    assign s_wd = ready && aset;
    tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(1), .NR(NRS)) u_s (
      .clk, .we(s_we), .waddr(s_wa), .wdata(s_wd), .raddr(sra), .rdata(s_rd));

    // ---- A^c: allocation phase, cleared at candidate c: A^c[i] := !S'[i] ^ (A[i] ^ A^c[i]) ----
    for (genvar c = 0; c < W; c++) begin : g_a
      logic          a_we, a_wd;
      logic [IW-1:0] a_wa;
      assign a_we = !ready || cand_v[b][c];
      assign a_wa = ready ? cand_i[b][c] : sw_q[IW-1:0];
      assign a_wd = ready && (!c_s[c] ^ c_a[c] ^ a_rd[c][NR + 1 + c]);
      tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(1), .NR(NRA)) u_a (
        .clk, .we(a_we), .waddr(a_wa), .wdata(a_wd), .raddr(ara), .rdata(a_rd[c]));
    end

    // ---- Reads ----
    for (genvar r = 0; r < NR; r++) begin : g_rdy
      always_comb begin
        logic a;
        a = 1'b0;
        for (int k = 0; k < W; k++) a ^= a_rd[k][r];
        b_rdy[b][r] = a == s_rd[r];
      end
    end
  end

  for (genvar r = 0; r < NR; r++) begin : g_out
    assign rdy[r] = b_rdy[rd_b[r]][r];
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && ready) begin
      for (int b = 0; b < NB; b++)
        for (int c = 0; c < W; c++)
          for (int d = c + 1; d < W; d++)
            assert (!(cand_v[b][c] && cand_v[b][d] && cand_i[b][c] == cand_i[b][d]))
              else $error("tg_rdytab: two candidates name one register");
    end
  end
`endif
endmodule
