// M9's indirect-target table (docs/spec/core-pipeline.md §3.2; DR-190, the coordinator's 01e2c013; m9-plan.md §6): a
// target per path of recent indirect targets, for a JALR that is not a return, read per fetch block as TAGE is.
// smt2-study's model (tgsim's itt_entries; area_recovery.md §7.11-7.12), keyed by the block and the slot of the
// JALR's last parcel instead of the JALR's address, so F1 reads it before pre-decode knows which parcel jumps. Path
// history for indirect jumps: Driesen and Hölzle, ISCA 1998; a tagged target cache: Chang, Hao and Patt, ISCA 1997.
//   MODE 1: one table of 256 entries, indexed by the block address folded to 8 bits, xor the path history, xor the
//           history shifted right by 8 (the model's).
//   MODE 2: two of 128: one indexed so (to 7 bits), one by the block address alone. The path half's entry when it
//           matches, else the block half's (smt2-study's split).
// An entry: {valid, slot, an 8-bit tag (the block address folded another way), U (the privilege it was trained in:
// U against S and M, so U-mode code never steers an S-mode jump), the target's bits 38:1}: 51 bits in a 72-bit row of
// block memory, one RAMB36 a table. F1 reads it as the block moves into F2 (re); F2 gets the entry's hit (valid, tag
// and privilege), its slot and its target. Commit writes {1, slot, tag, U, target} where the jump's block read: the
// block address and the history that block's lookup used (the FTQ keeps it), so lookup and training agree.
module tg_itt
  import tg_pkg::*;
#(
  parameter int MODE = 1,
  parameter int NP   = 8,                 // slots per block
  parameter int HW   = 16,                // the path history's bits
  localparam int SW  = idx_w(NP),
  localparam int LI  = (MODE == 2) ? 7 : 8,   // a table's index bits
  localparam int TW  = 8
) (
  input  logic          clk,
  // F1: the lookup, read as the block moves into F2 (re): the stream's block (TAGE's), its path history, its privilege
  input  logic          re,
  input  logic [38:4]   blk,
  input  logic [HW-1:0] ph,
  input  logic          pu,
  // F2: the block's entry
  output logic          hit,
  output logic [SW-1:0] slot,
  output logic [38:1]   tgt,
  // Training (commit): the jump's block (its last parcel's), the history its block's lookup used, its privilege,
  // its last parcel's slot and its target
  input  logic          we,
  input  logic [38:4]   w_blk,
  input  logic [HW-1:0] w_ph,
  input  logic          w_pu,
  input  logic [SW-1:0] w_slot,
  input  logic [38:1]   w_tgt
);
  typedef struct packed {
    logic          v;
    logic [SW-1:0] slot;
    logic [TW-1:0] tag;
    logic          pu;
    logic [38:1]   tgt;
  } ent_t;
  localparam int EW = $bits(ent_t);

  // The block address folded to LI bits, as TAGE's (blk[38:4], 35 bits; the stream's bit is the top one); the tag
  // walks it from the top, so the two folds take different bits together
  function automatic logic [LI-1:0] ifold(input logic [38:4] a);
    logic [LI-1:0] r;
    r = '0;
    for (int i = 0; i < 35; i++) r[i % LI] ^= a[4 + i];
    return r;
  endfunction
  function automatic logic [TW-1:0] tfold(input logic [38:4] a);
    logic [TW-1:0] r;
    r = '0;
    for (int i = 0; i < 35; i++) r[i % TW] ^= a[38 - i];
    return r;
  endfunction
  // the path half's index: the block xor the history folded to LI bits (with 8 bits the model's h ^ h >> 8)
  function automatic logic [LI-1:0] pidx(input logic [38:4] a, input logic [HW-1:0] h);
    logic [LI-1:0] r;
    r = ifold(a);
    for (int i = 0; i < HW; i++) r[i % LI] ^= h[i];
    return r;
  endfunction

  // F1: the indices; the tag and privilege go with the block into F2
  logic [TW-1:0] tg_q;
  logic          pu_q;
  always_ff @(posedge clk)
    if (re) begin
      tg_q <= tfold(blk);
      pu_q <= pu;
    end
  ent_t wd;
  assign wd = '{v: 1'b1, slot: w_slot, tag: tfold(w_blk), pu: w_pu, tgt: w_tgt};
  ent_t          ep, eb;
  logic [EW-1:0] dp;
  tg_ram_sdp #(.DEPTH(1 << LI), .WIDTH(EW)) u_path (
    .clk, .we(we), .waddr(pidx(w_blk, w_ph)), .wdata(wd), .re, .raddr(pidx(blk, ph)), .rdata(dp));
  assign ep = ent_t'(dp);
  if (MODE == 2) begin : g_blk
    logic [EW-1:0] db;
    tg_ram_sdp #(.DEPTH(1 << LI), .WIDTH(EW)) u_blk (
      .clk, .we(we), .waddr(ifold(w_blk)), .wdata(wd), .re, .raddr(ifold(blk)), .rdata(db));
    assign eb = ent_t'(db);
  end else begin : g_one
    assign eb = '0;
  end

  // F2: the path half's entry when it matches, else the block half's
  logic hp, hb;
  assign hp   = ep.v && ep.tag == tg_q && ep.pu == pu_q;
  assign hb   = eb.v && eb.tag == tg_q && eb.pu == pu_q;
  assign hit  = hp || hb;
  assign slot = hp ? ep.slot : eb.slot;
  assign tgt  = hp ? ep.tgt : eb.tgt;

`ifndef SYNTHESIS
  initial if (MODE < 1 || MODE > 2) $error("tg_itt: MODE is 1 or 2");
`endif
endmodule
