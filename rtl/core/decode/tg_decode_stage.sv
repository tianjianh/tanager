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

  dec_t [W-1:0]        d;
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
    tg_decode u_dec (.pc_lo(iq_insn[j].pc[3:0]), .blk(iq_insn[j].blk), .strad(iq_insn[j].strad), .insn(xi),
                     .len2(iq_insn[j].rvc),
                     .pre_ill(iq_insn[j].rvc && (!(EXT_C && misa_c) || rvc_ill)),
                     .fault(iq_insn[j].fault), .fault_pf(iq_insn[j].fault_pf), .fault_hi(iq_insn[j].fault_hi), .misa_m, .misa_b, .misa_a, .misa_f, .misa_d, .fs, .frm, .priv, .tvm, .tw, .tsr, .d(d[j]));
    logic [63:0] seq, pbase, poff, imm;
    logic        pt, hit;
    logic [63:0] ptg;
    assign pbase = {iq_insn[j].blk, 4'b0};
    assign poff  = iq_insn[j].strad ? 64'hFFFF_FFFF_FFFF_FFFE : {60'b0, iq_insn[j].pc[3:0]};
    assign seq   = pbase + poff + (iq_insn[j].rvc ? 64'd2 : 64'd4);
    assign pt    = iq_insn[j].pred_taken;
    assign ptg   = iq_insn[j].pred_target;
    // the branch's immediate (JAL or conditional), as tg_decode adds it for d.br_target
    assign imm   = (d[j].br_kind == BR_JAL) ? {{43{xi[31]}}, xi[31], xi[19:12], xi[20], xi[30:21], 1'b0}
                                            : {{51{xi[31]}}, xi[31], xi[7], xi[30:25], xi[11:8], 1'b0};
    assign hit   = eq_add3(pbase, poff, imm, ptg);   // ptg == d[j].br_target
    always_comb begin
      npc[j]   = pt ? ptg : seq;
      redir[j] = 1'b0;
      dfix[j]  = 1'b0;
      if (!d[j].exc) begin
        if (d[j].cls == C_BR && d[j].br_kind == BR_JAL) begin
          if (!pt || !hit) begin
            redir[j] = 1'b1; dfix[j] = 1'b1; npc[j] = d[j].br_target;
          end
        end else if (d[j].cls == C_BR && d[j].br_kind == BR_COND) begin
          if (pt && !hit) begin
            redir[j] = 1'b1; dfix[j] = 1'b1; npc[j] = d[j].br_target;
          end
        end else if (d[j].cls != C_BR && pt) begin
          redir[j] = 1'b1; dfix[j] = 1'b1; npc[j] = seq;
        end
      end
    end
  end

  // Group: a prefix of the queue head
  logic [TKW-1:0] n;
  always_comb begin
    logic stop;
    stop = 1'b0;
    n = '0;
    for (int j = 0; j < W; j++) begin
      if (!stop) begin
        if (!iq_valid[j]) stop = 1'b1;
        else if ((d[j].serial || d[j].exc) && j > 0) stop = 1'b1;
        else begin
          n = TKW'(j + 1);
          if (d[j].serial || d[j].exc || redir[j]) stop = 1'b1;
        end
      end
    end
    if (dred || flush) n = '0;
  end

  assign iq_take = de_take ? n : '0;
  for (genvar j = 0; j < W; j++) begin : g_out
    assign de_valid[j] = TKW'(j) < n;
    always_comb begin
      de_uop[j]          = '0;
      de_uop[j].pc       = iq_insn[j].pc;
      de_uop[j].insn     = iq_insn[j].insn;
      de_uop[j].rvc      = iq_insn[j].rvc;
      de_uop[j].pred_npc = npc[j];
      de_uop[j].ubtb_hit = iq_insn[j].ubtb_hit;
      de_uop[j].ubtb_way = iq_insn[j].ubtb_way;
      de_uop[j].dfix     = dfix[j];
      de_uop[j].tid      = iq_insn[j].tid;
      de_uop[j].d        = d[j];
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
endmodule
