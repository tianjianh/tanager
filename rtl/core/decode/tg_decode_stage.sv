// Decode stage (DE, docs/spec/core-pipeline.md §3.4, §4): decodes the DECODE_WIDTH instructions
// at the instruction-queue head and forms the group rename takes, all or nothing.
// Group rules: a serialising instruction or one with a decode-time exception goes alone, in
// slot 0; a decode-time redirect ends the group after its instruction.
// Redirects: JAL not predicted to its target, a branch predicted taken to a wrong target, or a
// prediction on something that is not a branch or jump. The redirect is registered (dred) and
// flushes the front end in the next cycle; decode takes nothing in that cycle.
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
  dec_t [W-1:0]        d;
  logic [W-1:0]        redir;
  logic [W-1:0][63:0]  npc;
  logic [W-1:0]        dfix;
  for (genvar j = 0; j < W; j++) begin : g_dec
    tg_decode u_dec (.pc(iq_insn[j].pc), .insn(iq_insn[j].insn), .rvc(iq_insn[j].rvc),
                     .fault(iq_insn[j].fault), .misa_m, .d(d[j]));
    logic [63:0] seq;
    logic        pt;
    logic [63:0] ptg;
    assign seq = iq_insn[j].pc + (iq_insn[j].rvc ? 64'd2 : 64'd4);
    assign pt  = iq_insn[j].pred_taken;
    assign ptg = iq_insn[j].pred_target;
    always_comb begin
      npc[j]   = pt ? ptg : seq;
      redir[j] = 1'b0;
      dfix[j]  = 1'b0;
      if (!d[j].exc) begin
        if (d[j].cls == C_BR && d[j].br_kind == BR_JAL) begin
          if (!pt || ptg != d[j].br_target) begin
            redir[j] = 1'b1; dfix[j] = 1'b1; npc[j] = d[j].br_target;
          end
        end else if (d[j].cls == C_BR && d[j].br_kind == BR_COND) begin
          if (pt && ptg != d[j].br_target) begin
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
