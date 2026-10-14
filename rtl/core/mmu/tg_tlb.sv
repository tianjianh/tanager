// Fully associative Sv39 TLB (docs/spec/core-mmu.md): NE entries in flip-flops; 4 KiB, 2 MiB and
// 1 GiB pages. NR combinational lookups; the PPN comes back with the superpage bits taken from
// the VA. No ASID tags: every satp change and SFENCE.VMA flushes the TLB (as Spike), so every
// entry belongs to the current address space.
// A fill first invalidates every entry whose page overlaps the new one (either may be the
// larger), so a lookup matches at most one entry and the result is a plain AND-OR; then it
// takes an invalid entry, else a round-robin victim. After spike S4's tg_dtlb.
module tg_tlb
  import tg_pkg::*, tg_core_pkg::*;
#(
  parameter int NE = 16,
  parameter int NR = 1,
  localparam int EW = idx_w(NE)
) (
  input  logic                clk,
  input  logic                rst,
  input  logic [NR-1:0][26:0] vpn,          // VA[38:12]
  output logic [NR-1:0]       hit,
  output tlb_pte_t [NR-1:0]   pte,
  input  logic                fill,
  input  logic [26:0]         fill_vpn,
  input  logic [1:0]          fill_lvl,     // 0: 4 KiB, 1: 2 MiB, 2: 1 GiB
  input  tlb_pte_t            fill_pte,
  input  logic                flush
);
  logic [NE-1:0]       v_q;
  logic [NE-1:0][26:0] vpn_q;
  logic [NE-1:0][1:0]  lvl_q;
  tlb_pte_t [NE-1:0]   pte_q;
  logic [EW-1:0]       rr_q;

  for (genvar r = 0; r < NR; r++) begin : g_rd
    logic [NE-1:0] m;
    for (genvar e = 0; e < NE; e++) begin : g_m
      assign m[e] = v_q[e] && vpn_q[e][26:18] == vpn[r][26:18] &&
                    (lvl_q[e] == 2'd2 || vpn_q[e][17:9] == vpn[r][17:9]) &&
                    (lvl_q[e] != 2'd0 || vpn_q[e][8:0] == vpn[r][8:0]);
    end
    always_comb begin
      logic [1:0] l;
      pte[r] = '0;
      l = '0;
      for (int e = 0; e < NE; e++) begin
        pte[r] |= {$bits(tlb_pte_t){m[e]}} & pte_q[e];
        l      |= {2{m[e]}} & lvl_q[e];
      end
      if (l != 2'd0) pte[r].ppn[8:0]  = vpn[r][8:0];
      if (l == 2'd2) pte[r].ppn[17:9] = vpn[r][17:9];
    end
    assign hit[r] = |m;
  end

  // Fill: entries overlapping the new page go; the new one takes an invalid entry or the victim
  logic [NE-1:0] ov;
  for (genvar e = 0; e < NE; e++) begin : g_ov
    assign ov[e] = v_q[e] && vpn_q[e][26:18] == fill_vpn[26:18] &&
                   (lvl_q[e] == 2'd2 || fill_lvl == 2'd2 || vpn_q[e][17:9] == fill_vpn[17:9]) &&
                   (lvl_q[e] != 2'd0 || fill_lvl != 2'd0 || vpn_q[e][8:0] == fill_vpn[8:0]);
  end
  logic [EW-1:0] fv;
  always_comb begin
    fv = rr_q;
    for (int e = NE - 1; e >= 0; e--) if (!v_q[e] || ov[e]) fv = EW'(e);
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      v_q  <= '0;
      rr_q <= '0;
    end else if (fill) begin
      v_q        <= (v_q & ~ov) | (NE'(1) << fv);
      rr_q       <= (int'(rr_q) == NE - 1) ? '0 : rr_q + 1'b1;
    end
  end
  always_ff @(posedge clk) begin
    if (fill) begin
      vpn_q[fv] <= fill_vpn;
      lvl_q[fv] <= fill_lvl;
      pte_q[fv] <= fill_pte;
    end
  end
endmodule
