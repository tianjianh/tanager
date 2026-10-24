// Fully associative Sv39 TLB (docs/spec/core-mmu.md): NE entries; 4 KiB, 2 MiB and 1 GiB pages.
// NR combinational lookups; the PPN comes back with the superpage bits taken from the VA. No
// ASID tags: every satp change and SFENCE.VMA flushes the TLB (as Spike), so every entry belongs
// to the current address space.
// A fill first invalidates every entry whose page overlaps the new one (either may be the
// larger), so a lookup matches at most one entry; then it takes an invalid entry, else a
// round-robin victim. After spike S4's tg_dtlb.
// Per thread (M7's step 4, docs/spec/threading.md): every entry carries its thread (t_q, set at the fill from
// fill_tid); a lookup matches only its thread's entries (lk_tid), a fill's overlap check takes only its thread's, and a
// flush clears only the flushed thread's entries (flush_tid), a fill of the other thread in that cycle staying. With one
// thread every entry is its, so this is the TLB before M7. The valid bits and levels are flip-flops; the
// leaf and its level are in LUTRAM, read at the OR-encoded match (one match at most). Without a
// match the leaf is undefined: users gate it with `hit`.
// The match, by CAM:
//   CAM = 0: each entry's VPN in flip-flops, compared at every lookup and for the overlap check.
//   CAM = 1: a CAM in LUTRAM (FPGA-friendly T5, docs/perf/fpga_friendly.md; after the spikes
//     track's tg_cam_lut). It wins on LUTs only with several compares per entry: the DTLB (two
//     lookups and the overlap check) takes it (-366 LUTs, -819 flip-flops at st), the ITLB (one
//     lookup) does not (-6 LUTs for +160 LUTRAM) and keeps flip-flops.
//     The VPN is cut into six slices, each 9-bit level into 5 + 4 bits. Slice table s holds, at
//     each slice value, one bit per entry: set when the entry's VPN has that value there. A
//     lookup reads every table at its VPN's slices, and entry e matches when its valid bit and
//     its tables' bits agree, a level's slices not counting above the entry's page size (lvl_q).
//     A fill takes three cycles in the tables, and behaves as a one-cycle fill: in the fill cycle
//     the maintenance read port reads the tables at the new VPN for the overlap check, and the
//     valid bits, the level and the leaf change at once; the next two cycles clear the victim's
//     bits at its old VPN (from a key store, which takes the new VPN with the set) and set them
//     at the new one, each a read-modify-write through the maintenance port. Meanwhile the entry
//     is left out of the table match and a comparator on the new VPN stands in for it. Fills come
//     at least six cycles apart (one walk at a time, asserted). After reset a sweep zeroes the
//     tables (32 cycles); every entry is invalid until filled, and the key store needs no reset
//     (clearing a never-filled entry's bits is a no-op).
//   EARLY ports (CAM = 1): the lookup's VPN and thread come a cycle ahead (vpn_e, lk_tid_e; vpn and
//     lk_tid are the same a cycle later), so the tables are read and matched a cycle ahead, masked by
//     the valid bits and the thread's entries as they will be at the edge (a flush, a fill's overlap),
//     with a fill's entry (T_CLEAR then) taken by the fill's VPN compared a cycle ahead too, encoded,
//     and the match, its index and the hit registered. The lookup's answer is the same; the leaf's
//     read address and the hit start at flip-flops (timing: DR-145; spikes §8.18's m2_foh_q and LSU
//     state families, which ran from the lookup's thread through the encode into the leaf LUTRAM).
module tg_tlb
  import tg_pkg::*, tg_core_pkg::*;
