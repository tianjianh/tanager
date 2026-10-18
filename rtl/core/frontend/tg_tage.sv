// TAGE-lite direction predictor (plan §4.2; M6; core-pipeline.md §3.2), read per fetch block.
//
// Tables, in block memory, read in F1 on the block address and the speculative history, the data
// in F2 (like the I$ data):
// - a base table: BI index bits (2K blocks), a 2-bit counter per halfword slot (taken: >= 2);
// - NT tagged tables of 2^LI entries, each entry two sub-entries {valid, slot, tag, ctr, u}: a
//   branch matches the sub-entry with its slot (its last parcel's, as the micro-BTB keys it) and
//   the table's tag for the block. ctr is 3 bits (taken: >= 4), u 2 bits.
// The provider for a slot is the longest-history table that matches; without one, the base.
// Index and tag: the block address folded with the history's first HL[t] bits (the newest
// first), as in the behavioural model the design was chosen on (reports/m6-tage-design.md).
//
// Training (commit, in order): a queue of requests, each with the indices and tags its block
// read at fetch (the FTQ keeps them) and the branch's slot, outcome and fetch-time direction. Port
// B of each memory reads the entries (T1) and writes them back updated (T2), one request every two
// cycles; a full queue drops a request. The update: the provider's counter moves toward the
// outcome; its useful bits move when its direction differed from the next match's (or the
// base's); without a provider the base counter moves. A wrong fetch-time direction allocates one
// sub-entry, invalid or not useful, in a longer table than the provider, else every candidate's
// useful bits age.
module tg_tage
  import tg_pkg::*;
