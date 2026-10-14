// 1-cycle 64-bit integer ALU (plan §4.8): add/sub and their W forms, Zba (shNadd, .uw),
// shifts and rotates (with W forms, slli.uw), slt/sltu, min/max, and/or/xor/andn/orn/xnor,
// Zbs (bset/bclr/binv/bext), sext.b/sext.h/zext.h/rev8/orc.b, Zicond, lui (pass b).
// clz/ctz/cpop take a second cycle on ALU1 and are not here. Spike S3; combinational, the
// issue port registers the result. The compare flags serve branches (ctl.sub = 1).
//   MINMAX = 0: min/max/minu/maxu are left out of the 1-cycle result (they then go to the
//   2-cycle path with clz/ctz/cpop). Their select after the full carry chain is the
//   longest path through the ALU.
module tg_alu
  import tg_alu_pkg::*;
#(
  parameter bit MINMAX = 1'b1
) (
  input  alu_ctl_t     ctl,
  input  logic [63:0]  a,
  input  logic [63:0]  b,
  output logic [63:0]  res,
  output logic         eq,    // a == b
  output logic         lt,    // a < b, signed   (valid with ctl.sub)
  output logic         ltu    // a < b, unsigned (valid with ctl.sub)
);
  // ---- Adder (one CARRY8 chain): (a pre-shifted) + (b or ~b) + sub ----
  logic [63:0] a_uw, a_add, b_add, sum;
  logic        cout;
  assign a_uw  = ctl.uw ? {32'b0, a[31:0]} : a;
  assign a_add = a_uw << ctl.zba_sh;
  assign b_add = ctl.sub ? ~b : b;
  assign {cout, sum} = {1'b0, a_add} + {1'b0, b_add} + {64'b0, ctl.sub};

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

  // ---- Logic, bit ops, unary ----
  logic [63:0] lb, lg, bmask, bitr, un;
  assign lb = ctl.lg_invb ? ~b : b;
  always_comb begin
    unique case (ctl.lg_fn)
      LG_AND:  lg = a & lb;
      LG_OR:   lg = a | lb;
      default: lg = a ^ lb;
    endcase
  end
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
    unique case (ctl.un_fn)
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

  // ---- Result: AND-OR over the one-hot group ----
  logic [63:0] r_add, r_sh;
  assign r_add = ctl.word ? {{32{sum[31]}}, sum[31:0]} : sum;
  assign r_sh  = ctl.word ? {{32{sh_out[31]}}, sh_out[31:0]} : sh_out;
  always_comb begin
    res = '0;
    if (ctl.grp[G_ADD])   res |= r_add;
    if (ctl.grp[G_SHIFT]) res |= r_sh;
    if (ctl.grp[G_SLT])   res |= {63'b0, less};
    if (MINMAX && ctl.grp[G_MINMX]) res |= (less ^ ctl.cmp_max) ? a : b;
    if (ctl.grp[G_LOGIC]) res |= lg;
    if (ctl.grp[G_BIT])   res |= bitr;
    if (ctl.grp[G_UNARY]) res |= un;
    if (ctl.grp[G_PASSB]) res |= b;
  end
endmodule
