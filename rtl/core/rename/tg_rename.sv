// Rename (RN) and dispatch (DS) stages (docs/spec/core-pipeline.md §5).
//
// RN (group in rn_q): sources from the RAT or an earlier slot of the group; steering to an
// issue port, whose bank supplies the destination; free-list pops; ROB, LQ, SQ and LLT
// allocation; RAT, ready and producer tables updated when the group moves on. All or nothing.
// A serialising or exception uop is renamed alone, into an empty window, after which RN takes
// nothing until the next flush.
// DS (group in ds_q): dependency vectors (pending producers' IDs AND NOT W), issue-queue rows,
// and the ROB / LQ / SQ entry writes (done by those units from ds_*). DS waits until every uop
// finds a free row in its queue's bank.
// The RAT entry of each architectural register holds its mapping and its producer: its wakeup
// column (a tag or an LLT), or for a 1-cycle op its ROB index (MX), and the rename slot it had.
// Sources need no table indexed by physical register (a pending source's producer is still in
// flight, so its column is current; a written one is ready and its column unused).
// Wakeup tags (plan §4.6, AR-1): MUL and the P1 bit counts take one of IQ_TAGS tags at RN; a
// tag returns 2 cycles after its producer's register write (tag_free, from tg_exec), when no
// group still in RN or DS can see the register as unwritten, and its column is then cleared in
// every queue row. 1-cycle ops take no column: a consumer names its row (MX) while the row is
// held, and needs nothing once it is freed. A flush returns every tag.
// The maps are LUTRAM (plan §8.5 R3): the speculative map has one bank per rename slot and the
// committed map one per commit slot, so each write port is a LUTRAM's; live-value tables in
// flip-flops name the bank holding each register's latest entry. A flush clears the per-register
// "renamed since the flush" bits, after which the committed map answers: recovery is immediate,
// with no copy. A reset sweep writes the identity into the committed map.
// The ready tables (one bit per physical register: written since allocated) are LUTRAM too
// (tg_rdytab): a set phase per bank, written by the bank's register-file port, and an allocation
// phase XOR-banked by rename slot. They read as the flip-flop vectors they replace did.
// MX (IQ_MX): a source whose producer is a 1-cycle op still holding its ALU-queue row is named
// by that row instead of its ID. DS records each 1-cycle op's row in a LUTRAM by ROB entry, one
// bank per rename slot (one write per bank per cycle); a consumer reads it in the bank of its
// producer's slot, and one compare of the row's destination (rowdst) against the source
// confirms the row still holds it. A producer in the same group is named by the row it is being
// written into. Otherwise the ID is used. rowdst is LUTRAM too, banked by DS slot and read by
// row: a row's value is the XOR of the banks.
// Per thread (M7's step 3, docs/spec/threading.md): a group is one thread's (t_rn, its slot 0's tid). The maps and the
// free lists are per thread (RAM form: the tid is an address bit), and so are the ROB, LQ and SQ tails with their
// room checks against that thread's heads, the block after a serialising uop, and the flush of the RN and DS stages
// (only when they hold the flushed thread's group). The wakeup tags and LLTs stay one pool each; each records its
// thread, and a flush returns the flushed thread's. Commit's pushes and map writes are the commit group's thread's
// (cm_tid). The divide and FP counts are shared totals (the room checks read one register each); with hart 1
// (M7's step 5c) each thread's share is kept beside them, and a flush takes only its thread's share off.
// With hart 1 (M7's step 5d, DR-178 as amended) RN has a register per thread: decode's group goes into its thread's,
// and rename works on one of the two a cycle (sel_q, chosen a cycle ahead from registered state), so a group that
// cannot rename waits in its own register and never holds the other thread's. With hart 1 a group also renames
// only when its issue queues' banks have rows for it (st_free), so a group short of rows waits there, not at DS.
// F and D (EXT_FD): a second map (tg_rmap) for the f registers, whose physical registers are
// {bank, index} in F0 (P4 results) or F1 (FP loads), with their own free lists and ready table.
// An FP op's integer source (FCVT.F.I, FMV.F.X) and an FP store's address are integer sources
// as usual; an FP op with an integer result writes bank B1. FMA and FMISC ops with an FP result
// take a wakeup tag; divides, square roots and FP->int ops an LLT. FP divides and FP->int ops
// are held to FDIV_INFLIGHT and FPI_INFLIGHT between rename and their return from P4: each
// count is the uops renamed but not yet issued (dropped by a flush) plus those issued and not
// yet returned (fdiv_done, fpi_pop: P4 returns every issued one, flushed or not).
module tg_rename
  import tg_pkg::*, tg_core_pkg::*;
