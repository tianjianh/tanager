`timescale 1ns/1ps
// tg_urf against the LUTRAM register file it would replace (spikes.md §8.14): three banks of
// tg_ram_lut with seven read ports and a bank select, as tg_irf, whose reads are asynchronous and
// whose writes land at the end of the cycle; the early ports' addresses go through a register, as
// today's issue -> RF register. tg_urf runs on the vendor's URAM288_BASE model (unisims_ver).
// Every core cycle sets random writes on all three ports, random early addresses for the next cycle
// and a random late address for this one, biased to collide with the writes: a read of an address
// written in the same cycle (it must return the old data), and in the cycle before (the new data).
// One core cycle after it starts, every read port's data must equal the reference's.
module tb_urf #(
  parameter int    NE    = 6,
  parameter int    NL    = 1,
  parameter string WMODE = "mid"
);
  localparam int NB = 3, DEPTH = 64, W = 64, NR = NE + NL, IW = 6, BW = 2;
  // nothing is written for START cycles (glbl holds the vendor model's global reset for 100 ns), then
  // every entry is filled once before the random phase
  localparam int CYCLES = 200000, START = 20, INIT = START + DEPTH + 2;

  // The core clock and twice it, rising together at every core edge (10, 20, ... ns)
  logic clk = 1'b1, clk2x = 1'b1;
  always #2.5 clk2x = ~clk2x;
  always #5.0 clk   = ~clk;

  logic [NB-1:0]          we;
  logic [NB-1:0][IW-1:0]  waddr;
  logic [NB-1:0][W-1:0]   wdata;
  logic [NE-1:0][BW-1:0]  e_bank_n;
  logic [NE-1:0][IW-1:0]  e_idx_n;
  logic [NL-1:0]          l_en;
  logic [NL-1:0][BW-1:0]  l_bank;
  logic [NL-1:0][IW-1:0]  l_idx;
  logic [NR-1:0][W-1:0]   rdata, ref_rdata;

  tg_urf #(.NB(NB), .DEPTH(DEPTH), .W(W), .NE(NE), .NL(NL), .WMODE(WMODE)) dut (
    .clk, .clk2x, .we, .waddr, .wdata, .e_bank_n, .e_idx_n, .l_en, .l_bank, .l_idx, .rdata);

  // ---- Reference ----
  logic [NE-1:0][BW-1:0]        r_bank_q;
  logic [NE-1:0][IW-1:0]        r_idx_q;
  logic [NR-1:0][IW-1:0]        r_raddr;
  logic [NR-1:0][BW-1:0]        r_rbank;
  logic [NB-1:0][NR-1:0][W-1:0] r_bank_rd;
  always_ff @(posedge clk) begin
    r_bank_q <= e_bank_n;
    r_idx_q  <= e_idx_n;
  end
  always_comb begin
    for (int p = 0; p < NE; p++) begin r_raddr[p] = r_idx_q[p]; r_rbank[p] = r_bank_q[p]; end
    for (int l = 0; l < NL; l++) begin r_raddr[NE + l] = l_idx[l]; r_rbank[NE + l] = l_bank[l]; end
  end
  for (genvar b = 0; b < NB; b++) begin : g_ref
    tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(W), .NR(NR)) u_ram (
      .clk, .we(we[b]), .waddr(waddr[b]), .wdata(wdata[b]), .raddr(r_raddr), .rdata(r_bank_rd[b]));
  end
  always_comb for (int p = 0; p < NR; p++) ref_rdata[p] = r_bank_rd[r_rbank[p]][p];

  // ---- Stimulus: set at each core edge for the cycle it starts (early addresses: the next one) ----
  int unsigned cyc = 0;
  // collision cases exercised, per read kind (early, late): read of an address written this cycle,
  // and of one written the cycle before
  int unsigned n_same_e = 0, n_same_l = 0, n_prev_e = 0, n_prev_l = 0, n_checks = 0, n_err = 0;
  logic [NE-1:0][BW-1:0] cur_bank;   // this cycle's early reads (presented in the last cycle)
  logic [NE-1:0][IW-1:0] cur_idx;
  initial begin
    we = '0; waddr = '0; wdata = '0; e_bank_n = '0; e_idx_n = '0; l_en = '0; l_bank = '0; l_idx = '0;
  end
  always @(posedge clk) begin
    logic [NB-1:0]          nwe;
    logic [NB-1:0][IW-1:0]  nwa;
    logic [NB-1:0][W-1:0]   nwd;
    logic [NE-1:0][BW-1:0]  neb;
    logic [NE-1:0][IW-1:0]  nei;
    logic [NL-1:0][BW-1:0]  nlb;
    logic [NL-1:0][IW-1:0]  nli;
    int p, b;
    cur_bank = e_bank_n;     // presented in the cycle that ends now: read in the cycle that starts
    cur_idx  = e_idx_n;
    for (b = 0; b < NB; b++) begin
      nwd[b] = {$urandom, $urandom};
      if (cyc < START) begin
        nwe[b] = 1'b0; nwa[b] = '0;
      end else if (cyc < START + DEPTH) begin  // fill every entry first
        nwe[b] = 1'b1; nwa[b] = IW'(cyc - START);
      end else begin
        nwe[b] = ($urandom_range(3) != 0);
        nwa[b] = IW'($urandom_range(DEPTH - 1));
        // a third of the time, write an address an early port reads in this cycle
        if ($urandom_range(2) == 0) begin
          p = $urandom_range(NE - 1);
          if (cur_bank[p] == BW'(b)) nwa[b] = cur_idx[p];
        end
      end
    end
    for (int l = 0; l < NL; l++) begin
      nlb[l] = BW'($urandom_range(NB - 1));
      nli[l] = IW'($urandom_range(DEPTH - 1));
      // a third of the time, read the address being written in this cycle
      if ($urandom_range(2) == 0) nli[l] = nwa[nlb[l]];
      // and a sixth, the one written in the last cycle
      else if ($urandom_range(1) == 0) nli[l] = waddr[nlb[l]];
    end
    for (p = 0; p < NE; p++) begin
      neb[p] = BW'($urandom_range(NB - 1));
      nei[p] = IW'($urandom_range(DEPTH - 1));
      // a third of the time, next cycle reads what this cycle writes
      if ($urandom_range(2) == 0) nei[p] = nwa[neb[p]];
    end
    // count the collisions the cycle starting now exercises (reads against this cycle's writes,
    // and against the last cycle's)
    if (cyc >= INIT) begin
      for (p = 0; p < NE; p++) begin
        if (nwe[cur_bank[p]] && nwa[cur_bank[p]] == cur_idx[p]) n_same_e++;
        if (we[cur_bank[p]] && waddr[cur_bank[p]] == cur_idx[p]) n_prev_e++;
      end
      for (int l = 0; l < NL; l++) begin
        if (nwe[nlb[l]] && nwa[nlb[l]] == nli[l]) n_same_l++;
        if (we[nlb[l]] && waddr[nlb[l]] == nli[l]) n_prev_l++;
      end
    end
    we <= nwe; waddr <= nwa; wdata <= nwd;
    e_bank_n <= neb; e_idx_n <= nei;
    l_en <= '1; l_bank <= nlb; l_idx <= nli;
    cyc <= cyc + 1;
  end

  // ---- Check: 1 ns before each core edge, the cycle's data on every port ----
  always @(posedge clk) begin
    #9.0;
    if (cyc > INIT) begin
      for (int p = 0; p < NR; p++) begin
        n_checks++;
        if (rdata[p] !== ref_rdata[p]) begin
          n_err++;
          if (n_err <= 10)
            $display("MISMATCH cycle %0d port %0d (%s): urf %h, LUTRAM %h", cyc, p,
                     (p < NE) ? "early" : "late", rdata[p], ref_rdata[p]);
        end
      end
    end
    if (cyc == CYCLES) begin
      $display("TB_URF %s (WMODE %s, %0d early + %0d late ports): %0d cycles, %0d port reads checked, %0d mismatches",
               (n_err == 0) ? "PASS" : "FAIL", WMODE, NE, NL, cyc - INIT, n_checks, n_err);
      $display("TB_URF collisions: early reads of an address written that cycle %0d, the cycle before %0d;", n_same_e, n_prev_e);
      $display("TB_URF             late reads of an address written that cycle %0d, the cycle before %0d", n_same_l, n_prev_l);
      $finish;
    end
  end
endmodule
