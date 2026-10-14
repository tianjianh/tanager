// RVC expander (RV64C, unprivileged ISA 20240411 ch. "C" and the Zca subset): maps a 16-bit
// encoding to the 32-bit instruction it stands for. Combinational. Reserved encodings and the
// FP forms (C.FLD, C.FSD, C.FLDSP, C.FSDSP) without D are `ill`; HINTs expand to their base
// instruction (Spike executes them that way). Wired into decode when the ISA gains C (M3).
module tg_rvc
  import tg_pkg::*;
(
  input  logic [15:0] c,
  input  logic        has_d,      // misa.D: the FP load/store forms exist
  output logic [31:0] insn,
  output logic        ill
);
  // Register fields
  logic [4:0] rd, rs2, rdp, rs1p, rs2p;
  assign rd   = c[11:7];
  assign rs2  = c[6:2];
  assign rdp  = {2'b01, c[4:2]};
  assign rs1p = {2'b01, c[9:7]};
  assign rs2p = {2'b01, c[4:2]};

  // Encoders
  function automatic logic [31:0] i_type(input logic [11:0] imm, input logic [4:0] rs1,
                                         input logic [2:0] f3, input logic [4:0] d, input logic [6:0] op);
    return {imm, rs1, f3, d, op};
  endfunction
  function automatic logic [31:0] s_type(input logic [11:0] imm, input logic [4:0] s2, input logic [4:0] s1,
                                         input logic [2:0] f3, input logic [6:0] op);
    return {imm[11:5], s2, s1, f3, imm[4:0], op};
  endfunction
  function automatic logic [31:0] r_type(input logic [6:0] f7, input logic [4:0] s2, input logic [4:0] s1,
                                         input logic [2:0] f3, input logic [4:0] d, input logic [6:0] op);
    return {f7, s2, s1, f3, d, op};
  endfunction
  // Branch and jump offsets are even: callers pass them without bit 0
  function automatic logic [31:0] b_type(input logic [12:1] imm, input logic [4:0] s2, input logic [4:0] s1,
                                         input logic [2:0] f3);
    return {imm[12], imm[10:5], s2, s1, f3, imm[4:1], imm[11], 7'b1100011};
  endfunction
  function automatic logic [31:0] j_type(input logic [20:1] imm, input logic [4:0] d);
    return {imm[20], imm[10:1], imm[11], imm[19:12], d, 7'b1101111};
  endfunction

  localparam logic [6:0] OP_LOAD = 7'b0000011, OP_STORE = 7'b0100011, OP_IMM = 7'b0010011,
                         OP_IMM32 = 7'b0011011, OP_OP = 7'b0110011, OP_OP32 = 7'b0111011,
                         OP_LUI = 7'b0110111, OP_JALR = 7'b1100111, OP_FLOAD = 7'b0000111,
                         OP_FSTORE = 7'b0100111;

  // Immediates
  logic [11:0] imm6, uimm_lw, uimm_ld, uimm_lwsp, uimm_ldsp, uimm_swsp, uimm_sdsp, nzuimm4, nzimm16;
  logic [12:0] boff;
  logic [20:0] joff;
  logic        unused;
  assign unused = boff[0] ^ joff[0];
  logic [5:0]  shamt;
  assign imm6      = {{7{c[12]}}, c[6:2]};
  assign uimm_lw   = {5'b0, c[5], c[12:10], c[6], 2'b0};
  assign uimm_ld   = {4'b0, c[6:5], c[12:10], 3'b0};
  assign uimm_lwsp = {4'b0, c[3:2], c[12], c[6:4], 2'b0};
  assign uimm_ldsp = {3'b0, c[4:2], c[12], c[6:5], 3'b0};
  assign uimm_swsp = {4'b0, c[8:7], c[12:9], 2'b0};
  assign uimm_sdsp = {3'b0, c[9:7], c[12:10], 3'b0};
  assign nzuimm4   = {2'b0, c[10:7], c[12:11], c[5], c[6], 2'b0};
  assign nzimm16   = {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0};
  assign boff      = {{5{c[12]}}, c[6:5], c[2], c[11:10], c[4:3], 1'b0};
  assign joff      = {{10{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
  assign shamt     = {c[12], c[6:2]};

  always_comb begin
    insn = '0;
    ill  = 1'b0;
    unique case ({c[1:0], c[15:13]})
      // ---- Quadrant 0 ----
      5'b00_000: begin                                   // C.ADDI4SPN
        insn = i_type(nzuimm4, 5'd2, 3'b000, rdp, OP_IMM);
        if (nzuimm4 == '0) ill = 1'b1;                   // includes the all-zero instruction
      end
      5'b00_001: begin                                   // C.FLD
        insn = i_type(uimm_ld, rs1p, 3'b011, rdp, OP_FLOAD);
        if (!has_d) ill = 1'b1;
      end
      5'b00_010: insn = i_type(uimm_lw, rs1p, 3'b010, rdp, OP_LOAD);    // C.LW
      5'b00_011: insn = i_type(uimm_ld, rs1p, 3'b011, rdp, OP_LOAD);    // C.LD
      5'b00_101: begin                                   // C.FSD
        insn = s_type(uimm_ld, rs2p, rs1p, 3'b011, OP_FSTORE);
        if (!has_d) ill = 1'b1;
      end
      5'b00_110: insn = s_type(uimm_lw, rs2p, rs1p, 3'b010, OP_STORE);  // C.SW
      5'b00_111: insn = s_type(uimm_ld, rs2p, rs1p, 3'b011, OP_STORE);  // C.SD
      // ---- Quadrant 1 ----
      5'b01_000: insn = i_type(imm6, rd, 3'b000, rd, OP_IMM);           // C.ADDI, C.NOP
      5'b01_001: begin                                   // C.ADDIW
        insn = i_type(imm6, rd, 3'b000, rd, OP_IMM32);
        if (rd == 5'd0) ill = 1'b1;
      end
      5'b01_010: insn = i_type(imm6, 5'd0, 3'b000, rd, OP_IMM);         // C.LI
      5'b01_011: begin
        if (rd == 5'd2) begin                            // C.ADDI16SP
          insn = i_type(nzimm16, 5'd2, 3'b000, 5'd2, OP_IMM);
          if (nzimm16 == '0) ill = 1'b1;
        end else begin                                   // C.LUI
          insn = {{15{c[12]}}, c[6:2], rd, OP_LUI};
          if ({c[12], c[6:2]} == '0) ill = 1'b1;
        end
      end
      5'b01_100: begin
        unique case (c[11:10])
          2'b00: insn = {6'b000000, shamt, rs1p, 3'b101, rs1p, OP_IMM};   // C.SRLI
          2'b01: insn = {6'b010000, shamt, rs1p, 3'b101, rs1p, OP_IMM};   // C.SRAI
          2'b10: insn = i_type(imm6, rs1p, 3'b111, rs1p, OP_IMM);         // C.ANDI
          default: begin
            unique case ({c[12], c[6:5]})
              3'b000: insn = r_type(7'b0100000, rs2p, rs1p, 3'b000, rs1p, OP_OP);    // C.SUB
              3'b001: insn = r_type(7'b0000000, rs2p, rs1p, 3'b100, rs1p, OP_OP);    // C.XOR
              3'b010: insn = r_type(7'b0000000, rs2p, rs1p, 3'b110, rs1p, OP_OP);    // C.OR
              3'b011: insn = r_type(7'b0000000, rs2p, rs1p, 3'b111, rs1p, OP_OP);    // C.AND
              3'b100: insn = r_type(7'b0100000, rs2p, rs1p, 3'b000, rs1p, OP_OP32);  // C.SUBW
              3'b101: insn = r_type(7'b0000000, rs2p, rs1p, 3'b000, rs1p, OP_OP32);  // C.ADDW
              default: ill = 1'b1;                       // reserved (Zcb)
            endcase
          end
        endcase
      end
      5'b01_101: insn = j_type(joff[20:1], 5'd0);                       // C.J
      5'b01_110: insn = b_type(boff[12:1], 5'd0, rs1p, 3'b000);         // C.BEQZ
      5'b01_111: insn = b_type(boff[12:1], 5'd0, rs1p, 3'b001);         // C.BNEZ
      // ---- Quadrant 2 ----
      5'b10_000: insn = {6'b000000, shamt, rd, 3'b001, rd, OP_IMM};     // C.SLLI
      5'b10_001: begin                                   // C.FLDSP
        insn = i_type(uimm_ldsp, 5'd2, 3'b011, rd, OP_FLOAD);
        if (!has_d) ill = 1'b1;
      end
      5'b10_010: begin                                   // C.LWSP
        insn = i_type(uimm_lwsp, 5'd2, 3'b010, rd, OP_LOAD);
        if (rd == 5'd0) ill = 1'b1;
      end
      5'b10_011: begin                                   // C.LDSP
        insn = i_type(uimm_ldsp, 5'd2, 3'b011, rd, OP_LOAD);
        if (rd == 5'd0) ill = 1'b1;
      end
      5'b10_100: begin
        if (!c[12]) begin
          if (rs2 == 5'd0) begin                         // C.JR
            insn = i_type(12'd0, rd, 3'b000, 5'd0, OP_JALR);
            if (rd == 5'd0) ill = 1'b1;
          end else begin                                 // C.MV
            insn = r_type(7'b0000000, rs2, 5'd0, 3'b000, rd, OP_OP);
          end
        end else begin
          if (rd == 5'd0 && rs2 == 5'd0) insn = 32'h0010_0073;           // C.EBREAK
          else if (rs2 == 5'd0) insn = i_type(12'd0, rd, 3'b000, 5'd1, OP_JALR);   // C.JALR
          else insn = r_type(7'b0000000, rs2, rd, 3'b000, rd, OP_OP);              // C.ADD
        end
      end
      5'b10_101: begin                                   // C.FSDSP
        insn = s_type(uimm_sdsp, rs2, 5'd2, 3'b011, OP_FSTORE);
        if (!has_d) ill = 1'b1;
      end
      5'b10_110: insn = s_type(uimm_swsp, rs2, 5'd2, 3'b010, OP_STORE); // C.SWSP
      5'b10_111: insn = s_type(uimm_sdsp, rs2, 5'd2, 3'b011, OP_STORE); // C.SDSP
      default: ill = 1'b1;                               // 00_100 (reserved), and c[1:0] = 11
    endcase
  end
endmodule
