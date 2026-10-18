// Measurement-only replay profile (smt2-study, area_recovery.md §6.10) for fpu-2's levers tree (a857a07), meant for
// the Linux boot (tests/unit/boot, TB="tb_boot.sv <this file>"); counts the whole run. Bound into tg_core:
//   - commit's replay flushes, split into ordering replays (the LSU found a younger load that ran before an older
//     store to its bytes: the head's replay flag without a DTLB miss) and DTLB retries (the head missed the DTLB and
//     now translates);
//   - for each, the cycles until the replayed instruction commits again (the commit stall it costs; ended early by
//     another flush, a trap or an interrupt);
//   - the ordering replays by PC, and how many a wait table would have caught: one bit per entry, indexed by
//     PC[k+1:2] (no tag, never cleared), set by a replay; a replay finding its bit set counts as caught. Tables of
//     16, 64, 256 and 1024 bits, and an exact set of PCs.
// Prints at the end: smt2_prof_rpl: key value ... and smt2_rpl_pc: lines for PCs with 2 or more replays.
module smt2_prof_rpl
  import tg_pkg::*, tg_trace_pkg::*;
#(parameter int CW = 2) (
  input logic                    clk, rst,
  input logic                    do_flush, rpl, do_irq, do_trap, hd_tlb, hd_retry,
  input logic [63:0]             hd_pc,
  input logic [CW-1:0]           tv,
  input tr_rec_t [CW-1:0]        tr
);
  localparam int NT = 4;
  function automatic int tb_of(input int t);   // log2 of the tables' sizes
    return t == 0 ? 4 : t == 1 ? 6 : t == 2 ? 8 : 10;
  endfunction
  longint unsigned cyc, n_ord, n_tlb, c_ord, c_tlb, n_part, caught [NT], c_caught [NT], ex_caught, ex_c_caught;
  logic [1023:0] wt [NT];
  int unsigned pc_n [longint unsigned];
  longint unsigned pc_c [longint unsigned];
  logic pend, pend_ord;
  longint unsigned pend_t, pend_pc;
  logic [NT-1:0] pend_hit;
  logic pend_ex;
  always_ff @(posedge clk) begin
    if (rst) begin
      cyc <= 0; n_ord <= 0; n_tlb <= 0; c_ord <= 0; c_tlb <= 0; n_part <= 0; ex_caught <= 0; ex_c_caught <= 0;
      for (int t = 0; t < NT; t++) begin caught[t] <= 0; c_caught[t] <= 0; wt[t] <= '0; end
      pend <= 1'b0;
    end else begin
      automatic logic done = 1'b0;
      automatic longint unsigned dt = 0;
      cyc <= cyc + 1;
      // the pending replay's instruction commits again (or a flush ends the wait)
      if (pend) begin
        for (int j = 0; j < CW; j++)
          if (tv[j] && tr[j].kind == TR_RETIRE && tr[j].pc == pend_pc && !done) begin
            done = 1'b1;
            dt = cyc - pend_t;
          end
        if (!done && do_flush) begin done = 1'b1; dt = cyc - pend_t; n_part <= n_part + 1; end
        if (done) begin
          if (pend_ord) begin
            c_ord <= c_ord + dt;
            pc_c[pend_pc] = pc_c[pend_pc] + dt;
            for (int t = 0; t < NT; t++) if (pend_hit[t]) c_caught[t] <= c_caught[t] + dt;
            if (pend_ex) ex_c_caught <= ex_c_caught + dt;
          end else c_tlb <= c_tlb + dt;
        end
      end
      if (do_flush && !do_irq && !do_trap && rpl && (!hd_tlb || hd_retry)) begin
        automatic logic ord = !hd_tlb;
        pend <= 1'b1; pend_ord <= ord; pend_t <= cyc; pend_pc <= hd_pc;
        if (ord) begin
          n_ord <= n_ord + 1;
          pend_ex <= pc_n.exists(hd_pc);
          if (pc_n.exists(hd_pc)) begin pc_n[hd_pc] = pc_n[hd_pc] + 1; ex_caught <= ex_caught + 1; end
          else begin pc_n[hd_pc] = 1; pc_c[hd_pc] = 0; end
          for (int t = 0; t < NT; t++) begin
            automatic int idx = int'(hd_pc[2 +: 10]) & ((1 << tb_of(t)) - 1);
            pend_hit[t] <= wt[t][idx];
            if (wt[t][idx]) caught[t] <= caught[t] + 1;
            wt[t][idx] <= 1'b1;
          end
        end else n_tlb <= n_tlb + 1;
      end else if (done) pend <= 1'b0;
    end
  end
  final begin
    $display("smt2_prof_rpl: cycles %0d ord %0d ord_cyc %0d tlb %0d tlb_cyc %0d ended_by_flush %0d pcs %0d exact_caught %0d exact_caught_cyc %0d wt16 %0d wt16_cyc %0d wt64 %0d wt64_cyc %0d wt256 %0d wt256_cyc %0d wt1024 %0d wt1024_cyc %0d",
             cyc, n_ord, c_ord, n_tlb, c_tlb, n_part, pc_n.num(), ex_caught, ex_c_caught, caught[0], c_caught[0],
             caught[1], c_caught[1], caught[2], c_caught[2], caught[3], c_caught[3]);
    foreach (pc_n[pc]) if (pc_n[pc] >= 2) $display("smt2_rpl_pc: pc %h replays %0d cycles %0d", pc, pc_n[pc], pc_c[pc]);
  end
endmodule

bind tg_core smt2_prof_rpl #(.CW(COMMIT_WIDTH)) u_smt2_prof_rpl (
  .clk, .rst, .do_flush(u_rob.do_flush), .rpl(u_rob.rpl_h[0]), .do_irq(u_rob.do_irq), .do_trap(u_rob.do_trap),
  .hd_tlb, .hd_retry, .hd_pc(u_rob.hp[0].pc), .tv(trace_valid_o), .tr(trace_o));
