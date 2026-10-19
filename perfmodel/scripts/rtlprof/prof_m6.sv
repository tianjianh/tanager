// Measurement-only boot profile for M6's remaining pieces (smt2-study, area_recovery.md §6.11) on main as merged
// (31e65c6: the RAS, TAGE-lite with two 2K tables, F2 returns and straddlers, DR-169's levers). Bound into tg_core for
// the Linux boot (tests/unit/boot, TB="tb_boot.sv <this file>"); counts the whole run. Reads the ROB, the LSU and its
// D$, rename and fetch hierarchically. For each piece, the cycles it could remove:
//   - commit: every cycle without a commit, charged to the ROB head (empty: what fetch waits on, or the refill after
//     the last flush by its cause; the head's DTLB retry; a load by its LQ state; a store; a serializing op; another
//     incomplete op; complete but held);
//   - checkpoints: each mispredicted branch's wait from its resolution in EX to commit's flush (recovery at commit);
//   - DTLB retry without the flush: each retry (the head missed the DTLB and now translates: flush and refetch), load
//     or store; its wait at the head before the flush, the stall until it commits again, and the cycles a replay from
//     the LQ would have saved: it would have completed RPL cycles after the last DTLB fill of its page;
//   - FENCE.I by generation: FENCE.Is and the I$ sweep's cycles;
//   - the I$: refills and fetch's parked cycles, split into a refill of the line after the previous refill's (what a
//     next-line prefetch on a miss covers), of the line after the last block fetch delivered (sequential flow), and
//     the rest;
//   - the micro-BTB: shadow tables of 64, 128 and 256 entries (2 ways, full tags) kept with the real one's updates
//     (the 64 one mirrors it); each F2 override of a taken exit the micro-BTB missed, and whether each shadow held
//     its block;
//   - the D$'s miss entries: occupancy; load requests that found every entry busy; cycles a load waits for a free
//     entry; store drains waiting on their line;
//   - early retirement and ownership: rename held by a full ROB with the head a load waiting on a miss (or another
//     incomplete op); by a full SQ while the drain waits on a store's line.
// Prints at the end: smt2_prof_m6: key value ...
module smt2_prof_m6
  import tg_pkg::*, tg_trace_pkg::*, tg_core_pkg::*;