#(
  parameter int NE  = 16,
  parameter int NR  = 1,
  parameter bit CAM = 1'b0,
  parameter logic [NR-1:0] EARLY = '0,      // lookups whose VPN comes a cycle ahead (CAM only)
  localparam int EW = idx_w(NE)
) (
  input  logic                clk,
  input  logic                rst,
  input  logic [NR-1:0][26:0] vpn,          // VA[38:12]
  input  logic [NR-1:0][26:0] vpn_e,        // an EARLY port's VPN a cycle ahead
  input  tid_t [NR-1:0]       lk_tid,       // each lookup's thread (with vpn)
  input  tid_t [NR-1:0]       lk_tid_e,     // an EARLY port's thread a cycle ahead (with vpn_e)
  output logic [NR-1:0]       hit,
  output tlb_pte_t [NR-1:0]   pte,
  input  logic                fill,
  input  logic [26:0]         fill_vpn,
  input  logic [1:0]          fill_lvl,     // 0: 4 KiB, 1: 2 MiB, 2: 1 GiB
  input  tlb_pte_t            fill_pte,
  input  tid_t                fill_tid,
  input  logic                flush,
  input  tid_t                flush_tid
);
  localparam int NT = NUM_THREADS;
  logic [NE-1:0]         v_q;
  tid_t [NE-1:0]         t_q;               // each entry's thread
  logic [NE-1:0][1:0]    lvl_q;
  logic [EW-1:0]         rr_q;
  logic [EW-1:0]         fv;
  logic [NR-1:0][NE-1:0] m;                 // each lookup's matching entries
  logic [NR-1:0][EW-1:0] mi;                // ... their index (OR-encoded: one match at most)
  logic [NR-1:0]         mh;                // ... and whether there is one
  function automatic logic [EW-1:0] enc(input logic [NE-1:0] x);
    enc = '0;
    for (int e = 0; e < NE; e++) if (x[e]) enc |= EW'(e);
  endfunction
  // The entries of thread t (every entry without SMT); the tids without SMT are thread 0, whatever their bits hold
  function automatic logic [NE-1:0] tm(input tid_t t);
    for (int e = 0; e < NE; e++) tm[e] = (NT == 1) || t_q[e] == t;
  endfunction
  tid_t [NR-1:0] lt, lte;
  tid_t          ft, xt;
  always_comb for (int r = 0; r < NR; r++) lt[r]  = (NT > 1) ? lk_tid[r] : tid_t'(0);
  always_comb for (int r = 0; r < NR; r++) lte[r] = (NT > 1) ? lk_tid_e[r] : tid_t'(0);
  assign ft = (NT > 1) ? fill_tid : tid_t'(0);
  assign xt = (NT > 1) ? flush_tid : tid_t'(0);
  logic [NE-1:0] vflush;                    // the entries a flush clears: its thread's
  logic          fill_ok;                   // a fill not of the thread being flushed
  assign vflush  = flush ? tm(xt) : '0;
  assign fill_ok = fill && !(flush && ft == xt);
  logic [NE-1:0]         ov;                // entries of the fill's thread its page overlaps
