// Decode stage (DE, docs/spec/core-pipeline.md §3.4, §4): decodes the DECODE_WIDTH instructions
// at the instruction-queue head and forms the group rename takes, all or nothing.
// Group rules: a serialising instruction or one with a decode-time exception goes alone, in
// slot 0; a decode-time redirect ends the group after its instruction.
// Redirects: JAL not predicted to its target, a branch predicted taken to a wrong target, a
// return not predicted to the return-address stack's top (RAS_ON; when the stack is not
// empty), or a prediction on something that is not a branch or jump. The redirect is registered
// (dred) and flushes the front end in the next cycle; decode takes nothing in that cycle.
// The return-address stack (tg_ras) moves with the groups rename takes: a group holds at most one
// of its operations (a later one waits for the next group), which reads the stack's top as it is.
// Timing: whether the predicted target is the branch's is checked without a carry chain: the
// target is block address + offset + immediate, and "a + b + c == k" holds when every bit of
// the carry-save sum matches the carry k needs there (Cortadella and Llaberia, IEEE Trans.
// Computers, 1992). The sums themselves (the targets, the next PC) feed only registers.
// The check needs neither the RVC expander nor the decoder's class and immediate: the queue
// brings the instruction's pre-decode marks (decode's class unless decode raises an exception,
// which the check excludes), and the offset comes from the raw encoding.
// With QUEUE_DECODE the group does not wait for a decoder either: whether an instruction raises an
// exception or goes alone comes with it from the queue, which decodes those bits as it writes the
// instruction (tg_fetch_compact), and the decoders clear their fields by the queue's illegal bit
// too. Without it a second decoder (u_decr) and a 16-bit rule give them from the raw encoding.
// DE_STAGE (DR-140 #8; off in both profiles, and lint-only on top of the default until the user
// turns it on): decode takes a stage of its own.
// DE1 decodes the queue head into registers, as many as there is room for (the slots DE2 does not
// hand on move to the front); DE2 forms the group and checks the predictions from them. The
// queue's take then counts a group as ending only at instructions that go alone: those after a
// redirect in it are dropped, as the redirect drops what DE1 holds. Every redirect costs one more
// front-end cycle.
module tg_decode_stage
  import tg_pkg::*, tg_core_pkg::*;
