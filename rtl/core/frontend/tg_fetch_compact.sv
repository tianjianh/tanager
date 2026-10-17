// IF3 compaction and the instruction queue (plan §4.2, §4.15). Spike S5.
//
// A pre-decoded fetch block arrives from IF2. Its whole instructions (plus one completed
// across the previous block's end, held in half_q) get ranks 0, 1, ...; up to WR of them
// are written per cycle at the queue tail, so a block with more instructions stays a
// second cycle. A 32-bit instruction starting in the block's last parcel waits in half_q
// for the next block (carry_out).
// The queue (DEPTH entries) is WR banks of LUTRAM, entry i in bank i mod WR, so a cycle's
// writes and reads (RD <= WR consecutive entries each) touch each bank at most once. The
// compaction selects directly into banks: bank b takes the instruction of rank r with
// (tail + r - done) mod WR == b, so no rotation stage follows it.
// Reads: RD instructions per cycle from the head (DECODE_WIDTH), rotated out of the banks.
// Each entry also carries three decode bits, made as it is written (a decoder per bank): illegal,
// a decode-time exception, serialising. Decode's group and its decoders' field clearing read them
// instead of waiting for a decode of their own (timing: the queue's take loop, decode -> rename).
// The state they depend on (misa, mstatus.FS, frm, the mode, TVM/TW/TSR) changes only as a
// serialising instruction or a trap commits, and the flush that follows empties the queue, so
// they are what decode would find; decode checks them in simulation.
module tg_fetch_compact
  import tg_pkg::*, tg_core_pkg::EXT_C, tg_core_pkg::EXT_FD, tg_core_pkg::dec_t,
         tg_core_pkg::dec_state_t;
