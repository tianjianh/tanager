// TAGE-lite direction predictor (plan §4.2; M6; core-pipeline.md §3.2), read per fetch block.
//
// Tables, in block memory, read in F1 on the block address and the speculative history, the data
// in F2 (like the I$ data):
// - a base table: BI index bits (2K blocks), a 2-bit counter per halfword slot (taken: >= 2);
// - NT tagged tables of 2^LI entries, each entry two sub-entries {valid, slot, tag, ctr, u}: a
//   branch matches the sub-entry with its slot (its last parcel's, as the micro-BTB keys it) and
//   the table's tag for the block. ctr is 3 bits (taken: >= 4), u 2 bits.
// The provider for a slot is the longest-history table that matches; without one, the base.
// Index and tag: the block address folded with the history's first hl(t) bits (the newest
// first), as in the behavioural model the design was chosen on (reports/m6-tage-design.md).
//
// Training (commit, in order): a queue of requests, each with its block's FTQ entry and the
// branch's slot, outcome and fetch-time direction. The head's indices and tags, which the FTQ kept
// from fetch, are read from it as the request leaves the queue (the FTQ frees no entry the queue
// still names). Port B of each memory reads the entries (T1) and writes them back updated (T2),
// one request every two cycles; a full queue drops a request. The update: the provider's counter moves toward the
// outcome; its useful bits move when its direction differed from the next match's (or the
// base's); without a provider the base counter moves. A wrong fetch-time direction allocates one
// sub-entry in a longer table than the provider (the shortest with a candidate: an invalid way first,
// else one not useful; way 0 before way 1), else every candidate's useful bits age.
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
  parameter int FW = 6,               // an FTQ entry's pointer, with its wrap bit
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
  // Training (commit): each request's FTQ entry; the queue's head entry (q_v: the queue holds one)
  // and its indices and tags, read from the FTQ
  input  logic [CW-1:0]        t_v,
  input  logic [CW-1:0][FW-1:0] t_ftq,
  input  logic [CW-1:0][SW-1:0] t_slot,
  input  logic [CW-1:0]        t_taken,
  input  logic [CW-1:0]        t_pred,
  output logic                 q_v,
  output logic [FW-1:0]        q_ftq,
  input  logic [NT*(LI+TW)+BI-1:0] q_ix
);
  localparam int IXW = NT * (LI + TW) + BI;
  // history lengths, geometric to 40 bits: by table count (the M6 size study's first pass)
  function automatic int hl(input int t);
    case (NT)
      1:       return 12;
      2:       return (t == 0) ? 8 : 32;
      3:       return (t == 0) ? 5 : (t == 1) ? 14 : 40;
      default: return (t == 0) ? 4 : (t == 1) ? 9 : (t == 2) ? 18 : 40;
    endcase
  endfunction
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
      i  = ai ^ hfold(h, hl(t));
      tg = a[4 +: TW] ^ tfold(h, hl(t), TW) ^ (tfold(h, hl(t), TW - 1) << 1);
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
    logic [FW-1:0]  ftq;
    logic [SW-1:0]  slot;
    logic           taken, pred;
  } treq_t;
  typedef struct packed {
    logic [IXW-1:0] ix;
    logic [SW-1:0]  slot;
    logic           taken, pred;
  } t2_t;
  treq_t [QN-1:0] q_q;
  logic [idx_w(QN+1)-1:0] qn_q;
  t2_t            t2_q;                    // T2: the request whose entries T1 read
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
          q[n] = '{ftq: t_ftq[j], slot: t_slot[j], taken: t_taken[j], pred: t_pred[j]};
          n++;
        end
      q_q    <= q;
      qn_q   <= (idx_w(QN+1))'(n);
      t2_v_q <= deq;
    end
    if (deq) t2_q <= '{ix: q_ix, slot: q_q[0].slot, taken: q_q[0].taken, pred: q_q[0].pred};
  end
  assign q_v   = qn_q != '0;
  assign q_ftq = q_q[0].ftq;

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
      .en_b(b_en), .we_b(b_we), .addr_b(t2_v_q ? ix_idx(t2_q.ix, t) : ix_idx(q_ix, t)),
      .wdata_b(wb[t]), .rdata_b(db));
    assign ra[t] = ent_t'(da);
    assign rb[t] = ent_t'(db);
  end
  begin : g_base
    logic [2*NP-1:0] da, db;
    tg_ram_tdp #(.DEPTH(1 << BI), .WIDTH(2 * NP)) u_mem (
      .clk, .en_a(re), .we_a(1'b0), .addr_a(ix_f1[IXW-1 -: BI]), .wdata_a('0), .rdata_a(da),
      .en_b(b_en), .we_b(b_we), .addr_b(t2_v_q ? t2_q.ix[IXW-1 -: BI] : q_ix[IXW-1 -: BI]),
      .wdata_b(bwb), .rdata_b(db));
    assign bra = da;
    assign brb = db;
  end

  // ---- F2: each slot's direction ----
  // Flat (timing: the BRAMs' outputs lead F2's decision): each sub-entry's tag is compared once
  // (tmv), not within every slot's search; a slot's candidates are the sub-entries that match with
  // its slot, in priority order (the longest table first, then way 0), and its direction is the
  // first one's counter, else the base's: one function of the candidates' hits and counters
  localparam int NK = 2 * NT;
  logic [NK-1:0]   km;                      // candidate k (priority order): valid and its tag matches
  logic [NK-1:0]   kc;                      // ... its counter's direction
  logic [NK-1:0][SW-1:0] ks;                // ... its slot
  always_comb
    for (int t = 0; t < NT; t++)
      for (int w = 0; w < 2; w++) begin
        km[2 * (NT - 1 - t) + w] = ra[t][w].v && ra[t][w].tag == ix_tag(ix_q, t);
        kc[2 * (NT - 1 - t) + w] = ra[t][w].ctr[2];
        ks[2 * (NT - 1 - t) + w] = ra[t][w].slot;
      end
  always_comb begin
    for (int s = 0; s < NP; s++) begin
      logic [NK-1:0] h;
      logic          any;
      for (int k = 0; k < NK; k++) h[k] = km[k] && ks[k] == SW'(s);
      dir[s] = bra[s][1];
      any    = 1'b0;
      for (int k = 0; k < NK; k++) begin
        if (h[k] && !any) dir[s] = kc[k];
        any = any || h[k];
      end
    end
  end
