// Content-addressable memory in LUTRAM (docs/perf/fpga_friendly.md T5), for lookups that are
// rarely written: TLBs filled by a walker, PMA tables.
//
// The key is split into NS = ceil(KEYW / SLICE) slices. Slice table s is a 2^SLICE-deep
// LUTRAM whose word at address v holds one bit per entry: set when that entry's key has
// value v in slice s. A lookup reads every table at its key's slices and ANDs the words with
// the valid bits, so it costs a few LUTRAM reads and an AND per entry instead of ENTRIES
// comparators of KEYW bits; the cost is in the writes.
//
// Lookup: combinational; lk_match is one bit per valid entry whose key equals lk_key,
//   lk_hit their OR and lk_idx their index (the OR of the indices if several match).
//   lk_valid is low in a cycle where the tables cannot serve a lookup: during the reset
//   sweep, and when the update cycles use the lookup port (below).
// Write: wr_valid && wr_ready stores wr_key in entry wr_idx in three cycles:
//   cycle 1 (accept): the entry's old key is read from the key store and the entry stops
//            matching (its valid bit clears at the end of the cycle);
//   cycle 2: each table clears the entry's bit at the old key's slice;
//   cycle 3: each table sets the entry's bit at the new key's slice and the key store takes
//            the new key; the entry is valid, and matches wr_key, from the next cycle.
//   wr_ready is low in cycles 2 and 3.
// Invalidate: inv clears entry inv_idx's valid bit, flush clears all of them, next cycle;
//   neither touches the tables, so both are single-cycle. A write's final cycle wins over an
//   invalidate or flush of the same entry in that cycle.
// Reset: rst starts a sweep (SWEEP cycles, below) after which no entry has a bit set in any
//   table, whatever a reset interrupted; ready is low and no writes are accepted until then.
//
// PRIM "m16": each table is a tg_ram_lut of 32 (SLICE 5) or 64 (SLICE 6) words of ENTRIES
//   bits, in RAM32M16s (14 entries per primitive per read port) or RAM64M8s (7). A table
//   write changes one entry's bit by read-modify-write: one LUT per two bits of data path.
//   RMW_PORT = 1 gives each table a second read port for that, so lookups continue through
//   writes (the tables cost twice the LUTRAM); with 0, cycles 2 and 3 use the lookup port.
//   The reset sweep zeroes every word: 2^SLICE cycles.
// PRIM "sw": each table is ceil(ENTRIES / 8) RAM64X8SWs (64 x 8, single port, one-bit
//   write), so a table write sets or clears the entry's own bit with no read-modify-write
//   and no data-path logic. SLICE is 6. The port is shared, so cycles 2 and 3 use the lookup
//   port. The reset sweep clears each entry at the key the key store holds: ENTRIES cycles
//   (the key store is written only when the tables are, so it always names the bits to clear).
// The key store (ENTRIES x KEYW, one read port) holds each entry's key for the clear.
(* keep_hierarchy = "yes" *)  // keeps the instance and its ports for the primitive check
module tg_cam_lut #(
  parameter int    ENTRIES  = 32,
  parameter int    KEYW     = 32,
  parameter string PRIM     = "m16",   // "m16" or "sw"
  parameter int    SLICE    = (PRIM == "sw") ? 6 : 5,
  parameter bit    RMW_PORT = 1'b1,    // "m16" only
  localparam int   IW       = (ENTRIES > 1) ? $clog2(ENTRIES) : 1
) (
  input  logic               clk,
  input  logic               rst,
  output logic               ready,
  input  logic [KEYW-1:0]    lk_key,
  output logic [ENTRIES-1:0] lk_match,
  output logic               lk_hit,
  output logic [IW-1:0]      lk_idx,
  output logic               lk_valid,
  input  logic               wr_valid,
  output logic               wr_ready,
  input  logic [IW-1:0]      wr_idx,
  input  logic [KEYW-1:0]    wr_key,
  input  logic               inv,
  input  logic [IW-1:0]      inv_idx,
  input  logic               flush
);
  localparam bit SW    = PRIM == "sw";
  localparam int NS    = (KEYW + SLICE - 1) / SLICE;
  localparam int TD    = 1 << SLICE;              // table depth
  localparam int KPAD  = NS * SLICE;
  localparam int NRT   = (!SW && RMW_PORT) ? 2 : 1;   // read ports per "m16" table
  localparam int SWEEP = SW ? ENTRIES : TD;       // reset sweep cycles
  localparam int CW    = (SLICE > IW) ? SLICE : IW;

  if (ENTRIES < 2 || KEYW < 1) begin : g_bad_params
    $error("tg_cam_lut: needs ENTRIES >= 2 and KEYW >= 1");
  end
  if (PRIM != "m16" && PRIM != "sw") begin : g_bad_prim
    $error("tg_cam_lut: PRIM must be \"m16\" or \"sw\"");
  end
  if ((SW && SLICE != 6) || (!SW && SLICE != 5 && SLICE != 6)) begin : g_bad_slice
    $error("tg_cam_lut: SLICE must be 6 for \"sw\" and 5 or 6 for \"m16\"");
  end

  // ---- control ---------------------------------------------------------------------------
  typedef enum logic [1:0] {S_SWEEP, S_IDLE, S_CLEAR, S_SET} st_e;
  st_e st_q;
  logic [CW-1:0]      cnt_q;                       // sweep step
  logic [IW-1:0]      idx_q;
  logic [KPAD-1:0]    key_q, old_q;                // new and old key, padded to NS slices
  logic [ENTRIES-1:0] valid_q;

  wire accept = wr_valid && wr_ready;
  wire sweep  = st_q == S_SWEEP;
  wire upd    = (st_q == S_CLEAR) || (st_q == S_SET);
  wire set    = st_q == S_SET;
  assign ready    = !sweep;
  assign wr_ready = st_q == S_IDLE && !rst;
  assign lk_valid = ready && ((!SW && RMW_PORT) || !upd);

  logic [KEYW-1:0] ks_key;                         // key store read: wr_idx, or the sweep's entry
  always_ff @(posedge clk) begin
    if (rst) begin
      st_q  <= S_SWEEP;
      cnt_q <= '0;
    end else begin
      case (st_q)
        S_SWEEP: begin
          cnt_q <= cnt_q + 1'b1;
          if (cnt_q == CW'(SWEEP - 1)) st_q <= S_IDLE;
        end
        S_IDLE:  if (accept) st_q <= S_CLEAR;
        S_CLEAR: st_q <= S_SET;
        default: st_q <= S_IDLE;                   // S_SET
      endcase
    end
    if (accept) begin
      idx_q <= wr_idx;
      key_q <= KPAD'(wr_key);
      old_q <= KPAD'(ks_key);
    end
  end

  logic [ENTRIES-1:0] inv_mask;
  always_comb begin
    inv_mask = '0;
    if (flush) inv_mask = '1;
    else if (inv) inv_mask[inv_idx] = 1'b1;
    if (accept) inv_mask[wr_idx] = 1'b1;           // the entry stops matching at once
  end
  always_ff @(posedge clk) begin
    if (rst) valid_q <= '0;
    else begin
      valid_q <= valid_q & ~inv_mask;
      if (set) valid_q[idx_q] <= 1'b1;
    end
  end

  // ---- key store: written with the tables, so it names the bits an entry has set ----------
  logic [0:0][IW-1:0]   ks_ra;
  logic [0:0][KEYW-1:0] ks_rd;
  if (SW) begin : g_ks_sweep
    assign ks_ra[0] = sweep ? IW'(cnt_q) : wr_idx;
  end else begin : g_ks_idx
    assign ks_ra[0] = wr_idx;
  end
  assign ks_key = ks_rd[0];
  tg_ram_lut #(.DEPTH(ENTRIES), .WIDTH(KEYW), .NR(1)) u_keys (
    .clk, .we(set), .waddr(idx_q), .wdata(key_q[KEYW-1:0]), .raddr(ks_ra), .rdata(ks_rd));

  // ---- slice tables -----------------------------------------------------------------------
  logic [KPAD-1:0]            lk_pad;
  logic [NS-1:0][ENTRIES-1:0] word;                // each table's word at lk_key's slice
  assign lk_pad = KPAD'(lk_key);

  if (SW) begin : g_sw
    // One-bit writes: entry (sweep ? cnt : idx) gets set (1 in cycle 3, else 0).
    logic [KPAD-1:0] sw_pad;                       // the swept entry's key
    logic [IW-1:0]   wbit;
    logic            twe;
    assign sw_pad = KPAD'(ks_key);
    assign wbit   = sweep ? IW'(cnt_q) : idx_q;
    assign twe    = upd || sweep;
    for (genvar s = 0; s < NS; s++) begin : g_tab
      logic [5:0] a;
      always_comb begin
        if (sweep)                a = sw_pad[s*6 +: 6];
        else if (st_q == S_CLEAR) a = old_q[s*6 +: 6];
        else if (set)             a = key_q[s*6 +: 6];
        else                      a = lk_pad[s*6 +: 6];
      end