#(
  parameter int WR    = 4,               // queue write ports = banks (power of two)
  parameter int RD    = DECODE_WIDTH,
  parameter int DEPTH = IBUF_ENTRIES,
  parameter int META_W = 8,              // per-instruction metadata from the front end
  localparam int NP   = FETCH_BYTES / 2,
  localparam int SW   = idx_w(NP),
  localparam int IN_W = 32 + 1 + SW + 3 + META_W,  // a candidate: insn, rvc, parcel, marks, metadata
  localparam int IB_W = IN_W + 3,                  // an entry: the decode bits, then the candidate
  localparam int QW   = idx_w(DEPTH),
  localparam int ROWS = DEPTH / WR,
  localparam int RW   = idx_w(ROWS),
  localparam int BW   = idx_w(WR),
  localparam int CW   = idx_w(NP + 2)
) (
  input  logic                    clk,
  input  logic                    rst,
  input  logic                    flush,
  input  dec_state_t              dst,        // the decoders' state (decode's)
  // Block from IF2
  input  logic                    blk_valid,
  input  logic [NP-1:0][15:0]     parcel,
  input  logic [NP-1:0]           start,
  input  logic [NP-1:0][2:0]      marks,      // {br, jal, jalr} per parcel
  input  logic                    carry_out,
  input  logic [META_W-1:0]       meta,       // e.g. FTQ index
  output logic                    blk_ready,  // the block is fully consumed this cycle
  // To decode
  output logic [RD-1:0]           out_valid,
  output logic [RD-1:0][IB_W-1:0] out_insn,
  input  logic [idx_w(RD + 1)-1:0] take        // instructions decode takes this cycle
);
  // ---- Instruction candidates: position p (0..NP-1) and the held straddler (index NP) ----
  logic                  half_v_q;
  logic [15:0]           half_q;
  logic [2:0]            half_marks_q;
  logic [NP:0]           inst_v;
  logic [NP:0][IN_W-1:0] inst;
  for (genvar p = 0; p < NP; p++) begin : g_inst
    logic [15:0] hi;
    assign hi = (p + 1 < NP) ? parcel[(p + 1) % NP] : 16'h0;
    assign inst_v[p] = start[p] && !(p == NP - 1 && carry_out);
    assign inst[p] = {meta, marks[p], SW'(p), parcel[p][1:0] != 2'b11, hi, parcel[p]};
  end
  assign inst_v[NP] = half_v_q;
  assign inst[NP]   = {meta, half_marks_q, SW'(NP - 1), 1'b0, parcel[0], half_q};

  // Ranks: the straddler first, then block order
  logic [NP:0][CW-1:0] rank;
  logic [CW-1:0]       count;
  always_comb begin
    logic [CW-1:0] r;
    r = half_v_q ? CW'(1) : CW'(0);
    rank[NP] = '0;
    for (int p = 0; p < NP; p++) begin
      rank[p] = r;
      r += CW'(inst_v[p]);
    end
    count = r;
  end

  // ---- Queue state ----
  logic [QW:0]   occ_q;
  logic [QW-1:0] head_q, tail_q;
  logic [CW-1:0] done_q;                 // instructions of this block already written
  logic [CW-1:0] left, nwr;
  assign left = count - done_q;
  assign nwr  = (left > CW'(WR)) ? CW'(WR) : left;
  logic room;
  assign room = (QW + 1)'(DEPTH) - occ_q >= (QW + 1)'(nwr);
  assign blk_ready = blk_valid && room && left <= CW'(WR);

  // ---- Compaction straight into the banks ----
  logic [WR-1:0]           bwe;
  logic [WR-1:0][RW-1:0]   bwaddr;
  logic [WR-1:0][IB_W-1:0] bwdata;
  for (genvar b = 0; b < WR; b++) begin : g_bank_wr
    logic [NP:0] sel;
    for (genvar p = 0; p <= NP; p++) begin : g_sel
      logic [CW-1:0] k;                 // position in this cycle's writes
      assign k = rank[p] - done_q;
      /* verilator lint_off CMPCONST */  // the straddler's rank is constant 0
      assign sel[p] = inst_v[p] && rank[p] >= done_q && k < CW'(WR)
                   && BW'(tail_q[BW-1:0] + BW'(k)) == BW'(b);
      /* verilator lint_on CMPCONST */
    end
    logic [IN_W-1:0] cand;
    always_comb begin
      cand = '0;
      for (int p = 0; p <= NP; p++) cand |= {IN_W{sel[p]}} & inst[p];
    end
    // The decode bits: a 32-bit instruction's from a decoder (its fields unused), a compressed
    // one's from its 16 bits (illegal: without C, reserved, or an FP load/store without D or with
    // the FP unit off; an exception also as C.EBREAK; never serialising)
    dec_t        qd;
    logic        q_ill32, q_illc, q_cfp, q_ill, q_exc, q_ser;
    logic [31:0] q_cx;
    tg_decode u_qdec (.pc_lo('0), .blk('0), .strad(1'b0), .insn(cand[31:0]), .link('0), .tgt('0),
                      .pre_ill(1'b0), .fault(1'b0), .fault_pf(1'b0), .fault_hi(1'b0),
                      .misa_m(dst.misa_m), .misa_b(dst.misa_b), .misa_a(dst.misa_a),
                      .misa_f(dst.misa_f), .misa_d(dst.misa_d), .fs(dst.fs), .frm(dst.frm),
                      .priv(dst.priv), .tvm(dst.tvm), .tw(dst.tw), .tsr(dst.tsr), .d(qd),
                      .ill_o(q_ill32));
    tg_rvc u_qrvc (.c(cand[15:0]), .has_d(EXT_FD && dst.misa_d), .insn(q_cx), .ill(q_illc));
    assign q_cfp = cand[1:0] != 2'b01 && cand[14:13] == 2'b01;
    always_comb begin
      if (cand[32]) begin                                  // compressed
        q_ill = !(EXT_C && dst.misa_c) || q_illc ||
                (q_cfp && !(EXT_FD && dst.misa_f && dst.fs != 2'd0 && dst.misa_d));
        q_exc = q_ill || cand[15:0] == 16'h9002;
        q_ser = 1'b0;
      end else begin
        q_ill = q_ill32;
        q_exc = qd.exc;
        q_ser = qd.serial;
      end
    end
    assign bwdata[b] = {q_ill, q_exc, q_ser, cand};
    logic unused_q;
    assign unused_q = ^{qd, q_cx};
    // Entry index tail + k; its row: (tail + k) / WR, where k = (b - tail) mod WR
    logic [QW-1:0] idx;
    assign idx = tail_q + QW'(BW'(BW'(b) - tail_q[BW-1:0]));
    assign bwaddr[b] = idx[QW-1:BW];
    logic unused;
    assign unused = ^idx[BW-1:0];   // equals b
    assign bwe[b] = blk_valid && room && |sel;
  end

  // ---- Banks ----
  logic [WR-1:0][RW-1:0]   braddr;
  logic [WR-1:0][IB_W-1:0] brdata;
  for (genvar b = 0; b < WR; b++) begin : g_bank
    logic [QW-1:0] idx;
    assign idx = head_q + QW'(BW'(BW'(b) - head_q[BW-1:0]));
    assign braddr[b] = idx[QW-1:BW];
    logic unused;
    assign unused = ^idx[BW-1:0];   // equals b
    logic [0:0][RW-1:0]   ra;
    logic [0:0][IB_W-1:0] rd;
    assign ra[0] = braddr[b];
    tg_ram_lut #(.DEPTH(ROWS), .WIDTH(IB_W), .NR(1)) u_ram (
      .clk, .we(bwe[b]), .waddr(bwaddr[b]), .wdata(bwdata[b]), .raddr(ra), .rdata(rd));
    assign brdata[b] = rd[0];
  end

  // ---- Reads: slot j takes entry head + j ----
  for (genvar j = 0; j < RD; j++) begin : g_rd
    logic [BW-1:0] b;
    assign b = BW'(head_q[BW-1:0] + BW'(j));
    assign out_insn[j]  = brdata[b];
    assign out_valid[j] = occ_q > (QW + 1)'(j);
  end

  // ---- State update ----
  always_ff @(posedge clk) begin
    if (rst || flush) begin
      occ_q    <= '0;
      head_q   <= '0;
      tail_q   <= '0;
      done_q   <= '0;
      half_v_q <= 1'b0;
    end else begin
      logic [QW:0] w;
      w = (blk_valid && room) ? (QW + 1)'(nwr) : '0;
      occ_q  <= occ_q + w - (QW + 1)'(take);
      head_q <= head_q + QW'(take);
      tail_q <= tail_q + QW'(w);
      if (blk_valid && room) begin
        if (blk_ready) begin
          done_q   <= '0;
          half_v_q <= carry_out;
        end else begin
          done_q   <= done_q + nwr;
        end
      end
    end
    if (blk_ready && carry_out) begin
      half_q       <= parcel[NP-1];
      half_marks_q <= marks[NP-1];
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && !flush) assert (int'(take) <= RD && (QW + 1)'(take) <= occ_q)
      else $error("tg_fetch_compact: take beyond the valid entries");
  end
`endif
endmodule
