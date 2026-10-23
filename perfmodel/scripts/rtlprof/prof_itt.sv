// Measurement-only indirect-jump profile (smt2-study, area_recovery.md §7.12) for M9's indirect-target predictor
// (DR-190): the stream scripts/m9_rtl.py replays through shadow indirect-target tables, as tgsim's itt_entries.
// Bound into tg_core, for the Linux boot (tests/unit/boot, TB="tb_boot.sv <this file>") or tg_vsim (sim/,
// COV_EVENTS=<this file>). For every committed JALR other than a return (tgsim's is_ret: rd x0, rs1 x1 or x5, offset
// 0; c.jr and c.jalr included) it prints
//   smt2_itt: <core> <thread> <cycle> <pc> <target> <misp> <hit> <gap>
//   - target: the PC of its thread's next instruction to retire, trap or take an interrupt;
//   - misp: commit flushed it as a mispredict;
//   - hit: the micro-BTB predicted taken at it (dispatch's ubtb_hit, kept by ROB entry);
//   - gap: cycles from its retirement to that next instruction's: the commit stall a mispredict costs.
// Every 10M cycles, and at the end: smt2_itt_at: core C cycles N instret I wfi W ijmp J ijmp_misp M misp K misp_gap G,
// where wfi counts cycles with a WFI at the committing thread's ROB head (the boot's idle waits, which a faster core
// does not shorten), and misp and misp_gap count every mispredict and its stall, for the indirect jumps' share.
module smt2_prof_itt
  import tg_pkg::*, tg_core_pkg::*;
#(parameter int CW = 2, parameter int DW = 2, parameter int CID = 0) (
  input logic                    clk, rst,
  input logic [DW-1:0]           ds_v,
  input robid_t [DW-1:0]         ds_rob,
  input logic [DW-1:0]           ds_hit,
  input tid_t                    tcm,           // the committing thread
  input logic [CW-1:0]           ret, mf,
  input robid_t [CW-1:0]         hid,
  input logic [CW-1:0][63:0]     rpc,
  input logic [CW-1:0][31:0]     rinsn,
  input logic [CW-1:0]           rrvc,
  input logic                    do_trap, do_irq, hd_wfi,
  input logic [63:0]             hd_pc
);
  localparam int NT = NUM_THREADS;
  initial if (CW != 2 || DW != 2) $fatal(1, "smt2_prof_itt: the bind's port lists assume two slots");
  function automatic logic ijmp(input logic [31:0] i, input logic rvc);   // a JALR other than a return
    logic [4:0]  rd, rs1;
    logic [11:0] imm;
    if (rvc) begin   // c.jr (rd x0) and c.jalr (rd x1): 100x, rs1 not x0, rs2 x0, quadrant 2
      if (i[15:13] != 3'b100 || i[11:7] == 5'd0 || i[6:2] != 5'd0 || i[1:0] != 2'b10) return 1'b0;
      rd = i[12] ? 5'd1 : 5'd0;
      rs1 = i[11:7];
      imm = '0;
    end else begin
      if (i[6:0] != 7'b1100111 || i[14:12] != 3'b000) return 1'b0;
      rd = i[11:7];
      rs1 = i[19:15];
      imm = i[31:20];
    end
    return !(rd == 5'd0 && (rs1 == 5'd1 || rs1 == 5'd5) && imm == 12'd0);
  endfunction
  logic [(1 << ROBW)-1:0] hit_by;
  longint unsigned cyc, ins, wfi, n_ij, n_ijm, n_m, g_m;
  longint unsigned p_t [NT], m_t [NT];
  logic [63:0] p_pc [NT];
  logic p [NT], p_misp [NT], p_hit [NT], m [NT];
  function automatic string line();
    return $sformatf("core %0d cycles %0d instret %0d wfi %0d ijmp %0d ijmp_misp %0d misp %0d misp_gap %0d", CID, cyc,
                     ins, wfi, n_ij, n_ijm, n_m, g_m);
  endfunction
  always_ff @(posedge clk) begin
    if (rst) begin
      cyc = 0; ins = 0; wfi = 0; n_ij = 0; n_ijm = 0; n_m = 0; g_m = 0; hit_by = '0;
      for (int t = 0; t < NT; t++) begin p[t] = 1'b0; m[t] = 1'b0; end
    end else begin
      automatic int t = int'(tcm);
      automatic logic ev = 1'b0;          // the thread's first event this cycle: a retirement, a trap or an interrupt
      automatic logic [63:0] ev_pc = '0;
      cyc++;
      if (hd_wfi) wfi++;
      for (int k = 0; k < DW; k++) if (ds_v[k]) hit_by[ds_rob[k]] = ds_hit[k];
      if (do_trap || do_irq) begin ev = 1'b1; ev_pc = hd_pc; end
      for (int j = 0; j < CW; j++)
        if (ret[j]) begin
          if (!ev) begin ev = 1'b1; ev_pc = rpc[j]; end
          ins++;
          if (p[t]) begin   // the pending jump's target retires in this cycle's group
            $display("smt2_itt: %0d %0d %0d %h %h %0d %0d %0d", CID, t, p_t[t], p_pc[t], rpc[j], p_misp[t], p_hit[t],
                     cyc - p_t[t]);
            p[t] = 1'b0;
          end
          if (ijmp(rinsn[j], rrvc[j])) begin
            n_ij++;
            if (mf[j]) n_ijm++;
            p[t] = 1'b1; p_t[t] = cyc; p_pc[t] = rpc[j]; p_misp[t] = mf[j]; p_hit[t] = hit_by[hid[j]];
          end
        end
      // a jump retired in an earlier cycle: its target is the thread's first event now (a trap or an interrupt too)
      if (p[t] && ev && p_t[t] != cyc) begin
        $display("smt2_itt: %0d %0d %0d %h %h %0d %0d %0d", CID, t, p_t[t], p_pc[t], ev_pc, p_misp[t], p_hit[t],
                 cyc - p_t[t]);
        p[t] = 1'b0;
      end
      // every mispredict: its stall until the thread's next event
      if (m[t] && ev) begin g_m += cyc - m_t[t]; m[t] = 1'b0; end
      if (|mf) begin n_m++; m[t] = 1'b1; m_t[t] = cyc; end
      if (cyc % 64'd10_000_000 == 0) $display("smt2_itt_at: %s", line());
    end
  end
  final $display("smt2_itt_at: %s", line());
endmodule

bind tg_core smt2_prof_itt #(.CW(COMMIT_WIDTH), .DW(DISPATCH_WIDTH), .CID(CORE_ID)) u_smt2_prof_itt (
  .clk, .rst, .ds_v(u_rn.ds_valid), .ds_rob({u_rn.ds_uop[1].rob, u_rn.ds_uop[0].rob}),
  .ds_hit({u_rn.ds_uop[1].ubtb_hit, u_rn.ds_uop[0].ubtb_hit}), .tcm(u_rob.t_cm),
  .ret(u_rob.ret), .mf(u_rob.mf & ~u_rob.hold_le), .hid(u_rob.hid),
  .rpc({u_rob.hp[1].pc, u_rob.hp[0].pc}), .rinsn({u_rob.hp[1].insn, u_rob.hp[0].insn}),
  .rrvc({u_rob.hp[1].rvc, u_rob.hp[0].rvc}), .do_trap(u_rob.do_trap), .do_irq(u_rob.do_irq),
  .hd_wfi(u_rob.cnt != 0 && u_rob.hp[0].sys == SYS_WFI), .hd_pc(u_rob.hp[0].pc));
