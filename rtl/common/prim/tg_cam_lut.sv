// Content-addressable memory in LUTRAM (docs/perf/fpga_friendly.md T5), for lookups that are
// rarely written: TLBs filled by a walker, PMP and PMA tables.
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
//   sweep, and, with RMW_PORT = 0, during a write's two update cycles.
// Write: wr_valid && wr_ready stores wr_key in entry wr_idx in three cycles:
//   cycle 1 (accept): the entry's old key is read from the key store and the entry stops
//            matching (its valid bit clears at the end of the cycle);
//   cycle 2: each table clears the entry's bit at the old key's slice (read-modify-write);
//   cycle 3: each table sets the entry's bit at the new key's slice; the entry is valid,
//            and matches wr_key, from the next cycle. wr_ready is low in cycles 2 and 3.
// Invalidate: inv clears entry inv_idx's valid bit, flush clears all of them, next cycle;
//   neither touches the tables, so both are single-cycle. A write's final cycle wins over an
//   invalidate or flush of the same entry in that cycle.
// Reset: rst starts a sweep of 2^SLICE cycles that zeroes every table (ready is low until it
//   ends; no writes are accepted). After that, an entry never written has no bits set.
//
// SLICE 5 maps each table to RAM32M16s (2 bits per LUT per read port: 14 entries per
// primitive and read port), SLICE 6 to RAM64M8s (7 entries); 5 is the cheaper of the two.
// RMW_PORT = 1 gives each table a second read port for the read-modify-write, so lookups
// continue through writes (the table costs about twice as much); with 0, the update cycles
// borrow the lookup port.
// The key store (ENTRIES x KEYW, one read port) holds each entry's key for the clear.
module tg_cam_lut #(
  parameter int ENTRIES  = 32,
  parameter int KEYW     = 32,
  parameter int SLICE    = 5,
  parameter bit RMW_PORT = 1'b1,
  localparam int IW      = (ENTRIES > 1) ? $clog2(ENTRIES) : 1
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
  localparam int NS    = (KEYW + SLICE - 1) / SLICE;
  localparam int TD    = 1 << SLICE;              // table depth
  localparam int KPAD  = NS * SLICE;
  localparam int NRT   = RMW_PORT ? 2 : 1;        // read ports per table

  if (ENTRIES < 2 || KEYW < 1 || (SLICE != 5 && SLICE != 6)) begin : g_bad_params
    $error("tg_cam_lut: needs ENTRIES >= 2, KEYW >= 1 and SLICE 5 or 6");
  end

  // ---- control ---------------------------------------------------------------------------
  typedef enum logic [1:0] {S_SWEEP, S_IDLE, S_CLEAR, S_SET} st_e;
  st_e st_q;
  logic [SLICE-1:0]   cnt_q;                       // sweep address
  logic [IW-1:0]      idx_q;
  logic [KPAD-1:0]    key_q, old_q;                // new and old key, padded to NS slices
  logic [ENTRIES-1:0] valid_q;

  wire accept = wr_valid && wr_ready;
  assign ready    = st_q != S_SWEEP;
  assign wr_ready = st_q == S_IDLE && !rst;

  logic [KEYW-1:0] old_key;                        // key store read at wr_idx
  always_ff @(posedge clk) begin
    if (rst) begin
      st_q  <= S_SWEEP;
      cnt_q <= '0;
    end else begin
      case (st_q)
        S_SWEEP: begin
          cnt_q <= cnt_q + 1'b1;
          if (cnt_q == SLICE'(TD - 1)) st_q <= S_IDLE;
        end
        S_IDLE:  if (accept) st_q <= S_CLEAR;
        S_CLEAR: st_q <= S_SET;
        default: st_q <= S_IDLE;                   // S_SET
      endcase
    end
    if (accept) begin
      idx_q <= wr_idx;
      key_q <= KPAD'(wr_key);
      old_q <= KPAD'(old_key);
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
      if (st_q == S_SET) valid_q[idx_q] <= 1'b1;
    end
  end

  // ---- key store --------------------------------------------------------------------------
  logic [0:0][IW-1:0]   ks_ra;
  logic [0:0][KEYW-1:0] ks_rd;
  assign ks_ra[0] = wr_idx;
  assign old_key  = ks_rd[0];
  tg_ram_lut #(.DEPTH(ENTRIES), .WIDTH(KEYW), .NR(1)) u_keys (
    .clk, .we(accept), .waddr(wr_idx), .wdata(wr_key), .raddr(ks_ra), .rdata(ks_rd));

  // ---- slice tables -----------------------------------------------------------------------
  logic [KPAD-1:0]    lk_pad;
  logic [ENTRIES-1:0] onehot;                      // the entry being updated
  assign lk_pad = KPAD'(lk_key);
  always_comb begin
    onehot = '0;
    onehot[idx_q] = 1'b1;
  end
  wire upd = (st_q == S_CLEAR) || (st_q == S_SET);

  logic [NS-1:0][ENTRIES-1:0] word;                // each table's word at lk_key's slice
  for (genvar s = 0; s < NS; s++) begin : g_tab
    logic [SLICE-1:0]             ua;              // update address
    logic [NRT-1:0][SLICE-1:0]    ra;
    logic [NRT-1:0][ENTRIES-1:0]  rd;
    logic [ENTRIES-1:0]           wd, cur;
    logic [SLICE-1:0]             wa;
    logic                         twe;
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
    assign twe = upd || st_q == S_SWEEP;
    assign wa  = (st_q == S_SWEEP) ? cnt_q : ua;
    always_comb begin
      if (st_q == S_SWEEP)      wd = '0;
      else if (st_q == S_SET)   wd = cur | onehot;
      else                      wd = cur & ~onehot;
    end
    tg_ram_lut #(.DEPTH(TD), .WIDTH(ENTRIES), .NR(NRT)) u_tab (
      .clk, .we(twe), .waddr(wa), .wdata(wd), .raddr(ra), .rdata(rd));
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
  assign lk_valid = ready && (RMW_PORT || !upd);
endmodule
