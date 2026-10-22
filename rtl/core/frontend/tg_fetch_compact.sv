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
// With QUEUE_DECODE each entry also carries three decode bits, made as it is written (a decoder per
// bank): illegal, a decode-time exception, serialising. Decode's group and its decoders' field
// clearing read them instead of waiting for a decode of their own (timing: the queue's take loop,
// decode -> rename).
// The state they depend on (misa, mstatus.FS, frm, the mode, TVM/TW/TSR) changes only as a
// serialising instruction or a trap commits, and the flush that follows empties the queue, so
// they are what decode would find; decode checks them in simulation.
// Per thread (M7's step 5b, with hart 1: MT): each thread has a queue of DEPTH entries in the same banks, at
// {tid, row}, with its own pointers, count and straddler; a block is written into its thread's (blk_tid), with
// that hart's decode state; a redirect empties its thread's (flush_q, one bit a queue: two threads' redirects may come
// in one cycle). Decode reads one thread's queue a cycle
// (out_tid, registered): after decode takes from it, the other thread's if that one has instructions, and an empty
// queue is skipped (D7: the first-served thread alternates). Step 5d: decode reads only a thread whose RN register
// takes a group next cycle (acc_t, rename's), so it never waits on a register that holds a stalled group.
// Without MT the one queue of before, the running thread's.
module tg_fetch_compact
  import tg_pkg::*, tg_core_pkg::EXT_C, tg_core_pkg::EXT_FD, tg_core_pkg::dec_t,
         tg_core_pkg::dec_state_t, tg_core_pkg::QUEUE_DECODE, tg_core_pkg::HART1_ON, tg_core_pkg::RUN_TID;
