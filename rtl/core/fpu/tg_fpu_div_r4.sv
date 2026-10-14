// Divide/sqrt by radix-4 digit recurrence, the area fallback for the Goldschmidt unit
// (docs/spec/fpu.md, "Fallback: radix-4 divide/sqrt"; bit-accurate model tests/unit/fpu/r4_model.h).
// Same ports and handshake as tg_fpu_div. One operation at a time:
//   t      request accepted (registered)
//   t+1    UNP: unpack, specials; normalise the divisor (or the radicand)
//   t+2    NRM: normalise the dividend (the same shifter)
//   t+3    INI: q in [1, 2) scaling, exponent, residual w0 = A - d (or x - 1)
//   t+4..  ITR: one radix-4 digit per cycle (27 for D, 12 for S), restoring, chosen by three
//          trial subtractions in parallel; the last one hands (T, G, S) to tg_fpu_div_round
//   ..     F1, F2 (tg_fpu_div_round), then the output register
// Latency 33 cycles (D) and 18 (S), divide and square root alike.
module tg_fpu_div_r4
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
  localparam int F = 56;                            // fraction bits of residual, root, divisor

  typedef enum logic [2:0] { S_IDLE, S_UNP, S_NRM, S_INI, S_ITR, S_RND } state_e;
  state_e st_q;

  fpu_req_t  rq_q;
  div_info_t info_q;
  logic [52:0] ma_q, mb_q;                          // significands, normalised as the FSM goes
  logic [12:0] ea_q, eb_q;                          // exponent fields minus leading zeros
  logic [59:0] w_q;                                 // residual, Q4.56 (< 2^58)
  logic [56:0] q_q;                                 // root or quotient so far, Q1.56
  logic [56:0] u_q;                                 // weight of the next digit (one-hot)
  logic [56:0] d_q;                                 // divisor, Q1.56
  logic [4:0]  cnt_q;
  logic        out_v_q;
  fpu_resp_t   out_q;

  logic sqrt_op, dbl_op;
  assign sqrt_op = info_q.sqrt;
  assign dbl_op  = info_q.dbl;

  // ---- Unpack ----
  fp_unp_t ua, ub;
  assign ua = unpack(rq_q.a, rq_q.fmt == FMT_D);
  assign ub = unpack(rq_q.b, rq_q.fmt == FMT_D);

  // ---- Shared normaliser: UNP normalises b (division) or a (square root), NRM normalises a ----
  logic [52:0] nrm_in, nrm_out;
  logic [5:0]  nrm_lz;
  assign nrm_in = (st_q == S_UNP && rq_q.op != FOP_FSQRT) ? ub.sig : ((st_q == S_UNP) ? ua.sig : ma_q);
  tg_fpu_lzc #(.W(53)) u_lz (.x(nrm_in), .cnt(nrm_lz));
  assign nrm_out = nrm_in << nrm_lz;

  // ---- One radix-4 step: largest b in {1, 2, 3} with X - S_b >= 0, else 0 ----
  //   division:     S1 = d,         S2 = 2d,         S3 = d + 2d
  //   square root:  S1 = 2Q | u,    S2 = 4Q | 4u,    S3 = (2Q | u) + (4Q | 8u)
  logic [60:0] x4, ta, tb, tc, t1, t2, t3;
  logic [59:0] w_d;
  logic [1:0]  dig;
  always_comb begin
    x4 = {1'b0, w_q[57:0], 2'b00};
    if (sqrt_op) begin
      ta = {3'b0, q_q, 1'b0} | {4'b0, u_q};
      tb = {2'b0, q_q, 2'b0} | {2'b0, u_q, 2'b0};
      tc = {2'b0, q_q, 2'b0} | {1'b0, u_q, 3'b0};
    end else begin
      ta = {4'b0, d_q};
      tb = {3'b0, d_q, 1'b0};
      tc = {3'b0, d_q, 1'b0};
    end
    t1 = x4 - ta;
    t2 = x4 - tb;
    t3 = x4 - ta - tc;
    if (!t3[60])      begin dig = 2'd3; w_d = t3[59:0]; end
    else if (!t2[60]) begin dig = 2'd2; w_d = t2[59:0]; end
    else if (!t1[60]) begin dig = 2'd1; w_d = t1[59:0]; end
    else              begin dig = 2'd0; w_d = x4[59:0]; end
  end
  logic [56:0] q_d;
  assign q_d = q_q | (dig[1] ? {u_q[55:0], 1'b0} : '0) | (dig[0] ? u_q : '0);

  // ---- Hand-off to rounding after the last digit: (T, G, S) at normal precision ----
  logic last;
  assign last = (st_q == S_ITR) && (cnt_q == '0);
  logic [52:0] r_t;
  logic        r_g, r_s;
  always_comb begin
    if (dbl_op) begin r_t = q_d[56:4];          r_g = q_d[3];  r_s = q_d[2] || (w_d != '0); end
    else        begin r_t = {29'b0, q_d[56:33]}; r_g = q_d[32]; r_s = (w_d != '0); end
  end
  logic      rd_v;
  fpu_resp_t rd_resp;
  tg_fpu_div_round u_round (
    .clk, .rst,
    .valid_i (last), .info_i (info_q), .t_i (r_t), .g_i (r_g), .s_i (r_s),
    .valid_o (rd_v), .resp_o (rd_resp)
  );

  // ---- Control and datapath registers ----
  assign ready_o = !rst && (st_q == S_IDLE) && !out_v_q;
  assign valid_o = out_v_q;
  assign resp_o  = out_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      st_q    <= S_IDLE;
      out_v_q <= 1'b0;
    end else begin
      if (out_v_q && ready_i) out_v_q <= 1'b0;
      if (rd_v) out_v_q <= 1'b1;
      unique case (st_q)
        S_IDLE: if (valid_i && ready_o) st_q <= S_UNP;
        S_UNP:  st_q <= S_NRM;
        S_NRM:  st_q <= S_INI;
        S_INI:  st_q <= S_ITR;
        S_ITR:  if (cnt_q == '0) st_q <= S_RND;
        default: if (rd_v) st_q <= S_IDLE;           // S_RND: wait for the rounding stages
      endcase
    end
    if (rd_v) out_q <= rd_resp;
    unique case (st_q)
      S_IDLE: if (valid_i && ready_o) rq_q <= req_i;
      S_UNP: begin
        info_q <= div_info_init(rq_q.op == FOP_FSQRT, rq_q.fmt == FMT_D, rq_q.rm, rq_q.tag, ua, ub);
        if (rq_q.op == FOP_FSQRT) begin
          ma_q <= nrm_out; ea_q <= 13'(ua.exp) - 13'(nrm_lz);
        end else begin
          ma_q <= ua.sig;  ea_q <= 13'(ua.exp);
          mb_q <= nrm_out; eb_q <= 13'(ub.exp) - 13'(nrm_lz);
        end
      end
      S_NRM: if (!sqrt_op) begin
        ma_q <= nrm_out; ea_q <= ea_q - 13'(nrm_lz);
      end
      S_INI: begin
        logic        lt, odd;
        logic signed [12:0] eu;
        div_info_t   i;
        logic [59:0] a;
        lt  = ma_q < mb_q;
        eu  = $signed(ea_q) - 13'sd1023;
        odd = eu[0];
        i   = info_q;
        if (sqrt_op) begin
          i.eq = 13'((eu - $signed({12'b0, odd})) >>> 1);
          a    = 60'(ma_q) << (odd ? 5 : 4);                           // x in [1, 4), Q4.56
          w_q  <= a - (60'(1) << F);                                    // x - 1
        end else begin
          i.eq = 13'($signed(ea_q) - $signed(eb_q) - $signed({12'b0, lt}));
          a    = 60'(ma_q) << (lt ? 5 : 4);                            // A in [1, 4)
          w_q  <= a - ({7'b0, mb_q} << 4);                              // A - d
        end
        info_q <= div_info_derive(i);
        d_q    <= {mb_q, 4'b0};
        q_q    <= 57'(1) << F;
        u_q    <= 57'(1) << (F - 2);
        cnt_q  <= dbl_op ? 5'd26 : 5'd11;
      end
      S_ITR: begin
        w_q   <= w_d;
        q_q   <= q_d;
        u_q   <= u_q >> 2;
        cnt_q <= cnt_q - 5'd1;
      end
      default: ;
    endcase
  end

  logic unused;
  assign unused = ^{rq_q.c, rq_q.src_fmt, rq_q.ifmt, ua.sub, ua.inf, ub.sub, ub.inf, x4[60],
                    w_q[59:58], t1[60], q_d[1:0], ub.exp[10], u_q[56]};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && valid_i && ready_o) begin
      assert (req_i.fmt != FMT_H) else $error("tg_fpu_div_r4: FMT_H is not implemented");
      assert (req_i.op inside {FOP_FDIV, FOP_FSQRT})
        else $error("tg_fpu_div_r4: operation %0d belongs to another unit", req_i.op);
    end
    if (!rst && rd_v) assert (!out_v_q || ready_i) else $error("tg_fpu_div_r4: result overwritten");
  end
`endif

endmodule
