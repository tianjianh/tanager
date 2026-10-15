// Decode stages (DE1, DE2; docs/spec/core-pipeline.md §3.4, §4). Measurement of a reserve lever
// (DR-135; branch tmp/core-cut-de, not for merge): decode takes a stage of its own.
//   DE1 decodes the DECODE_WIDTH instructions at the instruction-queue head into its registers,
//       as many as there is room for: the slots DE2 does not hand on are kept, moved to the front.
//   DE2 forms the group rename takes, all or nothing, from DE1's registers, and checks the
//       predictions (decode-time redirects).
// Group rules: a serialising instruction or one with a decode-time exception goes alone, in
// slot 0; a decode-time redirect ends the group after its instruction.
// Redirects: JAL not predicted to its target, a branch predicted taken to a wrong target, or a
// prediction on something that is not a branch or jump. The redirect is registered (dred) and
// flushes the front end and DE1 in the next cycle; decode takes nothing in that cycle.
// The queue's take depends only on DE1's registers and rename's take: for it, a group ends only
// at serialising and exception instructions. The instructions after a redirect in it are dropped,
// as the redirect drops what DE1 holds.
// Timing: whether the predicted target is the branch's is checked without a carry chain: the
// target is block address + offset + immediate, and "a + b + c == k" holds when every bit of
// the carry-save sum matches the carry k needs there (Cortadella and Llaberia, IEEE Trans.
// Computers, 1992). The sums themselves (the targets, the next PC) feed only registers.
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
  // a + b + c == k, carry-free
  function automatic logic eq_add3(input logic [63:0] a, input logic [63:0] b, input logic [63:0] c,
                                   input logic [63:0] k);
    logic [63:0] s, y, cin;
    s   = a ^ b ^ c;
    y   = ((a & b) | (a & c) | (b & c)) << 1;
    cin = {(s[62:0] & y[62:0]) | ((s[62:0] | y[62:0]) & ~k[62:0]), 1'b0};
    return (s ^ y ^ k) == cin;
  endfunction

  // ================= DE1: decode the queue head =================
  dec_t [W-1:0]       d;
  logic [W-1:0][20:0] bimm;            // the branch's immediate (JAL or conditional), sign at 20
  for (genvar j = 0; j < W; j++) begin : g_dec
    // Compressed instructions are expanded first; without C they are illegal (tval is the
    // 16-bit encoding, which the ROB keeps).
    logic [31:0] xinsn;
    logic        rvc_ill;
    tg_rvc u_rvc (.c(iq_insn[j].insn[15:0]), .has_d(EXT_FD && misa_d), .insn(xinsn), .ill(rvc_ill));
    logic [31:0] xi;
    assign xi = iq_insn[j].rvc ? xinsn : iq_insn[j].insn;
    tg_decode u_dec (.pc_lo(iq_insn[j].pc[3:0]), .blk(iq_insn[j].blk), .strad(iq_insn[j].strad), .insn(xi),
                     .len2(iq_insn[j].rvc),
                     .pre_ill(iq_insn[j].rvc && (!(EXT_C && misa_c) || rvc_ill)),
                     .fault(iq_insn[j].fault), .fault_pf(iq_insn[j].fault_pf), .fault_hi(iq_insn[j].fault_hi), .misa_m, .misa_b, .misa_a, .misa_f, .misa_d, .fs, .frm, .priv, .tvm, .tw, .tsr, .d(d[j]));
    // as tg_decode adds it for d.br_target
    assign bimm[j] = (d[j].br_kind == BR_JAL) ? {xi[31], xi[19:12], xi[20], xi[30:21], 1'b0}
                                              : {{8{xi[31]}}, xi[31], xi[7], xi[30:25], xi[11:8], 1'b0};
  end

  // DE1's registers: a prefix of the slots is valid
  logic [W-1:0]       v1_q;
  fe_insn_t [W-1:0]   i1_q;
  dec_t [W-1:0]       d1_q;
  logic [W-1:0][20:0] b1_q;

  // ================= DE2: checks and the group, from DE1's registers =================
  logic [W-1:0]        redir;
  logic [W-1:0][63:0]  npc;
  logic [W-1:0]        dfix;
  for (genvar j = 0; j < W; j++) begin : g_chk
    logic [63:0] seq, pbase, poff, imm;
    logic        pt, hit;
    logic [63:0] ptg;
    assign pbase = {i1_q[j].blk, 4'b0};
    assign poff  = i1_q[j].strad ? 64'hFFFF_FFFF_FFFF_FFFE : {60'b0, i1_q[j].pc[3:0]};
    assign seq   = pbase + poff + (i1_q[j].rvc ? 64'd2 : 64'd4);
    assign pt    = i1_q[j].pred_taken;
    assign ptg   = i1_q[j].pred_target;
    assign imm   = {{43{b1_q[j][20]}}, b1_q[j]};
    assign hit   = eq_add3(pbase, poff, imm, ptg);   // ptg == d1_q[j].br_target
    always_comb begin
      npc[j]   = pt ? ptg : seq;
      redir[j] = 1'b0;
      dfix[j]  = 1'b0;
      if (!d1_q[j].exc) begin
        if (d1_q[j].cls == C_BR && d1_q[j].br_kind == BR_JAL) begin
          if (!pt || !hit) begin
            redir[j] = 1'b1; dfix[j] = 1'b1; npc[j] = d1_q[j].br_target;
          end
        end else if (d1_q[j].cls == C_BR && d1_q[j].br_kind == BR_COND) begin
          if (pt && !hit) begin
            redir[j] = 1'b1; dfix[j] = 1'b1; npc[j] = d1_q[j].br_target;
          end
        end else if (d1_q[j].cls != C_BR && pt) begin
          redir[j] = 1'b1; dfix[j] = 1'b1; npc[j] = seq;
        end
      end
    end
  end

  // Group: a prefix of DE1 (n); for the queue's take, the same without the redirects (nq)
  logic [TKW-1:0] n, nq;
  always_comb begin
    logic stop, stopq;
    stop  = 1'b0;
    stopq = 1'b0;
    n  = '0;
    nq = '0;
    for (int j = 0; j < W; j++) begin
      if (!stop) begin
        if (!v1_q[j]) stop = 1'b1;
        else if ((d1_q[j].serial || d1_q[j].exc) && j > 0) stop = 1'b1;
        else begin
          n = TKW'(j + 1);
          if (d1_q[j].serial || d1_q[j].exc || redir[j]) stop = 1'b1;
        end
      end
      if (!stopq) begin
        if (!v1_q[j]) stopq = 1'b1;
        else if ((d1_q[j].serial || d1_q[j].exc) && j > 0) stopq = 1'b1;
        else begin
          nq = TKW'(j + 1);
          if (d1_q[j].serial || d1_q[j].exc) stopq = 1'b1;
        end
      end
    end
    if (dred || flush) begin
      n  = '0;
      nq = '0;
    end
  end

  for (genvar j = 0; j < W; j++) begin : g_out
    assign de_valid[j] = TKW'(j) < n;
    always_comb begin
      de_uop[j]          = '0;
      de_uop[j].pc       = i1_q[j].pc;
      de_uop[j].insn     = i1_q[j].insn;
      de_uop[j].rvc      = i1_q[j].rvc;
      de_uop[j].pred_npc = npc[j];
      de_uop[j].ubtb_hit = i1_q[j].ubtb_hit;
      de_uop[j].ubtb_way = i1_q[j].ubtb_way;
      de_uop[j].dfix     = dfix[j];
      de_uop[j].tid      = i1_q[j].tid;
      de_uop[j].d        = d1_q[j];
    end
  end

  // ================= The queue's take and DE1's next contents =================
  // DE2 hands on `used` slots (counted without redirects); the `left` after them move to the
  // front, and the queue fills the rest.
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
            b1_q[k] <= b1_q[s];
          end
          if (k >= left && s == k - left && s < acc) begin     // new: queue entry s
            v1_q[k] <= 1'b1;
            i1_q[k] <= iq_insn[s];
            d1_q[k] <= d[s];
            b1_q[k] <= bimm[s];
          end
        end
      end
    end
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

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      for (int j = 1; j < W; j++)
        assert (!v1_q[j] || v1_q[j-1]) else $error("tg_decode_stage: DE1's valid slots are not a prefix");
      assert (n <= nq) else $error("tg_decode_stage: the group is longer than the queue's count");
    end
  end
`endif
endmodule