`ifdef SYNTHESIS
  `define TG_CAM_SW_PRIMS
`elsif TG_SIM_PRIMS
  `define TG_CAM_SW_PRIMS
`endif
`ifdef TG_CAM_SW_PRIMS
  `undef TG_CAM_SW_PRIMS
      localparam int NP = (ENTRIES + 7) / 8;       // RAM64X8SWs per table
      logic [NP*8-1:0] o;
      for (genvar p = 0; p < NP; p++) begin : g_prim
        logic pwe;
        if (NP > 1) begin : g_sel
          assign pwe = twe && (32'(wbit) >> 3) == p;
        end else begin : g_one
          assign pwe = twe;
        end
        RAM64X8SW #(
          .INIT_A(64'h0), .INIT_B(64'h0), .INIT_C(64'h0), .INIT_D(64'h0),
          .INIT_E(64'h0), .INIT_F(64'h0), .INIT_G(64'h0), .INIT_H(64'h0)
        ) u_ram (
          .O(o[p*8 +: 8]), .A(a), .D(set), .WCLK(clk), .WE(pwe), .WSEL(3'(wbit)));
      end
      assign word[s] = o[ENTRIES-1:0];
      if (NP * 8 > ENTRIES) begin : g_spare
        /* verilator lint_off UNUSEDSIGNAL */  // the last primitive's spare bits
        logic [NP*8-ENTRIES-1:0] spare;
        assign spare = o[NP*8-1:ENTRIES];
        /* verilator lint_on UNUSEDSIGNAL */
      end
`else
      // Behavioural model (simulation): bit writes into 64 words of ENTRIES bits.
      logic [ENTRIES-1:0] mem [64];
      always_ff @(posedge clk) begin
        if (twe) mem[a][wbit] <= set;
      end
      assign word[s] = mem[a];