`ifndef SYNTHESIS
  logic                  rs_tq;             // the TLB has been reset: the checks wait for it
  initial rs_tq = 1'b0;
  always @(posedge clk) if (rst) rs_tq <= 1'b1;
`endif
  logic                  unused_vpn_e;      // read by EARLY ports only
  assign unused_vpn_e = ^{vpn_e, lte};

  // a VPN in the page of (k, l)
  function automatic logic vmatch(input logic [26:0] a, input logic [26:0] k, input logic [1:0] l);
    return a[26:18] == k[26:18] && (l == 2'd2 || a[17:9] == k[17:9]) &&
           (l != 2'd0 || a[8:0] == k[8:0]);
  endfunction

  if (CAM) begin : g_cam
    // Slices: s0 VPN[4:0], s1 [8:5] (level 0), s2 [13:9], s3 [17:14] (level 1), s4 [22:18],
    // s5 [26:23] (level 2)
    localparam int NS = 6;
    localparam int SLO [NS] = '{0, 5, 9, 14, 18, 23};
    localparam int SWD [NS] = '{5, 4, 5, 4, 5, 4};

    // ---- Table maintenance: reset sweep, then idle / clear / set ----
    typedef enum logic [1:0] { T_SWEEP, T_IDLE, T_CLEAR, T_SET } tstate_e;
    tstate_e       ts_q;
    logic [4:0]    sw_q;                    // sweep address
    logic [EW-1:0] uf_q;                    // the entry being written in the tables
    logic [26:0]   uk_q;                    // its new VPN
    logic [1:0]    ul_q;                    // its level
    logic          upd;                     // the tables do not hold uf_q's VPN yet
    assign upd = ts_q == T_CLEAR || ts_q == T_SET;

    // Key store: each entry's VPN as the tables hold it, read for the clear
    logic [0:0][EW-1:0] ks_ra;
    logic [0:0][26:0]   ks_rd;
    assign ks_ra[0] = uf_q;
    tg_ram_lut #(.DEPTH(NE), .WIDTH(27), .NR(1)) u_keys (
      .clk, .we(ts_q == T_SET), .waddr(uf_q), .wdata(uk_q), .raddr(ks_ra), .rdata(ks_rd));

    // ---- Slice tables: read ports 0..NR-1 for the lookups, NR for maintenance ----
    logic [NS-1:0][NR-1:0][NE-1:0] w;       // each lookup's word in each table
    logic [NS-1:0][NE-1:0]         wm;      // the maintenance port's word
    logic [NE-1:0]                 ubit;
    always_comb begin
      ubit = '0;
      ubit[uf_q] = 1'b1;
    end
    for (genvar s = 0; s < NS; s++) begin : g_tab
      localparam int LO = SLO[s];
      localparam int SW = SWD[s];
      logic [NR:0][SW-1:0]   ra;
      logic [NR:0][NE-1:0]   rd;
      logic [SW-1:0]         ma;            // maintenance address
      for (genvar r = 0; r < NR; r++) begin : g_ra
        assign ra[r] = EARLY[r] ? vpn_e[r][LO +: SW] : vpn[r][LO +: SW];
        assign w[s][r] = rd[r];
      end
      always_comb begin
        unique case (ts_q)
          T_SWEEP: ma = sw_q[SW-1:0];
          T_CLEAR: ma = ks_rd[0][LO +: SW];
          T_SET:   ma = uk_q[LO +: SW];
          default: ma = fill_vpn[LO +: SW];  // the fill cycle's overlap check
        endcase
      end
      assign ra[NR] = ma;
      assign wm[s]  = rd[NR];
      logic          twe;
      logic [NE-1:0] twd;
      assign twe = ts_q != T_IDLE;
      assign twd = (ts_q == T_SET)   ? (rd[NR] | ubit) :
                   (ts_q == T_CLEAR) ? (rd[NR] & ~ubit) : '0;
      tg_ram_lut #(.DEPTH(1 << SW), .WIDTH(NE), .NR(NR + 1)) u_tab (
        .clk, .we(twe), .waddr(ma), .wdata(twd), .raddr(ra), .rdata(rd));
    end

    // Entry e of the tables matches a set of words: its level's slices, and those below while
    // its page is smaller
    function automatic logic [NE-1:0] tmatch(input logic [NS-1:0][NE-1:0] x,
                                             input logic [NE-1:0][1:0] l, input logic [1:0] fl);
      for (int e = 0; e < NE; e++)
        tmatch[e] = x[4][e] && x[5][e] && (l[e] == 2'd2 || fl == 2'd2 || (x[2][e] && x[3][e])) &&
                    (l[e] != 2'd0 || fl != 2'd0 || (x[0][e] && x[1][e]));
    endfunction

    // The valid bits at the next edge, less a filled entry: an EARLY port masks its match a cycle
    // ahead with them, and takes the filled entry from the fill's own compare
    logic [NE-1:0] kvn;
    assign kvn = fill_ok ? (v_q & ~vflush & ~ov & ~(NE'(1) << fv)) : (v_q & ~vflush);
    if (EARLY == '0) begin : g_nokv
      logic unused_kv;                       // no EARLY port: synthesis drops it
      assign unused_kv = ^kvn;
    end
    for (genvar r = 0; r < NR; r++) begin : g_m
      logic [26:0]   lv;                     // the VPN the tables are read at
      logic [NE-1:0] mt;                     // their match
      assign lv = EARLY[r] ? vpn_e[r] : vpn[r];
      always_comb begin
        logic [NS-1:0][NE-1:0] x;
        for (int s = 0; s < NS; s++) x[s] = w[s][r];
        mt = v_q & tmatch(x, lvl_q, 2'd0);          // (the thread's mask: in the lookup's cycle, below)
        if (upd) begin                       // the entry being written: its new VPN, compared
          mt[uf_q] = v_q[uf_q] && vmatch(lv, uk_q, ul_q);
        end
      end
      if (EARLY[r]) begin : g_early
        // The match a cycle ahead, masked as the lookup's cycle will hold it (kvn; the thread's entries by
        // lk_tid_e), and a fill's entry at that edge by the fill's compare (the filled entry, uf_q then, matches;
        // then no other entry of the thread does): registered with its index and hit
        logic [NE-1:0] mk_q;
        logic [EW-1:0] mi_q;
        logic          fqc_q;
        always_ff @(posedge clk) begin
          logic [NE-1:0] mkn;
          logic          fqcn;
          mkn   = mt & kvn & tm(lte[r]);
          fqcn  = fill_ok && vmatch(vpn_e[r], fill_vpn, fill_lvl) && ft == lte[r];
          mk_q  <= rst ? '0 : mkn;
          fqc_q <= !rst && fqcn;
          mi_q  <= enc(mkn) | (fqcn ? fv : '0);
        end
        always_comb begin
          m[r] = mk_q;
          if (fqc_q) m[r][uf_q] = 1'b1;
        end
        assign mi[r] = mi_q;
        assign mh[r] = |mk_q || fqc_q;
      end else begin : g_now
        logic [NE-1:0] mn;
        assign mn    = mt & tm(lt[r]);
        assign m[r]  = mn;
        assign mi[r] = enc(mn);
        assign mh[r] = |mn;
      end
    end
    assign ov = v_q & tm(ft) & tmatch(wm, lvl_q, fill_lvl);

    always_ff @(posedge clk) begin
      if (rst) begin
        ts_q <= T_SWEEP;
        sw_q <= '0;
      end else begin
        unique case (ts_q)
          T_SWEEP: begin
            sw_q <= sw_q + 1'b1;
            if (sw_q == 5'd31) ts_q <= T_IDLE;
          end
          T_IDLE:  if (fill_ok) ts_q <= T_CLEAR;
          T_CLEAR: ts_q <= T_SET;
          default: ts_q <= T_IDLE;
        endcase
      end
      if (ts_q == T_IDLE && fill_ok) begin
        uf_q <= fv;
        uk_q <= fill_vpn;
        ul_q <= fill_lvl;
      end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (!rst) assert (!fill || ts_q == T_IDLE) else $error("tg_tlb: a fill while the tables are busy");
    end
    // Every lookup matches what the flip-flop form would (each entry's VPN kept here)
    logic [NE-1:0][26:0] vs_q;
    logic                rs_q;      // the TLB has been reset: the check waits for it
    initial rs_q = 1'b0;
    always @(posedge clk) begin
      if (rst) rs_q <= 1'b1;
      if (fill_ok) vs_q[fv] <= fill_vpn;
      if (rs_q && !rst && ts_q != T_SWEEP)
        for (int r = 0; r < NR; r++)
          for (int e = 0; e < NE; e++)
            assert (m[r][e] == (v_q[e] && tm(lt[r])[e] && vmatch(vpn[r], vs_q[e], lvl_q[e])))
              else $error("tg_tlb: lookup %0d's match of entry %0d differs from the entry's VPN", r, e);
    end
`endif
  end else begin : g_ff
    logic [NE-1:0][26:0] vpn_q;
    for (genvar r = 0; r < NR; r++) begin : g_m
      for (genvar e = 0; e < NE; e++) begin : g_e
        assign m[r][e] = v_q[e] && ((NT == 1) || t_q[e] == lt[r]) && vmatch(vpn[r], vpn_q[e], lvl_q[e]);
      end
      assign mi[r] = enc(m[r]);
      assign mh[r] = |m[r];
    end
    for (genvar e = 0; e < NE; e++) begin : g_ov
      assign ov[e] = v_q[e] && ((NT == 1) || t_q[e] == ft) && vpn_q[e][26:18] == fill_vpn[26:18] &&
                     (lvl_q[e] == 2'd2 || fill_lvl == 2'd2 || vpn_q[e][17:9] == fill_vpn[17:9]) &&
                     (lvl_q[e] != 2'd0 || fill_lvl != 2'd0 || vpn_q[e][8:0] == fill_vpn[8:0]);
    end
    always_ff @(posedge clk) begin
      if (fill_ok) vpn_q[fv] <= fill_vpn;
    end
  end

  localparam int DW = 2 + $bits(tlb_pte_t);
  logic [NR-1:0][EW-1:0] ra;
  logic [NR-1:0][DW-1:0] rd;
  tg_ram_lut #(.DEPTH(NE), .WIDTH(DW), .NR(NR)) u_leaf (
    .clk, .we(fill_ok), .waddr(fv), .wdata({fill_lvl, fill_pte}), .raddr(ra), .rdata(rd));

  for (genvar r = 0; r < NR; r++) begin : g_rd
    assign ra[r] = mi[r];
    always_comb begin
      logic [1:0] l;
      {l, pte[r]} = rd[r];
      if (l != 2'd0) pte[r].ppn[8:0]  = vpn[r][8:0];
      if (l == 2'd2) pte[r].ppn[17:9] = vpn[r][17:9];
    end
    assign hit[r] = mh[r];
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (rs_tq && !rst) begin
        assert ($onehot0(m[r])) else $error("tg_tlb: more than one entry matches a lookup");
        assert (mi[r] == enc(m[r]) && mh[r] == |m[r]) else $error("tg_tlb: lookup %0d's index or hit differs from its match", r);
      end
    end
`endif
  end

  // Fill: entries overlapping the new page go; the new one takes an invalid entry or the victim
  always_comb begin
    fv = rr_q;
    for (int e = NE - 1; e >= 0; e--) if (!v_q[e] || ov[e]) fv = EW'(e);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      v_q  <= '0;
      rr_q <= '0;
    end else begin
      if (flush) rr_q <= '0;
      if (fill_ok) begin
        v_q  <= (v_q & ~vflush & ~ov) | (NE'(1) << fv);
        if (!flush) rr_q <= (int'(rr_q) == NE - 1) ? '0 : rr_q + 1'b1;
      end else begin
        v_q  <= v_q & ~vflush;
      end
    end
  end
  // A fill the flush drops writes nothing: its victim may be the other thread's entry, which the flush keeps
  always_ff @(posedge clk) begin
    if (fill_ok) begin
      lvl_q[fv] <= fill_lvl;
      t_q[fv]   <= ft;
    end
  end
endmodule
