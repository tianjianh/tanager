// Decode stage (DE, docs/spec/core-pipeline.md §3.4, §4): decodes the DECODE_WIDTH instructions
// at the instruction-queue head and forms the group rename takes, all or nothing.
// Group rules: a serialising instruction or one with a decode-time exception goes alone, in
// slot 0; a decode-time redirect ends the group after its instruction.
// Redirects: JAL not predicted to its target, a branch predicted taken to a wrong target, or a
// prediction on something that is not a branch or jump. The redirect is registered (dred) and
// flushes the front end in the next cycle; decode takes nothing in that cycle.
// Timing: whether the predicted target is the branch's is checked without a carry chain: the
// target is block address + offset + immediate, and "a + b + c == k" holds when every bit of
// the carry-save sum matches the carry k needs there (Cortadella and Llaberia, IEEE Trans.
// Computers, 1992). The sums themselves (the targets, the next PC) feed only registers.
// The check needs neither the RVC expander nor the decoder's class and immediate: the queue
// brings the instruction's pre-decode marks (decode's class unless decode raises an exception,
// which the check excludes), and the offset comes from the raw encoding.
// Nor does the group wait for the expander: whether an instruction raises an exception or goes
// alone comes from the raw encoding too, from a second decoder (only these outputs are kept) for a
// 32-bit instruction, and from its 16 bits for a compressed one.
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
  output logic [63:0]         dred_pc
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
  logic [W-1:0]        exc_f, alone_f;    // d.exc and d.serial || d.exc, from the raw encoding
  logic [W-1:0]        redir;
  logic [W-1:0][63:0]  npc;
  logic [W-1:0]        dfix;
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
    tg_decode u_dec (.pc_lo(iq_insn[j].pc[3:0]), .blk(iq_insn[j].blk), .strad(iq_insn[j].strad), .insn(xi),
                     .len2(iq_insn[j].rvc),
                     .pre_ill,
                     .fault(iq_insn[j].fault), .fault_pf(iq_insn[j].fault_pf), .fault_hi(iq_insn[j].fault_hi), .misa_m, .misa_b, .misa_a, .misa_f, .misa_d, .fs, .frm, .priv, .tvm, .tw, .tsr, .d(d[j]));
    // Exception and going alone from the raw encoding. A compressed instruction raises one only when
    // it is illegal as such (pre_ill), is C.EBREAK, or is an FP load/store (C.FLD, C.FSD, C.FLDSP,
    // C.FSDSP: their D-less forms are pre_ill) with the FP unit off; none is serialising.
    dec_t dr;
    tg_decode u_decr (.pc_lo(iq_insn[j].pc[3:0]), .blk(iq_insn[j].blk), .strad(iq_insn[j].strad),
                      .insn(iq_insn[j].insn), .len2(1'b0), .pre_ill(1'b0), .fault(iq_insn[j].fault),
                      .fault_pf(iq_insn[j].fault_pf), .fault_hi(iq_insn[j].fault_hi), .misa_m, .misa_b,
                      .misa_a, .misa_f, .misa_d, .fs, .frm, .priv, .tvm, .tw, .tsr, .d(dr));
    logic [15:0] c16;
    logic        c_exc;
    assign c16   = iq_insn[j].insn[15:0];
    assign c_exc = iq_insn[j].fault || pre_ill || c16 == 16'h9002 ||
                   (c16[1:0] != 2'b01 && c16[14:13] == 2'b01 &&
                    !(EXT_FD && misa_f && fs != 2'd0 && misa_d));
    assign exc_f[j]   = iq_insn[j].rvc ? c_exc : dr.exc;
    assign alone_f[j] = iq_insn[j].rvc ? c_exc : (dr.exc || dr.serial);
    logic unused_dr;
    assign unused_dr = ^dr;                     // only exc and serial are kept
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (!rst && iq_valid[j])
        assert (exc_f[j] == d[j].exc && alone_f[j] == (d[j].exc || d[j].serial))
          else $error("tg_decode_stage: the raw encoding's exception or serialisation differs from decode's");
    end
`endif
  end

  // ================= The checks and the group: DE, or DE2 with DE_STAGE =================
  // Their inputs: the queue head, or with DE_STAGE the DE1 registers (g_de1 / g_de2, below)
  logic [W-1:0]     xv, xe, xa;
  fe_insn_t [W-1:0] xq;
  dec_t [W-1:0]     xd;
  for (genvar j = 0; j < W; j++) begin : g_chk
    logic [63:0] seq, pbase, poff, imm, tgt;
    logic        pt, hit, mbr, mjal, mjalr;
    logic [63:0] ptg;
    assign pbase = {xq[j].blk, 4'b0};
    assign poff  = xq[j].strad ? 64'hFFFF_FFFF_FFFF_FFFE : {60'b0, xq[j].pc[3:0]};
    assign seq   = pbase + poff + (xq[j].rvc ? 64'd2 : 64'd4);
    assign pt    = xq[j].pred_taken;
    assign ptg   = xq[j].pred_target;
    // the class from the queue's pre-decode marks, the offset from the raw encoding
    assign {mbr, mjal, mjalr} = xq[j].marks;
    logic [20:0] bimm;
    assign bimm  = bimm_of(xq[j].insn, mjal);
    assign imm   = {{43{bimm[20]}}, bimm};
    assign tgt   = pbase + poff + imm;               // d[j].br_target for a branch or JAL
    assign hit   = eq_add3(pbase, poff, imm, ptg);   // ptg == tgt
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
        if (mjal || mbr) assert (tgt == xd[j].br_target)
          else $error("tg_decode_stage: the raw offset gives another target than decode's");
      end
    end
`endif
  end

  // Group: a prefix of the checks' inputs
  logic [TKW-1:0] n;
  always_comb begin
    logic stop;
    stop = 1'b0;
    n = '0;
    for (int j = 0; j < W; j++) begin
      if (!stop) begin
        if (!xv[j]) stop = 1'b1;
        else if (xa[j] && j > 0) stop = 1'b1;
        else begin
          n = TKW'(j + 1);
          if (xa[j] || redir[j]) stop = 1'b1;
        end
      end
    end
    if (dred || flush) n = '0;
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
    assign xv = v1_q;
    assign xe = e1_q;
    assign xa = a1_q;
    assign xq = i1_q;
    assign xd = d1_q;
    // The queue's count of the group: the same without the redirects
    logic [TKW-1:0] nq;
    always_comb begin
      logic stopq;
      stopq = 1'b0;
      nq = '0;
      for (int j = 0; j < W; j++) begin
        if (!stopq) begin
          if (!v1_q[j]) stopq = 1'b1;
          else if (a1_q[j] && j > 0) stopq = 1'b1;
          else begin
            nq = TKW'(j + 1);
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
            end
            if (k >= left && s == k - left && s < acc) begin     // new: queue entry s
              v1_q[k] <= 1'b1;
              i1_q[k] <= iq_insn[s];
              d1_q[k] <= d[s];
              e1_q[k] <= exc_f[s];
              a1_q[k] <= alone_f[s];
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
          dred    <= 1'b1;
          dred_pc <= npc[j];
        end
      end
    end
  end
endmodule
