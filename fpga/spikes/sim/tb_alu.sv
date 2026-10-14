// Random test of tg_alu against a reference written from the RISC-V unprivileged spec
// (RV64I/M base ops, Zba, Zbb, Zbs, Zicond). to_ctl() is the decode the core's DE stage
// would do; it documents the control encoding.
//   Vtb_alu +seed=<n> +iters=<n>
module tb_alu #(
  parameter bit MINMAX = 1'b1   // 0: tg_alu without min/max; those ops are not generated
);
  import tg_alu_pkg::*;

  typedef enum int {
    ADD, SUB, ADDW, SUBW, SLL, SRL, SRA, SLLW, SRLW, SRAW, ROL, ROR, ROLW, RORW,
    SLT, SLTU, MIN, MAX, MINU, MAXU, AND, OR, XOR, ANDN, ORN, XNOR,
    SH1ADD, SH2ADD, SH3ADD, SH1ADDUW, SH2ADDUW, SH3ADDUW, ADDUW, SLLIUW,
    BSET, BCLR, BINV, BEXT, SEXTB, SEXTH, ZEXTH, REV8, ORCB, CZEQZ, CZNEZ, LUI, NOPS
  } op_e;

  function automatic alu_ctl_t to_ctl(input op_e op);
    alu_ctl_t c;
    c = '0;
    case (op)
      ADD, ADDW:   c.grp[G_ADD] = 1'b1;
      SUB, SUBW:   begin c.grp[G_ADD] = 1'b1; c.sub = 1'b1; end
      SH1ADD, SH2ADD, SH3ADD, SH1ADDUW, SH2ADDUW, SH3ADDUW, ADDUW: c.grp[G_ADD] = 1'b1;
      SLL, SRL, SRA, SLLW, SRLW, SRAW, ROL, ROR, ROLW, RORW, SLLIUW: c.grp[G_SHIFT] = 1'b1;
      SLT, SLTU:   begin c.grp[G_SLT] = 1'b1; c.sub = 1'b1; end
      MIN, MAX, MINU, MAXU: begin c.grp[G_MINMX] = 1'b1; c.sub = 1'b1; end
      AND, OR, XOR, ANDN, ORN, XNOR: c.grp[G_LOGIC] = 1'b1;
      BSET, BCLR, BINV: c.grp[G_BIT] = 1'b1;
      BEXT, SEXTB, SEXTH, ZEXTH, REV8, ORCB, CZEQZ, CZNEZ: c.grp[G_UNARY] = 1'b1;
      LUI:         c.grp[G_PASSB] = 1'b1;
      default: ;
    endcase
    c.word     = op inside {ADDW, SUBW, SLLW, SRLW, SRAW, ROLW, RORW};
    c.zba_sh   = (op inside {SH1ADD, SH1ADDUW}) ? 2'd1 : (op inside {SH2ADD, SH2ADDUW}) ? 2'd2 :
                 (op inside {SH3ADD, SH3ADDUW}) ? 2'd3 : 2'd0;
    c.uw       = op inside {SH1ADDUW, SH2ADDUW, SH3ADDUW, ADDUW, SLLIUW};
    c.sh_left  = op inside {SLL, SLLW, ROL, ROLW, SLLIUW};
    c.sh_arith = op inside {SRA, SRAW};
    c.sh_rot   = op inside {ROL, ROR, ROLW, RORW};
    c.cmp_unsigned = op inside {SLTU, MINU, MAXU};
    c.cmp_max  = op inside {MAX, MAXU};
    c.lg_fn    = (op inside {AND, ANDN}) ? LG_AND : (op inside {OR, ORN}) ? LG_OR : LG_XOR;
    c.lg_invb  = op inside {ANDN, ORN, XNOR};
    c.bit_fn   = (op == BSET) ? BIT_SET : (op == BCLR) ? BIT_CLR : BIT_INV;
    case (op)
      SEXTB: c.un_fn = UN_SEXTB;  SEXTH: c.un_fn = UN_SEXTH;  ZEXTH: c.un_fn = UN_ZEXTH;
      REV8:  c.un_fn = UN_REV8;   ORCB:  c.un_fn = UN_ORCB;   BEXT:  c.un_fn = UN_BEXT;
      CZEQZ: c.un_fn = UN_CZEQZ;  CZNEZ: c.un_fn = UN_CZNEZ;
      default: c.un_fn = UN_SEXTB;
    endcase
    return c;
  endfunction

  function automatic logic [63:0] sext32(input logic [31:0] x);
    return {{32{x[31]}}, x};
  endfunction

  function automatic logic [63:0] ref_op(input op_e op, input logic [63:0] a, input logic [63:0] b);
    logic [63:0] r;
    logic [31:0] w;
    int s;
    case (op)
      ADD:   r = a + b;
      SUB:   r = a - b;
      ADDW:  r = sext32(a[31:0] + b[31:0]);
      SUBW:  r = sext32(a[31:0] - b[31:0]);
      SLL:   r = a << b[5:0];
      SRL:   r = a >> b[5:0];
      SRA:   r = $signed(a) >>> b[5:0];
      SLLW:  r = sext32(a[31:0] << b[4:0]);
      SRLW:  r = sext32(a[31:0] >> b[4:0]);
      SRAW:  begin w = $signed(a[31:0]) >>> b[4:0]; r = sext32(w); end
      ROL:   begin s = int'(b[5:0]); r = (a << s) | (s == 0 ? 64'd0 : a >> (64 - s)); end
      ROR:   begin s = int'(b[5:0]); r = (a >> s) | (s == 0 ? 64'd0 : a << (64 - s)); end
      ROLW:  begin s = int'(b[4:0]); w = (a[31:0] << s) | (s == 0 ? 32'd0 : a[31:0] >> (32 - s)); r = sext32(w); end
      RORW:  begin s = int'(b[4:0]); w = (a[31:0] >> s) | (s == 0 ? 32'd0 : a[31:0] << (32 - s)); r = sext32(w); end
      SLT:   r = {63'b0, $signed(a) < $signed(b)};
      SLTU:  r = {63'b0, a < b};
      MIN:   r = ($signed(a) < $signed(b)) ? a : b;
      MAX:   r = ($signed(a) < $signed(b)) ? b : a;
      MINU:  r = (a < b) ? a : b;
      MAXU:  r = (a < b) ? b : a;
      AND:   r = a & b;
      OR:    r = a | b;
      XOR:   r = a ^ b;
      ANDN:  r = a & ~b;
      ORN:   r = a | ~b;
      XNOR:  r = ~(a ^ b);
      SH1ADD: r = (a << 1) + b;
      SH2ADD: r = (a << 2) + b;
      SH3ADD: r = (a << 3) + b;
      SH1ADDUW: r = ({32'b0, a[31:0]} << 1) + b;
      SH2ADDUW: r = ({32'b0, a[31:0]} << 2) + b;
      SH3ADDUW: r = ({32'b0, a[31:0]} << 3) + b;
      ADDUW: r = {32'b0, a[31:0]} + b;
      SLLIUW: r = {32'b0, a[31:0]} << b[5:0];
      BSET:  r = a | (64'd1 << b[5:0]);
      BCLR:  r = a & ~(64'd1 << b[5:0]);
      BINV:  r = a ^ (64'd1 << b[5:0]);
      BEXT:  r = {63'b0, a[b[5:0]]};
      SEXTB: r = {{56{a[7]}}, a[7:0]};
      SEXTH: r = {{48{a[15]}}, a[15:0]};
      ZEXTH: r = {48'b0, a[15:0]};
      REV8:  for (int i = 0; i < 8; i++) r[8*i +: 8] = a[8*(7-i) +: 8];
      ORCB:  for (int i = 0; i < 8; i++) r[8*i +: 8] = (a[8*i +: 8] != 0) ? 8'hff : 8'h00;
      CZEQZ: r = (b == 0) ? 64'd0 : a;
      CZNEZ: r = (b != 0) ? 64'd0 : a;
      LUI:   r = b;
      default: r = 'x;
    endcase
    return r;
  endfunction

  alu_ctl_t ctl;
  logic [63:0] a, b, res;
  logic eq, lt, ltu;
  tg_alu #(.MINMAX(MINMAX)) dut (.ctl, .a, .b, .res, .eq, .lt, .ltu);

  function automatic logic [63:0] rnd64();
    logic [63:0] v;
    v = {$urandom, $urandom};
    case ($urandom % 8)
      0: v = 64'd0;
      1: v = 64'hffff_ffff_ffff_ffff;
      2: v = {1'b1, 63'd0};
      3: v = 64'(int'($urandom % 70));          // small, shift amounts
      4: v = {32'h0, v[31:0]};
      default: ;
    endcase
    return v;
  endfunction

  int ncov [NOPS];
  initial begin
    int seed = 1, iters = 200000, errors = 0;
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("iters=%d", iters));
    void'($urandom(seed));
    for (int i = 0; i < iters; i++) begin
      automatic op_e op = op_e'($urandom % int'(NOPS));
      automatic logic [63:0] want;
      if (!MINMAX && op inside {MIN, MAX, MINU, MAXU}) continue;
      ncov[op]++;
      ctl = to_ctl(op);
      a = rnd64();
      b = rnd64();
      #1;
      want = ref_op(op, a, b);
      if (res !== want) begin
        errors++;
        if (errors <= 10) $display("ERROR %s a=%h b=%h got %h want %h", op.name(), a, b, res, want);
      end
      if (ctl.sub && (eq !== (a == b) || ltu !== (a < b) || lt !== ($signed(a) < $signed(b)))) begin
        errors++;
        if (errors <= 10) $display("ERROR flags %s a=%h b=%h eq %b lt %b ltu %b", op.name(), a, b, eq, lt, ltu);
      end
    end
    for (int k = 0; k < int'(NOPS); k++)
      if (ncov[k] == 0 && (MINMAX || !(op_e'(k) inside {MIN, MAX, MINU, MAXU}))) begin
      errors++;
      $display("ERROR op %s never tested", op_e'(k));
    end
    if (errors == 0) $display("PASS tb_alu (%0d ops)", iters);
    else $display("FAIL tb_alu: %0d errors", errors);
    $finish;
  end
endmodule
