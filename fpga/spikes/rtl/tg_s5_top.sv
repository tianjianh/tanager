// Spike S5: the front end's 1-cycle next-PC loop and the fetch pipeline (plan §3.2, §4.2,
// §8.1), registered inputs and outputs.
//   BP0/IF1: the fetch PC register and the micro-BTB (FA = 0: 64-entry 2-way LUTRAM;
//            FA = 1: the 32-entry flip-flop fallback) close a 1-cycle loop. The next PC also
//            drives the I$ data address directly (the I$ address register is the BRAMs'
//            own), so the loop ends at 16 BRAM address pins: zero-bubble fetch after a
//            redirect. Redirects (registered) override; SMT2 builds keep the other thread's
//            next PC aside and switch on the registered ICOUNT choice.
//   IF1:     I$ data, 8 ways x 16 bytes in BRAM with output registers; tags in LUTRAM;
//            ITLB (16 entries, fully associative).
//   IF2:     tag compare, way select, pre-decode (tg_predecode).
//   IF3:     compaction into the instruction queue (tg_fetch_compact, WR writes per cycle);
//            DECODE_WIDTH instructions leave per cycle.
module tg_s5_top
  import tg_pkg::*;
#(
  parameter int FA = 0,
  parameter int WR = 4,
  localparam int NP    = FETCH_BYTES / 2,
  localparam int SW    = idx_w(NP),
  localparam int WAYS  = L1_WAYS,
  localparam int SETS  = (L1I_KIB * 1024) / (WAYS * 64),
  localparam int SET_W = idx_w(SETS),
  localparam int WAY_W = idx_w(WAYS),
  localparam int PPN_W = PA_W - 12,
  localparam int TAG_W = PPN_W + 1,
  localparam int ROWW  = idx_w((SETS * 64) / FETCH_BYTES),   // 16-byte rows per way
  localparam int META_W = 8,
  localparam int IB_W  = 32 + 1 + SW + 3 + META_W,
  localparam int UW    = FA != 0 ? 5 : 1
) (
  input  logic                    clk,
  input  logic                    rst_i,
  // Redirects (registered upstream) and fetch control
  input  logic                    redirect_i,
  input  logic [38:1]             redirect_pc_i,
  input  tid_t                    redirect_tid_i,
  input  logic                    stall_i,          // queue nearly full (registered)
  input  tid_t                    fetch_tid_i,      // ICOUNT choice for the next fetch
  // micro-BTB update
  input  logic                    upd_valid_i,
  input  logic [UW-1:0]           upd_way_i,
  input  logic [38:4]             upd_pc_i,
  input  tid_t                    upd_tid_i,
  input  logic [38:1]             upd_target_i,
  input  logic [SW-1:0]           upd_slot_i,
  // I$ refill (data and tags), ITLB fill
  input  logic                    rf_valid_i,
  input  logic [WAY_W-1:0]        rf_way_i,
  input  logic [ROWW-1:0]         rf_row_i,
  input  logic [8*FETCH_BYTES-1:0] rf_data_i,
  input  logic [TAG_W-1:0]        rf_tag_i,
  input  logic                    tf_valid_i,
  input  logic [3:0]              tf_idx_i,
  input  logic [38:12]            tf_vpn_i,
  input  logic [PPN_W-1:0]        tf_ppn_i,
  input  logic [15:0]             asid_i,
  // Decode side
  input  logic [idx_w(DECODE_WIDTH + 1)-1:0] take_i,
  output logic [DECODE_WIDTH-1:0] out_valid_o,
  output logic [DECODE_WIDTH-1:0][IB_W-1:0] out_insn_o,
  output logic [38:1]             fetch_pc_o,
  output logic                    if2_hit_o
);
  // ---- Input registers ----
  logic rst, redirect_q, stall_q, upd_valid_q, rf_valid_q, tf_valid_q;
  logic [38:1] redirect_pc_q, upd_target_q;
  tid_t redirect_tid_q, fetch_tid_q, upd_tid_q;
  logic [UW-1:0] upd_way_q;
  logic [38:4] upd_pc_q;
  logic [SW-1:0] upd_slot_q;
  logic [WAY_W-1:0] rf_way_q;
  logic [ROWW-1:0] rf_row_q;
  logic [8*FETCH_BYTES-1:0] rf_data_q;
  logic [TAG_W-1:0] rf_tag_q;
  logic [3:0] tf_idx_q;
  logic [38:12] tf_vpn_q;
  logic [PPN_W-1:0] tf_ppn_q;
  logic [15:0] asid_q;
  logic [idx_w(DECODE_WIDTH + 1)-1:0] take_q;
  always_ff @(posedge clk) begin
    rst <= rst_i;
    redirect_q <= redirect_i; redirect_pc_q <= redirect_pc_i; redirect_tid_q <= redirect_tid_i;
    stall_q <= stall_i; fetch_tid_q <= fetch_tid_i;
    upd_valid_q <= upd_valid_i; upd_way_q <= upd_way_i; upd_pc_q <= upd_pc_i;
    upd_tid_q <= upd_tid_i; upd_target_q <= upd_target_i; upd_slot_q <= upd_slot_i;
    rf_valid_q <= rf_valid_i; rf_way_q <= rf_way_i; rf_row_q <= rf_row_i; rf_data_q <= rf_data_i;
    rf_tag_q <= rf_tag_i; tf_valid_q <= tf_valid_i; tf_idx_q <= tf_idx_i; tf_vpn_q <= tf_vpn_i;
    tf_ppn_q <= tf_ppn_i; asid_q <= asid_i; take_q <= take_i;
  end

  // ---- BP0: the next-PC loop ----
  logic [38:1] fpc_q, fpc_d;
  tid_t        ftid_q;
  logic [NUM_THREADS-1:0][38:1] saved_q;
  logic        hit;
  logic [38:1] target;
  logic [SW-1:0] br_slot;

  tg_ubtb #(.FA(FA != 0), .NE(UBTB_ENTRIES), .NFA(32)) u_ubtb (
    .clk, .rst, .pc(fpc_q[38:4]), .tid(ftid_q), .hit, .target, .br_slot,
    .upd_valid(upd_valid_q), .upd_way(upd_way_q), .upd_pc(upd_pc_q), .upd_tid(upd_tid_q),
    .upd_target(upd_target_q), .upd_slot(upd_slot_q), .upd_inval(1'b0));

  logic [38:1] pred;
  assign pred = hit ? target : {fpc_q[38:4] + 35'd1, 3'b000};
  always_comb begin
    if (redirect_q)                                  fpc_d = redirect_pc_q;
    else if (stall_q)                                fpc_d = fpc_q;
    else if (NUM_THREADS > 1 && fetch_tid_q != ftid_q) fpc_d = saved_q[fetch_tid_q];
    else                                             fpc_d = pred;
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      fpc_q   <= '0;
      ftid_q  <= '0;
      saved_q <= '0;
    end else begin
      fpc_q  <= fpc_d;
      ftid_q <= redirect_q ? redirect_tid_q : (stall_q ? ftid_q : fetch_tid_q);
      if (!redirect_q && !stall_q && fetch_tid_q != ftid_q) saved_q[ftid_q] <= pred;
      if (redirect_q && redirect_tid_q != ftid_q) saved_q[redirect_tid_q] <= redirect_pc_q;
    end
  end

  // ---- IF1: I$ data (address = next PC), tags, ITLB ----
  logic [WAYS-1:0][8*FETCH_BYTES-1:0] way_data;   // valid in IF2 (BRAM output register)
  for (genvar w = 0; w < WAYS; w++) begin : g_way
    tg_ram_sdp #(.DEPTH(1 << ROWW), .WIDTH(8 * FETCH_BYTES), .OUT_REG(1'b1), .PRIM("block")) u_data (
      .clk, .we(rf_valid_q && rf_way_q == WAY_W'(w)), .waddr(rf_row_q), .wdata(rf_data_q),
      .re(!stall_q || redirect_q), .raddr(fpc_d[4 +: ROWW]), .rdata(way_data[w]));
  end
  logic [WAYS-1:0][TAG_W-1:0] tag_rd;
  for (genvar w = 0; w < WAYS; w++) begin : g_tag
    logic [0:0][SET_W-1:0] ra;
    logic [0:0][TAG_W-1:0] rd;
    assign ra[0] = fpc_q[6 +: SET_W];
    tg_ram_lut #(.DEPTH(SETS), .WIDTH(TAG_W), .NR(1)) u_tag (
      .clk, .we(rf_valid_q && rf_way_q == WAY_W'(w)), .waddr(rf_row_q[ROWW-1 -: SET_W]),
      .wdata(rf_tag_q), .raddr(ra), .rdata(rd));
    assign tag_rd[w] = rd[0];
  end
  logic tlb_hit;
  logic [PPN_W-1:0] tlb_ppn;
  logic [5:0] tlb_perm;
  tg_dtlb #(.NE(ITLB_ENTRIES)) u_itlb (
    .clk, .rst, .tid(ftid_q), .asid(asid_q), .vpn(fpc_q[38:12]), .hit(tlb_hit), .ppn(tlb_ppn),
    .perm(tlb_perm), .fill_valid(tf_valid_q), .fill_idx(tf_idx_q), .fill_tid(ftid_q),
    .fill_asid(asid_q), .fill_vpn(tf_vpn_q), .fill_lvl(2'd0), .fill_g(1'b0), .fill_ppn(tf_ppn_q),
    .fill_perm(6'b001100), .flush_valid(1'b0), .flush_tid(ftid_q), .flush_all(1'b1),
    .flush_asid(asid_q));

  // ---- IF1 -> IF2 ----
  logic             if2_valid_q, if2_seq_q, if2_tlb_q;
  logic [38:1]      if2_pc_q;
  logic [SW-1:0]    if2_exit_q;
  logic [PPN_W-1:0] if2_ppn_q;
  logic [WAYS-1:0][TAG_W-1:0] if2_tag_q;
  always_ff @(posedge clk) begin
    if (rst || redirect_q) if2_valid_q <= 1'b0;
    else if (!stall_q)     if2_valid_q <= 1'b1;
    if (!stall_q) begin
      if2_pc_q   <= fpc_q;
      if2_exit_q <= hit ? br_slot : SW'(NP - 1);
      if2_seq_q  <= !hit;                 // the next block follows sequentially
      if2_ppn_q  <= tlb_ppn;
      if2_tlb_q  <= tlb_hit && tlb_perm[2];
      if2_tag_q  <= tag_rd;
    end
  end

  // ---- IF2: compare, way select, pre-decode ----
  logic [WAYS-1:0] way_hit;
  logic [8*FETCH_BYTES-1:0] blk;
  for (genvar w = 0; w < WAYS; w++) begin : g_hit
    assign way_hit[w] = if2_tag_q[w][TAG_W-1] && if2_tag_q[w][PPN_W-1:0] == if2_ppn_q;
  end
  always_comb begin
    blk = '0;
    for (int w = 0; w < WAYS; w++) blk |= {8*FETCH_BYTES{way_hit[w]}} & way_data[w];
  end
  logic [NP-1:0] start, is32, is_br, is_jal, is_jalr, is_call, is_ret;
  logic carry_out, carry_q;
  tg_predecode u_pd (
    .parcel(blk), .entry_slot(if2_pc_q[SW:1]), .exit_slot(if2_exit_q), .carry_in(carry_q),
    .start, .is32, .is_br, .is_jal, .is_jalr, .is_call, .is_ret, .carry_out);

  logic if2_ok;
  assign if2_ok = if2_valid_q && if2_tlb_q && |way_hit;

  // ---- IF2 -> IF3 ----
  logic                  if3_valid_q, if3_carry_q;
  logic [NP-1:0][15:0]   if3_parcel_q;
  logic [NP-1:0]         if3_start_q;
  logic [NP-1:0][2:0]    if3_marks_q;
  logic [META_W-1:0]     if3_meta_q;
  logic                  blk_ready;
  always_ff @(posedge clk) begin
    if (rst || redirect_q) begin
      if3_valid_q <= 1'b0;
      carry_q     <= 1'b0;
    end else if (!if3_valid_q || blk_ready) begin
      if3_valid_q <= if2_ok;
      carry_q     <= if2_ok && carry_out && if2_seq_q;
    end
    if (!if3_valid_q || blk_ready) begin
      if3_parcel_q <= blk;
      if3_start_q  <= start;
      if3_carry_q  <= carry_out;
      for (int p = 0; p < NP; p++) if3_marks_q[p] <= {is_br[p], is_jal[p], is_jalr[p]};
      if3_meta_q   <= {is_call[0], is_ret[0], if2_pc_q[9:4]};
    end
  end

  // ---- IF3: compaction into the instruction queue ----
  logic [DECODE_WIDTH-1:0] ov;
  logic [DECODE_WIDTH-1:0][IB_W-1:0] oi;
  tg_fetch_compact #(.WR(WR), .RD(DECODE_WIDTH), .DEPTH(IBUF_ENTRIES), .META_W(META_W)) u_cmp (
    .clk, .rst, .flush(redirect_q), .blk_valid(if3_valid_q), .parcel(if3_parcel_q),
    .start(if3_start_q), .marks(if3_marks_q), .carry_out(if3_carry_q), .meta(if3_meta_q),
    .blk_ready, .out_valid(ov), .out_insn(oi), .take(take_q));

  always_ff @(posedge clk) begin
    out_valid_o <= ov;
    out_insn_o  <= oi;
    fetch_pc_o  <= fpc_q;
    if2_hit_o   <= if2_ok;
  end

  logic unused;
  assign unused = ^{is32, tlb_perm[5:3], tlb_perm[1:0], if2_pc_q[38:10], is_call[NP-1:1],
                    is_ret[NP-1:1]};
endmodule
