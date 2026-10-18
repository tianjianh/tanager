// Measurement-only front-end profile (smt2-study, area_recovery.md §6.7) for fpu-2's f2cut tree (1e4a503: c149fce's
// M6 set with F2 restructured). Bound into tg_core; reads fetch, decode, rename and the ROB hierarchically.
// Counts, inside make perf's timed region (the commit trace's store to the ELF's tg_marker, +smt2_marker=<hex>;
// without it, the whole run):
//   - every F2 refetch by cause (override kinds, the branch cut, a dropped micro-BTB prediction), decode's redirects,
//     commit's flushes by cause, and the I$ miss, ITLB walk and FTQ-full cycles;
//   - decode's lost slots in cycles rename takes a group: starved (the queue offers fewer than two), charged to the
//     last front-end event before them (or to steady fetch when none in the last 32 cycles), or held back by
//     decode's own group rules;
//   - in steady fetch (no front-end event in the last 32 cycles): what F2 did in the starved cycles (empty, holding a
//     block it cannot deliver, delivering), and the blocks it delivered (count, instructions), beside the whole run;
//     with F2 empty, why F1 sent nothing (no fetch PC, stopped after a fault block, the I$ sweep after a FENCE.I,
//     PMP descriptors recomputed, an I$ miss or ITLB walk older than 32 cycles); FENCE.I flushes and sweep cycles.
// Prints one line at the end of the run (smt2_prof_f2: key value ...). Not part of sim/: build on a scratch tree
// with make -C sim CFG=st COV_EVENTS=<this file>, or the boot test with TB="tb_boot.sv <this file>".
module smt2_prof_f2 #(parameter int CW = 2) (
  input logic                  clk, rst,
  input logic [CW-1:0]         cm_valid, tr_st_wr,
  input logic [CW-1:0][63:0]   tr_st_va, tr_st_data,
  input logic                  flush, dred, de_take,
  input logic                  f2_deliver, f2_override, ovr_tk, ovr_ras, ovr_s, fx_tsrc, gh_b0, f2_hit_q, slot_ne,
  input logic                  pmp_cut, f2_isfault, f2_isf0, pred_ok, ft_full, f2v, miss_q, wk_q,
  input logic [1:0]            iq_valid, iq_take,
  input logic [7:0]            bs,
  input logic                  f1v, stop_q, ivs_done, pmp_busy, icinv,
  input logic                  do_flush, misp, rpl, do_irq, do_trap
);
  localparam int NC = 16;   // causes
  // 0 steady fetch, 1 flush: mispredict, 2 flush: replay, 3 flush: other, 4 decode redirect,
  // 5 override: missed taken branch, 6 missed JAL, 7 missed return, 8 missed JALR, 9 missed straddler,
  // 10 exit at another slot, 11 return target differs, 12 hit but not taken, 13 cut, 14 I$ miss, 15 ITLB walk
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
  longint unsigned cyc, n_ev [NC], lost [NC], n_bogus, c_ftq, c_icm, c_itlb, dec_rule, take [3], avail [3];
  longint unsigned s_f2v0, s_hold, s_del, w_cyc, w_del, w_ins, a_del, a_ins;
  longint unsigned e_f1v, e_stop, e_ivs, e_pmp, e_miss, e_walk, e_oth, n_icinv, c_ivs;
  int unsigned cause_q, since_q, fl_cause_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      cyc <= 0; n_bogus <= 0; c_ftq <= 0; c_icm <= 0; c_itlb <= 0; dec_rule <= 0;
      s_f2v0 <= 0; s_hold <= 0; s_del <= 0; w_cyc <= 0; w_del <= 0; w_ins <= 0; a_del <= 0; a_ins <= 0;
      e_f1v <= 0; e_stop <= 0; e_ivs <= 0; e_pmp <= 0; e_miss <= 0; e_walk <= 0; e_oth <= 0; n_icinv <= 0; c_ivs <= 0;
      for (int k = 0; k < NC; k++) begin n_ev[k] <= 0; lost[k] <= 0; end
      for (int k = 0; k < 3; k++) begin take[k] <= 0; avail[k] <= 0; end
      cause_q <= 0; since_q <= 1000; fl_cause_q <= 3;
    end else begin
      int ev, a, tk;
      ev = -1;
      // the ROB decides a flush a cycle before fetch sees it
      if (do_flush) fl_cause_q <= do_irq || do_trap ? 3 : rpl ? 2 : misp ? 1 : 3;
      if (flush) ev = fl_cause_q;
      else if (dred) ev = 4;
      else if (f2_override) begin
        if (ovr_tk && !f2_hit_q) ev = ovr_s ? 9 : ovr_ras ? 7 : gh_b0 ? 5 : fx_tsrc ? 6 : 8;
        else if (ovr_tk && slot_ne) ev = 10;
        else if (ovr_tk) ev = 11;
        else ev = 12;
      end else if (f2_deliver && pmp_cut && !f2_isfault) ev = 13;
      else if (miss_q && cause_q != 14) ev = 14;
      else if (wk_q && cause_q != 15) ev = 15;
      if (ev >= 0) begin
        cause_q <= ev;
        since_q <= 0;
      end else if (since_q < 1000) since_q <= since_q + 1;
      a  = $countones(iq_valid);
      tk = int'(iq_take);
      if (on) begin
        cyc <= cyc + 1;
        if (ev >= 0) n_ev[ev] <= n_ev[ev] + 1;
        if (f2_deliver && f2_hit_q && !pred_ok && !f2_isf0) n_bogus <= n_bogus + 1;
        if (f2v && ft_full) c_ftq <= c_ftq + 1;
        if (miss_q) c_icm <= c_icm + 1;
        if (wk_q) c_itlb <= c_itlb + 1;
        if (flush && icinv) n_icinv <= n_icinv + 1;
        if (!ivs_done) c_ivs <= c_ivs + 1;
        if (f2_deliver) begin
          a_del <= a_del + 1;
          a_ins <= a_ins + longint'($countones(bs));
        end
        if (ev < 0 && since_q >= 32) begin
          w_cyc <= w_cyc + 1;
          if (f2_deliver) begin
            w_del <= w_del + 1;
            w_ins <= w_ins + longint'($countones(bs));
          end
        end
        avail[a] <= avail[a] + 1;
        if (de_take) begin
          take[tk] <= take[tk] + 1;
          if (a < 2) begin
            automatic int c = (ev >= 0) ? ev : (since_q >= 32 ? 0 : int'(cause_q));
            lost[c] <= lost[c] + longint'(2 - a);
            if (c == 0) begin
              if (!f2v) begin
                s_f2v0 <= s_f2v0 + 1;
                if (!f1v) e_f1v <= e_f1v + 1;
                else if (stop_q) e_stop <= e_stop + 1;
                else if (!ivs_done) e_ivs <= e_ivs + 1;
                else if (pmp_busy) e_pmp <= e_pmp + 1;
                else if (miss_q) e_miss <= e_miss + 1;
                else if (wk_q) e_walk <= e_walk + 1;
                else e_oth <= e_oth + 1;
              end
              else if (!f2_deliver) s_hold <= s_hold + 1;
              else s_del <= s_del + 1;
            end
          end
          if (tk < a) dec_rule <= dec_rule + longint'(a - tk);
        end
      end
    end
  end
  final
    $display("smt2_prof_f2: cycles %0d ev_steady %0d ev_fl_misp %0d ev_fl_rpl %0d ev_fl_oth %0d ev_dred %0d ev_miss_br %0d ev_miss_jal %0d ev_miss_ret %0d ev_miss_jalr %0d ev_miss_strad %0d ev_slot %0d ev_rastgt %0d ev_nt %0d ev_cut %0d ev_icmiss %0d ev_itlb %0d lost_steady %0d lost_fl_misp %0d lost_fl_rpl %0d lost_fl_oth %0d lost_dred %0d lost_miss_br %0d lost_miss_jal %0d lost_miss_ret %0d lost_miss_jalr %0d lost_miss_strad %0d lost_slot %0d lost_rastgt %0d lost_nt %0d lost_cut %0d lost_icmiss %0d lost_itlb %0d bogus %0d ftq_full %0d icmiss_cyc %0d itlb_cyc %0d dec_rule %0d take0 %0d take1 %0d take2 %0d avail0 %0d avail1 %0d avail2 %0d s_f2v0 %0d s_hold %0d s_del %0d w_cyc %0d w_del %0d w_ins %0d a_del %0d a_ins %0d e_f1v %0d e_stop %0d e_ivs %0d e_pmp %0d e_miss %0d e_walk %0d e_oth %0d n_icinv %0d c_ivs %0d",
             cyc, n_ev[0], n_ev[1], n_ev[2], n_ev[3], n_ev[4], n_ev[5], n_ev[6], n_ev[7], n_ev[8], n_ev[9], n_ev[10],
             n_ev[11], n_ev[12], n_ev[13], n_ev[14], n_ev[15], lost[0], lost[1], lost[2], lost[3], lost[4], lost[5],
             lost[6], lost[7], lost[8], lost[9], lost[10], lost[11], lost[12], lost[13], lost[14], lost[15], n_bogus,
             c_ftq, c_icm, c_itlb, dec_rule, take[0], take[1], take[2], avail[0], avail[1], avail[2], s_f2v0, s_hold, s_del, w_cyc, w_del, w_ins,
             a_del, a_ins, e_f1v, e_stop, e_ivs, e_pmp, e_miss, e_walk, e_oth, n_icinv, c_ivs);
endmodule

bind tg_core smt2_prof_f2 #(.CW(COMMIT_WIDTH)) u_smt2_prof_f2 (
  .clk, .rst, .cm_valid, .tr_st_wr, .tr_st_va, .tr_st_data, .flush, .dred, .de_take,
  .f2_deliver(u_fetch.f2_deliver), .f2_override(u_fetch.f2_override), .ovr_tk(u_fetch.ovr_tk),
  .ovr_ras(u_fetch.ovr_ras), .ovr_s(u_fetch.ovr_s), .fx_tsrc(u_fetch.fx_tsrc), .gh_b0(u_fetch.gh_b[0]),
  .f2_hit_q(u_fetch.f2_hit_q), .slot_ne(u_fetch.f2_slot_q != u_fetch.fx_slot), .pmp_cut(u_fetch.pmp_cut),
  .f2_isfault(u_fetch.f2_isfault), .f2_isf0(u_fetch.f2_isf0), .pred_ok(u_fetch.pred_ok), .ft_full(u_fetch.ft_full),
  .f2v(u_fetch.f2v), .miss_q(u_fetch.miss_q), .wk_q(u_fetch.wk_q), .iq_valid(u_fetch.iq_valid),
  .iq_take(u_fetch.iq_take), .bs(u_fetch.blk_start), .f1v(u_fetch.f1_valid_q), .stop_q(u_fetch.stop_q),
  .ivs_done(u_fetch.ivs_done), .pmp_busy(u_fetch.pmp_busy), .icinv(u_fetch.icinv), .do_flush(u_rob.do_flush), .misp(|(u_rob.mf & ~u_rob.hold_le)), .rpl(u_rob.rpl_h[0]),
  .do_irq(u_rob.do_irq), .do_trap(u_rob.do_trap));
