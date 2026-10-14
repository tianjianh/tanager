// Issue stage (docs/spec/core-pipeline.md §6): one tg_iq per port (ALU queues, LD, STA) sharing
// the woken vector W (tg_wake). Spike S2 structures with STALE = 2 (column clear on retire and
// LLT release). The ALU queues wake their dependants at select; every other wakeup arrives on
// wake_reg (MUL delay line, load and divide completions). The payload leaves in the RF stage.
module tg_issue
  import tg_pkg::*, tg_core_pkg::*;
#(
  parameter bit DUP_SEL = 1'b0,          // S2 lever: separate select copy for the wakeup
  parameter int EARLY_W = IQ_PL_W,       // S2 lever: payload bits kept in flip-flops
  localparam int DW     = DISPATCH_WIDTH
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         flush,
  input  tid_t                         flush_tid,
  // Dispatch (DS)
  input  logic [N_IQ-1:0][DW-1:0]      disp_we,
  input  logic [DW-1:0][NCOL-1:0]      disp_dep,
  input  logic [DW-1:0][NCOL-1:0]      disp_wake,
  input  iq_pl_t [DW-1:0]              disp_pl,
  output logic [N_IQ-1:0][DW-1:0]      bank_free,
  // Wakeup
  input  logic [NCOL-1:0]              alloc,       // IDs given out at RN: W cleared
  input  logic [NCOL-1:0]              wake_reg,    // W set at the end of this cycle
  input  logic [NCOL-1:0]              col_clr,     // freed IDs (registered)
  output logic [NCOL-1:0]              w,
  // Select blocks (registered by their sources)
  input  logic                         a1_block,
  input  logic                         ld_block,
  // RF stage
  output logic [N_IQ-1:0]              iss_valid,
  output iq_pl_t [N_IQ-1:0]            iss_pl
);
  function automatic int rows_of(input int q);
    if (q == 0) return IQ_A0;
    if (q == 1) return IQ_A1;
    if (q < N_ALU) return IQ_A2;
    if (q == Q_LD) return IQ_LD;
    return IQ_STA;
  endfunction

  logic [N_ALU-1:0][NCOL-1:0] wake_now;
  logic [DW-1:0][NCOL-1:0]    no_ph;
  assign no_ph = '0;
  tid_t [DW-1:0]              dtid;
  robid_t [DW-1:0]            drob;
  logic [DW-1:0][IQ_PL_W-1:0] dpl;
  for (genvar k = 0; k < DW; k++) begin : g_d
    assign dtid[k] = disp_pl[k].tid;
    assign drob[k] = disp_pl[k].rob;
    assign dpl[k]  = disp_pl[k];
  end

  for (genvar q = 0; q < N_IQ; q++) begin : g_q
    localparam int ROWS = rows_of(q);
    localparam int CAP  = (ROWS * IQ_CAP_PCT) / 100;
    logic [NCOL-1:0] wn, busy;
    logic [NUM_THREADS-1:0][idx_w(DW + 1)-1:0] room;
    logic [IQ_PL_W-1:0] pl;
    logic blk;
    assign blk = (q == 1) ? a1_block : (q == Q_LD) ? ld_block : 1'b0;
    tg_iq #(
      .ROWS(ROWS), .DW(DW), .NCOL(NCOL), .PAYLOAD_W(IQ_PL_W), .CAP(CAP), .STALE(2),
      .WAKE_NOW(q < N_ALU), .WAKE_ENC(0), .ROBW(ROBW), .DUP_SEL(DUP_SEL), .EARLY_W(EARLY_W)
    ) u_iq (
      .clk, .rst,
      .disp_valid(disp_we[q]), .disp_tid(dtid), .disp_dep(disp_dep), .disp_dep_ph(no_ph),
      .disp_wake_oh(disp_wake), .disp_rob(drob), .disp_payload(dpl),
      .bank_free_q(bank_free[q]), .room_q(room),
      .w(w), .w1('0), .col_clr(col_clr), .cancel(1'b0), .sel_block(blk), .wake_now(wn),
      .busy(busy),
      .flush_valid(flush), .flush_tid(flush_tid), .flush_all(1'b1), .flush_rob('0),
      .iss_valid_q(iss_valid[q]), .iss_payload(pl)
    );
    assign iss_pl[q] = iq_pl_t'(pl);
    if (q < N_ALU) begin : g_now
      assign wake_now[q] = wn;
    end else begin : g_nonow
      logic unused;
      assign unused = ^wn;
    end
    logic unused;
    assign unused = ^{busy, room};
  end

  logic [NCOL-1:0] w1_unused, ph_unused;
  tg_wake #(.NCOL(NCOL), .NNOW(N_ALU), .STALE(2)) u_wake (
    .clk, .rst, .wake_now, .wake_reg, .alloc, .cancel(1'b0), .cancel_ids('0),
    .w_q(w), .w1_q(w1_unused), .phase_q(ph_unused));

  logic unused;
  assign unused = ^{w1_unused, ph_unused};
endmodule
