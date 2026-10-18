// Measurement-only profile (smt2-study, area_recovery.md §6.9) for fpu-2's levers tree (a857a07: the f2cut tree with
// STA_BASE and STEER_LA). Two binds into tg_core. The first, smt2_prof_rs, is scripts/rtlprof/prof_rs.sv's
// rename-stall profile with IQ-STA's shadow taking no data dependency under STA_BASE; it reads rename (u_rn) and
// issue (u_is). Counts, inside make perf's timed region (the commit trace's store to the ELF's tg_marker,
// +smt2_marker=<hex>; without it, the whole run):
//   - every cycle decode is held (!de_take), charged to the first of: a flush; the free lists not yet initialised; the
//     dispatch stage holding a group whose slot's bank of an issue queue is full (by queue, slot 0 first); the ROB, LQ
//     or SQ without room for the group; an integer or FP free list short; wakeup tags or LLTs short; the divide and
//     FP-op limits; the block after a serializing uop; a serializing uop waiting for an empty window; the ready tables
//     or the core's start; anything else. And, without the priority, how many held cycles also had the ROB, LQ, SQ or
//     free lists short or the dispatch stage blocked;
//   - when IQ-STA's bank stops the dispatch stage, its rows in that bank by what they wait on: the base register, only
//     the store's data (rename makes the row wait on rs2 too: tg_rename's iq_dep), nothing (not yet selected), or
//     issued and held for the speculative-wakeup shadow; and the same census of all four rows in every cycle.
//     A row's two sources are shadowed from the dispatch stage (their wakeup columns and MX rows) and checked as the
//     queue checks its dependency vector: against the woken vector and the ALU-queue rows selected.
//   - when an ALU queue's or IQ-LD's bank stops the dispatch stage, the bank's rows by state (waiting on a source, ready
//     and not yet granted, issued and held) from the queue's own ready and issued signals; for an ALU queue, whether the
//     stopped op was an ALU op that rename could have steered to the other ALU queue, whose bank for that slot had a
//     row (rename steers by the banks' free flags of the cycle before, which do not count the group dispatch writes in
//     the same cycle), and whether A1's select was blocked for a MUL, DIV or CSR result.
// Prints one line at the end of the run (smt2_prof_rs: key value ...). Not part of sim/: build on a scratch tree with
// make -C sim CFG=st COV_EVENTS=<this file>.
module smt2_prof_rs
  import tg_pkg::*, tg_core_pkg::*;
