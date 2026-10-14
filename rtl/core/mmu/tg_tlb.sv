// Fully associative Sv39 TLB (docs/spec/core-mmu.md): NE entries in flip-flops; 4 KiB, 2 MiB and
// 1 GiB pages; tagged with the ASID (global entries match any). NR combinational lookups: the
// first matching entry wins, and the PPN comes back with the superpage bits taken from the VA.
// A fill replaces an entry that already matches its VPN, else the first invalid entry, else a
// round-robin victim. Flush: every entry (SFENCE.VMA, satp writes). After spike S4's tg_dtlb.
module tg_tlb
  import tg_pkg::*, tg_core_pkg::*;
#(
  parameter int NE = 16,
  parameter int NR = 1,
  localparam int EW = idx_w(NE)
) (
  input  logic                clk,
  input  logic                rst,
  input  logic [15:0]         asid,
  input  logic [NR-1:0][26:0] vpn,          // VA[38:12]
  output logic [NR-1:0]       hit,
  output tlb_pte_t [NR-1:0]   pte,
  input  logic                fill,
  input  logic [26:0]         fill_vpn,
  input  logic [15:0]         fill_asid,
  input  logic [1:0]          fill_lvl,     // 0: 4 KiB, 1: 2 MiB, 2: 1 GiB
  input  tlb_pte_t            fill_pte,
  input  logic                flush
);
  logic [NE-1:0]       v_q;
  logic [NE-1:0][26:0] vpn_q;
  logic [NE-1:0][15:0] asid_q;
  logic [NE-1:0][1:0]  lvl_q;
  tlb_pte_t [NE-1:0]   pte_q;
  logic [EW-1:0]       rr_q;

  function automatic logic match(input logic v, input logic [26:0] ev, input logic [15:0] ea,
                                 input logic [1:0] el, input logic eg, input logic [26:0] q,
                                 input logic [15:0] qa);
    return v && (eg || ea == qa) && ev[26:18] == q[26:18] && (el == 2'd2 || ev[17:9] == q[17:9]) &&
           (el != 2'd0 || ev[8:0] == q[8:0]);
  endfunction

  for (genvar r = 0; r < NR; r++) begin : g_rd
    logic [NE-1:0] m;
    for (genvar e = 0; e < NE; e++) begin : g_m
      assign m[e] = match(v_q[e], vpn_q[e], asid_q[e], lvl_q[e], pte_q[e].g, vpn[r], asid);
    end
    always_comb begin
      pte[r] = '0;
      for (int e = NE - 1; e >= 0; e--) begin
        if (m[e]) begin
          pte[r] = pte_q[e];
          if (lvl_q[e] != 2'd0) pte[r].ppn[8:0]  = vpn[r][8:0];
          if (lvl_q[e] == 2'd2) pte[r].ppn[17:9] = vpn[r][17:9];
        end
      end
    end
    assign hit[r] = |m;
  end

  // Fill victim: an entry matching the fill, else the first invalid one, else round robin
  logic [NE-1:0] fm;
  for (genvar e = 0; e < NE; e++) begin : g_fm
    assign fm[e] = match(v_q[e], vpn_q[e], asid_q[e], lvl_q[e], pte_q[e].g, fill_vpn, fill_asid);
  end
  logic [EW-1:0] fv;
  always_comb begin
    fv = rr_q;
    for (int e = NE - 1; e >= 0; e--) if (!v_q[e]) fv = EW'(e);
    for (int e = NE - 1; e >= 0; e--) if (fm[e]) fv = EW'(e);
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      v_q  <= '0;
      rr_q <= '0;
    end else if (fill) begin
      v_q[fv]    <= 1'b1;
      vpn_q[fv]  <= fill_vpn;
      asid_q[fv] <= fill_asid;
      lvl_q[fv]  <= fill_lvl;
      pte_q[fv]  <= fill_pte;
      rr_q       <= (int'(rr_q) == NE - 1) ? '0 : rr_q + 1'b1;
    end
  end
endmodule