#(
  localparam int W   = DECODE_WIDTH,
  localparam int TKW = idx_w(W + 1)
) (
  input  logic                clk,
  input  logic                rst,
  input  logic                flush,
  input  logic                misa_m,
  input  logic                misa_b,
  input  logic                misa_c,
  input  logic                misa_a,
  input  logic                misa_f,
  input  logic                misa_d,
  input  logic [1:0]          fs,
  input  logic [2:0]          frm,
  input  priv_e               priv,
  input  logic                tvm,
  input  logic                tw,
  input  logic                tsr,
  // Instruction queue
  input  logic [W-1:0]        iq_valid,
  input  fe_insn_t [W-1:0]    iq_insn,
  output logic [TKW-1:0]      iq_take,
  // To rename
  output logic [W-1:0]        de_valid,
  output uop_t [W-1:0]        de_uop,
  input  logic                de_take,
  // Decode-time redirect (registered)
  output logic                dred,
  output logic [63:0]         dred_pc,
  output logic [FTQW-1:0]     dred_ftq,     // the redirecting instruction's FTQ entry and last slot,
  output logic [SLOT_W-1:0]   dred_slot,    // for the history's repair (TAGE_ON)
  output logic [1:0]          dred_rop,     // ... and its own return-address-stack operation and link,
  output logic [38:1]         dred_rlink,   // for the stack's repair (RAS_FE)
  // Return-address stack (tg_ras; RAS_ON): its top, and the taken group's operation
  input  logic                ras_v,
  input  logic [38:1]         ras_top,
  output logic                ras_push,
  output logic                ras_pop,
  output logic [38:1]         ras_link
);
  // The offset of a branch (jal = 0) or JAL (jal = 1), bits 20:0 with the sign at 20, from the raw
  // encoding: B and J types, or RVC's CB (c.beqz, c.bnez) and CJ (c.j); as decode adds it to the PC
  function automatic logic [20:0] bimm_of(input logic [31:0] x, input logic jal);
    if (x[1:0] == 2'b11)
      return jal ? {x[31], x[19:12], x[20], x[30:21], 1'b0}
                 : {{8{x[31]}}, x[31], x[7], x[30:25], x[11:8], 1'b0};
    else
      return jal ? {{9{x[12]}}, x[12], x[8], x[10:9], x[6], x[7], x[2], x[11], x[5:3], 1'b0}
                 : {{12{x[12]}}, x[12], x[6:5], x[2], x[11:10], x[4:3], 1'b0};
  endfunction

  // a + b + c == k, carry-free
  function automatic logic eq_add3(input logic [63:0] a, input logic [63:0] b, input logic [63:0] c,
                                   input logic [63:0] k);
    logic [63:0] s, y, cin;
    s   = a ^ b ^ c;
    y   = ((a & b) | (a & c) | (b & c)) << 1;
    cin = {(s[62:0] & y[62:0]) | ((s[62:0] | y[62:0]) & ~k[62:0]), 1'b0};
    return (s ^ y ^ k) == cin;
  endfunction

  dec_t [W-1:0]        d;
`ifndef SYNTHESIS
  logic rs_seen_q;                              // reset has been seen (the checks wait for it)
  initial rs_seen_q = 1'b0;
  always @(posedge clk) if (rst) rs_seen_q <= 1'b1;
`endif
  logic [W-1:0][63:0]  seq_d, tgt_d;      // per queue slot: pc + 2 or 4, pc + the offset
  logic [W-1:0]        exc_f, alone_f;    // d.exc and d.serial || d.exc, from the raw encoding
  logic [W-1:0]        redir;
  logic [W-1:0][63:0]  npc;
  logic [W-1:0]        dfix;
  logic [W-1:0][1:0]   rop;               // the return-address stack's operation: {push, pop}
  logic [63:0]         rtgt;              // the stack's top as a PC
  assign rtgt = {{25{ras_top[38]}}, ras_top, 1'b0};
  for (genvar j = 0; j < W; j++) begin : g_dec
    // Compressed instructions are expanded first; without C they are illegal (tval is the
    // 16-bit encoding, which the ROB keeps).
    logic [31:0] xinsn;
    logic        rvc_ill;
    tg_rvc u_rvc (.c(iq_insn[j].insn[15:0]), .has_d(EXT_FD && misa_d), .insn(xinsn), .ill(rvc_ill));
    logic [31:0] xi;
    assign xi = iq_insn[j].rvc ? xinsn : iq_insn[j].insn;
    logic pre_ill;
    assign pre_ill = iq_insn[j].rvc && (!(EXT_C && misa_c) || rvc_ill);
    // The next sequential PC (the link value) and the target of a JAL or branch: one add each,
    // for the decoder's uop and the checks (the offset from the raw encoding, by the JAL mark)
    logic [63:0] pbase, poff, imm;
    logic [20:0] bimm;
    assign pbase   = {iq_insn[j].blk, 4'b0};
    assign poff    = iq_insn[j].strad ? 64'hFFFF_FFFF_FFFF_FFFE : {60'b0, iq_insn[j].pc[3:0]};
    assign bimm    = bimm_of(iq_insn[j].insn, iq_insn[j].marks[1]);
    assign imm     = {{43{bimm[20]}}, bimm};
    assign seq_d[j] = pbase + poff + (iq_insn[j].rvc ? 64'd2 : 64'd4);
    assign tgt_d[j] = pbase + poff + imm;
    logic dec_ill;                              // the decoder's own illegal decision (checked)
    tg_decode #(.ILL_Q(QUEUE_DECODE)) u_dec (
                     .pc_lo(iq_insn[j].pc[3:0]), .blk(iq_insn[j].blk), .strad(iq_insn[j].strad), .insn(xi),
                     .link(seq_d[j]), .tgt(tgt_d[j]), .raw(iq_insn[j].insn),
                     .pre_ill,
                     .fault(iq_insn[j].fault), .fault_pf(iq_insn[j].fault_pf), .fault_hi(iq_insn[j].fault_hi), .misa_m, .misa_b, .misa_a, .misa_f, .misa_d, .fs, .frm, .priv, .tvm, .tw, .tsr,
                     .ill_q(iq_insn[j].q_ill), .d(d[j]), .ill_o(dec_ill));
    if (QUEUE_DECODE) begin : g_qd
      // Exception and going alone: the queue's bits, with a fetch fault from the entry's own flag
      assign exc_f[j]   = iq_insn[j].fault || iq_insn[j].q_exc;
      assign alone_f[j] = exc_f[j] || iq_insn[j].q_ser;
`ifndef SYNTHESIS
      // The queue's illegal bit is the decoder's own decision (the fault overrides both): from the
      // first reset on, as the queue's entries hold nothing written before it, and outside the flush
      // cycle, where entries written before a state change (a serialising instruction or a trap just
      // committed) wait to be dropped and decode takes nothing
      always_ff @(posedge clk) begin
        if (rs_seen_q && !rst && !flush && iq_valid[j] && !iq_insn[j].fault)
          assert (iq_insn[j].q_ill == dec_ill) else $error("tg_decode_stage: the queue's illegal bit differs from decode's");
      end
`endif
    end else begin : g_rd
      // Exception and going alone from the raw encoding. A compressed instruction raises one only when
      // it is illegal as such (pre_ill), is C.EBREAK, or is an FP load/store (C.FLD, C.FSD, C.FLDSP,
      // C.FSDSP: their D-less forms are pre_ill) with the FP unit off; none is serialising.
      dec_t dr;
      logic dr_ill;
      tg_decode u_decr (.pc_lo(iq_insn[j].pc[3:0]), .blk(iq_insn[j].blk), .strad(iq_insn[j].strad),
                        .insn(iq_insn[j].insn), .link('0), .tgt('0), .raw('0), .pre_ill(1'b0),
                        .fault(iq_insn[j].fault),
                        .fault_pf(iq_insn[j].fault_pf), .fault_hi(iq_insn[j].fault_hi), .misa_m, .misa_b,
                        .misa_a, .misa_f, .misa_d, .fs, .frm, .priv, .tvm, .tw, .tsr, .d(dr), .ill_o(dr_ill));
      logic [15:0] c16;
      logic        c_exc;
      assign c16   = iq_insn[j].insn[15:0];
      assign c_exc = iq_insn[j].fault || pre_ill || c16 == 16'h9002 ||
                     (c16[1:0] != 2'b01 && c16[14:13] == 2'b01 &&
                      !(EXT_FD && misa_f && fs != 2'd0 && misa_d));
      assign exc_f[j]   = iq_insn[j].rvc ? c_exc : dr.exc;
      assign alone_f[j] = iq_insn[j].rvc ? c_exc : (dr.exc || dr.serial);
      logic unused_dr;                            // only exc and serial are kept; no queue bits
      assign unused_dr = ^{dr, dr_ill, dec_ill, iq_insn[j].q_exc, iq_insn[j].q_ser};
    end
`ifndef SYNTHESIS
    // The raw encoding's offset is the expanded instruction's (the target decode used to add)
    logic [63:0] xtgt;
    assign xtgt = pbase + poff + ((d[j].br_kind == BR_JAL)
                    ? {{43{xi[31]}}, xi[31], xi[19:12], xi[20], xi[30:21], 1'b0}
                    : {{51{xi[31]}}, xi[31], xi[7], xi[30:25], xi[11:8], 1'b0});
    always_ff @(posedge clk) begin
      if (rs_seen_q && !rst && iq_valid[j])
        assert (exc_f[j] == d[j].exc && alone_f[j] == (d[j].exc || d[j].serial))
          else $error("tg_decode_stage: the raw encoding's exception or serialisation differs from decode's");
      if (!rst && iq_valid[j] && !d[j].exc && d[j].cls == C_BR && d[j].br_kind != BR_JALR)
        assert (tgt_d[j] == xtgt) else $error("tg_decode_stage: the raw offset gives another target than decode's");
      // An AUIPC is never compressed: its raw immediate is the decoded one
      if (!rst && iq_valid[j] && xi[6:0] == 7'b0010111)
        assert (!iq_insn[j].rvc && iq_insn[j].insn[31:12] == xi[31:12])
          else $error("tg_decode_stage: an AUIPC's raw immediate differs from its decoded one");
    end
`endif
  end

  // ================= The checks and the group: DE, or DE2 with DE_STAGE =================
  // Their inputs: the queue head, or with DE_STAGE the DE1 registers (g_de1 / g_de2, below)
  logic [W-1:0]     xv, xe, xa;
  fe_insn_t [W-1:0] xq;
  dec_t [W-1:0]     xd;
  logic [W-1:0][63:0] xseq, xtgt;
  for (genvar j = 0; j < W; j++) begin : g_chk
    logic [63:0] seq, pbase, poff, imm, tgt;
    logic        pt, hit, mbr, mjal, mjalr;
    logic [63:0] ptg;
    assign pbase = {xq[j].blk, 4'b0};
    assign poff  = xq[j].strad ? 64'hFFFF_FFFF_FFFF_FFFE : {60'b0, xq[j].pc[3:0]};
    assign seq   = xseq[j];
    assign pt    = xq[j].pred_taken;
    // a branch or JAL the front end took to its own target (TAGE_ON) carries no target: it is tgt
    assign ptg   = xq[j].pred_tsrc ? xtgt[j] : xq[j].pred_target;
    // the class from the queue's pre-decode marks, the offset from the raw encoding
    assign {mbr, mjal, mjalr} = xq[j].marks;
    logic [20:0] bimm;
    assign bimm  = bimm_of(xq[j].insn, mjal);
    assign imm   = {{43{bimm[20]}}, bimm};
    assign tgt   = xtgt[j];                          // d.br_target for a branch or JAL
    assign hit   = xq[j].pred_tsrc || eq_add3(pbase, poff, imm, ptg);   // ptg == tgt
    // The stack's operation from the raw encoding and the marks, like the class (timing: no RVC
    // expander or decoder before the group's count, the queue's take and the stack's pointer): a JAL
    // or JALR writing a link pushes, a JALR reading one pops unless it writes the same one; C.JALR
    // links x1, C.JR and C.J none. It is ras_op of decode's result wherever decode raises no
    // exception (asserted), which the gate excludes as ras_op does
    logic [1:0] rop_x;
    always_comb begin
      logic rdl, rsl;
      rdl   = xq[j].insn[11:7] == 5'd1 || xq[j].insn[11:7] == 5'd5;
      rsl   = (xq[j].rvc ? xq[j].insn[11:7] : xq[j].insn[19:15]) == 5'd1 ||
              (xq[j].rvc ? xq[j].insn[11:7] : xq[j].insn[19:15]) == 5'd5;
      rop_x = 2'b00;
      if (xq[j].rvc) begin
        if (mjalr) rop_x = {xq[j].insn[12], rsl && !(xq[j].insn[12] && xq[j].insn[11:7] == 5'd1)};
      end else if (mjal) begin
        rop_x = {rdl, 1'b0};
      end else if (mjalr) begin
        rop_x = {rdl, rsl && !(rdl && xq[j].insn[11:7] == xq[j].insn[19:15])};
      end
    end
    assign rop[j] = (RAS_DEC && !xe[j]) ? rop_x : 2'b00;   // (RAS_FE: fetch predicts returns)
`ifndef SYNTHESIS
    always_ff @(posedge clk)
      if (rs_seen_q && !rst && xv[j] && RAS_DEC)
        assert (rop[j] == ras_op(xd[j])) else $error("tg_decode_stage: the raw stack operation differs from decode's");
`endif
    always_comb begin
      npc[j]   = pt ? ptg : seq;
      redir[j] = 1'b0;
      dfix[j]  = 1'b0;
      if (!xe[j]) begin
        if (mjal) begin
          if (!pt || !hit) begin
            redir[j] = 1'b1; dfix[j] = 1'b1; npc[j] = tgt;
          end
        end else if (mbr) begin
          if (pt && !hit) begin
            redir[j] = 1'b1; dfix[j] = 1'b1; npc[j] = tgt;
          end
        end else if (mjalr && rop[j][0] && ras_v) begin
          // a return: the stack's top, unless the front end already followed it
          if (!pt || ptg != rtgt) begin
            redir[j] = 1'b1; dfix[j] = 1'b1; npc[j] = rtgt;
          end
        end else if (!mjalr && pt) begin
          redir[j] = 1'b1; dfix[j] = 1'b1; npc[j] = seq;
        end
      end
    end
`ifndef SYNTHESIS
    // The marks and the offset are decode's class and target wherever the check uses them
    always_ff @(posedge clk) begin
      if (!rst && xv[j] && !xd[j].exc) begin
        assert (mjal == (xd[j].cls == C_BR && xd[j].br_kind == BR_JAL) &&
                mbr == (xd[j].cls == C_BR && xd[j].br_kind == BR_COND) &&
                mjalr == (xd[j].cls == C_BR && xd[j].br_kind == BR_JALR))
          else $error("tg_decode_stage: pre-decode marks differ from decode's class");
      end
    end
`endif
  end

  // Group: a prefix of the checks' inputs, with at most one return-address-stack operation
  logic [TKW-1:0] n;
  always_comb begin
    logic stop, rs;
    stop = 1'b0;
    rs = 1'b0;
    n = '0;
    for (int j = 0; j < W; j++) begin
      if (!stop) begin
        if (!xv[j]) stop = 1'b1;
        else if (xa[j] && j > 0) stop = 1'b1;
        else if (rs && |rop[j]) stop = 1'b1;
        else begin
          n = TKW'(j + 1);
          if (|rop[j]) rs = 1'b1;
          if (xa[j] || redir[j]) stop = 1'b1;
        end
      end
    end
    if (dred || flush) n = '0;
  end
  // The taken group's stack operation (at most one slot has one)
  always_comb begin
    ras_push = 1'b0;
    ras_pop  = 1'b0;
    ras_link = '0;
    for (int j = 0; j < W; j++) begin
      if (de_take && TKW'(j) < n && |rop[j]) begin
        ras_push = rop[j][1];
        ras_pop  = rop[j][0];
        ras_link = xseq[j][38:1];
      end
    end
  end

  for (genvar j = 0; j < W; j++) begin : g_out
    assign de_valid[j] = TKW'(j) < n;
    always_comb begin
      de_uop[j]          = '0;
      de_uop[j].pc       = xq[j].pc;
      de_uop[j].insn     = xq[j].insn;
      de_uop[j].rvc      = xq[j].rvc;
      de_uop[j].pred_npc = npc[j];
      de_uop[j].ubtb_hit = xq[j].ubtb_hit;
      de_uop[j].ubtb_way = xq[j].ubtb_way;
      de_uop[j].dfix     = dfix[j];
      de_uop[j].ptk      = xq[j].pred_taken;
      de_uop[j].ftq      = xq[j].ftq;
      de_uop[j].tid      = xq[j].tid;
      de_uop[j].d        = xd[j];
    end
  end

  // ================= One decode stage, or two (DR-140 #8) =================
  if (DE_STAGE) begin : g_de2
    // DE1's registers (a prefix is valid)
    logic [W-1:0]     v1_q, e1_q, a1_q;
    fe_insn_t [W-1:0] i1_q;
    dec_t [W-1:0]     d1_q;
    logic [W-1:0][63:0] s1_q, t1_q;
    assign xv = v1_q;
    assign xe = e1_q;
    assign xa = a1_q;
    assign xq = i1_q;
    assign xd = d1_q;
    assign xseq = s1_q;
    assign xtgt = t1_q;
    // The queue's count of the group: the same without the redirects
    logic [TKW-1:0] nq;
    always_comb begin
      logic stopq, rsq;
      stopq = 1'b0;
      rsq = 1'b0;
      nq = '0;
      for (int j = 0; j < W; j++) begin
        if (!stopq) begin
          if (!v1_q[j]) stopq = 1'b1;
          else if (a1_q[j] && j > 0) stopq = 1'b1;
          else if (rsq && |rop[j]) stopq = 1'b1;
          else begin
            nq = TKW'(j + 1);
            if (|rop[j]) rsq = 1'b1;
            if (a1_q[j]) stopq = 1'b1;
          end
        end
      end
      if (dred || flush) nq = '0;
    end
    // DE2 hands on `used` slots; the `left` after them move to the front; the queue fills the rest
    int used, left, acc;
    always_comb begin
      int cnt1, iqn;
      cnt1 = 0;
      iqn  = 0;
      for (int j = 0; j < W; j++) begin
        cnt1 += int'(v1_q[j]);
        iqn  += int'(iq_valid[j]);
      end
      used = de_take ? int'(nq) : 0;
      left = cnt1 - used;
      acc  = (dred || flush) ? 0 : ((iqn < W - left) ? iqn : W - left);
    end
    assign iq_take = TKW'(acc);
    always_ff @(posedge clk) begin
      if (rst || flush || dred) begin
        v1_q <= '0;
      end else begin
        for (int k = 0; k < W; k++) begin
          v1_q[k] <= 1'b0;
          for (int s = 0; s < W; s++) begin
            if (k < left && s == k + used) begin                 // kept: slot s moves to k
              v1_q[k] <= 1'b1;
              i1_q[k] <= i1_q[s];
              d1_q[k] <= d1_q[s];
              e1_q[k] <= e1_q[s];
              a1_q[k] <= a1_q[s];
              s1_q[k] <= s1_q[s];
              t1_q[k] <= t1_q[s];
            end
            if (k >= left && s == k - left && s < acc) begin     // new: queue entry s
              v1_q[k] <= 1'b1;
              i1_q[k] <= iq_insn[s];
              d1_q[k] <= d[s];
              e1_q[k] <= exc_f[s];
              a1_q[k] <= alone_f[s];
              s1_q[k] <= seq_d[s];
              t1_q[k] <= tgt_d[s];
            end
          end
        end
      end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (!rst)
        for (int j = 1; j < W; j++)
          assert (!v1_q[j] || v1_q[j-1]) else $error("tg_decode_stage: DE1's valid slots are not a prefix");
    end
`endif
  end else begin : g_de1
    assign xv = iq_valid;
    assign xe = exc_f;
    assign xa = alone_f;
    assign xq = iq_insn;
    assign xd = d;
    assign xseq = seq_d;
    assign xtgt = tgt_d;
    assign iq_take = de_take ? n : '0;
  end

  // The last instruction taken redirects: flush the front end next cycle
  always_ff @(posedge clk) begin
    if (rst || flush) begin
      dred <= 1'b0;
    end else begin
      dred <= 1'b0;
      for (int j = 0; j < W; j++) begin
        if (de_take && n == TKW'(j + 1) && redir[j]) begin
          dred      <= 1'b1;
          dred_pc   <= npc[j];
          dred_ftq  <= xq[j].ftq;
          dred_slot <= xq[j].pc[SLOT_W:1] + SLOT_W'(!xq[j].rvc);
          // (RAS_FE: a call or return fetch could not see, as one that straddles into its block)
          dred_rop   <= RAS_FE ? ras_op(xd[j]) : 2'b00;
          dred_rlink <= xseq[j][38:1];
        end
      end
    end
  end
endmodule