#(parameter int CW = 2) (
  input logic                 clk, rst,
  input logic [CW-1:0]        cm_valid, tr_st_wr,
  input logic [CW-1:0][63:0]  tr_st_va, tr_st_data,
  input logic                 de_take, flush, ready, start,
  input logic [1:0]           rn_valid, ds_valid, ds_hasq, is_ld, is_st, ds_alu,
  input logic [1:0][2:0]      ds_q,
  input logic [N_IQ-1:0][1:0] bank_free,
  input logic                 ds_free, rn_ok, block_q, rn_serial, window_empty, irdy_ready, frdy_ready,
  input logic [2:0]           rob_room, lq_room, sq_room,
  input logic                 fl_short, ffl_short, tag_short, llt_short,
  input logic [1:0]           sta_we, p1, c1, p2, c2,
  input wid_t [1:0]           w1, w2,
  input logic [1:0][RA-1:0]   mrow1, mrow2,
  input logic [NCOL-1:0]      w_vec, w_all,
  input logic [RA-1:0]        mx_issued, mx_free,
  input logic [1:0][3:0]      aoh,
  input logic [3:0]           val, iss,
  input logic [IQ_A0-1:0]     a0_val, a0_rdy, a0_iss,
  input logic [IQ_A1-1:0]     a1_val, a1_rdy, a1_iss,
  input logic [IQ_LD-1:0]     ld_val, ld_rdy, ld_iss,
  input logic                 a1_block
);
  // held causes: 0 flush, 1 free lists not ready, 2-6 IQ-A0/A1/LD/STA/FP bank full, 7 ROB, 8 LQ, 9 SQ, 10 integer
  // free list, 11 FP free list, 12 tags or LLTs, 13 divide or FP-op limit, 14 block after a serializing uop,
  // 15 serializing uop waiting for an empty window, 16 ready tables or start, 17 other
  localparam int NH = 18;
  longint unsigned marker;
  logic            on;
  initial begin
    if (!$value$plusargs("smt2_marker=%h", marker)) marker = 0;
  end
  always_ff @(posedge clk) begin
    if (rst) on <= (marker == 0);
    else if (marker != 0)
      for (int j = 0; j < CW; j++)
        if (cm_valid[j] && tr_st_wr[j] && tr_st_va[j] == marker) on <= tr_st_data[j][7:0] == 8'd1;
  end

  // IQ-STA's rows: each source's wakeup column (when the row waits on one) and MX row, from the dispatch stage
  logic [3:0]          c1v, c2v;
  wid_t [3:0]          c1c, c2c;
  logic [3:0][RA-1:0]  m1, m2;
  always_ff @(posedge clk) begin
    for (int r = 0; r < 4; r++) begin   // a freed ALU-queue row leaves every row's MX dependencies
      m1[r] <= m1[r] & ~mx_free;
      m2[r] <= m2[r] & ~mx_free;
    end
    for (int k = 0; k < 2; k++)
      if (sta_we[k])
        for (int r = 0; r < 4; r++)
          if (aoh[k][r]) begin
            c1v[r] <= p1[k] && c1[k] && !w_vec[w1[k]];
            c1c[r] <= w1[k];
            c2v[r] <= p2[k] && c2[k] && !w_vec[w2[k]] && !STA_BASE;   // STA_BASE: the row does not wait on rs2
            c2c[r] <= w2[k];
            m1[r]  <= mrow1[k];
            m2[r]  <= STA_BASE ? '0 : mrow2[k];
          end
  end
  // 0 free, 1 waits for its base, 2 waits only for the store's data, 3 ready (not yet selected), 4 issued and held
  function automatic int row_cls(input int r);
    logic b, d;
    if (!val[r]) return 0;
    if (iss[r]) return 4;
    b = (!c1v[r] || w_all[c1c[r]]) && ((m1[r] & ~mx_issued) == '0);
    d = (!c2v[r] || w_all[c2c[r]]) && ((m2[r] & ~mx_issued) == '0);
    return !b ? 1 : !d ? 2 : 3;
  endfunction

  longint unsigned cyc, held [NH], i_ds, i_rob, i_lq, i_sq, i_fl, sta_blk [5], sta_data_cyc, occ [5];
  longint unsigned cen [3][4], alu_other, a1_blk;   // cen[A0, A1, LD][free, waiting, ready, held]
  always_ff @(posedge clk) begin
    if (rst) begin
      cyc <= 0; i_ds <= 0; i_rob <= 0; i_lq <= 0; i_sq <= 0; i_fl <= 0; sta_data_cyc <= 0; alu_other <= 0; a1_blk <= 0;
      for (int q = 0; q < 3; q++) for (int s = 0; s < 4; s++) cen[q][s] <= 0;
      for (int c = 0; c < NH; c++) held[c] <= 0;
      for (int c = 0; c < 5; c++) begin sta_blk[c] <= 0; occ[c] <= 0; end
    end else if (on) begin
      automatic int nrob = rn_valid[1] ? 2 : rn_valid[0] ? 1 : 0;
      automatic int nld = int'(rn_valid[0] && is_ld[0]) + int'(rn_valid[1] && is_ld[1]);
      automatic int nst = int'(rn_valid[0] && is_st[0]) + int'(rn_valid[1] && is_st[1]);
      automatic int occ_n [5] = '{default: 0};
      cyc <= cyc + 1;
      for (int r = 0; r < 4; r++) occ_n[row_cls(r)]++;
      for (int c = 0; c < 5; c++) occ[c] <= occ[c] + longint'(occ_n[c]);
      if (!de_take) begin
        automatic int c = 17, k = -1;
        if (flush) c = 0;
        else if (!ready) c = 1;
        else begin
          for (int j = 1; j >= 0; j--) if (ds_valid[j] && ds_hasq[j] && !bank_free[ds_q[j]][j]) k = j;
          if (!ds_free) c = (k >= 0) ? 2 + int'(ds_q[k]) : 17;
          else if (!rob_room[nrob]) c = 7;
          else if (!lq_room[nld]) c = 8;
          else if (!sq_room[nst]) c = 9;
          else if (fl_short) c = 10;
          else if (ffl_short) c = 11;
          else if (tag_short || llt_short) c = 12;
          else if (!rn_ok) c = 13;
          else if (block_q) c = 14;
          else if (rn_serial && !window_empty) c = 15;
          else if (!irdy_ready || !frdy_ready || !start) c = 16;
          if (!ds_free) i_ds <= i_ds + 1;
          if (!rob_room[nrob]) i_rob <= i_rob + 1;
          if (!lq_room[nld]) i_lq <= i_lq + 1;
          if (!sq_room[nst]) i_sq <= i_sq + 1;
          if (fl_short || ffl_short) i_fl <= i_fl + 1;
        end
        held[c] <= held[c] + 1;
        if (c == 5) begin   // IQ-STA's bank k: rows r with r mod 2 = k
          automatic int n [5] = '{default: 0};
          for (int r = k; r < 4; r += 2) n[row_cls(r)]++;
          for (int x = 0; x < 5; x++) sta_blk[x] <= sta_blk[x] + longint'(n[x]);
          if (n[2] > 0) sta_data_cyc <= sta_data_cyc + 1;
        end
        if (c >= 2 && c <= 4) begin   // IQ-A0, IQ-A1 or IQ-LD: the bank's rows r with r mod 2 = k
          automatic int q = c - 2;
          automatic int n [4] = '{default: 0};
          for (int r = k; r < (q == 0 ? IQ_A0 : q == 1 ? IQ_A1 : IQ_LD); r += 2) begin
            automatic logic v = q == 0 ? a0_val[r] : q == 1 ? a1_val[r] : ld_val[r];
            automatic logic y = q == 0 ? a0_rdy[r] : q == 1 ? a1_rdy[r] : ld_rdy[r];
            automatic logic i = q == 0 ? a0_iss[r] : q == 1 ? a1_iss[r] : ld_iss[r];
            n[!v ? 0 : i ? 3 : y ? 2 : 1]++;
          end
          for (int s = 0; s < 4; s++) cen[q][s] <= cen[q][s] + longint'(n[s]);
          if (q < 2 && ds_alu[k] && bank_free[1 - q][k]) alu_other <= alu_other + 1;
          if (q == 1 && a1_block) a1_blk <= a1_blk + 1;
        end
      end
    end
  end
  final
    $display("smt2_prof_rs: cycles %0d h_flush %0d h_init %0d h_iq_a0 %0d h_iq_a1 %0d h_iq_ld %0d h_iq_sta %0d h_iq_fp %0d h_rob %0d h_lq %0d h_sq %0d h_fl %0d h_ffl %0d h_tag %0d h_lim %0d h_block %0d h_serial %0d h_rdy %0d h_other %0d i_ds %0d i_rob %0d i_lq %0d i_sq %0d i_fl %0d sta_free %0d sta_base %0d sta_data %0d sta_ready %0d sta_held %0d sta_data_cyc %0d occ_free %0d occ_base %0d occ_data %0d occ_ready %0d occ_held %0d a0_free %0d a0_wait %0d a0_ready %0d a0_held %0d a1_free %0d a1_wait %0d a1_ready %0d a1_held %0d ld_free %0d ld_wait %0d ld_ready %0d ld_held %0d alu_other %0d a1_blk %0d",
             cyc, held[0], held[1], held[2], held[3], held[4], held[5], held[6], held[7], held[8], held[9], held[10],
             held[11], held[12], held[13], held[14], held[15], held[16], held[17], i_ds, i_rob, i_lq, i_sq, i_fl,
             sta_blk[0], sta_blk[1], sta_blk[2], sta_blk[3], sta_blk[4], sta_data_cyc, occ[0], occ[1], occ[2], occ[3],
             occ[4], cen[0][0], cen[0][1], cen[0][2], cen[0][3], cen[1][0], cen[1][1], cen[1][2], cen[1][3], cen[2][0],
             cen[2][1], cen[2][2], cen[2][3], alu_other, a1_blk);
endmodule

// The queues by index with two ALU queues: A0 0, A1 1, LD 2, STA 3 (four rows, IQ_STA, in the st configuration)
bind tg_core smt2_prof_rs #(.CW(COMMIT_WIDTH)) u_smt2_prof_rs (
  .clk, .rst, .cm_valid, .tr_st_wr, .tr_st_va, .tr_st_data, .de_take, .flush, .ready(u_rn.ready),
  .start(u_rn.start), .rn_valid(u_rn.rn_valid_q), .ds_valid(u_rn.ds_valid_q),
  .ds_hasq({u_rn.ds_ren_q[1].has_q, u_rn.ds_ren_q[0].has_q}),
  .is_ld({u_rn.rn_uop_q[1].d.cls == C_LD, u_rn.rn_uop_q[0].d.cls == C_LD}),
  .is_st({u_rn.rn_uop_q[1].d.cls == C_ST, u_rn.rn_uop_q[0].d.cls == C_ST}),
  .ds_alu({u_rn.ds_uop_q[1].d.cls == C_ALU, u_rn.ds_uop_q[0].d.cls == C_ALU}),
  .ds_q({3'(u_rn.ds_ren_q[1].q), 3'(u_rn.ds_ren_q[0].q)}), .bank_free(u_rn.iq_bank_free), .ds_free(u_rn.ds_free),
  .rn_ok(u_rn.rn_ok), .block_q(u_rn.block_q), .rn_serial(u_rn.rn_serial), .window_empty(u_rn.window_empty),
  .irdy_ready(u_rn.irdy_ready), .frdy_ready(u_rn.frdy_ready), .rob_room(u_rn.rob_room), .lq_room(u_rn.lq_room),
  .sq_room(u_rn.sq_room),
  .fl_short(int'(u_rn.pops[0]) > int'(u_rn.fl_count[0]) || int'(u_rn.pops[1]) > int'(u_rn.fl_count[1]) ||
            int'(u_rn.pops[2]) > int'(u_rn.fl_count[2])),
  .ffl_short(int'(u_rn.fpops[0]) > int'(u_rn.ffl_count[0]) || int'(u_rn.fpops[1]) > int'(u_rn.ffl_count[1])),
  .tag_short(u_rn.tag_short), .llt_short(u_rn.llt_short), .sta_we(u_rn.iq_we[Q_STA]),
  .p1({u_rn.ds_ren_q[1].p1, u_rn.ds_ren_q[0].p1}), .c1({u_rn.ds_ren_q[1].c1, u_rn.ds_ren_q[0].c1}),
  .p2({u_rn.ds_ren_q[1].p2, u_rn.ds_ren_q[0].p2}), .c2({u_rn.ds_ren_q[1].c2, u_rn.ds_ren_q[0].c2}),
  .w1({wid_t'(u_rn.ds_ren_q[1].w1), wid_t'(u_rn.ds_ren_q[0].w1)}),
  .w2({wid_t'(u_rn.ds_ren_q[1].w2), wid_t'(u_rn.ds_ren_q[0].w2)}), .mrow1(u_rn.mrow1), .mrow2(u_rn.mrow2),
  .w_vec(u_rn.w_vec), .w_all(u_is.w_all), .mx_issued(u_is.mx_issued), .mx_free(u_is.mx_free),
  .aoh(u_is.g_q[3].aoh), .val(u_is.g_q[3].val_o), .iss(u_is.g_q[3].iss_o),
  .a0_val(u_is.g_q[0].val_o), .a0_rdy(u_is.g_q[0].u_iq.ready), .a0_iss(u_is.g_q[0].iss_o),
  .a1_val(u_is.g_q[1].val_o), .a1_rdy(u_is.g_q[1].u_iq.ready), .a1_iss(u_is.g_q[1].iss_o),
  .ld_val(u_is.g_q[2].val_o), .ld_rdy(u_is.g_q[2].u_iq.ready), .ld_iss(u_is.g_q[2].iss_o), .a1_block(u_is.a1_block));

// The second, smt2_prof_ld: the loads and what they cost, inside the same region. Each load at M2 by the LSU's verdict
// (m2_out: done, waits for a store, miss, retry, fault), a store wait split into the data not yet in the SQ and the
// store not covering the load; the cycles LQ entries spend waiting for a store (L_STQ); speculative wakeup's cancels
// by the verdict of the load that missed M2 the cycle before; commit's flushes by cause, and the PCs of the loads
// replayed at commit (those with 20 or more).
module smt2_prof_ld #(parameter int CW = 2, parameter int LQN = 16) (
  input logic                  clk, rst,
  input logic [CW-1:0]         cm_valid, tr_st_wr,
  input logic [CW-1:0][63:0]   tr_st_va, tr_st_data,
  input logic                  m2_v, m2_pt, m2_fhit, m2_fcov, m2_fdat,
  input logic [2:0]            m2_out,
  input logic                  sw_cancel,
  input logic [LQN-1:0]        lq_v,
  input logic [LQN-1:0][3:0]   lq_st,
  input logic                  do_flush, misp, rpl, do_irq, do_trap,
  input logic [63:0]           hd_pc
);
  longint unsigned marker;
  logic            on;
  initial begin
    if (!$value$plusargs("smt2_marker=%h", marker)) marker = 0;
  end
  always_ff @(posedge clk) begin
    if (rst) on <= (marker == 0);
    else if (marker != 0)
      for (int j = 0; j < CW; j++)
        if (cm_valid[j] && tr_st_wr[j] && tr_st_va[j] == marker) on <= tr_st_data[j][7:0] == 8'd1;
  end
  // m2_out: 0 done, 1 waits for a store, 2 miss, 3 retry (a D$ row clash), 4 fault; LQ state 4 is L_STQ
  longint unsigned n_out [5], stq_nodata, stq_part, n_cancel [6], stq_cyc, f_rpl, f_misp, f_oth;
  int unsigned rpl_pc [longint unsigned];
  logic [2:0] out_q;
  logic       v_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < 5; i++) n_out[i] <= 0;
      for (int i = 0; i < 6; i++) n_cancel[i] <= 0;
      stq_nodata <= 0; stq_part <= 0; stq_cyc <= 0; f_rpl <= 0; f_misp <= 0; f_oth <= 0;
      v_q <= 1'b0; out_q <= '0;
    end else begin
      v_q   <= m2_v && !m2_pt;
      out_q <= m2_out;
      if (on) begin
        automatic int w = 0;
        if (m2_v && !m2_pt) begin
          n_out[m2_out] <= n_out[m2_out] + 1;
          if (m2_out == 3'd1) begin
            if (m2_fcov && !m2_fdat) stq_nodata <= stq_nodata + 1;
            else stq_part <= stq_part + 1;
          end
        end
        if (sw_cancel) begin   // the load that missed M2 was there the cycle before
          if (v_q) n_cancel[out_q] <= n_cancel[out_q] + 1;
          else n_cancel[5] <= n_cancel[5] + 1;
        end
        for (int i = 0; i < LQN; i++) if (lq_v[i] && lq_st[i] == 4'd4) w++;
        stq_cyc <= stq_cyc + longint'(w);
        if (do_flush) begin
          if (do_irq || do_trap) f_oth <= f_oth + 1;
          else if (rpl) begin
            f_rpl <= f_rpl + 1;
            if (rpl_pc.exists(hd_pc)) rpl_pc[hd_pc] = rpl_pc[hd_pc] + 1;
            else rpl_pc[hd_pc] = 1;
          end
          else if (misp) f_misp <= f_misp + 1;
          else f_oth <= f_oth + 1;
        end
      end
    end
  end
  final begin
    $display("smt2_prof_ld: m2_ok %0d m2_stq %0d m2_miss %0d m2_retry %0d m2_fault %0d stq_nodata %0d stq_part %0d cancel_ok %0d cancel_stq %0d cancel_miss %0d cancel_retry %0d cancel_fault %0d cancel_nold %0d stq_cyc %0d fl_rpl %0d fl_misp %0d fl_oth %0d",
             n_out[0], n_out[1], n_out[2], n_out[3], n_out[4], stq_nodata, stq_part, n_cancel[0], n_cancel[1],
             n_cancel[2], n_cancel[3], n_cancel[4], n_cancel[5], stq_cyc, f_rpl, f_misp, f_oth);
    foreach (rpl_pc[pc]) if (rpl_pc[pc] >= 20) $display("smt2_prof_rpl: pc %h replays %0d", pc, rpl_pc[pc]);
  end
endmodule

bind tg_core smt2_prof_ld #(.CW(COMMIT_WIDTH), .LQN(LQ_ENTRIES)) u_smt2_prof_ld (
  .clk, .rst, .cm_valid, .tr_st_wr, .tr_st_va, .tr_st_data, .m2_v(u_lsu.m2_v_q), .m2_pt(u_lsu.m2_pt_q),
  .m2_fhit(u_lsu.m2_fhit_q), .m2_fcov(u_lsu.m2_fcov_q), .m2_fdat(u_lsu.m2_fdat_q), .m2_out(3'(u_lsu.m2_out)),
  .sw_cancel(u_is.sw_cancel), .lq_v(u_lsu.lq_v_q), .lq_st(u_lsu.lq_st_q), .do_flush(u_rob.do_flush),
  .misp(|(u_rob.mf & ~u_rob.hold_le)), .rpl(u_rob.rpl_h[0]), .do_irq(u_rob.do_irq), .do_trap(u_rob.do_trap),
  .hd_pc(u_rob.hp[0].pc));
