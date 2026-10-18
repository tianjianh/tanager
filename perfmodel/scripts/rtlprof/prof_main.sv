// Measurement-only profile binds (docs/perf/area_recovery.md §6.4) for main's core: commit's flushes by cause with the PCs
// of replayed loads, and rename's stalls by cause. Bound into tg_rename and tg_rob; counts from reset and prints at
// the end of the run. Not part of sim/: on a scratch tree, make -C sim CFG=st COV_EVENTS=<this file>.
module smt2_prof_rob (input logic clk, rst, empty, do_flush, do_irq, do_trap, rpl, serial, misp,
                      input logic [63:0] hd_pc);
  longint unsigned c_empty, n_irq, n_trap, n_rpl, n_ser, n_misp, n_oth;
  int unsigned rpl_pc [longint unsigned];
  always_ff @(posedge clk) begin
    if (rst) begin
      c_empty <= 0; n_irq <= 0; n_trap <= 0; n_rpl <= 0; n_ser <= 0; n_misp <= 0; n_oth <= 0;
    end else begin
      if (empty) c_empty <= c_empty + 1;
      if (do_flush) begin
        if (do_irq) n_irq <= n_irq + 1;
        else if (do_trap) n_trap <= n_trap + 1;
        else if (rpl) begin
          n_rpl <= n_rpl + 1;
          if (rpl_pc.exists(hd_pc)) rpl_pc[hd_pc] = rpl_pc[hd_pc] + 1;
          else rpl_pc[hd_pc] = 1;
        end
        else if (serial) n_ser <= n_ser + 1;
        else if (misp) n_misp <= n_misp + 1;
        else n_oth <= n_oth + 1;
      end
    end
  end
  final begin
    $display("smt2_prof_rob: rob_empty %0d flushes: irq %0d trap %0d replay %0d serial %0d mispredict %0d other %0d",
             c_empty, n_irq, n_trap, n_rpl, n_ser, n_misp, n_oth);
    foreach (rpl_pc[pc]) if (rpl_pc[pc] >= 20) $display("smt2_prof_rpl: pc %h replays %0d", pc, rpl_pc[pc]);
  end
endmodule

// Rename's cycles by what holds its group (first reason in this order), and dispatch's IQ-bank stalls per queue
module smt2_prof_rn (
  input logic        clk, rst, any, fire, flush, ds_free, rob_f, lq_f, sq_f, tag_s, llt_s, rn_ok, irdy, frdy,
  input logic        ser_wait, block_q,
  input logic [1:0]  dsv, hasq,
  input logic [2:0]  q0, q1,
  input logic [9:0]  ibf
);
  longint unsigned c_idle, c_fire, c_ds, c_rob, c_lq, c_sq, c_tag, c_llt, c_res, c_rdy, c_ser, c_blk, c_oth;
  longint unsigned c_iqf[8];
  always_ff @(posedge clk) begin
    if (rst) begin
      c_idle <= 0; c_fire <= 0; c_ds <= 0; c_rob <= 0; c_lq <= 0; c_sq <= 0; c_tag <= 0; c_llt <= 0; c_res <= 0;
      c_rdy <= 0; c_ser <= 0; c_blk <= 0; c_oth <= 0;
      for (int i = 0; i < 8; i++) c_iqf[i] <= 0;
    end else if (!flush) begin
      if (!any) c_idle <= c_idle + 1;
      else if (fire) c_fire <= c_fire + 1;
      else if (!ds_free) c_ds <= c_ds + 1;
      else if (rob_f) c_rob <= c_rob + 1;
      else if (lq_f) c_lq <= c_lq + 1;
      else if (sq_f) c_sq <= c_sq + 1;
      else if (tag_s) c_tag <= c_tag + 1;
      else if (llt_s) c_llt <= c_llt + 1;
      else if (!rn_ok) c_res <= c_res + 1;
      else if (!irdy || !frdy) c_rdy <= c_rdy + 1;
      else if (ser_wait) c_ser <= c_ser + 1;
      else if (block_q) c_blk <= c_blk + 1;
      else c_oth <= c_oth + 1;
      if (dsv[0] && hasq[0] && !ibf[2 * q0]) c_iqf[q0] <= c_iqf[q0] + 1;
      else if (dsv[1] && hasq[1] && !ibf[2 * q1 + 1]) c_iqf[q1] <= c_iqf[q1] + 1;
    end
  end
  final
    $display("smt2_prof_rn: idle %0d fire %0d ds_full %0d rob_full %0d lq_full %0d sq_full %0d tags %0d llt %0d fl_div %0d rdytab %0d serial %0d block %0d other %0d iqfull_a0 %0d iqfull_a1 %0d iqfull_ld %0d iqfull_sta %0d iqfull_fp %0d",
             c_idle, c_fire, c_ds, c_rob, c_lq, c_sq, c_tag, c_llt, c_res, c_rdy, c_ser, c_blk, c_oth, c_iqf[0],
             c_iqf[1], c_iqf[2], c_iqf[3], c_iqf[4]);
endmodule

bind tg_rename smt2_prof_rn u_smt2_prof_rn (
  .clk, .rst, .any(|rn_valid_q), .fire(rn_fire), .flush, .ds_free,
  .rob_f(rob_cnt(rtail_q, rob_head) + $countones(rn_valid_q) > ROB_ENTRIES),
  .lq_f(lq_cnt(ltail_q, lq_head) + ren_nld(rn_uop_q, rn_valid_q) > LQ_ENTRIES),
  .sq_f(sq_cnt(stail_q, sq_head) + ren_nst(rn_uop_q, rn_valid_q) > SQ_ENTRIES),
  .tag_s(tag_short), .llt_s(llt_short), .rn_ok, .irdy(irdy_ready), .frdy(frdy_ready),
  .ser_wait(rn_serial && !window_empty), .block_q, .dsv(ds_valid_q), .hasq({ds_ren_q[1].has_q, ds_ren_q[0].has_q}),
  .q0(3'(ds_ren_q[0].q)), .q1(3'(ds_ren_q[1].q)), .ibf(10'(iq_bank_free)));
bind tg_rob smt2_prof_rob u_smt2_prof_rob (.clk, .rst, .empty(cnt == 0), .do_flush, .do_irq, .do_trap,
  .rpl(rpl_h[0]), .serial(cmp_h[0] && hp[0].serial), .misp(|(mf & ~hold_le)), .hd_pc(hp[0].pc));
