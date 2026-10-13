// Fully associative L1 TLB for Sv39 (plan §4.10): NE entries in flip-flops, 4 KiB, 2 MiB
// and 1 GiB pages, entries tagged {TID, ASID} (plan §6.2 rule 5), global pages match any
// ASID. Lookup is combinational (the load pipe registers it at the end of M1). Spike S4.
// Fill replaces the entry the caller names. Flush (SFENCE.VMA, per thread): all entries,
// or one ASID's non-global entries.
module tg_dtlb
  import tg_pkg::*;
#(
  parameter int NE     = DTLB_ENTRIES,
  localparam int PPN_W = PA_W - 12,
  localparam int EW    = idx_w(NE)
) (
  input  logic              clk,
  input  logic              rst,
  // Lookup
  input  tid_t              tid,
  input  logic [15:0]       asid,
  input  logic [38:12]      vpn,
  output logic              hit,
  output logic [PPN_W-1:0]  ppn,        // superpage bits already taken from the VA
  output logic [5:0]        perm,       // {d, a, u, x, w, r}
  // Fill
  input  logic              fill_valid,
  input  logic [EW-1:0]     fill_idx,
  input  tid_t              fill_tid,
  input  logic [15:0]       fill_asid,
  input  logic [38:12]      fill_vpn,
  input  logic [1:0]        fill_lvl,   // 0: 4 KiB, 1: 2 MiB, 2: 1 GiB
  input  logic              fill_g,
  input  logic [PPN_W-1:0]  fill_ppn,
  input  logic [5:0]        fill_perm,
  // Flush
  input  logic              flush_valid,
  input  tid_t              flush_tid,
  input  logic              flush_all,  // else: one ASID, global entries kept
  input  logic [15:0]       flush_asid
);
  typedef struct packed {
    tid_t             tid;
    logic [15:0]      asid;
    logic [38:12]     vpn;
    logic [1:0]       lvl;
    logic             g;
    logic [PPN_W-1:0] ppn;
    logic [5:0]       perm;
  } ent_t;

  logic [NE-1:0] valid_q;
  ent_t [NE-1:0] ent_q;

  logic [NE-1:0] match;
  for (genvar e = 0; e < NE; e++) begin : g_cmp
    assign match[e] = valid_q[e] && ent_q[e].tid == tid
                   && (ent_q[e].g || ent_q[e].asid == asid)
                   && ent_q[e].vpn[38:30] == vpn[38:30]
                   && (ent_q[e].lvl == 2'd2 || ent_q[e].vpn[29:21] == vpn[29:21])
                   && (ent_q[e].lvl != 2'd0 || ent_q[e].vpn[20:12] == vpn[20:12]);
  end

  // One-hot AND-OR of the matching entry; fills keep the entries distinct.
  logic [PPN_W-1:0] eppn;
  logic [1:0]       elvl;
  always_comb begin
    eppn = '0;
    elvl = '0;
    perm = '0;
    for (int e = 0; e < NE; e++) begin
      eppn |= {PPN_W{match[e]}} & ent_q[e].ppn;
      elvl |= {2{match[e]}} & ent_q[e].lvl;
      perm |= {6{match[e]}} & ent_q[e].perm;
    end
  end
  assign hit = |match;
  always_comb begin
    ppn = eppn;
    if (elvl != 2'd0) ppn[8:0]  = vpn[20:12];
    if (elvl == 2'd2) ppn[17:9] = vpn[29:21];
  end

  always_ff @(posedge clk) begin
    if (rst) valid_q <= '0;
    else begin
      for (int e = 0; e < NE; e++) begin
        if (flush_valid && ent_q[e].tid == flush_tid
            && (flush_all || (!ent_q[e].g && ent_q[e].asid == flush_asid)))
          valid_q[e] <= 1'b0;
      end
      if (fill_valid) valid_q[fill_idx] <= 1'b1;
    end
    if (fill_valid) begin
      ent_q[fill_idx] <= '{tid: fill_tid, asid: fill_asid, vpn: fill_vpn, lvl: fill_lvl,
                           g: fill_g, ppn: fill_ppn, perm: fill_perm};
    end
  end
endmodule
