// Measurement only (smt2-study, area_recovery.md §6.15): tg_tage's training updates, one line per event, to set
// beside tgsim's TGSIM_BTTRACE. Bound into every tg_tage. +ptage_all: every update; else the chosen (block, slot)s,
// +ptage_blk0..3=HEX (blk = pc[38:4]) and +ptage_slot0..3=N, by default ud's four loop exits. Also each request the
// full queue drops.
//   T cycle base slot taken pred b=before/after t<t>:idx/tag w0 w1 > w0' w1' (each v.slot.tag.ctr.u)
//   D cycle (a request dropped)
module smt2_prof_tage #(parameter int NP = 8, parameter int NT = 2, parameter int LI = 11, parameter int TW = 9,
                        parameter int BI = 11, parameter int HW = 64) (
  input logic                         clk, rst,
  input logic [NT*36-1:0]             rb, wb,
  input logic [2*NP-1:0]              brb, bwb,
  input logic                         t2_v_q,
  input logic [NT*(LI+TW)+BI+3+2-1:0] t2_q,
  input logic [1:0]                   t_v,
  input logic [2:0]                   qn_q,
  input logic                         deq
);
  localparam int IXW = NT * (LI + TW) + BI;
  logic [38:4] tb [4];
  int          ts [4];
  bit          all;
  initial begin
    all = $test$plusargs("ptage_all");
    tb[0] = 35'h0800002e; ts[0] = 1;
    tb[1] = 35'h0800004d; ts[1] = 7;
    tb[2] = 35'h0800003d; ts[2] = 6;
    tb[3] = 35'h0800004c; ts[3] = 0;
    for (int i = 0; i < 4; i++) begin
      void'($value$plusargs($sformatf("ptage_blk%0d=%%h", i), tb[i]));
      void'($value$plusargs($sformatf("ptage_slot%0d=%%d", i), ts[i]));
    end
  end
  function automatic string sub(input logic [17:0] e);   // {v, slot[2:0], tag[8:0], ctr[2:0], u[1:0]}
    return $sformatf("%0d.%0d.%03x.%0d.%0d", e[17], e[16:14], e[13:5], e[4:2], e[1:0]);
  endfunction
  function automatic bit chosen(input logic [BI-1:0] base, input logic [2:0] slot);
    if (all) return 1'b1;
    for (int i = 0; i < 4; i++) if (base == tb[i][4 +: BI] && int'(slot) == ts[i]) return 1'b1;
    return 1'b0;
  endfunction
  int unsigned cyc;
  always_ff @(posedge clk) begin
    if (rst) cyc <= 0;
    else begin
      int n;
      cyc <= cyc + 1;
      // the queue's drops: requests that find it full (tg_tage's enqueue, after this cycle's dequeue)
      n = int'(qn_q) - (deq ? 1 : 0);
      for (int j = 0; j < 2; j++)
        if (t_v[j]) begin
          if (n < 4) n++;
          else $display("PT D %0d", cyc);
        end
      if (t2_v_q && chosen(t2_q[5 + IXW - 1 -: BI], t2_q[4:2])) begin
        string s;
        s = $sformatf("PT T %0d %03x %0d taken=%0d pred=%0d b=%0d/%0d", cyc, t2_q[5 + IXW - 1 -: BI], t2_q[4:2],
                      t2_q[1], t2_q[0], brb[2*t2_q[4:2] +: 2], bwb[2*t2_q[4:2] +: 2]);
        for (int t = 0; t < NT; t++)
          s = {s, $sformatf(" t%0d:%03x/%03x %s %s > %s %s", t, t2_q[5 + t*(LI+TW) +: LI],
                            t2_q[5 + t*(LI+TW)+LI +: TW], sub(rb[t*36 +: 18]), sub(rb[t*36+18 +: 18]),
                            sub(wb[t*36 +: 18]), sub(wb[t*36+18 +: 18]))};
        $display("%s", s);
      end
    end
  end
endmodule

bind tg_tage smt2_prof_tage #(.NP(NP), .NT(NT), .LI(LI), .TW(TW), .BI(BI), .HW(HW)) u_ptage (
  .clk, .rst, .rb, .wb, .brb, .bwb, .t2_v_q, .t2_q, .t_v, .qn_q, .deq);
