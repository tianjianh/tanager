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
//   ...    the remainder round, then F0 (in that slot's next c0), F1 and F2 into the output queue
module tg_fpu_div
  import tg_pkg::*;
  import tg_fpu_pkg::*;
  import tg_fpu_util_pkg::*;
#(
  // Tag bits the user reads: the output queue keeps only these, and the response returns the
  // rest as zero (requests must leave them zero). tg_fp_exec tags a divide with its table index.
  parameter int TAG_W = FPU_TAG_W
) (
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


  // ------------------------------------------------------------------------------------------
  // S1: unpack, normalise, specials, seed-ROM address
  // ------------------------------------------------------------------------------------------
  // Pipeline and ring registers stay flip-flops (shreg_extract): as shift-register LUTs they
  // would cost LUTs, the scarce resource, to save flip-flops (docs/spec/fpu.md, "Timing and area").
  logic     s1_v;
  (* shreg_extract = "no" *) fpu_req_t s1_q;
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

  div_info_t s1_info;
  assign s1_info = div_info_init(s1_sqrt, s1_dbl, s1_q.rm, s1_q.tag, ua, ub);

  // Exponent fields after normalisation (double bias, may go below 1)
  logic [12:0] s1_ea, s1_eb;
  assign s1_ea = 13'(ua.exp) - 13'(lza);
  assign s1_eb = 13'(ub.exp) - 13'(lzb);
  logic s1_odd;                                     // unbiased exponent of a is odd
  assign s1_odd = !s1_ea[0];

  logic [10:0] rom_addr;
  assign rom_addr = s1_sqrt ? {1'b1, s1_odd, ma[51:43]} : {1'b0, mb[51:42]};
  logic [8:0] rom_data;
  // Seed ROM in one BRAM18 (2K x 9, docs/spec/fpu.md "Seed ROM"): address and output registers
  // in the block RAM, so the data appears two cycles after the address.
  tg_rom #(.DEPTH(2048), .WIDTH(9), .PRIM("block"), .RD_LAT(2), .INIT(tg_fpu_seed_pkg::SEED_ROM)) u_rom (
    .clk, .re(1'b1), .raddr(rom_addr), .rdata(rom_data));

  logic        s2_v;
  (* shreg_extract = "no" *) div_info_t s2_info;
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
  div_info_t       s2_info_x;
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
  (* shreg_extract = "no" *) div_info_t s3_info;
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
  div_info_t       s4_info;
  logic [59:0] s4_opa, s4_opb;
  logic [9:0]  s4_seed;
  div_info_t s3_info_x;
  assign s3_info_x = div_info_derive(s3_info);
  always_ff @(posedge clk) begin
    if (rst) s4_v <= 1'b0;
    else     s4_v <= s3_v;
    s4_info <= s3_info_x;
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
  (* use_dsp = "yes" *) logic [28:0] sma_hi_q;        // (a DSP, not LUTs, for the 26 x 3 bits)
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
    // 5 e2hi = 4 e2hi + e2hi in the DSP's pre-adder (D + A), not in LUTs
    smc_a = $signed(21'(r3_q.info.sqrt ? {e2hi, 2'b0} : 19'd0)) + $signed(21'(e2hi));
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
    div_info_t       info;
    logic [2:0]  rnd;          // round in the multipliers
    logic [59:0] opa;          // A or x
    logic [59:0] opb;          // division: mb; square root: q1 from round 3
    logic [9:0]  seed;
    logic [59:0] c;            // candidate of the remainder round
  } slot_t;

  logic  r1_v, r2_v, r3_v, r4_v, r1_vd;
  (* shreg_extract = "no" *) slot_t r1_q, r2_q, r3_q, r4_q;
  slot_t r1_d;

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

  // Output credits: queue entries plus the results in the rounding stages.
  logic [2:0] q_count;
  logic       rd1_v, rd2_v;
  logic       credit_ok;
  assign credit_ok = (32'(q_count) + 32'(rd1_v) + 32'(rd2_v)) < OUT_DEPTH;

  logic fin, to_f0, cont;
  assign fin   = r4_v && (r4_q.rnd == n_last(r4_q.info.sqrt, r4_q.info.dbl));
  assign to_f0 = fin && credit_ok;
  assign cont  = r4_v && !to_f0;

  // A request accepted now enters the slot that is in c0 now, four cycles later.
  assign ready_o = !rst && !s4_v && !cont;

  // The iteration factors share one adder: K - (src >> h) + e, i.e.
  //   division R2: 2 - D0 + e23     division R3: 2 - D1
  //   sqrt R2:     3/2 - u0/2 + e23 sqrt R4:     3/2 - w1/2
  logic [59:0] fac_sum;
  always_comb begin
    logic        sq, use_m1, use_e;
    logic [59:0] k, src;
    logic [2:0]  nr;
    nr     = r4_q.rnd + 3'd1;
    sq     = r4_q.info.sqrt;
    use_m1 = sq && (nr == 3'd4);
    use_e  = (nr == 3'd2);
    k      = sq ? 60'(3 * (ONE >> 1)) : 60'(2 * ONE);
    src    = use_m1 ? m1 : m2;
    if (sq) src = src >> 1;
    fac_sum = k + ~src + 60'd1 + (use_e ? 60'(e23) : 60'd0);
  end

  always_comb begin
    logic [2:0]  nn;
    logic [59:0] seedq, cand, grid;
    r1_d  = r4_q;
    r1_vd = 1'b0;
    x1 = '0; y1 = '0; x2 = '0; y2 = '0;
    grid  = r4_q.info.dbl ? 60'(1) << 5 : 60'(1) << 34;
    seedq = {2'b0, r4_q.seed, 48'b0};
    nn    = fin ? r4_q.rnd : r4_q.rnd + 3'd1;
    cand  = fin ? r4_q.c : (m1 + (grid >> 1)) & ~(grid - 60'd1);
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
        // 2 - D0 + e23 (~ 1/D0 to third order) or 2 - D1
        x1 = m1; y1 = fac_sum;
        x2 = m2; y2 = fac_sum;
      end else begin
        unique case (nn)
          3'd2: begin                                // P = 3/2 - u0/2 + 3/8 e2 + 5/16 e3
            x1 = m1; y1 = fac_sum;
            x2 = seedq; y2 = fac_sum;
          end
          3'd3: begin                                // w1 = q1 y1; keep q1
            r1_d.opb = m1;
            x1 = m1; y1 = m2;
          end
          default: begin                             // q2 = q1 (3/2 - w1/2)
            x1 = r4_q.opb; y1 = fac_sum;
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
  logic [95:0] rem;
  logic [59:0] f;
  always_comb begin
    logic [59:0] grid;
    rem  = {r4_q.opa[37:0], 58'b0} - p1[95:0];
    grid = r4_q.info.dbl ? 60'(1) << 5 : 60'(1) << 34;
    f    = rem[95] ? r4_q.c - grid : r4_q.c;
  end

  // ------------------------------------------------------------------------------------------
  // F1, F2: rounding (tg_fpu_div_round)
  // ------------------------------------------------------------------------------------------
  logic      rd_v;
  fpu_resp_t rd_resp;
  tg_fpu_div_round u_round (
    .clk, .rst,
    .valid_i (to_f0),
    .info_i  (r4_q.info),
    .t_i     (r4_q.info.dbl ? f[58:6] : {29'b0, f[58:35]}),
    .g_i     (r4_q.info.dbl ? f[5] : f[34]),
    .s_i     (rem != '0),
    .valid_o (rd_v),
    .resp_o  (rd_resp)
  );
  always_ff @(posedge clk) begin
    if (rst) begin rd1_v <= 1'b0; rd2_v <= 1'b0; end
    else     begin rd1_v <= to_f0; rd2_v <= rd1_v; end
  end

  // ------------------------------------------------------------------------------------------
  // Output queue
  // ------------------------------------------------------------------------------------------
  // It keeps only what the user reads: the result, the flags and TAG_W tag bits. A divide never
  // writes an integer register.
  typedef struct packed {
    logic [63:0]      result;
    logic [4:0]       fflags;
    logic [TAG_W-1:0] tag;
  } outq_t;
  logic  q_in_ready;
  outq_t q_in, q_out;
  assign q_in.result = rd_resp.result;
  assign q_in.fflags = rd_resp.fflags;
  assign q_in.tag    = rd_resp.tag[TAG_W-1:0];
  tg_fifo #(.T(outq_t), .DEPTH(OUT_DEPTH)) u_outq (
    .clk, .rst,
    .in_valid (rd_v), .in_ready (q_in_ready), .in_data (q_in),
    .out_valid (valid_o), .out_ready (ready_i), .out_data (q_out),
    .count (q_count)
  );
  always_comb begin
    resp_o          = '0;
    resp_o.result   = q_out.result;
    resp_o.fflags   = q_out.fflags;
    resp_o.int_dest = 1'b0;
    resp_o.tag      = FPU_TAG_W'(q_out.tag);
  end

  logic unused;
  assign unused = ^{s1_q.c, s1_q.src_fmt, s1_q.ifmt, ua.inf, ub.sub, ua.sub, p1[119:118],
                    p2[119:118], p2[57:0], q_in_ready, r2_q.info, r3_q.rnd, f[59], f[4:0],
                    r4_q.info.eq, rd_resp.int_dest, rd_resp.tag};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (valid_i && ready_o) begin
        assert (req_i.fmt != FMT_H) else $error("tg_fpu_div: FMT_H is not implemented");
        assert (fpu_unit_of(req_i.op) == FU_DIV)
          else $error("tg_fpu_div: operation %0d belongs to another unit", req_i.op);
        assert ((req_i.tag >> TAG_W) == '0)
          else $error("tg_fpu_div: request tag wider than TAG_W");
      end
      assert (!(s4_v && cont)) else $error("tg_fpu_div: slot collision");
      assert (!rd_v || q_in_ready) else $error("tg_fpu_div: output queue overflow");
      assert (rd_v == rd2_v) else $error("tg_fpu_div: credit tracking out of step");
    end
  end
`endif

endmodule