#(parameter int CW = 2, parameter int NM = 4, parameter int NLQ = 16, parameter int RPL = 5) (
  input logic                    clk, rst,
  input logic [CW-1:0]           tv,
  input tr_rec_t [CW-1:0]        tr,
  // ROB
  input logic                    do_flush, do_irq, do_trap, do_icinv, rpl,
  input logic [CW-1:0]           mf,
  input robid_t [CW-1:0]         hid,
  input logic                    br_valid, br_misp, br_exc,
  input robid_t                  br_rob, head_q,
  input int                      rob_cnt,
  input logic                    hd_cmp, hd_isld, hd_isst, hd_serial,
  input logic [2:0]              hd_sys,
  input logic [63:0]             hd_pc,
  input logic [LQW-2:0]          hd_lq,
  // LSU and D$
  input logic                    hd_tlb, hd_retry, hd_ldtlb,
  input logic [26:0]             hd_vpn, fill_vpn,
  input logic                    dt_fill,
  input logic [NLQ-1:0]          lq_v, lq_wany,
  input logic [NLQ-1:0][3:0]     lq_st,
  input logic [NM-1:0]           mbusy,
  input logic                    rq_v, a_ans, f_any, st_req, st_ack, st_busy,
  // rename
  input logic                    de_take,
  input logic [1:0]              rn_valid, rn_st,
  input logic [2:0]              rob_room, sq_room,
  // fetch
  input logic                    f_ready, miss_park, r_start, wk_q, ivs_done, f2_deliver,
  input logic [38:6]             miss_line,
  input logic [63:0]             f2_pc,
  input logic                    f2_override, ovr_tk, ovr_ras, ovr_s, f2_hit_q,
  input logic                    u_valid, u_way, u_inval,
  input logic [38:4]             u_pc
);
  localparam logic [3:0] L_MISS = 4'd3, L_STQ = 4'd4;
  localparam int NC = 15;   // zero-commit causes
  // 0 empty: I$ sweep, 1 empty: I$ miss, 2 empty: ITLB walk, 3 empty: refill after a mispredict, 4 ... after a replay,
  // 5 ... after another flush, 6 empty: other, 7 head DTLB retry, 8 head load: D$ miss, 9 ... waits for a store,
  // 10 ... other, 11 head store, 12 head serializing, 13 head other incomplete, 14 head complete but held
  localparam int NH = 7;    // mispredict waits: 0-2, 3-5, 6-10, 11-20, 21-50, 51-100, more
  localparam int NS = 3;    // shadow micro-BTBs of 64, 128, 256 entries
  function automatic int sw_of(input int s);
    return s == 0 ? 5 : s == 1 ? 6 : 7;
  endfunction
  function automatic int hbin(input longint unsigned w);
    return w <= 2 ? 0 : w <= 5 ? 1 : w <= 10 ? 2 : w <= 20 ? 3 : w <= 50 ? 4 : w <= 100 ? 5 : 6;
  endfunction

  longint unsigned cyc, ins, zc [NC], fl_t;
  int unsigned     fl_kind;   // the last flush: 3 mispredict, 4 replay, 5 other
  // checkpoints
  longint unsigned t_res [1 << ROBW];
  longint unsigned n_misp, w_misp, h_misp [NH];
  // DTLB retries
  longint unsigned fill_t [longint unsigned];
  longint unsigned hd_since, n_rt [2], c_head [2], c_stall [2], c_save [2], n_part;
  robid_t          head_prev;
  logic            pend;
  int unsigned     pend_k;
  longint unsigned pend_t, pend_pc, pend_head, pend_fill;
  // FENCE.I and the I$
  longint unsigned n_fi, c_sweep, n_ref [3], c_park [3], c_park_zc [3];
  int unsigned     ref_cls;
  logic [38:6]     last_ref, last_dl;
  // micro-BTB shadows
  logic [38:4]     stag [NS][2][128];
  logic            sval [NS][2][128];
  longint unsigned n_ovr [3], caught [3][NS];
  // D$ miss entries, ROB and SQ full
  longint unsigned occ [NM + 1], n_rq, n_rq_full, n_rq_none, c_ld_wait_full, c_zc_wait_full;
  longint unsigned c_dr_wait, c_dr_line, c_dr_entry;
  longint unsigned c_rob_full, c_rob_ldmiss, c_rob_oth, c_sq_full, c_sq_stmiss;
  int              ob;

  initial begin
    for (int s = 0; s < NS; s++) for (int w = 0; w < 2; w++) for (int i = 0; i < 128; i++) sval[s][w][i] = 1'b0;
  end

  always @(posedge clk) begin
    if (rst) begin
      cyc = 0; ins = 0; fl_t = 0; fl_kind = 5; n_misp = 0; w_misp = 0; hd_since = 0; n_part = 0; pend = 1'b0;
      head_prev = '0;
      n_fi = 0; c_sweep = 0; ref_cls = 2; last_ref = '0; last_dl = '0;
      n_rq = 0; n_rq_full = 0; n_rq_none = 0; c_ld_wait_full = 0; c_zc_wait_full = 0;
      c_dr_wait = 0; c_dr_line = 0; c_dr_entry = 0; c_rob_full = 0; c_rob_ldmiss = 0; c_rob_oth = 0;
      c_sq_full = 0; c_sq_stmiss = 0;
      for (int c = 0; c < NC; c++) zc[c] = 0;
      for (int h = 0; h < NH; h++) h_misp[h] = 0;
      for (int k = 0; k < 2; k++) begin n_rt[k] = 0; c_head[k] = 0; c_stall[k] = 0; c_save[k] = 0; end
      for (int k = 0; k < 3; k++) begin
        n_ref[k] = 0; c_park[k] = 0; c_park_zc[k] = 0; n_ovr[k] = 0;
        for (int s = 0; s < NS; s++) caught[k][s] = 0;
      end
      for (int k = 0; k <= NM; k++) occ[k] = 0;
    end else begin
      automatic logic       any_cm = |tv;
      automatic logic [3:0] hst = lq_st[hd_lq];
      automatic logic       ld_wait_full = 1'b0;
      automatic logic       done = 1'b0;
      automatic longint unsigned dt = 0;
      cyc++;
      for (int j = 0; j < CW; j++) if (tv[j] && tr[j].kind == TR_RETIRE) ins++;
      for (int i = 0; i < NLQ; i++) if (lq_v[i] && lq_wany[i] && lq_st[i] == L_MISS && !f_any) ld_wait_full = 1'b1;
      // ---- zero-commit cycles by the head's state ----
      if (!any_cm) begin
        automatic int c;
        if (rob_cnt == 0) begin
          if (!ivs_done) c = 0;
          else if (miss_park) c = 1;
          else if (wk_q) c = 2;
          else if (cyc - fl_t <= 64) c = int'(fl_kind);
          else c = 6;
        end else if (hd_tlb) c = 7;
        else if (!hd_cmp && hd_isld) c = hst == L_MISS ? 8 : hst == L_STQ ? 9 : 10;
        else if (!hd_cmp && hd_isst) c = 11;
        else if (hd_sys != 3'd0 || hd_serial) c = 12;
        else if (!hd_cmp) c = 13;
        else c = 14;
        zc[c]++;
        if (c == 8 && lq_wany[hd_lq] && !f_any) c_zc_wait_full++;
      end
      // ---- flushes: the last one's cause for the refill after it ----
      if (do_flush) begin
        fl_t = cyc;
        fl_kind = (do_irq || do_trap) ? 5 : rpl ? 4 : |mf ? 3 : 5;
        if (do_icinv) n_fi++;
      end
      // ---- checkpoints: resolution to commit's flush ----
      if (br_valid && br_misp && !br_exc) t_res[br_rob] = cyc;
      if (do_flush && !do_irq && !do_trap && !rpl && |mf) begin
        for (int j = 0; j < CW; j++)
          if (mf[j]) begin
            automatic longint unsigned w = cyc - t_res[hid[j]];
            automatic int hb = hbin(w);
            n_misp++;
            w_misp += w;
            h_misp[hb]++;
            break;
          end
      end
      // ---- DTLB retries ----
      if (dt_fill) fill_t[longint'(fill_vpn)] = cyc;
      if (pend) begin
        for (int j = 0; j < CW; j++)
          if (tv[j] && tr[j].kind == TR_RETIRE && tr[j].pc == pend_pc && !done) begin
            done = 1'b1;
            dt = cyc - pend_t;
          end
        if (!done && do_flush) begin done = 1'b1; dt = cyc - pend_t; n_part++; end
        if (done) begin
          automatic longint unsigned rc = pend_t + dt;     // when it committed again
          automatic longint unsigned nc = (pend_fill + RPL > pend_head ? pend_fill + RPL : pend_head) + 1;
          c_stall[pend_k] += dt;
          if (rc > nc) c_save[pend_k] += rc - nc;
          pend = 1'b0;
        end
      end
      if (do_flush && !do_irq && !do_trap && rpl && hd_tlb && hd_retry) begin
        automatic int k = hd_ldtlb ? 0 : 1;
        n_rt[k]++;
        c_head[k] += cyc - hd_since;
        pend = 1'b1; pend_k = k; pend_t = cyc; pend_pc = hd_pc; pend_head = hd_since;
        pend_fill = fill_t.exists(longint'(hd_vpn)) ? fill_t[longint'(hd_vpn)] : cyc - 1;
        if (pend_fill < hd_since) pend_fill = hd_since;   // translated before it reached the head
      end
      if (head_q != head_prev) hd_since = cyc;
      head_prev = head_q;
      // ---- FENCE.I's sweep and the I$ ----
      if (!ivs_done) c_sweep++;
      if (f2_deliver) last_dl = f2_pc[38:6];
      if (r_start) begin
        ref_cls = (miss_line == last_ref + 1) ? 0 : (miss_line == last_dl + 1) ? 1 : 2;
        n_ref[ref_cls]++;
        last_ref = miss_line;
      end
      if (miss_park) begin
        c_park[ref_cls]++;
        if (!any_cm) c_park_zc[ref_cls]++;
      end
      // ---- micro-BTB: overrides of a taken exit it missed, and the shadows ----
      if (f2_override && ovr_tk && !f2_hit_q) begin
        automatic int k = ovr_ras ? 1 : ovr_s ? 2 : 0;
        n_ovr[k]++;
        for (int s = 0; s < NS; s++) begin
          automatic int i = int'(f2_pc[4 +: 7]) & ((1 << sw_of(s)) - 1);
          if ((sval[s][0][i] && stag[s][0][i] == f2_pc[38:4]) || (sval[s][1][i] && stag[s][1][i] == f2_pc[38:4]))
            caught[k][s]++;
        end
      end
      if (f_ready && u_valid)
        for (int s = 0; s < NS; s++) begin
          automatic int i = int'(u_pc[4 +: 7]) & ((1 << sw_of(s)) - 1);
          automatic int hw = (sval[s][0][i] && stag[s][0][i] == u_pc) ? 0 :
                             (sval[s][1][i] && stag[s][1][i] == u_pc) ? 1 : -1;
          if (s == 0) begin                 // the real one's organization: the update names the way
            sval[s][u_way][i] = !u_inval;
            stag[s][u_way][i] = u_pc;
          end else if (u_inval) begin
            if (hw >= 0) sval[s][hw][i] = 1'b0;
          end else begin
            automatic int w = hw >= 0 ? hw : int'(u_way);
            sval[s][w][i] = 1'b1;
            stag[s][w][i] = u_pc;
          end
        end
      // ---- the D$'s miss entries ----
      ob = $countones(mbusy);
      occ[ob]++;
      if (rq_v) begin
        n_rq++;
        if (!a_ans && !f_any) n_rq_full++;
        else if (!a_ans) n_rq_none++;
      end
      if (ld_wait_full) c_ld_wait_full++;
      if (st_req && !st_ack) begin
        c_dr_wait++;
        if (st_busy) c_dr_line++;
        else if (!f_any) c_dr_entry++;
      end
      // ---- rename held by a full ROB or SQ ----
      if (!de_take && rn_valid != 2'b00) begin
        automatic int nrob = rn_valid[1] ? 2 : 1;
        automatic int nst = int'(rn_valid[0] && rn_st[0]) + int'(rn_valid[1] && rn_st[1]);
        if (!rob_room[nrob]) begin
          c_rob_full++;
          if (!hd_cmp && hd_isld && hst == L_MISS) c_rob_ldmiss++;
          else if (!hd_cmp) c_rob_oth++;
        end
        if (!sq_room[nst]) begin
          c_sq_full++;
          if (st_req && !st_ack && (st_busy || !f_any)) c_sq_stmiss++;
        end
      end
    end
  end
  final
    $display("smt2_prof_m6: cycles %0d instret %0d zc_fe_sweep %0d zc_fe_icmiss %0d zc_fe_itlb %0d zc_fe_misp %0d zc_fe_rpl %0d zc_fe_flush %0d zc_fe_other %0d zc_dtlb %0d zc_ld_miss %0d zc_ld_stq %0d zc_ld_other %0d zc_st %0d zc_serial %0d zc_exec %0d zc_held %0d misp %0d misp_wait %0d mw_0_2 %0d mw_3_5 %0d mw_6_10 %0d mw_11_20 %0d mw_21_50 %0d mw_51_100 %0d mw_gt100 %0d rt_ld %0d rt_ld_head %0d rt_ld_stall %0d rt_ld_save %0d rt_st %0d rt_st_head %0d rt_st_stall %0d rt_st_save %0d rt_ended_by_flush %0d fencei %0d sweep_cyc %0d ref_seqref %0d ref_seqdl %0d ref_other %0d park_seqref %0d park_seqdl %0d park_other %0d park_zc_seqref %0d park_zc_seqdl %0d park_zc_other %0d ovr_br %0d ovr_ret %0d ovr_strad %0d ub64_br %0d ub128_br %0d ub256_br %0d ub64_ret %0d ub128_ret %0d ub256_ret %0d ub64_strad %0d ub128_strad %0d ub256_strad %0d occ0 %0d occ1 %0d occ2 %0d occ3 %0d occ4 %0d rq %0d rq_full %0d rq_none %0d ld_wait_full %0d zc_wait_full %0d dr_wait %0d dr_line %0d dr_entry %0d rob_full %0d rob_full_ldmiss %0d rob_full_oth %0d sq_full %0d sq_full_stmiss %0d",
             cyc, ins, zc[0], zc[1], zc[2], zc[3], zc[4], zc[5], zc[6], zc[7], zc[8], zc[9], zc[10], zc[11], zc[12],
             zc[13], zc[14], n_misp, w_misp, h_misp[0], h_misp[1], h_misp[2], h_misp[3], h_misp[4], h_misp[5],
             h_misp[6], n_rt[0], c_head[0], c_stall[0], c_save[0], n_rt[1], c_head[1], c_stall[1], c_save[1], n_part,
             n_fi, c_sweep, n_ref[0], n_ref[1], n_ref[2], c_park[0], c_park[1], c_park[2], c_park_zc[0],
             c_park_zc[1], c_park_zc[2], n_ovr[0], n_ovr[1], n_ovr[2], caught[0][0], caught[0][1], caught[0][2],
             caught[1][0], caught[1][1], caught[1][2], caught[2][0], caught[2][1], caught[2][2], occ[0], occ[1],
             occ[2], occ[3], occ[NM], n_rq, n_rq_full, n_rq_none, c_ld_wait_full, c_zc_wait_full, c_dr_wait,
             c_dr_line, c_dr_entry, c_rob_full, c_rob_ldmiss, c_rob_oth, c_sq_full, c_sq_stmiss);
endmodule

bind tg_core smt2_prof_m6 #(.CW(COMMIT_WIDTH), .NM(DC_MSHRS), .NLQ(LQ_ENTRIES)) u_smt2_prof_m6 (
  .clk, .rst, .tv(trace_valid_o), .tr(trace_o),
  .do_flush(u_rob.do_flush), .do_irq(u_rob.do_irq), .do_trap(u_rob.do_trap), .do_icinv(u_rob.do_icinv),
  .rpl(u_rob.rpl_h[0]), .mf(u_rob.mf & ~u_rob.hold_le), .hid(u_rob.hid), .br_valid(u_rob.br_valid),
  .br_misp(u_rob.br_misp), .br_exc(u_rob.br_exc), .br_rob(u_rob.br_rob), .head_q(u_rob.head_q),
  .rob_cnt(int'(u_rob.cnt)), .hd_cmp(u_rob.cmp_h[0]), .hd_isld(u_rob.hp[0].is_ld), .hd_isst(u_rob.hp[0].is_st),
  .hd_serial(u_rob.hp[0].serial), .hd_sys(3'(u_rob.hp[0].sys)), .hd_pc(u_rob.hp[0].pc),
  .hd_lq(u_rob.hp[0].lq[LQW-2:0]),
  .hd_tlb, .hd_retry, .hd_ldtlb(u_lsu.hd_ld), .hd_vpn(u_lsu.hd_va[38:12]), .fill_vpn(u_lsu.pw_vpn),
  .dt_fill(u_lsu.dt_fill), .lq_v(u_lsu.lq_v_q), .lq_wany(u_lsu.lq_wany_q), .lq_st(u_lsu.lq_st_q),
  .mbusy(u_lsu.u_dc.g_mn.busy), .rq_v(u_lsu.u_dc.g_mn.rq_v_q),
  .a_ans(u_lsu.u_dc.g_mn.a_retry || u_lsu.u_dc.g_mn.a_wait), .f_any(u_lsu.u_dc.g_mn.f_any),
  .st_req(u_lsu.st_req), .st_ack(u_lsu.st_ack), .st_busy(u_lsu.u_dc.g_mn.st_busy),
  .de_take, .rn_valid(u_rn.rn_valid_q),
  .rn_st({u_rn.rn_uop_q[1].d.cls == C_ST, u_rn.rn_uop_q[0].d.cls == C_ST}),
  .rob_room(u_rn.rob_room), .sq_room(u_rn.sq_room),
  .f_ready(u_fetch.ready), .miss_park(u_fetch.miss_q || u_fetch.am_go), .r_start(u_fetch.r_start),
  .wk_q(u_fetch.wk_q), .ivs_done(u_fetch.ivs_done), .f2_deliver(u_fetch.f2_deliver),
  .miss_line(u_fetch.miss_pc_q[38:6]), .f2_pc(u_fetch.f2_pc_q), .f2_override(u_fetch.f2_override),
  .ovr_tk(u_fetch.ovr_tk), .ovr_ras(u_fetch.ovr_ras), .ovr_s(u_fetch.ovr_s), .f2_hit_q(u_fetch.f2_hit_q),
  .u_valid(u_fetch.u_valid), .u_way(u_fetch.u_way), .u_inval(u_fetch.u_inval), .u_pc(u_fetch.u_pc));
