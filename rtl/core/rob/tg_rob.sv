// Reorder buffer and commit for M2 (docs/spec/core-pipeline.md §8, §9.3-9.4, §11).
//   Payload: ROB_BANKS-way interleaved LUTRAM, written at dispatch, read at the head.
//   Flags per entry: complete, exc, mispredict and mmio as toggle tables in LUTRAM, one per
//   reporting port (below); replay in flip-flops (an entry may be marked more than once).
// A replay marked tlb (a DTLB miss) waits at the head for the LSU: hd_retry (the DTLB now
// translates it: flush and refetch) or hd_fault (the deciding walk faulted: trap).
//   Oldest-exception and oldest-mispredict registers hold the cause/tval and the redirect
//   target of the oldest entry that reported one.
// Commit retires up to COMMIT_WIDTH complete entries in order. Exceptions, serialising
// instructions and replays are handled at the head alone; a mispredicted branch retires and
// ends the group. Every recovery is a flush plus redirect, registered (flush, flush_pc).
// Per thread (M7's step 3, docs/spec/threading.md): a head, a tail, the xRET-in-flight bits, the oldest-exception
// and oldest-mispredict registers and the WFI counter per thread. A dispatch group is one thread's (t_ds) and
// advances its tail; a flush recovers the flushing instruction's thread (flush_tid). Commit serves one thread a
// cycle (t_cm): the running thread in merged mode; in split mode (SPLIT) a registered choice, and each thread's
// pointers wrap inside its half (rob_add_t). A report's thread is its entry's (rob_tid).
module tg_rob
  import tg_pkg::*, tg_trace_pkg::*, tg_core_pkg::*;