`endif
    end
  end else begin : g_m16
    logic [ENTRIES-1:0] mask;                      // the entries whose bit a table write sets
    always_comb begin                              // or clears: the one being updated, or all
      mask = '0;                                   // of them in the reset sweep (a clear)
      mask[idx_q] = 1'b1;
      if (sweep) mask = '1;
    end
    for (genvar s = 0; s < NS; s++) begin : g_tab
      logic [SLICE-1:0]             ua;            // update address
      logic [NRT-1:0][SLICE-1:0]    ra;
      logic [NRT-1:0][ENTRIES-1:0]  rd;
      logic [ENTRIES-1:0]           wd, cur;
      logic [SLICE-1:0]             wa;
      assign ua = (st_q == S_CLEAR) ? old_q[s*SLICE +: SLICE] : key_q[s*SLICE +: SLICE];
      if (RMW_PORT) begin : g_rmw
        assign ra[0] = lk_pad[s*SLICE +: SLICE];
        assign ra[1] = ua;
        assign cur   = rd[1];
      end else begin : g_shared
        assign ra[0] = upd ? ua : lk_pad[s*SLICE +: SLICE];
        assign cur   = rd[0];
      end
      assign word[s] = rd[0];
      assign wa = sweep ? SLICE'(cnt_q) : ua;
      // three inputs per bit (the current bit, its mask bit, set), so two bits share a LUT6_2
      assign wd = set ? (cur | mask) : (cur & ~mask);
      tg_ram_lut #(.DEPTH(TD), .WIDTH(ENTRIES), .NR(NRT)) u_tab (
        .clk, .we(upd || sweep), .waddr(wa), .wdata(wd), .raddr(ra), .rdata(rd));
    end
  end

  // ---- match ------------------------------------------------------------------------------
  always_comb begin
    lk_match = valid_q;
    for (int s = 0; s < NS; s++) lk_match &= word[s];
    lk_hit = |lk_match;
    lk_idx = '0;
    for (int e = 0; e < ENTRIES; e++) begin
      if (lk_match[e]) lk_idx |= IW'(e);
    end
  end
endmodule
