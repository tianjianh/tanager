// One instruction decoder (docs/spec/core-pipeline.md §4): RV64IM, Zicsr, Zifencei, the system
// instructions, and (with their switches) A, F/D, Zba/Zbb/Zbs/Zicond. F and D follow Spike:
// legal only with misa.F (and misa.D for D) and mstatus.FS != Off; a rounding mode of 5 or 6,
// or DYN while frm >= 5, is illegal in the instructions that round. Combinational. A compressed
// instruction arrives already expanded by tg_rvc (its link value, PC + 2, comes in as `link`);
// misa.M gates MUL/DIV. Immediates that need the PC (AUIPC, the JAL/JALR link value, the branch
// and JAL targets) are made in decode, so execute never adds the PC. Each is the block address
// plus the PC's offset in it plus the operand, one three-input add (a carry-save step and one
// carry chain), so it doesn't wait for the PC's own decrement (a straddler's) (timing). AUIPC's
// is added here; the link value and the target come in (`link`, `tgt`): the decode stage adds
// them once, for its own next PC and redirect too (area).
module tg_decode
  import tg_pkg::*, tg_alu_pkg::*, tg_fpu_pkg::*, tg_core_pkg::*;
#(
  // 1: the fields are cleared by ill_q, the instruction queue's illegal bit (decoded as it was
  // written, with the same state: every change of it ends in a flush), not by this decoder's own,
  // so the fields do not wait for the illegal decision (timing); the own one is then checked
  // against it in simulation
  parameter bit ILL_Q = 1'b0
)
(
  input  logic [3:0]  pc_lo,      // the PC's low bits (none of its own adds need the rest)
  input  logic [63:4] blk,        // pc = {blk, 4'b0} + off: off = pc_lo, or -2 when strad
  input  logic        strad,
  input  logic [31:0] insn,       // 32-bit encoding (a compressed one already expanded)
  input  logic [63:0] link,       // pc + 2 or 4
  input  logic [63:0] tgt,        // pc + the JAL's or branch's offset
  input  logic        pre_ill,    // illegal before decode (a compressed encoding without C)
  input  logic        fault,      // fetch fault at pc: access, or page (fault_pf)
  input  logic        fault_pf,
  input  logic        fault_hi,   // ... on the second half (tval = pc + 2)
  input  logic        misa_m,
  input  logic        misa_b,     // Zba/Zbb/Zbs (with EXT_B)
  input  logic        misa_a,     // atomics (with EXT_A)
  input  logic        misa_f,     // F and D (with EXT_FD)
  input  logic        misa_d,
  input  logic [1:0]  fs,         // mstatus.FS
  input  logic [2:0]  frm,
  input  priv_e       priv,       // current mode (stable: mode changes end in a flush)
  input  logic        tvm,
  input  logic        tw,
  input  logic        tsr,
  input  logic        ill_q = 1'b0,   // with ILL_Q: the queue's illegal bit
  output dec_t        d,
  output logic        ill_o       // this decoder's illegal decision (before the fault override)
);
  logic xb, xf, xd;
  assign xb = EXT_B && misa_b;
  assign xf = EXT_FD && misa_f && fs != 2'd0;
  assign xd = xf && misa_d;
  // A format the configuration has: S with F, D with D
  function automatic logic fmt_ok(input logic [1:0] f, input logic hf, input logic hd);
    return (f == 2'd0 && hf) || (f == 2'd1 && hd);
  endfunction
  // A rounding mode the instruction may use (frm for DYN); Spike's RM macro
  logic [2:0] rm_eff;
  assign rm_eff = (insn[14:12] == 3'd7) ? frm : insn[14:12];
  logic [6:0] op;
  logic [2:0] f3;
  logic [6:0] f7;
  logic [63:0] imm_i, imm_s, imm_u;
  assign op = insn[6:0];
  assign f3 = insn[14:12];
  assign f7 = insn[31:25];
  assign imm_i = {{52{insn[31]}}, insn[31:20]};
  assign imm_s = {{52{insn[31]}}, insn[31:25], insn[11:7]};
  assign imm_u = {{32{insn[31]}}, insn[31:12], 12'b0};
  logic [63:0] pbase, poff;
  assign pbase = {blk, 4'b0};
  assign poff  = strad ? 64'hFFFF_FFFF_FFFF_FFFE : {60'b0, pc_lo};

  function automatic alu_ctl_t ctl(input logic [2:0] grp);
    alu_ctl_t c;
    c = '0;
    c.grp[grp] = 1'b1;
    return c;
  endfunction

  logic ill;
  assign ill_o = ill;
  always_comb begin
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

    if (pre_ill || insn[1:0] != 2'b11) begin
      ill = 1'b1;
    end else begin
      unique case (op)
        7'b0110111: begin                                  // LUI
          d.rd_en = 1'b1; d.alu = ctl(3'(G_PASSB)); d.b_imm = 1'b1; d.imm = imm_u;
        end
        7'b0010111: begin                                  // AUIPC
          d.rd_en = 1'b1; d.alu = ctl(3'(G_PASSB)); d.b_imm = 1'b1; d.imm = pbase + poff + imm_u;
        end
        7'b1101111: begin                                  // JAL
          d.cls = C_BR; d.br_kind = BR_JAL; d.rd_en = 1'b1;
          d.alu = ctl(3'(G_PASSB)); d.b_imm = 1'b1; d.imm = link;
          d.br_target = tgt;
        end
        7'b1100111: begin                                  // JALR
          if (f3 != 3'd0) ill = 1'b1;
          d.cls = C_BR; d.br_kind = BR_JALR; d.rd_en = 1'b1; d.rs1_en = 1'b1;
          d.alu = ctl(3'(G_PASSB)); d.b_imm = 1'b1; d.imm = link;
        end
        7'b1100011: begin                                  // branches
          if (f3 == 3'd2 || f3 == 3'd3) ill = 1'b1;
          d.cls = C_BR; d.br_kind = BR_COND; d.rs1_en = 1'b1; d.rs2_en = 1'b1;
          d.alu = ctl(3'(G_ADD)); d.alu.sub = 1'b1; d.br_target = tgt;
        end
        7'b0000011: begin                                  // loads
          if (f3 == 3'd7) ill = 1'b1;
          d.cls = C_LD; d.rs1_en = 1'b1; d.rd_en = 1'b1; d.imm = imm_i;
        end
        7'b0100011: begin                                  // stores
          if (f3[2]) ill = 1'b1;
          d.cls = C_ST; d.rs1_en = 1'b1; d.rs2_en = 1'b1; d.imm = imm_s;
        end
        7'b0000111: begin                                  // FLW, FLD
          d.cls = C_LD; d.rs1_en = 1'b1; d.rd_en = 1'b1; d.rd_fp = 1'b1; d.imm = imm_i;
          if (!((f3 == 3'd2 && xf) || (f3 == 3'd3 && xd))) ill = 1'b1;
        end
        7'b0100111: begin                                  // FSW, FSD
          d.cls = C_ST; d.rs1_en = 1'b1; d.rs2_en = 1'b1; d.rs2_fp = 1'b1; d.imm = imm_s;
          if (!((f3 == 3'd2 && xf) || (f3 == 3'd3 && xd))) ill = 1'b1;
        end
        7'b1000011, 7'b1000111, 7'b1001011, 7'b1001111: begin   // FMADD, FMSUB, FNMSUB, FNMADD
          d.cls = C_FP; d.rd_en = 1'b1; d.rd_fp = 1'b1;
          d.rs1_en = 1'b1; d.rs1_fp = 1'b1; d.rs2_en = 1'b1; d.rs2_fp = 1'b1;
          d.rs3_en = 1'b1; d.rs3 = insn[31:27];
          d.fmt = ffmt_e'(insn[26:25]); d.rm = rm_e'(rm_eff);
          unique case (op[3:2])
            2'b00:   d.fop = FOP_FMADD;
            2'b01:   d.fop = FOP_FMSUB;
            2'b10:   d.fop = FOP_FNMSUB;
            default: d.fop = FOP_FNMADD;
          endcase
          if (!fmt_ok(insn[26:25], xf, xd) || rm_eff > 3'd4) ill = 1'b1;
        end
        7'b1010011: begin                                  // OP-FP
          logic rnd;                                       // uses the rounding mode
          d.cls = C_FP; d.rd_en = 1'b1; d.rd_fp = 1'b1;
          d.rs1_en = 1'b1; d.rs1_fp = 1'b1; d.rs2_en = 1'b1; d.rs2_fp = 1'b1;
          d.fmt = ffmt_e'(insn[26:25]); d.rm = rm_e'(rm_eff);
          d.ifmt = ifmt_e'(insn[21:20]);
          rnd = 1'b0;
          if (!fmt_ok(insn[26:25], xf, xd)) ill = 1'b1;
          unique case (insn[31:27])
            5'b00000: begin d.fop = FOP_FADD; rnd = 1'b1; end
            5'b00001: begin d.fop = FOP_FSUB; rnd = 1'b1; end
            5'b00010: begin d.fop = FOP_FMUL; rnd = 1'b1; end
            5'b00011: begin d.fop = FOP_FDIV; rnd = 1'b1; d.fp_div = 1'b1; end
            5'b01011: begin                                // FSQRT
              d.fop = FOP_FSQRT; rnd = 1'b1; d.fp_div = 1'b1; d.rs2_en = 1'b0;
              if (insn[24:20] != 5'd0) ill = 1'b1;
            end
            5'b00100: begin                                // FSGNJ, FSGNJN, FSGNJX
              d.fop = (f3 == 3'd0) ? FOP_FSGNJ : (f3 == 3'd1) ? FOP_FSGNJN : FOP_FSGNJX;
              if (f3 > 3'd2) ill = 1'b1;
            end
            5'b00101: begin                                // FMIN, FMAX
              d.fop = f3[0] ? FOP_FMAX : FOP_FMIN;
              if (f3 > 3'd1) ill = 1'b1;
            end
            5'b01000: begin                                // FCVT.S.D, FCVT.D.S
              d.fop = FOP_FCVT_F_F; rnd = 1'b1; d.rs2_en = 1'b0;
              d.src_fmt = ffmt_e'(insn[21:20]);
              if (insn[24:22] != 3'd0 || insn[21:20] == insn[26:25] || !fmt_ok(insn[21:20], xf, xd))
                ill = 1'b1;
            end
            5'b10100: begin                                // FLE, FLT, FEQ
              d.fop = (f3 == 3'd0) ? FOP_FLE : (f3 == 3'd1) ? FOP_FLT : FOP_FEQ;
              d.rd_fp = 1'b0; d.fp_int = 1'b1;
              if (f3 > 3'd2) ill = 1'b1;
            end
            5'b11000: begin                                // FCVT.W/WU/L/LU.fmt
              d.fop = FOP_FCVT_I_F; rnd = 1'b1; d.rs2_en = 1'b0;
              d.rd_fp = 1'b0; d.fp_int = 1'b1;
              if (insn[24:22] != 3'd0) ill = 1'b1;
            end
            5'b11010: begin                                // FCVT.fmt.W/WU/L/LU
              d.fop = FOP_FCVT_F_I; rnd = 1'b1; d.rs2_en = 1'b0; d.rs1_fp = 1'b0;
              if (insn[24:22] != 3'd0) ill = 1'b1;
            end
            5'b11100: begin                                // FMV.X.W/D, FCLASS
              d.fop = (f3 == 3'd0) ? FOP_FMV_X_F : FOP_FCLASS; d.rs2_en = 1'b0;
              d.rd_fp = 1'b0; d.fp_int = 1'b1;
              if (insn[24:20] != 5'd0 || f3 > 3'd1) ill = 1'b1;
            end
            5'b11110: begin                                // FMV.W.X, FMV.D.X
              d.fop = FOP_FMV_F_X; d.rs2_en = 1'b0; d.rs1_fp = 1'b0;
              if (insn[24:20] != 5'd0 || f3 != 3'd0) ill = 1'b1;
            end
            default: ill = 1'b1;
          endcase
          if (rnd && rm_eff > 3'd4) ill = 1'b1;
        end
        7'b0101111: begin                                  // AMO: LR, SC, AMO*.W/D
          d.cls = C_ST; d.amo = 1'b1; d.amo_op = insn[31:27]; d.serial = 1'b1;
          d.rs1_en = 1'b1; d.rs2_en = 1'b1; d.rd_en = 1'b1; d.imm = '0;
          if (!(EXT_A && misa_a) || !(f3 == 3'd2 || f3 == 3'd3)) ill = 1'b1;
          unique case (insn[31:27])
            AMO_LR: begin
              d.rs2_en = 1'b0;
              if (insn[24:20] != 5'd0) ill = 1'b1;
            end
            AMO_SC, AMO_SWAP, AMO_ADD, AMO_XOR, AMO_AND, AMO_OR, AMO_MIN, AMO_MAX, AMO_MINU,
            AMO_MAXU: ;
            default: ill = 1'b1;
          endcase
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
            3'd1: begin
              if (w ? (f7 == 7'd0) : (insn[31:26] == 6'd0)) begin           // SLLI, SLLIW
                d.alu = ctl(3'(G_SHIFT)); d.alu.sh_left = 1'b1; d.alu.word = w;
              end else if (xb && w && insn[31:26] == 6'b000010) begin   // SLLI.UW
                d.alu = ctl(3'(G_SHIFT)); d.alu.sh_left = 1'b1; d.alu.uw = 1'b1;
              end else if (xb && insn[31:20] inside {12'h600, 12'h601, 12'h602}) begin
                d.cls = C_MUL; d.bcnt = 1'b1; d.word = w;                 // CLZ, CTZ, CPOP (W)
                d.mul_op = mul_op_e'(insn[21:20]);
                d.b_imm = 1'b0;
              end else if (xb && !w && insn[31:20] == 12'h604) begin    // SEXT.B
                d.alu = ctl(3'(G_UNARY)); d.alu.un_fn = UN_SEXTB;
              end else if (xb && !w && insn[31:20] == 12'h605) begin    // SEXT.H
                d.alu = ctl(3'(G_UNARY)); d.alu.un_fn = UN_SEXTH;
              end else if (xb && !w && insn[31:26] inside {6'b001010, 6'b010010, 6'b011010}) begin
                d.alu = ctl(3'(G_BIT));                                   // BSETI, BCLRI, BINVI
                d.alu.bit_fn = (insn[31:26] == 6'b001010) ? BIT_SET :
                               (insn[31:26] == 6'b010010) ? BIT_CLR : BIT_INV;
              end else begin
                ill = 1'b1;
              end
            end
            default: begin                                 // f3 = 5
              if (w ? (f7 == 7'd0 || f7 == 7'b0100000)
                    : (insn[31:26] == 6'd0 || insn[31:26] == 6'b010000)) begin   // SRLI/SRAI(W)
                d.alu = ctl(3'(G_SHIFT)); d.alu.word = w; d.alu.sh_arith = insn[30];
              end else if (xb && (w ? f7 == 7'b0110000 : insn[31:26] == 6'b011000)) begin
                d.alu = ctl(3'(G_SHIFT)); d.alu.word = w; d.alu.sh_rot = 1'b1;   // RORI(W)
              end else if (xb && !w && insn[31:20] == 12'h287) begin    // ORC.B
                d.alu = ctl(3'(G_UNARY)); d.alu.un_fn = UN_ORCB;
              end else if (xb && !w && insn[31:20] == 12'h6B8) begin    // REV8
                d.alu = ctl(3'(G_UNARY)); d.alu.un_fn = UN_REV8;
              end else if (xb && !w && insn[31:26] == 6'b010010) begin  // BEXTI
                d.alu = ctl(3'(G_UNARY)); d.alu.un_fn = UN_BEXT;
              end else begin
                ill = 1'b1;
              end
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
          end else if (f7 == 7'b0100000 && f3 == 3'd0) begin                // SUB(W)
            d.alu = ctl(3'(G_ADD)); d.alu.sub = 1'b1; d.alu.word = w;
          end else if (f7 == 7'b0100000 && f3 == 3'd5) begin                // SRA(W)
            d.alu = ctl(3'(G_SHIFT)); d.alu.sh_arith = 1'b1; d.alu.word = w;
          end else if (xb && !w && f7 == 7'b0100000 && f3 inside {3'd4, 3'd6, 3'd7}) begin
            d.alu = ctl(3'(G_LOGIC)); d.alu.lg_invb = 1'b1;                 // XNOR, ORN, ANDN
            d.alu.lg_fn = (f3 == 3'd4) ? LG_XOR : (f3 == 3'd6) ? LG_OR : LG_AND;
          end else if (xb && f7 == 7'b0010000 && f3 inside {3'd2, 3'd4, 3'd6}) begin
            d.alu = ctl(3'(G_ADD)); d.alu.zba_sh = f3[2:1]; d.alu.uw = w;  // SHnADD(.UW)
          end else if (xb && w && f7 == 7'b0000100 && f3 == 3'd0) begin  // ADD.UW
            d.alu = ctl(3'(G_ADD)); d.alu.uw = 1'b1;
          end else if (xb && w && f7 == 7'b0000100 && f3 == 3'd4 && insn[24:20] == 5'd0) begin
            d.alu = ctl(3'(G_UNARY)); d.alu.un_fn = UN_ZEXTH; d.rs2_en = 1'b0;   // ZEXT.H
          end else if (xb && !w && f7 == 7'b0000101 && f3[2]) begin       // MIN(U), MAX(U)
            d.cls = C_MUL; d.bcnt = 1'b1; d.mul_op = MUL_HU;                // P1's 2-cycle path
            d.alu.cmp_unsigned = f3[0]; d.alu.cmp_max = f3[1];
          end else if (xb && f7 == 7'b0110000 && (f3 == 3'd1 || f3 == 3'd5)) begin
            d.alu = ctl(3'(G_SHIFT)); d.alu.sh_rot = 1'b1; d.alu.sh_left = !f3[2]; d.alu.word = w;
          end else if (xb && !w && f3 == 3'd1 && f7 inside {7'b0010100, 7'b0100100, 7'b0110100}) begin
            d.alu = ctl(3'(G_BIT));                                         // BSET, BCLR, BINV
            d.alu.bit_fn = (f7 == 7'b0010100) ? BIT_SET : (f7 == 7'b0100100) ? BIT_CLR : BIT_INV;
          end else if (xb && !w && f7 == 7'b0100100 && f3 == 3'd5) begin  // BEXT
            d.alu = ctl(3'(G_UNARY)); d.alu.un_fn = UN_BEXT;
          end else if (EXT_ZICOND && !w && f7 == 7'b0000111 && (f3 == 3'd5 || f3 == 3'd7)) begin
            d.alu = ctl(3'(G_UNARY)); d.alu.un_fn = f3[1] ? UN_CZNEZ : UN_CZEQZ;   // CZERO.*
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
            unique casez (insn)
              32'h0000_0073: begin
                d.exc = 1'b1;
                d.exc_cause = (priv == PRIV_M) ? EXC_ECALL_M : (priv == PRIV_S) ? EXC_ECALL_S : EXC_ECALL_U;
              end
              32'h0010_0073: begin d.exc = 1'b1; d.exc_cause = EXC_BREAK; end
              32'h3020_0073: begin
                d.sys = SYS_MRET; d.serial = 1'b1;
                if (priv != PRIV_M) ill = 1'b1;
              end
              32'h1020_0073: begin                         // SRET
                d.sys = SYS_SRET; d.serial = 1'b1;
                if (!EXT_SU || priv == PRIV_U || (priv == PRIV_S && tsr)) ill = 1'b1;
              end
              32'h1050_0073: begin                         // WFI
                d.sys = SYS_WFI; d.serial = 1'b1;
                if (EXT_SU && priv != PRIV_M && (tw || priv == PRIV_U)) ill = 1'b1;
              end
              32'b0001001_?????_?????_000_00000_1110011,   // SFENCE.VMA
              32'b0001011_?????_?????_000_00000_1110011: begin   // SINVAL.VMA (Svinval)
                d.sys = SYS_SFENCE; d.serial = 1'b1;
                if (!EXT_SU || priv == PRIV_U || (priv == PRIV_S && tvm)) ill = 1'b1;
              end
              32'h1800_0073, 32'h1810_0073: begin          // SFENCE.W.INVAL, SFENCE.INVAL.IR
                d.sys = SYS_SFENCE; d.serial = 1'b1;
                if (!EXT_SU || priv == PRIV_U) ill = 1'b1;
              end
              default: ill = 1'b1;
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

    if (d.rd == 5'd0 && !d.rd_fp) d.rd_en = 1'b0;       // f0 is a register
    if (d.rs1 == 5'd0 && !d.rs1_fp) d.rs1_en = 1'b0;
    if (d.rs2 == 5'd0 && !d.rs2_fp) d.rs2_en = 1'b0;

    if (fault) begin
      d = '0;
      d.cls = C_SYS; d.exc = 1'b1; d.exc_cause = fault_pf ? EXC_IPAGE : EXC_IACCESS;
      d.exc_hi = fault_hi;
    end else if (ILL_Q ? ill_q : ill) begin
      d = '0;
      d.cls = C_SYS; d.exc = 1'b1; d.exc_cause = EXC_ILLEGAL;
    end
  end
endmodule
