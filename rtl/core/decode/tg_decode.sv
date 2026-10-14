// One instruction decoder (docs/spec/core-pipeline.md §4): RV64IM, Zicsr, Zifencei, M-mode
// system instructions. Combinational. Compressed encodings are illegal until the RVC expander
// (M3); misa.M gates MUL/DIV. Immediates that need the PC (AUIPC, the JAL/JALR link value, the
// branch and JAL targets) are computed here, so execute never adds the PC.
module tg_decode
  import tg_pkg::*, tg_alu_pkg::*, tg_core_pkg::*;
(
  input  logic [63:0] pc,
  input  logic [31:0] insn,
  input  logic        rvc,
  input  logic        fault,      // fetch access fault at pc
  input  logic        misa_m,
  output dec_t        d
);
  logic [6:0] op;
  logic [2:0] f3;
  logic [6:0] f7;
  logic [63:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  assign op = insn[6:0];
  assign f3 = insn[14:12];
  assign f7 = insn[31:25];
  assign imm_i = {{52{insn[31]}}, insn[31:20]};
  assign imm_s = {{52{insn[31]}}, insn[31:25], insn[11:7]};
  assign imm_b = {{51{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
  assign imm_u = {{32{insn[31]}}, insn[31:12], 12'b0};
  assign imm_j = {{43{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

  function automatic alu_ctl_t ctl(input logic [2:0] grp);
    alu_ctl_t c;
    c = '0;
    c.grp[grp] = 1'b1;
    return c;
  endfunction

  always_comb begin
    logic ill;
    d = '0;
    d.cls = C_ALU;
    d.rs1 = insn[19:15];
    d.rs2 = insn[24:20];
    d.rd  = insn[11:7];
    d.mem_size = f3[1:0];
    d.mem_uns  = f3[2];
    d.br_f3 = f3;
    d.jalr_off = insn[31:20];
    d.csr_op = csr_op_e'(f3[1:0]);
    d.csr_imm = f3[2];
    ill = 1'b0;

    if (rvc || insn[1:0] != 2'b11) begin
      ill = 1'b1;
    end else begin
      unique case (op)
        7'b0110111: begin                                  // LUI
          d.rd_en = 1'b1; d.alu = ctl(3'(G_PASSB)); d.b_imm = 1'b1; d.imm = imm_u;
        end
        7'b0010111: begin                                  // AUIPC
          d.rd_en = 1'b1; d.alu = ctl(3'(G_PASSB)); d.b_imm = 1'b1; d.imm = pc + imm_u;
        end
        7'b1101111: begin                                  // JAL
          d.cls = C_BR; d.br_kind = BR_JAL; d.rd_en = 1'b1;
          d.alu = ctl(3'(G_PASSB)); d.b_imm = 1'b1; d.imm = pc + 64'd4; d.br_target = pc + imm_j;
        end
        7'b1100111: begin                                  // JALR
          if (f3 != 3'd0) ill = 1'b1;
          d.cls = C_BR; d.br_kind = BR_JALR; d.rd_en = 1'b1; d.rs1_en = 1'b1;
          d.alu = ctl(3'(G_PASSB)); d.b_imm = 1'b1; d.imm = pc + 64'd4;
        end
        7'b1100011: begin                                  // branches
          if (f3 == 3'd2 || f3 == 3'd3) ill = 1'b1;
          d.cls = C_BR; d.br_kind = BR_COND; d.rs1_en = 1'b1; d.rs2_en = 1'b1;
          d.alu = ctl(3'(G_ADD)); d.alu.sub = 1'b1; d.br_target = pc + imm_b;
        end
        7'b0000011: begin                                  // loads
          if (f3 == 3'd7) ill = 1'b1;
          d.cls = C_LD; d.rs1_en = 1'b1; d.rd_en = 1'b1; d.imm = imm_i;
        end
        7'b0100011: begin                                  // stores
          if (f3[2]) ill = 1'b1;
          d.cls = C_ST; d.rs1_en = 1'b1; d.rs2_en = 1'b1; d.imm = imm_s;
        end
        7'b0010011, 7'b0011011: begin                      // OP-IMM, OP-IMM-32
          logic w;
          w = op[3];
          d.rs1_en = 1'b1; d.rd_en = 1'b1; d.b_imm = 1'b1; d.imm = imm_i;
          unique case (f3)
            3'd0: begin d.alu = ctl(3'(G_ADD)); d.alu.word = w; end
            3'd2: begin d.alu = ctl(3'(G_SLT)); d.alu.sub = 1'b1; if (w) ill = 1'b1; end
            3'd3: begin d.alu = ctl(3'(G_SLT)); d.alu.sub = 1'b1; d.alu.cmp_unsigned = 1'b1; if (w) ill = 1'b1; end
            3'd4: begin d.alu = ctl(3'(G_LOGIC)); d.alu.lg_fn = LG_XOR; if (w) ill = 1'b1; end
            3'd6: begin d.alu = ctl(3'(G_LOGIC)); d.alu.lg_fn = LG_OR;  if (w) ill = 1'b1; end
            3'd7: begin d.alu = ctl(3'(G_LOGIC)); d.alu.lg_fn = LG_AND; if (w) ill = 1'b1; end
            3'd1: begin                                    // SLLI, SLLIW
              d.alu = ctl(3'(G_SHIFT)); d.alu.sh_left = 1'b1; d.alu.word = w;
              if (w ? (f7 != 7'd0) : (insn[31:26] != 6'd0)) ill = 1'b1;
            end
            default: begin                                 // SRLI/SRAI, SRLIW/SRAIW
              d.alu = ctl(3'(G_SHIFT)); d.alu.word = w;
              d.alu.sh_arith = insn[30];
              if (w ? (f7 != 7'd0 && f7 != 7'b0100000) : (insn[31:26] != 6'd0 && insn[31:26] != 6'b010000))
                ill = 1'b1;
            end
          endcase
        end
        7'b0110011, 7'b0111011: begin                      // OP, OP-32
          logic w;
          w = op[3];
          d.rs1_en = 1'b1; d.rs2_en = 1'b1; d.rd_en = 1'b1;
          if (f7 == 7'b0000001) begin                      // M extension
            if (!misa_m) ill = 1'b1;
            d.word = w;
            if (!f3[2]) begin
              d.cls = C_MUL; d.mul_op = mul_op_e'(f3[1:0]);
              if (w && f3 != 3'd0) ill = 1'b1;             // only MULW
            end else begin
              d.cls = C_DIV; d.div_op = div_op_e'(f3[1:0]);
            end
          end else if (f7 == 7'b0000000) begin
            unique case (f3)
              3'd0: begin d.alu = ctl(3'(G_ADD)); d.alu.word = w; end
              3'd1: begin d.alu = ctl(3'(G_SHIFT)); d.alu.sh_left = 1'b1; d.alu.word = w; end
              3'd2: begin d.alu = ctl(3'(G_SLT)); d.alu.sub = 1'b1; if (w) ill = 1'b1; end
              3'd3: begin d.alu = ctl(3'(G_SLT)); d.alu.sub = 1'b1; d.alu.cmp_unsigned = 1'b1; if (w) ill = 1'b1; end
              3'd4: begin d.alu = ctl(3'(G_LOGIC)); d.alu.lg_fn = LG_XOR; if (w) ill = 1'b1; end
              3'd5: begin d.alu = ctl(3'(G_SHIFT)); d.alu.word = w; end
              3'd6: begin d.alu = ctl(3'(G_LOGIC)); d.alu.lg_fn = LG_OR;  if (w) ill = 1'b1; end
              default: begin d.alu = ctl(3'(G_LOGIC)); d.alu.lg_fn = LG_AND; if (w) ill = 1'b1; end
            endcase
          end else if (f7 == 7'b0100000 && f3 == 3'd0) begin
            d.alu = ctl(3'(G_ADD)); d.alu.sub = 1'b1; d.alu.word = w;
          end else if (f7 == 7'b0100000 && f3 == 3'd5) begin
            d.alu = ctl(3'(G_SHIFT)); d.alu.sh_arith = 1'b1; d.alu.word = w;
          end else begin
            ill = 1'b1;
          end
        end
        7'b0001111: begin                                  // FENCE, FENCE.I
          d.cls = C_SYS; d.serial = 1'b1;
          if (f3 == 3'd0)      d.sys = SYS_FENCE;
          else if (f3 == 3'd1) d.sys = SYS_FENCEI;
          else                 ill = 1'b1;
        end
        7'b1110011: begin                                  // SYSTEM
          if (f3 == 3'd0) begin
            d.cls = C_SYS;
            unique case (insn)
              32'h0000_0073: begin d.exc = 1'b1; d.exc_cause = EXC_ECALL_M; end
              32'h0010_0073: begin d.exc = 1'b1; d.exc_cause = EXC_BREAK; end
              32'h3020_0073: begin d.sys = SYS_MRET; d.serial = 1'b1; end
              32'h1050_0073: begin d.sys = SYS_WFI;  d.serial = 1'b1; end
              default: ill = 1'b1;                         // SRET, SFENCE.VMA (no S-mode), ...
            endcase
          end else if (f3 == 3'd4) begin
            ill = 1'b1;
          end else begin                                   // CSRR[WSC][I]
            d.cls = C_CSR; d.serial = 1'b1; d.rd_en = 1'b1;
            d.rs1_en = !f3[2];
            d.csr_wr = (f3[1:0] == 2'b01) || (insn[19:15] != 5'd0);
          end
        end
        default: ill = 1'b1;
      endcase
    end

    if (d.rd == 5'd0) d.rd_en = 1'b0;
    if (d.rs1 == 5'd0) d.rs1_en = 1'b0;
    if (d.rs2 == 5'd0) d.rs2_en = 1'b0;

    if (fault) begin
      d = '0;
      d.cls = C_SYS; d.exc = 1'b1; d.exc_cause = EXC_IACCESS;
    end else if (ill) begin
      d = '0;
      d.cls = C_SYS; d.exc = 1'b1; d.exc_cause = EXC_ILLEGAL;
    end
  end
endmodule
