// Return-address stack (plan §4.2; M6; core-pipeline.md §4.3): decode predicts returns from it.
//
// Operations, by the RISC-V hints (unprivileged spec §2.5.1), with x1 and x5 the link registers:
// a JAL or JALR whose rd is a link pushes its link (PC + 2 or 4); a JALR whose rs1 is a link pops,
// unless rd is the same register; a JALR with two different links pops, then pushes (ras_op in
// tg_core_pkg).
//
// Two copies:
// - The committed copy (a_*) follows commit: its pointer, its count, and a LUTRAM written by
//   committed pushes.
// - The speculative stack (s_*) follows decode: decode reads its top and moves it with the groups
//   rename takes. Its entries are a LUTRAM written by decode's pushes, each with a valid bit; an
//   entry without one reads the committed copy's.
// A flush (every recovery is at commit) clears the valid bits and takes the committed pointer and
// count, so the stack is exact after any flush: a mispredict, a trap, a replay. That holds because
// decode is ahead of commit: whatever commit writes since a flush, decode wrote at the same entry
// first, so an entry without a valid bit is unchanged in the committed copy since the flush. A
// decode redirect needs no repair: only the groups rename takes move the stack.
//
// The stack is circular (NE a power of two): a push past NE entries overwrites the oldest; the
// count saturates at NE and at 0, and the pointer always moves.
// The speculative side's operations come from decode, or with TAGE (TAGE_ON) from fetch's F2, as
// each block is delivered (its exit's call or return); fetch then also repairs it at decode's
// redirect, from the redirecting block's FTQ entry: the pointer, count and top entry before the
// block (r_*). Deeper entries a dropped path overwrote stay wrong until the next flush.
// The speculative side does at most one operation per cycle (decode: a group holds at most one;
// fetch: one block's exit).
// Commit does any number of pops and at most one push per cycle (tg_rob ends a group before a
// second push), in slot order, a slot's pop before its push.
// LATE (fetch's operations, RAS_FE; timing): the speculative side's operation and repair are
// registered and take effect a cycle later, so fetch's F2 decision does not run on into the stack's
// pointer, count, valid bits and LUTRAM. Meanwhile the outputs show the stack as it will be: a
// pending push's link on top, a pending pop's entry below, a pending repair's values, as the
// registers held them without LATE. A flush drops what is pending (as before, it would have undone
// it), and one write port still serves: an operation and a repair never come in one cycle.
module tg_ras
  import tg_pkg::*;
