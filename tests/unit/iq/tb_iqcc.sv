// Unit test of tg_iq's carry-chain readiness and select (CC, the area pass's lever 2; rtl/core/issue/tg_iq.sv):
// two queues, CC = 0 and CC = 1, take the same random inputs every cycle, and every output must match. Built with
// TG_SIM_PRIMS, so the CC queue's chains run on the CARRY8 model (models/CARRY8.sv, from UG974). The inputs are
// random within the queue's contract: dispatch only into a free bank; random dependencies on ID columns and on
// matrix rows; the woken vector, the matrix's issued and freed rows, the select and class blocks, the shadow cancel
// and thread-scoped kills change at random. Nothing here checks the select against a model: the CC = 0 queue is
// the reference (tb_iqcap and the core's regressions check that one).
//   Vtb_iqcc +seed=<n> +n=<cycles>
module tb_iqcc;
  import tg_pkg::*;
  parameter int ROWS  = 10;
  parameter int DW    = 2;
  parameter int NCOL  = 40;
  parameter int RA    = 20;
  parameter bit MX    = 1'b1;
  parameter bit CBLK  = 1'b0;
  parameter int STALE = 0;
  localparam int CAP  = ROWS / 2;
  localparam int RMAX = 2 * DW;
  localparam int OCW  = idx_w(ROWS + 1);
  localparam int NT   = 2;
  localparam int PW   = 12;
  localparam int ROBW = 8;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;
  int seed = 1, n = 100000, errors = 0, cyc = 0, grants = 0;

  // ---- Shared inputs ----
  logic [DW-1:0]            disp_valid;
  tid_t [DW-1:0]            disp_tid;
  logic [DW-1:0][NCOL-1:0]  disp_dep;
  logic [DW-1:0][ROBW-1:0]  disp_rob;
  logic [DW-1:0][PW-1:0]    disp_payload;
  logic [DW-1:0][RA-1:0]    disp_mdep;
  logic [DW-1:0]            disp_cblk;
  logic                     cap_on, cancel, sel_block, cls_block, flush_valid, flush_all;
  logic [NCOL-1:0]          w, col_clr;
  logic [RA-1:0]            mx_issued, mx_free;
  tid_t                     flush_tid;
  logic [ROBW-1:0]          flush_rob;

  // ---- Outputs, one set per queue ----
  typedef struct packed {
    logic [DW-1:0]               bank_free_q, bank_free2_q;
    logic [DW-1:0][1:0]          bank_nfree_q;
    logic [NT-1:0][RMAX-1:0]     room_ge_q;
    logic [NT-1:0][OCW-1:0]      occ_q;
    logic [NT-1:0][DW-1:0][1:0]  bank_left_q;
    logic [NCOL-1:0]             wake_now, busy;
    logic [ROWS-1:0]             issued_o, free_o, valid_o;
    logic [DW-1:0][ROWS-1:0]     alloc_oh_o;
    logic                        iss_valid_q;
    logic [PW-1:0]               iss_payload, iss_early_n;
  } out_t;
  out_t o0, o1;

  for (genvar v = 0; v < 2; v++) begin : g_q
    out_t o;
    tg_iq #(.ROWS(ROWS), .DW(DW), .NCOL(NCOL), .PAYLOAD_W(PW), .CAP(CAP), .STALE(STALE), .WAKE_NOW(1'b0),
            .WAKE_ENC(1), .ROBW(ROBW), .DUP_SEL(1'b1), .EARLY_W(PW), .MX(MX), .RA(RA), .PRE_RDY(1'b0),
            .CBLK(CBLK), .BANK_CAP(1'b1), .CC(v == 1)) u_iq (
      .clk, .rst, .disp_valid, .disp_tid, .disp_dep, .disp_dep_ph('0), .disp_wake_oh('0), .disp_rob,
      .disp_payload, .bank_free_q(o.bank_free_q), .bank_free2_q(o.bank_free2_q), .bank_nfree_q(o.bank_nfree_q),
      .cap_on, .room_ge_q(o.room_ge_q), .occ_q(o.occ_q), .bank_left_q(o.bank_left_q),
      .w, .w_next('0), .w1('0), .col_clr, .cancel, .sel_block, .disp_cblk, .cls_block,
      .wake_now(o.wake_now), .busy(o.busy), .disp_mdep, .mx_issued, .mx_free, .issued_o(o.issued_o),
      .free_o(o.free_o), .valid_o(o.valid_o), .alloc_oh_o(o.alloc_oh_o), .flush_valid, .flush_tid, .flush_all,
      .flush_rob, .iss_valid_q(o.iss_valid_q), .iss_payload(o.iss_payload), .iss_early_n(o.iss_early_n));
  end
  assign o0 = g_q[0].o;
  assign o1 = g_q[1].o;

  function automatic logic [NCOL-1:0] sparse_col(input int pct);
    logic [NCOL-1:0] v;
    for (int c = 0; c < NCOL; c++) v[c] = ($urandom % 100) < pct;
    return v;
  endfunction
  function automatic logic [RA-1:0] sparse_ra(input int pct);
    logic [RA-1:0] v;
    for (int j = 0; j < RA; j++) v[j] = ($urandom % 100) < pct;
    return v;
  endfunction

  // Inputs change after each rising edge (blocking, before the next edge's sampling)
  task automatic drive();
    int phase;
    phase = (cyc / 2000) % 4;           // phases: busy wakeups, sparse wakeups, heavy blocks, kills
    for (int k = 0; k < DW; k++) begin
      disp_valid[k]   = o0.bank_free_q[k] && ($urandom % 100) < 60;
      disp_tid[k]     = tid_t'($urandom % NT);
      disp_dep[k]     = sparse_col(phase == 1 ? 12 : 6);
      disp_rob[k]     = ROBW'($urandom);
      disp_payload[k] = PW'($urandom);
      disp_mdep[k]    = MX ? sparse_ra(8) : '0;
      disp_cblk[k]    = CBLK && ($urandom % 100) < 40;
    end
    w          = sparse_col(phase == 1 ? 55 : 85);
    col_clr    = (STALE == 2) ? sparse_col(5) : '0;
    mx_issued  = sparse_ra(phase == 1 ? 40 : 70);
    mx_free    = sparse_ra(5);
    cap_on     = ($urandom % 100) < 70;
    cancel     = ($urandom % 100) < 4;
    sel_block  = ($urandom % 100) < (phase == 2 ? 40 : 8);
    cls_block  = CBLK && ($urandom % 100) < (phase == 2 ? 50 : 15);
    flush_valid = ($urandom % 100) < (phase == 3 ? 10 : 2);
    flush_tid  = tid_t'($urandom % NT);
    flush_all  = ($urandom % 100) < 30;
    flush_rob  = ROBW'($urandom);
  endtask

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("n=%d", n));
    void'($urandom(seed));
    disp_valid = '0; disp_tid = '0; disp_dep = '0; disp_rob = '0; disp_payload = '0; disp_mdep = '0;
    disp_cblk = '0; cap_on = 1'b0; cancel = 1'b0; sel_block = 1'b0; cls_block = 1'b0; flush_valid = 1'b0;
    flush_all = 1'b0; w = '0; col_clr = '0; mx_issued = '0; mx_free = '0; flush_tid = '0; flush_rob = '0;
    repeat (3) @(posedge clk);
    rst = 1'b0;
    for (cyc = 0; cyc < n; cyc++) begin
      @(negedge clk);
      drive();
      #1;
      if (o0 !== o1) begin
        errors++;
        if (errors <= 5)
          $display("MISMATCH cycle %0d: iss_valid %b/%b payload %h/%h early_n %h/%h issued %b/%b valid %b/%b",
                   cyc, o0.iss_valid_q, o1.iss_valid_q, o0.iss_payload, o1.iss_payload, o0.iss_early_n,
                   o1.iss_early_n, o0.issued_o, o1.issued_o, o0.valid_o, o1.valid_o);
      end
      if (o0.iss_valid_q) grants++;
    end
    if (errors == 0 && grants > n / 20)
      $display("PASS tb_iqcc ROWS=%0d DW=%0d NCOL=%0d RA=%0d MX=%0d CBLK=%0d STALE=%0d (%0d cycles, %0d issues)",
               ROWS, DW, NCOL, RA, MX, CBLK, STALE, n, grants);
    else
      $display("FAIL tb_iqcc ROWS=%0d DW=%0d: %0d mismatching cycles, %0d issues in %0d cycles",
               ROWS, DW, errors, grants, n);
    $finish;
  end
endmodule
