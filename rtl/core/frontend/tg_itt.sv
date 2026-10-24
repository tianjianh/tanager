// M9's indirect-target table (docs/spec/core-pipeline.md §3.2; DR-190, the coordinator's 01e2c013; m9-plan.md §6): a
// target per path of recent indirect targets, for a JALR that is not a return, read per fetch block as TAGE is.
// smt2-study's model (tgsim's itt_entries; area_recovery.md §7.11-7.12), keyed by the block and the slot of the
// JALR's last parcel instead of the JALR's address, so F1 reads it before pre-decode knows which parcel jumps. Path
// history for indirect jumps: Driesen and Hölzle, ISCA 1998; a tagged target cache: Chang, Hao and Patt, ISCA 1997.
//   MODE 1: one table of 256 entries, indexed by the block address folded to 8 bits, xor the path history, xor the
//           history shifted right by 8 (the model's).
//   MODE 2: two of 128: one indexed so (to 7 bits), one by the block address alone. The path half's entry when it
//           matches, else the block half's (smt2-study's split).
// An entry: a key {valid, slot, an 8-bit tag (the block address folded another way), U (the privilege it was trained
// in: U against S and M, so U-mode code never steers an S-mode jump)}, 13 bits in LUT RAM, and the target's bits 38:1
// in block memory, one RAMB36 a table. F1 checks the key (valid, tag, privilege) as the block moves into F2 (re) and
// gives its hit and slot (hit1, slot1), which fetch registers beside the micro-BTB's: so F2's exit search takes its
// predicted slot from registers, as without the table (the coordinator's restructure, 10-24: with the key read from
// block memory, the search was 2-4 levels deeper from the I$ data in spikes-2's placed runs). F2 gets the same hit and
// slot registered, the target, and the lookup's coordinates (ri: the index or indices and the tag), which the FTQ
// keeps for the block. Commit writes the key and the target at the coordinates the jump's block read (w_ri), so lookup
// and training agree without the block's address or history at commit. Both memories read first, as one row did.
module tg_itt
  import tg_pkg::*;
#(
  parameter int MODE = 1,
  parameter int NP   = 8,                 // slots per block
  parameter int HW   = 16,                // the path history's bits
  localparam int SW  = idx_w(NP),
  localparam int LI  = (MODE == 2) ? 7 : 8,   // a table's index bits
  localparam int TW  = 8,
  localparam int RIW = (MODE == 2 ? 2 * LI : LI) + TW   // the coordinates: {path index, [block index,] tag}
) (
  input  logic           clk,
  // F1: the lookup, read as the block moves into F2 (re): the stream's block (TAGE's), its path history, its privilege
  input  logic           re,
  input  logic [38:4]    blk,
  input  logic [HW-1:0]  ph,
  input  logic           pu,
  // F1: the key's check, for fetch's predicted-slot registers
  output logic           hit1,
  output logic [SW-1:0]  slot1,
  // F2: the block's entry (the check registered on re, and the target), and the coordinates its lookup read
  output logic           hit,
  output logic [SW-1:0]  slot,
  output logic [38:1]    tgt,
  output logic [RIW-1:0] ri,
  // Training (commit): the coordinates the jump's block read (its last parcel's block), its privilege, its last
  // parcel's slot and its target
  input  logic           we,
  input  logic [RIW-1:0] w_ri,
  input  logic           w_pu,
  input  logic [SW-1:0]  w_slot,
  input  logic [38:1]    w_tgt
);
  typedef struct packed {
    logic          v;
    logic [SW-1:0] slot;
    logic [TW-1:0] tag;
    logic          pu;
  } key_t;
  localparam int KW = $bits(key_t);

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

  // F1: the indices and the tag
  logic [LI-1:0] pi, bi, pi_q, bi_q;
  logic [TW-1:0] tg, tg_q;
  assign pi = pidx(blk, ph);
  assign bi = ifold(blk);
  assign tg = tfold(blk);
  // the write's coordinates and key
  logic [LI-1:0] w_pi, w_bi;
  logic [TW-1:0] w_tg;
  key_t          wk;
  assign wk = '{v: 1'b1, slot: w_slot, tag: w_tg, pu: w_pu};
  // the path table: its keys in LUT RAM (read at F1), its targets in block memory (read on re)
  key_t          kp, kb;
  logic [KW-1:0] kpr;
  logic [38:1]   tp, tb;
  tg_ram_lut #(.DEPTH(1 << LI), .WIDTH(KW), .NR(1)) u_pkey (
    .clk, .we(we), .waddr(w_pi), .wdata(wk), .raddr(pi), .rdata(kpr));
  assign kp = key_t'(kpr);
  tg_ram_sdp #(.DEPTH(1 << LI), .WIDTH(38)) u_path (
    .clk, .we(we), .waddr(w_pi), .wdata(w_tgt), .re, .raddr(pi), .rdata(tp));
  if (MODE == 2) begin : g_blk
    logic [KW-1:0] kbr;
    tg_ram_lut #(.DEPTH(1 << LI), .WIDTH(KW), .NR(1)) u_bkey (
      .clk, .we(we), .waddr(w_bi), .wdata(wk), .raddr(bi), .rdata(kbr));
    assign kb = key_t'(kbr);
    tg_ram_sdp #(.DEPTH(1 << LI), .WIDTH(38)) u_blk (
      .clk, .we(we), .waddr(w_bi), .wdata(w_tgt), .re, .raddr(bi), .rdata(tb));
    assign ri = {pi_q, bi_q, tg_q};
    assign {w_pi, w_bi, w_tg} = w_ri;
  end else begin : g_one
    assign kb   = '0;
    assign tb   = '0;
    assign ri   = {pi_q, tg_q};
    assign {w_pi, w_tg} = w_ri;
    assign w_bi = '0;
    logic unused_bi;
    assign unused_bi = ^{bi_q, w_bi};
  end

  // F1: the keys' check, the path half's entry when it matches, else the block half's
  logic hp1, hb1, hp_q;
  assign hp1   = kp.v && kp.tag == tg && kp.pu == pu;
  assign hb1   = kb.v && kb.tag == tg && kb.pu == pu;
  assign hit1  = hp1 || hb1;
  assign slot1 = hp1 ? kp.slot : kb.slot;
  // F2: the check and the coordinates registered with the targets' read
  always_ff @(posedge clk)
    if (re) begin
      pi_q <= pi;
      bi_q <= bi;
      tg_q <= tg;
      hit  <= hit1;
      slot <= slot1;
      hp_q <= hp1;
    end
  assign tgt = hp_q ? tp : tb;

`ifndef SYNTHESIS
  initial if (MODE < 1 || MODE > 2) $error("tg_itt: MODE is 1 or 2");
`endif
endmodule