#(
  parameter int  NE = 32,
  parameter int  CW = 2,
  parameter bit  LATE = 1'b0,
  localparam int PW = idx_w(NE)
) (
  input  logic                clk,
  input  logic                rst,
  input  logic                flush,
  // The speculative side: the top; one operation (of a group rename takes, or a delivered block)
  output logic                top_v,      // the stack is not empty
  output logic [38:1]         top,
  output logic [PW-1:0]       s_tos,      // its pointer and count (TAGE_ON: the FTQ's snapshot)
  output logic [PW:0]         s_cnt,
  input  logic                d_push,
  input  logic                d_pop,
  input  logic [38:1]         d_link,
  // A repair (TAGE_ON: decode's redirect): pointer, count and top entry (written when r_wr)
  input  logic                r_v,
  input  logic                r_wr,
  input  logic [PW-1:0]       r_tos,
  input  logic [PW:0]         r_cnt,
  input  logic [38:1]         r_top,
  // Commit, in slot order
  input  logic [CW-1:0]       c_push,
  input  logic [CW-1:0]       c_pop,
  input  logic [CW-1:0][38:1] c_link
);
  if (NE < 2 || (NE & (NE - 1)) != 0) begin : g_bad_ne
    $error("tg_ras: NE must be a power of two, at least 2");
  end

  // ---- Committed copy ----
  logic [PW-1:0] a_tos_q, a_tos_d;
  logic [PW:0]   a_cnt_q, a_cnt_d;
  logic          a_we;
  logic [PW-1:0] a_wa;
  logic [38:1]   a_wd;
  always_comb begin
    logic [PW-1:0] t;
    logic [PW:0]   c;
    t = a_tos_q;
    c = a_cnt_q;
    a_we = 1'b0;
    a_wa = '0;
    a_wd = '0;
    for (int j = 0; j < CW; j++) begin
      if (c_pop[j]) begin
        t = t - 1'b1;
        if (c != '0) c = c - 1'b1;
      end
      if (c_push[j]) begin
        t = t + 1'b1;
        if (c != (PW + 1)'(NE)) c = c + 1'b1;
        a_we = 1'b1;
        a_wa = t;
        a_wd = c_link[j];
      end
    end
    a_tos_d = t;
    a_cnt_d = c;
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      a_tos_q <= '0;
      a_cnt_q <= '0;
    end else begin
      a_tos_q <= a_tos_d;
      a_cnt_q <= a_cnt_d;
    end
  end

  // ---- Speculative stack ----
  logic [PW-1:0] s_tos_q, s_tos_n;
  logic [PW:0]   s_cnt_q, s_cnt_n;
  logic [NE-1:0] sv_q;                       // decode wrote the entry since the last flush
  // The operation and the repair this cycle makes: the inputs', or with LATE the last cycle's
  logic                o_push, o_pop, o_rv, o_rwr;
  logic [38:1]         o_link, o_rtop;
  logic [PW-1:0]       o_rtos;
  logic [PW:0]         o_rcnt;
  if (LATE) begin : g_late
    logic          p_push_q, p_pop_q, p_rv_q, p_rwr_q;
    logic [38:1]   p_link_q, p_rtop_q;
    logic [PW-1:0] p_rtos_q;
    logic [PW:0]   p_rcnt_q;
    always_ff @(posedge clk) begin
      if (rst) begin
        p_push_q <= 1'b0;
        p_pop_q  <= 1'b0;
        p_rv_q   <= 1'b0;
      end else begin
        p_push_q <= d_push && !flush;
        p_pop_q  <= d_pop && !flush;
        p_rv_q   <= r_v && !flush;
      end
      p_link_q <= d_link;
      p_rwr_q  <= r_wr;
      p_rtos_q <= r_tos;
      p_rcnt_q <= r_cnt;
      p_rtop_q <= r_top;
    end
    assign {o_push, o_pop, o_rv, o_rwr, o_link, o_rtop, o_rtos, o_rcnt} =
           {p_push_q, p_pop_q, p_rv_q, p_rwr_q, p_link_q, p_rtop_q, p_rtos_q, p_rcnt_q};
  end else begin : g_now
    assign {o_push, o_pop, o_rv, o_rwr, o_link, o_rtop, o_rtos, o_rcnt} =
           {d_push, d_pop, r_v, r_wr, d_link, r_top, r_tos, r_cnt};
  end
  // the pointer and count after the operation (a pop, then a push) or the repair
  always_comb begin
    logic [PW:0] c;
    c = s_cnt_q;
    if (o_pop && c != '0) c = c - 1'b1;
    if (o_push && c != (PW + 1)'(NE)) c = c + 1'b1;
    s_tos_n = o_rv ? o_rtos : s_tos_q - PW'(o_pop) + PW'(o_push);
    s_cnt_n = o_rv ? o_rcnt : c;
  end
  logic [0:0][PW-1:0] ra;
  logic [0:0][38:1]   s_rd, a_rd;
  // the top as read: without LATE at the pointer; with LATE at the pointer after what is pending, a
  // push's or repair's written entry passed by
  assign ra[0] = LATE ? s_tos_n : s_tos_q;
  tg_ram_lut #(.DEPTH(NE), .WIDTH(38), .NR(1)) u_spec (
    .clk, .we(((o_rv && o_rwr) || (o_push && !o_rv)) && !flush && !rst), .waddr(s_tos_n),
    .wdata(o_rv ? o_rtop : o_link), .raddr(ra), .rdata(s_rd));
  tg_ram_lut #(.DEPTH(NE), .WIDTH(38), .NR(1)) u_comm (
    .clk, .we(a_we && !rst), .waddr(a_wa), .wdata(a_wd), .raddr(ra), .rdata(a_rd));
  if (LATE) begin : g_out_late
    assign top   = (o_rv && o_rwr) ? o_rtop : (o_push && !o_rv) ? o_link : sv_q[s_tos_n] ? s_rd[0] : a_rd[0];
    assign top_v = s_cnt_n != '0;
    assign s_tos = s_tos_n;
    assign s_cnt = s_cnt_n;
  end else begin : g_out_now
    assign top   = sv_q[s_tos_q] ? s_rd[0] : a_rd[0];
    assign top_v = s_cnt_q != '0;
    assign s_tos = s_tos_q;
    assign s_cnt = s_cnt_q;
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      s_tos_q <= '0;
      s_cnt_q <= '0;
      sv_q    <= '0;
    end else if (flush) begin
      s_tos_q <= a_tos_d;
      s_cnt_q <= a_cnt_d;
      sv_q    <= '0;
    end else begin
      s_tos_q <= s_tos_n;
      s_cnt_q <= s_cnt_n;
      if ((o_rv && o_rwr) || (o_push && !o_rv)) sv_q[s_tos_n] <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  // At most one push per commit cycle (tg_rob); decode moves the stack only outside a flush
  always_ff @(posedge clk) begin
    if (!rst) begin
      assert ($countones(c_push) <= 1) else $error("tg_ras: two pushes in one commit cycle");
      assert (!((flush || r_v) && (d_push || d_pop))) else $error("tg_ras: an operation in a flush's or a repair's cycle");
      assert (!(o_rv && (o_push || o_pop))) else $error("tg_ras: an operation and a repair in one cycle");
    end
  end
`endif
endmodule