#(
  parameter int WR    = 4,               // queue write ports = banks (power of two)
  parameter int RD    = DECODE_WIDTH,
  parameter int DEPTH = IBUF_ENTRIES,
  parameter int META_W = 8,              // per-instruction metadata from the front end
  localparam int NP   = FETCH_BYTES / 2,
  localparam int SW   = idx_w(NP),
  localparam int IN_W = 32 + 1 + SW + 3 + META_W,  // a candidate: insn, rvc, parcel, marks, metadata
  localparam int IB_W = IN_W + (QUEUE_DECODE ? 3 : 0),  // an entry: the decode bits, then the candidate
  localparam int QW   = idx_w(DEPTH),
  localparam int ROWS = DEPTH / WR,
  localparam int RW   = idx_w(ROWS),
  localparam int BW   = idx_w(WR),
  localparam int CW   = idx_w(NP + 2)
) (
  input  logic                    clk,
  input  logic                    rst,
  input  logic [NUM_THREADS-1:0]  flush_q,    // redirects: each empties its queue (bit 0 alone without MT)
  input  logic [NUM_THREADS-1:0]  drop_t,     // MT: a thread behind a serial uop at rename: its queue empties and
                                              // takes its blocks without writing them (its flush would drop them)
  input  logic [NUM_THREADS-1:0]  acc_t,      // MT (step 5d): a thread's RN register takes a group next cycle
  input  dec_state_t [NUM_THREADS-1:0] dst,   // the decoders' state, per hart (decode's)
  // Block from IF2
  input  logic                    blk_valid,
  input  tid_t                    blk_tid,
  input  logic [NP-1:0][15:0]     parcel,
  input  logic [NP-1:0]           start,
  input  logic [NP-1:0][2:0]      marks,      // {br, jal, jalr} per parcel
  input  logic                    carry_out,
  input  logic [META_W-1:0]       meta,       // e.g. FTQ index
  output logic                    blk_ready,  // the block is fully consumed this cycle
  // To decode: one thread's queue head
  output tid_t                    out_tid,
  output logic [RD-1:0]           out_valid,
  output logic [RD-1:0][IB_W-1:0] out_insn,
  input  logic [idx_w(RD + 1)-1:0] take,       // instructions decode takes this cycle (out_tid's)
  input  logic [idx_w(RD + 1)-1:0] take_t,     // ... if rename takes decode's group (tk), and if not: take is the
  input  logic [idx_w(RD + 1)-1:0] take_n,     // choice (asserted). The counts and the head run on both beside
  input  logic                     tk,         // rename's decision, which picks last (timing)
  output logic [NUM_THREADS-1:0][idx_w(DEPTH):0] occ_o   // MT (5e): each thread's entries, registered (fetch's room)
);
  localparam bit MT = HART1_ON && NUM_THREADS > 1;   // a queue per thread (two threads)
  localparam int NQ = MT ? 2 : 1;
  localparam int TW = MT ? 1 : 0;                    // the tid's bit in the banks' address
  // The threads: the block's, the reader's, the redirected; their queues (0 without MT)
  tid_t wt;
  logic wq, rq;
  logic rt_q;                                        // the thread decode reads (MT)
  // Each bank's read address takes its own copy of rt_q, and picks its own head and row from it (timing: on the
  // product chip, rt_q's fan-out of about 800, the head's pick and a bank's row index were 1.6 ns of wire before the
  // LUTRAM, at the head of the paths into rename's payload write, pay_wd_q). Kept, so that synthesis does not merge
  // the copies into rt_q
  (* keep = "true" *) logic [WR-1:0] rt_b_q;
  assign wt  = MT ? blk_tid : RUN_TID;
  assign wq  = MT && blk_tid[0];
  assign rq  = MT && rt_q;
  assign out_tid = MT ? tid_t'(rt_q) : RUN_TID;
  dec_state_t wdst;                                  // the writing hart's decode state
  assign wdst = dst[wt];
  // ---- Instruction candidates: position p (0..NP-1) and the held straddler (index NP) ----
  logic [NQ-1:0]         hv_q;                  // each thread's held straddler
  logic [NQ-1:0][15:0]   hp_q;
  logic [NQ-1:0][2:0]    hm_q;
  logic                  half_v_q;              // ... the block's thread's
  logic [15:0]           half_q;
  logic [2:0]            half_marks_q;
  assign half_v_q     = hv_q[wq];
  assign half_q       = hp_q[wq];
  assign half_marks_q = hm_q[wq];
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

  // ---- Queue state: per thread; done_q is the block's ----
  logic [NQ-1:0][QW:0]   occ_t_q;
  logic [NQ-1:0][QW-1:0] head_t_q, tail_t_q;
  logic [QW:0]   occ_q, rocc;                // the block's thread's count; the reader's
  logic [QW-1:0] tail_q;                     // the block's thread's tail
  logic [BW-1:0] head_q;                     // the reader's head's bank (the slots' rotation; each bank reads its own)
  assign occ_q  = occ_t_q[wq];
  always_comb for (int q = 0; q < NUM_THREADS; q++) occ_o[q] = (q < NQ) ? occ_t_q[q < NQ ? q : 0] : '0;
  assign tail_q = tail_t_q[wq];
  assign rocc   = occ_t_q[rq];
  assign head_q = head_t_q[rq][BW-1:0];
  logic [CW-1:0] done_q;                 // instructions of this block already written
  logic [CW-1:0] left, nwr;
  assign left = count - done_q;
  assign nwr  = (left > CW'(WR)) ? CW'(WR) : left;
  logic room;
  assign room = (QW + 1)'(DEPTH) - occ_q >= (QW + 1)'(nwr);
  logic [NQ-1:0] fq;                         // the queues that empty: a redirect's, or (MT) a dropped thread's
  for (genvar q = 0; q < NQ; q++) begin : g_fq
    assign fq[q] = flush_q[q] || (MT && drop_t[q]);
  end
  logic unused_fq;                           // (without MT the second thread's bits)
  assign unused_fq = ^{flush_q, drop_t, acc_t};
  assign blk_ready = blk_valid && ((MT && drop_t[wq]) || (room && left <= CW'(WR)));

  // ---- Compaction straight into the banks ----
  logic [WR-1:0]           bwe;
  logic [WR-1:0][RW+TW-1:0] bwaddr;
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
    if (QUEUE_DECODE) begin : g_qd
      // The decode bits: a 32-bit instruction's from a decoder (its fields unused), a compressed
      // one's from its 16 bits (illegal: without C, reserved, or an FP load/store without D or with
      // the FP unit off; an exception also as C.EBREAK; never serialising)
      dec_t        qd;
      logic        q_ill32, q_illc, q_cfp, q_ill, q_exc, q_ser;
      logic [31:0] q_cx;
      tg_decode u_qdec (.pc_lo('0), .blk('0), .strad(1'b0), .insn(cand[31:0]), .link('0), .tgt('0), .raw('0),
                        .pre_ill(1'b0), .fault(1'b0), .fault_pf(1'b0), .fault_hi(1'b0),
                        .misa_m(wdst.misa_m), .misa_b(wdst.misa_b), .misa_a(wdst.misa_a),
                        .misa_f(wdst.misa_f), .misa_d(wdst.misa_d), .fs(wdst.fs), .frm(wdst.frm),
                        .priv(wdst.priv), .tvm(wdst.tvm), .tw(wdst.tw), .tsr(wdst.tsr), .d(qd),
                        .ill_o(q_ill32));
      tg_rvc u_qrvc (.c(cand[15:0]), .has_d(EXT_FD && wdst.misa_d), .insn(q_cx), .ill(q_illc));
      assign q_cfp = cand[1:0] != 2'b01 && cand[14:13] == 2'b01;
      always_comb begin
        if (cand[32]) begin                                // compressed
          q_ill = !(EXT_C && wdst.misa_c) || q_illc ||
                  (q_cfp && !(EXT_FD && wdst.misa_f && wdst.fs != 2'd0 && wdst.misa_d));
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
    end else begin : g_nqd
      assign bwdata[b] = cand;
    end
    // Entry index tail + k; its row: (tail + k) / WR, where k = (b - tail) mod WR
    logic [QW-1:0] idx;
    assign idx = tail_q + QW'(BW'(BW'(b) - tail_q[BW-1:0]));
    assign bwaddr[b] = (RW + TW)'({wq, idx[QW-1:BW]});
    logic unused;
    assign unused = ^idx[BW-1:0];   // equals b
    assign bwe[b] = blk_valid && room && |sel;
  end

  if (!QUEUE_DECODE) begin : g_nqd_dst
    logic unused_dst;                     // the decoders' state, for the decode bits only
    assign unused_dst = ^{dst, wdst};
  end

  // ---- Banks ----
  logic [WR-1:0][RW+TW-1:0] braddr;
  logic [WR-1:0][IB_W-1:0] brdata;
  for (genvar b = 0; b < WR; b++) begin : g_bank
    logic [QW-1:0] idx;
    logic          rqb;                // the reader, from this bank's copy
    logic [QW-1:0] hb;
    assign rqb = MT && rt_b_q[b];
    assign hb  = head_t_q[rqb];
    assign idx = hb + QW'(BW'(BW'(b) - hb[BW-1:0]));
    assign braddr[b] = (RW + TW)'({rqb, idx[QW-1:BW]});
    logic unused;
    assign unused = ^idx[BW-1:0];   // equals b
    logic [0:0][RW+TW-1:0] ra;
    logic [0:0][IB_W-1:0] rd;
    assign ra[0] = braddr[b];
    tg_ram_lut #(.DEPTH(ROWS * NQ), .WIDTH(IB_W), .NR(1)) u_ram (
      .clk, .we(bwe[b]), .waddr(bwaddr[b]), .wdata(bwdata[b]), .raddr(ra), .rdata(rd));
    assign brdata[b] = rd[0];
  end

  // ---- Reads: slot j takes entry head + j ----
  for (genvar j = 0; j < RD; j++) begin : g_rd
    logic [BW-1:0] b;
    assign b = BW'(head_q[BW-1:0] + BW'(j));
    assign out_insn[j]  = brdata[b];
    assign out_valid[j] = rocc > (QW + 1)'(j) && !(MT && drop_t[rq]);
  end

  // ---- State update ----
  // The next counts (for decode's next thread): the block's thread's gains this cycle's writes, the reader's loses
  // decode's take, and a redirected thread's queue empties
  logic [QW:0] w;
  assign w = (blk_valid && room) ? (QW + 1)'(nwr) : '0;
  logic [NQ-1:0][QW:0] occ_n;
  logic ro;                                          // the other thread's queue (MT)
  assign ro = MT && !rt_q;
  // The reader's next count and head after decode's take, with rename taking decode's group and without, then picked
  // by rename's decision (tk, de_take): the same values. Kept, so that synthesis does not share one subtractor behind
  // a select by tk (timing: de_take, the end of rename's checks, reached the counts through the subtraction; the
  // product chip's occ_t_q family, -1.756 ns from the issue queues' dep_q)
  (* keep = "true" *) logic [NQ-1:0][QW:0]   occ_tt, occ_tn;
  (* keep = "true" *) logic [NQ-1:0][QW-1:0] head_tt, head_tn;
  always_comb
    for (int q = 0; q < NQ; q++) begin
      occ_tt[q]  = occ_t_q[q] + ((wq == 1'(q)) ? w : '0) - ((rq == 1'(q)) ? (QW + 1)'(take_t) : '0);
      occ_tn[q]  = occ_t_q[q] + ((wq == 1'(q)) ? w : '0) - ((rq == 1'(q)) ? (QW + 1)'(take_n) : '0);
      head_tt[q] = head_t_q[q] + QW'(take_t);
      head_tn[q] = head_t_q[q] + QW'(take_n);
      occ_n[q]   = fq[q] ? '0 : tk ? occ_tt[q] : occ_tn[q];
    end
  // decode's next thread (MT): the other one after a take from this one, or when this one's queue is empty, if the
  // other's holds instructions; only one whose RN register takes a group next cycle (step 5d), so the other one also
  // when this one's register will not. Both counts are read without decode's take, which waits for rename's
  // decision: the other queue's next count is its count with this cycle's writes (decode takes only from this one),
  // and "this one empties" needs no take either: with a take the other one is due anyway, and without one the next
  // count is the count with the writes (or 0 when the queue empties). So the take reaches rt_q through an OR of its
  // bits, not through the counts' arithmetic (timing: the product chip's worst paths ended at rt_q, -1.108 ns from the
  // LQ's head and -1.025 ns from DS, both through rename's de_take, then 2.7 ns of the counts)
  logic [QW:0] occ_wr, occ_wo;                       // the reader's and the other's counts with this cycle's writes
  logic        rt_n;
  assign occ_wr = occ_t_q[rq] + ((wq == rq) ? w : '0);
  assign occ_wo = occ_t_q[ro] + ((wq == ro) ? w : '0);
  logic        tz;                                  // decode takes from the reader: by rename's decision, picked last
  assign tz     = tk ? take_t != '0 : take_n != '0;
  assign rt_n   = (MT && !fq[ro] && occ_wo != '0 && acc_t[ro] && (tz || fq[rq] || occ_wr == '0 || !acc_t[rq]))
                  ? ro : rt_q;
  always_ff @(posedge clk) begin
    for (int q = 0; q < NQ; q++) begin
      if (rst || fq[q]) begin
        occ_t_q[q]  <= '0;
        head_t_q[q] <= '0;
        tail_t_q[q] <= '0;
        hv_q[q]     <= 1'b0;
      end else begin
        occ_t_q[q] <= occ_n[q];
        if (rq == 1'(q)) head_t_q[q] <= tk ? head_tt[q] : head_tn[q];
        if (wq == 1'(q)) begin
          tail_t_q[q] <= tail_t_q[q] + QW'(w);
          if (blk_ready) hv_q[q] <= carry_out;
        end
      end
    end
    // the block's progress: reset by its thread's redirect (fetch drops the block), else as the block is written
    if (rst || fq[wq]) begin
      done_q <= '0;
    end else if (blk_valid && room) begin
      if (blk_ready) done_q <= '0;
      else           done_q <= done_q + nwr;
    end
    if (blk_ready && carry_out) begin
      hp_q[wq] <= parcel[NP-1];
      hm_q[wq] <= marks[NP-1];
    end
    rt_q   <= rst ? (MT && RUN_TID[0]) : rt_n;
    rt_b_q <= rst ? {WR{MT && RUN_TID[0]}} : {WR{rt_n}};
  end

`ifndef SYNTHESIS
  logic rt_rs;                                       // (the copies are checked from the first reset on)
  initial rt_rs = 1'b0;
  always @(posedge clk) if (rst) rt_rs <= 1'b1;
  always_ff @(posedge clk)
    if (rt_rs && !rst) assert (rt_b_q == {WR{rt_q}}) else $error("tg_fetch_compact: a bank's copy of rt_q differs from it");
  always_ff @(posedge clk) begin
    if (!rst && !fq[rq]) assert (int'(take) <= RD && (QW + 1)'(take) <= rocc)
      else $error("tg_fetch_compact: take beyond the valid entries");
    if (!rst) assert (take == (tk ? take_t : take_n)) else $error("tg_fetch_compact: decode's take is not its choice by tk");
    // the switch as it was written before, from the next counts
    if (!rst) assert (rt_n == ((MT && occ_n[ro] != '0 && acc_t[ro] && (take != '0 || occ_n[rq] == '0 || !acc_t[rq])) ? ro
                                                                                                                 : rt_q))
      else $error("tg_fetch_compact: the read thread's switch differs from the next counts'");
  end
  // (MT) decode slots left empty while the other thread's queue held instructions (the one-thread-a-group rule), and of
  // them those in cycles the read thread had under a group; on stderr at the end with hart 1
  longint unsigned n_es, n_esu;
  always_ff @(posedge clk)
    if (rst) begin
      n_es  <= 0;
      n_esu <= 0;
    end else if (MT && occ_t_q[ro] != '0 && !fq[ro]) begin
      n_es <= n_es + longint'(RD) - longint'(take);
      if (rocc < (QW + 1)'(RD)) n_esu <= n_esu + longint'(RD) - longint'(take);
    end
  final if (MT) $fwrite(32'h8000_0002, "TG-STALL2 %m: decode left %0d slots empty while the other thread's queue held instructions (%0d with under a group in the read thread's)\n",
                        n_es, n_esu);
`endif
endmodule
