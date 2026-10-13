// Spike S2, whole scheduler: every issue queue of plan §4.6 (A0..A(N_ALU-1), LD, STA, FP,
// sized from tg_pkg) sharing one woken vector, with registered inputs and outputs.
// The ALU queues wake their dependants at select (the protected loop, across queues);
// loads (speculative, 3-cycle load-to-use), MUL (3 cycles, on A1) and FP ops wake through
// delay lines fed by the registered issue outputs; LLT completions come from outside.
// Payload fields used here: [COL_W-1:0] wakeup ID, [COL_W] delayed wake, [COL_W+1] long
// delay (FMA); the rest is opaque.
module tg_s2_sched_top
  import tg_pkg::*;
#(
  parameter int STALE    = 0,
  parameter int WAKE_ENC = 0,
  parameter bit DUP_SEL  = 1'b0,
  parameter int EARLY_W  = 64,       // payload bits in flip-flops (the rest in LUTRAM)
  localparam int NCOL  = ROB_ENTRIES + LLT_ENTRIES,
  localparam int COL_W = idx_w(NCOL),
  localparam int DW    = DISPATCH_WIDTH,
  localparam int NQ    = N_ALU + 3,             // ALU queues, LD, STA, FP
  localparam int QW    = idx_w(NQ),
  localparam int PW    = 64,
  localparam int ROBW  = ROB_IDX_W + 1,
  localparam int RMW   = idx_w(DW + 1)
) (
  input  logic                    clk,
  input  logic                    rst_i,
  input  logic [DW-1:0]           disp_valid_i,
  input  logic [DW-1:0][QW-1:0]   disp_queue_i,
  input  tid_t [DW-1:0]           disp_tid_i,
  input  logic [DW-1:0][NCOL-1:0] disp_dep_i,
  input  logic [DW-1:0][NCOL-1:0] disp_dep_ph_i,
  input  logic [DW-1:0][NCOL-1:0] disp_wake_oh_i,
  input  logic [DW-1:0][ROBW-1:0] disp_rob_i,
  input  logic [DW-1:0][PW-1:0]   disp_payload_i,
  input  logic [NCOL-1:0]         llt_done_i,
  input  logic [NCOL-1:0]         alloc_i,
  input  logic [NCOL-1:0]         cancel_ids_i,
  input  logic [NCOL-1:0]         col_clr_i,
  input  logic                    cancel_i,
  input  logic                    flush_valid_i,
  input  tid_t                    flush_tid_i,
  input  logic                    flush_all_i,
  input  logic [ROBW-1:0]         flush_rob_i,
  output logic [NQ-1:0]           iss_valid_o,
  output logic [NQ-1:0][PW-1:0]   iss_payload_o,
  output logic [NQ-1:0][DW-1:0]   bank_free_o,
  output logic [NQ-1:0][NUM_THREADS-1:0][RMW-1:0] room_o,
  output logic [NCOL-1:0]         busy_o,
  output logic [NCOL-1:0]         w_o
);
  function automatic int rows_of(input int q);
    if (q == 0) return IQ_A0;
    if (q == 1) return IQ_A1;
    if (q < N_ALU) return IQ_A2;
    if (q == N_ALU) return IQ_LD;
    if (q == N_ALU + 1) return IQ_STA;
    return IQ_FP;
  endfunction

  // Input registers
  logic                    rst;
  logic [DW-1:0]           disp_valid_q;
  logic [DW-1:0][QW-1:0]   disp_queue_q;
  tid_t [DW-1:0]           disp_tid_q;
  logic [DW-1:0][NCOL-1:0] disp_dep_q, disp_dep_ph_q, disp_wake_oh_q;
  logic [DW-1:0][ROBW-1:0] disp_rob_q;
  logic [DW-1:0][PW-1:0]   disp_payload_q;
  logic [NCOL-1:0]         llt_done_q, alloc_q, cancel_ids_q, col_clr_q;
  logic                    cancel_q, flush_valid_q, flush_all_q;
  tid_t                    flush_tid_q;
  logic [ROBW-1:0]         flush_rob_q;
  always_ff @(posedge clk) begin
    rst            <= rst_i;
    disp_valid_q   <= disp_valid_i;
    disp_queue_q   <= disp_queue_i;
    disp_tid_q     <= disp_tid_i;
    disp_dep_q     <= disp_dep_i;
    disp_dep_ph_q  <= disp_dep_ph_i;
    disp_wake_oh_q <= disp_wake_oh_i;
    disp_rob_q     <= disp_rob_i;
    disp_payload_q <= disp_payload_i;
    llt_done_q     <= llt_done_i;
    alloc_q        <= alloc_i;
    cancel_ids_q   <= cancel_ids_i;
    col_clr_q      <= col_clr_i;
    cancel_q       <= cancel_i;
    flush_valid_q  <= flush_valid_i;
    flush_tid_q    <= flush_tid_i;
    flush_all_q    <= flush_all_i;
    flush_rob_q    <= flush_rob_i;
  end

  logic [NCOL-1:0] w_q, w1_q, phase_q;
  logic [N_ALU-1:0][NCOL-1:0] wake_now;
  logic [NQ-1:0][NCOL-1:0] busy;
  logic [NQ-1:0][DW-1:0] bank_free_q;
  logic [NQ-1:0][NUM_THREADS-1:0][RMW-1:0] room_q;
  logic [NQ-1:0] iss_valid_q;
  logic [NQ-1:0][PW-1:0] iss_payload_q;

  for (genvar q = 0; q < NQ; q++) begin : g_q
    localparam int ROWS = rows_of(q);
    logic [DW-1:0] dv;
    logic [NCOL-1:0] wn;
    for (genvar k = 0; k < DW; k++) begin : g_disp
      assign dv[k] = disp_valid_q[k] && disp_queue_q[k] == QW'(q) && bank_free_q[q][k]
                     && room_q[q][disp_tid_q[k]] != '0;
    end
    tg_iq #(
      .ROWS(ROWS), .DW(DW), .NCOL(NCOL), .PAYLOAD_W(PW), .CAP((ROWS * IQ_CAP_PCT) / 100),
      .STALE(STALE), .WAKE_NOW(q < N_ALU), .WAKE_ENC(WAKE_ENC), .ROBW(ROBW),
      .DUP_SEL(DUP_SEL), .EARLY_W(EARLY_W)
    ) u_iq (
      .clk, .rst,
      .disp_valid(dv), .disp_tid(disp_tid_q), .disp_dep(disp_dep_q),
      .disp_dep_ph(disp_dep_ph_q), .disp_wake_oh(disp_wake_oh_q), .disp_rob(disp_rob_q),
      .disp_payload(disp_payload_q),
      .bank_free_q(bank_free_q[q]), .room_q(room_q[q]),
      .w(w_q), .w1(w1_q), .col_clr(col_clr_q), .cancel(cancel_q), .wake_now(wn),
      .busy(busy[q]),
      .flush_valid(flush_valid_q), .flush_tid(flush_tid_q), .flush_all(flush_all_q),
      .flush_rob(flush_rob_q),
      .iss_valid_q(iss_valid_q[q]), .iss_payload(iss_payload_q[q])
    );
    if (q < N_ALU) begin : g_now
      assign wake_now[q] = wn;
    end else begin : g_nonow
      logic unused;
      assign unused = ^wn;   // zero: only ALU queues wake at select
    end
  end

  // Delayed wakeups from the registered issue outputs: the short class lands one cycle
  // later (load hit speculation, MUL), the long class four (FMA).
  logic [NCOL-1:0] wake_reg_d, wake_reg_q;
  logic [NQ-1:0][3:0]            dl_v_q;
  logic [NQ-1:0][3:0]            dl_long_q;
  logic [NQ-1:0][3:0][COL_W-1:0] dl_id_q;
  always_ff @(posedge clk) begin
    for (int q = 0; q < NQ; q++) begin
      if (rst) dl_v_q[q] <= '0;
      else     dl_v_q[q] <= {dl_v_q[q][2:0], iss_valid_q[q] && iss_payload_q[q][COL_W]};
      dl_long_q[q] <= {dl_long_q[q][2:0], iss_payload_q[q][COL_W+1]};
      dl_id_q[q]   <= {dl_id_q[q][2:0], iss_payload_q[q][COL_W-1:0]};
    end
  end
  always_comb begin
    wake_reg_d = llt_done_q;
    for (int q = 0; q < NQ; q++) begin
      for (int c = 0; c < NCOL; c++) begin
        if (dl_v_q[q][0] && !dl_long_q[q][0] && dl_id_q[q][0] == COL_W'(c)) wake_reg_d[c] = 1'b1;
        if (dl_v_q[q][3] &&  dl_long_q[q][3] && dl_id_q[q][3] == COL_W'(c)) wake_reg_d[c] = 1'b1;
      end
    end
  end
  always_ff @(posedge clk) wake_reg_q <= wake_reg_d;

  tg_wake #(.NCOL(NCOL), .NNOW(N_ALU), .STALE(STALE)) u_wake (
    .clk, .rst, .wake_now, .wake_reg(wake_reg_q), .alloc(alloc_q), .cancel(cancel_q),
    .cancel_ids(cancel_ids_q), .w_q, .w1_q, .phase_q
  );

  logic [NCOL-1:0] busy_all;
  always_comb begin
    busy_all = '0;
    for (int q = 0; q < NQ; q++) busy_all |= busy[q];
  end

  always_ff @(posedge clk) begin
    iss_valid_o   <= iss_valid_q;
    iss_payload_o <= iss_payload_q;
    bank_free_o   <= bank_free_q;
    room_o        <= room_q;
    busy_o        <= busy_all;
    w_o           <= w_q ^ w1_q ^ phase_q;
  end
endmodule