#(
  parameter int NP = 8,               // slots per block
  parameter int CW = 2,               // training requests per cycle
  parameter int NT = 4,
  parameter int LI = 10,              // tagged tables' index bits
  parameter int TW = 9,               // tag bits
  parameter int BI = 11,              // base table's index bits
  parameter int HW = 64,              // history bits kept
  localparam int SW = idx_w(NP)
) (
  input  logic                 clk,
  input  logic                 rst,
  // F1: the lookup, read as the block moves into F2 (re)
  input  logic                 re,
  input  logic [38:4]          blk,
  input  logic [HW-1:0]        gh,
  // F2: the block's per-slot directions, and its indices and tags (for the FTQ)
  output logic [NP-1:0]        dir,
  output logic [NT*(LI+TW)+BI-1:0] ix,
  // Training (commit)
  input  logic [CW-1:0]        t_v,
  input  logic [CW-1:0][NT*(LI+TW)+BI-1:0] t_ix,
  input  logic [CW-1:0][SW-1:0] t_slot,
  input  logic [CW-1:0]        t_taken,
  input  logic [CW-1:0]        t_pred
);
  localparam int IXW = NT * (LI + TW) + BI;
  localparam int HL [4] = '{4, 9, 18, 40};
  typedef struct packed {
    logic          v;
    logic [SW-1:0] slot;
    logic [TW-1:0] tag;
    logic [2:0]    ctr;
    logic [1:0]    u;
  } sub_t;
  localparam int EW = 2 * $bits(sub_t);
  typedef sub_t [1:0] ent_t;

  // ---- Hashes ----
  // the block address folded into n bits (blk[38:4], 35 bits)
  function automatic logic [LI-1:0] afold(input logic [38:4] a);
    logic [LI-1:0] r;
    r = '0;
    for (int i = 0; i < 35; i++) r[i % LI] ^= a[4 + i];
    return r;
  endfunction
  // the history's first len bits folded into LI bits, or into TW (tags) and TW - 1 bits
  function automatic logic [LI-1:0] hfold(input logic [HW-1:0] h, input int len);
    logic [LI-1:0] r;
    r = '0;
    for (int i = 0; i < len; i++) r[i % LI] ^= h[i];
    return r;
  endfunction
  function automatic logic [TW-1:0] tfold(input logic [HW-1:0] h, input int len, input int n);
    logic [TW-1:0] r;
    r = '0;
    for (int i = 0; i < len; i++) r[i % n] ^= h[i];
    return r;
  endfunction
  // {base index, then per table: tag, index}
  function automatic logic [IXW-1:0] hash(input logic [38:4] a, input logic [HW-1:0] h);
    logic [IXW-1:0] r;
    logic [LI-1:0]  ai;
    ai = afold(a);
    r = '0;
    r[IXW-1 -: BI] = a[4 +: BI];
    for (int t = 0; t < NT; t++) begin
      logic [LI-1:0] i;
      logic [TW-1:0] tg;
      i  = ai ^ hfold(h, HL[t]);
      tg = a[4 +: TW] ^ tfold(h, HL[t], TW) ^ (tfold(h, HL[t], TW - 1) << 1);
      r[t*(LI+TW) +: LI+TW] = {tg, i};
    end
    return r;
  endfunction
  function automatic logic [LI-1:0] ix_idx(input logic [IXW-1:0] x, input int t);
    return x[t*(LI+TW) +: LI];
  endfunction
  function automatic logic [TW-1:0] ix_tag(input logic [IXW-1:0] x, input int t);
    return x[t*(LI+TW) + LI +: TW];
  endfunction

  logic [IXW-1:0] ix_f1, ix_q;
  assign ix_f1 = hash(blk, gh);
  always_ff @(posedge clk) if (re) ix_q <= ix_f1;
  assign ix = ix_q;

  // ---- Training queue and its port-B pipeline ----
  localparam int QN = 4;
  typedef struct packed {
    logic [IXW-1:0] ix;
    logic [SW-1:0]  slot;
    logic           taken, pred;
  } treq_t;
  treq_t [QN-1:0] q_q;
  logic [idx_w(QN+1)-1:0] qn_q;
  treq_t          t2_q;                    // T2: the request whose entries T1 read
  logic           t2_v_q;
  logic           deq;                     // T1: port B reads the head request's entries
  assign deq = qn_q != '0 && !t2_v_q;      // (not while T2 writes)
  always_ff @(posedge clk) begin
    if (rst) begin
      qn_q   <= '0;
      t2_v_q <= 1'b0;
    end else begin
      int n;
      treq_t [QN-1:0] q;
      q = q_q;
      n = int'(qn_q);
      if (deq) begin
        for (int k = 0; k < QN - 1; k++) q[k] = q[k + 1];
        n--;
      end
      for (int j = 0; j < CW; j++)
        if (t_v[j] && n < QN) begin
          q[n] = '{ix: t_ix[j], slot: t_slot[j], taken: t_taken[j], pred: t_pred[j]};
          n++;
        end
      q_q    <= q;
      qn_q   <= (idx_w(QN+1))'(n);
      t2_v_q <= deq;
    end
    if (deq) t2_q <= q_q[0];
  end

  // ---- Memories: port A predicts, port B trains ----
  ent_t [NT-1:0]        ra, rb, wb;
  logic [NP-1:0][1:0]   bra, brb, bwb;
  logic                 b_en, b_we;
  assign b_en = deq || t2_v_q;
  assign b_we = t2_v_q;
  for (genvar t = 0; t < NT; t++) begin : g_tab
    logic [EW-1:0] da, db;
    tg_ram_tdp #(.DEPTH(1 << LI), .WIDTH(EW)) u_mem (
      .clk, .en_a(re), .we_a(1'b0), .addr_a(ix_idx(ix_f1, t)), .wdata_a('0), .rdata_a(da),
      .en_b(b_en), .we_b(b_we), .addr_b(t2_v_q ? ix_idx(t2_q.ix, t) : ix_idx(q_q[0].ix, t)),
      .wdata_b(wb[t]), .rdata_b(db));
    assign ra[t] = ent_t'(da);
    assign rb[t] = ent_t'(db);
  end
  begin : g_base
    logic [2*NP-1:0] da, db;
    tg_ram_tdp #(.DEPTH(1 << BI), .WIDTH(2 * NP)) u_mem (
      .clk, .en_a(re), .we_a(1'b0), .addr_a(ix_f1[IXW-1 -: BI]), .wdata_a('0), .rdata_a(da),
      .en_b(b_en), .we_b(b_we), .addr_b(t2_v_q ? t2_q.ix[IXW-1 -: BI] : q_q[0].ix[IXW-1 -: BI]),
      .wdata_b(bwb), .rdata_b(db));
    assign bra = da;
    assign brb = db;
  end

  // ---- F2: each slot's direction ----
  always_comb begin
    for (int s = 0; s < NP; s++) begin
      logic found;
      found  = 1'b0;
      dir[s] = bra[s][1];
      for (int t = NT - 1; t >= 0; t--)
        for (int w = 0; w < 2; w++)
          if (!found && ra[t][w].v && ra[t][w].tag == ix_tag(ix_q, t) && ra[t][w].slot == SW'(s)) begin
            found  = 1'b1;
            dir[s] = ra[t][w].ctr[2];
          end
    end
  end

  // ---- T2: the update ----
  always_comb begin
    int  pt, pw, at, aw;
    logic pdir, adir, done;
    logic [SW-1:0] s;
    done = 1'b0;
    s  = t2_q.slot;
    wb = rb;
    bwb = brb;
    pt = -1; pw = 0; at = -1; aw = 0;
    for (int t = NT - 1; t >= 0; t--)
      for (int w = 0; w < 2; w++)
        if (rb[t][w].v && rb[t][w].tag == ix_tag(t2_q.ix, t) && rb[t][w].slot == s) begin
          if (pt < 0) begin pt = t; pw = w; end
          else if (at < 0 && t < pt) begin at = t; aw = w; end
        end
    adir = (at >= 0) ? rb[at][aw].ctr[2] : brb[s][1];
    pdir = (pt >= 0) ? rb[pt][pw].ctr[2] : adir;
    if (pt >= 0) begin
      if (t2_q.taken && rb[pt][pw].ctr != 3'd7) wb[pt][pw].ctr = rb[pt][pw].ctr + 1'b1;
      if (!t2_q.taken && rb[pt][pw].ctr != 3'd0) wb[pt][pw].ctr = rb[pt][pw].ctr - 1'b1;
      if (pdir != adir) begin
        if (pdir == t2_q.taken && rb[pt][pw].u != 2'd3) wb[pt][pw].u = rb[pt][pw].u + 1'b1;
        if (pdir != t2_q.taken && rb[pt][pw].u != 2'd0) wb[pt][pw].u = rb[pt][pw].u - 1'b1;
      end
    end else begin
      if (t2_q.taken && brb[s] != 2'd3) bwb[s] = brb[s] + 1'b1;
      if (!t2_q.taken && brb[s] != 2'd0) bwb[s] = brb[s] - 1'b1;
    end
    if (t2_q.pred != t2_q.taken && pt < NT - 1) begin
      for (int t = 0; t < NT; t++)
        if (t > pt && !done)
          for (int w = 0; w < 2; w++)
            if (!done && (!rb[t][w].v || rb[t][w].u == 2'd0)) begin
              wb[t][w] = '{v: 1'b1, slot: s, tag: ix_tag(t2_q.ix, t), ctr: t2_q.taken ? 3'd4 : 3'd3, u: 2'd0};
              done = 1'b1;
            end
      if (!done)
        for (int t = 0; t < NT; t++)
          if (t > pt)
            for (int w = 0; w < 2; w++)
              if (rb[t][w].u != 2'd0) wb[t][w].u = rb[t][w].u - 1'b1;
    end
  end

`ifndef SYNTHESIS
  initial if (NT != 4) $error("tg_tage: the history lengths are set for four tables");
`endif
endmodule
