// 1-cycle 64-bit integer ALU (plan §4.8): add/sub and their W forms, Zba (shNadd, .uw),
// shifts and rotates (with W forms, slli.uw), slt/sltu, min/max, and/or/xor/andn/orn/xnor,
// Zbs (bset/bclr/binv/bext), sext.b/sext.h/zext.h/rev8/orc.b, Zicond, lui (pass b).
// clz/ctz/cpop take a second cycle on ALU1 and are not here. Spike S3; combinational, the
// issue port registers the result. The compare flags serve branches (ctl.sub = 1).
//   MINMAX = 0: min/max/minu/maxu are left out of the 1-cycle result (they then go to the
//   2-cycle path with clz/ctz/cpop). Their select after the full carry chain is the
//   longest path through the ALU.
// FPGA form (docs/perf/fpga_friendly.md T7, DR-123): the logic ops and lui go through the
// adder (a op b plus zero, or zero plus b: no carries), so the result is an encoded 4:1
// select of the adder, the shifter, the bit ops and the unary ops (slt takes the unary
// path's zeros above bit 0).
module tg_alu
  import tg_alu_pkg::*;
#(
  parameter bit MINMAX = 1'b1,
  parameter bit SIMPLE = 1'b0      // (scratch study) add/sub, logic, slt, lui only: no shifter, Zba, Zbs, unary
) (
  input  alu_ctl_t     ctl,
  input  logic [63:0]  a,
  input  logic [63:0]  b,
  output logic [63:0]  res,
  output logic         eq,    // a == b
  output logic         lt,    // a < b, signed   (valid with ctl.sub)
  output logic         ltu    // a < b, unsigned (valid with ctl.sub)
);
  // ---- Adder (one CARRY8 chain): x + y + sub ----
  // add/sub: x = a pre-shifted, y = b or ~b; logic: x = a op b, y = 0; lui: x = 0, y = b
  logic        is_lg, is_pb;
  logic [63:0] a_uw, a_add, lb, xx, yy, sum;
  logic        cout;
  assign is_lg = ctl.grp[G_LOGIC];
  assign is_pb = ctl.grp[G_PASSB];
  assign a_uw  = (!SIMPLE && ctl.uw) ? {32'b0, a[31:0]} : a;
  assign a_add = SIMPLE ? a_uw : a_uw << ctl.zba_sh;
  assign lb    = ctl.lg_invb ? ~b : b;
  always_comb begin
    unique case (ctl.lg_fn)
      LG_AND:  xx = is_lg ? (a & lb) : is_pb ? 64'd0 : a_add;
      LG_OR:   xx = is_lg ? (a | lb) : is_pb ? 64'd0 : a_add;
      default: xx = is_lg ? (a ^ lb) : is_pb ? 64'd0 : a_add;
    endcase
  end
  assign yy = is_lg ? 64'd0 : (ctl.sub ? ~b : b);
  assign {cout, sum} = {1'b0, xx} + {1'b0, yy} + {64'b0, ctl.sub && !is_lg};

  // a - b: borrow is !cout; signed less-than from the sign bits and the difference
  assign ltu = !cout;
  assign lt  = (a[63] == b[63]) ? sum[63] : a[63];
  assign eq  = (a == b);
  logic less;
  assign less = ctl.cmp_unsigned ? ltu : lt;

  // ---- Shifter: one right rotator; left shifts rotate right by 64 - n = 1 + ~n ----
  // W forms work on the low word: 5-bit amounts, rotates use the word twice, and the
  // result is sign-extended from bit 31 (the fill above bit 31 then does not matter).
  logic [5:0]  amt, ramt;
  logic [63:0] sh_in, rin, rot, keep, sh_out;
  always_comb begin
    if (ctl.word) begin
      amt = {1'b0, b[4:0]};
      if (ctl.sh_rot)        sh_in = {a[31:0], a[31:0]};
      else if (ctl.sh_arith) sh_in = {{32{a[31]}}, a[31:0]};
      else                   sh_in = {32'b0, a[31:0]};
    end else begin
      amt   = b[5:0];
      sh_in = ctl.uw ? {32'b0, a[31:0]} : a;     // slli.uw
    end
  end
  assign rin  = ctl.sh_left ? {sh_in[0], sh_in[63:1]} : sh_in;
  assign ramt = ctl.sh_left ? ~amt : amt;
  always_comb begin
    for (int i = 0; i < 64; i++) rot[i] = rin[6'(i) + ramt];   // rotate right by ramt
  end
  always_comb begin
    for (int i = 0; i < 64; i++)
      keep[i] = ctl.sh_left ? (6'(i) >= amt) : (6'(i) <= 6'd63 - amt);
  end
  logic fill;
  assign fill   = ctl.sh_arith && sh_in[63];
  assign sh_out = ctl.sh_rot ? rot : ((rot & keep) | (~keep & {64{fill}}));

  // ---- Bit ops, unary (and slt) ----
  logic [63:0] bmask, bitr, un;
  assign bmask = 64'd1 << b[5:0];
  always_comb begin
    unique case (ctl.bit_fn)
      BIT_SET: bitr = a | bmask;
      BIT_CLR: bitr = a & ~bmask;
      default: bitr = a ^ bmask;
    endcase
  end
  logic bz;
  assign bz = (b == 64'd0);
  always_comb begin
    unique case (ctl.grp[G_SLT] ? UN_BEXT : ctl.un_fn)     // slt: zeros above bit 0
      UN_SEXTB: un = {{56{a[7]}}, a[7:0]};
      UN_SEXTH: un = {{48{a[15]}}, a[15:0]};
      UN_ZEXTH: un = {48'b0, a[15:0]};
      UN_REV8:  for (int i = 0; i < 8; i++) un[8*i +: 8] = a[8*(7-i) +: 8];
      UN_ORCB:  for (int i = 0; i < 8; i++) un[8*i +: 8] = {8{|a[8*i +: 8]}};
      UN_BEXT:  un = {63'b0, a[b[5:0]]};
      UN_CZEQZ: un = bz ? 64'd0 : a;
      default:  un = bz ? a : 64'd0;     // czero.nez
    endcase
  end

  // ---- Result: an encoded 4:1 select; the W forms sign-extend above bit 31 ----
  // With MINMAX, min/max is a fifth source (after the full carry chain: the longest path).
  logic [1:0] rs;
  always_comb begin
    rs = 2'd0;                                               // adder: add, sub, logic, lui
    if (ctl.grp[G_SHIFT])                     rs = 2'd1;
    if (ctl.grp[G_BIT])                       rs = 2'd2;
    if (ctl.grp[G_UNARY] || ctl.grp[G_SLT])   rs = 2'd3;
  end
  always_comb begin
    if (SIMPLE) begin
      res = ctl.grp[G_SLT] ? 64'd0 : ctl.word ? {{32{sum[31]}}, sum[31:0]} : sum;   // slt: zeros above bit 0
    end else
    for (int i = 0; i < 64; i++) begin
      unique case (rs)
        2'd0:    res[i] = (i >= 32 && ctl.word) ? sum[31] : sum[i];
        2'd1:    res[i] = (i >= 32 && ctl.word) ? sh_out[31] : sh_out[i];
        2'd2:    res[i] = bitr[i];
        default: res[i] = un[i];
      endcase
    end
    if (ctl.grp[G_SLT]) res[0] = less;
    if (MINMAX && ctl.grp[G_MINMX]) res = (less ^ ctl.cmp_max) ? a : b;
  end
endmodule
