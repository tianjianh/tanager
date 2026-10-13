// Spike S2, single queue: one ALU issue queue (IQ-A0) and the woken vector, with every
// input and output registered so the out-of-context run times only internal paths.
// The protected loop is W -> readiness -> select -> wake_now -> W (plan §8.1).
// Sizes come from the build configuration (tg_pkg): NCOL = ROB entries + LLTs,
// DISPATCH_WIDTH write ports, the per-thread cap IQ_CAP_PCT.
module tg_s2_iq_top
  import tg_pkg::*;
#(
  parameter int STALE    = 0,
  parameter int WAKE_ENC = 0,
  parameter bit DUP_SEL  = 1'b0,
  parameter int EARLY_W  = 64,       // payload bits in flip-flops (the rest in LUTRAM)
  parameter bit MX       = 1'b0,     // matrix wakeup for 1-cycle producers
  parameter int ROWS     = IQ_A0,
  localparam int NCOL = ROB_ENTRIES + LLT_ENTRIES,
  localparam int DW   = DISPATCH_WIDTH,
  localparam int CAP  = (ROWS * IQ_CAP_PCT) / 100,
  localparam int PW   = 64,
  localparam int ROBW = ROB_IDX_W + 1,
  localparam int RMW  = idx_w(DW + 1)
) (
  input  logic                    clk,
  input  logic                    rst_i,
  input  logic [DW-1:0]           disp_valid_i,
  input  tid_t [DW-1:0]           disp_tid_i,
  input  logic [DW-1:0][NCOL-1:0] disp_dep_i,
  input  logic [DW-1:0][NCOL-1:0] disp_dep_ph_i,
  input  logic [DW-1:0][NCOL-1:0] disp_wake_oh_i,
  input  logic [DW-1:0][ROBW-1:0] disp_rob_i,
  input  logic [DW-1:0][PW-1:0]   disp_payload_i,
  input  logic [DW-1:0][ROWS-1:0] disp_mdep_i,
  input  logic [NCOL-1:0]         wake_reg_i,
  input  logic [NCOL-1:0]         alloc_i,
  input  logic [NCOL-1:0]         cancel_ids_i,
  input  logic [NCOL-1:0]         col_clr_i,
  input  logic                    cancel_i,
  input  logic                    flush_valid_i,
  input  tid_t                    flush_tid_i,
  input  logic                    flush_all_i,
  input  logic [ROBW-1:0]         flush_rob_i,
  output logic                    iss_valid_o,
  output logic [PW-1:0]           iss_payload_o,
  output logic [DW-1:0]           bank_free_o,
  output logic [NUM_THREADS-1:0][RMW-1:0] room_o,
  output logic [NCOL-1:0]         busy_o,
  output logic [NCOL-1:0]         w_o
);
  // Input registers
  logic                    rst;
  logic [DW-1:0]           disp_valid_q;
  tid_t [DW-1:0]           disp_tid_q;
  logic [DW-1:0][NCOL-1:0] disp_dep_q, disp_dep_ph_q, disp_wake_oh_q;
  logic [DW-1:0][ROBW-1:0] disp_rob_q;
  logic [DW-1:0][PW-1:0]   disp_payload_q;
  logic [DW-1:0][ROWS-1:0] disp_mdep_q;
  logic [NCOL-1:0]         wake_reg_q, alloc_q, cancel_ids_q, col_clr_q;
  logic                    cancel_q, flush_valid_q, flush_all_q;
  tid_t                    flush_tid_q;
  logic [ROBW-1:0]         flush_rob_q;
  always_ff @(posedge clk) begin
    rst            <= rst_i;
    disp_valid_q   <= disp_valid_i;
    disp_tid_q     <= disp_tid_i;
    disp_dep_q     <= disp_dep_i;
    disp_dep_ph_q  <= disp_dep_ph_i;
    disp_wake_oh_q <= disp_wake_oh_i;
    disp_rob_q     <= disp_rob_i;
    disp_payload_q <= disp_payload_i;
    disp_mdep_q    <= disp_mdep_i;
    wake_reg_q     <= wake_reg_i;
    alloc_q        <= alloc_i;
    cancel_ids_q   <= cancel_ids_i;
    col_clr_q      <= col_clr_i;
    cancel_q       <= cancel_i;
    flush_valid_q  <= flush_valid_i;
    flush_tid_q    <= flush_tid_i;
    flush_all_q    <= flush_all_i;
    flush_rob_q    <= flush_rob_i;
  end

  logic [NCOL-1:0] w_q, w1_q, phase_q, wake_now, busy;
  logic [ROWS-1:0] issued, freed;
  logic [DW-1:0]   bank_free_q, disp_valid;
  logic [NUM_THREADS-1:0][RMW-1:0] room_q;

  // Dispatch writes only into a bank with a free row and while its thread has room.
  for (genvar k = 0; k < DW; k++) begin : g_disp
    assign disp_valid[k] = disp_valid_q[k] && bank_free_q[k] && room_q[disp_tid_q[k]] != '0;
  end

  tg_iq #(
    .ROWS(ROWS), .DW(DW), .NCOL(NCOL), .PAYLOAD_W(PW), .CAP(CAP), .STALE(STALE),
    .WAKE_NOW(1'b1), .WAKE_ENC(WAKE_ENC), .ROBW(ROBW), .DUP_SEL(DUP_SEL), .EARLY_W(EARLY_W),
    .MX(MX), .RA(ROWS)
  ) u_iq (
    .clk, .rst,
    .disp_valid, .disp_tid(disp_tid_q), .disp_dep(disp_dep_q), .disp_dep_ph(disp_dep_ph_q),
    .disp_wake_oh(disp_wake_oh_q), .disp_rob(disp_rob_q), .disp_payload(disp_payload_q),
    .bank_free_q, .room_q,
    .w(w_q), .w1(w1_q), .col_clr(col_clr_q), .cancel(cancel_q), .wake_now, .busy,
    .disp_mdep(disp_mdep_q), .mx_issued(issued), .mx_free(freed), .issued_o(issued),
    .free_o(freed),
    .flush_valid(flush_valid_q), .flush_tid(flush_tid_q), .flush_all(flush_all_q),
    .flush_rob(flush_rob_q),
    .iss_valid_q(iss_valid_o), .iss_payload(iss_payload_o)
  );

  tg_wake #(.NCOL(NCOL), .NNOW(1), .STALE(STALE), .HIST(MX ? 1 : 2)) u_wake (
    .clk, .rst, .wake_now, .wake_reg(wake_reg_q), .alloc(alloc_q), .cancel(cancel_q),
    .cancel_ids(cancel_ids_q), .w_q, .w1_q, .phase_q
  );

  always_ff @(posedge clk) begin
    bank_free_o <= bank_free_q;
    room_o      <= room_q;
    busy_o      <= busy;
    w_o         <= w_q ^ w1_q ^ phase_q;
  end
endmodule