#(
  parameter int unsigned CORE_ID = 0,
  localparam int NB   = ROB_BANKS,
  localparam int ROWS = ROB_ENTRIES / ROB_BANKS,
  localparam int RIW  = ROBW - 1,
  localparam int CW   = COMMIT_WIDTH,
  localparam int NCW  = idx_w(CW + 1)
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         ready,
  // Dispatch
  input  logic                         ds_fire,
  input  logic [DISPATCH_WIDTH-1:0]    ds_valid,
  input  uop_t [DISPATCH_WIDTH-1:0]    ds_uop,
  input  ren_t [DISPATCH_WIDTH-1:0]    ds_ren,
  output robid_t [NUM_THREADS-1:0]     head_o,       // each thread's head
  output tid_t                         hd_tid_o,     // the thread whose head commits this cycle (the LSU's head checks)
  // Completion
  input  logic [N_ALU-1:0]             alu_cmp,
  input  robid_t [N_ALU-1:0]           alu_rob,
  input  logic                         oth_cmp,
  input  robid_t                       oth_rob,
  input  logic                         oth_exc,
  input  logic [4:0]                   oth_fflags,   // FP->int results (EXT_FD)
  input  logic [63:0]                  oth_tval,
  input  logic                         br_valid,
  input  robid_t                       br_rob,
  input  logic                         br_misp,
  input  logic [63:0]                  br_npc,
  input  logic                         br_exc,
  input  logic [63:0]                  br_tval,
  input  logic                         fp_cmp,       // P4's F0 results (EXT_FD)
  input  robid_t                       fp_cmp_rob,
  input  logic [4:0]                   fp_cmp_fflags,
  input  logic                         ld_cmp,
  input  robid_t                       ld_rob,
  input  logic                         ld_mmio,
  input  logic [1:0]                   st_cmp,
  input  robid_t [1:0]                 st_rob,
  input  logic [3:0]                   lx_valid,
  input  robid_t [3:0]                 lx_rob,
  input  logic [3:0][3:0]              lx_cause,
  input  logic                         spx_valid,    // a store's PMP denial, after it completed: exception only
  input  robid_t                       spx_rob,
  input  logic [2:0]                   cmh_v,        // commit stops at these entries: the LSU's held stores
  input  robid_t [2:0]                 cmh_rob,      // (a PMP denial may come), a load whose replay mark is late
  input  logic                         replay_valid,
  input  robid_t                       replay_rob,
  input  logic [1:0]                   tlbm_valid,   // DTLB misses (LD and STA ports): replay
  input  robid_t [1:0]                 tlbm_rob,
  input  logic                         hd_tlb,       // the head is a load or store that missed the DTLB
  input  logic                         hd_retry,
  input  logic                         hd_fault,
  input  logic [3:0]                   hd_cause,
  input  logic [63:0]                  hd_lva,       // the head load's VA, or the head store's:
  input  logic [63:0]                  hd_sva,       // tval of an LSU exception (taken at the head)
  // LSU state
  input  logic                         sq_drained,
  input  logic                         mmio_busy,
  // To rename
  output logic [CW-1:0]                cm_valid,
  output logic [CW-1:0]                cm_rd_en,
  output logic [CW-1:0]                cm_rd_fp,     // rd is an f register (EXT_FD)
  output logic [CW-1:0][4:0]           cm_fflags,    // the retiring FP op's exception flags
  output tid_t  [CW-1:0]               cm_tid,       // the retiring instruction's thread
  output logic [CW-1:0][4:0]           cm_rd,
  output preg_t [CW-1:0]               cm_dst,
  output preg_t [CW-1:0]               cm_old,
  // To the return-address stack's committed copy (tg_ras): each slot's operation and link
  output logic [CW-1:0]                cm_ras_push,
  output logic [CW-1:0]                cm_ras_pop,
  output logic [CW-1:0][38:1]          cm_ras_link,
  // To TAGE (TAGE_ON): each slot's conditional branch, its outcome and fetch-time direction, its
  // block's FTQ entry and its slot; and the youngest retiring instruction's FTQ entry
  output logic [CW-1:0]                cm_cbr,
  output logic [CW-1:0]                cm_ctaken,
  output logic [CW-1:0]                cm_cpred,
  output logic [CW-1:0][FTQW-1:0]      cm_cftq,
  output logic [CW-1:0][SLOT_W-1:0]    cm_cslot,
  output logic                         cm_hv,
  output logic [FTQW-1:0]              cm_hftq,
  // To the LSU
  output logic [NCW-1:0]               cm_nld,
  output logic [NCW-1:0]               cm_nst,
  output sqid_t [CW-1:0]               tr_sq,
  input  logic [CW-1:0]                tr_st_wr,
  input  logic [CW-1:0][63:0]          tr_st_va,
  input  logic [CW-1:0][63:0]          tr_st_data,
  input  logic [CW-1:0][1:0]           tr_st_size,
  output lqid_t [CW-1:0]               tr_lq,        // ... and committed loads' (interfaces.md v1.5, mem_ld)
  input  logic [CW-1:0][63:0]          tr_ld_va,
  input  logic [CW-1:0][1:0]           tr_ld_size,
  // Trace register reads
  output preg_t [CW-1:0]               tr_tag,
  input  logic [CW-1:0][63:0]          tr_data,
  // CSR file
  output logic                         cm_csr,
  output logic [NCW-1:0]               cm_n,
  output logic                         tr_valid,
  output logic                         tr_irq,
  output logic [5:0]                   tr_code,
  output logic [63:0]                  tr_epc,
  output logic [63:0]                  tr_tval,
  output logic                         mret,
  output logic                         sret,
  output logic                         sfence,       // SFENCE.VMA retires: flush the TLBs
  input  logic [63:0]                  trap_target,  // an exception's target
  input  logic [63:0]                  irq_target,   // an interrupt's
  output logic                         xret_v,       // an MRET or SRET is in flight (registered) ...
  output logic                         xret_s,       // ... and it is SRET: tg_csr reads its xepc
  input  logic [63:0]                  xepc,
  input  priv_e                        priv,
  input  logic                         irq_take,     // the head thread's (t_cm: tg_csr reads hd_tid_o)
  input  logic [5:0]                   irq_code,
  input  logic                         wfi_wake,
  input  logic [NUM_THREADS-1:0]       wfi_wake_h,   // each hart's (with hart 1: a parked WFI's turns)
  input  logic                         csr_hold,     // with hart 1: a trap's cold-CSR writes run (tg_csr), no commit
  // Flush and redirect (registered)
  output logic                         flush,
  output tid_t                         flush_tid,
  output logic [63:0]                  flush_pc,
  output logic                         icinv,
  // Commit trace
  output tr_rec_t [CW-1:0]             trace_o,
  output logic [CW-1:0]                trace_valid_o,
  // Step 6 (D2, threading.md), with hart 1: a thread that waits in WFI while its sibling runs goes to sleep
  input  md_t                          md_i,          // the mode (tg_rename)
  input  md_t                          mdn_i,         // ... next cycle's
  input  logic                         mrs_i,         // the split moves md_i.run's empty window to its half's start
  input  logic [NUM_THREADS-1:0]       wk_i,          // each sleeping thread wakes
  input  logic                         sph_i,         // a wake waits for the split: md_i.run's WFI retires
  input  logic                         h1off_i,       // mtgsmt.HART1_OFF (tg_csr): hart 1 does not wake
  output logic                         flush_slp,     // the flush follows a WFI gone to sleep (registered, with flush)
  output logic [NUM_THREADS-1:0]       slp_o,         // each thread asleep
  output logic [NUM_THREADS-1:0]       wkr_o          // ... and asking to wake
);
  if (NB < DISPATCH_WIDTH || NB < CW || (ROB_ENTRIES % NB) != 0) begin : g_bad
    $error("tg_rob: ROB_BANKS must cover the widths and divide ROB_ENTRIES");
  end
  if (SPLIT && (NUM_THREADS != 2 || (ROB_ENTRIES / 2) % NB != 0)) begin : g_bad_split
    $error("tg_rob: the split mode needs two threads and halves of whole bank rows");
  end

  localparam int NT = NUM_THREADS;
  md_t md, mdn;                     // the mode and next cycle's (step 6; constants without hart 1)
  assign md  = HART1_ON ? md_i : MD_C;
  assign mdn = HART1_ON ? mdn_i : MD_C;
  localparam bit MT = HART1_ON && NT > 1;      // hart 1 runs (M7's step 5c): interrupts at either thread's head
  // The threads: the dispatch group's (its slot 0's tid), the committing one (the running thread until the split
  // mode) and the flushed one; without SMT thread 0, whatever the tid bits hold
  tid_t t_ds, t_cm, t_fl;
  tid_t ct_q, ct_n;                  // split mode: the commit thread, chosen a cycle ahead
  assign t_ds = (NT > 1) ? ds_uop[0].tid : tid_t'(0);
  assign t_cm = (SPLIT && NT > 1) ? ct_q : RUN_TID;
  assign t_fl = (NT > 1) ? flush_tid : tid_t'(0);
  // A report (completion, exception, mispredict, MMIO, replay) in a flush's cycle is dropped when its entry is the
  // flushed thread's: every report while one thread runs; with hart 1 (MT) the other thread's reports stand
  function automatic logic rdrop(input robid_t e, input logic fl, input tid_t ft);
    return fl && (!MT || rob_tid(e, md) == ft);
  endfunction
  robid_t [NT-1:0] head_q, tail_q;
  assign head_o   = head_q;
  assign hd_tid_o = t_cm;
  logic [NT-1:0]          xr_v_q, xr_s_q;  // an MRET or SRET in flight; SRET

  logic   [NT-1:0]        exr_v_q;
  robid_t [NT-1:0]        exr_rob_q;
  logic   [NT-1:0][3:0]   exr_cause_q;
  logic   [NT-1:0][63:0]  exr_tval_q;
  logic   [NT-1:0]        exr_mem_q;      // an LSU exception: tval is the head's VA (hd_lva / hd_sva)
  logic   [NT-1:0]        mpr_v_q;
  robid_t [NT-1:0]        mpr_rob_q;
  logic   [NT-1:0][63:0]  mpr_npc_q;

  // ---- Payload LUTRAM ----
  function automatic int bank_of(input logic [RIW-1:0] i);
    return int'(i) % NB;
  endfunction
  function automatic int row_of(input logic [RIW-1:0] i);
    return int'(i) / NB;
  endfunction
  rob_pl_t [DISPATCH_WIDTH-1:0] dpl;
  logic [DISPATCH_WIDTH-1:0]    fp_cmp_d, fp_exc_d, fp_misp_d, fp_mmio_d;   // flag parities at dispatch
  for (genvar k = 0; k < DISPATCH_WIDTH; k++) begin : g_dpl
    always_comb begin
      dpl[k]            = '0;
      dpl[k].pc         = ds_uop[k].pc;
      dpl[k].insn       = ds_uop[k].insn;
      dpl[k].rvc        = ds_uop[k].rvc;
      dpl[k].tid        = ds_uop[k].tid;
      dpl[k].rd_en      = ds_uop[k].d.rd_en;
      dpl[k].rd         = ds_uop[k].d.rd;
      dpl[k].rd_fp      = EXT_FD && ds_uop[k].d.rd_fp;
      dpl[k].is_fp      = EXT_FD && ds_uop[k].d.cls == C_FP;
      dpl[k].dst        = ds_ren[k].dst;
      dpl[k].old        = ds_ren[k].old;
      dpl[k].is_ld      = ds_uop[k].d.cls == C_LD;
      dpl[k].is_st      = ds_uop[k].d.cls == C_ST;
      dpl[k].is_br      = ds_uop[k].d.cls == C_BR;
      dpl[k].is_csr     = ds_uop[k].d.cls == C_CSR;
      dpl[k].sys        = ds_uop[k].d.sys;
      dpl[k].serial     = ds_uop[k].d.serial;
      dpl[k].dexc       = ds_uop[k].d.exc;
      dpl[k].dexc_cause = ds_uop[k].d.exc_cause;
      dpl[k].dexc_hi    = ds_uop[k].d.exc_hi;
      dpl[k].lq         = ds_ren[k].lq;
      dpl[k].sq         = ds_ren[k].sq;
      {dpl[k].ras_push, dpl[k].ras_pop} = ras_op(ds_uop[k].d);
      // TAGE trains on the conditional branches its blocks predict (a straddler with the block its
      // last parcel is in, at slot 0), not one with a decode exception
      dpl[k].cbr        = TAGE_ON && ds_uop[k].d.cls == C_BR && ds_uop[k].d.br_kind == BR_COND && !ds_uop[k].d.exc;
      dpl[k].ptk        = ds_uop[k].ptk;
      dpl[k].ftq        = ds_uop[k].ftq;
      dpl[k].f_cmp      = fp_cmp_d[k] ^ !ds_ren[k].has_q;   // complete at once without a queue
      dpl[k].f_exc      = fp_exc_d[k] ^ ds_uop[k].d.exc;
      dpl[k].f_misp     = fp_misp_d[k];
      dpl[k].f_mmio     = fp_mmio_d[k];
    end
  end
  logic [NB-1:0]                      pw_we;
  logic [NB-1:0][idx_w(ROWS)-1:0]     pw_a;
  logic [NB-1:0][ROB_PL_W-1:0]        pw_d;
  always_comb begin
    pw_we = '0; pw_a = '0; pw_d = '0;
    for (int k = 0; k < DISPATCH_WIDTH; k++) begin
      if (ds_fire && ds_valid[k]) begin
        pw_we[bank_of(ds_ren[k].rob[RIW-1:0])] = 1'b1;
        pw_a[bank_of(ds_ren[k].rob[RIW-1:0])]  = idx_w(ROWS)'(row_of(ds_ren[k].rob[RIW-1:0]));
        pw_d[bank_of(ds_ren[k].rob[RIW-1:0])]  = dpl[k];
      end
    end
  end
  // The commit slots' entries (head + j), their banks and the banks' read rows are registered
  // with the head, chosen by the commit count from the values for each count (timing: the
  // payload, flag and FP-flag reads start at flip-flops, not at adders on the head; asserted)
  localparam int BKW = idx_w(NB);
  typedef struct packed {
    robid_t [CW-1:0]                hid;
    logic [CW-1:0][BKW-1:0]         bk;
    logic [NB-1:0][idx_w(ROWS)-1:0] pa;
  } hwin_t;
  function automatic hwin_t hwin(input robid_t h, input int k, input tid_t t, input md_t m);  // thread t's h + k
    hwin_t w;
    w = '0;
    for (int j = 0; j < CW; j++) begin
      w.hid[j] = rob_add_t(h, k + j, t, m);
      w.bk[j]  = BKW'(bank_of(w.hid[j][RIW-1:0]));
      w.pa[bank_of(w.hid[j][RIW-1:0])] = idx_w(ROWS)'(row_of(w.hid[j][RIW-1:0]));
    end
    return w;
  endfunction
  hwin_t [CW:0] hw_n;               // after committing k
  hwin_t        hw_q;
  always_comb for (int k = 0; k <= CW; k++) hw_n[k] = hwin(head_q[t_cm], k, t_cm, mdn);   // (next cycle's window)
  robid_t [CW-1:0]  hid;              // head + j
  rob_pl_t [CW-1:0] hp;
  logic [NB-1:0][idx_w(ROWS)-1:0] pr_a;
  logic [NB-1:0][ROB_PL_W-1:0]    pr_d;
  assign hid  = hw_q.hid;
  assign pr_a = hw_q.pa;
  for (genvar j = 0; j < CW; j++) begin : g_hid
    assign hp[j] = rob_pl_t'(pr_d[hw_q.bk[j]]);
  end
  for (genvar b = 0; b < NB; b++) begin : g_pl
    logic [0:0][idx_w(ROWS)-1:0] ra;
    logic [0:0][ROB_PL_W-1:0]    rd;
    assign ra[0] = pr_a[b];
    tg_ram_lut #(.DEPTH(ROWS), .WIDTH(ROB_PL_W), .NR(1)) u_pl (
      .clk, .we(pw_we[b]), .waddr(pw_a[b]), .wdata(pw_d[b]), .raddr(ra), .rdata(rd));
    assign pr_d[b] = rd[0];
  end

  // ---- FP exception flags (EXT_FD), by ROB entry, in LUTRAM ----
  // P4's F0 completions write one table and FP->int completions (bank 1) the other, so each
  // table has one write port; at commit an FP op's result file (rd_fp) says which it wrote.
  // Entries are read only once complete, and every completion writes its flags.
  logic [CW-1:0][RIW-1:0] ffr_a;
  logic [CW-1:0][4:0]     ffp_rd, ffi_rd;
  for (genvar j = 0; j < CW; j++) begin : g_ffa
    assign ffr_a[j] = hid[j][RIW-1:0];
  end
  if (EXT_FD) begin : g_ff
    tg_ram_lut #(.DEPTH(ROB_ENTRIES), .WIDTH(5), .NR(CW)) u_ffp (
      .clk, .we(fp_cmp), .waddr(fp_cmp_rob[RIW-1:0]), .wdata(fp_cmp_fflags), .raddr(ffr_a),
      .rdata(ffp_rd));
    tg_ram_lut #(.DEPTH(ROB_ENTRIES), .WIDTH(5), .NR(CW)) u_ffi (
      .clk, .we(oth_cmp), .waddr(oth_rob[RIW-1:0]), .wdata(oth_fflags), .raddr(ffr_a),
      .rdata(ffi_rd));
  end else begin : g_noff
    assign ffp_rd = '0;
    assign ffi_rd = '0;
  end

  // ---- Complete, exception, mispredict and MMIO flags (FPGA-friendly T2) ----
  // Each reporting port toggles its own one-bit LUTRAM table at the entry it reports, so every
  // table has one writer. A flag is the parity of its ports' tables XOR the bit the payload took
  // at dispatch (that parity then, XOR the flag's initial value), so dispatch writes none of the
  // tables, and their contents need no reset. This holds while every live entry gets at most
  // one report per flag per lap and none as it is dispatched (asserted); reports in a flush
  // cycle for the flushed thread's entries are dropped (rdrop), as the flip-flop flags dropped them,
  // and later ones for squashed entries come before those entries are dispatched again.
  // Read ports per table: the commit slots' entries, the dispatched entries, and its own write
  // entry (the toggle).
  localparam int NCP = N_ALU + 9;                // completion ports
  localparam int NXP = 7;                        // exception ports
  localparam int NFT = NCP + NXP + 2;            // tables: completions, exceptions, mispredict, MMIO
  localparam int NFR = CW + DISPATCH_WIDTH + 1;
  logic [NFT-1:0]          ft_v;
  robid_t [NFT-1:0]        ft_e;
  always_comb begin
    // completions: tables 0 .. NCP-1
    for (int i = 0; i < N_ALU; i++) begin
      ft_v[i] = alu_cmp[i];
      ft_e[i] = alu_rob[i];
    end
    ft_v[N_ALU]     = oth_cmp;            ft_e[N_ALU]     = oth_rob;
    ft_v[N_ALU + 1] = EXT_FD && fp_cmp;   ft_e[N_ALU + 1] = fp_cmp_rob;
    ft_v[N_ALU + 2] = ld_cmp;             ft_e[N_ALU + 2] = ld_rob;
    for (int i = 0; i < 2; i++) begin
      ft_v[N_ALU + 3 + i] = st_cmp[i];
      ft_e[N_ALU + 3 + i] = st_rob[i];
    end
    for (int i = 0; i < 4; i++) begin
      ft_v[N_ALU + 5 + i] = lx_valid[i];
      ft_e[N_ALU + 5 + i] = lx_rob[i];
      // exceptions: tables NCP .. NCP+NXP-1
      ft_v[NCP + 2 + i]   = lx_valid[i];
      ft_e[NCP + 2 + i]   = lx_rob[i];
    end
    ft_v[NCP]     = oth_cmp && oth_exc;    ft_e[NCP]     = oth_rob;
    ft_v[NCP + 1] = br_valid && br_exc;    ft_e[NCP + 1] = br_rob;
    ft_v[NCP + 6] = spx_valid;             ft_e[NCP + 6] = spx_rob;
    // mispredict and MMIO load
    ft_v[NFT - 2] = br_valid && !br_exc && br_misp;  ft_e[NFT - 2] = br_rob;
    ft_v[NFT - 1] = ld_cmp && ld_mmio;               ft_e[NFT - 1] = ld_rob;
  end
  // The store ports' completion reports write their toggle tables a cycle later, from registers,
  // and the commit slots' reads add the pending toggle in that cycle, so every flag reads as
  // before: asserted against the shadow flags below, which take the reports when they come (timing,
  // DR-148 fn12: in G7 the STA's PMP check -> sa_exc -> st_cmp -> those tables' WE was -0.76 ns at
  // 21 levels, 70% wire). A flush in the write's cycle keeps it, since the report came before it.
  // The dispatched entries' reads need no correction: a reported entry is live, so it is never
  // being dispatched in the write's cycle (asserted)
  localparam int SCT = N_ALU + 3;                // the store ports' completion tables: SCT, SCT + 1
  logic [1:0]       sp_v_q;
  robid_t [1:0]     sp_e_q;
  always_ff @(posedge clk) begin
    for (int i = 0; i < 2; i++) begin
      sp_v_q[i] <= st_cmp[i] && !rdrop(st_rob[i], flush, t_fl) && !rst;
      sp_e_q[i] <= st_rob[i];
    end
  end
  logic [NFT-1:0]   fw_v;                        // the tables' writes: the reports, the store ports' late
  robid_t [NFT-1:0] fw_e;
  always_comb begin
    for (int t = 0; t < NFT; t++) begin
      fw_v[t] = ft_v[t] && !rdrop(ft_e[t], flush, t_fl) && !rst;
      fw_e[t] = ft_e[t];
    end
    for (int i = 0; i < 2; i++) begin
      fw_v[SCT + i] = sp_v_q[i] && !rst;
      fw_e[SCT + i] = sp_e_q[i];
    end
  end
  logic [NFT-1:0][NFR-1:0] ft_rd;
  // (MT, step 5d) one more read port, at the other thread's head (oh, below), for the commit turn; synthesis keeps it
  // on the completion and MMIO tables only
  localparam int NFRX = NFR + (MT ? 1 : 0);
  robid_t         oh;               // the other thread's head entry
  logic [NFT-1:0] ft_ro;            // each table there
  if (MT) begin : g_oh
    assign oh = head_q[~t_cm];
  end else begin : g_noh
    assign oh = head_q[t_cm];
  end
  for (genvar t = 0; t < NFT; t++) begin : g_ft
    logic [NFRX-1:0][RIW-1:0] ra;
    logic [NFRX-1:0]          rd;
    for (genvar j = 0; j < CW; j++) begin : g_rh
      assign ra[j] = hid[j][RIW-1:0];
    end
    for (genvar k = 0; k < DISPATCH_WIDTH; k++) begin : g_rd
      assign ra[CW + k] = ds_ren[k].rob[RIW-1:0];
    end
    assign ra[NFR-1] = fw_e[t][RIW-1:0];
    if (MT) begin : g_ro
      assign ra[NFRX-1] = oh[RIW-1:0];
      assign ft_ro[t]   = rd[NFRX-1];
    end else begin : g_nro
      assign ft_ro[t]   = 1'b0;
    end
    tg_ram_lut #(.DEPTH(ROB_ENTRIES), .WIDTH(1), .NR(NFRX)) u_ft (
      .clk, .we(fw_v[t]), .waddr(fw_e[t][RIW-1:0]), .wdata(!ft_rd[t][NFR-1]),
      .raddr(ra), .rdata(rd));
    assign ft_rd[t] = rd[NFR-1:0];
  end
  // The completion and exception parities at each read port
  logic [NFR-1:0] par_c, par_x;
  always_comb begin
    for (int p = 0; p < NFR; p++) begin
      par_c[p] = 1'b0;
      par_x[p] = 1'b0;
      for (int t = 0; t < NCP; t++)         par_c[p] ^= ft_rd[t][p];
      for (int t = NCP; t < NCP + NXP; t++) par_x[p] ^= ft_rd[t][p];
    end
    // the commit slots: the store tables' pending toggles (above)
    for (int j = 0; j < CW; j++)
      for (int i = 0; i < 2; i++)
        par_c[j] ^= sp_v_q[i] && sp_e_q[i][RIW-1:0] == hid[j][RIW-1:0];
  end
  logic [CW-1:0] cmp_h, exc_h, misp_h, mmio_h;   // the flags of the commit slots' entries
  for (genvar j = 0; j < CW; j++) begin : g_fh
    assign cmp_h[j]  = par_c[j] ^ hp[j].f_cmp;
    assign exc_h[j]  = par_x[j] ^ hp[j].f_exc;
    assign misp_h[j] = ft_rd[NFT-2][j] ^ hp[j].f_misp;
    assign mmio_h[j] = ft_rd[NFT-1][j] ^ hp[j].f_mmio;
  end
  for (genvar k = 0; k < DISPATCH_WIDTH; k++) begin : g_fd
    assign fp_cmp_d[k]  = par_c[CW + k];
    assign fp_exc_d[k]  = par_x[CW + k];
    assign fp_misp_d[k] = ft_rd[NFT-2][CW + k];
    assign fp_mmio_d[k] = ft_rd[NFT-1][CW + k];
  end

  // ---- Replay flag: XOR-banked LUTRAM (FPGA-friendly T2) ----
  // Cleared at dispatch; set by the LSU's replay report and its two TLB-miss reports, possibly
  // more than once a lap (so not a toggle table). One table per writer, and the flag is the XOR
  // of the tables: a writer stores its value XOR the other tables at its entry, read in the same
  // cycle. Two writers at one entry in a cycle would cancel; none do (asserted): a setter's entry
  // is live, so never one being dispatched; a TLB miss is a new access at AG, never a load the
  // ordering search finds (it has a value); the LD and STA ports carry different instructions.
  localparam int NRW = DISPATCH_WIDTH + 3;       // dispatch slots, then replay, TLB miss LD, STA
  localparam int NRR = NRW - 1 + CW;             // read ports: the other writers', then the head's
  logic [NRW-1:0]           rw_v;
  logic [NRW-1:0][RIW-1:0]  rw_a;
  logic [NRW-1:0]           rw_d;
  logic [NRW-1:0][NRR-1:0]  rw_rd;
  always_comb begin
    rw_v[DISPATCH_WIDTH +: 3] = {tlbm_valid[1], tlbm_valid[0], replay_valid};
    rw_a[DISPATCH_WIDTH +: 3] = {tlbm_rob[1][RIW-1:0], tlbm_rob[0][RIW-1:0], replay_rob[RIW-1:0]};
    rw_d[DISPATCH_WIDTH +: 3] = '1;
    for (int k = 0; k < DISPATCH_WIDTH; k++) begin
      rw_v[k] = ds_fire && ds_valid[k];
      rw_a[k] = ds_ren[k].rob[RIW-1:0];
      rw_d[k] = 1'b0;
    end
  end
  localparam int NRRX = NRR + (MT ? 1 : 0);
  logic [NRW-1:0] rw_ro;            // (MT) each table at the other thread's head
  for (genvar b = 0; b < NRW; b++) begin : g_rw
    logic [NRRX-1:0][RIW-1:0] ra;
    logic [NRRX-1:0]          rd;
    for (genvar p = 0; p < NRW - 1; p++) begin : g_ro
      assign ra[p] = rw_a[(p < b) ? p : p + 1];
    end
    for (genvar j = 0; j < CW; j++) begin : g_rh
      assign ra[NRW - 1 + j] = hid[j][RIW-1:0];
    end
    if (MT) begin : g_oh
      assign ra[NRRX-1] = oh[RIW-1:0];
      assign rw_ro[b]   = rd[NRRX-1];
    end else begin : g_noh
      assign rw_ro[b]   = 1'b0;
    end
    logic wd;
    always_comb begin
      wd = rw_d[b];
      for (int w = 0; w < NRW; w++) if (w != b) wd ^= rw_rd[w][(b < w) ? b : b - 1];
    end
    tg_ram_lut #(.DEPTH(ROB_ENTRIES), .WIDTH(1), .NR(NRRX)) u_rw (
      .clk, .we(rw_v[b] && !rdrop(robid_t'(rw_a[b]), flush, t_fl) && !rst), .waddr(rw_a[b]), .wdata(wd), .raddr(ra),
      .rdata(rd));
    assign rw_rd[b] = rd[NRR-1:0];
  end
  logic [CW-1:0] rpl_h;                          // the flag of each commit slot's entry
  always_comb begin
    for (int j = 0; j < CW; j++) begin
      rpl_h[j] = 1'b0;
      for (int b = 0; b < NRW; b++) rpl_h[j] ^= rw_rd[b][NRW - 1 + j];
    end
  end

  // (MT, step 5d) the other thread's head entry is actionable: complete, marked for a replay (or a TLB miss), or an MMIO
  // load waiting to issue at the head. Its flags as the commit slots' (the tables' extra port above, the store
  // tables' pending toggles, and its dispatch parities from a two-bit copy of the payload's, per bank)
  logic o_act;
  if (MT) begin : g_oact
    logic [NB-1:0][1:0] po_rd;      // {f_cmp, f_mmio} at the other head's row, per bank
    for (genvar b = 0; b < NB; b++) begin : g_po
      logic [0:0][idx_w(ROWS)-1:0] ra;
      logic [0:0][1:0]             rd;
      rob_pl_t                     w;
      assign w     = rob_pl_t'(pw_d[b]);
      assign ra[0] = idx_w(ROWS)'(row_of(oh[RIW-1:0]));
      tg_ram_lut #(.DEPTH(ROWS), .WIDTH(2), .NR(1)) u_po (
        .clk, .we(pw_we[b]), .waddr(pw_a[b]), .wdata({w.f_cmp, w.f_mmio}), .raddr(ra), .rdata(rd));
      assign po_rd[b] = rd[0];
      logic unused_w;               // (the payload's other fields)
      assign unused_w = ^w;
    end
    logic unused_oh;                // (the index's thread bit: the tables are read by entry)
    assign unused_oh = oh[ROBW-1];
    logic o_cmp, o_mmio, o_rpl;
    always_comb begin
      o_cmp = po_rd[bank_of(oh[RIW-1:0])][1];
      for (int t = 0; t < NCP; t++) o_cmp ^= ft_ro[t];
      for (int i = 0; i < 2; i++) o_cmp ^= sp_v_q[i] && sp_e_q[i][RIW-1:0] == oh[RIW-1:0];
      o_mmio = po_rd[bank_of(oh[RIW-1:0])][0] ^ ft_ro[NFT-1];
      o_rpl  = ^rw_ro;
      o_act  = o_cmp || o_rpl || o_mmio;
    end
  end else begin : g_noact
    assign o_act = 1'b0;
    logic unused_ro;
    assign unused_ro = ^{ft_ro, rw_ro, oh};
  end

  // ---- Commit decision ----
  int cnt;
  assign cnt = rob_cnt_t(tail_q[t_cm], head_q[t_cm], md);
  logic [CW-1:0] ret;               // retiring slots
  logic          do_flush, do_trap, do_irq, do_icinv, do_csr, do_mret, do_sret, do_sfence, use_tt, tlbx;
  logic [63:0]   nf_pc;
  logic [3:0]    t_cause;
  logic [63:0]   t_tval;
  logic          stop;
  logic          pushed;            // a return-address-stack push retires in the group (one per cycle)
  logic [CW-1:0] mf;                // the slot whose mispredict ends the group
  // Commit holds (cmh_*): a store whose PMP check comes after it completed retires only once a
  // denial would show, and a load whose ordering replay mark is a cycle late does not retire before
  // it; the group stops at the held entry. hold_le[j]: slot j or an older one is held.
  logic [CW-1:0] hold_le;
  always_comb begin
    logic any;
    any = 1'b0;
    for (int j = 0; j < CW; j++) begin
      for (int h = 0; h < 3; h++) if (cmh_v[h] && cmh_rob[h] == hid[j]) any = 1'b1;
      hold_le[j] = any;
    end
  end
  // WFI retires when a locally enabled interrupt is pending, or after WFI_MAX cycles (the ISA
  // lets WFI complete at any time; Spike treats it as a no-op), so it never hangs the hart.
  localparam int WFI_MAX = 4096;
  // Step 6 (D2), with hart 1: a WFI that has waited SLP_WAIT cycles while the sibling is awake retires and its thread
  // sleeps (slp_q): its flush keeps it blocked at rename, and its half can go to the sibling (tg_rename merges them).
  // It wakes on a locally enabled interrupt (its next instruction takes it), after SLP_MAX cycles asleep (WFI may
  // complete at any time), or, while merged, once the halves split. mtgsmt.HART1_OFF keeps hart 1 asleep.
  localparam int SLP_WAIT = 64;
  localparam int SLP_MAX  = HART1_ON ? 65536 : WFI_MAX;
  logic [NT-1:0][idx_w(SLP_MAX + 1)-1:0] wfi_cnt_q;   // a WFI's wait at the head, then a sleeping thread's
  logic [NT-1:0] slp_q, slp_rdy;
  logic          slp_now, sl_ret;
  always_comb
    for (int t = 0; t < NT; t++)       // thread t's WFI may go to sleep (the sibling awake, no merge or split moving)
      slp_rdy[t] = HART1_ON && NT > 1 && int'(wfi_cnt_q[t]) >= SLP_WAIT && !slp_q[NT - 1 - t] && md.split &&
                   mdn.split && !sph_i;
  // With hart 1 a thread whose head is a WFI still waiting at its last turn (wfp_q) takes no commit turns while no
  // interrupt is pending for it (registered: wkh_q) and its count runs, which then runs every cycle; without it
  // the turns alternate as before
  logic [NT-1:0] wfp_q, wkh_q;
  logic go;
  always_comb begin
    slp_now = slp_rdy[t_cm] && !wfi_wake;
    unique case (hp[0].sys)
      SYS_FENCE, SYS_FENCEI, SYS_SFENCE: go = sq_drained;    // later walks see the stores
      SYS_WFI:               go = wfi_wake || int'(wfi_cnt_q[t_cm]) == WFI_MAX || slp_now || (HART1_ON && sph_i);
      default:               go = !(hp[0].is_csr && hp[0].insn[31:20] == 12'h180) || sq_drained;  // satp
    endcase
  end
  always_ff @(posedge clk) begin
    if (rst) wfi_cnt_q <= '0;
    else if (flush) wfi_cnt_q[t_fl] <= '0;
    else if (HART1_ON && slp_q[t_cm]) ;                      // (a sleeper's count runs below)
    else if (cnt == 0 || hp[0].sys != SYS_WFI) wfi_cnt_q[t_cm] <= '0;
    else if (int'(wfi_cnt_q[t_cm]) != WFI_MAX) wfi_cnt_q[t_cm] <= wfi_cnt_q[t_cm] + 1'b1;
    if (MT && !rst)
      for (int t = 0; t < NT; t++) begin
        if (tid_t'(t) != t_cm && wfp_q[t] && !(flush && t_fl == tid_t'(t)) && int'(wfi_cnt_q[t]) != WFI_MAX)
          wfi_cnt_q[t] <= wfi_cnt_q[t] + 1'b1;
        if (HART1_ON && slp_q[t] && int'(wfi_cnt_q[t]) != SLP_MAX) wfi_cnt_q[t] <= wfi_cnt_q[t] + 1'b1;
        if (HART1_ON && wk_i[t]) wfi_cnt_q[t] <= '0;
      end
    wkh_q <= MT ? wfi_wake_h : '0;
    if (rst || !MT) wfp_q <= '0;
    else begin
      if (!flush) wfp_q[t_cm] <= cnt > 0 && hp[0].sys == SYS_WFI && !ret[0];
      if (flush) wfp_q[t_fl] <= 1'b0;
    end
    if (rst || !HART1_ON) slp_q <= '0;
    else begin
      if (sl_ret) slp_q[t_cm] <= 1'b1;
      for (int t = 0; t < NT; t++) if (wk_i[t]) slp_q[t] <= 1'b0;
    end
  end
  // a sleeping thread asks to wake: a locally enabled interrupt, or SLP_MAX cycles; hart 1 not while it is held off.
  // (Simulation only, +xwake=N) it also asks with probability N per mille a cycle (WFI may complete at any time), so
  // step 6's merges and splits come at random points; without it no random number is drawn, so other random streams
  // stay as they are
  logic [NT-1:0] xw_q;
`ifndef SYNTHESIS
  int unsigned xw_pm;
  initial if (!$value$plusargs("xwake=%d", xw_pm)) xw_pm = 0;
  always_ff @(posedge clk)
    if (xw_pm != 0) for (int t = 0; t < NT; t++) xw_q[t] <= !rst && ($urandom % 1000) < xw_pm;
    else xw_q <= '0;
`else
  assign xw_q = '0;
`endif
  always_comb
    for (int t = 0; t < NT; t++)
      wkr_o[t] = HART1_ON && slp_q[t] && (wkh_q[t] || int'(wfi_cnt_q[t]) == SLP_MAX || xw_q[t]) &&
                 !(h1off_i && tid_t'(t) == ~RUN_TID);
  assign slp_o = slp_q;
  // One adder on the head's PC: a serial instruction's next PC (+2 or +4), or a fetch fault's
  // tval (+2 when only the second half of a 32-bit instruction faults). The second is a decode
  // exception, which traps, so one instruction never needs both.
  logic [63:0] hd_pc_inc;
  assign hd_pc_inc = hp[0].pc + (hp[0].dexc ? {62'b0, hp[0].dexc_hi, 1'b0} : (hp[0].rvc ? 64'd2 : 64'd4));
  always_comb begin
    ret = '0;
    do_flush = 1'b0; do_trap = 1'b0; do_irq = 1'b0; do_icinv = 1'b0; do_csr = 1'b0; do_mret = 1'b0;
    do_sret = 1'b0; do_sfence = 1'b0;
    sl_ret = 1'b0;
    use_tt = 1'b0;
    tlbx = 1'b0;
    nf_pc = '0;
    t_cause = '0;
    t_tval = '0;
    stop = 1'b0;
    pushed = 1'b0;
    mf = '0;
    if (!flush && ready && !(MT && csr_hold) && cnt > 0) begin
      if (irq_take && (MT || t_cm == RUN_TID) && hp[0].sys != SYS_WFI && !mmio_busy) begin   // (t_cm's)
        do_irq = 1'b1;
        do_flush = 1'b1;
        use_tt = 1'b1;
      end else if (rpl_h[0]) begin
        // The refetch PC, cause and tval don't wait for the head's TLB check (hd_retry, the
        // LSU's DTLB lookup this cycle): they count only if it flushes or traps
        nf_pc   = hp[0].pc;
        t_cause = hd_cause;
        t_tval  = hp[0].is_ld ? hd_lva : hd_sva;
        if (!hd_tlb || hd_retry) begin
          do_flush = 1'b1;
        end else if (hd_fault) begin
          do_trap  = 1'b1;
          do_flush = 1'b1;
          use_tt   = 1'b1;
          tlbx     = 1'b1;
        end
      end else if (cmp_h[0] && exc_h[0]) begin
        do_trap = 1'b1;
        do_flush = 1'b1;
        use_tt = 1'b1;
        if (hp[0].dexc) begin
          t_cause = hp[0].dexc_cause;
          unique case (hp[0].dexc_cause)
            EXC_ILLEGAL: t_tval = {32'b0, hp[0].insn};
            EXC_BREAK: t_tval = hp[0].pc;
            EXC_IACCESS, EXC_IPAGE: t_tval = hd_pc_inc;
            default: t_tval = '0;
          endcase
        end else begin
          t_cause = exr_cause_q[t_cm];
          t_tval  = exr_mem_q[t_cm] ? (hp[0].is_ld ? hd_lva : hd_sva) : exr_tval_q[t_cm];
        end
      end else if (cmp_h[0] && hp[0].serial) begin
        if (go) begin
          ret[0]   = 1'b1;
          do_flush = 1'b1;
          do_icinv = hp[0].sys == SYS_FENCEI;
          do_csr   = hp[0].is_csr;
          do_mret  = hp[0].sys == SYS_MRET;
          do_sret  = hp[0].sys == SYS_SRET;
          do_sfence = hp[0].sys == SYS_SFENCE;
          nf_pc    = (do_mret || do_sret) ? xepc : hd_pc_inc;
          sl_ret   = hp[0].sys == SYS_WFI && slp_now;
        end
      end else begin
        stop = 1'b0;
        pushed = 1'b0;
        for (int j = 0; j < CW; j++) begin
          if (!stop) begin
            if (j < cnt && cmp_h[j] && !exc_h[j] && !hp[j].serial && !rpl_h[j] && !(pushed && hp[j].ras_push)) begin
              ret[j] = 1'b1;
              if (hp[j].ras_push) pushed = 1'b1;
              if (misp_h[j]) begin
                mf[j] = 1'b1;
                stop = 1'b1;
              end
            end else begin
              stop = 1'b1;
            end
          end
        end
        // The holds cut the group last (timing: the LSU's S2 verdict arrives late)
        ret      = ret & ~hold_le;
        do_flush = |(mf & ~hold_le);
        nf_pc    = mpr_npc_q[t_cm];                 // (read only with do_flush)
      end
    end
  end

  // ---- Outputs to rename, LSU, CSR ----
  always_comb begin
    int nl, ns, n;
    nl = 0; ns = 0; n = 0;
    for (int j = 0; j < CW; j++) begin
      cm_valid[j] = ret[j];
      cm_rd_en[j] = ret[j] && hp[j].rd_en;
      cm_rd_fp[j] = hp[j].rd_fp;
      cm_fflags[j] = (EXT_FD && hp[j].is_fp) ? (hp[j].rd_fp ? ffp_rd[j] : ffi_rd[j]) : '0;
      cm_tid[j]   = hp[j].tid;
      cm_rd[j]    = hp[j].rd;
      cm_dst[j]   = hp[j].dst;
      cm_old[j]   = hp[j].old;
      cm_ras_push[j] = ret[j] && hp[j].ras_push;
      cm_ras_pop[j]  = ret[j] && hp[j].ras_pop;
      cm_ras_link[j] = hp[j].pc[38:1] + (hp[j].rvc ? 38'd1 : 38'd2);
      // a conditional branch's mispredict is its direction (its taken target is checked at decode)
      cm_cbr[j]      = ret[j] && hp[j].cbr;
      cm_ctaken[j]   = hp[j].ptk ^ misp_h[j];
      cm_cpred[j]    = hp[j].ptk;
      cm_cftq[j]     = hp[j].ftq;
      cm_cslot[j]    = hp[j].pc[SLOT_W:1] + SLOT_W'(!hp[j].rvc);
      tr_sq[j]    = COMMIT_TRACE ? hp[j].sq : '0;       // the trace's reads (DR-146: none without it)
      tr_lq[j]    = COMMIT_TRACE ? hp[j].lq : '0;
      tr_tag[j]   = COMMIT_TRACE ? hp[j].dst : '0;
      if (ret[j]) begin
        n++;
        if (hp[j].is_ld) nl++;
        if (hp[j].is_st) ns++;
      end
    end
    cm_nld = NCW'(nl);
    cm_nst = NCW'(ns);
    cm_n   = NCW'(n);
    cm_hv   = ret[0];
    cm_hftq = hp[0].ftq;
    for (int j = 1; j < CW; j++) if (ret[j]) cm_hftq = hp[j].ftq;
  end
  assign cm_csr   = do_csr;
  assign mret     = do_mret;
  assign sret     = do_sret;
  assign sfence   = do_sfence;
  assign tr_valid = do_trap || do_irq;
  assign tr_irq   = do_irq;
  assign tr_code  = do_irq ? irq_code : {2'b0, t_cause};
  assign tr_epc   = hp[0].pc;
  assign tr_tval  = t_tval;

  // ---- Trace records ----
  // An atomic that reads memory: LR or an AMO, not SC (the A extension's opcode; funct5 3 is SC)
  function automatic logic amo_reads(input logic [6:0] opcode, input logic [4:0] funct5);
    return opcode == 7'b0101111 && funct5 != 5'b00011;
  endfunction
  // The hart: the core's first plus the thread (SOLO_TID's thread, tid 1, is hart 0, as mhartid)
  localparam hart_t HART0 = hart_t'(CORE_ID * NUM_THREADS);
  tr_rec_t [CW-1:0] rec;
  always_comb begin
    for (int j = 0; j < CW; j++) begin
      rec[j] = '0;
      rec[j].hart = HART0 + ((TID_W > 0) ? hart_t'(tid_t'(hp[j].tid ^ RUN_TID)) : hart_t'(0));
      rec[j].priv = priv;
      rec[j].pc   = hp[j].pc;
      rec[j].insn = hp[j].insn;
      rec[j].rvc  = hp[j].rvc;
      if (j == 0 && do_irq) begin
        rec[j].kind  = TR_IRQ;
        rec[j].insn  = '0;
        rec[j].rvc   = 1'b0;
        rec[j].cause = {1'b1, 57'b0, irq_code};
      end else if (j == 0 && do_trap) begin
        rec[j].kind  = TR_TRAP;
        rec[j].cause = {60'b0, t_cause};
        rec[j].tval  = t_tval;
      end else begin
        rec[j].kind     = TR_RETIRE;
        rec[j].rd_we    = hp[j].rd_en;
        rec[j].rd_fp    = hp[j].rd_fp;
        rec[j].rd       = hp[j].rd;
        rec[j].rd_value = hp[j].rd_en ? tr_data[j] : '0;
        rec[j].mem_st   = hp[j].is_st && tr_st_wr[j];     // not LR or a failed SC
        // v1.5: a read of memory (interfaces.md §5, Reads): a load (its LQ entry's address and size), LR or an AMO
        // (its SQ entry's, which an AMO's write shares); never SC
        rec[j].mem_ld   = hp[j].is_ld || (hp[j].is_st && amo_reads(hp[j].insn[6:0], hp[j].insn[31:27]));
        if (hp[j].is_ld) begin
          rec[j].mem_vaddr = tr_ld_va[j];
          rec[j].mem_size  = tr_ld_size[j];
        end else if (rec[j].mem_st || rec[j].mem_ld) begin
          rec[j].mem_vaddr = tr_st_va[j];
          rec[j].mem_size  = tr_st_size[j];
        end
        if (rec[j].mem_st) begin
          unique case (tr_st_size[j])
            2'd0: rec[j].mem_wdata = {56'b0, tr_st_data[j][7:0]};
            2'd1: rec[j].mem_wdata = {48'b0, tr_st_data[j][15:0]};
            2'd2: rec[j].mem_wdata = {32'b0, tr_st_data[j][31:0]};
            default: rec[j].mem_wdata = tr_st_data[j];
          endcase
        end
        rec[j].mmio_ld = hp[j].is_ld && mmio_h[j];
        rec[j].nondet  = hp[j].is_csr && hp[j].rd_en && csr_nondet(hp[j].insn[31:20]);
      end
    end
  end

  // Oldest exception after this cycle's reports. Candidates, in priority order: the register,
  // CSR (oth), branch, then the LSU's four ports and its store PMP port. The oldest valid one wins, the first in that
  // order on a tie. Computed in parallel rather than as a chain: every pair's age compare uses
  // only ROB indices, which arrive early (the LSU's AG ports send their payload's index whether
  // or not they fault), and the late valid bits only gate a one-hot select. tval: an LSU winner
  // takes the head's VA at the trap (ex_m), so ex_t is the best of the first three alone, as
  // the chain left it.
  localparam int NEX = 8;
  logic   [NT-1:0]        ex_v;
  robid_t [NT-1:0]        ex_r;
  logic   [NT-1:0][3:0]   ex_c;
  logic   [NT-1:0][63:0]  ex_t;
  logic   [NT-1:0]        ex_m;
  // Each thread's select takes its register and the reports whose entries are its (rob_tid)
  for (genvar t = 0; t < NT; t++) begin : g_ex
    logic [NEX-1:0]             xc_v, xc_win;
    robid_t [NEX-1:0]           xc_r;
    logic [NEX-1:0][3:0]        xc_c;
    logic [NEX-1:0][NEX-1:0]    xc_o;     // xc_o[i][j]: candidate i is strictly older than j
    always_comb begin
      xc_v = {spx_valid, lx_valid, br_valid && br_exc, oth_cmp && oth_exc, exr_v_q[t]};
      xc_r = {spx_rob, lx_rob, br_rob, oth_rob, exr_rob_q[t]};
      xc_c = {4'(EXC_SACCESS), lx_cause, 4'(EXC_IMISALIGN), 4'(EXC_ILLEGAL), exr_cause_q[t]};
      for (int i = 1; i < NEX; i++) if (rob_tid(xc_r[i], md) != tid_t'(t)) xc_v[i] = 1'b0;
      for (int i = 0; i < NEX; i++)
        for (int j = 0; j < NEX; j++) xc_o[i][j] = rob_older(xc_r[i], xc_r[j]);
      for (int i = 0; i < NEX; i++) begin
        xc_win[i] = xc_v[i];
        for (int j = 0; j < NEX; j++) begin
          if (j < i && xc_v[j] && !xc_o[i][j]) xc_win[i] = 1'b0;    // an earlier one as old
          if (j > i && xc_v[j] && xc_o[j][i])  xc_win[i] = 1'b0;    // a later one older
        end
      end
      ex_v[t] = |xc_v;
      ex_r[t] = '0;
      ex_c[t] = '0;
      for (int i = 0; i < NEX; i++) begin
        ex_r[t] |= {$bits(robid_t){xc_win[i]}} & xc_r[i];
        ex_c[t] |= {4{xc_win[i]}} & xc_c[i];
      end
      ex_m[t] = |xc_win[NEX-1:3] || (xc_win[0] && exr_mem_q[t]);
      // tval of the best of the register, CSR and branch candidates
      ex_t[t] = exr_tval_q[t];
      if (xc_v[1] && (!xc_v[0] || xc_o[1][0])) ex_t[t] = oth_tval;
      if (xc_v[2] && (!xc_v[0] || xc_o[2][0]) && (!xc_v[1] || xc_o[2][1])) ex_t[t] = br_tval;
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
      if (!rst && !flush) assert ($onehot0(xc_win)) else $error("tg_rob: more than one oldest exception");
`endif
  end

  // The commit thread (split mode), chosen a cycle ahead so the head window still comes from flip-flops: the other
  // thread whenever it has entries, so two busy threads alternate and an empty one is not served. With hart 1 (step
  // 5d) a thread keeps the turn while it commits and the other's head is not actionable, up to RUN_K turns in a row
  // (the LSU's head operations, MMIO loads, atomics and walks at the head, go only in their thread's turns): the
  // other thread's turn comes next cycle when its head is actionable, this thread committed nothing, or RUN_K
  logic o_park;                     // (MT) the other thread waits in WFI: no turn for it yet
  logic o_has;                      // ... it has entries
  localparam int RUN_K = 4;
  logic [1:0] run_q;                // (MT) this thread's turns in a row before this one, while the other waits
  always_comb begin
    ct_n = t_cm;
    o_park = MT && wfp_q[~t_cm] && !wkh_q[~t_cm] && int'(wfi_cnt_q[~t_cm]) != WFI_MAX && !slp_rdy[~t_cm];
    o_has  = 1'b0;
    if (SPLIT && NT > 1 && rob_cnt_t(tail_q[~t_cm], head_q[~t_cm], md) != 0) o_has = 1'b1;
    if (SPLIT && NT > 1 && o_has && !o_park && (!MT || o_act || !(|ret) || int'(run_q) == RUN_K - 1)) ct_n = ~t_cm;
  end
  always_ff @(posedge clk)
    if (rst || !MT || ct_n != t_cm || !o_has || o_park) run_q <= '0;
    else if (int'(run_q) != RUN_K - 1) run_q <= run_q + 1'b1;

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    // Trace leaves one cycle after commit
    trace_o <= COMMIT_TRACE ? rec : '0;   // without the commit trace (DR-146) the assembly is dead logic
    if (rst) begin
      trace_valid_o <= '0;
      for (int t = 0; t < NT; t++) begin
        head_q[t] <= rob_start(tid_t'(t), MD_C);
        tail_q[t] <= rob_start(tid_t'(t), MD_C);
      end
      ct_q     <= RUN_TID;
      flush    <= 1'b0;
      flush_slp <= 1'b0;
      icinv    <= 1'b0;
      exr_v_q  <= '0;
      mpr_v_q  <= '0;
      xr_v_q   <= '0;
    end else begin
      for (int j = 0; j < CW; j++) trace_valid_o[j] <= COMMIT_TRACE && (ret[j] || (j == 0 && (do_trap || do_irq)));
      flush     <= do_flush;
      flush_slp <= HART1_ON && sl_ret;
      // Every flush is the committing thread's: its head instruction's tid
      flush_tid <= hp[0].tid;
      flush_pc  <= use_tt ? (do_irq ? irq_target : trap_target) : nf_pc;
      icinv     <= do_icinv;
      head_q[t_cm] <= hw_n[cm_n].hid[0];
      ct_q      <= ct_n;

      if (flush) begin
        tail_q[t_fl]  <= head_q[t_fl];
        exr_v_q[t_fl] <= 1'b0;
        mpr_v_q[t_fl] <= 1'b0;
        xr_v_q[t_fl]  <= 1'b0;
      end else begin
        // Dispatch
        if (ds_fire) begin
          // MRET and SRET are serial: dispatched alone, with nothing after them until their
          // flush, so this holds until they commit
          xr_v_q[t_ds] <= 1'b0;
          xr_s_q[t_ds] <= 1'b0;
          for (int k = 0; k < DISPATCH_WIDTH; k++) begin
            if (ds_valid[k] && (ds_uop[k].d.sys == SYS_MRET || ds_uop[k].d.sys == SYS_SRET)) xr_v_q[t_ds] <= 1'b1;
            if (ds_valid[k] && ds_uop[k].d.sys == SYS_SRET) xr_s_q[t_ds] <= 1'b1;
          end
          tail_q[t_ds] <= rob_add_t(tail_q[t_ds], $countones(ds_valid), t_ds, md);
        end
        // Completions, exceptions, mispredicts and MMIO loads: the toggle tables; replay: the
        // XOR-banked tables (above)
      end
      // Step 6: a split with the running thread's window empty moves its pointers to its half's start
      if (HART1_ON && mrs_i) begin
        head_q[md.run] <= rob_start(md.run, mdn);
        tail_q[md.run] <= rob_start(md.run, mdn);
      end
      // Oldest exception: the current register and this cycle's reports (in a flush's cycle the other
      // thread's, with hart 1)
      for (int t = 0; t < NT; t++)
        if (!flush || (MT && t_fl != tid_t'(t))) begin
          exr_v_q[t] <= ex_v[t] && !(do_trap && t_cm == tid_t'(t));
          exr_rob_q[t] <= ex_r[t]; exr_cause_q[t] <= ex_c[t]; exr_tval_q[t] <= ex_t[t];
          exr_mem_q[t] <= ex_m[t];
        end
      // Oldest mispredict, its thread's
      if (br_valid && br_misp && !br_exc && !rdrop(br_rob, flush, t_fl) &&
          (!mpr_v_q[rob_tid(br_rob, md)] || rob_older(br_rob, mpr_rob_q[rob_tid(br_rob, md)]))) begin
        mpr_v_q[rob_tid(br_rob, md)]   <= 1'b1;
        mpr_rob_q[rob_tid(br_rob, md)] <= br_rob;
        mpr_npc_q[rob_tid(br_rob, md)] <= br_npc;
      end
    end
  end
  assign xret_v    = xr_v_q[t_cm];
  assign xret_s    = xr_s_q[t_cm];
  always_ff @(posedge clk)
    hw_q <= rst ? hwin(rob_start(RUN_TID, MD_C), 0, RUN_TID, MD_C)
                : (HART1_ON && mrs_i && ct_n == md.run) ? hwin(rob_start(md.run, mdn), 0, md.run, mdn)
                : ((ct_n == t_cm) ? hw_n[cm_n] : hwin(head_q[ct_n], 0, ct_n, mdn));
`ifndef SYNTHESIS
  // Checks of registers against each other wait for the core's first reset: in the SoC the reset
  // comes from a register (the host bridge's), so the first cycle may see it low before any reset
  logic rs_q;
  initial rs_q = 1'b0;
  always @(posedge clk) if (rst) rs_q <= 1'b1;
  always_ff @(posedge clk) begin
    if (rs_q && !rst)
      assert (hw_q == hwin(head_q[t_cm], 0, t_cm, md)) else $error("tg_rob: the registered head window differs from the head");
  end
  always_ff @(posedge clk) begin
    if (!rst && (do_mret || do_sret))
      assert (xr_v_q[t_cm] && xr_s_q[t_cm] == do_sret) else $error("tg_rob: an xRET commits that xret_v/xret_s do not name");
    if (!rst && ret[0] && hp[0].serial)
      assert (!hp[0].dexc) else $error("tg_rob: a serial instruction with a decode exception retires");
  end
  // The registered timer-pending bit (tg_csr, DR-146) settles two cycles after a CSR write, which
  // retires alone and flushes: no interrupt may be taken within that margin. Each hart's pending bits
  // are its own, so the margin is per thread: with hart 1 the other thread may take its interrupt
  // (verif-2's two-hart random programs, 10-21)
  logic [NT-1:0][1:0] csr_ago_q;          // each thread: a CSR instruction of its retired one / two cycles ago
  always_ff @(posedge clk) begin
    for (int t = 0; t < NT; t++)
      csr_ago_q[t] <= rst ? '0 : {csr_ago_q[t][0], do_csr && t_cm == tid_t'(t)};
    if (rs_q && !rst && do_irq)
      assert (csr_ago_q[t_cm] == '0) else $error("tg_rob: an interrupt within two cycles of its thread's CSR write");
  end
`endif

  logic unused;
  assign unused = ^{hp[0].is_br, hp[0].lq, hp[CW-1].is_br, hp[CW-1].lq,
                    ld_rob[ROBW-1], replay_rob[ROBW-1], alu_rob, st_rob, oth_rob[ROBW-1], tlbm_rob,
                    br_rob[ROBW-1], lx_rob, fp_cmp_rob[ROBW-1]};

`ifndef SYNTHESIS
  // Shadow flags as flip-flops (the form the toggle tables replace): the head's flags must
  // match them, and the tables' condition must hold (no second report for a live entry, none
  // for an entry as it is dispatched).
  logic [ROB_ENTRIES-1:0] cmp_s, exc_s, misp_s, mmio_s, rpl_s;
  function automatic logic live(input robid_t e);
    return rob_cnt_t(e, head_q[rob_tid(e, md)], md) < rob_cnt_t(tail_q[rob_tid(e, md)], head_q[rob_tid(e, md)], md);
  endfunction
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (ds_fire && !flush) begin
        for (int k = 0; k < DISPATCH_WIDTH; k++) begin
          if (ds_valid[k]) begin
            cmp_s[ds_ren[k].rob[RIW-1:0]]  <= !ds_ren[k].has_q;
            exc_s[ds_ren[k].rob[RIW-1:0]]  <= ds_uop[k].d.exc;
            misp_s[ds_ren[k].rob[RIW-1:0]] <= 1'b0;
            mmio_s[ds_ren[k].rob[RIW-1:0]] <= 1'b0;
            rpl_s[ds_ren[k].rob[RIW-1:0]]  <= 1'b0;
          end
        end
      end
      if (replay_valid && !rdrop(replay_rob, flush, t_fl)) rpl_s[replay_rob[RIW-1:0]] <= 1'b1;
      for (int i = 0; i < 2; i++)
        if (tlbm_valid[i] && !rdrop(tlbm_rob[i], flush, t_fl)) rpl_s[tlbm_rob[i][RIW-1:0]] <= 1'b1;
      for (int a = 0; a < NRW; a++)
        for (int b = a + 1; b < NRW; b++)
          assert (flush || !(rw_v[a] && rw_v[b] && rw_a[a] == rw_a[b]))
            else $error("tg_rob: two replay-table writers at entry %0d", rw_a[a]);
      for (int t = 0; t < NFT; t++) begin
        if (ft_v[t] && !rdrop(ft_e[t], flush, t_fl)) begin
          if (t < NCP)            cmp_s[ft_e[t][RIW-1:0]]  <= 1'b1;
          else if (t < NCP + NXP) exc_s[ft_e[t][RIW-1:0]]  <= 1'b1;
          else if (t == NFT - 2)  misp_s[ft_e[t][RIW-1:0]] <= 1'b1;
          else                    mmio_s[ft_e[t][RIW-1:0]] <= 1'b1;
          if (live(ft_e[t])) begin
            if (t < NCP)
              assert (!cmp_s[ft_e[t][RIW-1:0]]) else $error("tg_rob: a second completion of %0d", ft_e[t]);
            else if (t < NCP + NXP)
              assert (!exc_s[ft_e[t][RIW-1:0]]) else $error("tg_rob: a second exception of %0d", ft_e[t]);
            else if (t == NFT - 2)
              assert (!misp_s[ft_e[t][RIW-1:0]]) else $error("tg_rob: a second mispredict of %0d", ft_e[t]);
            else
              assert (!mmio_s[ft_e[t][RIW-1:0]]) else $error("tg_rob: a second MMIO mark of %0d", ft_e[t]);
          end
          for (int u = t + 1; u < NFT; u++) begin
            if ((t < NCP) == (u < NCP) && (t < NCP + NXP) == (u < NCP + NXP) && (t < NFT - 2) == (u < NFT - 2) &&
                (t < NFT - 1) == (u < NFT - 1) && live(ft_e[t]))
              assert (!(ft_v[u] && ft_e[u] == ft_e[t])) else $error("tg_rob: two reports of one flag for %0d", ft_e[t]);
          end
          if (ds_fire)
            for (int k = 0; k < DISPATCH_WIDTH; k++)
              assert (!(ds_valid[k] && ds_ren[k].rob[RIW-1:0] == ft_e[t][RIW-1:0]))
                else $error("tg_rob: a report for entry %0d as it is dispatched", ft_e[t]);
        end
      end
      // the store tables' late writes: never at an entry being dispatched
      for (int i = 0; i < 2; i++)
        if (sp_v_q[i] && ds_fire)
          for (int k = 0; k < DISPATCH_WIDTH; k++)
            assert (!(ds_valid[k] && ds_ren[k].rob[RIW-1:0] == sp_e_q[i][RIW-1:0]))
              else $error("tg_rob: a store table's late write at entry %0d as it is dispatched", sp_e_q[i]);
      for (int j = 0; j < CW; j++) begin
        if (j < cnt && !flush) begin
          assert (cmp_h[j] == cmp_s[hid[j][RIW-1:0]] && exc_h[j] == exc_s[hid[j][RIW-1:0]] &&
                  misp_h[j] == misp_s[hid[j][RIW-1:0]] && mmio_h[j] == mmio_s[hid[j][RIW-1:0]])
            else $error("tg_rob: the toggle-table flags of %0d differ from the shadow flags", hid[j]);
          assert (rpl_h[j] == rpl_s[hid[j][RIW-1:0]])
            else $error("tg_rob: the replay tables' flag of %0d differs from the shadow flag", hid[j]);
        end
      end
    end
  end
  // The oldest-exception chain the parallel select replaces, per thread: same winner, cause, tval and kind
  for (genvar t = 0; t < NT; t++) begin : g_sx
    logic        sx_v, sx_m;
    robid_t      sx_r;
    logic [3:0]  sx_c;
    logic [63:0] sx_t;
    function automatic logic mine(input robid_t e);
      return rob_tid(e, md) == tid_t'(t);
    endfunction
    always_comb begin
      sx_v = exr_v_q[t]; sx_r = exr_rob_q[t]; sx_c = exr_cause_q[t]; sx_t = exr_tval_q[t]; sx_m = exr_mem_q[t];
      if (oth_cmp && oth_exc && mine(oth_rob) && (!sx_v || rob_older(oth_rob, sx_r))) begin
        sx_v = 1'b1; sx_r = oth_rob; sx_c = EXC_ILLEGAL; sx_t = oth_tval; sx_m = 1'b0;
      end
      if (br_valid && br_exc && mine(br_rob) && (!sx_v || rob_older(br_rob, sx_r))) begin
        sx_v = 1'b1; sx_r = br_rob; sx_c = EXC_IMISALIGN; sx_t = br_tval; sx_m = 1'b0;
      end
      for (int i = 0; i < 4; i++) begin
        if (lx_valid[i] && mine(lx_rob[i]) && (!sx_v || rob_older(lx_rob[i], sx_r))) begin
          sx_v = 1'b1; sx_r = lx_rob[i]; sx_c = lx_cause[i]; sx_m = 1'b1;
        end
      end
      if (spx_valid && mine(spx_rob) && (!sx_v || rob_older(spx_rob, sx_r))) begin
        sx_v = 1'b1; sx_r = spx_rob; sx_c = EXC_SACCESS; sx_m = 1'b1;
      end
    end
    always_ff @(posedge clk) begin
      if (!rst && !flush)
        assert (ex_v[t] == sx_v && (!sx_v || (ex_r[t] == sx_r && ex_c[t] == sx_c && ex_m[t] == sx_m &&
                                              (sx_m || ex_t[t] == sx_t))))
          else $error("tg_rob: thread %0d's parallel oldest-exception select differs from the chain", t);
    end
  end
  always_ff @(posedge clk) begin
    if (!rst && !flush) begin
      assert (cnt >= 0 && cnt <= part_size(ROB_ENTRIES, md)) else $error("tg_rob: bad occupancy %0d", cnt);
      if (do_trap && !hp[0].dexc && !tlbx)
        assert (exr_v_q[t_cm] && exr_rob_q[t_cm] == hid[0]) else $error("tg_rob: exception register does not hold the head");
      for (int j = 0; j < CW; j++)
        if (ret[j] && misp_h[j])
          assert (mpr_v_q[t_cm] && mpr_rob_q[t_cm] == hid[j])
            else $error("tg_rob: mispredict register does not hold the branch");
      for (int j = 0; j < CW; j++)
        if (j < cnt) assert (rob_tid(hid[j], md) == t_cm) else $error("tg_rob: commit slot %0d is not its thread's", j);
    end
  end
  // (MT, step 5d) a thread with entries, not parked in WFI, waits at most RUN_K cycles for a commit turn: its head
  // operations (MMIO loads, atomics, a walk at the head), which the LSU runs only in its thread's turns, so wait at
  // most RUN_K turns of a sibling that keeps its head actionable
  if (MT) begin : g_turnwait
    logic [NT-1:0][2:0] wt_q;
    always_ff @(posedge clk)
      for (int t = 0; t < NT; t++) begin
        if (rst || tid_t'(t) == t_cm || rob_cnt_t(tail_q[t], head_q[t], md) == 0 ||
            (wfp_q[t] && !wkh_q[t] && int'(wfi_cnt_q[t]) != WFI_MAX && !slp_rdy[t]))
          wt_q[t] <= '0;
        else if (wt_q[t] != 3'd7)
          wt_q[t] <= wt_q[t] + 1'b1;
        if (rs_q && !rst)
          assert (int'(wt_q[t]) <= RUN_K) else $error("tg_rob: thread %0d waited %0d cycles for a commit turn", t, wt_q[t]);
      end
  end
  // (MT, for the compute pairs' gap, smt2_report §13.14) commit cycles in which the chosen thread commits nothing,
  // and of them those in which the other thread's head had completed (it could have committed; not parked in WFI);
  // on stderr at the end with hart 1
  if (MT) begin : g_cmw
    longint unsigned n_cm0, n_cmw;
    always_ff @(posedge clk)
      if (rst) begin
        n_cm0 <= 0;
        n_cmw <= 0;
      end else if (!flush && ready && !csr_hold && !(|ret) && !do_flush) begin
        n_cm0 <= n_cm0 + 1;
        if (rob_cnt_t(tail_q[~t_cm], head_q[~t_cm], md) != 0 && cmp_s[head_q[~t_cm][RIW-1:0]] && !wfp_q[~t_cm])
          n_cmw <= n_cmw + 1;
      end
    final $fwrite(32'h8000_0002, "TG-STALL2 %m: commit's thread committed nothing %0d cycles (%0d with the other thread's head complete)\n",
                  n_cm0, n_cmw);
  end
`endif
endmodule
