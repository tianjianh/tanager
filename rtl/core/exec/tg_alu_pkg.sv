// Control word of the 1-cycle integer ALU (plan §4.8), pre-decoded before EX so the ALU
// itself does no decoding. Spike S3; the core track owns the final encoding.
package tg_alu_pkg;
  // Result group, one-hot in alu_ctl_t.grp
  localparam int G_ADD   = 0;  // add, sub, shNadd[.uw], add.uw, auipc, jalr target
  localparam int G_SHIFT = 1;  // sll, srl, sra, rol, ror (and the W forms), slli.uw
  localparam int G_SLT   = 2;  // slt, sltu
  localparam int G_MINMX = 3;  // min, max, minu, maxu
  localparam int G_LOGIC = 4;  // and, or, xor, andn, orn, xnor
  localparam int G_BIT   = 5;  // bset, bclr, binv
  localparam int G_UNARY = 6;  // sext.b, sext.h, zext.h, rev8, orc.b, bext, czero.*
  localparam int G_PASSB = 7;  // lui, li: the result is operand b
  localparam int NGRP    = 8;

  typedef enum logic [2:0] {
    UN_SEXTB, UN_SEXTH, UN_ZEXTH, UN_REV8, UN_ORCB, UN_BEXT, UN_CZEQZ, UN_CZNEZ
  } alu_un_e;

  typedef enum logic [1:0] { LG_AND, LG_OR, LG_XOR } alu_lg_e;
  typedef enum logic [1:0] { BIT_SET, BIT_CLR, BIT_INV } alu_bit_e;

  typedef struct packed {
    logic [NGRP-1:0] grp;      // result group, one-hot
    logic       word;          // W op: 32-bit result, sign-extended
    logic       sub;           // adder: b inverted, carry in (sub; compares use it too)
    logic [1:0] zba_sh;        // adder: a shifted left by 0..3 (shNadd)
    logic       uw;            // a zero-extended from 32 bits (.uw forms)
    logic       sh_left;       // shifter: sll, rol
    logic       sh_arith;      // shifter: sra
    logic       sh_rot;        // shifter: rol, ror
    logic       cmp_unsigned;  // slt/min/max: unsigned compare
    logic       cmp_max;       // min/max: take the larger
    alu_lg_e    lg_fn;
    logic       lg_invb;       // andn, orn, xnor
    alu_bit_e   bit_fn;
    alu_un_e    un_fn;
  } alu_ctl_t;
endpackage
