// Unit test of tg_fetch with two streams (M7's step 5b, hart 1 on: TG_HART1=1), the core's own unit test. The memory
// holds instructions with no branch or jump (32-bit `addi x0, x0, imm` and 16-bit `c.nop` hints, mixed, so 32-bit ones
// straddle blocks), each 64 KiB repeating; the l1i answers Gets in order after random delays. Hart 0 fetches from
// reset, hart 1 from its first flush. Random flushes and decode redirects of either thread, some in one cycle for both;
// FENCE.I with some flushes; each thread's rename register takes a group next cycle at random (rn_acc, 80%: the
// queue's read-thread choice, step 5d); decode takes random counts from the thread the queue presents (nothing in a redirect's
// cycle), commit retires what decode took, in order per thread, a thread a cycle, and frees the FTQ.
// Checked: every instruction decode takes is its thread's next (the PC its stream expects, its bits from memory, its
// size), carries a valid thread, no fault and no prediction; both threads progress.
// Negatives (TB_FLUSH_TID0, TB_DRED_TID0): the DUT gets thread 0 for every flush, or every decode redirect: they fail.
module tb_fetch
  import tg_pkg::*, tg_tl_pkg::*, tg_core_pkg::*;
#(
  parameter int CYCLES = 200000,
  parameter int SEED   = 1
);
  localparam int NT  = NUM_THREADS;
  localparam int W   = DECODE_WIDTH;
  localparam int TKW = idx_w(W + 1);
  localparam int MH  = 32768;                       // halfwords in the image (64 KiB, repeating)
  localparam logic [63:0] BASE = 64'h8000_0000;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = !clk;

  // ---- The image: halfwords, and where instructions start ----
  logic [15:0] mem16 [MH];
  bit          start [MH];
  function automatic logic [15:0] hw(input logic [63:0] a);
    return mem16[int'((a - BASE) >> 1) % MH];
  endfunction
  function automatic bit is_start(input logic [63:0] a);
    return start[int'((a - BASE) >> 1) % MH];
  endfunction

  // ---- DUT ----
  logic        ready, flush, icinv, dred, upd_valid, upd_way, upd_inval, pmp_busy, tlb_flush, it_fill;
  tid_t        flush_tid, dred_tid, d_flush_tid, d_dred_tid, c_tid, ras_tid, upd_tid, tlb_flush_tid, it_fill_tid, iw_tid;
  logic [NUM_THREADS-1:0] hpm_imiss;           // (M9's counter event: not checked here)
  pc40_t       flush_pc, dred_pc;          // the redirects are pc40s (core-pipeline.md §8.6)
  logic [63:0] upd_pc, upd_target, iw_va;
  logic [FTQW-1:0]   dred_ftq, c_hftq;
  logic [SLOT_W-1:0] dred_slot, upd_slot;
  logic [1:0]        dred_rop;
  logic [38:1]       dred_rlink;
  logic [COMMIT_WIDTH-1:0] c_cbr, c_taken, c_pred;
  logic [COMMIT_WIDTH-1:0] c_ret, c_ijmp;                     // the indirect-target table's (ITT_ON; not driven here)
  logic [COMMIT_WIDTH-1:0][17:2] c_pc;
  logic        c_trv;
  logic [17:2] c_trepc;
  logic [COMMIT_WIDTH-1:0][FTQW-1:0]   c_ftq;
  logic [COMMIT_WIDTH-1:0][SLOT_W-1:0] c_slot;
  logic        c_hv;
  logic        ras_push, ras_pop, ras_rv, ras_rwr;
  logic [38:1] ras_link, ras_rtop;
  logic [RAS_PW-1:0] ras_rtos;
  logic [RAS_PW:0]   ras_rcnt;
  logic [W-1:0]      iq_valid;
  fe_insn_t [W-1:0]  iq_insn;
  logic [TKW-1:0]    iq_take, iq_take_t, iq_take_n;  // decode's take, the choice by rename's acceptance (de_take) between
  logic              de_take;                       // its count (iq_take_t) and nothing (iq_take_n), as decode makes it
  logic              iq_tnz_t, iq_tnz_n;            // ... whether each is nonzero (decode's flags for the read thread)
  logic [NT-1:0]     rn_acc;                        // rename's registers take a group next cycle (tg_rename's acc_o)
  dec_state_t [NT-1:0] dst;
  priv_e  [NT-1:0]     priv_h;
  pmp_d_t [NT-1:0][PMP_ENTRIES-1:0] pmp_d_h;
  logic   [NT-1:0]     xl_h;
  logic        iw_req, iw_ack, iw_done, iw_ok;
  logic [3:0]  iw_cause;
  logic [26:0] it_fill_vpn;
  logic [1:0]  it_fill_lvl;
  tlb_pte_t    it_fill_pte;
  tl_a_t       a;
  logic        a_valid, a_ready, d_valid, d_ready;
  tl_d_t       d;
`ifdef TB_FLUSH_TID0
  assign d_flush_tid = '0;
`else
  assign d_flush_tid = flush_tid;
`endif
`ifdef TB_DRED_TID0
  assign d_dred_tid = '0;
`else
  assign d_dred_tid = dred_tid;
`endif
  tg_fetch dut (
    .clk, .rst, .boot_pc(BASE), .ready,
    .flush, .flush_tid(d_flush_tid), .flush_pc, .icinv, .dred, .dred_tid(d_dred_tid), .dred_pc, .dred_ftq, .dred_slot,
    .dred_rop, .dred_rlink, .c_cbr, .c_taken, .c_pred, .c_ftq, .c_slot, .c_hv, .c_hftq, .c_tid,
    .c_ret, .c_pc, .c_ijmp, .c_trv, .c_trepc,
    .ras_v_s('0), .ras_top_s('0), .ras_tos_s('0), .ras_cnt_s('0), .ras_tid, .ras_push, .ras_pop, .ras_link, .ras_rv,
    .ras_rwr, .ras_rtos, .ras_rcnt, .ras_rtop,
    .upd_valid, .upd_way, .upd_pc, .upd_slot, .upd_target, .upd_inval, .upd_tid,
    .iq_valid, .iq_insn, .iq_take, .iq_take_t, .iq_take_n, .iq_tnz_t, .iq_tnz_n, .de_take, .rn_block('0), .rn_acc,
    .xl_h, .dst, .priv_h, .pmp_d_h, .pmp_busy, .tlb_flush, .tlb_flush_tid,
    .it_fill, .it_fill_vpn, .it_fill_lvl, .it_fill_pte, .it_fill_tid,
    .iw_req, .iw_tid, .iw_va, .iw_ack, .iw_done, .iw_ok, .iw_cause, .hpm_imiss,
    .l1i_a_o(a), .l1i_a_valid_o(a_valid), .l1i_a_ready_i(a_ready), .l1i_d_i(d), .l1i_d_valid_i(d_valid),
    .l1i_d_ready_o(d_ready));

  // ---- The l1i: Gets taken in order, answered after random delays, a message's four beats together. The D channel
  // is driven at the falling edge for the next rising one (no combinational read of the queue) ----
  typedef struct { logic [63:0] line; logic [TL_SRC_W-1:0] src; int due; } req_t;
  req_t rq[$];
  int   beat, cyc;
  initial begin d = '0; d_valid = 1'b0; beat = 0; end
  always @(negedge clk) begin
    d       = '0;
    d_valid = 1'b0;
    if (!rst && rq.size() > 0 && rq[0].due <= cyc) begin
      d_valid  = 1'b1;
      d.opcode = D_ACCESS_ACK_DATA;
      d.size   = 3'd6;
      d.source = rq[0].src;
      for (int h = 0; h < 8; h++) d.data[16 * h +: 16] = hw(rq[0].line + 64'(16 * beat + 2 * h));
    end
  end
  always @(posedge clk) begin
    if (rst) begin
      rq.delete();
      beat = 0;
    end else begin
      if (d_valid) begin
        if (beat == 3) begin
          void'(rq.pop_front());
          beat = 0;
        end else beat = beat + 1;
      end
      if (a_valid && a_ready) rq.push_back('{line: {a.address[63:6], 6'b0}, src: a.source, due: cyc + $urandom_range(3, 40)});
    end
  end

  // ---- The model: each thread's expected next PC; what decode took, to retire ----
  logic [63:0] exp_pc [NT];
  bit          live [NT];
  typedef struct { logic [FTQW-1:0] ftq; int due; } ret_t;
  ret_t        rt [NT][$];
  logic [FTQW-1:0] last_ftq [NT];
  logic [SLOT_W-1:0] last_slot [NT];
  bit          took [NT];
  int          ntook [NT];
  int          mism, nflush, ndred, nboth, nicinv;

  function automatic logic [63:0] rand_target();
    int k;
    do k = $urandom_range(0, MH / 2); while (!start[k]);
    return BASE + 64'(64'(65536) * $urandom_range(0, 3)) + 64'(2 * k);
  endfunction

  initial begin
    // The image: 30% 32-bit addi x0 (straddling where they fall), else 16-bit c.nop hints; it ends with a 16-bit one,
    // so its repeat continues at an instruction
    void'($urandom(SEED));
    for (int k = 0; k < MH; ) begin
      if (k + 2 < MH && $urandom_range(0, 9) < 3) begin
        logic [11:0] imm;
        imm = 12'($urandom);
        mem16[k] = 16'h0013; mem16[k + 1] = {imm, 4'b0}; start[k] = 1; start[k + 1] = 0; k += 2;
      end else begin
        mem16[k] = 16'h0001 | (16'($urandom_range(0, 1)) << 12) | (16'($urandom_range(0, 31)) << 2);
        start[k] = 1; k += 1;
      end
    end
    mism = 0; nflush = 0; ndred = 0; nboth = 0; nicinv = 0;
    for (int t = 0; t < NT; t++) begin
      live[t] = (t == 0); exp_pc[t] = BASE; took[t] = 0; ntook[t] = 0; last_ftq[t] = '0; last_slot[t] = '0;
    end
    {flush, icinv, dred, c_hv, upd_valid, upd_way, upd_inval, pmp_busy, tlb_flush, it_fill} = '0;
    flush_tid = '0; dred_tid = '0; flush_pc = '0; dred_pc = '0; dred_ftq = '0; dred_slot = '0; dred_rop = '0;
    dred_rlink = '0; c_cbr = '0; c_taken = '0; c_pred = '0; c_ftq = '0; c_slot = '0; c_hftq = '0; c_tid = '0;
    c_ret = '0; c_pc = '0; c_ijmp = '0; c_trv = 1'b0; c_trepc = '0;
    upd_pc = '0; upd_target = '0; upd_slot = '0; upd_tid = '0; tlb_flush_tid = '0; it_fill_tid = '0;
    it_fill_vpn = '0; it_fill_lvl = '0; it_fill_pte = '0; iw_ack = 0; iw_done = 0; iw_ok = 1; iw_cause = '0;
    iq_take = '0; iq_take_t = '0; iq_take_n = '0; iq_tnz_t = 1'b0; iq_tnz_n = 1'b0; de_take = 1'b0; a_ready = 1'b1;
    rn_acc = '1;
    for (int t = 0; t < NT; t++) begin
      dst[t] = '{misa_m: 1, misa_b: EXT_B, misa_c: 1, misa_a: 1, misa_f: EXT_FD, misa_d: EXT_FD, fs: 2'd1, frm: '0,
                 priv: PRIV_M, tvm: 0, tw: 0, tsr: 0};
      priv_h[t] = PRIV_M;
    end
    pmp_d_h = '0;
    xl_h    = '0;
    cyc = 0;
    repeat (3) @(posedge clk);
    @(negedge clk) rst = 1'b0;
    while (!ready) @(negedge clk);
    for (cyc = 0; cyc < CYCLES; cyc++) begin
      int n, t, rt_t, ft, dt;
      bit pending_dred;
      // ---- Drive this cycle's inputs (sampled at the next rising edge) ----
      a_ready = $urandom_range(0, 9) < 8;
      for (int t = 0; t < NT; t++) rn_acc[t] = $urandom_range(0, 9) < 8;
      // a decode redirect this cycle, chosen last cycle after decode took from that thread
      pending_dred = dred;
      if (pending_dred) begin
        ndred++;
        exp_pc[dred_tid] = pc40_sx(dred_pc);
      end
      // a flush (hart 1 starts with its first); sometimes with FENCE.I; sometimes beside the decode redirect
      flush = 0; icinv = 0;
      if (cyc == 40 || $urandom_range(0, 199) == 0 || (pending_dred && cyc > 40 && $urandom_range(0, 4) == 0)) begin
        // (beside a decode redirect, mostly the other thread's: both apply in one cycle)
        ft = (cyc == 40) ? 1 : (pending_dred && $urandom_range(0, 3) != 0) ? 1 - int'(dred_tid) : $urandom_range(0, NT - 1);
        flush = 1; flush_tid = tid_t'(ft); flush_pc = pc40_of(rand_target()); icinv = $urandom_range(0, 19) == 0;
        nflush++; nicinv += int'(icinv);
        if (pending_dred && int'(dred_tid) != ft) nboth++;
        if (pending_dred && int'(dred_tid) == ft) ndred--;      // (the flush wins for its own stream)
        live[ft] = 1; exp_pc[ft] = pc40_sx(flush_pc);
        rt[ft].delete();                                          // its unretired instructions are squashed
      end
      // decode: nothing in a redirect's cycle; else a random count of the presented thread's head
      n = 0;
      if (!flush && !dred) begin
        int v;
        v = 0;
        for (int j = 0; j < W; j++) if (iq_valid[j] && v == j) v++;
        n = $urandom_range(0, v);
      end
      // rename takes the group at random (75%); decode's count goes out either way (iq_take_t), its take is the choice
      de_take   = $urandom_range(0, 3) != 0;
      iq_take_t = TKW'(n);
      iq_take_n = '0;
      iq_tnz_t  = iq_take_t != '0;
      iq_tnz_n  = iq_take_n != '0;
      if (!de_take) n = 0;
      iq_take   = TKW'(n);
      // commit: the thread whose turn it is retires its oldest due instructions (one or two)
      c_hv = 0;
      rt_t = cyc % NT;
      if (!flush && rt[rt_t].size() > 0 && rt[rt_t][0].due <= cyc) begin
        int k;
        k = (rt[rt_t].size() > 1 && rt[rt_t][1].due <= cyc && $urandom_range(0, 1)) ? 2 : 1;
        c_hv = 1; c_tid = tid_t'(rt_t);
        for (int i = 0; i < k; i++) begin c_hftq = rt[rt_t][0].ftq; rt[rt_t].pop_front(); end
      end
      #1;
      // ---- Check what decode takes ----
      took[0] = 0; if (NT > 1) took[NT-1] = 0;
      for (int j = 0; j < n; j++) begin
        logic [63:0] p;
        logic [31:0] w;
        bit          wide;
        dt = int'(iq_insn[j].tid);
        p  = pc40_sx(iq_insn[j].pc);
        wide = hw(p)[1:0] == 2'b11;
        w  = wide ? {hw(p + 2), hw(p)} : {16'b0, hw(p)};
`ifdef TB_TRACE
        if (cyc < 160) $display("take cycle %0d slot %0d thread %0d pc %h insn %h (mem %h) ftq %0d", cyc, j, dt, p,
                                iq_insn[j].insn, w, iq_insn[j].ftq);
`endif
        if (dt >= NT || !live[dt] || p != exp_pc[dt] || iq_insn[j].insn != w || iq_insn[j].rvc != !wide ||
            iq_insn[j].fault || iq_insn[j].pred_taken || !is_start(p)) begin
          if (mism < 10)
            $display("MISMATCH cycle %0d slot %0d thread %0d: pc %h insn %h rvc %0b fault %0b taken %0b, expected pc %h insn %h",
                     cyc, j, dt, p, iq_insn[j].insn, iq_insn[j].rvc, iq_insn[j].fault, iq_insn[j].pred_taken,
                     (dt < NT) ? exp_pc[dt] : 64'h0, w);
          mism++;
        end
        if (dt < NT) begin
          exp_pc[dt] = p + (wide ? 64'd4 : 64'd2);
          rt[dt].push_back('{ftq: iq_insn[j].ftq, due: cyc + $urandom_range(2, 30)});
          last_ftq[dt] = iq_insn[j].ftq;
          last_slot[dt] = SLOT_W'(p[SLOT_W:1] + SLOT_W'(wide));
          took[dt] = 1;
          ntook[dt]++;
        end
      end
      @(posedge clk);
      // ---- Next cycle's decode redirect: after a take, for its thread's last instruction, unless flushed now ----
      @(negedge clk);
      dred = 0;
      for (int u = 0; u < NT; u++)
        if (took[u] && !(flush && int'(flush_tid) == u) && !dred && $urandom_range(0, 99) < 2) begin
          dred = 1; dred_tid = tid_t'(u); dred_pc = pc40_of(rand_target()); dred_ftq = last_ftq[u]; dred_slot = last_slot[u];
          // the redirecting instruction stays; the queue's later ones go (exp_pc set when it applies)
        end
    end
    // ---- Both threads progressed ----
    for (int t = 0; t < NT; t++)
      if (ntook[t] < CYCLES / 50) begin
        $display("MISMATCH thread %0d took only %0d instructions", t, ntook[t]);
        mism++;
      end
    if (mism == 0)
      $display("TB_FETCH PASS: %0d cycles, %0d and %0d instructions, %0d flushes (%0d with FENCE.I), %0d decode redirects, %0d cycles with both",
               CYCLES, ntook[0], ntook[NT-1], nflush, nicinv, ndred, nboth);
    else
      $display("TB_FETCH FAIL: %0d mismatches", mism);
    $finish;
  end
endmodule
