// Divide/sqrt unit: Goldschmidt iteration on two 60 x 60-bit multipliers with a seed ROM,
// small DSP multipliers for the correction terms and a remainder step for correct rounding
// (docs/spec/fpu.md, "Divide/sqrt unit"; bit-accurate model: tests/unit/fpu/gs_model.h).
//
// Operations own one of four ring slots, one per multiplier phase (cycle mod 4). A round is c0
// (operands formed here and registered in the multipliers) and c1..c3 (multiplier stages);
// r1..r4 carry each slot's state alongside, so r4 and the products are available in c0.
//   t      request accepted (registered)
//   t+1    S1: unpack, normalise, specials, seed-ROM address
//   t+2    S2: exponent, operand scaling (ROM read)
//   t+3    S3: SM0 (D0 approximation or y0^2)
//   t+4    c0 of round 1; rounds every 4 cycles; SMa..SMc finish e23 for round 2
//   ...    the remainder round, then F0 (in that slot's next c0) and F1 into the output queue
module tg_fpu_div
  import tg_pkg::*;
  import tg_fpu_pkg::*;
  import tg_fpu_util_pkg::*;
(
  input  logic       clk,
  input  logic       rst,
  input  logic       valid_i,
  input  fpu_req_t   req_i,
  output logic       ready_o,
  output logic       valid_o,
  output fpu_resp_t  resp_o,
  input  logic       ready_i
);
  localparam int QF = 58;                          // Q2.58 iteration values
  localparam logic [59:0] ONE = 60'(1) << QF;
  localparam int OUT_DEPTH = 4;

  typedef enum logic [1:0] { SP_NONE, SP_NAN, SP_INF, SP_ZERO } spec_e;

  typedef struct packed {
    logic        sqrt;
    logic        dbl;
    rm_e         rm;
    logic [FPU_TAG_W-1:0] tag;
    spec_e       spec;
    logic        nv, dz;       // flags of a special result
    logic        sign;
    logic [12:0] eq;           // signed: the result is q * 2^eq with q in [1, 2)
  } info_t;

  // ------------------------------------------------------------------------------------------
  // S1: unpack, normalise, specials, seed-ROM address
  // ------------------------------------------------------------------------------------------
  logic     s1_v;
  fpu_req_t s1_q;
  always_ff @(posedge clk) begin
    if (rst) s1_v <= 1'b0;
    else     s1_v <= valid_i && ready_o;
    if (valid_i && ready_o) s1_q <= req_i;
  end

  logic    s1_dbl, s1_sqrt;
  fp_unp_t ua, ub;
  assign s1_dbl  = (s1_q.fmt == FMT_D);
  assign s1_sqrt = (s1_q.op == FOP_FSQRT);
  assign ua = unpack(s1_q.a, s1_dbl);
  assign ub = unpack(s1_q.b, s1_dbl);

  logic [5:0]  lza, lzb;
  tg_fpu_lzc #(.W(53)) u_lza (.x(ua.sig), .cnt(lza));
  tg_fpu_lzc #(.W(53)) u_lzb (.x(ub.sig), .cnt(lzb));
  logic [52:0] ma, mb;                             // normalised significands (zero stays zero)
  assign ma = ua.sig << lza;
  assign mb = ub.sig << lzb;

  info_t s1_info;
  always_comb begin
    s1_info      = '0;
    s1_info.sqrt = s1_sqrt;
    s1_info.dbl  = s1_dbl;
    s1_info.rm   = s1_q.rm;
    s1_info.tag  = s1_q.tag;
    s1_info.sign = s1_sqrt ? 1'b0 : (ua.sign ^ ub.sign);
    s1_info.spec = SP_NONE;
    if (s1_sqrt) begin
      if (ua.nan)                  begin s1_info.spec = SP_NAN;  s1_info.nv = ua.snan; end
      else if (ua.zero)            begin s1_info.spec = SP_ZERO; s1_info.sign = ua.sign; end
      else if (ua.sign)            begin s1_info.spec = SP_NAN;  s1_info.nv = 1'b1; end
      else if (ua.inf)             begin s1_info.spec = SP_INF; end
    end else begin
      if (ua.nan || ub.nan)        begin s1_info.spec = SP_NAN;  s1_info.nv = ua.snan || ub.snan; end
      else if ((ua.inf && ub.inf) || (ua.zero && ub.zero))
                                   begin s1_info.spec = SP_NAN;  s1_info.nv = 1'b1; end
      else if (ua.inf)             begin s1_info.spec = SP_INF; end
      else if (ub.zero)            begin s1_info.spec = SP_INF;  s1_info.dz = 1'b1; end
      else if (ua.zero || ub.inf)  begin s1_info.spec = SP_ZERO; end
    end
  end

  // Exponent fields after normalisation (double bias, may go below 1)
  logic [12:0] s1_ea, s1_eb;
  assign s1_ea = 13'(ua.exp) - 13'(lza);
  assign s1_eb = 13'(ub.exp) - 13'(lzb);
  logic s1_odd;                                     // unbiased exponent of a is odd
  assign s1_odd = !s1_ea[0];

  logic [10:0] rom_addr;
  assign rom_addr = s1_sqrt ? {1'b1, s1_odd, ma[51:43]} : {1'b0, mb[51:42]};
  logic [8:0] rom_data;
  tg_fpu_seed_rom u_rom (.clk, .addr(rom_addr), .data(rom_data));

  logic        s2_v;
  info_t       s2_info;
  logic [52:0] s2_ma, s2_mb;
  logic [12:0] s2_ea, s2_eb;
  logic        s2_odd;
  always_ff @(posedge clk) begin
    if (rst) s2_v <= 1'b0;
    else     s2_v <= s1_v;
    s2_info <= s1_info;
    s2_ma <= ma; s2_mb <= mb; s2_ea <= s1_ea; s2_eb <= s1_eb; s2_odd <= s1_odd;
  end

  // ------------------------------------------------------------------------------------------
  // S2: scaling (q and the root in [1, 2)) and the result exponent
  // ------------------------------------------------------------------------------------------
  logic        lt;
  info_t       s2_info_x;
  logic [59:0] s2_opa, s2_opb;
  always_comb begin
    logic signed [12:0] eu;
    lt = s2_ma < s2_mb;
    s2_info_x = s2_info;
    eu = $signed(s2_ea) - 13'sd1023;                // unbiased exponent of a
    if (s2_info.sqrt) begin
      s2_opa = s2_odd ? {s2_ma, 7'b0} : {1'b0, s2_ma, 6'b0};       // x in [1, 4)
      s2_info_x.eq = 13'((eu - $signed({12'b0, s2_odd})) >>> 1);
    end else begin
      s2_opa = lt ? {s2_ma, 7'b0} : {1'b0, s2_ma, 6'b0};           // A in [1, 4), A / mb in [1, 2)
      s2_info_x.eq = 13'($signed(s2_ea) - $signed(s2_eb) - $signed({12'b0, lt}));
    end
    s2_opb = {1'b0, s2_mb, 6'b0};
  end

  logic        s3_v;
  info_t       s3_info;
  logic [59:0] s3_opa, s3_opb;
  always_ff @(posedge clk) begin
    if (rst) s3_v <= 1'b0;
    else     s3_v <= s2_v;
    s3_info <= s2_info_x;
    s3_opa <= s2_opa;
    s3_opb <= s2_opb;
  end

  // ------------------------------------------------------------------------------------------
  // S3: seed and SM0 (division: mb[52:29] * s, the approximate D0; square root: y0^2)
  // ------------------------------------------------------------------------------------------
  logic [9:0]  seed10;
  assign seed10 = {1'b1, rom_data};
  logic [33:0] sm0_q;
  always_ff @(posedge clk) begin
    if (s3_info.sqrt) sm0_q <= 34'(seed10) * 34'(seed10);
    else              sm0_q <= 34'(s3_opb[58:35]) * 34'(seed10);     // mb[52:29]
  end

  logic        s4_v;
  info_t       s4_info;
  logic [59:0] s4_opa, s4_opb;
  logic [9:0]  s4_seed;
  always_ff @(posedge clk) begin
    if (rst) s4_v <= 1'b0;
    else     s4_v <= s3_v;
    s4_info <= s3_info;
    s4_opa  <= s3_opa;
    s4_opb  <= s3_opb;
    s4_seed <= seed10;
  end

  // ------------------------------------------------------------------------------------------
  // SMa..SMc: e0 ~ 1 - D0 (or 1 - x y0^2), e2 ~ e0^2 and e23 = e2 + e3 (division) or
  // 3/8 e2 + 5/16 e3 (square root), in lockstep with the slot: an operation entering in t+4 is
  // in r1 during t+5, r3 during t+7 and r4 during t+8, the c0 of its round 2, when e23 is ready
  // (gs_model.h, small_terms).
  // ------------------------------------------------------------------------------------------
  logic [42:0]        sma_lo_q;                     // t+4: x[59:34] * y0^2 in two tiles
  logic [28:0]        sma_hi_q;
  logic signed [26:0] e0d_q;                        // t+4: division e0, Q.33
  always_ff @(posedge clk) begin
    sma_lo_q <= 43'(s4_opa[59:34]) * 43'(sm0_q[16:0]);
    sma_hi_q <= 29'(s4_opa[59:34]) * 29'(sm0_q[19:17]);
    e0d_q    <= 27'($signed(35'(64'd1 << 33)) - $signed({1'b0, sm0_q}));
  end

  logic signed [26:0] e0_q, e0_d_q;                 // t+5, t+6: e0 in Q.33
  logic signed [46:0] e0s;
  always_comb begin
    logic [45:0] u0a;                               // x * y0^2 approximation, Q2.44
    u0a = 46'(sma_lo_q) + (46'(sma_hi_q) << 17);
    e0s = $signed(47'(64'd1 << 44)) - $signed({1'b0, u0a});
  end
  always_ff @(posedge clk) begin
    e0_q   <= r1_q.info.sqrt ? 27'(e0s >>> 11) : e0d_q;
    e0_d_q <= e0_q;
  end

  logic signed [44:0] smb_q;                        // t+6: e0 * (e0 >>> 9), Q.57
  always_ff @(posedge clk) begin
    smb_q <= 45'($signed(e0_q) * $signed(18'(e0_q >>> 9)));
  end

  logic signed [46:0] smc_q;                        // t+7: e3 + e2, or 5 e3 + 6 e2 (x 1/16 later)
  logic [16:0]        e2hi;
  logic signed [45:0] e2;
  logic signed [20:0] smc_a;
  logic signed [46:0] smc_c;
  always_comb begin
    e2    = 46'(smb_q) <<< 1;                       // Q.58, non-negative
    e2hi  = e2[40:24];                              // Q.34
    smc_a = r3_q.info.sqrt ? $signed(21'(e2hi) * 21'sd5) : $signed(21'(e2hi));
    smc_c = r3_q.info.sqrt ? $signed(47'(e2) * 47'sd6) : $signed(47'(e2));
  end
  always_ff @(posedge clk) begin
    smc_q <= 47'($signed(smc_a) * $signed(18'(e0_d_q >>> 9))) + smc_c;
  end
  logic signed [42:0] e23;                          // t+8, Q2.58
  assign e23 = r4_q.info.sqrt ? 43'(smc_q >>> 4) : 43'(smc_q);

  // ------------------------------------------------------------------------------------------
  // Ring
  // ------------------------------------------------------------------------------------------
  typedef struct packed {
    info_t       info;
    logic [2:0]  rnd;          // round in the multipliers
    logic [59:0] opa;          // A or x
    logic [59:0] opb;          // division: mb; square root: q1 from round 3
    logic [9:0]  seed;
    logic [59:0] c;            // candidate of the remainder round
  } slot_t;

  logic  r1_v, r2_v, r3_v, r4_v, r1_vd;
  slot_t r1_q, r2_q, r3_q, r4_q, r1_d;

  logic [119:0] p1, p2;
  logic [59:0]  x1, y1, x2, y2;
  tg_fpu_div_mul u_m1 (.clk, .x(x1), .y(y1), .p(p1));
  tg_fpu_div_mul u_m2 (.clk, .x(x2), .y(y2), .p(p2));

  logic [59:0] m1, m2;
  assign m1 = p1[117:58];
  assign m2 = p2[117:58];

  function automatic logic [2:0] n_last(input logic sqrt, input logic dbl);
    return sqrt ? (dbl ? 3'd5 : 3'd3) : (dbl ? 3'd4 : 3'd3);
  endfunction

  // Output credits: queue entries plus the result in F1.
  logic [2:0] q_count;
  logic       f1_v;
  logic       credit_ok;
  assign credit_ok = (32'(q_count) + 32'(f1_v)) < OUT_DEPTH;

  logic fin, to_f0, cont;
  assign fin   = r4_v && (r4_q.rnd == n_last(r4_q.info.sqrt, r4_q.info.dbl));
  assign to_f0 = fin && credit_ok;
  assign cont  = r4_v && !to_f0;

  // A request accepted now enters the slot that is in c0 now, four cycles later.
  assign ready_o = !rst && !s4_v && !cont;

  always_comb begin
    logic [2:0]  nn;
    logic [59:0] seedq, cand, fac, grid;
    r1_d  = r4_q;
    r1_vd = 1'b0;
    x1 = '0; y1 = '0; x2 = '0; y2 = '0;
    grid  = r4_q.info.dbl ? 60'(1) << 5 : 60'(1) << 34;
    seedq = {2'b0, r4_q.seed, 48'b0};
    nn    = fin ? r4_q.rnd : r4_q.rnd + 3'd1;
    cand  = fin ? r4_q.c : (m1 + (grid >> 1)) & ~(grid - 60'd1);
    fac   = '0;
    if (s4_v) begin
      // round 1: N0 = A s, D0 = mb s; or q0 = x y0, u0 = x y0^2
      r1_vd     = 1'b1;
      r1_d      = '0;
      r1_d.info = s4_info;
      r1_d.rnd  = 3'd1;
      r1_d.opa  = s4_opa;
      r1_d.opb  = s4_opb;
      r1_d.seed = s4_seed;
      x1 = s4_opa;
      y1 = {2'b0, s4_seed, 48'b0};
      x2 = s4_info.sqrt ? s4_opa : s4_opb;
      y2 = s4_info.sqrt ? {2'b0, sm0_q[19:0], 38'b0} : {2'b0, s4_seed, 48'b0};
    end else if (cont) begin
      r1_vd    = 1'b1;
      r1_d.rnd = nn;
      if (nn == n_last(r4_q.info.sqrt, r4_q.info.dbl)) begin
        // remainder round: mb * c or c * c (repeated while the output queue is full)
        r1_d.c = cand;
        x1 = r4_q.info.sqrt ? cand : r4_q.opb;
        y1 = cand;
      end else if (!r4_q.info.sqrt) begin
        if (nn == 3'd2) fac = 60'(2 * ONE) - m2 + 60'(e23);   // ~ 1/D0 to third order
        else            fac = 60'(2 * ONE) - m2;              // 2 - D1
        x1 = m1; y1 = fac;
        x2 = m2; y2 = fac;
      end else begin
        unique case (nn)
          3'd2: begin                                // P = (3 - u0)/2 + 3/8 e2 + 5/16 e3
            fac = ((60'(3 * ONE) - m2) >> 1) + 60'(e23);
            x1 = m1; y1 = fac;
            x2 = seedq; y2 = fac;
          end
          3'd3: begin                                // w1 = q1 y1; keep q1
            r1_d.opb = m1;
            x1 = m1; y1 = m2;
          end
          default: begin                             // q2 = q1 (3 - w1)/2
            fac = (60'(3 * ONE) - m1) >> 1;
            x1 = r4_q.opb; y1 = fac;
          end
        endcase
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      r1_v <= 1'b0; r2_v <= 1'b0; r3_v <= 1'b0; r4_v <= 1'b0;
    end else begin
      r1_v <= r1_vd; r2_v <= r1_v; r3_v <= r2_v; r4_v <= r3_v;
    end
    r1_q <= r1_d; r2_q <= r1_q; r3_q <= r2_q; r4_q <= r3_q;
  end

  // ------------------------------------------------------------------------------------------
  // F0: remainder sign and zero test; (T, G, S) at normal precision
  // ------------------------------------------------------------------------------------------
  info_t       f1_info;
  logic [52:0] f1_t;
  logic        f1_g, f1_s;
  logic [95:0] rem;
  logic [59:0] f;
  always_comb begin
    logic [59:0] grid;
    rem  = {r4_q.opa[37:0], 58'b0} - p1[95:0];
    grid = r4_q.info.dbl ? 60'(1) << 5 : 60'(1) << 34;
    f    = rem[95] ? r4_q.c - grid : r4_q.c;
  end
  always_ff @(posedge clk) begin
    if (rst) f1_v <= 1'b0;
    else     f1_v <= to_f0;
    f1_info <= r4_q.info;
    f1_t    <= r4_q.info.dbl ? f[58:6] : {29'b0, f[58:35]};
    f1_g    <= r4_q.info.dbl ? f[5] : f[34];
    f1_s    <= rem != '0;
  end

  // ------------------------------------------------------------------------------------------
  // F1: denormalise (division below 2^emin), round, pack, specials
  // ------------------------------------------------------------------------------------------
  fpu_resp_t f1_resp;
  always_comb begin
    logic dbl, s, tt0, gg, ss, inc, inexact, tiny, ovf, tmax;
    logic signed [12:0] eq, emin, k;
    logic [53:0] xg;
    logic [5:0]  ks;
    logic [52:0] tt;
    logic [62:0] pk_d;
    logic [30:0] pk_s;
    logic [12:0] fbase;
    dbl  = f1_info.dbl;
    s    = f1_info.sign;
    eq   = $signed(f1_info.eq);
    emin = dbl ? -13'sd1022 : -13'sd126;
    // denormalising shift with sticky
    k    = emin - eq;
    ks   = (eq >= emin) ? 6'd0 : (k > 13'sd55) ? 6'd55 : 6'(k);
    xg   = {f1_t, f1_g} >> ks;
    tt   = xg[53:1];
    gg   = xg[0];
    ss   = f1_s || (({f1_t, f1_g} & ((54'(1) << ks) - 54'd1)) != '0);
    tt0  = tt[0];
    inc  = round_up(f1_info.rm, s, tt0, gg, ss);
    inexact = gg || ss;
    tmax = dbl ? (&f1_t[52:0]) : (&f1_t[23:0]);
    tiny = (eq < emin) && !(eq == emin - 13'sd1 && tmax && round_up(f1_info.rm, s, 1'b1, f1_g, f1_s));
    // pack {exponent - 1 + hidden, fraction} + increment (exponent field 0 when subnormal)
    fbase = (eq < emin) ? 13'd0 : 13'(eq + (dbl ? 13'sd1022 : 13'sd126));
    pk_d = ({50'b0, fbase} << 52) + {10'b0, tt} + 63'(inc);
    pk_s = ({18'b0, fbase} << 23) + {7'b0, tt[23:0]} + 31'(inc);
    if (dbl) ovf = (eq > 13'sd1023) || (&pk_d[62:52]);
    else     ovf = (eq > 13'sd127)  || (&pk_s[30:23]);
    f1_resp.tag = f1_info.tag;
    f1_resp.int_dest = 1'b0;
    f1_resp.fflags = '0;
    unique case (f1_info.spec)
      SP_NAN:  begin f1_resp.result = cnan(dbl); f1_resp.fflags[FL_NV] = f1_info.nv; end
      SP_INF:  begin f1_resp.result = inf_value(dbl, s); f1_resp.fflags[FL_DZ] = f1_info.dz; end
      SP_ZERO: f1_resp.result = zero_value(dbl, s);
      default: begin
        if (ovf) begin
          f1_resp.result = ovf_value(dbl, s, ovf_to_inf(f1_info.rm, s));
          f1_resp.fflags[FL_OF] = 1'b1;
          f1_resp.fflags[FL_NX] = 1'b1;
        end else begin
          f1_resp.result = dbl ? {s, pk_d} : box_s({s, pk_s});
          f1_resp.fflags[FL_NX] = inexact;
          f1_resp.fflags[FL_UF] = tiny && inexact;
        end
      end
    endcase
  end

  // ------------------------------------------------------------------------------------------
  // Output queue
  // ------------------------------------------------------------------------------------------
  logic q_in_ready;
  tg_fifo #(.T(fpu_resp_t), .DEPTH(OUT_DEPTH)) u_outq (
    .clk, .rst,
    .in_valid (f1_v), .in_ready (q_in_ready), .in_data (f1_resp),
    .out_valid (valid_o), .out_ready (ready_i), .out_data (resp_o),
    .count (q_count)
  );

  logic unused;
  assign unused = ^{s1_q.c, s1_q.src_fmt, s1_q.ifmt, ua.inf, ub.sub, ua.sub, p1[119:118],
                    p2[119:118], p2[57:0], q_in_ready, r2_q.info, r3_q.rnd, f[59], f[4:0],
                    f1_info.sqrt};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (valid_i && ready_o) begin
        assert (req_i.fmt != FMT_H) else $error("tg_fpu_div: FMT_H is not implemented");
        assert (req_i.op inside {FOP_FDIV, FOP_FSQRT})
          else $error("tg_fpu_div: operation %0d belongs to another unit", req_i.op);
      end
      assert (!(s4_v && cont)) else $error("tg_fpu_div: slot collision");
      assert (!f1_v || q_in_ready) else $error("tg_fpu_div: output queue overflow");
    end
  end
`endif

endmodule