`ifndef SYNTHESIS
  // the search as first built, per slot
  always_ff @(posedge clk) begin
    if (!rst) begin
      for (int s = 0; s < NP; s++) begin
        logic found, d;
        found = 1'b0;
        d     = bra[s][1];
        for (int t = NT - 1; t >= 0; t--)
          for (int w = 0; w < 2; w++)
            if (!found && ra[t][w].v && ra[t][w].tag == ix_tag(ix_q, t) && ra[t][w].slot == SW'(s)) begin
              found = 1'b1;
              d     = ra[t][w].ctr[2];
            end
        assert (dir[s] == d) else $error("tg_tage: the flat direction differs from the search's");
      end
    end
  end
`endif

  // ---- T2: the update ----
  always_comb begin
    int  pt, pw, at, aw, nw;
    logic pdir, adir, done;
    logic [SW-1:0] s;
    done = 1'b0;
    s  = t2_q.slot;
    wb = rb;
    bwb = brb;
    pt = -1; pw = 0; at = -1; aw = 0; nw = -1;
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
      // An invalid way before a not-useful one: taking way 0 whenever it was either, two branches sharing an entry
      // evicted each other's fresh way-0 sub-entry for ever while way 1 stayed invalid (ud's loop exits; smt2-study,
      // area_recovery §6.16)
      for (int t = 0; t < NT; t++)
        if (t > pt && !done) begin
          if      (!rb[t][0].v)        nw = 0;
          else if (!rb[t][1].v)        nw = 1;
          else if (rb[t][0].u == 2'd0) nw = 0;
          else if (rb[t][1].u == 2'd0) nw = 1;
          else                         nw = -1;
          if (nw >= 0) begin
            wb[t][nw] = '{v: 1'b1, slot: s, tag: ix_tag(t2_q.ix, t), ctr: t2_q.taken ? 3'd4 : 3'd3, u: 2'd0};
            done = 1'b1;
          end
        end
      if (!done)
        for (int t = 0; t < NT; t++)
          if (t > pt)
            for (int w = 0; w < 2; w++)
              if (rb[t][w].u != 2'd0) wb[t][w].u = rb[t][w].u - 1'b1;
    end
  end

`ifndef SYNTHESIS
  initial if (NT < 1 || NT > 4) $error("tg_tage: one to four tagged tables");
`endif
endmodule