#(
  localparam int W   = RENAME_WIDTH,
  localparam int FPW = PIDX_W + 1
) (
  input  logic clk,
  input  logic rst,
  output logic ready,          // free lists initialised
  input  logic start,          // the core's reset sequence is done
  input  logic flush,
  input  tid_t flush_tid,
  input  logic flush_slp,      // with hart 1 (step 6): the flush follows a WFI gone to sleep; its thread stays blocked
  // From decode
  input  logic [W-1:0]   de_valid,
  input  uop_t [W-1:0]   de_uop,
  output logic           de_take,
  output logic [NUM_THREADS-1:0] blk_o,  // with hart 1: each thread behind a serial uop until its flush (fetch drops
                                         // its later instructions; RN drops its group: the flush would)
  output logic [NUM_THREADS-1:0] acc_o,  // with hart 1 (step 5d): each thread's RN register can take decode's group
                                         // next cycle (it will be empty, or renamed from): decode's thread choice
  // Window state, per thread
  input  robid_t [NUM_THREADS-1:0] rob_head,
  input  lqid_t  [NUM_THREADS-1:0] lq_head,
  input  sqid_t  [NUM_THREADS-1:0] sq_head,
  input  sqid_t  [NUM_THREADS-1:0] sq_cmt,      // first uncommitted SQ entry
  // Issue state
  input  logic [N_IQ-1:0][DISPATCH_WIDTH-1:0] iq_bank_free,
  input  logic [N_IQ-1:0][DISPATCH_WIDTH-1:0] iq_bank_free2,  // at least two rows free (STEER_LA)
  // M7 step 7's caps (tg_issue, registered; all ones while they are off): [q][t][n-1], thread t may take n more rows
  // of queue q (n up to 2 W: a group at DS and one at RN); [q][t][k][j-1], it may take j more rows of bank k and
  // still not hold all of it
  input  logic [N_IQ-1:0][NUM_THREADS-1:0][2*DISPATCH_WIDTH-1:0]    iq_room_ge,
  input  logic [N_IQ-1:0][NUM_THREADS-1:0][DISPATCH_WIDTH-1:0][1:0] iq_bank_left,
  input  logic [NCOL-1:0] w_vec,
  input  logic [NCOL-1:0] busy,         // IDs a queued row still depends on: not reallocated
  // Register-file writes (ready bits), LLT releases, divides leaving the divider
  input  logic [INT_BANKS-1:0]             rf_we,
  input  logic [INT_BANKS-1:0][PIDX_W-1:0] rf_widx,
  input  logic [LLT_ENTRIES-1:0]           llt_rel,
  input  logic [IQ_TAGS-1:0]               tag_free,    // tags returned (registered)
  input  logic                             div_done,
  input  tid_t                             div_done_tid,   // ... its thread (hart 1: the per-thread shares)
  // F and D (EXT_FD): FP register-file writes (F0: P4, F1: FP loads), P4 issue and returns
  input  logic [1:0]                       fp_we,
  input  logic [1:0][FPIDX_W-1:0]          fp_widx,
  input  logic                             fdiv_iss,    // IQ-FP issued a divide / sqrt
  input  logic                             fpi_iss,     // ... an FP->int op
  input  tid_t                             fp_iss_tid,  // ... its thread (IQ-FP's one issue)
  input  logic                             fdiv_done,   // P4 returned a divide
  input  logic                             fpi_pop,     // ... an FP->int op
  // Commit (one thread's group a cycle)
  input  tid_t                             cm_tid,
  input  logic [COMMIT_WIDTH-1:0]          cm_valid,
  input  logic [COMMIT_WIDTH-1:0]          cm_rd_en,
  input  logic [COMMIT_WIDTH-1:0][4:0]     cm_rd,
  input  preg_t [COMMIT_WIDTH-1:0]         cm_dst,
  input  preg_t [COMMIT_WIDTH-1:0]         cm_old,
  input  logic [COMMIT_WIDTH-1:0]          cm_rd_fp,    // ... rd is an f register
  // DS
  output logic                             ds_fire,
  output logic [DISPATCH_WIDTH-1:0]        ds_valid,
  output uop_t [DISPATCH_WIDTH-1:0]        ds_uop,
  output ren_t [DISPATCH_WIDTH-1:0]        ds_ren,
  output logic [N_IQ-1:0][DISPATCH_WIDTH-1:0] iq_we,
  output logic [DISPATCH_WIDTH-1:0][NCOL-1:0] iq_dep,
  output iq_pl_t [DISPATCH_WIDTH-1:0]      iq_pl,
  output logic [DISPATCH_WIDTH-1:0][RA-1:0] iq_mdep,     // MX: sources named by ALU-queue row
  input  logic [RA-1:0]                    mx_hold,     // ALU-queue rows holding an op
  input  logic [N_ALU-1:0][DISPATCH_WIDTH-1:0][RA-1:0] mx_alloc,  // rows written next
  output logic [NCOL-1:0]                  wid_alloc,   // IDs given out at RN (clear W)
  output logic [DISPATCH_WIDTH-1:0]        ds_src2_rdy,  // DS: rs2's register is written
  output robid_t [NUM_THREADS-1:0]         rob_tail,    // next ROB entry RN gives out, per thread
  output logic [7:0]                       dbg_o,       // board debug: RN's stall flags (tg_core's dbg_o)
  // Step 6 (D2, threading.md), with hart 1: a sleeping thread lends its half of the window to its sibling
  input  logic [NUM_THREADS-1:0]           slp_i,       // each thread asleep (tg_rob)
  input  logic [NUM_THREADS-1:0]           wkr_i,       // ... and asking to wake
  output md_t                              md_o,        // the mode (tg_core_pkg's md_t)
  output md_t                              mdn_o,       // ... next cycle's
  output logic                             mrs_o,       // at this edge the split moves md_o.run's empty window to
                                                        // its half's start (tg_rob, tg_lsu)
  output logic [NUM_THREADS-1:0]           wk_o,        // each sleeping thread wakes (registered)
  output logic                             sph_o        // a wake waits for the split: md_o.run's WFI retires (tg_rob)
);
  if (W != DISPATCH_WIDTH) begin : g_bad
    $error("tg_rename: RENAME_WIDTH must equal DISPATCH_WIDTH");
  end

  // ---- State ----
  localparam int KSW = idx_w(W);
  typedef struct packed {
    pid_t           id;                    // producer's column, or its ROB index if l1
    logic           cv;                    // ... has a wakeup column
    logic           l1;                    // ... is a 1-cycle op
    logic [KSW-1:0] ks;                    // ... renamed in this slot of its group
  } rprod_t;
  function automatic logic is_lat1(input uclass_e c);       // a 1-cycle op in an ALU queue
    return c == C_ALU || c == C_BR;
  endfunction
  localparam int NT = NUM_THREADS;
  // M7's step 6 (D2): the mode, merged or split (md_q, below), and next cycle's; constants without hart 1
  md_t md_q, mdn_q;
  md_t md, mdn;
  assign md  = HART1_ON ? md_q : MD_C;
  assign mdn = HART1_ON ? mdn_q : MD_C;
  logic sp_hold;                    // the split stops the running thread's renaming
  logic [NT-1:0] mg_pend;           // each thread runs beside a sleeper whose window is empty: a merge waits
  logic [NT-1:0] nwr_hold;          // ... and a tail is within a group of its half's end: that thread waits
  // the end of thread t's half (split): its pointers' last index + 1
  function automatic int rob_end(input int t); return (t != 0) ? ROB_ENTRIES : ROB_ENTRIES / 2; endfunction
  function automatic int lq_end(input int t);  return (t != 0) ? LQ_ENTRIES : LQ_ENTRIES / 2;   endfunction
  function automatic int sq_end(input int t);  return (t != 0) ? SQ_ENTRIES : SQ_ENTRIES / 2;   endfunction
  logic [LLT_ENTRIES-1:0] llt_busy_q;
  logic [IQ_TAGS-1:0]    tag_busy_q;
  logic [LLT_ENTRIES-1:0] llt_tid_q;       // each LLT's and tag's thread (bit 0 of the tid: NT <= 2)
  logic [IQ_TAGS-1:0]    tag_tid_q;
  robid_t [NT-1:0]       rtail_q;
  lqid_t  [NT-1:0]       ltail_q;
  sqid_t  [NT-1:0]       stail_q;
  logic [idx_w(DIV_INFLIGHT + 1)-1:0] div_cnt_q;
  // FP divides and FP->int ops: renamed, not yet issued (a flush drops them) / issued, not
  // yet returned by P4
  logic [idx_w(FDIV_INFLIGHT + 1)-1:0] fdiv_pre_q, fdiv_post_q;
  logic [idx_w(FPI_INFLIGHT + 1)-1:0]  fpi_pre_q, fpi_post_q;
  logic [NT-1:0]         block_q;          // after a serialising uop, until the thread's flush
  // With hart 1 each thread's share of the divide count and of the FP counts not yet issued, so a flush takes only
  // its own off the totals (without hart 1 a flush empties them: one thread runs)
  localparam bit CMT = HART1_ON && NT > 1;
  logic [NT-1:0][idx_w(DIV_INFLIGHT + 1)-1:0]  div_t_q;
  logic [NT-1:0][idx_w(FDIV_INFLIGHT + 1)-1:0] fdiv_pre_t_q;
  logic [NT-1:0][idx_w(FPI_INFLIGHT + 1)-1:0]  fpi_pre_t_q;
  logic                                        div_dec;      // a divide returned: the total (and its share) drop
  assign div_dec = div_done && (CMT ? div_t_q[div_done_tid] != '0 : div_cnt_q != '0);
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (CMT && !rst)
      assert (int'(div_cnt_q) == int'(div_t_q[0]) + int'(div_t_q[NT-1]) &&
              int'(fdiv_pre_q) == int'(fdiv_pre_t_q[0]) + int'(fdiv_pre_t_q[NT-1]) &&
              int'(fpi_pre_q) == int'(fpi_pre_t_q[0]) + int'(fpi_pre_t_q[NT-1]))
        else $error("tg_rename: a count differs from its threads' shares");
`endif

  // RN: a register per thread with hart 1 (step 5d), one without; rn_valid_q and rn_uop_q are the group rename
  // works on this cycle, the selected register's (sel_q). The select is a register, so its multiplexer sits after
  // the RN registers, not on decode's path into them.
  localparam int NRN = CMT ? NT : 1;
  logic [NRN-1:0][W-1:0] rn_v_q;
  uop_t [NRN-1:0][W-1:0] rn_u_q;
  logic                  sel_q;            // (CMT) the RN register rename works on this cycle: its thread
  logic [W-1:0]          rn_valid_q;
  uop_t [W-1:0]          rn_uop_q;
  assign rn_valid_q = rn_v_q[CMT ? sel_q : 1'b0];
  assign rn_uop_q   = rn_u_q[CMT ? sel_q : 1'b0];
  logic [W-1:0]          ds_valid_q;
  uop_t [W-1:0]          ds_uop_q;
  ren_t [W-1:0]          ds_ren_q;
  logic [W-1:0][N_IQ-1:0] ds_qoh_q;        // DS's slots' queues, one-hot (none without a queue): ds_ren_q's has_q and q
  // DR-185: the fields rename never reads (the payload: the PC, the instruction, the prediction state, the immediate,
  // the branch target, the units' controls) wait in a LUTRAM beside rename, not in the RN and DS registers. Decode
  // writes a group's payload as the group enters its thread's RN register; DS reads it as the group dispatches. A
  // thread has at most two groups between them (its RN register's and DS's); with three rows a thread ({thread, row})
  // one is always free, so decode writes its group every cycle into its thread's free row, chosen from registers
  // alone (the write port waits for no fire). With PAY_WREG (the default) the write is registered and lands a cycle
  // later (pay_wa_q, pay_wd_q): decode's paths end at flip-flops beside decode, not at the LUTRAM, and a group taken
  // in cycle c is written at the end of c + 1, while DS reads it at c + 2 at the earliest. The RN and DS registers keep
  // the fields rename reads and the row (rn_s_q, ds_s_q). ds_full is DS's group whole.
  typedef struct packed {
    logic [63:0]     pc;
    logic [31:0]     insn;
    logic            rvc;
    logic [63:0]     pred_npc;
    logic            ubtb_hit, ubtb_way, dfix, ptk;
    logic [FTQW-1:0] ftq;
    tg_alu_pkg::alu_ctl_t alu;
    logic            b_imm;
    logic [63:0]     imm;
    br_kind_e        br_kind;
    logic [2:0]      br_f3;
    logic [63:0]     br_target;
    logic [11:0]     jalr_off;
    logic [1:0]      mem_size;
    logic            mem_uns;
    logic [4:0]      amo_op;
    mul_op_e         mul_op;
    div_op_e         div_op;
    logic            word, bcnt;
    csr_op_e         csr_op;
    logic            csr_imm, csr_wr;
    sys_e            sys;
    logic [3:0]      exc_cause;
    logic            exc_hi;
    tg_fpu_pkg::fop_e  fop;
    tg_fpu_pkg::ffmt_e fmt, src_fmt;
    tg_fpu_pkg::ifmt_e ifmt;
    tg_fpu_pkg::rm_e   rm;
  } pay_t;
  /* verilator lint_off UNUSEDSIGNAL */            // each of the two reads its own part of the uop
  function automatic pay_t pay_of(input uop_t u);
    pay_t p;
    p.pc = u.pc; p.insn = u.insn; p.rvc = u.rvc; p.pred_npc = u.pred_npc; p.ubtb_hit = u.ubtb_hit;
    p.ubtb_way = u.ubtb_way; p.dfix = u.dfix; p.ptk = u.ptk; p.ftq = u.ftq;
    p.alu = u.d.alu; p.b_imm = u.d.b_imm; p.imm = u.d.imm; p.br_kind = u.d.br_kind; p.br_f3 = u.d.br_f3;
    p.br_target = u.d.br_target; p.jalr_off = u.d.jalr_off; p.mem_size = u.d.mem_size; p.mem_uns = u.d.mem_uns;
    p.amo_op = u.d.amo_op; p.mul_op = u.d.mul_op; p.div_op = u.d.div_op; p.word = u.d.word; p.bcnt = u.d.bcnt;
    p.csr_op = u.d.csr_op; p.csr_imm = u.d.csr_imm; p.csr_wr = u.d.csr_wr; p.sys = u.d.sys;
    p.exc_cause = u.d.exc_cause; p.exc_hi = u.d.exc_hi; p.fop = u.d.fop; p.fmt = u.d.fmt; p.src_fmt = u.d.src_fmt;
    p.ifmt = u.d.ifmt; p.rm = u.d.rm;
    return p;
  endfunction
  function automatic uop_t ren_of(input uop_t u);     // the fields rename reads; the payload's zero
    uop_t r;
    r = '0;
    r.tid = u.tid; r.d.cls = u.d.cls; r.d.rs1 = u.d.rs1; r.d.rs2 = u.d.rs2; r.d.rd = u.d.rd; r.d.rs3 = u.d.rs3;
    r.d.rs1_en = u.d.rs1_en; r.d.rs2_en = u.d.rs2_en; r.d.rd_en = u.d.rd_en; r.d.rs3_en = u.d.rs3_en;
    r.d.rs1_fp = u.d.rs1_fp; r.d.rs2_fp = u.d.rs2_fp; r.d.rd_fp = u.d.rd_fp; r.d.amo = u.d.amo;
    r.d.serial = u.d.serial; r.d.exc = u.d.exc; r.d.fp_int = u.d.fp_int; r.d.fp_div = u.d.fp_div;
    return r;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  function automatic uop_t with_pay(input uop_t r, input pay_t p);
    uop_t u;
    u = r;
    u.pc = p.pc; u.insn = p.insn; u.rvc = p.rvc; u.pred_npc = p.pred_npc; u.ubtb_hit = p.ubtb_hit;
    u.ubtb_way = p.ubtb_way; u.dfix = p.dfix; u.ptk = p.ptk; u.ftq = p.ftq;
    u.d.alu = p.alu; u.d.b_imm = p.b_imm; u.d.imm = p.imm; u.d.br_kind = p.br_kind; u.d.br_f3 = p.br_f3;
    u.d.br_target = p.br_target; u.d.jalr_off = p.jalr_off; u.d.mem_size = p.mem_size; u.d.mem_uns = p.mem_uns;
    u.d.amo_op = p.amo_op; u.d.mul_op = p.mul_op; u.d.div_op = p.div_op; u.d.word = p.word; u.d.bcnt = p.bcnt;
    u.d.csr_op = p.csr_op; u.d.csr_imm = p.csr_imm; u.d.csr_wr = p.csr_wr; u.d.sys = p.sys;
    u.d.exc_cause = p.exc_cause; u.d.exc_hi = p.exc_hi; u.d.fop = p.fop; u.d.fmt = p.fmt; u.d.src_fmt = p.src_fmt;
    u.d.ifmt = p.ifmt; u.d.rm = p.rm;
    return u;
  endfunction
  localparam int PAYW = $bits(pay_t);
  localparam int PAYA = (NRN > 1) ? 3 : 2;          // a payload row's address: {thread,} row (0..2)
  logic [NRN-1:0][1:0]   rn_s_q;                    // each RN register's group's row
  logic [1:0]            ds_s_q;                    // DS's group's
  logic [1:0]            pay_s;                     // the free row of decode's thread: where its group is written
  pay_t [W-1:0]          ds_pay;
  uop_t [W-1:0]          ds_full;
  // The threads: RN's group (t_rn), DS's (t_ds), commit's (t_cm) and the flushed one (t_fl); without SMT thread 0,
  // whatever
  // the tid bits hold
  tid_t t_rn, t_ds, t_cm, t_fl;
  assign t_rn = CMT ? tid_t'(sel_q) : (NT > 1) ? rn_uop_q[0].tid : tid_t'(0);
  assign t_ds = (NT > 1) ? ds_uop_q[0].tid : tid_t'(0);
  assign t_cm = (NT > 1) ? cm_tid : tid_t'(0);
  assign t_fl = (NT > 1) ? flush_tid : tid_t'(0);

  logic [3*W-1:0] irdy;                  // integer ready table reads: RN sources, DS rs2
  logic [4*W-1:0] frdy;                  // FP: RN sources (3 per slot), DS rs2
  for (genvar k = 0; k < W; k++) begin : g_s2r
    assign ds_src2_rdy[k] = (EXT_FD && ds_uop_q[k].d.rs2_fp) ? frdy[3*W + k] : irdy[2*W + k];
  end
  assign rob_tail  = rtail_q;

  // Rename's fire, declared ahead of the free lists that take it: inside their generate blocks a
  // not-yet-declared name becomes a new implicit net in synthesis (Vivado: Synth 8-11241), which
  // left `pop` undriven, so no free list's head ever moved and every allocation of a bank got the
  // same register (the board's register corruption; simulation resolves the name to this one)
  logic         rn_fire;

  // ---- Free lists, one per bank (bank 0 keeps preg 0 as the zero register, and x1..x31) ----
  logic [INT_BANKS-1:0]                 fl_ready;
  logic [INT_BANKS-1:0][NT-1:0][FPW-1:0] fl_count;
  logic [INT_BANKS-1:0][W-1:0][PIDX_W-1:0] fl_pop;
  logic [INT_BANKS-1:0][idx_w(W+1)-1:0] fl_pop_n;
  logic [INT_BANKS-1:0][COMMIT_WIDTH-1:0] fl_push_v;
  logic [INT_BANKS-1:0][COMMIT_WIDTH-1:0][PIDX_W-1:0] fl_push_idx;
  logic [INT_BANKS-1:0][idx_w(COMMIT_WIDTH+1)-1:0] fl_cmt_n;
  // Transfers (HART1_ON, D3 revised): a group waiting for a bank's registers asks that bank's list for its sibling's,
  // one a cycle; the want is registered (off rename's fire path), and taken while the group's thread is at RN
  logic [INT_BANKS-1:0] fl_want_q, fl_xfer;
  logic [1:0]           ffl_want_q, ffl_xfer;
  tid_t                 want_t_q;
  for (genvar b = 0; b < INT_BANKS; b++) begin : g_fl
    // homes: bank 0's 0-31 for the running thread; with hart 1 (step 5) its homes too (tg_core_pkg H1_*: bank 1's
    // 0-15, the load bank's 0-14), and the rest of each bank divided between the harts (FIRST_S), with transfers
    tg_freelist #(.DEPTH(INT_PREGS_PER_BANK), .NB(FL_BANKS), .NPOP(W), .NPUSH(COMMIT_WIDTH),
                  .FIRST(b == 0 ? 32 : 0), .SPLIT_L(HART1_ON),
                  .FIRST_S(b == 0 ? 32 : b == H1_LO_BANK ? H1_LO_N : b == H1_HI_BANK ? H1_HI_N : 0)) u_fl (
      .clk, .rst, .ready(fl_ready[b]), .count(fl_count[b]), .pop_tid(t_rn), .pop_idx(fl_pop[b]),
      .pop_n(fl_pop_n[b]), .pop(rn_fire), .push_tid(t_cm), .push_v(fl_push_v[b]), .push_idx(fl_push_idx[b]),
      .commit_n(fl_cmt_n[b]), .flush, .flush_tid(t_fl), .want(fl_want_q[b]), .want_tid(want_t_q),
      .give_last(1'b1), .xfer(fl_xfer[b]));
  end

  // ---- FP free lists (EXT_FD): F0 starts with indices 32-63 (f0-f31 map to F0 0-31), F1 0-63; with hart 1 (step 5)
  // its f0-f31 are F1's 0-31 and each bank's rest (32-63) is divided between the harts. With hart 1 an FP destination
  // whose own bank (P4's results F0, FP loads F1) has no register left for its thread takes the other's (DR-179)
  localparam bit FXB = FP_XBANK;
  logic [1:0] fown_s;               // (FXB) a destination found its own bank short for its thread (it crossed)
  logic       fgl;                  // (FXB) the FP lists' giver (want_t_q's sibling) is blocked: it gives its last
  assign fgl = FXB && block_q[CMT ? !want_t_q : 1'b0];
  logic [1:0]                         ffl_ready;
  logic [1:0][NT-1:0][FPIDX_W:0]      ffl_count;
  logic [1:0][W-1:0][FPIDX_W-1:0]     ffl_pop;
  logic [1:0][idx_w(W+1)-1:0]         ffl_pop_n;
  logic [1:0][COMMIT_WIDTH-1:0]       ffl_push_v;
  logic [1:0][COMMIT_WIDTH-1:0][FPIDX_W-1:0] ffl_push_idx;
  logic [1:0][idx_w(COMMIT_WIDTH+1)-1:0] ffl_cmt_n;
  logic [1:0][idx_w(W+1)-1:0]         fpops;
  if (EXT_FD) begin : g_ffl
    for (genvar b = 0; b < 2; b++) begin : g_b
      tg_freelist #(.DEPTH(FP_PREGS_PER_BANK), .NB(FL_BANKS), .NPOP(W), .NPUSH(COMMIT_WIDTH),
                    .FIRST(b == FPB_F0 ? 32 : 0), .SPLIT_L(HART1_ON), .FIRST_S(32)) u_fl (
        .clk, .rst, .ready(ffl_ready[b]), .count(ffl_count[b]), .pop_tid(t_rn), .pop_idx(ffl_pop[b]),
        .pop_n(ffl_pop_n[b]), .pop(rn_fire), .push_tid(t_cm), .push_v(ffl_push_v[b]), .push_idx(ffl_push_idx[b]),
        .commit_n(ffl_cmt_n[b]), .flush, .flush_tid(t_fl), .want(ffl_want_q[b]), .want_tid(want_t_q),
        .give_last(fgl), .xfer(ffl_xfer[b]));
    end
  end else begin : g_noffl
    assign ffl_ready = '1;
    assign ffl_count = '0;
    assign ffl_pop   = '0;
    assign ffl_xfer  = '0;
    logic unused;
    assign unused = ^{ffl_pop_n, ffl_push_v, ffl_push_idx, ffl_cmt_n};
  end

  // ---- Rename maps (LUTRAM) ----
  // Read ports: rs1 and rs2 of slot k at 2k and 2k + 1, rd (the old mapping) at 2W + k; the
  // producer fields are read for the sources only.
  localparam int NMR = 3 * W;
  localparam int PRW = $bits(preg_t);
  localparam int PDW = $bits(rprod_t);
  logic [NMR-1:0][4:0]                  map_ra;
  preg_t  [NMR-1:0]                     map_p;    // mapping per read port
  rprod_t [2*W-1:0]                     map_pd;   // producer per source port (a committed
                                                  // mapping's producer is done: not read)
  for (genvar k = 0; k < W; k++) begin : g_mra
    assign map_ra[2*k]     = rn_uop_q[k].d.rs1;
    assign map_ra[2*k+1]   = rn_uop_q[k].d.rs2;
    assign map_ra[2*W + k] = rn_uop_q[k].d.rd;
  end
  ren_t [W-1:0] ren;
  logic [W-1:0]                im_we;
  logic [W-1:0]                fm_we;                      // (declared ahead of the loop that drives it)
  logic [W-1:0][4:0]           im_wa;
  logic [W-1:0][PRW-1:0]       im_wdp;
  logic [W-1:0][PDW-1:0]       im_wdd;
  logic [COMMIT_WIDTH-1:0]     icm_we;
  logic [NMR-1:0][PRW-1:0]     im_rdp;
  logic [2*W-1:0][PDW-1:0]     im_rdd;
  logic                        imap_ready;
  for (genvar k = 0; k < W; k++) begin : g_imw
    assign im_we[k]  = rn_fire && rn_valid_q[k] && rn_uop_q[k].d.rd_en && !rn_uop_q[k].d.rd_fp;
    assign fm_we[k]  = EXT_FD && rn_fire && rn_valid_q[k] && rn_uop_q[k].d.rd_en && rn_uop_q[k].d.rd_fp;
    assign im_wa[k]  = rn_uop_q[k].d.rd;
    assign im_wdp[k] = ren[k].dst;
    assign im_wdd[k] = rprod_t'{id: is_lat1(rn_uop_q[k].d.cls) ? pid_t'(ren[k].rob[ROBW-2:0])
                                                               : pid_t'(ren[k].wid),
                                cv: ren[k].use_tag || ren[k].use_llt,
                                l1: is_lat1(rn_uop_q[k].d.cls), ks: KSW'(k)};
  end
  for (genvar j = 0; j < COMMIT_WIDTH; j++) begin : g_icm
    assign icm_we[j] = cm_valid[j] && cm_rd_en[j] && !cm_rd_fp[j];
  end
  tg_rmap #(.W(W), .CW(COMMIT_WIDTH), .PW(PRW), .DW(PDW), .NR(NMR), .NRD(2 * W), .HSPLIT(HART1_ON), .HIW(PIDX_W),
            .HSPL(1 + H1_LO_N), .HB_LO(H1_LO_BANK), .HOFF_LO(-1), .HB_HI(H1_HI_BANK), .HOFF_HI(-(1 + H1_LO_N)),
            .X0(1'b1)) u_imap (
    .clk, .rst, .flush, .flush_tid(t_fl), .ready(imap_ready), .rtid(t_rn), .ctid(t_cm), .ra(map_ra), .rd_p(im_rdp), .rd_d(im_rdd),
    .we(im_we), .wa(im_wa), .wd_p(im_wdp), .wd_d(im_wdd), .cwe(icm_we), .cwa(cm_rd),
    .cwd(cm_dst));
  for (genvar i = 0; i < NMR; i++) begin : g_imr
    assign map_p[i] = preg_t'(im_rdp[i]);
  end
  for (genvar i = 0; i < 2 * W; i++) begin : g_imd
    assign map_pd[i] = rprod_t'(im_rdd[i]);
  end

  // FP map (EXT_FD): rs1, rs2, rs3 of slot k at 3k .. 3k + 2, rd at 3W + k; the producer
  // fields (its wakeup column: an FP result always has one) for the sources
  localparam int FNMR = 4 * W;
  localparam int FRW  = FPIDX_W + 1;
  logic [FNMR-1:0][4:0]        fmap_ra;
  logic [FNMR-1:0][FRW-1:0]    fmap_p;
  logic [3*W-1:0][COL_W-1:0]   fmap_w;
  logic                        fmap_ready;
  logic [COMMIT_WIDTH-1:0]     fcm_we;
  logic [COMMIT_WIDTH-1:0][FRW-1:0] fcm_wd;
  for (genvar k = 0; k < W; k++) begin : g_fmra
    assign fmap_ra[3*k]     = rn_uop_q[k].d.rs1;
    assign fmap_ra[3*k+1]   = rn_uop_q[k].d.rs2;
    assign fmap_ra[3*k+2]   = rn_uop_q[k].d.rs3;
    assign fmap_ra[3*W + k] = rn_uop_q[k].d.rd;
  end
  for (genvar j = 0; j < COMMIT_WIDTH; j++) begin : g_fcm
    assign fcm_we[j] = EXT_FD && cm_valid[j] && cm_rd_en[j] && cm_rd_fp[j];
    assign fcm_wd[j] = FRW'(cm_dst[j]);
  end
  if (EXT_FD) begin : g_fmap
    logic [W-1:0][4:0]       fm_wa;
    logic [W-1:0][FRW-1:0]   fm_wdp;
    logic [W-1:0][COL_W-1:0] fm_wdd;
    for (genvar k = 0; k < W; k++) begin : g_w
      assign fm_wa[k]  = rn_uop_q[k].d.rd;
      assign fm_wdp[k] = FRW'(ren[k].dst);
      assign fm_wdd[k] = ren[k].wid;
    end
    tg_rmap #(.W(W), .CW(COMMIT_WIDTH), .PW(FRW), .DW(COL_W), .NR(FNMR), .NRD(3 * W), .HSPLIT(HART1_ON),
              .HIW(FPIDX_W), .HSPL(32), .HB_LO(FPB_F1), .HOFF_LO(0), .X0(1'b0)) u_fmap (
      .clk, .rst, .flush, .flush_tid(t_fl), .ready(fmap_ready), .rtid(t_rn), .ctid(t_cm), .ra(fmap_ra), .rd_p(fmap_p),
      .rd_d(fmap_w),
      .we(fm_we), .wa(fm_wa), .wd_p(fm_wdp), .wd_d(fm_wdd), .cwe(fcm_we), .cwa(cm_rd),
      .cwd(fcm_wd));
  end else begin : g_nofmap
    assign fmap_ready = 1'b1;
    assign fmap_p     = '0;
    assign fmap_w     = '0;
    logic unused;
    assign unused = ^{fmap_ra, fm_we, fcm_we, fcm_wd};
  end
  // ---- Ready tables (LUTRAM): set by register-file writes, cleared by allocation at RN ----
  // Read ports: the RN sources (integer rs1, rs2 of slot k at 2k, 2k + 1; FP rs1-rs3 at 3k ..
  // 3k + 2), then rs2 of each DS slot (store data).
  // Clears: every cycle, each free list's next W registers (those it holds), rename or not
  logic irdy_ready, frdy_ready;
  logic [INT_BANKS-1:0][W-1:0] icv;
  logic [1:0][W-1:0]           fcv;
  logic [3*W-1:0][BANK_W-1:0] ir_b;
  logic [3*W-1:0][PIDX_W-1:0] ir_i;
  always_comb begin
    for (int b = 0; b < INT_BANKS; b++)
      for (int c = 0; c < W; c++) icv[b][c] = int'(fl_count[b][t_rn]) > c;
    for (int b = 0; b < 2; b++)
      for (int c = 0; c < W; c++) fcv[b][c] = int'(ffl_count[b][t_rn]) > c;
  end
  for (genvar i = 0; i < 2 * W; i++) begin : g_irs
    assign ir_b[i] = preg_bank(map_p[i]);
    assign ir_i[i] = preg_idx(map_p[i]);
  end
  for (genvar k = 0; k < W; k++) begin : g_ird
    assign ir_b[2*W + k] = preg_bank(ds_ren_q[k].src2);
    assign ir_i[2*W + k] = preg_idx(ds_ren_q[k].src2);
  end
  tg_rdytab #(.NB(INT_BANKS), .DEPTH(INT_PREGS_PER_BANK), .W(W), .NR(3 * W)) u_irdy (
    .clk, .rst, .ready(irdy_ready), .set_v(rf_we), .set_i(rf_widx), .cand_v(icv), .cand_i(fl_pop),
    .rd_b(ir_b), .rd_i(ir_i), .rdy(irdy));
  if (EXT_FD) begin : g_frdy
    logic [4*W-1:0]              fr_b;
    logic [4*W-1:0][FPIDX_W-1:0] fr_i;
    for (genvar i = 0; i < 3 * W; i++) begin : g_frs
      assign fr_b[i] = fmap_p[i][FPIDX_W];
      assign fr_i[i] = fmap_p[i][FPIDX_W-1:0];
    end
    for (genvar k = 0; k < W; k++) begin : g_frd
      assign fr_b[3*W + k] = fpreg_bank(ds_ren_q[k].src2);
      assign fr_i[3*W + k] = fpreg_idx(ds_ren_q[k].src2);
    end
    tg_rdytab #(.NB(2), .DEPTH(FP_PREGS_PER_BANK), .W(W), .NR(4 * W)) u_frdy (
      .clk, .rst, .ready(frdy_ready), .set_v(fp_we), .set_i(fp_widx), .cand_v(fcv), .cand_i(ffl_pop),
      .rd_b(fr_b), .rd_i(fr_i), .rdy(frdy));
  end else begin : g_nofrdy
    assign frdy_ready = 1'b1;
    assign frdy       = '1;
    logic unused;
    assign unused = ^{fcv, ffl_pop};
  end

  // `ready` (decode may hand over a group) does not wait for the ready tables' sweep: it takes
  // 64 cycles after reset, as the D$'s does, so only rn_fire waits for it, and no earlier than
  // `start` did
  assign ready = &fl_ready && imap_ready && &ffl_ready && fmap_ready;

  // ---- RN ----
  // Wakeup columns: an LLT for loads, atomics and divides with a destination, a tag for MUL and
  // the bit counts (P1's MUL slot), none for 1-cycle and serialised ops. The slot after c users
  // takes the (c+1)-th free one from the bottom, all slots at once: one-hot picks from the free
  // vector with its lowest c bits cleared (timing: no slot waits for the one before)
  logic [W-1:0]                  u_llt, u_tag;
  logic [W-1:0][LLT_ENTRIES-1:0] llt_oh;
  logic [W-1:0][IQ_TAGS-1:0]     tag_oh;
  logic                          llt_short, tag_short;
  always_comb begin
    for (int k = 0; k < W; k++) begin
      u_llt[k] = rn_uop_q[k].d.rd_en && rn_valid_q[k] &&
                 (rn_uop_q[k].d.cls == C_LD || rn_uop_q[k].d.cls == C_DIV || rn_uop_q[k].d.amo ||
                  (rn_uop_q[k].d.cls == C_FP && (rn_uop_q[k].d.fp_div || rn_uop_q[k].d.fp_int)));
      u_tag[k] = rn_uop_q[k].d.rd_en && rn_valid_q[k] &&
                 (rn_uop_q[k].d.cls == C_MUL ||
                  (rn_uop_q[k].d.cls == C_FP && !rn_uop_q[k].d.fp_div && !rn_uop_q[k].d.fp_int));
    end
  end
  always_comb begin
    logic [W-1:0][LLT_ENTRIES-1:0] lf;   // the free vectors less their lowest c bits
    logic [W-1:0][IQ_TAGS-1:0]     tf;
    logic [LLT_ENTRIES-1:0]        l;
    logic [IQ_TAGS-1:0]            t;
    int cl, ct;
    l = ~llt_busy_q & ~busy[IQ_TAGS +: LLT_ENTRIES];
    t = ~tag_busy_q;
    for (int c = 0; c < W; c++) begin
      lf[c] = l;
      tf[c] = t;
      l = l & (l - 1'b1);
      t = t & (t - 1'b1);
    end
    llt_short = 1'b0;
    tag_short = 1'b0;
    cl = 0;
    ct = 0;
    for (int k = 0; k < W; k++) begin
      llt_oh[k] = '0;
      tag_oh[k] = '0;
      if (u_llt[k]) begin
        llt_oh[k] = lf[cl] & (~lf[cl] + 1'b1);
        if (lf[cl] == '0) llt_short = 1'b1;
        cl++;
      end
      if (u_tag[k]) begin
        tag_oh[k] = tf[ct] & (~tf[ct] + 1'b1);
        if (tf[ct] == '0) tag_short = 1'b1;
        ct++;
      end
    end
  end
  function automatic int oh_enc(input logic [NCOL-1:0] x);   // the set bit's index (0 if none)
    int r;
    r = 0;
    for (int t = 0; t < NCOL; t++) if (x[t]) r |= t;
    return r;
  endfunction

  // Room for n more of each counted resource, n = 0..W, from registers, so the group's needs pick
  // one at the end; the free lists' are icv / fcv (timing: no compare after the steering)
  // (each thread's, picked by the group's thread: the compares stay on registers)
  logic [W:0] rob_room, lq_room, sq_room, div_room, fdiv_room, fpi_room;
`ifndef SYNTHESIS
  logic [6:0] rn_why;           // why the RN group cannot fire: ROB, LQ, SQ, tags/LLTs, unit counts, int/FP registers
`endif
  logic [NT-1:0][W:0] rob_room_t, lq_room_t, sq_room_t;
  always_comb begin
    for (int t = 0; t < NT; t++)
      for (int n = 0; n <= W; n++) begin
        rob_room_t[t][n] = rob_cnt_t(rtail_q[t], rob_head[t], md) + n <= part_size(ROB_ENTRIES, md) && !nwr_hold[t];
        lq_room_t[t][n]  = lq_cnt_t(ltail_q[t], lq_head[t], md) + n <= part_size(LQ_ENTRIES, md) && !nwr_hold[t];
        sq_room_t[t][n]  = sq_cnt_t(stail_q[t], sq_head[t], md) + n <= part_size(SQ_ENTRIES, md) && !nwr_hold[t];
      end
    rob_room = rob_room_t[t_rn];
    lq_room  = lq_room_t[t_rn];
    sq_room  = sq_room_t[t_rn];
    for (int n = 0; n <= W; n++) begin
      div_room[n]  = int'(div_cnt_q) + n <= DIV_INFLIGHT;
      fdiv_room[n] = int'(fdiv_pre_q) + int'(fdiv_post_q) + n <= FDIV_INFLIGHT;
      fpi_room[n]  = int'(fpi_pre_q) + int'(fpi_post_q) + n <= FPI_INFLIGHT;
    end
  end
`ifndef SYNTHESIS
  logic          rn_ok_ref;         // the compares the flags replace (checked below)
`endif

  // The ALU-queue banks the steering may take (STEER_LA): the flags count a bank's free rows after the
  // last dispatch, not the one in DS now, so a bank whose last free row the DS op in this slot takes
  // is full for the group behind it: it needs a second free row (DS fires before RN's group reaches
  // it; when DS holds, RN holds too and steers again)
  logic [N_IQ-1:0][W-1:0] st_free;
  always_comb
    for (int p = 0; p < N_IQ; p++)
      for (int k = 0; k < W; k++)
        st_free[p][k] = !STEER_LA ? iq_bank_free[p][k]
                      : iq_bank_free2[p][k] ||
                        (iq_bank_free[p][k] && !(ds_valid_q[k] && ds_qoh_q[k][p]));

  // M7 step 7's caps (DR-175; smt2_report §13.15): R1, a thread holds at most IQ_CAP_PCT of each queue's rows; R2, it
  // takes no row that would leave it holding all of a bank's rows while its sibling's waiting group (the sibling's RN
  // register) needs a row in that bank (IQ_BANK_RULE 1; 2: whether or not the sibling needs it; 0: no such rule).
  // The sibling's group counts only while it waits for rows alone: everything else it needs is there, its own caps
  // included (rwo_q: rdy's terms but the rows, a cycle late). A group that waits for its window to drain (a serial
  // uop, an idle hart's WFI), for ROB, LQ or SQ room, or at its own cap would otherwise hold the running thread back
  // for a row it could not take: with that, Linux on four harts reached /init 11.5% later
  // tg_issue's flags count the rows after the last dispatch, so a thread's group at DS counts here too: cap_ok[t][q][c],
  // thread t may take c + 1 more rows of queue q beyond its DS group's; bank_ok[t][q][k], one more row of bank k. All
  // from registers. The flags are all ones while the caps are off (hart 1 off, or the halves merged: step 6), and so
  // are these. A group that fails them waits in its own RN register (R3), and the steering takes an ALU queue that
  // passes them when one does
  logic [NT-1:0][N_IQ-1:0][W-1:0] sib_need, bank_ok;
  logic [NT-1:0][N_IQ-1:0][W:0]   cap_ok;
  logic [NT-1:0]                  rwo, rwo_q;     // a thread's group waits for rows alone (below, with rdy)
  always_ff @(posedge clk) rwo_q <= rst ? '0 : rwo;
  always_comb begin
    sib_need = '0;
    if (CMT && IQ_BANK_RULE != 0)
      for (int t = 0; t < NT; t++)
        for (int k = 0; k < W; k++) begin
          if (IQ_BANK_RULE == 2)
            for (int q = 0; q < N_IQ; q++) sib_need[t][q][k] = 1'b1;
          else if (rn_v_q[CMT ? (t + 1) % NT : 0][k] && !block_q[(t + 1) % NT] && rwo_q[(t + 1) % NT])
            unique case (rn_u_q[CMT ? (t + 1) % NT : 0][k].d.cls)
              C_BR:                sib_need[t][0][k] = 1'b1;
              C_MUL, C_DIV, C_CSR: sib_need[t][1][k] = 1'b1;
              C_LD:                sib_need[t][Q_LD][k] = 1'b1;
              C_ST:                sib_need[t][Q_STA][k] = 1'b1;
              C_ALU:               for (int p = 0; p < N_ALU; p++) sib_need[t][p][k] = 1'b1;
              C_FP:                sib_need[t][EXT_FD ? Q_FP : 0][k] = 1'b1;
              default: ;
            endcase
        end
    for (int t = 0; t < NT; t++)
      for (int q = 0; q < N_IQ; q++) begin
        int dn;
        logic dk;
        dn = 0;
        for (int k = 0; k < W; k++) begin
          dk = ds_valid_q[k] && t_ds == tid_t'(t) && ds_qoh_q[k][q];
          dn += int'(dk);
          bank_ok[t][q][k] = !sib_need[t][q][k] || iq_bank_left[q][t][k][dk];
        end
        // Without R1 (IQ_CAP_PCT 100, step 7's form) tg_iq's room flags are ones, and every index a valid uop reads has
        // dn + c <= 2W - 1 (its group's earlier rows c <= W - 1, DS's dn <= W): cap_ok is ones, and no DS row count
        // reaches the steering, the fire check or rdy (the chip's ds_ren_q -> rn_fire -> decode family, §8.18)
        for (int c = 0; c <= W; c++) cap_ok[t][q][c] = IQ_CAP_PCT >= 100 || (dn + c < 2 * W && iq_room_ge[q][t][dn + c]);
      end
  end

  logic          rn_ok;             // resources available for the whole group
  logic          caps_ok;           // ... within the caps (step 7)
  logic [INT_BANKS-1:0][idx_w(W+1)-1:0] pops;
  always_comb begin
    int nrob, nld, nst, ndiv, nfdiv, nfpi, port, pref, p, b, fb;
    logic found;
    logic [N_IQ-1:0][idx_w(W+1)-1:0] qn;   // the group's rows in each queue so far (the caps)
    qn = '0;
    caps_ok = 1'b1;
    pops = '0;
    fpops = '0;
    fown_s = '0;
    nld = 0; nst = 0; ndiv = 0; nfdiv = 0; nfpi = 0; nrob = 0;
    port = 0; pref = 0; p = 0; b = 0; fb = 0;
    found = 1'b0;
    for (int k = 0; k < W; k++) begin
      ren[k] = '0;
      // Steering
      port = 0;
      ren[k].has_q = 1'b1;
      unique case (rn_uop_q[k].d.cls)
        C_BR:  port = 0;
        C_MUL, C_DIV, C_CSR: port = 1;
        C_LD:  port = Q_LD;
        C_ST:  port = Q_STA;
        C_ALU: begin
          pref = k % N_ALU;
          port = pref;
          found = 1'b0;
          for (int j = 0; j < N_ALU; j++) begin
            p = (pref + j) % N_ALU;
            if (!found && st_free[p][k] && icv[p][idx_w(W)'(pops[p])] &&       // fl_count[p] > pops[p]
                cap_ok[t_rn][p][qn[p]] && bank_ok[t_rn][p][k]) begin
              port = p;
              found = 1'b1;
            end
          end
        end
        C_FP:  port = EXT_FD ? Q_FP : 0;
        default: begin port = 0; ren[k].has_q = 1'b0; end
      endcase
      ren[k].q = QW'(port);
      if (rn_valid_q[k] && ren[k].has_q) begin
        if (!cap_ok[t_rn][port][qn[port]] || !bank_ok[t_rn][port][k]) caps_ok = 1'b0;
        qn[port] = qn[port] + 1'b1;
      end
      // Window entries
      ren[k].rob = rob_add_t(rtail_q[t_rn], k, t_rn, md);
      ren[k].lq  = lq_add_t(ltail_q[t_rn], nld, t_rn, md);
      ren[k].sq  = sq_add_t(stail_q[t_rn], nst, t_rn, md);
      if (rn_valid_q[k]) begin
        if (rn_uop_q[k].d.cls == C_LD) nld++;
        if (rn_uop_q[k].d.cls == C_ST) nst++;
        if (rn_uop_q[k].d.cls == C_DIV) ndiv++;
        if (rn_uop_q[k].d.cls == C_FP && rn_uop_q[k].d.fp_div) nfdiv++;
        if (rn_uop_q[k].d.cls == C_FP && rn_uop_q[k].d.fp_int) nfpi++;
        nrob = k + 1;
      end
      // Sources: the maps, or the closest earlier slot that writes the register
      ren[k].src1 = rn_uop_q[k].d.rs1_en ? map_p[2*k] : '0;
      ren[k].src2 = rn_uop_q[k].d.rs2_en ? map_p[2*k+1] : '0;
      ren[k].p1   = rn_uop_q[k].d.rs1_en && !irdy[2*k];
      ren[k].p2   = rn_uop_q[k].d.rs2_en && !irdy[2*k+1];
      ren[k].w1   = map_pd[2*k].id;
      ren[k].w2   = map_pd[2*k+1].id;
      ren[k].c1   = map_pd[2*k].cv;
      ren[k].c2   = map_pd[2*k+1].cv;
      ren[k].l1   = map_pd[2*k].l1;
      ren[k].l2   = map_pd[2*k+1].l1;
      ren[k].ks1  = map_pd[2*k].ks;
      ren[k].ks2  = map_pd[2*k+1].ks;
      ren[k].old  = map_p[2*W + k];
      if (EXT_FD) begin
        // f-register sources: always a wakeup column, never MX
        if (rn_uop_q[k].d.rs1_fp) begin
          ren[k].src1 = preg_t'(fmap_p[3*k]);
          ren[k].p1   = rn_uop_q[k].d.rs1_en && !frdy[3*k];
          ren[k].w1   = pid_t'(fmap_w[3*k]);
          ren[k].c1   = 1'b1;
          ren[k].l1   = 1'b0;
        end
        if (rn_uop_q[k].d.rs2_fp) begin
          ren[k].src2 = preg_t'(fmap_p[3*k+1]);
          ren[k].p2   = rn_uop_q[k].d.rs2_en && !frdy[3*k+1];
          ren[k].w2   = pid_t'(fmap_w[3*k+1]);
          ren[k].c2   = 1'b1;
          ren[k].l2   = 1'b0;
        end
        ren[k].src3 = rn_uop_q[k].d.rs3_en ? preg_t'(fmap_p[3*k+2]) : '0;
        ren[k].p3   = rn_uop_q[k].d.rs3_en && !frdy[3*k+2];
        ren[k].w3   = pid_t'(fmap_w[3*k+2]);
        ren[k].c3   = 1'b1;
        if (rn_uop_q[k].d.rd_fp) ren[k].old = preg_t'(fmap_p[3*W + k]);
      end
      for (int i = 0; i < k; i++) begin
        if (rn_uop_q[i].d.rd_en) begin
          if (rn_uop_q[k].d.rs1_en && rn_uop_q[i].d.rd == rn_uop_q[k].d.rs1 &&
              rn_uop_q[i].d.rd_fp == rn_uop_q[k].d.rs1_fp) begin
            ren[k].src1 = ren[i].dst; ren[k].p1 = 1'b1;
            ren[k].w1 = is_lat1(rn_uop_q[i].d.cls) ? pid_t'(ren[i].rob[ROBW-2:0]) : pid_t'(ren[i].wid);
            ren[k].c1 = ren[i].use_tag || ren[i].use_llt;
            ren[k].l1 = is_lat1(rn_uop_q[i].d.cls); ren[k].ks1 = KSW'(i);
          end
          if (rn_uop_q[k].d.rs2_en && rn_uop_q[i].d.rd == rn_uop_q[k].d.rs2 &&
              rn_uop_q[i].d.rd_fp == rn_uop_q[k].d.rs2_fp) begin
            ren[k].src2 = ren[i].dst; ren[k].p2 = 1'b1;
            ren[k].w2 = is_lat1(rn_uop_q[i].d.cls) ? pid_t'(ren[i].rob[ROBW-2:0]) : pid_t'(ren[i].wid);
            ren[k].c2 = ren[i].use_tag || ren[i].use_llt;
            ren[k].l2 = is_lat1(rn_uop_q[i].d.cls); ren[k].ks2 = KSW'(i);
          end
          if (EXT_FD && rn_uop_q[k].d.rs3_en && rn_uop_q[i].d.rd_fp && rn_uop_q[i].d.rd == rn_uop_q[k].d.rs3) begin
            ren[k].src3 = ren[i].dst; ren[k].p3 = 1'b1; ren[k].w3 = pid_t'(ren[i].wid); ren[k].c3 = 1'b1;
          end
          if (rn_uop_q[i].d.rd == rn_uop_q[k].d.rd && rn_uop_q[i].d.rd_fp == rn_uop_q[k].d.rd_fp)
            ren[k].old = ren[i].dst;
        end
      end
      // Wakeup column (the picks above)
      ren[k].use_llt = u_llt[k];
      ren[k].use_tag = u_tag[k];
      ren[k].wid = '0;
      if (ren[k].use_llt) begin
        ren[k].llt = llt_t'(oh_enc(NCOL'(llt_oh[k])));
        ren[k].wid = llt_col(int'(ren[k].llt));
      end else if (rn_uop_q[k].d.cls == C_FP && (rn_uop_q[k].d.fp_div || rn_uop_q[k].d.fp_int)) begin
        ren[k].wid = llt_col(0);          // rd = x0: no LLT, but P4 expects an LLT column
      end
      if (ren[k].use_tag) ren[k].wid = wid_t'(oh_enc(NCOL'(tag_oh[k])));
      // Destination from the port's bank (atomics: the load bank, written by the LSU; FP->int
      // results: bank 1); an f register from F0 (P4) or F1 (FP loads)
      if (rn_uop_q[k].d.rd_en && rn_valid_q[k]) begin
        if (EXT_FD && rn_uop_q[k].d.rd_fp) begin
          fb = (rn_uop_q[k].d.cls == C_LD) ? FPB_F1 : FPB_F0;
          // (DR-179) its own bank's list for the thread has none left after the group's earlier slots: the other
          // bank's (its pops then checked below like the own bank's); the inputs are registers, the count flags
          if (FXB && !fcv[fb][idx_w(W)'(fpops[fb])]) begin
            fown_s[fb] = 1'b1;
            fb = 1 - fb;
          end
          ren[k].dst = mk_fpreg(fb, ffl_pop[fb][fpops[fb]]);
          fpops[fb] = fpops[fb] + 1'b1;
        end else begin
          b = (port == Q_LD || rn_uop_q[k].d.amo) ? LD_BANK : (rn_uop_q[k].d.cls == C_FP) ? 1 : port;
          ren[k].dst = mk_preg(b, fl_pop[b][pops[b]]);
          pops[b] = pops[b] + 1'b1;
        end
      end
    end
    // Resources: the room flags above, picked by the group's needs
    rn_ok = 1'b1;
    if (!rob_room[nrob] || !lq_room[nld] || !sq_room[nst]) rn_ok = 1'b0;
    if (llt_short || tag_short) rn_ok = 1'b0;
    if (!div_room[ndiv] || !fdiv_room[nfdiv] || !fpi_room[nfpi]) rn_ok = 1'b0;
`ifndef SYNTHESIS
    rn_why = {1'b0, 1'b0, !div_room[ndiv] || !fdiv_room[nfdiv] || !fpi_room[nfpi], llt_short || tag_short,
              !sq_room[nst], !lq_room[nld], !rob_room[nrob]};
`endif
    for (int i = 0; i < 2; i++) begin
      if (fpops[i] != '0 && !fcv[i][idx_w(W)'(fpops[i] - 1'b1)]) begin
        rn_ok = 1'b0;                                                                 // fpops > ffl_count
`ifndef SYNTHESIS
        rn_why[6] = 1'b1;
`endif
      end
    end
    for (int i = 0; i < INT_BANKS; i++) begin
      if (pops[i] != '0 && !icv[i][idx_w(W)'(pops[i] - 1'b1)]) begin
        rn_ok = 1'b0;                                                                 // pops > fl_count
`ifndef SYNTHESIS
        rn_why[5] = 1'b1;
`endif
      end
    end
`ifndef SYNTHESIS
    rn_ok_ref = !(rob_cnt_t(rtail_q[t_rn], rob_head[t_rn], md) + nrob > part_size(ROB_ENTRIES, md) ||
                  lq_cnt_t(ltail_q[t_rn], lq_head[t_rn], md) + nld > part_size(LQ_ENTRIES, md) ||
                  sq_cnt_t(stail_q[t_rn], sq_head[t_rn], md) + nst > part_size(SQ_ENTRIES, md) || llt_short || tag_short ||
                  int'(div_cnt_q) + ndiv > DIV_INFLIGHT || int'(fdiv_pre_q) + int'(fdiv_post_q) + nfdiv > FDIV_INFLIGHT ||
                  int'(fpi_pre_q) + int'(fpi_post_q) + nfpi > FPI_INFLIGHT);
    if (nwr_hold[t_rn]) rn_ok_ref = 1'b0;
    for (int i = 0; i < 2; i++) if (int'(fpops[i]) > int'(ffl_count[i][t_rn])) rn_ok_ref = 1'b0;
    for (int i = 0; i < INT_BANKS; i++) if (int'(pops[i]) > int'(fl_count[i][t_rn])) rn_ok_ref = 1'b0;
`endif
  end

  // Serialising and exception uops: alone, into the thread's empty window; then block the thread until its flush.
  logic rn_serial, window_empty;
  assign rn_serial    = rn_valid_q[0] && (rn_uop_q[0].d.serial || rn_uop_q[0].d.exc);
  assign window_empty = rtail_q[t_rn] == rob_head[t_rn] && !(|ds_valid_q && t_ds == t_rn);

  logic ds_free;
  // (CMT) the group's issue-queue rows: each uop's bank has one for it a group ahead (st_free, the flags STEER_LA's
  // steering reads). While the other thread's register holds a group, a group short of rows waits in its own RN
  // register, not at DS, where it would hold that group too; otherwise it goes on and DS waits for the rows, as
  // without hart 1 (the row is taken the cycle it frees: waiting at RN would cost a lone thread a cycle a time,
  // 1.5-2.3% of CoreMark and Dhrystone). Split, that let a hog's group short of rows reach DS while its sibling's
  // register was empty for a cycle, and hold DS for as long as its own rows took (step 7: stride + Dhrystone hung at 250
  // cycles under the bank rule, DS so held in 60% of cycles). ROWS_AT_RN (tg_core_pkg) 2 keeps a group short of rows at
  // RN whenever the halves are split; 1 only when its own thread holds all but at most one of a bank it lacks a row in
  // (tg_issue's bank_left flags, split only: ds_hog); 0 as in step 5d. Merged, a lone thread goes on to DS as before
  logic iq_rows, rows_need, ds_hog;
  always_comb begin
    iq_rows = 1'b1;
    ds_hog  = 1'b0;
    for (int k = 0; k < W; k++)
      if (rn_valid_q[k] && ren[k].has_q && !st_free[ren[k].q][k]) begin
        iq_rows = 1'b0;
        if (ROWS_AT_RN == 1 && !iq_bank_left[ren[k].q][t_rn][k][0]) ds_hog = 1'b1;
      end
  end
  assign rows_need = CMT && (|rn_v_q[CMT ? !sel_q : 1'b0] || ds_hog || (ROWS_AT_RN == 2 && md.split));
  assign rn_fire = (|rn_valid_q) && rn_ok && ds_free && !block_q[t_rn] && !flush && ready && start &&
                   irdy_ready && frdy_ready && (!rn_serial || window_empty) && (!rows_need || iq_rows) && !sp_hold &&
                   caps_ok;
  assign blk_o   = CMT ? block_q : '0;

  // With hart 1 (step 5d) each register's group is judged from registered state: it looks able to rename when its
  // thread's ROB, LQ and SQ halves and the unit counts have room for it, its queues' banks rows (st_free; an ALU uop
  // any ALU queue's), and a serial uop finds its window drained. The free registers and the tags are left to the
  // attempt itself (none held a group in 5c's pair runs). A thread behind a serial uop (block_q) has its later group
  // dropped (its flush would kill it), so it never holds rename.
  logic [NT-1:0] rdy;
  logic [W-1:0]  alu_rows;          // some ALU queue's bank has a row for slot k
  always_comb
    for (int k = 0; k < W; k++) begin
      alu_rows[k] = 1'b0;
      for (int p = 0; p < N_ALU; p++) alu_rows[k] |= st_free[p][k];
    end
  if (!CMT) begin : g_alr_off
    logic unused_alr;
    assign unused_alr = ^alu_rows;
  end
  for (genvar t = 0; t < NT; t++) begin : g_rdy
    if (CMT) begin : g_on
      localparam int CW1 = idx_w(W + 1);
      logic [CW1-1:0] nr, nl, ns, nd, nf, ni;
      logic           iq, cq, ser, wemp, rw, r;
      logic [N_IQ-1:0][CW1-1:0] cn, cnw;
      logic           cw;              // cq with every row taken as free (rwo: the group would fire given a row)
      always_comb begin
        int q;
        logic got;
        nr = CW1'($countones(rn_v_q[t]));
        nl = CW1'(ren_nld(rn_u_q[t], rn_v_q[t]));
        ns = CW1'(ren_nst(rn_u_q[t], rn_v_q[t]));
        nd = CW1'(ren_ndiv(rn_u_q[t], rn_v_q[t]));
        nf = CW1'(ren_nfp(rn_u_q[t], rn_v_q[t], 1'b1));
        ni = CW1'(ren_nfp(rn_u_q[t], rn_v_q[t], 1'b0));
        iq = 1'b1;
        for (int k = 0; k < W; k++)
          if (rn_v_q[t][k])
            unique case (rn_u_q[t][k].d.cls)
              C_BR:                iq = iq && st_free[0][k];
              C_MUL, C_DIV, C_CSR: iq = iq && st_free[1][k];
              C_LD:                iq = iq && st_free[Q_LD][k];
              C_ST:                iq = iq && st_free[Q_STA][k];
              C_ALU:               iq = iq && alu_rows[k];
              C_FP:                iq = iq && st_free[EXT_FD ? Q_FP : 0][k];
              default: ;
            endcase
        // ... and within the caps (step 7): each uop's queue as the steering takes it, an ALU uop's the first ALU queue
        // with a row in its bank under them
        cq  = 1'b1;
        cn  = '0;
        q   = -1;
        got = 1'b0;
        for (int k = 0; k < W; k++)
          if (rn_v_q[t][k]) begin
            q = -1;
            unique case (rn_u_q[t][k].d.cls)
              C_BR:                q = 0;
              C_MUL, C_DIV, C_CSR: q = 1;
              C_LD:                q = Q_LD;
              C_ST:                q = Q_STA;
              C_FP:                q = EXT_FD ? Q_FP : 0;
              C_ALU: begin
                got = 1'b0;
                for (int j = 0; j < N_ALU; j++)
                  if (!got && st_free[(k + j) % N_ALU][k] && cap_ok[t][(k + j) % N_ALU][cn[(k + j) % N_ALU]] &&
                      bank_ok[t][(k + j) % N_ALU][k]) begin
                    q = (k + j) % N_ALU;
                    got = 1'b1;
                  end
                if (!got) cq = 1'b0;
              end
              default: ;
            endcase
            if (q >= 0) begin
              if (!cap_ok[t][q][cn[q]] || !bank_ok[t][q][k]) cq = 1'b0;
              cn[q] = cn[q] + 1'b1;
            end
          end
        // cw: the same caps and bank checks with every row taken as free, so that rwo (rw && (cq || cw)) is the group
        // that would fire given a row, R2's sibling. cq's steering takes an ALU uop's queue only where its bank has a
        // free row, so with no ALU row free in that bank cq is low, and rwo on cq alone would leave out a group short of
        // ALU rows alone: R2 then never kept an ALU bank's last row for a starved sibling (ms_stride + dhrystone, fpu-2
        // 10-22). Both are greedy, each uop taking the first ALU queue that fits, so cw may spend an earlier queue's
        // cap where cq went on to another: cq || cw counts a ready group whatever cw finds (core-2's review)
        cw  = 1'b1;
        cnw = '0;
        for (int k = 0; k < W; k++)
          if (rn_v_q[t][k]) begin
            q = -1;
            unique case (rn_u_q[t][k].d.cls)
              C_BR:                q = 0;
              C_MUL, C_DIV, C_CSR: q = 1;
              C_LD:                q = Q_LD;
              C_ST:                q = Q_STA;
              C_FP:                q = EXT_FD ? Q_FP : 0;
              C_ALU: begin
                got = 1'b0;
                for (int j = 0; j < N_ALU; j++)
                  if (!got && cap_ok[t][(k + j) % N_ALU][cnw[(k + j) % N_ALU]] && bank_ok[t][(k + j) % N_ALU][k]) begin
                    q = (k + j) % N_ALU;
                    got = 1'b1;
                  end
                if (!got) cw = 1'b0;
              end
              default: ;
            endcase
            if (q >= 0) begin
              if (!cap_ok[t][q][cnw[q]] || !bank_ok[t][q][k]) cw = 1'b0;
              cnw[q] = cnw[q] + 1'b1;
            end
          end
        ser  = rn_v_q[t][0] && (rn_u_q[t][0].d.serial || rn_u_q[t][0].d.exc);
        wemp = rtail_q[t] == rob_head[t] && !(|ds_valid_q && t_ds == tid_t'(t));
        rw   = |rn_v_q[t] && !block_q[t] && rob_room_t[t][nr] && lq_room_t[t][nl] && sq_room_t[t][ns] &&
               div_room[nd] && fdiv_room[nf] && fpi_room[ni] && (!ser || wemp);
        r    = rw && iq && cq;
      end
      assign rdy[t] = r;
      assign rwo[t] = rw && (cq || cw);
    end else begin : g_off
      assign rdy[t] = 1'b0;
      assign rwo[t] = 1'b0;
    end
  end

  // Decode's group (its thread t_de) goes into its thread's register when that is empty or renamed from this
  // cycle, or the thread is blocked (the group is dropped); without hart 1 into the one register, as before
  tid_t t_de;
  assign t_de = CMT ? de_uop[0].tid : t_rn;
  logic [NT-1:0] rn_vac;
  always_comb
    for (int t = 0; t < NT; t++)
      rn_vac[t] = CMT ? (!(|rn_v_q[CMT ? t : 0]) || (sel_q == t[0] && rn_fire) || block_q[t])
                      : (!(|rn_valid_q) || rn_fire);
  assign de_take = !flush && ready && rn_vac[t_de];

  // (CMT) the register rename works on next cycle: the other thread's when its group looks able to rename (or has
  // just come from decode, not yet judged), so two such threads alternate and a stalled group gives way; else this
  // one's while it holds a group. acc_o tells decode's thread choice which registers take a group next cycle: an
  // empty one, a blocked thread's, or the chosen one's while its group looks able to rename (rdy). A chosen group
  // that cannot (its ROB, LQ or SQ half full for a miss's length) does not keep decode on its thread: rename stays
  // on it while the other register is empty, and the other thread's group, waiting in its queue, would never come
  // (smt2_report §13.20: 52-89% of decode's empty slots in mixed pairs at 250 cycles).
  // A group short of registers stays chosen: its thread's transfer next cycle needs that thread to be the one
  // popping (tg_freelist's pt == xt, the want registered from this cycle's group), so alternating would starve it
  logic          want_any;
  always_comb begin
    want_any = 1'b0;
    for (int b = 0; b < INT_BANKS; b++) if (int'(pops[b]) > int'(fl_count[b][t_rn])) want_any = 1'b1;
    for (int b = 0; b < 2; b++) if (EXT_FD && int'(fpops[b]) > int'(ffl_count[b][t_rn])) want_any = 1'b1;
  end
  // Both are written as a choice by rn_fire and decode's valid bits (de_any) between their values for each pair (i =
  // {rn_fire, de_any}): the same function (timing: rn_fire, the end of rename's checks, reached decode's thread choice
  // through de_take, the registers' next valid bits and sel_n, and decode's valid bits through the next valid bits and
  // sel_n; now both through one select. The product chip's paths into fetch's rt_q)
  logic                    sel_n, de_any;
  logic [3:0]              sel_f, tk_f;    // sel_n, de_take given {rn_fire, de_any} = i
  logic [3:0][NT-1:0]      vn, nw, acc_f;  // each register holds a group next cycle; ... one decode hands it now; acc_o
  assign de_any = |de_valid;
  always_comb
    for (int i = 0; i < 4; i++) begin
      tk_f[i] = !flush && ready && (!(|rn_v_q[CMT ? t_de : 0]) || (sel_q == t_de[0] && i >= 2) || block_q[t_de]);
      for (int t = 0; t < NT; t++) begin
        nw[i][t] = CMT && tk_f[i] && i % 2 == 1 && t_de == tid_t'(t) && !block_q[t];
        vn[i][t] = nw[i][t] || (CMT && |rn_v_q[CMT ? t : 0] && !(sel_q == t[0] && i >= 2) && !block_q[t] &&
                                !(flush && t_fl == tid_t'(t)));
      end
      sel_f[i] = sel_q;
      if (CMT) begin
        if (vn[i][sel_q] && |rn_valid_q && want_any)                sel_f[i] = sel_q;   // its transfer needs it chosen
        else if (vn[i][!sel_q] && (nw[i][!sel_q] || rdy[!sel_q])) sel_f[i] = !sel_q;
        else if (!vn[i][sel_q])                                   sel_f[i] = !sel_q;
      end
      for (int t = 0; t < NT; t++) acc_f[i][t] = CMT && (!vn[i][t] || (sel_f[i] == t[0] && rdy[t]) || block_q[t]);
    end
  assign sel_n = sel_f[{rn_fire, de_any}];
  assign acc_o = acc_f[{rn_fire, de_any}];
`ifndef SYNTHESIS
  // The choice as it was written before, from de_take, checked against the select every cycle
  logic          sel_r;
  logic [NT-1:0] vn_r, nw_r, acc_r;
  always_comb begin
    for (int t = 0; t < NT; t++) begin
      nw_r[t] = CMT && de_take && |de_valid && t_de == tid_t'(t) && !block_q[t];
      vn_r[t] = nw_r[t] || (CMT && |rn_v_q[CMT ? t : 0] && !(sel_q == t[0] && rn_fire) && !block_q[t] &&
                            !(flush && t_fl == tid_t'(t)));
    end
    sel_r = sel_q;
    if (CMT) begin
      if (vn_r[sel_q] && |rn_valid_q && want_any)            sel_r = sel_q;
      else if (vn_r[!sel_q] && (nw_r[!sel_q] || rdy[!sel_q])) sel_r = !sel_q;
      else if (!vn_r[sel_q])                                 sel_r = !sel_q;
    end
    for (int t = 0; t < NT; t++) acc_r[t] = CMT && (!vn_r[t] || (sel_r == t[0] && rdy[t]) || block_q[t]);
  end
  always_ff @(posedge clk)
    if (!rst && CMT) assert (sel_n == sel_r && acc_o == acc_r && de_take == tk_f[{rn_fire, de_any}])
      else $error("tg_rename: the thread choice's select by rn_fire and de_any differs from the choice through de_take");
`endif

  // The pops each free list takes when rename fires (the free list applies rn_fire last)
  assign ffl_pop_n[0] = fpops[0];
  assign ffl_pop_n[1] = fpops[1];
  for (genvar b = 0; b < INT_BANKS; b++) begin : g_pops
    assign fl_pop_n[b] = pops[b];
  end

  // Transfers' wants (HART1_ON): the group at RN needs more of a bank's registers than its thread's list holds. FP
  // with crossing (DR-179): a group short in both banks asks in both; and a destination that finds its own bank short
  // asks for one there although it crosses, so it takes the sibling's spare rather than crossing into the bank the
  // other writer writes (its loads wait there for P4, P4's results there take the load path's slot). A running giver
  // keeps one; a blocked one (parked in WFI, or behind a serial uop) gives its last (fgl). On the 25 FP pairs this
  // gains 0.42 / 0.37 / 0.06% at 30 / 120 / 250 cycles over asking only while the sibling is blocked (fpu-2's runs:
  // tk_dgemm with itself +2.5 to +4.9%, its P4 results into F1 420K -> 182K at 120); where both threads overfill the
  // FP banks by design (m7_fprestore pairs) the transfers go back and forth and cost up to 11%
  always_ff @(posedge clk) begin
    if (rst || !HART1_ON) begin
      fl_want_q  <= '0;
      ffl_want_q <= '0;
      want_t_q   <= '0;
    end else begin
      want_t_q <= t_rn;
      for (int b = 0; b < INT_BANKS; b++)
        fl_want_q[b] <= |rn_valid_q && int'(pops[b]) > int'(fl_count[b][t_rn]);
      for (int b = 0; b < 2; b++)
        ffl_want_q[b] <= EXT_FD && |rn_valid_q && (int'(fpops[b]) > int'(ffl_count[b][t_rn]) ||
                                                   (FXB && (fown_s[b] ||
                                                            int'(fpops[1-b]) > int'(ffl_count[1-b][t_rn]))));
    end
  end
`ifndef SYNTHESIS
  // The transfers, per bank, on stderr at the end of a run with hart 1 (stdout is compared with Spike)
  longint unsigned nxf[INT_BANKS + 2];
  always_ff @(posedge clk)
    if (rst) begin
      for (int b = 0; b < INT_BANKS + 2; b++) nxf[b] <= 0;
    end else begin
      for (int b = 0; b < INT_BANKS; b++) if (fl_xfer[b]) nxf[b] <= nxf[b] + 1;
      for (int b = 0; b < 2; b++) if (ffl_xfer[b]) nxf[INT_BANKS + b] <= nxf[INT_BANKS + b] + 1;
    end
  // The shared stall the coordinator asked to measure (M7's step 5): cycles the group rename works on does not fire
  // while the other thread's group waits for rename, in RN's other register (step 5d: rename turns to it next if it
  // looks able to go) or, with one RN register (5c), in decode behind it; on stderr at the end with hart 1
  logic oth_w, oth_r;                // the other thread's group waits ... and looks able to rename (room for it)
  always_comb begin
    oth_w = 1'b0;
    oth_r = 1'b0;
    if (CMT) begin
      oth_w = |rn_v_q[CMT ? !sel_q : 1'b0] && !block_q[!sel_q];
      oth_r = oth_w && rdy[!sel_q];
    end
  end
  longint unsigned n_rnhold2;
  always_ff @(posedge clk)
    if (rst) n_rnhold2 <= 0;
    else if (HART1_ON && |rn_valid_q && !rn_fire && !flush && oth_w) n_rnhold2 <= n_rnhold2 + 1;
  // Sharper (the throughput it may cost): that group looks able to rename (its thread's ROB, LQ, SQ halves, the unit
  // counts, its queues' rows, a serial uop's drain), so it could have gone but for the choice
  longint unsigned n_rnhold2b;
  always_ff @(posedge clk)
    if (rst) n_rnhold2b <= 0;
    else if (HART1_ON && |rn_valid_q && !rn_fire && !flush && oth_r) n_rnhold2b <= n_rnhold2b + 1;
  final if (HART1_ON) $fwrite(32'h8000_0002, "TG-STALL2 %m: RN holds the other thread's group %0d cycles (%0d with room in that thread's window)\n",
                              n_rnhold2, n_rnhold2b);
  // ... and why the group rename works on cannot fire in those cycles (each cause counted on its own; several may
  // hold): DS still holds a group, a serial uop (its block or its window's drain), the group's ROB, LQ or SQ room, the
  // shared tags or LLTs, the divide and FP counts, its integer or FP registers, its queues' rows (step 5d)
  longint unsigned n_why [10];
  always_ff @(posedge clk)
    if (rst) for (int i = 0; i < 10; i++) n_why[i] <= 0;
    else if (HART1_ON && |rn_valid_q && !rn_fire && !flush && oth_r) begin
      if (!ds_free) n_why[0] <= n_why[0] + 1;
      if (block_q[t_rn] || (rn_serial && !window_empty)) n_why[1] <= n_why[1] + 1;
      for (int k = 0; k < 7; k++) if (rn_why[k]) n_why[2 + k] <= n_why[2 + k] + 1;
      if (!iq_rows) n_why[9] <= n_why[9] + 1;
    end
  final if (HART1_ON) $fwrite(32'h8000_0002, "TG-RNHOLD %m: ds %0d serial %0d rob %0d lq %0d sq %0d tags %0d units %0d iregs %0d fregs %0d rows %0d\n",
                              n_why[0], n_why[1], n_why[2], n_why[3], n_why[4], n_why[5], n_why[6], n_why[7], n_why[8], n_why[9]);
  // With hart 1: a thread whose window (ROB, RN and DS) has been empty for a few cycles holds no wakeup tag and no LLT
  // (a tag returns two cycles after its op completes): a return lost to the other thread's flush leaks it for good
  if (CMT) begin : g_leak
    logic [NT-1:0][2:0] emp_q;               // cycles each thread's window has been empty (saturating at 7)
    always_ff @(posedge clk)
      for (int t = 0; t < NT; t++) begin
        if (rst || rtail_q[t] != rob_head[t] || |rn_v_q[t] || (|ds_valid_q && t_ds == tid_t'(t)))
          emp_q[t] <= '0;
        else if (emp_q[t] != 3'd7) emp_q[t] <= emp_q[t] + 1'b1;
        if (!rst && emp_q[t] >= 3'd5)
          for (int i = 0; i < IQ_TAGS; i++)
            assert (!(tag_busy_q[i] && tag_tid_q[i] == t[0])) else $error("tg_rename: thread %0d's window is empty but tag %0d is busy for it", t, i);
        if (!rst && emp_q[t] >= 3'd5)
          for (int i = 0; i < LLT_ENTRIES; i++)
            assert (!(llt_busy_q[i] && llt_tid_q[i] == t[0])) else $error("tg_rename: thread %0d's window is empty but LLT %0d is busy for it", t, i);
      end
  end
  // (step 7) rwo is the group that would fire given a row (core-2's review): a ready group counts, and a group that
  // counts but is not ready finds a bank it needs short of a row (its uop's queue's, or for an ALU uop some ALU
  // queue's), so its own terms (the caps, the bank rule, the rest of rw) all hold. From the first reset on: before
  // it the registers are random, and in the SoC the core's reset is a register
  if (CMT) begin : g_rwo_chk
    logic rs_q;                     // the core has been reset (as tg_lsu's)
    initial rs_q = 1'b0;
    always @(posedge clk) if (rst) rs_q <= 1'b1;
    for (genvar t = 0; t < NT; t++) begin : g_t
      logic rshort;
      always_comb begin
        rshort = 1'b0;
        for (int k = 0; k < W; k++)
          if (rn_v_q[t][k])
            unique case (rn_u_q[t][k].d.cls)
              C_BR:                rshort |= !st_free[0][k];
              C_MUL, C_DIV, C_CSR: rshort |= !st_free[1][k];
              C_LD:                rshort |= !st_free[Q_LD][k];
              C_ST:                rshort |= !st_free[Q_STA][k];
              C_FP:                rshort |= !st_free[EXT_FD ? Q_FP : 0][k];
              C_ALU:               for (int p = 0; p < N_ALU; p++) rshort |= !st_free[p][k];
              default: ;
            endcase
      end
      always_ff @(posedge clk)
        if (rs_q && !rst) begin
          assert (!rdy[t] || rwo[t]) else $error("tg_rename: thread %0d's group is ready but not counted as waiting for rows alone", t);
          assert (!rwo[t] || rdy[t] || rshort)
            else $error("tg_rename: thread %0d's group waits for rows alone with every bank it needs holding a row", t);
        end
    end
  end
  // DS's queue one-hot is ds_ren_q's has_q and q (both load while DS is free), for a valid slot, from the first reset
  logic qoh_rs_q;
  initial qoh_rs_q = 1'b0;
  always @(posedge clk) if (rst) qoh_rs_q <= 1'b1;
  always_ff @(posedge clk)
    if (qoh_rs_q && !rst)
      for (int k = 0; k < W; k++)
        for (int q = 0; q < N_IQ; q++)
          if (ds_valid_q[k])
            assert (ds_qoh_q[k][q] == (ds_ren_q[k].has_q && int'(ds_ren_q[k].q) == q))
              else $error("tg_rename: DS slot %0d's queue one-hot differs from its queue", k);
  // (DR-179) FP destinations renamed across, on stderr at the end with hart 1: P4's results into F1, FP loads into F0
  longint unsigned nfx[2];
  logic [1:0][idx_w(W+1)-1:0] fx_n;
  always_comb begin
    fx_n = '0;
    for (int k = 0; k < W; k++)
      if (EXT_FD && rn_valid_q[k] && rn_uop_q[k].d.rd_en && rn_uop_q[k].d.rd_fp &&
          int'(fpreg_bank(ren[k].dst)) != ((rn_uop_q[k].d.cls == C_LD) ? FPB_F1 : FPB_F0)) begin
        if (rn_uop_q[k].d.cls == C_LD) fx_n[1] = fx_n[1] + 1'b1;
        else                            fx_n[0] = fx_n[0] + 1'b1;
      end
  end
  always_ff @(posedge clk)
    if (rst) begin
      nfx[0] <= 0;
      nfx[1] <= 0;
    end else if (rn_fire) begin
      nfx[0] <= nfx[0] + longint'(fx_n[0]);
      nfx[1] <= nfx[1] + longint'(fx_n[1]);
    end
  final if (HART1_ON && EXT_FD) $fwrite(32'h8000_0002, "TG-FXB %m: renamed across, P4 results into F1 %0d, FP loads into F0 %0d\n",
                                        nfx[0], nfx[1]);
  // +xfer_log=FILE appends the counts to FILE, a line a run (a regress run's total: the lines' sum)
  string xf_log;
  final if (HART1_ON) begin
    int fd;
    $fwrite(32'h8000_0002, "TG-XFER %m:");
    for (int b = 0; b < INT_BANKS; b++) $fwrite(32'h8000_0002, " B%0d %0d", b, nxf[b]);
    $fwrite(32'h8000_0002, " F0 %0d F1 %0d\n", nxf[INT_BANKS], nxf[INT_BANKS + 1]);
    if ($value$plusargs("xfer_log=%s", xf_log)) begin
      fd = $fopen(xf_log, "a");
      if (fd != 0) begin
        for (int b = 0; b < INT_BANKS + 2; b++) $fwrite(fd, "%0d ", nxf[b]);
        $fwrite(fd, "\n");
        $fclose(fd);
      end
    end
  end
`endif

  always_comb begin                  // the picks' columns (each slot's vectors are 0 unless it uses one)
    wid_alloc = '0;
    if (rn_fire) begin
      for (int k = 0; k < W; k++) begin
        wid_alloc[0 +: IQ_TAGS]           |= tag_oh[k];
        wid_alloc[IQ_TAGS +: LLT_ENTRIES] |= llt_oh[k];
      end
    end
  end

  // ---- DS ----
  logic ds_ok;
  always_comb begin
    ds_ok = 1'b1;
    for (int k = 0; k < W; k++) begin
      if (ds_valid_q[k] && ds_ren_q[k].has_q && !iq_bank_free[ds_ren_q[k].q][k]) ds_ok = 1'b0;
    end
  end
  assign ds_fire  = (|ds_valid_q) && ds_ok && !flush;
  assign ds_free  = !(|ds_valid_q) || ds_fire;
  assign ds_valid = ds_valid_q;
  // Board debug (tg_core's dbg_o): slot 0 valid, serial, the empty window, the block after a
  // serial uop, resources, fire, DS busy, and ready && start
  assign dbg_o = {ready && start, |ds_valid_q, rn_fire, rn_ok, block_q[t_rn], window_empty, rn_serial,
                  rn_valid_q[0]};
`ifndef SYNTHESIS
  // (DR-185) Simulation only: each group's whole uop rides in shadows beside the RN and DS registers, loaded with them,
  // and DS's group as rejoined from the LUTRAM must equal it in every valid slot (any row reused too early shows)
  uop_t [NRN-1:0][W-1:0] rn_sh_q;
  uop_t [W-1:0]          ds_sh_q;
  logic                  pay_rs;                     // (checked from the first reset on)
  initial pay_rs = 1'b0;
  always @(posedge clk) if (rst) pay_rs <= 1'b1;
`endif
  // DR-185's payload LUTRAM (above): decode's thread's free row is the first that neither its RN register's group nor
  // its group at DS holds, from registers; the write goes there every cycle, taken or not, so a taken group's row
  // holds it and an untaken one is written again next cycle. A dropped or flushed group's row is simply free. The read
  // is DS's group's row, from registers
  always_comb begin
    logic       rv, dv;
    logic [1:0] rr;
    tid_t       td;
    td    = CMT ? t_de : tid_t'(0);
    rv    = |rn_v_q[CMT ? td[0] : 1'b0];
    rr    = rn_s_q[CMT ? td[0] : 1'b0];
    dv    = |ds_valid_q && (!CMT || t_ds == td);    // (one register without hart 1: DS's group is the thread's)
    pay_s = 2'd0;
    for (int i = 2; i >= 0; i--)
      if (!(rv && rr == 2'(i)) && !(dv && ds_s_q == 2'(i))) pay_s = 2'(i);
  end
  logic [PAYA-1:0] pay_wa, pay_ra, pay_wa_q;
  logic [W*PAYW-1:0] pay_wd, pay_rd, pay_wd_q;
  if (PAY_WREG) begin : g_pay_wreg              // (tg_core_pkg: through a register, or direct)
    always_ff @(posedge clk) begin
      pay_wa_q <= pay_wa;
      pay_wd_q <= pay_wd;
    end
  end else begin : g_pay_wdir
    assign pay_wa_q = pay_wa;
    assign pay_wd_q = pay_wd;
  end
  assign pay_wa = (NRN > 1) ? PAYA'({t_de[0], pay_s}) : PAYA'(pay_s);
  assign pay_ra = (NRN > 1) ? PAYA'({t_ds[0], ds_s_q}) : PAYA'(ds_s_q);
  always_comb for (int k = 0; k < W; k++) pay_wd[k*PAYW +: PAYW] = pay_of(de_uop[k]);
  tg_ram_lut #(.DEPTH(4 * NRN), .WIDTH(W * PAYW), .NR(1)) u_pay (
    .clk, .we(1'b1), .waddr(pay_wa_q), .wdata(pay_wd_q), .raddr(pay_ra), .rdata(pay_rd));
  always_comb
    for (int k = 0; k < W; k++) begin
      ds_pay[k]  = pay_rd[k*PAYW +: PAYW];
      ds_full[k] = with_pay(ds_uop_q[k], ds_pay[k]);
    end
`ifndef SYNTHESIS
  // (DR-185) the split loses no field: a uop's rename fields and its payload give it back whole
  always_ff @(posedge clk)
    if (!rst && de_take)
      for (int k = 0; k < W; k++)
        if (de_valid[k]) assert (with_pay(ren_of(de_uop[k]), pay_of(de_uop[k])) == de_uop[k])
          else $error("tg_rename: a uop field is neither rename's nor the payload's (DR-185)");
`endif
  assign ds_uop   = ds_full;
  assign ds_ren   = ds_ren_q;

  // MX: name a pending source by the ALU-queue row that holds its 1-cycle producer
  logic [W-1:0][RA-1:0] mrow1, mrow2;     // one-hot row, or 0 (use the ID)
  logic [W-1:0][RA-1:0] myrow;            // the row slot k is written into (ALU-queue 1-cycle ops)
  // The row of each 1-cycle op by ROB entry, one bank per rename slot. Reads: both sources of
  // every slot, in every bank; the source's producer slot picks the bank.
  localparam int ROBIW = ROBW - 1;
  logic [W-1:0][2*W-1:0][RA_W-1:0] rowrd;
  logic [2*W-1:0][ROBIW-1:0]       rowra;
  logic [W-1:0][RA_W-1:0]          row1, row2;   // the rows of each slot's rs1 and rs2 producers
  logic [W-1:0]                    rw_we;        // slot k's op takes its row ...
  logic [W-1:0][RA_W-1:0]          rw_a;         // ... this one
  // rowdst, the destination of the op each ALU-queue row holds: bank b is written only by slot b,
  // at its row, with its value XOR the other banks' there. Reads: every slot's source rows, then
  // the other slots' write rows (for that XOR).
  localparam int RDN = 3 * W - 1;
  logic [W-1:0][RDN-1:0][PRW-1:0]  rdst_rd;
  logic [W-1:0][PRW-1:0]           rdst1, rdst2; // rowdst at row1, row2
  for (genvar k = 0; k < W; k++) begin : g_rowa
    assign rowra[2*k]   = ds_ren_q[k].w1[ROBIW-1:0];
    assign rowra[2*k+1] = ds_ren_q[k].w2[ROBIW-1:0];
    assign row1[k]      = rowrd[ds_ren_q[k].ks1][2*k];
    assign row2[k]      = rowrd[ds_ren_q[k].ks2][2*k+1];
  end
  for (genvar b = 0; b < W; b++) begin : g_rowtab
    always_comb begin
      rw_a[b] = '0;
      for (int r = 0; r < RA; r++) if (myrow[b][r]) rw_a[b] = RA_W'(r);
    end
    assign rw_we[b] = IQ_MX && ds_fire && ds_valid_q[b] && ds_uop_q[b].d.rd_en &&
                      is_lat1(ds_uop_q[b].d.cls) && myrow[b] != '0;
    tg_ram_lut #(.DEPTH(ROB_ENTRIES), .WIDTH(RA_W), .NR(2 * W)) u_row (
      .clk, .we(rw_we[b]), .waddr(ds_ren_q[b].rob[ROBIW-1:0]), .wdata(rw_a[b]), .raddr(rowra),
      .rdata(rowrd[b]));
    logic [RDN-1:0][RA_W-1:0] dra;
    for (genvar k = 0; k < W; k++) begin : g_dra
      assign dra[2*k]   = row1[k];
      assign dra[2*k+1] = row2[k];
    end
    for (genvar o = 0; o < W; o++) begin : g_dro
      if (o != b) begin : g_o
        assign dra[2*W + (o < b ? o : o - 1)] = rw_a[o];
      end
    end
    logic [PRW-1:0] dwd;
    always_comb begin
      dwd = ds_ren_q[b].dst;
      for (int o = 0; o < W; o++)
        if (o != b) dwd ^= rdst_rd[o][2*W + (b < o ? b : b - 1)];
    end
    tg_ram_lut #(.DEPTH(RA), .WIDTH(PRW), .NR(RDN)) u_rdst (
      .clk, .we(rw_we[b]), .waddr(rw_a[b]), .wdata(dwd), .raddr(dra), .rdata(rdst_rd[b]));
  end
  always_comb begin
    for (int k = 0; k < W; k++) begin
      rdst1[k] = '0;
      rdst2[k] = '0;
      for (int b = 0; b < W; b++) begin
        rdst1[k] ^= rdst_rd[b][2*k];
        rdst2[k] ^= rdst_rd[b][2*k+1];
      end
    end
  end
  for (genvar k = 0; k < W; k++) begin : g_mx
    always_comb begin
      myrow[k] = '0;
      if (ds_ren_q[k].has_q && int'(ds_ren_q[k].q) < N_ALU)
        myrow[k] = mx_alloc[ds_ren_q[k].q][k];
    end
    always_comb begin
      mrow1[k] = '0;
      mrow2[k] = '0;
      if (IQ_MX) begin
        if (ds_ren_q[k].p1 && ds_ren_q[k].l1 && int'(row1[k]) < RA && mx_hold[row1[k]] &&
            rdst1[k] == ds_ren_q[k].src1)
          mrow1[k][row1[k]] = 1'b1;
        if (ds_ren_q[k].p2 && ds_ren_q[k].l2 && int'(row2[k]) < RA && mx_hold[row2[k]] &&
            rdst2[k] == ds_ren_q[k].src2)
          mrow2[k][row2[k]] = 1'b1;
        // a producer in the same group: the row it is being written into
        for (int i = 0; i < k; i++) begin
          if (ds_valid_q[i] && ds_uop_q[i].d.rd_en && is_lat1(ds_uop_q[i].d.cls) && myrow[i] != '0) begin
            if (ds_ren_q[k].p1 && ds_ren_q[i].dst == ds_ren_q[k].src1) mrow1[k] = myrow[i];
            if (ds_ren_q[k].p2 && ds_ren_q[i].dst == ds_ren_q[k].src2) mrow2[k] = myrow[i];
          end
        end
      end
    end
  end

  always_comb begin
    iq_we = '0;
    for (int k = 0; k < W; k++) begin
      if (ds_fire && ds_valid_q[k] && ds_ren_q[k].has_q) iq_we[ds_ren_q[k].q][k] = 1'b1;
      // A pending source waits on its producer's column, or on its row (MX); a 1-cycle
      // producer whose row has been freed needs nothing. A store's data (its rs2) is not a source
      // of its address op (STA_BASE): the SQ captures it when its register is written
      iq_dep[k] = '0;
      if (ds_ren_q[k].p1 && ds_ren_q[k].c1) iq_dep[k][wid_t'(ds_ren_q[k].w1)] = 1'b1;
      if (ds_ren_q[k].p2 && ds_ren_q[k].c2 && !(STA_BASE && ds_uop_q[k].d.cls == C_ST))
        iq_dep[k][wid_t'(ds_ren_q[k].w2)] = 1'b1;
      if (EXT_FD && ds_ren_q[k].p3 && ds_ren_q[k].c3) iq_dep[k][wid_t'(ds_ren_q[k].w3)] = 1'b1;
      iq_dep[k] &= ~w_vec;
      iq_mdep[k] = mrow1[k] | ((STA_BASE && ds_uop_q[k].d.cls == C_ST) ? '0 : mrow2[k]);
      iq_pl[k] = '0;
      iq_pl[k].rob       = ds_ren_q[k].rob;
      iq_pl[k].tid       = ds_full[k].tid;
      iq_pl[k].cls       = ds_full[k].d.cls;
      iq_pl[k].alu       = ds_full[k].d.alu;
      iq_pl[k].b_imm     = ds_full[k].d.b_imm;
      iq_pl[k].imm       = ds_full[k].d.imm;
      iq_pl[k].src1      = ds_ren_q[k].src1;
      iq_pl[k].src2      = ds_ren_q[k].src2;
      iq_pl[k].dst_en    = ds_full[k].d.rd_en;
      iq_pl[k].dst       = ds_ren_q[k].dst;
      iq_pl[k].wid       = ds_ren_q[k].wid;
      iq_pl[k].llt       = ds_ren_q[k].llt;
      iq_pl[k].pc        = ds_full[k].pc;
      iq_pl[k].br_kind   = ds_full[k].d.br_kind;
      iq_pl[k].br_f3     = ds_full[k].d.br_f3;
      iq_pl[k].br_target = ds_full[k].d.br_target;
      iq_pl[k].jalr_off  = ds_full[k].d.jalr_off;
      iq_pl[k].pred_npc  = ds_full[k].pred_npc;
      iq_pl[k].ubtb_hit  = ds_full[k].ubtb_hit;
      iq_pl[k].ubtb_way  = ds_full[k].ubtb_way;
      iq_pl[k].dfix      = ds_full[k].dfix;
      iq_pl[k].rvc       = ds_full[k].rvc;
      iq_pl[k].mul_op    = ds_full[k].d.mul_op;
      iq_pl[k].div_op    = ds_full[k].d.div_op;
      iq_pl[k].word      = ds_full[k].d.word;
      iq_pl[k].bcnt      = ds_full[k].d.bcnt;
      iq_pl[k].csr_op    = ds_full[k].d.csr_op;
      iq_pl[k].csr_imm   = ds_full[k].d.csr_imm;
      iq_pl[k].csr_wr    = ds_full[k].d.csr_wr;
      iq_pl[k].csr_addr  = ds_full[k].insn[31:20];
      iq_pl[k].csr_zimm  = ds_full[k].insn[19:15];
      iq_pl[k].insn      = ds_full[k].insn;
      iq_pl[k].lq        = ds_ren_q[k].lq;
      iq_pl[k].sq        = ds_ren_q[k].sq;
      iq_pl[k].mem_size  = ds_full[k].d.mem_size;
      iq_pl[k].mem_uns   = ds_full[k].d.mem_uns;
      iq_pl[k].src3      = ds_ren_q[k].src3;
      iq_pl[k].src1_fp   = ds_full[k].d.rs1_fp;
      iq_pl[k].dst_fp    = ds_full[k].d.rd_fp;
      iq_pl[k].fop       = ds_full[k].d.fop;
      iq_pl[k].fmt       = ds_full[k].d.fmt;
      iq_pl[k].src_fmt   = ds_full[k].d.src_fmt;
      iq_pl[k].ifmt      = ds_full[k].d.ifmt;
      iq_pl[k].rm        = ds_full[k].d.rm;
      iq_pl[k].fp_int    = ds_full[k].d.fp_int;
      iq_pl[k].fp_div    = ds_full[k].d.fp_div;
    end
  end

  // ---- Commit: committed map, free-list pushes and commit heads ----
  always_comb begin
    fl_push_v = '0;
    fl_push_idx = '0;
    fl_cmt_n = '0;
    ffl_push_v = '0;
    ffl_push_idx = '0;
    ffl_cmt_n = '0;
    for (int j = 0; j < COMMIT_WIDTH; j++) begin
      if (cm_valid[j] && cm_rd_en[j] && !(EXT_FD && cm_rd_fp[j])) begin
        fl_push_v[preg_bank(cm_old[j])][j]   = 1'b1;
        fl_push_idx[preg_bank(cm_old[j])][j] = preg_idx(cm_old[j]);
        fl_cmt_n[preg_bank(cm_dst[j])]       = fl_cmt_n[preg_bank(cm_dst[j])] + 1'b1;
      end
      if (EXT_FD && cm_valid[j] && cm_rd_en[j] && cm_rd_fp[j]) begin
        ffl_push_v[fpreg_bank(cm_old[j])][j]   = 1'b1;
        ffl_push_idx[fpreg_bank(cm_old[j])][j] = fpreg_idx(cm_old[j]);
        ffl_cmt_n[fpreg_bank(cm_dst[j])]       = ffl_cmt_n[fpreg_bank(cm_dst[j])] + 1'b1;
      end
    end
  end

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    if (rst) begin
      fdiv_pre_q <= '0;
      fdiv_post_q <= '0;
      fpi_pre_q  <= '0;
      fpi_post_q <= '0;
      llt_busy_q <= '0;
      tag_busy_q <= '0;
      for (int t = 0; t < NT; t++) begin
        rtail_q[t] <= rob_start(tid_t'(t), MD_C);
        ltail_q[t] <= lq_start(tid_t'(t), MD_C);
        stail_q[t] <= sq_start(tid_t'(t), MD_C);
      end
      div_cnt_q  <= '0;
      div_t_q    <= '0;
      fdiv_pre_t_q <= '0;
      fpi_pre_t_q  <= '0;
      block_q    <= '0;
      rn_v_q     <= '0;
      sel_q      <= RUN_TID[0];
      ds_valid_q <= '0;
    end else begin
      llt_busy_q <= llt_busy_q & ~llt_rel;
      fdiv_post_q <= fdiv_post_q + (idx_w(FDIV_INFLIGHT + 1))'(fdiv_iss) - (idx_w(FDIV_INFLIGHT + 1))'(fdiv_done);
      fpi_post_q  <= fpi_post_q + (idx_w(FPI_INFLIGHT + 1))'(fpi_iss) - (idx_w(FPI_INFLIGHT + 1))'(fpi_pop);
      tag_busy_q <= tag_busy_q & ~tag_free;
      if (div_dec) div_cnt_q <= div_cnt_q - 1'b1;
      if (CMT && div_dec) div_t_q[div_done_tid] <= div_t_q[div_done_tid] - 1'b1;

      if (flush) begin
        // the flushed thread's tagged producers in flight are squashed: their tags and LLTs return
        for (int i = 0; i < LLT_ENTRIES; i++) if (llt_tid_q[i] == t_fl[0]) llt_busy_q[i] <= 1'b0;
        for (int i = 0; i < IQ_TAGS; i++) if (tag_tid_q[i] == t_fl[0]) tag_busy_q[i] <= 1'b0;
        rtail_q[t_fl] <= rob_head[t_fl];
        ltail_q[t_fl] <= lq_head[t_fl];
        stail_q[t_fl] <= sq_cmt[t_fl];
        if (!CMT) begin
          div_cnt_q  <= '0;              // (one thread: its divides)
          fdiv_pre_q <= '0;              // not yet issued: gone with the flush
          fpi_pre_q  <= '0;
        end else begin                   // hart 1: the flushed thread's share goes; the other's issue and done count
          div_cnt_q <= div_cnt_q - div_t_q[t_fl] - (idx_w(DIV_INFLIGHT + 1))'(div_dec && div_done_tid != t_fl);
          div_t_q[t_fl] <= '0;
          fdiv_pre_q <= fdiv_pre_q - fdiv_pre_t_q[t_fl] - (idx_w(FDIV_INFLIGHT + 1))'(fdiv_iss && fp_iss_tid != t_fl);
          fpi_pre_q  <= fpi_pre_q - fpi_pre_t_q[t_fl] - (idx_w(FPI_INFLIGHT + 1))'(fpi_iss && fp_iss_tid != t_fl);
          fdiv_pre_t_q[t_fl] <= '0;
          fpi_pre_t_q[t_fl]  <= '0;
          if (fdiv_iss && fp_iss_tid != t_fl) fdiv_pre_t_q[fp_iss_tid] <= fdiv_pre_t_q[fp_iss_tid] - 1'b1;
          if (fpi_iss && fp_iss_tid != t_fl)  fpi_pre_t_q[fp_iss_tid]  <= fpi_pre_t_q[fp_iss_tid] - 1'b1;
        end
        block_q[t_fl] <= HART1_ON && flush_slp;   // (step 6: a WFI's sleep keeps its thread blocked until it wakes)
        if (CMT)               rn_v_q[CMT ? t_fl[0] : 1'b0] <= '0;   // (with hart 1 the flushed thread's)
        else if (t_rn == t_fl) rn_v_q[0]       <= '0;
        if (t_ds == t_fl) ds_valid_q <= '0;
      end else begin
        // FP divides and FP->int ops renamed this cycle, and those issued
        fdiv_pre_q <= fdiv_pre_q + (idx_w(FDIV_INFLIGHT + 1))'(rn_fire ? ren_nfp(rn_uop_q, rn_valid_q, 1'b1) : 0)
                      - (idx_w(FDIV_INFLIGHT + 1))'(fdiv_iss);
        fpi_pre_q  <= fpi_pre_q + (idx_w(FPI_INFLIGHT + 1))'(rn_fire ? ren_nfp(rn_uop_q, rn_valid_q, 1'b0) : 0)
                      - (idx_w(FPI_INFLIGHT + 1))'(fpi_iss);
        if (CMT)
          for (int t = 0; t < NT; t++) begin
            fdiv_pre_t_q[t] <= fdiv_pre_t_q[t]
                               + (idx_w(FDIV_INFLIGHT + 1))'((rn_fire && t_rn == tid_t'(t)) ? ren_nfp(rn_uop_q, rn_valid_q, 1'b1) : 0)
                               - (idx_w(FDIV_INFLIGHT + 1))'(fdiv_iss && fp_iss_tid == tid_t'(t));
            fpi_pre_t_q[t]  <= fpi_pre_t_q[t]
                               + (idx_w(FPI_INFLIGHT + 1))'((rn_fire && t_rn == tid_t'(t)) ? ren_nfp(rn_uop_q, rn_valid_q, 1'b0) : 0)
                               - (idx_w(FPI_INFLIGHT + 1))'(fpi_iss && fp_iss_tid == tid_t'(t));
          end
        // DS
        if (ds_fire) ds_valid_q <= '0;
        // RN -> DS
        if (rn_fire) begin
          ds_valid_q <= rn_valid_q;
          rn_v_q[CMT ? sel_q : 1'b0] <= '0;
          for (int k = 0; k < W; k++) begin
            if (rn_valid_q[k]) begin
              if (ren[k].use_llt) begin
                llt_busy_q[ren[k].llt] <= 1'b1;
                llt_tid_q[ren[k].llt]  <= t_rn[0];
              end
              if (ren[k].use_tag) begin
                tag_busy_q[ren[k].wid[WTAG_W-1:0]] <= 1'b1;
                tag_tid_q[ren[k].wid[WTAG_W-1:0]]  <= t_rn[0];
              end
            end
          end
          rtail_q[t_rn] <= rob_add_t(rtail_q[t_rn], $countones(rn_valid_q), t_rn, md);
          ltail_q[t_rn] <= lq_add_t(ltail_q[t_rn], ren_nld(rn_uop_q, rn_valid_q), t_rn, md);
          stail_q[t_rn] <= sq_add_t(stail_q[t_rn], ren_nst(rn_uop_q, rn_valid_q), t_rn, md);
          div_cnt_q <= div_cnt_q + (idx_w(DIV_INFLIGHT + 1))'(ren_ndiv(rn_uop_q, rn_valid_q))
                       - (idx_w(DIV_INFLIGHT + 1))'(div_dec);
          if (CMT)
            div_t_q[t_rn] <= div_t_q[t_rn] + (idx_w(DIV_INFLIGHT + 1))'(ren_ndiv(rn_uop_q, rn_valid_q))
                             - (idx_w(DIV_INFLIGHT + 1))'(div_dec && div_done_tid == t_rn);
          if (rn_serial) block_q[t_rn] <= 1'b1;
        end
        // DE -> RN (with hart 1 into the group's thread's register; a thread behind a serial uop drops its group)
        if (CMT) for (int t = 0; t < NT; t++) if (block_q[t]) rn_v_q[CMT ? t : 0] <= '0;
        if (de_take && !(CMT && block_q[t_de])) begin
          rn_v_q[CMT ? t_de[0] : 1'b0] <= de_valid;
          for (int k = 0; k < W; k++) rn_u_q[CMT ? t_de[0] : 1'b0][k] <= ren_of(de_uop[k]);
          rn_s_q[CMT ? t_de[0] : 1'b0] <= pay_s;     // the row this cycle's write fills
`ifndef SYNTHESIS
          rn_sh_q[CMT ? t_de[0] : 1'b0] <= de_uop;
`endif
        end
      end
      // Step 6: a wake unblocks its thread; a split with the running thread's window empty moves its tails to its
      // half's start (with the ROB's and the LSU's pointers: mrs_o)
      if (HART1_ON) begin
        for (int t = 0; t < NT; t++) if (wk_o[t]) block_q[t] <= 1'b0;
        if (mrs_o) begin
          rtail_q[md.run] <= rob_start(md.run, mdn);
          ltail_q[md.run] <= lq_start(md.run, mdn);
          stail_q[md.run] <= sq_start(md.run, mdn);
        end
      end
      if (CMT) sel_q <= sel_n;
    end
  end

  // ---- Step 6 (D2, threading.md): merge and split ----
  // A thread that waited in WFI while its sibling ran goes to sleep: tg_rob retires the WFI, and its flush keeps the
  // thread blocked here, so decode drops its groups and fetch holds its stream. Once the sleeper's window is empty
  // (its committed stores drained) a merge waits (mg_pend): the runner's tails do not wrap in its half (the room
  // flags above), so its window stops wrapping as its heads move on, and the halves merge around it. The mode,
  // decided from registered pointers and announced a cycle ahead (mdn_q, then md_q), reaches every module while the
  // tails still cannot wrap. A wake waits for the split: the runner renames nothing until its window lies in its half
  // without wrapping (win_fits), or is empty; then its pointers go back to its half's start (mrs_o). The sleeper wakes
  // with the split.
  logic          rs_q, sp_q;
  logic [NT-1:0] wk_q, emp, nwr, fit, wk_now;
  logic          mg_go, sp_go;
  tid_t          mg_r;                   // a merge's running thread
  always_comb begin
    for (int t = 0; t < NT; t++) begin
      emp[t] = rtail_q[t] == rob_head[t] && ltail_q[t] == lq_head[t] && stail_q[t] == sq_head[t];
      nwr[t] = rtail_q[t][ROBW-1] == rob_head[t][ROBW-1] && ltail_q[t][LQW-1] == lq_head[t][LQW-1] &&
               stail_q[t][SQW-1] == sq_head[t][SQW-1];        // its windows do not wrap
      fit[t] = win_fits(int'(rob_head[t][ROBW-2:0]), rob_head[t][ROBW-1], int'(rtail_q[t][ROBW-2:0]),
                        rtail_q[t][ROBW-1], ROB_ENTRIES / 2, tid_t'(t)) &&
               win_fits(int'(lq_head[t][LQW-2:0]), lq_head[t][LQW-1], int'(ltail_q[t][LQW-2:0]),
                        ltail_q[t][LQW-1], LQ_ENTRIES / 2, tid_t'(t)) &&
               win_fits(int'(sq_head[t][SQW-2:0]), sq_head[t][SQW-1], int'(stail_q[t][SQW-2:0]),
                        stail_q[t][SQW-1], SQ_ENTRIES / 2, tid_t'(t));
      // a sleeper's wake without a merge to undo (none in flight)
      wk_now[t] = HART1_ON && slp_i[t] && wkr_i[t] && !wk_q[t] && md_q.split && mdn_q.split && !sp_q;
    end
    mg_go = 1'b0;
    mg_r  = '0;
    if (HART1_ON && NT > 1 && md_q.split && mdn_q.split && !sp_q)
      for (int t = 0; t < NT; t++)
        if (slp_i[t] && !wkr_i[t] && !wk_q[t] && emp[t] && nwr[NT - 1 - t]) begin
          mg_go = 1'b1;
          mg_r  = tid_t'(NT - 1 - t);
        end
    sp_go = HART1_ON && sp_q && (fit[md_q.run] || emp[md_q.run]);
    for (int t = 0; t < NT; t++) begin
      // (a merge decided for runner t holds its tails until md_q merges, even if the sleeper asks to wake meanwhile:
      // a tail that wrapped in its half then would leave the sleeper's half inside the merged window)
      mg_pend[t] = HART1_ON && NT > 1 && md_q.split &&
                   ((!sp_q && slp_i[NT - 1 - t] && !wkr_i[NT - 1 - t] && emp[NT - 1 - t]) ||
                    (!mdn_q.split && mdn_q.run == tid_t'(t)));
      nwr_hold[t] = mg_pend[t] && (int'(rtail_q[t][ROBW-2:0]) + W >= rob_end(t) ||
                                   int'(ltail_q[t][LQW-2:0]) + W >= lq_end(t) ||
                                   int'(stail_q[t][SQW-2:0]) + W >= sq_end(t));
    end
  end
  always_ff @(posedge clk)
    if (rst || !HART1_ON) begin
      md_q  <= MD_C;
      mdn_q <= MD_C;
      rs_q  <= 1'b0;
      sp_q  <= 1'b0;
      wk_q  <= '0;
    end else begin
      md_q <= mdn_q;
      wk_q <= wk_now;
      if (mdn_q.split && !md_q.split) wk_q[~md_q.run] <= 1'b1;            // the sleeper wakes with the split
      rs_q <= sp_go && emp[md_q.run];
      if (mg_go) mdn_q <= '{split: 1'b0, run: mg_r};
      if (!md_q.split && mdn_q == md_q && wkr_i[~md_q.run] && !sp_q) sp_q <= 1'b1;
      if (sp_go) begin
        mdn_q <= '{split: 1'b1, run: md_q.run};
        sp_q  <= 1'b0;
      end
    end
  assign sp_hold = HART1_ON && (sp_q || (mdn_q.split && !md_q.split));
`ifndef SYNTHESIS
  // (step 6) a merge finds the runner's windows unwrapped in its half (mg_pend held its tails while it was in flight)
  logic mg_rs, md_sq;
  initial mg_rs = 1'b0;
  always @(posedge clk) if (rst) mg_rs <= 1'b1;
  always_ff @(posedge clk) begin
    md_sq <= md_q.split;
    if (mg_rs && !rst && HART1_ON && NT > 1 && md_sq && !md_q.split)
      assert (nwr[md_q.run]) else $error("tg_rename: a merge found thread %0d's window wrapped in its half", md_q.run);
  end
  // (step 6) the merges and splits, the cycles merged and the splits' drains, the wakes; on stderr at the end
  longint unsigned n_mg, n_sp, n_spr, n_mgc, n_spc, n_wk;
  always_ff @(posedge clk)
    if (rst) begin
      n_mg <= 0; n_sp <= 0; n_spr <= 0; n_mgc <= 0; n_spc <= 0; n_wk <= 0;
    end else if (HART1_ON) begin
      if (mg_go) n_mg <= n_mg + 1;
      if (sp_go) n_sp <= n_sp + 1;
      if (sp_go && emp[md_q.run]) n_spr <= n_spr + 1;
      if (!md_q.split) n_mgc <= n_mgc + 1;
      if (sp_q) n_spc <= n_spc + 1;
      n_wk <= n_wk + longint'($countones(wk_q));
    end
  final if (HART1_ON) $fwrite(32'h8000_0002, "TG-SMT %m: %0d merges, %0d splits (%0d with the window empty), %0d cycles merged, %0d cycles draining for a split, %0d wakes\n",
                              n_mg, n_sp, n_spr, n_mgc, n_spc, n_wk);
`endif
  assign md_o    = md;
  assign mdn_o   = mdn;
  assign mrs_o   = HART1_ON && rs_q;
  assign wk_o    = HART1_ON ? wk_q : '0;
  assign sph_o   = HART1_ON && sp_q;

  // The DS payload takes RN's group whenever DS is free, so its enable does not wait for
  // rn_fire (a load of every DS flip-flop); ds_valid_q says whether RN fired, and nothing reads
  // the payload of an invalid slot
  always_ff @(posedge clk) begin
    if (ds_free) begin
      ds_uop_q <= rn_uop_q;
      ds_ren_q <= ren;
      for (int k = 0; k < W; k++)
        for (int q = 0; q < N_IQ; q++) ds_qoh_q[k][q] <= ren[k].has_q && int'(ren[k].q) == q;
      ds_s_q   <= rn_s_q[CMT ? sel_q : 1'b0];
`ifndef SYNTHESIS
      ds_sh_q  <= rn_sh_q[CMT ? sel_q : 1'b0];
`endif
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (pay_rs && !rst)
      for (int k = 0; k < W; k++)
        if (ds_valid_q[k]) assert (ds_full[k] == ds_sh_q[k])
          else $error("tg_rename: DS's slot %0d rejoined from the payload LUTRAM differs from its group (DR-185)", k);
`endif

  function automatic int ren_nld(input uop_t [W-1:0] u, input logic [W-1:0] v);
    int n;
    n = 0;
    for (int k = 0; k < W; k++) if (v[k] && u[k].d.cls == C_LD) n++;
    return n;
  endfunction
  // FP divides (dv = 1) or FP->int ops (dv = 0) in a group
  function automatic int ren_nfp(input uop_t [W-1:0] u, input logic [W-1:0] v, input logic dv);
    int n;
    n = 0;
    for (int k = 0; k < W; k++)
      if (v[k] && u[k].d.cls == C_FP && (dv ? u[k].d.fp_div : u[k].d.fp_int)) n++;
    return n;
  endfunction
  function automatic int ren_ndiv(input uop_t [W-1:0] u, input logic [W-1:0] v);
    int n;
    n = 0;
    for (int k = 0; k < W; k++) if (v[k] && u[k].d.cls == C_DIV) n++;
    return n;
  endfunction
  function automatic int ren_nst(input uop_t [W-1:0] u, input logic [W-1:0] v);
    int n;
    n = 0;
    for (int k = 0; k < W; k++) if (v[k] && u[k].d.cls == C_ST) n++;
    return n;
  endfunction

  logic unused;
  assign unused = ^{busy[IQ_TAGS-1:0]};   // tag columns are cleared when a tag returns, not guarded

`ifndef SYNTHESIS
  // A group is a prefix of valid slots. Only allocated LLTs are released (a flush frees them
  // all, and a release registered from that cycle may follow).
  logic flush_d;
  logic ds_nr_q;                    // (CMT) DS's group left RN without its rows (the other register was empty)
  always_ff @(posedge clk) if (rn_fire) ds_nr_q <= !iq_rows;
  always_ff @(posedge clk) flush_d <= flush;
  always_ff @(posedge clk) begin
    if (!rst) begin
      assert ((llt_rel & ~llt_busy_q) == '0 || flush || flush_d)
        else $error("tg_rename: an LLT released while free");
      for (int k = 1; k < W; k++)
        assert (!rn_valid_q[k] || rn_valid_q[k-1]) else $error("tg_rename: group is not a prefix");
      assert ((tag_free & ~tag_busy_q) == '0 || flush) else $error("tg_rename: a free tag returned");
      // with hart 1 a group leaves RN without its banks' rows after DS's write (iq_rows) only while the other
      // thread's register is empty, so DS waits only for such a group: the one stage both threads pass never holds
      // one thread's group while the other thread's waited at RN (step 5d)
      if (CMT && |ds_valid_q) assert (ds_ok || ds_nr_q) else $error("tg_rename: DS holds a group that had its rows");
    end
  end
  // The resource check's flags give what the compares gave
  always_ff @(posedge clk) begin
    if (!rst) assert (rn_ok == rn_ok_ref) else $error("tg_rename: the resource flags differ from the compares");
  end
  // The parallel picks give what the in-order loop gave: each slot the first free column left
  // by the slots before it
  always_ff @(posedge clk) begin
    logic [LLT_ENTRIES-1:0] lfr;
    logic [IQ_TAGS-1:0]     tfr;
    logic                   ls, ts, got;
    int                     li, ti;
    if (!rst) begin
      lfr = ~llt_busy_q & ~busy[IQ_TAGS +: LLT_ENTRIES];
      tfr = ~tag_busy_q;
      ls = 1'b0;
      ts = 1'b0;
      for (int k = 0; k < W; k++) begin
        if (u_llt[k]) begin
          got = 1'b0; li = 0;
          for (int t = 0; t < LLT_ENTRIES; t++)
            if (!got && lfr[t]) begin got = 1'b1; lfr[t] = 1'b0; li = t; end
          if (!got) ls = 1'b1;
          assert (llt_oh[k] == (got ? LLT_ENTRIES'(1) << li : '0)) else $error("tg_rename: slot %0d's LLT pick", k);
        end
        if (u_tag[k]) begin
          got = 1'b0; ti = 0;
          for (int t = 0; t < IQ_TAGS; t++)
            if (!got && tfr[t]) begin got = 1'b1; tfr[t] = 1'b0; ti = t; end
          if (!got) ts = 1'b1;
          assert (tag_oh[k] == (got ? IQ_TAGS'(1) << ti : '0)) else $error("tg_rename: slot %0d's tag pick", k);
        end
      end
      assert (ls == llt_short && ts == tag_short) else $error("tg_rename: the picks' shortage flags");
    end
  end
`endif
`ifndef SYNTHESIS
  // (TG_FP_BANK96: banks of 96, no crossing) every FP destination comes from its own bank: P4's F0, FP loads' F1
  if (EXT_FD && !FP_XBANK) begin : g_nox
    always_ff @(posedge clk)
      if (!rst && rn_fire)
        for (int k = 0; k < W; k++)
          if (rn_valid_q[k] && rn_uop_q[k].d.rd_en && rn_uop_q[k].d.rd_fp)
            assert (int'(fpreg_bank(ren[k].dst)) == ((rn_uop_q[k].d.cls == C_LD) ? FPB_F1 : FPB_F0))
              else $error("tg_rename: an FP destination crossed banks with banks of 96");
  end
`endif
endmodule
