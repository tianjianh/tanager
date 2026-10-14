// Micro-BTB (plan §4.2): predicts the next fetch block in one cycle from the current one.
// Spike S5. Two organisations, same ports:
//   FA = 0: UBTB_ENTRIES entries, 2-way set associative, in LUTRAM (tg_ram_lut); index
//           pc[4 +: SET_W] (16-byte blocks), partial tag above it plus the thread ID.
//   FA = 1: the fallback, NFA entries fully associative in flip-flops, one-hot select.
// An entry holds the target (VA bits 38:1) and the halfword offset of the taken branch in
// the block (fetch drops what follows it). Lookup is combinational (the next-PC loop);
// updates come registered from BP2/commit. Replacement: the update names the way (FA = 0)
// or the entry (FA = 1); the training logic owns the policy.
module tg_ubtb
  import tg_pkg::*;
#(
  parameter bit FA     = 1'b0,
  parameter int NE     = UBTB_ENTRIES,  // FA = 0: total entries (2 ways)
  parameter int NFA    = 32,            // FA = 1
  parameter int TAG_W  = 12,
  localparam int SETS  = NE / 2,
  localparam int SET_W = idx_w(SETS),
  localparam int SLOT_W = idx_w(FETCH_BYTES / 2),
  localparam int UW    = FA ? idx_w(NFA) : 1    // update index: entry (FA) or way
) (
  input  logic               clk,
  input  logic               rst,
  // Lookup
  input  logic [38:4]        pc,          // fetch block address
  input  tid_t               tid,
  output logic               hit,
  output logic [38:1]        target,
  output logic [SLOT_W-1:0]  br_slot,
  // Update
  input  logic               upd_valid,
  input  logic [UW-1:0]      upd_way,
  input  logic [38:4]        upd_pc,
  input  tid_t               upd_tid,
  input  logic [38:1]        upd_target,
  input  logic [SLOT_W-1:0]  upd_slot,
  input  logic               upd_inval    // remove the entry instead
);
  typedef struct packed {
    logic              v;
    tid_t              tid;
    logic [TAG_W-1:0]  tag;
    logic [38:1]       tgt;
    logic [SLOT_W-1:0] slot;
  } ent_t;
  localparam int EBITS = $bits(ent_t);

  if (!FA) begin : g_set
    // Tag: the TAG_W block-address bits above the index
    /* verilator lint_off UNUSEDSIGNAL */  // the tag is a slice of the block address
    function automatic logic [TAG_W-1:0] tag_of(input logic [38:4] a);
      return a[4 + SET_W +: TAG_W];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    logic [0:0][SET_W-1:0] ra;
    assign ra[0] = pc[4 +: SET_W];

    // One LUTRAM per way (each way has its own write enable)
    ent_t [1:0] e;
    for (genvar w = 0; w < 2; w++) begin : g_way
      ent_t wd;
      assign wd = '{v: !upd_inval, tid: upd_tid, tag: tag_of(upd_pc), tgt: upd_target,
                    slot: upd_slot};
      logic [0:0][EBITS-1:0] q;
      tg_ram_lut #(.DEPTH(SETS), .WIDTH(EBITS), .NR(1)) u_ram (
        .clk, .we(upd_valid && upd_way == UW'(w)), .waddr(upd_pc[4 +: SET_W]), .wdata(wd),
        .raddr(ra), .rdata(q));
      assign e[w] = q[0];
    end
    // Valid bits are LUTRAM contents, so reset cannot clear them; the front end invalidates
    // every set after reset (32 cycles) before it uses predictions.
    logic [1:0] h;
    for (genvar w = 0; w < 2; w++) begin : g_hit
      assign h[w] = e[w].v && e[w].tid == tid && e[w].tag == tag_of(pc);
    end
    assign hit     = |h;
    assign target  = h[0] ? e[0].tgt : e[1].tgt;
    assign br_slot = h[0] ? e[0].slot : e[1].slot;
    logic unused;
    assign unused = rst;
  end else begin : g_fa
    logic [NFA-1:0]          v_q;
    tid_t [NFA-1:0]          tid_q;
    logic [NFA-1:0][38:4]    pc_q;
    logic [NFA-1:0][38:1]    tgt_q;
    logic [NFA-1:0][SLOT_W-1:0] slot_q;
    logic [NFA-1:0] h;
    for (genvar i = 0; i < NFA; i++) begin : g_cmp
      assign h[i] = v_q[i] && tid_q[i] == tid && pc_q[i] == pc;
    end
    always_comb begin
      target  = '0;
      br_slot = '0;
      for (int i = 0; i < NFA; i++) begin
        target  |= {38{h[i]}} & tgt_q[i];
        br_slot |= {SLOT_W{h[i]}} & slot_q[i];
      end
    end
    assign hit = |h;
    always_ff @(posedge clk) begin
      if (rst) v_q <= '0;
      else if (upd_valid) v_q[upd_way] <= !upd_inval;
      if (upd_valid) begin
        tid_q[upd_way]  <= upd_tid;
        pc_q[upd_way]   <= upd_pc;
        tgt_q[upd_way]  <= upd_target;
        slot_q[upd_way] <= upd_slot;
      end
    end
  end
endmodule
