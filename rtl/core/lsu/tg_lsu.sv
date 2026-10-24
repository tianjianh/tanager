// Load/store unit for M2 (docs/spec/core-lsu.md): LQ, SQ, the load pipe AG -> M1 -> M2 -> WB,
// store-address checks, store-data capture through the shared read port, the store drain,
// MMIO, and the L1D (tg_dcache).
//
// Load pipe. AG is the LD port's EX stage (address from tg_exec), or an LQ replay when the AG
// slot is empty. AG: checks, D$ port A read, LQ address write. M1: tags, hit dword, search of
// the older stores. M2: forward / cache / wait; a result goes to the result register (WB, the
// register file is written at its end) and wakes the load's LLT at the end of M2.
// Waiting loads (miss, store conflict, MMIO) re-check their condition every cycle; ready ones
// replay oldest first, and IQ-LD's select is blocked while one waits for the slot.
// Atomics (serialising, so alone in the window) use the STA port and an SQ entry for rs2; at the
// ROB head, once every older store has drained, an FSM performs them in the D$ and writes rd
// through the result register. Their SQ entry leaves without a write after commit.
// Translation (M3, core-mmu.md): new loads and store addresses look up the DTLB at AG; the LQ
// and SQ keep the VA (trace, tval, walks) and the PA (D$, forwarding, ordering). A DTLB miss
// does not access memory: the ROB entry is marked replay+tlb and the walker prefetches the
// translation. At the ROB head such an entry is retried once the DTLB translates it, or after
// a non-speculative walk (committed stores drained first), whose fault is then precise. The
// walker (tg_ptw) reads PTEs through the load pipe's AG slot, ahead of LQ replays.
module tg_lsu
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_core_pkg::*;
#(
  localparam int LIW = LQW - 1,
  localparam int SIW = SQW - 1
) (
  input  logic                         clk,
  input  logic                         rst,
  output logic                         ready,         // the D$ state is swept after reset
  input  logic                         init_we,       // the reset sequence's zero writes (tg_core), ...
  input  logic [4:0]                   init_idx,      // ... at x0..x31's homes: with hart 1 its load-bank and F1 ones
  input  logic                         flush,
  input  tid_t                         flush_tid,
  // Dispatch
  input  logic                         ds_fire,
  input  logic [DISPATCH_WIDTH-1:0]    ds_valid,
  input  uop_t [DISPATCH_WIDTH-1:0]    ds_uop,
  input  ren_t [DISPATCH_WIDTH-1:0]    ds_ren,
  output lqid_t [NUM_THREADS-1:0]      lq_head_o,     // each thread's
  output sqid_t [NUM_THREADS-1:0]      sq_head_o,
  output sqid_t [NUM_THREADS-1:0]      sq_cmt_o,
  // Address generation from tg_exec (EX of the LD and STA ports)
  input  logic                         ld_ag_valid,
  input  iq_pl_t                       ld_ag_pl,
  input  logic [63:0]                  ld_ag_addr,
  input  logic                         sta_ag_valid,
  input  iq_pl_t                       sta_ag_pl,
  input  logic [63:0]                  sta_ag_addr,
  output logic                         ld_block,      // registered: IQ-LD select blocked
  output logic                         fp_block,      // registered: IQ-FP select blocked (a held FP load waits)
  // Load results
  output logic                         ld_m2_will,
  output logic                         ld_m2_miss,    // the load in M2 missed the D$ (tg_issue's wakeup filter)
  output logic [PIDX_W-1:0]            ld_m2_dst,
  output logic                         ld_res_valid,
  output logic [PIDX_W-1:0]            ld_res_dst,
  output logic [63:0]                  ld_res_data,
  output logic [NCOL-1:0]              wake_ld,       // LLTs confirmed this cycle
  output logic [LLT_ENTRIES-1:0]       llt_done,      // load bank written this cycle
  // FP loads (EXT_FD): their bank (F1, or F0 when rename crossed it: DR-179) written by P4 straight from the result
  // register, announced at M2. P4's write next cycle (its announcement) holds a load bound for that bank (below)
  output logic                         fld_m2_will,
  output logic                         fld_m2_bank,
  output logic [FPIDX_W-1:0]           fld_m2_idx,
  output logic                         fld_valid,
  output logic                         fld_bank,
  output logic [FPIDX_W-1:0]           fld_idx,
  output logic [63:0]                  fld_data,
  input  logic                         p4_nx_we,
  input  logic                         p4_nx_bank,
  // Store data: the shared integer port (busy while P4 reads an integer source) or, for FP
  // stores, the FP file's store-data port; FP register writes are snooped for FP store data
  output preg_t                        sd_tag,
  input  logic [63:0]                  sd_data,
  input  logic                         sd_busy,
  output preg_t                        fsd_tag,
  input  logic [1:0][63:0]             fsd_data,   // both FP banks (P4): fsd_tag's bank picks one
  input  logic [1:0]                   fp_we,
  input  logic [1:0][FPIDX_W-1:0]      fp_widx,
  input  logic [DISPATCH_WIDTH-1:0]    ds_src2_rdy,   // DS: the store data's register is written
  input  logic [INT_BANKS-1:0]         rf_we,         // register-file writes, snooped for store data
  input  logic [INT_BANKS-1:0][PIDX_W-1:0] rf_widx,
  // To the ROB
  output logic                         ld_cmp_valid,
  output robid_t                       ld_cmp_rob,
  output logic                         ld_cmp_mmio,
  output logic [1:0]                   st_cmp_valid,
  output robid_t [1:0]                 st_cmp_rob,
  output logic [3:0]                   exc_valid,     // new load (AG), denied line (M2), MMIO load, store
  output robid_t [3:0]                 exc_rob,
  output logic [3:0][3:0]              exc_cause,
  output logic                         replay_valid,  // a store's ordering violation (its oldest load), a
  output robid_t                       replay_rob,    // cycle after the store's search
  output logic                         snp_valid,     // CoRR (architecture_plan §4.9): a thread's oldest load the snoop
  output robid_t                       snp_rob,       // marking found holding a value another hart may have overwritten
  output logic [NUM_THREADS-1:0][2:0]  hpm_lsu,       // M9's counters (TG_HPM): each thread's L1D load misses (0), data
                                                       // walks (1) and fetch's walks (2), pulses (tg_core registers them)
  output logic                         spx_valid,     // a store's PMP denial, found after it decided (S3)
  output robid_t                       spx_rob,
  output logic [1:0]                   sth_v,         // commit stops before these stores: S2, S3
  output robid_t [1:0]                 sth_rob,
  // From the ROB / commit
  input  robid_t [NUM_THREADS-1:0]     rob_head,      // each thread's
  input  tid_t                         hd_tid,        // the thread whose head commits this cycle (the head checks)
  input  tid_t                         hd_tid_n,      // ... next cycle's (the ROB's ct_n)
  input  tid_t                         cm_tid,        // the commit group's thread
  input  logic [idx_w(COMMIT_WIDTH + 1)-1:0] cm_nld,  // loads retiring this cycle
  input  logic [idx_w(COMMIT_WIDTH + 1)-1:0] cm_nst,  // stores retiring this cycle
  input  sqid_t [COMMIT_WIDTH-1:0]     tr_sq,          // trace: committed stores' fields
  output logic [COMMIT_WIDTH-1:0]      tr_st_wr,       // ... the store wrote memory (atomics)
  output logic [COMMIT_WIDTH-1:0][63:0] tr_st_va,
  output logic [COMMIT_WIDTH-1:0][63:0] tr_st_data,
  output logic [COMMIT_WIDTH-1:0][1:0] tr_st_size,
  input  lqid_t [COMMIT_WIDTH-1:0]     tr_lq,          // trace: committed loads' address and size (v1.5, mem_ld)
  output logic [COMMIT_WIDTH-1:0][63:0] tr_ld_va,
  output logic [COMMIT_WIDTH-1:0][1:0] tr_ld_size,
  output logic                         sq_drained,    // no committed store left (hd_tid's)
  output logic                         mmio_busy,     // an MMIO load or an atomic: no interrupt (hd_tid's)
  input  logic                         irq_go,        // the ROB takes an interrupt this cycle (its trap's tr_irq)
  input  logic                         rsv_clr,       // trap or xRET: the LR reservation ends (hd_tid's)
  // Translation and PMP (M3), each hart's (M7's step 4: an access takes its thread's)
  input  priv_e  [NUM_THREADS-1:0]                  priv,          // fetch walks
  input  priv_e  [NUM_THREADS-1:0]                  priv_d,        // loads and stores
  input  logic   [NUM_THREADS-1:0]                  sum,
  input  logic   [NUM_THREADS-1:0]                  mxr,
  input  logic   [NUM_THREADS-1:0]                  satp_sv39,
  input  logic   [NUM_THREADS-1:0][43:0]            satp_ppn,
  input  pmp_d_t [NUM_THREADS-1:0][PMP_ENTRIES-1:0] pmp_d,
  input  logic   [NUM_THREADS-1:0][PMP_ENTRIES-1:0][2:0] pmp_pal,
  input  logic   [NUM_THREADS-1:0]                  pmp_lk_h,      // DR-183: a hart's active locked entries
  // DR-183 (PMP_FILL): fetch's checks on the shared checker. A registered request, held until its response the
  // cycle after its grant: a page's S/U result and whether a region boundary lies inside it (4 KiB), or one 4-byte
  // word's
  input  logic                         pfc_req,
  input  logic                         pfc_page,       // a page, else a word
  input  logic                         pfc_tag,        // the response echoes it
  input  tid_t                         pfc_tid,
  input  logic [PA_W-1:0]              pfc_pa,
  input  logic                         pfc_m,          // a word under M's rules (M-mode with a locked entry)
  output logic                         pfc_rsp_v,
  output logic                         pfc_rsp_tag,
  output logic                         pfc_rsp_ok,     // the word may be fetched
  output logic                         pfc_rsp_nh,     // a region boundary lies inside the page
  output logic                         pfc_rsp_x,      // the page's S/U execute permission
  input  logic                         tlb_flush,
  input  tid_t                         tlb_flush_tid,  // ... the hart whose entries it clears
  output logic [1:0]                   tlbm_valid,    // DTLB misses at AG (LD, STA)
  output robid_t [1:0]                 tlbm_rob,
  output logic                         hd_tlb,        // the ROB head is a load or store that missed the DTLB
  output logic                         hd_retry,      // the ROB head's DTLB miss resolves
  output logic                         hd_fault,
  output logic [3:0]                   hd_cause,
  output logic [63:0]                  hd_lva,        // the LQ head's VA and the SQ commit point's: the ROB
  output logic [63:0]                  hd_sva,        // head's tval when a load or store traps there
  input  logic                         iw_req,        // fetch walks
  input  logic [63:0]                  iw_va,
  input  tid_t                         iw_tid,        // ... the walking thread's (M7's step 5b)
  output logic                         iw_ack,
  output logic                         iw_done,
  output logic                         iw_ok,
  output logic [3:0]                   iw_cause,
  output logic                         it_fill,
  output logic [26:0]                  it_fill_vpn,
  output logic [1:0]                   it_fill_lvl,
  output tid_t                         it_fill_tid,   // ... the walk's thread
  output tlb_pte_t                     it_fill_pte,
  output logic                         st_dropped,
  // l1d
  output tl_a_t                        l1d_a_o,
  output logic                         l1d_a_valid_o,
  input  logic                         l1d_a_ready_i,
  input  tl_b_t                        l1d_b_i,
  input  logic                         l1d_b_valid_i,
  output logic                         l1d_b_ready_o,
  output tl_c_t                        l1d_c_o,
  output logic                         l1d_c_valid_o,
  input  logic                         l1d_c_ready_i,
  input  tl_d_t                        l1d_d_i,
  input  logic                         l1d_d_valid_i,
  output logic                         l1d_d_ready_o,
  output tl_e_t                        l1d_e_o,
  output logic                         l1d_e_valid_o,
  input  logic                         l1d_e_ready_i,
  // mmio
  output tl_a_t                        mmio_a_o,
  output logic                         mmio_a_valid_o,
  input  logic                         mmio_a_ready_i,
  input  tl_d_t                        mmio_d_i,
  input  logic                         mmio_d_valid_i,
  output logic                         mmio_d_ready_o,
  output logic [15:0]                  dbg_o,         // board debug: atomic, SQ head, D$ (tg_core's dbg_o)
  // Step 6 (D2, threading.md), with hart 1: the halves merge while a thread sleeps (tg_rename)
  input  md_t                          md_i,          // the mode
  input  md_t                          mdn_i,         // ... next cycle's
  input  logic                         mrs_i          // the split moves md_i.run's empty window to its half's start
);
  // ---- Helpers ----
  function automatic logic [7:0] bmask(input logic [2:0] off, input logic [1:0] size);
    logic [7:0] m;
    unique case (size)
      2'd0: m = 8'h01;
      2'd1: m = 8'h03;
      2'd2: m = 8'h0f;
      default: m = 8'hff;
    endcase
    return m << off;
  endfunction
  // The naturally aligned element of a dword, 2^size bytes at byte offset off, extended. off is
  // a multiple of the size (misaligned accesses trap at AG), so each result byte selects among
  // the few offsets its element sizes allow, not among all eight as a shifter would.
  function automatic logic [63:0] ext_al(input logic [63:0] dw, input logic [2:0] off,
                                         input logic [1:0] size, input logic uns);
    logic [7:0]  b0;                                 // the element's byte 0: any offset
    logic [7:0]  b1;                                 // ... byte 1: an even offset
    logic [15:0] h1;                                 // ... bytes 2-3: offset 0 or 4
    logic        s;
    b0 = dw[{off, 3'b000} +: 8];
    b1 = dw[{off[2:1], 1'b1, 3'b000} +: 8];
    h1 = dw[{off[2], 5'b10000} +: 16];
    unique case (size)
      2'd0:    s = b0[7];
      2'd1:    s = b1[7];
      default: s = h1[15];
    endcase
    s = s && !uns;
    unique case (size)
      2'd0:    return {{56{s}}, b0};
      2'd1:    return {{48{s}}, b1, b0};
      2'd2:    return {{32{s}}, h1, b1, b0};
      default: return dw;
    endcase
  endfunction
  // AMO arithmetic. a: the old value (sign-extended for .W); for .W only the low word is written.
  function automatic logic [63:0] amo_alu(input logic [4:0] op, input logic w, input logic [63:0] a,
                                          input logic [63:0] b);
    logic [63:0] bs;
    logic lt, ltu;
    bs  = w ? {{32{b[31]}}, b[31:0]} : b;
    lt  = $signed(a) < $signed(bs);
    ltu = w ? a[31:0] < b[31:0] : a < b;
    unique case (op)
      AMO_ADD:  return a + b;
      AMO_XOR:  return a ^ b;
      AMO_AND:  return a & b;
      AMO_OR:   return a | b;
      AMO_MIN:  return lt ? a : bs;
      AMO_MAX:  return lt ? bs : a;
      AMO_MINU: return ltu ? a : b;
      AMO_MAXU: return ltu ? b : a;
      default:  return b;                           // SWAP and SC (LR writes nothing)
    endcase
  endfunction
  // A store's bytes copied into every naturally aligned slot of their size. Stores are
  // naturally aligned, so this puts them in their own byte lanes, which is all a byte-masked
  // write or a covered load reads: no shifter by the address.
  function automatic logic [63:0] rep(input logic [63:0] d, input logic [1:0] size);
    unique case (size)
      2'd0:    return {8{d[7:0]}};
      2'd1:    return {4{d[15:0]}};
      2'd2:    return {2{d[31:0]}};
      default: return d;
    endcase
  endfunction
  function automatic logic misal(input logic [2:0] a, input logic [1:0] size);
    unique case (size)
      2'd0: return 1'b0;
      2'd1: return a[0];
      2'd2: return a[1:0] != 2'b0;
      default: return a[2:0] != 3'b0;
    endcase
  endfunction

  // ---- LQ ----
  typedef enum logic [3:0] {
    L_WAIT  = 4'd0,   // allocated; address not generated yet
    L_PIPE  = 4'd1,   // in M1/M2
    L_DONE  = 4'd2,   // value obtained
    L_MISS  = 4'd3,   // waits for the MSHR to go idle
    L_STQ   = 4'd4,   // waits for a store
    L_MMIO  = 4'd5,   // waits to be the ROB head
    L_READY = 4'd6,   // replays when the AG slot is free
    L_EXC   = 4'd7,
    L_TLB   = 4'd8    // DTLB miss: resolved at the ROB head (replay)
  } lstate_e;
  logic   [LQ_ENTRIES-1:0]           lq_v_q;
  lstate_e [LQ_ENTRIES-1:0]          lq_st_q;
  sqid_t  [LQ_ENTRIES-1:0]           lq_sq_q;      // SQ tail at rename: older stores before it
  logic   [LQ_ENTRIES-1:0][1:0]      lq_size_q;
  // Cold fields, written at AG and read by index (M2, the MMIO load, the LQ head), live in
  // LUTRAM, not CAM flip-flops: the VA (tval, the ROB head's walk), the ROB index, and the
  // result's destination, LLT and format. The destination's index is the wider of the integer and FP files'.
  localparam int LDW = (EXT_FD && FPIDX_W > PIDX_W) ? FPIDX_W : PIDX_W;
  typedef struct packed {
    robid_t            rob;
    logic              dv;                         // writes a register
    logic              fp;                         // ... an f register (EXT_FD)
    logic              fb;                         // ... in this FP bank (F1; F0 when crossed, DR-179)
    logic              uns;                        // zero-extends (FP: raw bits)
    logic [LDW-1:0]    dst;
    llt_t              llt;
    logic [63:0]       va;
  } lqc_t;
  logic [2:0][LIW-1:0]               lqc_ra;       // M2, the MMIO load, the LQ head
  lqc_t [2:0]                        lqc_rd;
  lqc_t                              lqc_wd;
  logic [1:0][LIW-1:0]               lqr_ra;       // the ordering violation's ROB index, CoRR's snoop report's
  robid_t [1:0]                      lqr_rd;
  typedef struct packed {
    logic [PA_W-1:0] pa;
    logic [1:0]      size;
  } lqa_t;
  logic [1:0][LIW-1:0]               lqa_ra;       // a replay, the LQ head (MMIO)
  lqa_t [1:0]                        lqa_rd;
  typedef struct packed {
    logic [PA_W-1:0] pa;
    logic [7:0]      mask;
    logic [1:0]      size;
  } sqh_t;
  sqh_t                              sqh;          // the SQ head's address fields
  logic   [LQ_ENTRIES-1:0][PA_W-1:0] lq_pa_q;
  logic   [LQ_ENTRIES-1:0]           lq_pav_q;     // physical address known
  logic   [LQ_ENTRIES-1:0]           lq_mc_q;      // M9's counters (TG_HPM): the load's L1D miss is counted (its first)
  sqid_t  [LQ_ENTRIES-1:0]           lq_blk_q;     // blocking store
  logic   [LQ_ENTRIES-1:0]           lq_part_q;    // ... partial overlap (wait until it leaves)
  // DR-183 (PMP_FILL): the load's PMP check is still to come, the shared checker having been taken in its check
  // cycle: its replay asks again (a parked MMIO load: the head asks before its issue, mh_req)
  logic   [LQ_ENTRIES-1:0]           lq_pck_q;
  // DR-149 (DC_MSHRS > 1): an L_MISS load waits for its entry's install (lq_we_q), or, while it
  // has none (lq_wany_q), for any install or the miss side going idle
  logic   [LQ_ENTRIES-1:0]           lq_wany_q;
  logic   [LQ_ENTRIES-1:0][idx_w(DC_MSHRS)-1:0] lq_we_q;
  // Per thread (M7's steps 3 and 4, docs/spec/threading.md): the LQ's and SQ's pointers. Dispatch moves its group's
  // thread's tails (t_ds), commit its thread's LQ head and SQ commit pointer (t_cm), and a flush recovers its thread's
  // (t_fl). In split mode (SPLIT) a thread's pointers wrap inside its half (x_add_t), and a flush drops the flushed
  // thread's entries only. Step 4: every search stays inside its thread's entries (lq_ot, sq_ot) and window; the
  // replays and the drain alternate between the threads (D8); the head checks and the MMIO load follow the ROB's
  // commit thread (t_hd); the atomics have a slot and the reservation a register per thread; and a flush kills only
  // its thread's operations (kill_t), each stage knowing its operation's thread from its queue entry or its walk.
  // In merged mode one thread runs: its tids are the constant RUN_TID (the same values the payloads carry), so
  // synthesis keeps none of the second thread's logic until two threads run (step 5).
  localparam int NT = NUM_THREADS;
  md_t md, mdn;                     // the mode and next cycle's (step 6; constants without hart 1)
  // The mode comes from a copy of rename's md_q kept here (the same value: md_q takes mdn every cycle, and both
  // reset to MD_C), so its fan-out starts beside the logic it feeds, not across the core at rename (timing: the full
  // chip's worst path started at md_q, spikes §8.18). Kept, so that synthesis does not merge it into md_q
  (* keep = "true" *) md_t md_l_q;
  always_ff @(posedge clk) md_l_q <= rst ? MD_C : mdn_i;
  assign md  = HART1_ON ? md_l_q : MD_C;
  assign mdn = HART1_ON ? mdn_i : MD_C;
`ifndef SYNTHESIS
  logic md_rs;                      // (the copy is checked from the first reset on)
  initial md_rs = 1'b0;
  always @(posedge clk) if (rst) md_rs <= 1'b1;
  always_ff @(posedge clk)
    if (md_rs && !rst && HART1_ON)
      assert (md_l_q == md_i) else $error("tg_lsu: the mode's copy differs from rename's md_q");
`endif
  // The SQ pointers of each LQ half's thread (its own split, the running thread's merged): picked once a half, not
  // an entry (step 6's mode makes an entry's thread a signal)
  sqid_t [1:0] sqh_lh, sqt_lh;
  tid_t t_ds, t_cm, t_fl, t_hd;
  assign t_ds = (NT > 1 && SPLIT) ? ds_uop[0].tid : RUN_TID;
  assign t_cm = (NT > 1 && SPLIT) ? cm_tid : RUN_TID;
  assign t_fl = (NT > 1 && SPLIT) ? flush_tid : RUN_TID;
  assign t_hd = (NT > 1 && SPLIT) ? hd_tid : RUN_TID;
  tid_t t_iw;                                   // fetch's walk's thread
  assign t_iw = (NT > 1 && SPLIT) ? iw_tid : RUN_TID;
  // The entries each thread owns (in merged mode the running thread every one), registered from the next cycle's mode
  // as md_l_q is, so each equals lq_own/sq_own of md in every cycle (asserted below). Timing: the mode's fan-out
  // into every search's thread terms starts at these registers (spikes §8.18, the replay pick from md_l_q)
  // (without hart 1 the mode is the constant MD_C: constants, no registers)
  logic [NT-1:0][LQ_ENTRIES-1:0] lq_ot;
  logic [NT-1:0][SQ_ENTRIES-1:0] sq_ot;
  if (HART1_ON) begin : g_ot
    always_ff @(posedge clk)
      for (int t = 0; t < NT; t++) begin
        lq_ot[t] <= lq_own(tid_t'(t), rst ? MD_C : mdn);
        sq_ot[t] <= sq_own(tid_t'(t), rst ? MD_C : mdn);
      end
  end else begin : g_otc
    always_comb
      for (int t = 0; t < NT; t++) begin
        lq_ot[t] = lq_own(tid_t'(t), MD_C);
        sq_ot[t] = sq_own(tid_t'(t), MD_C);
      end
  end
  logic [LQ_ENTRIES-1:0] fl_lq;                 // the flushed thread's half (step 6: none of a sleeper's while merged)
  logic [SQ_ENTRIES-1:0] fl_sq;
  assign fl_lq = lq_ot[t_fl];
  assign fl_sq = sq_ot[t_fl];
  // A flush kills only its thread's operations (rule 2): in merged mode each is the running thread's, as the flush
  logic [NT-1:0] kill_t;
  always_comb for (int t = 0; t < NT; t++) kill_t[t] = flush && (!SPLIT || t_fl == tid_t'(t));
  tid_t t_ldag;                                 // the LD port's load's thread: its payload's, its LQ entry's (asserted)
  assign t_ldag = ld_ag_pl.tid;
  lqid_t  [NT-1:0]                   lq_head_q, lq_tail_q;

  // ---- SQ ----
  logic   [SQ_ENTRIES-1:0]           sq_v_q;
  // The trace's read ports (one per commit slot) exist only with the commit trace (DR-146,
  // TG_COMMIT_TRACE); TRP is where the other ports start
  localparam int TRP = tg_trace_pkg::COMMIT_TRACE ? COMMIT_WIDTH : 0;
  // The ROB index and size, written at STA and read only by index, live in LUTRAM (u_sqrob,
  // u_sqsz): the store-data completion and the head's DTLB retry read the index; the trace and
  // forwarding read the size
  logic [1:0][SIW-1:0]               sqrob_ra;     // the captured store, the commit point
  robid_t [1:0]                      sqrob_rd;
  logic [TRP:0][SIW-1:0]             sqsz_ra;      // the trace's stores, the forwarding store
  logic [TRP:0][1:0]                 sqsz_rd;
  logic   [SQ_ENTRIES-1:0]           sq_av_q, sq_dv_q, sq_mmio_q, sq_exc_q;
  // VA and data in LUTRAM: the VA for the trace, the head's walk and tval; the data for the
  // trace, forwarding, the drain and atomics. The CAMs use the PA and masks in flip-flops.
  localparam int SVR = TRP + 1;                   // SQ VA reads: trace, the commit point (head walk, atomic)
  localparam int SDR = TRP + 2;                   // SQ data reads: trace, forwarding, the head (drain, atomic)
  logic [SVR-1:0][SIW-1:0]           sqva_ra;
  logic [SVR-1:0][63:0]              sqva_rd;
  logic [SDR-1:0][SIW-1:0]           sqd_ra;
  logic [SDR-1:0][63:0]              sqd_rd;
  logic                              sqd_we;
  logic [SIW-1:0]                    sqd_wa;
  logic [63:0]                       sqd_wd;
  logic   [SQ_ENTRIES-1:0]           sq_dr_q;      // the data's register is written (snooped)
  logic   [SQ_ENTRIES-1:0][PA_W-1:0] sq_pa_q;
  logic   [SQ_ENTRIES-1:0]           sq_tlb_q;     // DTLB miss: no address (ROB replay)
  logic   [SQ_ENTRIES-1:0]           sq_pden_q;    // an atomic that its PMP check (S2) denied
  logic   [SQ_ENTRIES-1:0][7:0]      sq_mask_q;
  preg_t  [SQ_ENTRIES-1:0]           sq_tag_q;
  logic   [SQ_ENTRIES-1:0]           sq_fp_q;      // the data is an f register (EXT_FD)
  logic   [SQ_ENTRIES-1:0]           sq_amo_q;     // an atomic's entry: never forwards or drains
  logic   [SQ_ENTRIES-1:0]           sq_amw_q;     // ... the atomic wrote memory (trace)
  sqid_t  [NT-1:0]                   sq_head_q, sq_cmt_q, sq_tail_q;
  always_comb
    for (int h = 0; h < 2; h++) begin
      sqh_lh[h] = sq_head_q[lq_tid(h * (LQ_ENTRIES / 2), md)];
      sqt_lh[h] = sq_tail_q[lq_tid(h * (LQ_ENTRIES / 2), md)];
    end
  logic   [SQ_ENTRIES-1:0]           sq_hge_q;     // the drain's head's mask (t_dr_q's): slot i at or after its slot

  assign lq_head_o = lq_head_q;
  logic [LIW-1:0] hl;                             // the LQ head's slot (the head thread's)
  assign hl = lq_head_q[t_hd][LIW-1:0];
  assign sq_head_o = sq_head_q;
  assign sq_cmt_o  = sq_cmt_q;
  logic [NT-1:0] sq_drn;                          // each thread's committed stores have drained
  always_comb for (int t = 0; t < NT; t++) sq_drn[t] = sq_head_q[t] == sq_cmt_q[t];
  assign sq_drained = sq_drn[t_hd];

  function automatic logic [SQ_ENTRIES-1:0] sq_ge(input int b);   // the slots at or after slot b
    logic [SQ_ENTRIES-1:0] m;
    for (int i = 0; i < SQ_ENTRIES; i++) m[i] = i >= b;
    return m;
  endfunction
  function automatic logic [LIW-1:0] lqi(input lqid_t p);
    /* verilator lint_off UNUSEDSIGNAL */  // the wrap bit is not part of the index
    lqid_t q;
    /* verilator lint_on UNUSEDSIGNAL */
    q = p;
    return q[LIW-1:0];
  endfunction
  function automatic sqid_t sq_id(input int i, input sqid_t head);
    // the ID (index plus wrap) of SQ slot i, given that it lies in [head, head + SQ_ENTRIES)
    logic w;
    w = (i >= int'(head[SIW-1:0])) ? head[SIW] : !head[SIW];
    return {w, SIW'(i)};
  endfunction

  // ---- Age searches ----
  // A queue's entries lie in [head, tail), so the oldest of a set of slots is the first at or
  // after the head's slot, else the first from slot 0; and the youngest of a set inside
  // [head, e) is the last below e's slot, else the last overall. Two priority encoders per
  // search, with no distance arithmetic.
  function automatic logic [LIW-1:0] lq_first(input logic [LQ_ENTRIES-1:0] v);
    logic [LIW-1:0] r;
    r = '0;
    for (int i = LQ_ENTRIES - 1; i >= 0; i--) if (v[i]) r = LIW'(i);
    return r;
  endfunction
  function automatic logic [SIW-1:0] sq_first(input logic [SQ_ENTRIES-1:0] v);
    logic [SIW-1:0] r;
    r = '0;
    for (int i = SQ_ENTRIES - 1; i >= 0; i--) if (v[i]) r = SIW'(i);
    return r;
  endfunction
  function automatic logic [SIW-1:0] sq_last(input logic [SQ_ENTRIES-1:0] v);
    logic [SIW-1:0] r;
    r = '0;
    for (int i = 0; i < SQ_ENTRIES; i++) if (v[i]) r = SIW'(i);
    return r;
  endfunction
  function automatic logic [LIW-1:0] lq_oldest(input logic [LQ_ENTRIES-1:0] v, input logic [LIW-1:0] h);
    logic [LQ_ENTRIES-1:0] hi;
    for (int i = 0; i < LQ_ENTRIES; i++) hi[i] = v[i] && i >= int'(h);
    return |hi ? lq_first(hi) : lq_first(v);
  endfunction
  // The same search on a carry chain (timing, DR-145: in G6 the ordering check's select took seven
  // LUT levels after its address compares): the set twice over, the slots at or after the head's
  // in the low half, so the lowest set bit of the 2N is the oldest (u & -u, whose chain carries
  // "no set bit below"); the halves' one-hot bits merge, then an OR encode. Exactly lq_oldest, an
  // empty set giving 0 (asserted against it)
  function automatic logic [LIW-1:0] lq_oldest_c(input logic [LQ_ENTRIES-1:0] v, input logic [LIW-1:0] h);
    logic [LQ_ENTRIES-1:0]   ge, e;
    logic [2*LQ_ENTRIES-1:0] u, oh;
    logic [LIW-1:0]          r;
    for (int i = 0; i < LQ_ENTRIES; i++) ge[i] = i >= int'(h);
    u  = {v, v & ge};
    oh = u & -u;
    e  = oh[LQ_ENTRIES-1:0] | oh[2*LQ_ENTRIES-1:LQ_ENTRIES];
    r  = '0;
    for (int i = 0; i < LQ_ENTRIES; i++) if (e[i]) r = r | LIW'(i);
    return r;
  endfunction
  // the oldest slot of v, from the head's mask (hge[i]: slot i at or after the head's slot)
  function automatic logic [SIW-1:0] sq_oldest(input logic [SQ_ENTRIES-1:0] v,
                                               input logic [SQ_ENTRIES-1:0] hge);
    logic [SQ_ENTRIES-1:0] hi;
    hi = v & hge;
    return |hi ? sq_first(hi) : sq_first(v);
  endfunction
  // The same search as a one-hot on a carry chain (as lq_oldest_c): v twice over, the slots at or
  // after the head's in the low half, so the lowest set bit of the 2N is the oldest (u & -u); an
  // empty set gives slot 0, as sq_oldest does (asserted against it)
  function automatic logic [SQ_ENTRIES-1:0] sq_oldest_oh(input logic [SQ_ENTRIES-1:0] v,
                                                        input logic [SQ_ENTRIES-1:0] hge);
    logic [2*SQ_ENTRIES-1:0] u, oh;
    logic [SQ_ENTRIES-1:0]   e;
    u    = {v, v & hge};
    oh   = u & -u;
    e    = oh[SQ_ENTRIES-1:0] | oh[2*SQ_ENTRIES-1:SQ_ENTRIES];
    e[0] = e[0] || !(|v);
    return e;
  endfunction
  // a one-hot's slot, an OR encode
  function automatic logic [SIW-1:0] sq_enc(input logic [SQ_ENTRIES-1:0] e);
    logic [SIW-1:0] r;
    r = '0;
    for (int i = 0; i < SQ_ENTRIES; i++) if (e[i]) r = r | SIW'(i);
    return r;
  endfunction
  // whether SQ slot i lies in the window [h, e) of IDs (every slot when e is h + SQ_ENTRIES)
  function automatic logic sq_inwin(input int i, input sqid_t h, input sqid_t e);
    return (h[SIW] == e[SIW]) ? i >= int'(h[SIW-1:0]) && i < int'(e[SIW-1:0])
                              : i >= int'(h[SIW-1:0]) || i < int'(e[SIW-1:0]);
  endfunction
  // whether ID p is in the SQ, [h, t): its slot is in the window, with the window's wrap bit
  function automatic logic sq_live(input sqid_t p, input sqid_t h, input sqid_t t);
    logic w;
    w = (int'(p[SIW-1:0]) >= int'(h[SIW-1:0])) ? h[SIW] : !h[SIW];
    return sq_inwin(int'(p[SIW-1:0]), h, t) && p[SIW] == w;
  endfunction

  // ---- Commit-side trace reads (only with the commit trace) ----
  if (tg_trace_pkg::COMMIT_TRACE) begin : g_trace
    for (genvar j = 0; j < COMMIT_WIDTH; j++) begin : g_tr
      assign sqva_ra[j]    = tr_sq[j][SIW-1:0];
      assign sqd_ra[j]     = tr_sq[j][SIW-1:0];
      assign tr_st_va[j]   = sqva_rd[j];
      assign tr_st_data[j] = sqd_rd[j];
      assign sqsz_ra[j]    = tr_sq[j][SIW-1:0];
      assign tr_st_size[j] = sqsz_rd[j];
      assign tr_st_wr[j]   = !sq_amo_q[tr_sq[j][SIW-1:0]] || sq_amw_q[tr_sq[j][SIW-1:0]];
    end
    // The committed loads' VA (v1.5's mem_ld): a copy of u_lqc's, written with it at AG, read by the commit slots'
    // LQ indices (the head's reads stay u_lqc's); the size from the LQ's flip-flops
    logic [COMMIT_WIDTH-1:0][LIW-1:0] lqva_ra;
    logic [COMMIT_WIDTH-1:0][63:0]    lqva_rd;
    for (genvar j = 0; j < COMMIT_WIDTH; j++) begin : g_trl
      assign lqva_ra[j]    = tr_lq[j][LIW-1:0];
      assign tr_ld_va[j]   = lqva_rd[j];
      assign tr_ld_size[j] = lq_size_q[tr_lq[j][LIW-1:0]];
    end
    tg_ram_lut #(.DEPTH(LQ_ENTRIES), .WIDTH(64), .NR(COMMIT_WIDTH)) u_lqva (
      .clk, .we(ld_ag_valid && !kill_t[t_ldag]), .waddr(ld_ag_pl.lq[LIW-1:0]), .wdata(lqc_wd.va), .raddr(lqva_ra),
      .rdata(lqva_rd));
  end else begin : g_notrace
    assign tr_st_va   = '0;
    assign tr_st_data = '0;
    assign tr_st_size = '0;
    assign tr_st_wr   = '0;
    assign tr_ld_va   = '0;
    assign tr_ld_size = '0;
    logic unused_tr;
    assign unused_tr = ^{tr_sq, tr_lq, sq_amw_q};      // sq_amw_q: an atomic wrote memory, for the trace
  end

  // ---- D$ ----
  logic              dc_rd_en;
  logic [PA_W-1:0]   dc_rd_pa;
  logic [PA_W-1:0]   m1_pa;
  logic              dc_hit;
  logic [63:0]       dc_dword;
  logic              lm_req;
  logic [PA_W-1:0]   lm_pa;
  logic              mshr_idle, lm_fdn;            // lm_fdn: the miss's line, its last fill denied
  logic              lm_ans_v, lm_ans_wait;      // DR-149 (DC_MSHRS > 1): the miss's answer, its entry
  logic [idx_w(DC_MSHRS)-1:0] lm_ans_e;
  logic [DC_MSHRS-1:0] m_done;                   // ... the entries' installs, and any (or none busy)
  logic              m_wake_any;
  logic              pf_req;                      // STORE_PF: a store's line, wanted with T (STA, below)
  logic [PA_W-1:0]   pf_pa;
  logic              st_req, st_ack;
  logic              st_wait, st_resv;            // M7: the drain's store needs a miss entry; one waits (below)
  logic [PA_W-1:0]   st_pa;
  logic [15:0]       st_mask;
  logic [63:0]       st_wdata;
  logic              am_req, am_sel, am_ack, am_den, lose_v;
  logic              pr_hold;                     // the D$'s probes wait: a young LR reservation
  logic [PA_W-1:0]   am_pa;
  logic [15:0]       am_wmask;
  logic [63:0]       am_wdata;
  logic [63:0]       am_rdata;
  logic [PA_W-1:6]   lose_line;
  logic [7:0] dc_dbg;
  logic              dc_snp_v;                    // CoRR: a line leaves the D$ (a probe to N, an eviction)
  logic [PA_W-1:6]   dc_snp_line;
  tg_dcache u_dc (
    .clk, .rst, .ready,
    .ld_rd_en(dc_rd_en), .ld_rd_pa(dc_rd_pa), .ld_m1_pa(m1_pa), .ld_hit(dc_hit), .ld_dword(dc_dword),
    .lm_req, .lm_pa, .mshr_idle, .lm_fdn, .lm_ans_v, .lm_ans_wait, .lm_ans_e, .m_done, .m_wake_any,
    .pf_req, .pf_pa,
    .st_req, .st_pa, .st_mask, .st_wdata, .st_ack, .st_dropped, .st_wait, .st_resv,
    .am_req, .am_sel, .pr_hold, .am_pa, .am_wmask, .am_wdata, .am_ack, .am_rdata, .am_den, .lose_v, .lose_line,
    .a_o(l1d_a_o), .a_valid_o(l1d_a_valid_o), .a_ready_i(l1d_a_ready_i),
    .b_i(l1d_b_i), .b_valid_i(l1d_b_valid_i), .b_ready_o(l1d_b_ready_o),
    .c_o(l1d_c_o), .c_valid_o(l1d_c_valid_o), .c_ready_i(l1d_c_ready_i),
    .d_i(l1d_d_i), .d_valid_i(l1d_d_valid_i), .d_ready_o(l1d_d_ready_o),
    .e_o(l1d_e_o), .e_valid_o(l1d_e_valid_o), .e_ready_i(l1d_e_ready_i), .dbg_o(dc_dbg),
    .snp_v(dc_snp_v), .snp_line(dc_snp_line), .split_i(md.split));

  // ================= AG =================
  // A replay takes the AG slot when the LD port has nothing in EX: each thread's oldest ready load, the threads
  // taking turns when both have one (D8; both picks are formed, the thread selects last)
  logic [LQ_ENTRIES-1:0] rp_ready;
  for (genvar i = 0; i < LQ_ENTRIES; i++) begin : g_rpr
    assign rp_ready[i] = lq_v_q[i] && lq_st_q[i] == L_READY;
  end
  logic             rp_any;
  logic [LIW-1:0]   rp_idx;
  logic [NT-1:0][LIW-1:0] rp_it;                  // each thread's oldest ready load
  logic [NT-1:0]    rp_at;                        // ... it has one
  tid_t             rp_t;                         // the thread served
  logic             rp_turn_q;                    // both have one: thread 1's turn
  always_comb
    for (int t = 0; t < NT; t++) begin
      rp_it[t] = lq_oldest_c(rp_ready & lq_ot[t], lqi(lq_head_q[t]));
      rp_at[t] = |(rp_ready & lq_ot[t]);
    end
  assign rp_t   = (NT > 1) ? tid_t'(rp_at[NT-1] && (!rp_at[0] || rp_turn_q)) : tid_t'(0);
  assign rp_any = |rp_ready;
  assign rp_idx = rp_it[rp_t];

  // ---- DTLB: LD port, STA port, the ROB head ----
  // the ROB head's check takes one port (#9 on, ROB_HEAD_TLB_LATE) or two (off)
  localparam int DT_NR = ROB_HEAD_TLB_LATE ? 3 : 4;
  logic [DT_NR-1:0][26:0] dt_vpn;
  logic [DT_NR-1:0]       dt_hit;
  tlb_pte_t [DT_NR-1:0]   dt_pte;
  logic             dt_fill;
  logic [26:0]      pw_vpn;
  logic [1:0]       pw_lvl;
  tlb_pte_t         pw_pte;
  logic [63:0]      hd_va;
  // The stage that translates, checks and decides for a new load (ln_*) and a store address
  // (sn_*): AG on its own signals, or with the address-stage split (DR-140 #4, LSU_AG_SPLIT;
  // core-lsu.md) M1, a cycle after AG, on registers. g_split / g_nosplit (below) drive these.
  logic        ln_v, sn_v;
  logic [63:0] ln_va, sn_va;
  robid_t      ln_rob, sn_rob;
  logic [1:0]  ln_size, sn_size;
  logic [SIW-1:0] sn_sq;
  tid_t           sn_t;                          // ... its thread, from its payload (its SQ entry's: asserted)
  logic        s2_v_q, s2_go, s2_den;            // S2: a store's PMP check, the cycle after it decides (STA)
  logic [SIW-1:0] s2_idx_q;
  // Three lookups: the LD port, the STA port, and the ROB head's check. The head's check has a
  // port of its own (timing: on a shared port the head VA and the store's address reached each
  // other's checks, paths that are never live together), and still counts only when STA is
  // idle, as when it shared STA's port.
  assign dt_vpn[0] = ln_va[38:12];
  assign dt_vpn[1] = sn_va[38:12];
  // (the head's ports: g_hd_late / g_hd_two, with the head's check below)
  // With the split, the LD and STA lookups read and match the CAM a cycle ahead, at AG, on the
  // addresses M1 registers (tg_tlb's EARLY ports: the same answer, from flip-flops in M1)
  logic [DT_NR-1:0][26:0] dt_vpn_e;
  always_comb begin
    dt_vpn_e    = '0;
    dt_vpn_e[0] = ld_ag_addr[38:12];
    dt_vpn_e[1] = sta_ag_addr[38:12];
  end
  // Each lookup's thread (M7's step 4): a load's or a store's, its queue entry's half; the head's, the ROB's commit
  // thread (t_hd). Each access translates and checks with its thread's privilege, SUM, MXR, satp and PMP: the deciding
  // load's (t_ln) and store's (t_sn), the head's, the load checker's load's (t_lck), the store checker's user's
  // (t_pst), the walk's (in tg_ptw)
  tid_t [DT_NR-1:0] dt_tid;                       // (driven below ln_lq's declaration)
  tid_t             t_ln, t_sn;
  tid_t             pw_dtid;                      // the walk's thread (the fills')
  logic [NT-1:0]    xl_t;                         // each thread's data accesses translate
  logic             xl_l, xl_s;                   // ... the deciding load's, the deciding store's
  assign t_ln = dt_tid[0];
  assign t_sn = dt_tid[1];
  always_comb for (int t = 0; t < NT; t++) xl_t[t] = EXT_SU && satp_sv39[t] && priv_d[t] != PRIV_M;
  assign xl_l = xl_t[t_ln];
  assign xl_s = xl_t[t_sn];
  tg_tlb #(.NE(DTLB_ENTRIES), .NR(DT_NR), .CAM(1'b1), .EARLY(LSU_AG_SPLIT ? DT_NR'(3) : DT_NR'(0))) u_dtlb (
    .clk, .rst, .vpn(dt_vpn), .vpn_e(dt_vpn_e), .lk_tid(dt_tid), .hit(dt_hit), .pte(dt_pte), .fill(dt_fill),
    .fill_vpn(pw_vpn), .fill_lvl(pw_lvl), .fill_pte(pw_pte), .fill_tid(pw_dtid), .flush(tlb_flush),
    .flush_tid(tlb_flush_tid));

  // ---- New load from the LD port: translate and check (replays reuse the LQ's PA) ----
  // A translated access to a PMP-homogeneous page uses the DTLB's cached PMP result (plan
  // §4.10) where it decides; bare-mode accesses and pages with a region boundary inside use the
  // checker, which runs on the registered PA after the decision (M1, or M2 with the split:
  // g_split / g_nosplit). A denial it finds faults the load in M2 (an MMIO load: L_MMIO -> L_EXC,
  // its issue held until then).
  logic [PA_W-1:0] nl_pa;
  logic        nl_mis, nl_pf, nl_tm, nl_acc, nl_mmio, nl_exc, nl_go, nl_pmpc, nl_pmpd;
  logic        nl_lpc, lpc_r;                     // #13: an untranslated S/U load's region cached (g_lpc); its read verdict
  logic        lps_hit, lps_r, lps_w;             // ... the deciding store's (sn_va), and its read and write verdicts
  logic [0:0]  nl_chk;
  logic [PA_W-1:0] lck_pa;                        // the checker's access: a registered PA and size
  logic        lck_dbl;
  tid_t        t_lck;                             // ... and its load's thread
  logic        ck_ms, ck_ml;                      // M-mode (the data privilege's) for the checkers: the store at its
                                                  // decision, the load in its check (registered with the split: below)
  logic        mm_hold_p;                         // the head's MMIO issue held by the profile's check (below)
  logic        lmc_v;                             // DR-183 (PMP_FILL): a parked MMIO load's check this cycle ...
  logic [LIW-1:0] lmc_lq;                         // ... its entry
  logic        m1_rck_q, m2_rck_q;                // DR-183 (PMP_FILL): a replay with its check pending, in M1, M2
  logic        mh_req, mh_gnt;                    // ... the head's MMIO load asks the checker; granted
  logic        l_den, lm_den, mm_hold;            // denied: the load in M2; an MMIO load (check only); the head's
  logic        lm_st;                             // ... MMIO issue held; the denied MMIO load's state write,
  logic [LIW-1:0] lm_lq;                          // ... and its LQ entry
  pma_e        nl_pma;
  assign nl_pa   = xl_l ? {dt_pte[0].ppn, ln_va[11:0]} : ln_va[PA_W-1:0];
  assign nl_mis  = misal(ln_va[2:0], ln_size);
  assign nl_pf   = xl_l && !nl_mis && !va_canon(ln_va);
  assign nl_tm   = xl_l && !nl_mis && !nl_pf &&
                   !(dt_hit[0] && pte_ok(dt_pte[0], ACC_R, priv_d[t_ln], sum[t_ln], mxr[t_ln]));
  // The region class of both PAs, picked by xl_l last (timing: the translated PA's class does not
  // wait for the mode's select)
  assign nl_pma  = xl_l ? pma_of({dt_pte[0].ppn, ln_va[11:0]}) : pma_of(ln_va[PA_W-1:0]);
  logic       pmp_hit_ld, pmp_hit_st;
  logic [2:0] pmp_rwx_ld, pmp_rwx_st;
  // DR-183 (PMP_FILL): no load checker; the shared one (u_pmp_st) checks a load in a cycle it grants it (l_gnt)
  logic l_ask, l_gnt, l_nok;     // a load (or a parked MMIO load) asks the checker; granted; an M2 load unchecked
  logic [0:0] sa_chk;
  // #13 (DR-191; spikes §8.18, fix 1): the shared checker's answer, registered every cycle (below, after fetch's
  // response): with LSU_CHK_REG (CKR) each user takes it the cycle after its grant, so no path runs from the checker's
  // compare into the LQ, the SQ's decision or the walker. A bare store checks in S2 instead of at its decision; the
  // head's MMIO load and the walker take the answer a cycle later; a load's (core-2's side) likewise
  localparam bit CKR = PMP_FILL && LSU_CHK_REG;
  logic       ck_ok_q, ck_hit_q, ck_nh_q;
  logic [2:0] ck_rwx_q;
  // #13, the loads' side (fix 1; with the split): a load or MMIO load granted its check in M2 takes ck_ok_q the cycle
  // after (lg_*): a load that would complete waits that cycle in the hold (ch_*, integer results) and then takes the
  // result register first, a denied one goes to L_EXC and reports then (g_ckld, below M2)
  localparam bit CK_LD = PMP_FILL && LSU_CHK_REG && LSU_AG_SPLIT;
  logic           m2_ck, m2_mck;                  // M2's load checks this cycle; M2's parked MMIO load does (g_split)
  typedef enum logic [1:0] { LG_HOLD, LG_RDY, LG_KEEP, LG_MMIO } lg_e;
  logic           lg_v_q, lg_den, ch_take;
  lg_e            lg_k_q;
  logic [LIW-1:0] lg_lq_q;
  tid_t           lg_t_q;
  robid_t         lg_rob_q;
  logic           ch_dv_q;                        // the hold's result: its write, register, data, LLT
  logic [LDW-1:0] ch_dst_q;
  logic [63:0]    ch_data_q;
  llt_t           ch_llt_q;
  if (!PMP_FILL) begin : g_pmp_ld
    tg_pmp #(.S(1)) u_pmp_ld (.pa(lck_pa), .dbl(lck_dbl), .acc(ACC_R),
                              .m_mode(ck_ml), .d(pmp_d[t_lck]), .ok(nl_chk), .hit(pmp_hit_ld),
                              .rwx(pmp_rwx_ld));
  end else begin : g_pmp_ldf
    assign nl_chk     = sa_chk;
    assign pmp_hit_ld = 1'b0;
    assign pmp_rwx_ld = '0;
  end
  assign nl_pmpc = (xl_l && dt_pte[0].ph) || nl_lpc;   // a cached result applies: the DTLB's, or bare the region's
  // ... else the checker decides, later; with PMP_FILL not M-mode while its hart has no locked entry (DR-183)
  assign nl_pmpd = !nl_pmpc && !(PMP_FILL && priv_d[t_ln] == PRIV_M && !pmp_lk_h[t_ln]);
  assign nl_acc  = (xl_l ? dt_pte[0].big : ln_va[63:PA_W] != '0) || nl_pma == PMA_NONE ||
                   (nl_pmpc && !(xl_l ? dt_pte[0].pr : lpc_r));
  assign nl_mmio = nl_pma == PMA_DEVICE || nl_pma == PMA_ROM;
  assign nl_exc  = nl_mis || nl_pf || (!nl_tm && nl_acc);
  assign nl_go   = !nl_exc && !nl_tm && !nl_mmio;

  // The AG slot: the LD port, else a PTE read, else an LQ replay
  logic              pt_req, pt_gnt;
  logic [PA_W-1:0]   pt_pa;
  logic              ag_v, ag_rp, ag_pt;
  logic [LIW-1:0]    ag_lq;
  logic [PA_W-1:0]   ag_pa;
  logic              ag_go;
  logic fh_hole_ag;      // the AG slot stays empty this cycle: a held FP load's M2 bubble (FH_HOLE, below)
  assign ag_pt   = !ld_ag_valid && pt_req && !kill_t[pw_dtid] && !fh_hole_ag;
  assign ag_rp   = !ld_ag_valid && !pt_req && rp_any && !kill_t[rp_t] && !fh_hole_ag;
  assign ag_v    = (ld_ag_valid && !kill_t[t_ldag]) || ag_pt || ag_rp;
  assign ag_lq   = ld_ag_valid ? ld_ag_pl.lq[LIW-1:0] : rp_idx;
  tid_t ag_t;                                        // ... its thread: the payload's, or the replay's (rp_t)
  assign ag_t    = ld_ag_valid ? ld_ag_pl.tid : rp_t;
  // ag_pa and ag_go (it continues to M1) depend on where a new load decides: g_split / g_nosplit
  assign pt_gnt  = ag_pt;
  // The D$ reads for every AG op, whether or not it goes on to M1 (timing: ag_go waits for the new
  // load's TLB, PMP and fault decision). Only M1 of the op that read uses port A's data, and M1
  // and M2 never hold, so a read for an op that stops is never seen.
  assign dc_rd_en = ag_v;
  assign dc_rd_pa = ag_pa;

  // A store write to the same 16-byte row in the AG cycle: the load read old data (m1_clash, from
  // g_split / g_nosplit)

  // ================= M1 =================
  logic              m1_v_q, m1_pt_q;
  logic [LIW-1:0]    m1_lq_q;
  tid_t              m1_t_q;                         // M1's load's thread: AG's, carried (its LQ entry's: asserted)
  logic [PA_W-1:0]   m1_pa_q;
  logic [PA_W-1:0]   m1pa;                           // M1's PA (with the split: a new load's from the DTLB)
  logic              m1_clash, m1_go;                // the AG row clash; M1 goes on to M2
  logic [LIW-1:0]    ln_lq;                          // a new load's LQ entry where it decides
  logic [LIW-1:0]    ln_lqw;                         // ... as its LQ flip-flops are written (no split: AG's index)
  always_comb begin                                  // the DTLB lookups' threads (above)
    for (int r = 0; r < DT_NR; r++) dt_tid[r] = t_hd;
    dt_tid[0] = LSU_AG_SPLIT ? m1_t_q : ld_ag_pl.tid;   // ln_lq's thread: M1's (split), else AG's payload's
    dt_tid[1] = sn_t;
  end
  // M1's thread (and M2's, t_m2): a load's, its LQ entry's; a PTE read's, the walk's (which lasts while its read is
  // in the pipe: a flush of its thread kills both)
  tid_t              t_m1;
  assign t_m1 = m1_pt_q ? pw_dtid : m1_t_q;
  assign m1_pa    = m1pa;
  logic [7:0]        m1_mask;
  assign m1_mask = bmask(m1pa[2:0], lq_size_q[m1_lq_q]);

  // Youngest older store with a byte overlap in the same dword: the search over the SQ's stores
  // (q_*), and with the split, the store address in M1 selected last (g_split / g_nosplit). The
  // stores are the load's thread's (t_m1: its entries, from its SQ head)
  logic              f_hit, f_cover, f_data;
  logic [SQ_ENTRIES-1:0] f_oh;                      // the forwarding store, one-hot (encoded in M2)
  sqid_t                 f_lim;                     // the stores in [head, f_lim) are older
  logic [SQ_ENTRIES-1:0] fc_sq;                     // overlapping older stores in the SQ
  logic              q_hit, q_cover, q_data;        // ... any; the youngest covers; its data is there
  logic [SQ_ENTRIES-1:0] q_oh;                      // ... the youngest, one-hot
  assign f_lim = lq_sq_q[m1_lq_q];
  // A store's terms that do not wait for the load's translation (its state, the window, the byte
  // overlap) go into the PA compare as one more bit, so the compare's carry chain can end in the
  // candidate bit itself (timing: core-2's form for lq_oldest_c)
  always_comb begin
    for (int i = 0; i < SQ_ENTRIES; i++) begin
      logic early;
      early    = sq_v_q[i] && sq_ot[t_m1][i] && sq_av_q[i] && !sq_mmio_q[i] && !sq_amo_q[i] &&
                 sq_inwin(i, sq_head_q[t_m1], f_lim) && |(sq_mask_q[i] & m1_mask);
      fc_sq[i] = {sq_pa_q[i][PA_W-1:3], early} == {m1pa[PA_W-1:3], 1'b1};
    end
  end
  // The youngest goes to M2 as a one-hot vector, encoded there (timing: no index encode or
  // multiplexer after the search). The youngest is the highest candidate below f_lim's slot, else
  // the highest of all: the highest set bit of {below, all}, found by carry chain on the reversed
  // vector (y & -y, as lq_oldest_c) and folded over the halves, so no running OR along the queue.
  // Its cover and data-valid bits need no one-hot: w's highest set bit lies in w & b, for the
  // per-entry bits b, exactly when (w & b) > (w & ~b), the two being disjoint; a compare is one
  // carry chain (timing: no OR over the one-hot after the search).
  logic [SQ_ENTRIES-1:0] fc_lo;                     // the candidates below f_lim's slot
  logic [2*SQ_ENTRIES-1:0] fc_w;                    // {below, all}: the youngest is its highest bit
  logic [SQ_ENTRIES-1:0] cov;                       // per store: its bytes cover the load's
  always_comb for (int i = 0; i < SQ_ENTRIES; i++) cov[i] = (sq_mask_q[i] & m1_mask) == m1_mask;
  always_comb begin
    logic [2*SQ_ENTRIES-1:0] w, y, ly;
    for (int i = 0; i < SQ_ENTRIES; i++) fc_lo[i] = fc_sq[i] && i < int'(f_lim[SIW-1:0]);
    w  = {fc_lo, fc_sq};
    fc_w = w;
    for (int i = 0; i < 2 * SQ_ENTRIES; i++) y[i] = w[2 * SQ_ENTRIES - 1 - i];
    ly = y & -y;
    for (int i = 0; i < SQ_ENTRIES; i++)
      q_oh[i] = ly[2 * SQ_ENTRIES - 1 - i] | ly[SQ_ENTRIES - 1 - i];
    q_hit   = |fc_sq;
    q_cover = (w & {cov, cov}) > (w & ~{cov, cov});
    q_data  = (w & {sq_dv_q, sq_dv_q}) > (w & ~{sq_dv_q, sq_dv_q});
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst)
      assert (q_cover == |(q_oh & cov) && q_data == |(q_oh & sq_dv_q))
        else $error("tg_lsu: the forwarding compare differs from the youngest's bits");
  end
`endif


  // ================= M2 =================
  logic              m2_v_q, m2_clash_q, m2_hit_q, m2_fhit_q, m2_fcov_q, m2_fdat_q, m2_pt_q;
  logic [LIW-1:0]    m2_lq_q;
  tid_t              m2_t_q;                         // M2's load's thread, carried from M1
  logic              m2_m_q;                         // ... its data privilege is M (the split's check, ck_ml)
  logic              ma3_v_q, ma4_v_q;           // DR-149: a load's miss, carried to the D$'s answer
  logic [LIW-1:0]    ma3_lq_q, ma4_lq_q;
  logic [PA_W-1:0]   m2_pa_q;
  logic [63:0]       m2_dword_q, m2_fdword;
  logic [SQ_ENTRIES-1:0] m2_foh_q;                  // the forwarding store, one-hot
  logic [SIW-1:0]    m2_fidx;                       // ... its index
  tid_t              t_m2;                          // M2's thread (as t_m1)
  assign t_m2 = m2_pt_q ? pw_dtid : m2_t_q;
  always_comb begin
    m2_fidx = '0;
    for (int i = 0; i < SQ_ENTRIES; i++) if (m2_foh_q[i]) m2_fidx |= SIW'(i);
  end
  sqid_t             m2_fid;
  assign m2_fid = sq_id(int'(m2_fidx), sq_head_q[t_m2]);
  // The forwarded data, read in M2 at the forwarding store's index (timing: the M1 search ends at
  // m2_foh_q). Data that was in at M1 (m2_fdat_q) does not change; data captured since is not used.
  assign sqsz_ra[TRP] = m2_fidx;
  assign m2_fdword = rep(sqd_rd[TRP], sqsz_rd[TRP]);   // LUTRAM reads at m2_fidx

  typedef enum logic [2:0] { O_OK, O_STQ, O_MISS, O_RETRY, O_FAULT, O_HOLD } m2_out_e;
  m2_out_e   m2_out, m2_out_w;                      // the outcome; ... before the PMP checker's verdict
  logic [63:0] m2_val;
  always_comb begin
    logic [63:0] dw;
    m2_out_w = O_OK;
    dw = m2_dword_q;
    if (m2_fhit_q) begin
      if (m2_fcov_q && m2_fdat_q) dw = m2_fdword;
      else                        m2_out_w = O_STQ;
    end else if (m2_clash_q) begin
      m2_out_w = O_RETRY;
    end else if (!m2_hit_q) begin
      m2_out_w = lm_fdn ? O_FAULT : O_MISS;   // (lm_pa is m2_pa_q: its line's last fill was denied)
    end
    m2_val = ext_al(dw, m2_pa_q[2:0], lq_size_q[m2_lq_q], lqc_rd[0].uns);
  end
  // a PMP denial found after the decision: first. DR-183 (PMP_FILL): a load whose check found the shared checker
  // taken does not complete, and replays with its check pending; one that would not complete keeps its outcome
  // #13 (CK_LD): a granted checked load completes nothing in M2 (O_HOLD: it waits a cycle for its verdict, in the
  // hold or its entry); M2's load yields the result register to the hold's take and port 1 to its denial (O_RETRY)
  m2_out_e   m2_out_ck;
  always_comb begin
    m2_out_ck = m2_out_w;
    if (m2_out_w == O_FAULT)                         m2_out_ck = lg_den ? O_RETRY : O_FAULT;
    else if (m2_out_w == O_OK || m2_out_w == O_RETRY) begin
      if (m2_ck)                                     m2_out_ck = l_gnt ? O_HOLD : O_RETRY;
      else if (ch_take && m2_out_w == O_OK)          m2_out_ck = O_RETRY;
    end
  end
  assign m2_out = CK_LD ? m2_out_ck : l_den ? O_FAULT : (l_nok && m2_out_w == O_OK) ? O_RETRY : m2_out_w;
  // PTE reads: the cache's dword (no forwarding: the deciding walk runs with the SQ drained)
  logic m2_ok, pt_rsp, pt_hit, pt_den;
  assign pt_rsp = m2_v_q && m2_pt_q && !kill_t[t_m2];
  assign pt_hit = m2_hit_q && !m2_clash_q;
  assign pt_den = !m2_hit_q && lm_fdn;
  // The wakeups do not wait for the PMP checker (m2_okw): a load it denies faults, and the dependents
  // it woke read a stale value and go with the trap's flush (the flush frees its LLT)
  logic m2_okw;
  // (m2_out_w == O_OK, written out: the denied-line compare only chooses between two outcomes that
  // are not O_OK, so it stays off the wakeup path)
  assign m2_okw = m2_v_q && !m2_pt_q && !kill_t[t_m2] && !(CK_LD ? m2_ck || ch_take : l_nok) &&
                  (m2_fhit_q ? m2_fcov_q && m2_fdat_q : !m2_clash_q && m2_hit_q);
  assign m2_ok  = m2_okw && !l_den;
  if (CK_LD) begin : g_ckld
    // A check granted in M2 (a load going on, or a parked MMIO load's), its kind for the verdict next cycle: a load
    // that would complete with an integer result (or none) waits in the hold, one that would complete an FP result or
    // met a clash replays (L_READY: P4's bank and the clash wait for a new pass), one that misses or waits for a store
    // keeps its state, and an MMIO load stays parked; each goes to L_EXC instead if the checker denied it
    always_ff @(posedge clk) begin
      lg_v_q    <= !rst && !kill_t[t_m2] && l_gnt && (m2_mck || (m2_ck && m2_v_q && !m2_pt_q && m2_out_w != O_FAULT));
      lg_k_q    <= m2_mck ? LG_MMIO : (m2_out_w == O_MISS || m2_out_w == O_STQ) ? LG_KEEP :
                   (m2_out_w == O_OK && !(lqc_rd[0].dv && lqc_rd[0].fp)) ? LG_HOLD : LG_RDY;
      lg_lq_q   <= m2_lq_q;
      lg_t_q    <= t_m2;
      lg_rob_q  <= lqc_rd[0].rob;
      ch_dv_q   <= lqc_rd[0].dv;
      ch_dst_q  <= lqc_rd[0].dst;
      ch_data_q <= m2_val;
      ch_llt_q  <= lqc_rd[0].llt;
    end
    assign ch_take = lg_v_q && lg_k_q == LG_HOLD && ck_ok_q && !kill_t[lg_t_q];
    assign lg_den  = lg_v_q && !ck_ok_q && !kill_t[lg_t_q];
    if (LPC_N > 0) begin : g_lpc
      // The bare-mode region cache: the verdicts of LPC_N 2 MiB regions for untranslated S/U loads, as the DTLB caches
      // a translated page's (a checked load completes a cycle late, and its dependants miss SPEC_WAKE's M2 bypass: a
      // bare pointer chase ran 2x slower). A granted load's check fills an entry when no region boundary lies inside
      // its region (the page test at level 1, ck_nh_q) and the access was S/U's: the deciding entry's read permission,
      // hit ? r : 0. A new load whose region hits needs no check: it completes in M2, or faults at M1. A TLB flush of
      // the hart (PMP, satp or SFENCE.VMA writes) empties its entries and drops a fill in the same cycle; round robin
      localparam int LW = (LPC_N > 1) ? $clog2(LPC_N) : 1;
      logic [LPC_N-1:0]            lv_q, lr_q, lw_q;
      tid_t [LPC_N-1:0]            lt_q;
      logic [LPC_N-1:0][PA_W-22:0] lrg_q;
      logic [LW-1:0]               lrr_q;
      logic [PA_W-22:0]            lg_rg_q;      // the granted load's region and S/U-ness, with lg_*
      logic                        lg_m_q;
      logic [LPC_N-1:0]            lph, lpf, lps;  // M1's new load's region hits; the fill's is there already; the store's
      logic                        fill;
      always_ff @(posedge clk) begin
        lg_rg_q <= lck_pa[PA_W-1:21];
        lg_m_q  <= ck_ml;
      end
      always_comb
        for (int i = 0; i < LPC_N; i++) begin
          lph[i] = lv_q[i] && lt_q[i] == t_ln && lrg_q[i] == ln_va[PA_W-1:21];
          lpf[i] = lv_q[i] && lt_q[i] == lg_t_q && lrg_q[i] == lg_rg_q;
          lps[i] = lv_q[i] && lt_q[i] == t_sn && lrg_q[i] == sn_va[PA_W-1:21];
        end
      assign nl_lpc = !xl_l && priv_d[t_ln] != PRIV_M && |lph;
      assign lpc_r  = |(lph & lr_q);
      // (a store's decision, for soc-2's side: an untranslated S/U store whose region is cached decides with its R and W)
      assign lps_hit = !xl_s && priv_d[t_sn] != PRIV_M && |lps;
      assign lps_r   = |(lps & lr_q);
      assign lps_w   = |(lps & lw_q);
      assign fill   = lg_v_q && lg_k_q != LG_MMIO && !kill_t[lg_t_q] && !lg_m_q && !ck_nh_q && !(|lpf) &&
                      !(tlb_flush && (NT == 1 || lg_t_q == tlb_flush_tid));
      always_ff @(posedge clk) begin
        if (rst) begin
          lv_q  <= '0;
          lrr_q <= '0;
        end else begin
          if (fill) begin
            lv_q[lrr_q]  <= 1'b1;
            lt_q[lrr_q]  <= lg_t_q;
            lrg_q[lrr_q] <= lg_rg_q;
            lr_q[lrr_q]  <= ck_hit_q && ck_rwx_q[2];
            lw_q[lrr_q]  <= ck_hit_q && ck_rwx_q[1];
            lrr_q        <= (int'(lrr_q) == LPC_N - 1) ? '0 : lrr_q + 1'b1;
          end
          if (tlb_flush)
            for (int i = 0; i < LPC_N; i++) if (NT == 1 || lt_q[i] == tlb_flush_tid) lv_q[i] <= 1'b0;
        end
      end
    end else begin : g_nolpc
      assign nl_lpc  = 1'b0;
      assign lpc_r   = 1'b0;
      assign lps_hit = 1'b0;
      assign lps_r   = 1'b0;
      assign lps_w   = 1'b0;
    end
`ifndef SYNTHESIS
    // +chkstat: the verdicts taken a cycle late, by kind, the held loads' takes and the denials
    bit ck_on;
    initial ck_on = $test$plusargs("chkstat");
    longint unsigned ck_n [4];
    longint unsigned ck_n_take, ck_n_den;
    always_ff @(posedge clk)
      if (rst) begin
        ck_n <= '{default: 0}; ck_n_take <= 0; ck_n_den <= 0;
      end else if (lg_v_q && !kill_t[lg_t_q]) begin
        ck_n[lg_k_q] <= ck_n[lg_k_q] + 1;
        ck_n_take    <= ck_n_take + (ch_take ? 1 : 0);
        ck_n_den     <= ck_n_den + (lg_den ? 1 : 0);
      end
    final if (ck_on)
      $fwrite(32'h8000_0002, "TG-CHK %m: verdicts held %0d (taken %0d), to replay %0d, kept %0d, MMIO %0d; denied %0d\n",
              ck_n[LG_HOLD], ck_n_take, ck_n[LG_RDY], ck_n[LG_KEEP], ck_n[LG_MMIO], ck_n_den);
`endif
  end else begin : g_nockld
    assign lg_v_q    = 1'b0;
    assign lg_k_q    = LG_HOLD;
    assign lg_lq_q   = '0;
    assign lg_t_q    = '0;
    assign lg_rob_q  = '0;
    assign ch_dv_q   = 1'b0;
    assign ch_dst_q  = '0;
    assign ch_data_q = '0;
    assign ch_llt_q  = '0;
    assign ch_take   = 1'b0;
    assign lg_den    = 1'b0;
    assign nl_lpc    = 1'b0;
    assign lpc_r     = 1'b0;
    assign lps_hit   = 1'b0;
    assign lps_r     = 1'b0;
    assign lps_w     = 1'b0;
    logic unused_mck;                             // (the parked MMIO load's check: CK_LD's)
    assign unused_mck = m2_mck;
  end
  // FP banks of 64 with renaming across both (DR-179): each FP bank has one write port, and P4's stream takes it in
  // priority (its pipelines cannot hold). An FP load completing in M2 whose write (next cycle) meets P4's announced
  // write in its bank is held: its result waits in fh_* (below) with no wakeup and no completion, and takes the
  // result register in a later cycle, when M2 does not and P4 leaves its bank, a cycle it makes for itself
  // (FH_HOLE, below); its LLT wakes then, as an MMIO response's. A second one while fh holds one retries. The terms
  // reach the FP load's own wakeup, its result and its LQ state, not M2's outcome or the integer paths (ld_m2_will,
  // the miss request).
  logic m2_fcol, m2_fhold, m2_fretry;
  logic fh_v_q;
  logic fk_hold;          // a phantom P4 write in every bank next cycle (the hold's test mode, below)
`ifdef SYNTHESIS
  assign fk_hold = 1'b0;
`else
  // Simulation only: +fhold_pct=N treats N% of the cycles as P4 writing every bank next cycle, so FP loads are held,
  // taken and retried with or without real collisions (none before rename crosses). Not while IQ-FP's select is
  // blocked (fp_block, below), as P4 then empties. Its own xorshift32 sequence: the testbench's $urandom stays as it
  // was
  bit          fk_on;
  int unsigned fk_pct;
  logic [31:0] fk_r_q;
  initial fk_on = $value$plusargs("fhold_pct=%d", fk_pct);
  assign fk_hold = fk_on && !rst && !fp_block && fk_r_q % 100 < fk_pct;
  always_ff @(posedge clk) begin
    logic [31:0] y;
    y = fk_r_q ^ (fk_r_q << 13);
    y = y ^ (y >> 17);
    fk_r_q <= rst ? 32'h6a09_e667 : y ^ (y << 5);
  end
`endif
  assign m2_fcol   = EXT_FD && lqc_rd[0].dv && lqc_rd[0].fp &&
                     ((p4_nx_we && p4_nx_bank == lqc_rd[0].fb) || fk_hold);
  assign m2_fhold  = m2_fcol && !fh_v_q;
  assign m2_fretry = m2_fcol && fh_v_q;
  // The miss request does not wait for the PMP checker either (timing: it feeds the D$'s port
  // arbitration): a load it denies faults, and only the line's refill may go ahead, a cacheable
  // line (device and unmapped addresses never reach M2's miss), its data written to no register
  assign lm_req = m2_v_q && !kill_t[t_m2] && (m2_pt_q ? !m2_hit_q && !m2_clash_q && !pt_den : m2_out_w == O_MISS);
  assign lm_pa  = m2_pa_q;
  assign ld_m2_will  = m2_okw && lqc_rd[0].dv && !lqc_rd[0].fp;
  assign ld_m2_miss  = m2_v_q && !m2_pt_q && !m2_fhit_q && !m2_clash_q && !m2_hit_q;
  assign ld_m2_dst   = PIDX_W'(lqc_rd[0].dst);
  assign fld_m2_will = EXT_FD && m2_okw && lqc_rd[0].dv && lqc_rd[0].fp && !m2_fcol;
  assign fld_m2_bank = lqc_rd[0].fb;
  assign fld_m2_idx  = FPIDX_W'(lqc_rd[0].dst);

  // ================= MMIO =================
  typedef enum logic [1:0] { X_IDLE, X_REQ, X_WAIT } xstate_e;
  xstate_e         xs_q;
  logic            x_st_q;                 // the request is a store (from the drain)
  logic            x_kill_q;               // a load request whose load was flushed
  logic [LIW-1:0]  x_lq_q;
  logic [PA_W-1:0] x_pa_q;
  tid_t            x_t_q;                  // the access's thread: with hart 1 its hart is the request's source
  logic [1:0]      x_size_q;
  logic [63:0]     x_wdata_q;
  logic            xr_v_q;                 // a load response waits for the result register
  logic [63:0]     xr_data_q;
  logic            xd_q;                   // ... and has completed, until a load retires
  logic [NT-1:0]   am_v_q;                 // an atomic is in the thread's window
  tid_t            x_t;                    // the MMIO load's thread (its LQ entry's)
  assign x_t = lq_tid(int'(x_lq_q), md);
  // An interrupt must not separate an MMIO load or an atomic from its commit (side effects): the head thread's
  assign mmio_busy = (((xs_q != X_IDLE && !x_st_q) || xr_v_q || xd_q) && x_t == t_hd) || am_v_q[t_hd];

  // MMIO load: the head thread's ROB head, its committed stores drained, the port free. A load at its thread's ROB
  // head is the oldest in its window, so it is that thread's LQ head (hl); the threads take turns with the ROB's
  // commit thread (t_hd). It does not issue in a cycle in which the ROB takes an interrupt (DR-176): mmio_busy rises
  // only the cycle after the issue, so in the issue's cycle the ROB could take the interrupt and flush the load with
  // its request already out; the load then ran again after the trap, and a read with a side effect happened twice
  // (SD1's lost interrupt on the board: a PLIC claim read twice, the first claim's source never completed). The ROB
  // takes the interrupt first, and the load issues once, after the trap. The gate is the ROB's decision itself (for
  // its commit thread, the head thread), not a pending interrupt, so the load never waits on one the ROB cannot take
  // (its trace back-pressure, or one hart's interrupt at the other hart's head).
  logic            mm_go, mm_cand;
  logic [LIW-1:0]  mm_idx;
  robid_t          hd_rob;                 // the head thread's ROB head
  assign hd_rob  = rob_head[t_hd];
  assign mm_idx  = hl;
  assign mm_cand = lq_v_q[hl] && lq_st_q[hl] == L_MMIO && lqc_rd[2].rob == hd_rob;
  // DR-183 (PMP_FILL): the head's MMIO load whose check found the shared checker taken waits for it (mm_hold) and
  // asks again, with its thread's descriptors and privilege, while the MMIO port, and so its exception report, is
  // free (the DR-176 gate in mm_go stays as it is)
  assign mm_hold = mm_hold_p || (PMP_FILL && lq_pck_q[hl]);

  // Drain: the SQ head once committed. The head ports (the drain, an MMIO store, an atomic) read one thread's head,
  // t_dr_q's (D8): the threads take turns a cycle at a time when both want it (a committed store, or an atomic as their
  // next entry), except while the head is in use over cycles (an MMIO store from its start to its pop, an atomic from
  // its start to the flush after its commit). In merged mode it is the running thread's (dr_sw, with the atomics).
  tid_t           t_dr_q, t_dro;           // the drain's thread; the other
  logic [NT-1:0]  dr_want;                 // a thread wants the head
  logic           dr_hold, dr_sw;          // the head is in use; the drain's thread changes next cycle
  logic [SIW-1:0] dh;
  assign t_dro = (NT > 1) ? ~t_dr_q : t_dr_q;
  logic [NT-1:0]  fpc_t;                   // (with hart 1) each thread's forward-progress claim on a line (below)
  assign dh = sq_head_q[t_dr_q][SIW-1:0];
  logic dr_v, dr_amo;
  assign dr_v   = sq_v_q[dh] && sq_head_q[t_dr_q] != sq_cmt_q[t_dr_q];
  assign dr_amo = dr_v && sq_amo_q[dh];      // performed before commit: leaves without a write
  logic dr_mmio_go;
  assign dr_mmio_go = dr_v && sq_mmio_q[dh] && xs_q == X_IDLE && !xr_v_q && !(HART1_ON && NT > 1 && fpc_t[t_dro]);
  // With hart 1 the other thread's MMIO load also waits for a completed one to retire (xd_q): the MMIO state is one
  // set, and its thread (x_t, from x_lq_q) says whose load holds back interrupts (mmio_busy) and when xd_q clears. A
  // second load issued over it took that over, so an interrupt could flush the first, completed but not retired, and
  // its read ran twice (verif-2's two-hart random programs, 10-21). With one thread the load waiting is its head's,
  // so none can be issued meanwhile
  assign mm_go = mm_cand && sq_drn[t_hd] && !dr_mmio_go && xs_q == X_IDLE && !xr_v_q && !(HART1_ON && NT > 1 && xd_q) &&
                 !kill_t[t_hd] && !mm_hold && !irq_go;
  assign st_req   = dr_v && !sq_mmio_q[dh] && !sq_amo_q[dh];
  assign st_pa    = sqh.pa;
  assign st_mask  = {8'b0, sqh.mask} << {sqh.pa[3], 3'b000};
  assign st_wdata = rep(sqd_rd[TRP+1], sqh.size);
  logic dr_pop;
  assign dr_pop = (st_req && st_ack) || dr_amo ||
                  (xs_q == X_WAIT && x_st_q && mmio_d_valid_i);

  always_comb begin
    mmio_a_o = '0;
    mmio_a_o.opcode  = x_st_q ? A_PUT_FULL : A_GET;
    mmio_a_o.size    = {1'b0, x_size_q};
    // the hart's index in the core (interfaces §2.4: a source per hart), 0 for a lone hart (also with SOLO_TID)
    mmio_a_o.source  = (HART1_ON && NT > 1) ? TL_SRC_W'(x_t_q ^ RUN_TID) : '0;
    mmio_a_o.address = x_pa_q;
    mmio_a_o.mask    = TL_MASK_W'({8'b0, bmask(x_pa_q[2:0], x_size_q)} << {x_pa_q[3], 3'b000});
    mmio_a_o.data    = {64'b0, x_wdata_q << {x_pa_q[2:0], 3'b000}} << {x_pa_q[3], 6'b000000};
    mmio_a_valid_o   = xs_q == X_REQ;
    mmio_d_ready_o   = 1'b1;
  end

  // ================= Result register (WB) =================
  // An FLW's word arrives zero-extended (FP loads take their bytes raw) and is NaN-boxed as the
  // register is written, so fld_data is the value P4 writes to F1 with no logic after the register.
  logic            r_v_q, r_dv_q, r_mmio_q;
  logic            r_fv_q;                    // the result writes an f register (EXT_FD) ...
  logic            r_fb_q;                    // ... in this bank
  logic [LDW-1:0]    r_dst_q;
  logic [63:0]     r_data_q;
  robid_t          r_rob_q;
  llt_t            r_llt_q;
  // With hart 1 (M7's step 5c) the reset sequence zeroes its homes in the load bank (x17-x31 at 0-14) and in F1
  // (f0-f31 at 0-31) through these write ports: the register holds zero from the reset to the first load, which
  // comes after rename starts (no multiplexer on the data)
  localparam bit IMT = HART1_ON && NUM_THREADS > 1;
  logic          r_init;
  assign r_init       = IMT && init_we;
  assign ld_res_valid = (r_v_q && r_dv_q && !r_fv_q) || (r_init && init_idx < 5'd15);
  assign fld_valid    = r_fv_q || (EXT_FD && r_init);
  assign fld_bank     = r_init || r_fb_q;          // (the reset's zeros: hart 1's homes in F1)
  assign fld_idx      = r_init ? FPIDX_W'(init_idx) : FPIDX_W'(r_dst_q);
  assign fld_data     = r_data_q;
  assign ld_res_dst   = r_init ? PIDX_W'(init_idx) : PIDX_W'(r_dst_q);
  assign ld_res_data  = r_data_q;
  assign ld_cmp_valid = r_v_q;
  assign ld_cmp_rob   = r_rob_q;
  assign ld_cmp_mmio  = r_mmio_q;
  always_comb begin
    llt_done = '0;
    if (r_v_q && r_dv_q) llt_done[r_llt_q] = 1'b1;
  end
  // An MMIO response takes the result register when M2 does not
  // The MMIO and atomic results take the result register when no M2 load completes, its PMP
  // verdict aside (m2_okw): a load the checker denies leaves the register empty that cycle, and
  // they take it the next (timing, DR-145: G6's load PMP checker -> the result take -> the
  // wakeup, -1.56 ns; a cycle only when one waits beside a PMP-denied load in M2)
  // An FP load's response (an FP load from a device) also waits while P4 writes its bank next cycle (DR-179), and
  // blocks IQ-FP's select meanwhile (fp_block, below)
  logic xr_take, xr_fcol;
  assign xr_fcol = FP_XBANK && lqc_rd[1].dv && lqc_rd[1].fp && ((p4_nx_we && p4_nx_bank == lqc_rd[1].fb) || fk_hold);
  assign xr_take = xr_v_q && !m2_okw && !ch_take && !kill_t[x_t] && !xr_fcol;
  // A held FP load's result (DR-179; M2 above): it takes the result register last, when nothing else does and P4
  // leaves its bank next cycle, so its write never meets P4's; a flush of its thread drops it
  tid_t            fh_tid_q;
  logic            fh_fb_q;
  logic [LDW-1:0]  fh_dst_q;
  logic [63:0]     fh_data_q;
  robid_t          fh_rob_q;
  llt_t            fh_llt_q;
  logic            fh_take;
  logic            fh_stay;                // fh holds its load into the next cycle (a failed take)
  logic [2:0]      fh_w_q;                 // fh's failed takes before this cycle (saturating)
  localparam logic [2:0] FH_LDB = 3'd7;    // IQ-LD's select is blocked after 8 (ld_block, below) ...
  localparam logic [2:0] FH_BLK = 3'd7;    // ... and IQ-FP's after 8 (fp_block)
  // A load entering fh makes its own slot (FH_HOLE). IQ-FP's select is blocked the cycle after the fill, so P4 writes
  // nothing 7 cycles on (fill+8; tg_fp_exec keeps FMISC results and divide claims out of that slot). IQ-LD's select is
  // blocked at fill+3 and the AG slot left empty at fill+5, so M2 completes nothing at fill+7. fh takes the result
  // register then and writes into P4's free slot: P4 loses one select a hold, not the 7 cycles of a drain (lone FP
  // restores -4.8% -> -0.7% against FP 96, core-2's RTL runs with crossing). The blocks after 8 failed takes stay for
  // a slot taken anyway (an MMIO or atomic result, a flush)
  localparam bit         FH_HOLE = FP_XBANK;

  // ================= Atomics =================
  // AM_IDLE -> (ROB head, address and data known, older stores drained) -> AM_REQ: the D$ holds
  // the line in T and reads and writes it in two cycles, or three with DC_AMO_READ_REG
  // (am_ack) -> AM_RES: rd through the result register -> AM_DONE until the flush that follows
  // its commit. An SC without a reservation for its line fails without touching memory.
  // Per thread (M7's step 4): each thread's atomic, serialised in its own window, has a slot (am_*_q[t]); the FSM
  // performs one at a time (the D$'s store port), starting the drain's thread's (am_t_q: the running one's thread).
  // Each hart has its reservation; a store or an atomic's write by one hart ends the other's on that line, as a
  // probe would (plan §6.2 rule 4).
  typedef enum logic [1:0] { AM_IDLE, AM_REQ, AM_RES, AM_DONE } amstate_e;
  amstate_e          am_st_q;
  // (DR-183, PMP_FILL: the head's MMIO check, above with mm_hold; here, after the atomics' state it reads.) Its
  // request is a register's, with its operands: the head qualifies one cycle (mh_ask) and asks the next (timing: the
  // head's compare with the ROB's head, through the LQ's LUTRAM read, had headed every path through the shared
  // checker, the chip's worst with the switch on; core-2 on spikes 8.18). A grant or its thread's flush ends the
  // request. The head stays while it asks (its pending check holds its issue: mm_hold), and its check stays pending
  // (a parked MMIO load takes no other check: asserted, so the request reads no LQ entry, which had put the LQ's
  // flags ahead of the checker's operand select: spikes-2, 10-23); the grant still needs the MMIO port, so its
  // exception report, free in its own cycle
  logic            mh_ask, mh_q, mh_dbl_q, mh_m_q;
  logic            mhg_v_q;                       // #13: a check granted last cycle, its answer now (ck_ok_q) ...
  tid_t            mhg_t_q;                       // ... for this load
  logic [LIW-1:0]  mhg_lq_q;
  robid_t          mhg_rob_q;
  logic [PA_W-1:0] mh_pa_q;
  tid_t            mh_t_q;
  logic [LIW-1:0]  mh_lq_q;
  robid_t          mh_rob_q;
  assign mh_ask = PMP_FILL && mm_cand && lq_pck_q[hl] && xs_q == X_IDLE && !xr_v_q && am_st_q == AM_IDLE;
  always_ff @(posedge clk) begin
    mh_q     <= !rst && mh_ask && !mh_gnt && !mhg_v_q && !kill_t[t_hd];   // (#13: not again while its answer comes)
    mh_pa_q  <= lq_pa_q[hl];
    mh_dbl_q <= lq_size_q[hl] == 2'd3;
    mh_m_q   <= priv_d[t_hd] == PRIV_M;
    mh_t_q   <= t_hd;
    mh_lq_q  <= hl;
    mh_rob_q <= lqc_rd[2].rob;
    mhg_v_q  <= !rst && CKR && mh_gnt && !kill_t[mh_t_q];
    if (mh_gnt) begin
      mhg_t_q   <= mh_t_q;
      mhg_lq_q  <= mh_lq_q;
      mhg_rob_q <= mh_rob_q;
    end
  end
  assign mh_req = mh_q && xs_q == X_IDLE && !xr_v_q && am_st_q == AM_IDLE;
  tid_t              am_t_q;                // the FSM's atomic's thread
  robid_t            [NT-1:0] am_rob_q;
  sqid_t             [NT-1:0] am_sq_q;
  logic              [NT-1:0] am_dv_q;
  logic [NT-1:0][PIDX_W-1:0] am_dst_q;
  llt_t              [NT-1:0] am_llt_q;
  logic [NT-1:0][4:0] am_op_q;
  logic [4:0]        am_op;                 // the op starting (AM_IDLE: the drain's thread's) or running
  logic [63:0]       am_res_q;              // rd: the old value, or the SC outcome
  logic [NT-1:0]     rsv_v_q;               // each hart's LR reservation: one 64-byte line (Za64rs)
  logic [NT-1:0][PA_W-1:6] rsv_line_q;
  logic [1:0]        am_size;
  logic              am_lr, am_sc, am_go, am_take, rsv_ok, am_wr;
  logic [63:0]       am_old, am_new;
  // An atomic runs only as the SQ head (every older store drained, itself not committed), so
  // it reads its entry through the head's ports, which the drain cannot use meanwhile. Its address,
  // size and operand are registered as it starts (timing: the read-modify-write then starts at
  // flip-flops); the head and its entry do not change while it runs.
  logic [PA_W-1:0] am_pa_q;
  logic [1:0]      am_size_q;
  logic [63:0]     am_b_q;
  logic            rsv_ok_go;                     // the reservation check as it starts: the head's fields
  assign am_size  = am_size_q;
  assign am_pa    = am_pa_q;
  assign am_op    = am_op_q[(am_st_q == AM_IDLE) ? t_dr_q : am_t_q];
  assign am_lr    = am_op == AMO_LR;
  assign am_sc    = am_op == AMO_SC;
  assign am_go    = am_v_q[t_dr_q] && am_st_q == AM_IDLE && sq_v_q[dh] && sq_av_q[dh] && sq_dv_q[dh] &&
                    sq_head_q[t_dr_q] == am_sq_q[t_dr_q] && rob_head[t_dr_q] == am_rob_q[t_dr_q] &&
                    !(s2_v_q && s2_idx_q == dh) && !kill_t[t_dr_q] && !(HART1_ON && NT > 1 && fpc_t[t_dro]) &&
                    !(CKR && mh_gnt);   // (#13: the head's MMIO check's answer takes exception port 2 next cycle)
  // Its PMP check (S2) denied it: it faults as it starts, without an access. It starts only after
  // that check (timing: the checker's verdict, which the walker's address also reaches, stays off
  // the atomic's start)
  logic            pden_go, am_pden_q;
  assign pden_go  = sq_pden_q[dh];
  // The reservation covers the SC's line and has not just been lost (probe, eviction)
  assign rsv_ok   = rsv_v_q[am_t_q] && rsv_line_q[am_t_q] == am_pa[PA_W-1:6] &&
                    !(lose_v && lose_line == rsv_line_q[am_t_q]);
  assign rsv_ok_go = rsv_v_q[t_dr_q] && rsv_line_q[t_dr_q] == sqh.pa[PA_W-1:6] &&
                     !(lose_v && lose_line == rsv_line_q[t_dr_q]);
  assign am_req   = am_st_q == AM_REQ && !kill_t[am_t_q] && !am_pden_q;
  assign am_sel   = am_st_q == AM_REQ;              // the D$ store port's address: the state alone
  assign am_old   = ext_al(am_rdata, am_pa[2:0], am_size, 1'b0);
  assign am_new   = amo_alu(am_op, am_size == 2'd2, am_old, am_b_q);
  assign am_wr    = !am_lr && (!am_sc || rsv_ok);
  assign am_wmask = (am_req && am_ack && am_wr) ? {8'b0, bmask(am_pa[2:0], am_size)} << {am_pa[3], 3'b000}
                                                 : 16'h0;
  assign am_wdata = rep(am_new, am_size);
  assign am_take  = am_st_q == AM_RES && !m2_okw && !ch_take && !xr_take && !kill_t[am_t_q];
  assign fh_take  = fh_v_q && !m2_okw && !ch_take && !xr_take && !am_take && !kill_t[fh_tid_q] &&
                    !(p4_nx_we && p4_nx_bank == fh_fb_q) && !fk_hold;
  assign fh_stay  = fh_v_q && !fh_take && !kill_t[fh_tid_q];
  assign fh_hole_ag = FH_HOLE && fh_v_q && fh_w_q == 3'd4;
`ifndef SYNTHESIS
  // #13 (CK_LD): one take of the result register a cycle; a load waiting for its verdict (held, or to replay) is still
  // in L_PIPE then, as M2 left it
  always_ff @(posedge clk)
    if (md_rs && !rst) begin
      assert ($onehot0({ch_take, m2_ok && !m2_fcol, xr_take, am_take, fh_take}))
        else $error("tg_lsu: two takes of the result register in a cycle");
      if (CK_LD && lg_v_q && !kill_t[lg_t_q] && (lg_k_q == LG_HOLD || lg_k_q == LG_RDY))
        assert (lq_v_q[lg_lq_q] && lq_st_q[lg_lq_q] == L_PIPE) else $error("tg_lsu: a load waiting for its PMP verdict left L_PIPE");
    end
`endif
`ifndef SYNTHESIS
  // A held load never outlives its thread's flush: the flush frees its LLT and its register at once (rename), so a
  // later take would wake an LLT given out again and write a register with a new owner
  logic fh_kill_q;
  always_ff @(posedge clk) begin
    fh_kill_q <= !rst && fh_v_q && kill_t[fh_tid_q];
    if (!rst && fh_kill_q) assert (!fh_v_q) else $error("tg_lsu: a held FP load outlived its thread's flush");
  end
  // ... nor waits long (core-2's check): it takes 7 cycles after the fill (FH_HOLE), or after 8 failed takes IQ-LD's
  // and IQ-FP's selects are blocked until it does, so M2 empties (each replay completes once) and P4's stream empties
  // (ld_block and fp_block, below)
  int unsigned fh_age;                    // the cycles fh has held its load before this one
  always_ff @(posedge clk) begin
    fh_age <= (rst || !fh_v_q) ? 0 : fh_age + 1;
    if (!rst && fh_v_q) assert (fh_age < 64) else $error("tg_lsu: a held FP load waited 64 cycles");
  end
  // The hold's events, on stderr at the end with +fhold_pct (TG-FHOLD)
  longint unsigned fk_n_hold, fk_n_take, fk_n_retry, fk_n_drop, fk_n_fpb;
  int unsigned     fk_max;
  always_ff @(posedge clk) begin
    if (rst) begin
      fk_n_hold <= 0; fk_n_take <= 0; fk_n_retry <= 0; fk_n_drop <= 0; fk_n_fpb <= 0; fk_max <= 0;
    end else begin
      if (m2_ok && m2_fhold) fk_n_hold <= fk_n_hold + 1;
      if (fh_take) fk_n_take <= fk_n_take + 1;
      if (m2_v_q && !m2_pt_q && !kill_t[t_m2] && m2_out == O_OK && m2_fretry) fk_n_retry <= fk_n_retry + 1;
      if (fh_v_q && kill_t[fh_tid_q]) fk_n_drop <= fk_n_drop + 1;
      if (fp_block) fk_n_fpb <= fk_n_fpb + 1;
      if (fh_take && fh_age + 1 > fk_max) fk_max <= fh_age + 1;
    end
  end
  final if (fk_on) begin
    $fwrite(32'h8000_0002, "TG-FHOLD %m: %0d FP loads held, %0d taken, %0d retried, %0d dropped by a flush; ",
            fk_n_hold, fk_n_take, fk_n_retry, fk_n_drop);
    $fwrite(32'h8000_0002, "longest wait %0d cycles; IQ-FP blocked %0d cycles (+fhold_pct=%0d)\n", fk_max, fk_n_fpb, fk_pct);
  end
`endif

  logic [NT-1:0]           rsv_v_d;
  (* keep = "true" *) logic [NT-1:0] rsv_v_e;   // all but a trap's or xRET's clear, kept as a net
  logic [NT-1:0][PA_W-1:6] rsv_line_d;
  always_comb begin
    rsv_v_e    = rsv_v_q;
    rsv_line_d = rsv_line_q;
    if (am_req && am_ack && am_lr) begin
      rsv_v_e[am_t_q]    = 1'b1;
      rsv_line_d[am_t_q] = am_pa[PA_W-1:6];
    end
    // every SC ends its hart's
    if (am_go && am_sc && !rsv_ok_go && !pden_go)    rsv_v_e[t_dr_q] = 1'b0;
    if (am_req && (am_ack || am_den) && am_sc)       rsv_v_e[am_t_q] = 1'b0;
    for (int t = 0; t < NT; t++) begin
      if (lose_v && lose_line == rsv_line_d[t]) rsv_v_e[t] = 1'b0;
      // the other hart's store or atomic writing the line (with one thread, never)
      if (tid_t'(t) != t_dr_q && st_req && st_ack && !st_dropped && st_pa[PA_W-1:6] == rsv_line_d[t])
        rsv_v_e[t] = 1'b0;
      if (tid_t'(t) != am_t_q && am_req && am_ack && am_wr && am_pa[PA_W-1:6] == rsv_line_d[t]) rsv_v_e[t] = 1'b0;
    end
  end
  // A trap or xRET ends its hart's too (the ROB's commit thread), in the last LUT (timing: the commit's trap decision
  // is late)
  always_comb for (int t = 0; t < NT; t++) rsv_v_d[t] = rsv_v_e[t] && !(rsv_clr && t_hd == tid_t'(t));
  // The drain's turn (above): a thread wants the head with a committed store, or with an atomic as its next entry
  always_comb
    for (int t = 0; t < NT; t++) dr_want[t] = !sq_drn[t] || (am_v_q[t] && sq_head_q[t] == am_sq_q[t]);
  assign dr_hold = dr_mmio_go || (xs_q != X_IDLE && x_st_q) || am_go || am_st_q != AM_IDLE;
  assign dr_sw   = NT > 1 && dr_want[t_dro] && !dr_hold;
  // A thread's head store (or atomic) that needs a miss entry and got none keeps the D$'s last free entry from loads
  // until it allocates (smt2_report §13.10): recorded per thread in its own drain cycles, so the other thread's turns
  // do not clear it (tg_dcache, st_resv). With one thread, none
  logic [NT-1:0] stw_q;
  always_ff @(posedge clk)
    if (rst)                    stw_q <= '0;
    else if (st_req || am_req)  stw_q[t_dr_q] <= SPLIT && st_wait;
  assign st_resv = |stw_q;
  // A young reservation holds the D$'s probes, up to RSV_HOLD cycles after its LR or until it ends
  // (its SC, the line lost, a trap or xRET), so an LR/SC pair completes under another core's probes:
  // a read probe that takes T away also ends it (forward progress, core-pipeline §13). Bounded and
  // independent of A-channel progress (TL-C rule 4). The count runs from the LR whatever the
  // reservation does, and the hold is the count while the registered reservation holds, so its end
  // (a trap's clear above all) stays out of the count's reset (timing). The same hold as clearing the
  // count at the end: a reservation starts only with an LR's ack, which sets the count (k-induction;
  // checked against that form in simulation)
  localparam int RSV_HOLD = 64;
  logic [NT-1:0][6:0] rsv_hold_q;                  // per hart
  logic [NT-1:0]      pr_hold_t;
  always_ff @(posedge clk)
    for (int t = 0; t < NT; t++) begin
      if (rst)                                                   rsv_hold_q[t] <= '0;
      else if (am_req && am_ack && am_lr && am_t_q == tid_t'(t)) rsv_hold_q[t] <= 7'(RSV_HOLD);
      else if (rsv_hold_q[t] != '0)                              rsv_hold_q[t] <= rsv_hold_q[t] - 1'b1;
    end
  always_comb for (int t = 0; t < NT; t++) pr_hold_t[t] = rsv_v_q[t] && rsv_hold_q[t] != '0;
  // With hart 1, each thread's forward-progress claim (fpc_t): its head store asked for its line and was not
  // acknowledged (a miss; the D$ keeps the installed line FU_ST cycles for its first write), or its LR's reservation
  // still holds probes (RSV_HOLD). The sibling's atomic or MMIO store, which holds the head for tens of cycles, starts
  // only once neither is out: else the window ran out in the sibling's cycles, the other core took the line, and two
  // cores whose stores or LR/SC loops met on a line, each beside a spinning sibling, took it from each other forever
  // (verif-2's four-hart coherence programs, 10-21). Recorded in the thread's own drain cycles; a committed store
  // outlives a flush, so a flush leaves it
  logic [NT-1:0] stm_q;
  always_ff @(posedge clk)
    for (int t = 0; t < NT; t++)
      if (rst || !(HART1_ON && NT > 1)) stm_q[t] <= 1'b0;
      else if (t_dr_q == tid_t'(t))     stm_q[t] <= st_req && !st_ack;
  always_comb for (int t = 0; t < NT; t++) fpc_t[t] = stm_q[t] || pr_hold_t[t];
  assign pr_hold = |pr_hold_t;
  // Loads wake their LLT the cycle before the register file is written
  always_comb begin
    wake_ld = '0;
    if (m2_okw && lqc_rd[0].dv && !m2_fcol) wake_ld[llt_col(int'(lqc_rd[0].llt))] = 1'b1;
    if (fh_take) wake_ld[llt_col(int'(fh_llt_q))] = 1'b1;
    if (ch_take && ch_dv_q) wake_ld[llt_col(int'(ch_llt_q))] = 1'b1;
    if (xr_take && lqc_rd[1].dv) wake_ld[llt_col(int'(lqc_rd[1].llt))] = 1'b1;
    if (am_take && am_dv_q[am_t_q]) wake_ld[llt_col(int'(am_llt_q[am_t_q]))] = 1'b1;
  end

  // ================= Store data capture =================
  // The oldest store whose data is ready captures it; while P4 takes the shared read port
  // (sd_busy, late: P4's issue) only an FP store can, the oldest ready one. Both choices are
  // formed without sd_busy, which picks between them last, and "oldest" reads the head's mask,
  // a register (sq_hge_q), not the head pointer's decoding. Each read tag takes its own choice:
  // sd_tag is read only when the port is free, and fsd_tag's value is used only when an FP store
  // captures, which is then the oldest ready FP store in either case. The choices are one-hots
  // from a carry chain, and the read tags and the FP flag are AND-ORs over them (timing: no
  // priority ripple, encoder or decoder on the way to the register file and u_sqd's data); the
  // slots, an OR encode beside them, serve the capture's writes and reports
  logic                  cap_v, cap_fp;
  logic [SIW-1:0]        cap_idx, cap_ia, cap_if;
  logic [SQ_ENTRIES-1:0] sq_dvn;                 // the entries with data by the next cycle: now, or captured now
  logic [SQ_ENTRIES-1:0] cap_ea, cap_ef;
`ifndef SYNTHESIS
  logic [SQ_ENTRIES-1:0] ca_s, cf_s;      // the candidate sets, for the choices' check
`endif
  always_comb begin
    logic [SQ_ENTRIES-1:0] ca, cf;
    for (int i = 0; i < SQ_ENTRIES; i++) begin
      ca[i] = sq_v_q[i] && !sq_dv_q[i] && sq_dr_q[i];
      cf[i] = ca[i] && sq_fp_q[i];
    end
    cap_ea  = sq_oldest_oh(ca, sq_hge_q);
    cap_ef  = sq_oldest_oh(cf, sq_hge_q);
    cap_ia  = sq_enc(cap_ea);
    cap_if  = sq_enc(cap_ef);
    // (any flush: a cycle's stall, the data captured the next; with hart 1 also the other thread's atomic writing
    // u_sqd, whose one write port it takes: the capture waits that cycle)
    cap_v   = (sd_busy ? |cf : |ca) && !flush && !(IMT && am_req && am_ack);
    cap_idx = sd_busy ? cap_if : cap_ia;
    cap_fp  = sd_busy ? |(cap_ef & sq_fp_q) : |(cap_ea & sq_fp_q);
    sd_tag  = '0;
    fsd_tag = '0;
    for (int i = 0; i < SQ_ENTRIES; i++) begin
      if (cap_ea[i]) sd_tag  = sd_tag  | sq_tag_q[i];
      if (cap_ef[i]) fsd_tag = fsd_tag | sq_tag_q[i];
    end
`ifndef SYNTHESIS
    ca_s    = ca;
    cf_s    = cf;
`endif
  end
  always_comb begin                               // (sq_dvn: an L_STQ load's replay may start on the capture)
    sq_dvn = sq_dv_q;
    if (cap_v) sq_dvn[cap_idx] = 1'b1;
  end

  // ================= STA =================
  logic [SIW-1:0] sa_idx;
  logic [7:0]     sa_mask;
  pma_e           sa_pma;
  logic           sa_mis, sa_pf, sa_tm, sa_acc, sa_exc, sa_mmio, sa_ok, sa_amo, sa_lr, sa_pmpc;
  logic [PA_W-1:0] sa_pa;
  acc_e           sa_at;
  logic [SIW-1:0] sa_idx_ag;                    // AG's entry (its ROB index, size and VA go in at AG)
  assign sa_idx_ag = sta_ag_pl.sq[SIW-1:0];
  assign sa_idx  = sn_sq;
  assign sa_amo  = sq_amo_q[sa_idx];
  assign sa_lr   = sa_amo && am_op_q[t_sn] == AMO_LR;    // LR faults and translates as a load
  assign sa_at   = sa_lr ? ACC_R : ACC_W;
  assign sa_mask = bmask(sn_va[2:0], sn_size);
  assign sa_pa   = xl_s ? {dt_pte[1].ppn, sn_va[11:0]} : sn_va[PA_W-1:0];
  assign sa_mis  = misal(sn_va[2:0], sn_size);
  assign sa_pf   = xl_s && !sa_mis && !va_canon(sn_va);
  assign sa_tm   = xl_s && !sa_mis && !sa_pf &&
                   !(dt_hit[1] && pte_ok(dt_pte[1], sa_at, priv_d[t_sn], sum[t_sn], mxr[t_sn]));
  assign sa_pma  = pma_of(sa_pa);
  // PMP: a translated store to a PMP-homogeneous page decides with the DTLB's cached result
  // (plan §4.10), and a bare-mode store with the checker on its VA (a register with the split; no
  // walk of its thread runs in bare mode, and another thread's waits: below). A translated store to
  // a page with a region boundary inside decides as if PMP allowed it, and the checker looks at its
  // registered PA in S2, the next cycle (below).
  assign sa_pmpc = xl_s && dt_pte[1].ph;
  // ... and which take the checker at their decision: bare ones, and with PMP_FILL not M-mode while its hart has no
  // locked entry (DR-183). With the split a register's (sn_pck_q, below): its thread's translation, privilege and
  // locked entries had headed the checker's operand select, and so its compares (spikes-2's priv_dl_q family)
  logic sa_pck;
  // atomics only in main memory (interfaces.md §2.4)
  assign sa_acc  = (xl_s ? dt_pte[1].big : sn_va[63:PA_W] != '0) ||
                   (sa_pmpc && !(sa_lr ? dt_pte[1].pr : dt_pte[1].pw)) || (!CKR && sa_pck && !sa_chk[0]) ||
                   (lps_hit && !(sa_lr ? lps_r : lps_w)) ||   // (#13: a bare S/U store in a cached region)
                   sa_pma == PMA_NONE || sa_pma == PMA_ROM || (sa_amo && sa_pma != PMA_MEM);
  assign sa_exc  = sa_mis || sa_pf || (!sa_tm && sa_acc);
  assign sa_mmio = sa_pma == PMA_DEVICE && !sa_amo;
  assign sa_ok   = sn_v && !sa_exc && !sa_tm && !kill_t[t_sn];
`ifndef SYNTHESIS
  // (DR-182) Shadow PMP checks, simulation only: a translated load or store address that decides with its DTLB entry's
  // cached PMP result (ph) is checked in full on its own physical address too, and the two must agree
  logic       sh_ld_ok, sh_st_ok, sh_ld_hit, sh_st_hit;
  logic [2:0] sh_ld_rwx, sh_st_rwx;
  tg_pmp #(.S(1)) u_pmp_sh_ld (.pa(nl_pa), .dbl(ln_size == 2'd3), .acc(ACC_R), .m_mode(1'b0), .d(pmp_d[t_ln]),
                               .ok(sh_ld_ok), .hit(sh_ld_hit), .rwx(sh_ld_rwx));
  tg_pmp #(.S(1)) u_pmp_sh_st (.pa(sa_pa), .dbl(sn_size == 2'd3), .acc(sa_at), .m_mode(1'b0), .d(pmp_d[t_sn]),
                               .ok(sh_st_ok), .hit(sh_st_hit), .rwx(sh_st_rwx));
  logic unused_sh;
  assign unused_sh = ^{sh_ld_hit, sh_ld_rwx, sh_st_hit, sh_st_rwx};
  // (DR-183, PMP_FILL) An M-mode load or store that skips the check, its hart having no locked entry, must pass one
  // in full under M's rules
  if (PMP_FILL) begin : g_shm
    logic       shm_ld_ok, shm_st_ok, shm_ld_hit, shm_st_hit;
    logic [2:0] shm_ld_rwx, shm_st_rwx;
    tg_pmp #(.S(1)) u_pmp_shm_ld (.pa(nl_pa), .dbl(ln_size == 2'd3), .acc(ACC_R), .m_mode(1'b1), .d(pmp_d[t_ln]),
                                  .ok(shm_ld_ok), .hit(shm_ld_hit), .rwx(shm_ld_rwx));
    tg_pmp #(.S(1)) u_pmp_shm_st (.pa(sa_pa), .dbl(sn_size == 2'd3), .acc(sa_at), .m_mode(1'b1), .d(pmp_d[t_sn]),
                                  .ok(shm_st_ok), .hit(shm_st_hit), .rwx(shm_st_rwx));
    logic unused_shm;
    assign unused_shm = ^{shm_ld_hit, shm_ld_rwx, shm_st_hit, shm_st_rwx};
    always_ff @(posedge clk)
      if (!rst) begin
        if (ln_v && !xl_l && priv_d[t_ln] == PRIV_M && !pmp_lk_h[t_ln] && !nl_mis)
          assert (shm_ld_ok) else $error("tg_lsu: an M-mode load skipped PMP (no locked entry), but a full check denies it at PA %h",
                                         nl_pa);
        if (sn_v && !xl_s && priv_d[t_sn] == PRIV_M && !pmp_lk_h[t_sn] && !sa_mis)
          assert (shm_st_ok) else $error("tg_lsu: an M-mode store skipped PMP (no locked entry), but a full check denies it at PA %h",
                                         sa_pa);
      end
  end
  always_ff @(posedge clk)
    if (!rst) begin
      if (ln_v && nl_pmpc && (!xl_l || dt_hit[0]) && !nl_mis && !nl_pf && !nl_tm)
        assert (sh_ld_ok == (xl_l ? dt_pte[0].pr : lpc_r))
          else $error("tg_lsu: a load's cached PMP result (r %b) differs from the full check (%b) at PA %h",
                      xl_l ? dt_pte[0].pr : lpc_r, sh_ld_ok, nl_pa);
      // (#13's region cache: the port a store's decision may take, soc-2's side; its verdict against the full check)
      if (sn_v && lps_hit && !sa_mis && !sa_pf && !sa_tm)
        assert (sh_st_ok == (sa_lr ? lps_r : lps_w))
          else $error("tg_lsu: a store's region-cache result (r %b w %b) differs from the full check (%b) at PA %h",
                      lps_r, lps_w, sh_st_ok, sa_pa);
      if (sn_v && sa_pmpc && dt_hit[1] && !sa_mis && !sa_pf && !sa_tm)
        assert (sh_st_ok == (sa_lr ? dt_pte[1].pr : dt_pte[1].pw))
          else $error("tg_lsu: a store's cached PMP result (r %b w %b) differs from the full check (%b) at PA %h",
                      dt_pte[1].pr, dt_pte[1].pw, sh_st_ok, sa_pa);
    end
`endif

  // ---- S2: a translated store's PMP check after its decision ----
  // The timing: the checker leaves the path from the DTLB through the decision. The store has
  // decided and may have completed (st_cmp_valid[0]); a denial reaches the ROB as an exception
  // alone, a cycle later (S3: spx_valid; the store's completion comes as before, with its data).
  // The ROB retires nothing from the store on while it is in S2 (sth_v[0], registered: the
  // verdict stays off the commit path) and, if denied, in S3 until the exception shows
  // (sth_v[1]). An atomic, which retires only after it runs, is marked instead (sq_pden_q): it
  // faults as it starts, as for a denied line.
  // The checker is shared with the walker, which takes it as before, in a cycle without a store
  // at the decision (chk_gnt; so walks keep their timing). The S2 check then waits a cycle; the
  // walker never checks two cycles running, and no store comes to S2 meanwhile. A bare-mode
  // store uses the checker at its decision (bst): its thread's data are bare, so no walk of that
  // thread runs. Another thread's walk or S2 check waits for it (two threads, M7: S2 then waits
  // while the other thread's bare stores decide; nothing enters S2 meanwhile, as they are bare).
  logic [PA_W-1:0] pc_pa;
  logic [1:0]      pc_lvl;                         // DR-183 (PMP_FILL): the walker's leaf level, in W_PMP
  logic            pc_dbl, pw_chk, w_use, bst;
  logic            s2_amo_q, s2_m_q, s2_dbl_q, s3_den_q;
  acc_e            s2_at_q;
  logic [PA_W-1:0] s2_pa_q;
  robid_t          s2_rob_q, s3_rob_q;
  tid_t            pc_t, s2_t_q, t_pst;            // the walk's thread, S2's store's, the checker's user's
  assign bst    = sn_v && sa_pck && !CKR;                   // (#13: a bare store checks in S2, as below)
  assign w_use  = pw_chk && !sn_v;
  assign s2_go  = s2_v_q && !w_use && !bst;
  assign s2_den = s2_go && !sa_chk[0] && !kill_t[s2_t_q];
  // DR-183 (PMP_FILL): the cycles none of those takes go, in turn, to the head's MMIO load with its check pending,
  // a load (new, or a replay with its check pending), and fetch's request. Fetch goes before loads once it has
  // waited PFC_WAIT cycles, so a stream of load replays cannot starve it. The MMIO load and fetch keep asking; a
  // load replays and asks again. Fetch's request is not granted again in the cycle of its response
  localparam int PFC_WAIT = 3;
  logic          ck_free, pfc_ask, pfc_gnt, pfc_pri;
  logic [1:0]    pfc_wait_q;
  logic          pfc_rsp_v_q;
  assign ck_free = PMP_FILL && !bst && !w_use && !s2_go;
  assign pfc_ask  = PMP_FILL && pfc_req && !pfc_rsp_v_q;
  assign pfc_pri  = int'(pfc_wait_q) == PFC_WAIT;
  assign mh_gnt  = mh_req && ck_free;
  assign l_gnt   = ck_free && !mh_req && !(pfc_ask && pfc_pri);
  assign pfc_gnt  = pfc_ask && ck_free && !mh_req && !(l_ask && !pfc_pri);
  if (!PMP_FILL) begin : g_ck
    assign t_pst  = bst ? t_sn : w_use ? pc_t : s2_t_q;
    tg_pmp #(.S(1)) u_pmp_st (.pa(bst ? sn_va[PA_W-1:0] : w_use ? pc_pa : s2_pa_q),
                              .dbl(bst ? sn_size == 2'd3 : w_use ? pc_dbl : s2_dbl_q),
                              .acc(bst ? sa_at : w_use ? ACC_R : s2_at_q),
                              .m_mode(bst ? ck_ms : !w_use && s2_m_q),
                              .d(pmp_d[t_pst]), .ok(sa_chk), .hit(pmp_hit_st), .rwx(pmp_rwx_st));
    logic unused_mh;                               // (the head's MMIO check is PMP_FILL's)
    assign unused_mh = ^{mh_pa_q, mh_dbl_q, mh_m_q};
  end else begin : g_ckf
    logic [PA_W-1:0] ck_pa;
    logic            ck_dbl, ck_m;
    acc_e            ck_acc;
    always_comb begin
      if (bst) begin
        ck_pa = sn_va[PA_W-1:0]; ck_dbl = sn_size == 2'd3; ck_acc = sa_at; ck_m = ck_ms;
      end else if (w_use) begin
        ck_pa = pc_pa; ck_dbl = pc_dbl; ck_acc = ACC_R; ck_m = 1'b0;
      end else if (s2_go) begin
        ck_pa = s2_pa_q; ck_dbl = s2_dbl_q; ck_acc = s2_at_q; ck_m = s2_m_q;
      end else if (mh_req) begin
        ck_pa = mh_pa_q; ck_dbl = mh_dbl_q; ck_acc = ACC_R; ck_m = mh_m_q;
      end else if (l_ask && !(pfc_ask && pfc_pri)) begin
        ck_pa = lck_pa; ck_dbl = lck_dbl; ck_acc = ACC_R; ck_m = ck_ml;
      end else begin
        ck_pa = pfc_pa; ck_dbl = 1'b0; ck_acc = ACC_X; ck_m = pfc_m && !pfc_page;
      end
    end
    assign t_pst = bst ? t_sn : w_use ? pc_t : s2_go ? s2_t_q : mh_req ? mh_t_q :
                   (l_ask && !(pfc_ask && pfc_pri)) ? t_lck : pfc_tid;
    tg_pmp #(.S(1)) u_pmp_st (.pa(ck_pa), .dbl(ck_dbl), .acc(ck_acc), .m_mode(ck_m), .d(pmp_d[t_pst]), .ok(sa_chk),
                              .hit(pmp_hit_st), .rwx(pmp_rwx_st));
  end
  // DR-183 (PMP_FILL): DR-182's per-page test beside the checker (tg_ptw keeps its own with the switch off): is a
  // region boundary inside the page? For the walker's leaf in W_PMP, or fetch's page (4 KiB), whichever is granted
  logic pg_nh;
  if (PMP_FILL) begin : g_pg
    localparam logic [PMP_GW-1:0] AL4K = PMP_GW'((64'd1 << 10) - 1);
    localparam logic [PMP_GW-1:0] AL2M = PMP_GW'((64'd1 << 19) - 1);
    localparam logic [PMP_GW-1:0] AL1G = PMP_GW'((64'd1 << 28) - 1);
    logic [PMP_GW-1:0] pg;
    logic [1:0]        pg_lvl;
    tid_t              pg_t;
    // (#13, g_lpc: or a granted load's 2 MiB region, for the bare-mode region cache)
    logic lpg;
    assign lpg    = CK_LD && LPC_N > 0 && l_ask && l_gnt;
    assign pg     = PMP_GW'({w_use ? pc_pa[PA_W-1:12] : lpg ? {lck_pa[PA_W-1:21], 9'b0} : pfc_pa[PA_W-1:12], 10'b0});
    assign pg_lvl = w_use ? pc_lvl : lpg ? 2'd1 : 2'd0;
    assign pg_t   = w_use ? pc_t : lpg ? t_lck : pfc_tid;
    always_comb begin
      logic [PMP_GW-1:0] alm;
      logic              in_pg, sub_pg, bound, msk;
      alm = (pg_lvl == 2'd2) ? AL1G : (pg_lvl == 2'd1) ? AL2M : AL4K;
      pg_nh = 1'b0;
      for (int i = 0; i < PMP_ENTRIES; i++) begin
        msk    = (pg_lvl == 2'd2) ? pmp_d[pg_t][i].mask[27] :
                 (pg_lvl == 2'd1) ? pmp_d[pg_t][i].mask[18] : pmp_d[pg_t][i].mask[9];
        in_pg  = ((pmp_d[pg_t][i].a ^ pg) & ~alm) == '0;
        sub_pg = pmp_d[pg_t][i].nap && !pmp_d[pg_t][i].above && msk;
        bound  = (pmp_d[pg_t][i].tor || (i < PMP_ENTRIES - 1 && pmp_d[pg_t][(i + 1) % PMP_ENTRIES].tor)) &&
                 !pmp_pal[pg_t][i][pg_lvl];
        if (in_pg && (sub_pg || bound)) pg_nh = 1'b1;
      end
    end
    // Fetch's response, the cycle after its grant
    logic pfc_tag_q, pfc_ok_q, pfc_nh_q, pfc_x_q;
    always_ff @(posedge clk) begin
      pfc_rsp_v_q <= !rst && pfc_gnt;
      pfc_tag_q   <= pfc_tag;
      pfc_ok_q    <= sa_chk[0];
      pfc_nh_q    <= pg_nh;
      pfc_x_q     <= pmp_hit_st && pmp_rwx_st[0];
      pfc_wait_q  <= (rst || !pfc_ask || pfc_gnt) ? 2'd0 : pfc_pri ? pfc_wait_q : pfc_wait_q + 2'd1;
    end
    assign pfc_rsp_v   = pfc_rsp_v_q;
    assign pfc_rsp_tag = pfc_tag_q;
    assign pfc_rsp_ok  = pfc_ok_q;
    assign pfc_rsp_nh  = pfc_nh_q;
    assign pfc_rsp_x   = pfc_x_q;
  end else begin : g_nopg
    assign pg_nh      = 1'b0;
    assign pfc_rsp_v_q = 1'b0;
    assign pfc_wait_q  = '0;
    assign pfc_rsp_v   = 1'b0;
    assign pfc_rsp_tag = 1'b0;
    assign pfc_rsp_ok  = 1'b0;
    assign pfc_rsp_nh  = 1'b0;
    assign pfc_rsp_x   = 1'b0;
    logic unused_pfc;
    assign unused_pfc = ^{pfc_req, pfc_page, pfc_tag, pfc_tid, pfc_pa, pfc_m, pmp_lk_h, pc_lvl, pfc_gnt};
  end
  always_ff @(posedge clk) begin
    ck_ok_q  <= sa_chk[0];
    ck_hit_q <= pmp_hit_st;
    ck_rwx_q <= pmp_rwx_st;
    ck_nh_q  <= pg_nh;
  end
  always_ff @(posedge clk) begin
    s2_v_q   <= !rst && ((sa_ok && ((xl_s && !sa_pmpc) || (CKR && sa_pck && !lps_hit))) ||
                         (s2_v_q && !s2_go && !kill_t[s2_t_q]));
    // (S2 waits with a store at the decision only for another thread's bare store, which does not enter S2; with #13
    // a bare store enters S2 and none checks at its decision, so S2 waits only for the walker, with no store deciding.
    // A bare S/U store in a region the cache holds (lps_hit) decides with its cached verdict instead, as a translated
    // store with sa_pmpc does, and takes no S2: so its check no longer meets the next load's M2 check)
    if (sn_v && !(s2_v_q && bst)) begin
      s2_pa_q  <= sa_pa;
      s2_dbl_q <= sn_size == 2'd3;
      s2_at_q  <= sa_at;
      s2_m_q   <= priv_d[t_sn] == PRIV_M;
      s2_t_q   <= t_sn;
      s2_amo_q <= sa_amo;
      s2_rob_q <= sn_rob;
      s2_idx_q <= sa_idx;
    end
    s3_den_q <= !rst && s2_den && !s2_amo_q;
    s3_rob_q <= s2_rob_q;
  end
  // ---- Store ownership prefetch (STORE_PF, DR-171) ----
  // A cacheable store whose address decides without a fault asks the D$ for its line with T the next
  // cycle; s2_pa_q, which every decided store loads, holds its PA then. Its PMP verdict may still be
  // on its way (S2): as with a load's miss, only the line's fill goes ahead (a cache-state change; the
  // drain writes in order, and only a store that commits)
  logic pf_v_q;
  always_ff @(posedge clk)
    pf_v_q <= !rst && STORE_PF && DC_MSHRS > 1 && sa_ok && !sa_amo && sa_pma == PMA_MEM;
  assign pf_req = pf_v_q && !flush;               // (a hint: any flush drops it)
  assign pf_pa  = s2_pa_q;
  assign spx_valid  = s3_den_q;
  assign spx_rob    = s3_rob_q;
  assign sth_v[0]   = s2_v_q && !s2_amo_q;
  assign sth_rob[0] = s2_rob_q;
  assign sth_v[1]   = s3_den_q;
  assign sth_rob[1] = s3_rob_q;

  // Ordering check: the oldest younger load that has its value (or is in M1/M2) and overlaps
  // (a load is younger than the store when the store is in [head, the load's lq_sq)); the store's
  // thread's loads, from its heads (M7's step 4)
  logic           rp_v_c, rp_v_q;
  logic [LIW-1:0] rp_ra_c, rp_ra_q;
`ifndef SYNTHESIS
  logic [LQ_ENTRIES-1:0] oc_s;      // the search's set, for the select's check
`endif
  always_comb begin
    logic [LQ_ENTRIES-1:0] oc;
    for (int i = 0; i < LQ_ENTRIES; i++)
      oc[i] = lq_v_q[i] && lq_ot[t_sn][i] && lq_pav_q[i] && (lq_st_q[i] == L_DONE || lq_st_q[i] == L_PIPE) &&
              sq_inwin(int'(sa_idx), sq_head_q[t_sn], lq_sq_q[i]) &&
              lq_pa_q[i][PA_W-1:3] == sa_pa[PA_W-1:3] &&
              |(bmask(lq_pa_q[i][2:0], lq_size_q[i]) & sa_mask);
    rp_v_c  = sa_ok && |oc;
    rp_ra_c = lq_oldest_c(oc, lqi(lq_head_q[t_sn]));
`ifndef SYNTHESIS
    oc_s    = oc;
`endif
  end
  // The report goes out a cycle later from flip-flops: the load's LQ index, whose ROB index the
  // LUTRAM reads then (timing: the read leaves the search). No AG load writes that entry in the
  // search's cycle, as the load is live (asserted)
  always_ff @(posedge clk) begin
    rp_v_q  <= !rst && rp_v_c;                    // (sa_ok: not killed)
    rp_ra_q <= rp_ra_c;
  end
`ifndef SYNTHESIS
  logic rs_q;                       // the core has been reset: the checks wait for it (tg_rob)
  initial rs_q = 1'b0;
  always @(posedge clk) if (rst) rs_q <= 1'b1;
  // The store's M-mode flag for the checkers (ck_ms: registered with the split) is the data privilege's at its
  // decision whenever its thread's flush doesn't squash it (the load's: in g_split)
  always_ff @(posedge clk)
    if (rs_q && !rst && sn_v && !kill_t[t_sn]) begin
      assert (ck_ms == (priv_d[t_sn] == PRIV_M)) else $error("tg_lsu: the store's M-mode flag differs from priv_d");
      assert (sa_pck == (!xl_s && !(PMP_FILL && priv_d[t_sn] == PRIV_M && !pmp_lk_h[t_sn])))
        else $error("tg_lsu: the store's checker request (sa_pck) differs from its translation, privilege and locks");
    end
  // (DR-183, core-2's check) The head's MMIO check request is the head's of a cycle ago, re-derived every cycle (a
  // flush ends it the cycle after): at its grant its entry is still that MMIO load, waiting for its check, as the
  // request captured it
  always_ff @(posedge clk) begin
    if (rs_q && !rst && mh_gnt)
      assert (lq_v_q[mh_lq_q] && lq_st_q[mh_lq_q] == L_MMIO && lq_pa_q[mh_lq_q] == mh_pa_q &&
              (lq_size_q[mh_lq_q] == 2'd3) == mh_dbl_q && lq_tid(int'(mh_lq_q), md) == mh_t_q)
        else $error("tg_lsu: the head's MMIO check granted for LQ %0d, which is no longer the load it asked for", mh_lq_q);
    if (rs_q && !rst && mh_q)
      assert (lq_pck_q[mh_lq_q]) else $error("tg_lsu: the head's MMIO check request for LQ %0d, whose check is done", mh_lq_q);
  end
  always_ff @(posedge clk)
    if (rs_q && !rst && !flush && rp_v_c && ld_ag_valid)
      assert (ld_ag_pl.lq[LIW-1:0] != rp_ra_c) else $error("tg_lsu: an AG load writes a replayed load's LQ entry");
  always_ff @(posedge clk) begin    // the carry-chain selects against the reference (same values)
    assert (rp_ra_c == lq_oldest(oc_s, lqi(lq_head_q[t_sn]))) else $error("tg_lsu: the ordering check's oldest select differs");
    assert (rp_idx == lq_oldest(rp_ready & lq_ot[rp_t], lqi(lq_head_q[rp_t]))) else $error("tg_lsu: the replay pick differs");
  end
`endif
  assign lqr_ra[0]    = rp_ra_q;
  assign replay_valid = rp_v_q;
  assign replay_rob   = lqr_rd[0];

  // ---- CoRR: a load's order against older loads of its address (architecture_plan §4.9; M7's exit 4) ----
  // The search above orders a load against older stores, not against older loads of its address: a younger load that
  // issued first could keep a value another hart overwrote before the older one read it (litmus CoRR on four harts,
  // 10-23). So a line that leaves the D$ (a probe to N, an eviction: another agent may write it without probing us), or
  // that the sibling thread writes (a store, an atomic: with hart 1), marks the loads that have read it and not
  // committed, and each thread's oldest marked load is replayed from the ROB's head (its replay flag), which refetches
  // it and everything after it. A load the mark misses committed first, before any older load of its address could
  // read after the event, so it is in order.
  // The event's line is registered twice and compared in the third cycle: a load that read the line before the event
  // (at AG up to its cycle) has its PA in the LQ by then (written in M1), one that read it after (from the next cycle
  // on) does not yet. The compare is partial, PA[19:6] (the set index and 8 tag bits): a false match only replays.
  localparam int SNW = 14;
  logic           ev_v, ev1_v_q, ev2_v_q;
  logic [SNW-1:0] ev_l, ev1_l_q, ev2_l_q;
  logic [NT-1:0]  ev_tm, ev1_tm_q, ev2_tm_q;      // the threads whose loads the event marks
  logic           st_ev, am_ev;                    // (hart 1) the drain's write (t_dr_q's), the atomic's (am_t_q's)
  assign st_ev = IMT && st_ack && !st_dropped;
  assign am_ev = IMT && am_req && am_ack && am_wr;
  always_comb begin
    ev_v  = dc_snp_v || st_ev || am_ev;            // (one a cycle: the D$'s state port takes one write)
    ev_l  = dc_snp_v ? dc_snp_line[6 +: SNW] : st_ev ? st_pa[6 +: SNW] : am_pa[6 +: SNW];
    ev_tm = dc_snp_v ? '1 : st_ev ? ~(NT'(1) << t_dr_q) : ~(NT'(1) << am_t_q);
  end
  always_ff @(posedge clk) begin
    ev1_v_q  <= !rst && ev_v;
    ev2_v_q  <= !rst && ev1_v_q;
    ev1_l_q  <= ev_l;
    ev2_l_q  <= ev1_l_q;
    ev1_tm_q <= ev_tm;
    ev2_tm_q <= ev1_tm_q;
  end
  // The marks: set by the compare; cleared when the entry is free (a commit, a kill), when it re-enters AG (it reads
  // again), and for a thread when its oldest mark is reported (the replay from it covers its younger loads)
  logic [LQ_ENTRIES-1:0] lq_snp_q, snp_hit, snp_ag;
  logic [LQ_ENTRIES-1:0] lq_io_q;                 // the entry is a device load (decided with its PA): never marked, as it
                                                   // reads at the ROB head with nothing older, and must not run twice
  always_comb
    for (int i = 0; i < LQ_ENTRIES; i++) begin
      logic own;
      own = 1'b0;
      for (int t = 0; t < NT; t++) own |= ev2_tm_q[t] && lq_ot[t][i];
      snp_hit[i] = ev2_v_q && own && lq_v_q[i] && lq_pav_q[i] && !lq_io_q[i] &&
                   (lq_st_q[i] == L_DONE || lq_st_q[i] == L_PIPE) &&
                   lq_pa_q[i][6 +: SNW] == ev2_l_q;
      snp_ag[i]  = ((ld_ag_valid && !kill_t[t_ldag]) || ag_rp) && ag_lq == LIW'(i);
    end
  // The report: a thread's oldest mark a cycle (the threads alternate), its ROB index read the cycle after
  tid_t           sr_t, sr_last_q;
  logic [NT-1:0]  sr_any;
  logic           sr_v;
  logic [LIW-1:0] sr_lq;
  logic           snp_v_q;
  logic [LIW-1:0] snp_lq_q;
  tid_t           snp_t_q;
  always_comb begin
    for (int t = 0; t < NT; t++) sr_any[t] = |(lq_snp_q & lq_ot[t]);
    sr_t  = (NT > 1 && sr_any[NT-1] && (!sr_any[0] || sr_last_q == '0)) ? tid_t'(NT - 1) : '0;
    sr_v  = sr_any[sr_t];
    sr_lq = lq_oldest_c(lq_snp_q & lq_ot[sr_t], lqi(lq_head_q[sr_t]));
  end
  always_ff @(posedge clk) begin
    for (int i = 0; i < LQ_ENTRIES; i++)
      lq_snp_q[i] <= !rst && lq_v_q[i] && !snp_ag[i] && ((lq_snp_q[i] && !(sr_v && lq_ot[sr_t][i])) || snp_hit[i]);
    snp_v_q  <= !rst && sr_v && !kill_t[sr_t];
    snp_lq_q <= sr_lq;
    snp_t_q  <= sr_t;
    if (rst) sr_last_q <= '0;
    else if (sr_v) sr_last_q <= sr_t;
  end
  assign lqr_ra[1]  = snp_lq_q;
  assign snp_valid  = snp_v_q && lq_v_q[snp_lq_q] && !kill_t[snp_t_q];   // (still in the LQ: its ROB entry is live)
  assign snp_rob    = lqr_rd[1];
  logic unused_snp;                                // (the compare is partial: PA[19:6])
  assign unused_snp = ^dc_snp_line[PA_W-1:6+SNW];
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst) assert ($onehot0({dc_snp_v, st_ev, am_ev})) else $error("tg_lsu: two CoRR events in a cycle");
  // +snpstat: the events by source, the marks and the reports (each report replays a load from the ROB's head)
  bit snp_on;
  initial snp_on = $test$plusargs("snpstat");
  longint unsigned snp_n_dc, snp_n_st, snp_n_am, snp_n_mark, snp_n_rep;
  always_ff @(posedge clk)
    if (rst) begin
      snp_n_dc <= 0; snp_n_st <= 0; snp_n_am <= 0; snp_n_mark <= 0; snp_n_rep <= 0;
    end else begin
      snp_n_dc   <= snp_n_dc + (dc_snp_v ? 1 : 0);
      snp_n_st   <= snp_n_st + (st_ev ? 1 : 0);
      snp_n_am   <= snp_n_am + (am_ev ? 1 : 0);
      snp_n_mark <= snp_n_mark + $countones(snp_hit);
      snp_n_rep  <= snp_n_rep + (snp_valid ? 1 : 0);
    end
  final if (snp_on)
    $fwrite(32'h8000_0002, "TG-SNP %m: events D$ %0d, stores %0d, atomics %0d; loads marked %0d; replays reported %0d\n",
            snp_n_dc, snp_n_st, snp_n_am, snp_n_mark, snp_n_rep);
`endif

  // ================= ROB reports =================
  always_comb begin
    exc_valid = '0; exc_rob = '0; exc_cause = '0;      // (tval: the VA at the head, hd_lva/hd_sva)
    // The AG and M2 ports' ROB indices and causes do not wait for their fault decision: the ROB
    // reads them only with exc_valid, and its age compares then start early
    exc_rob[0]   = ln_rob;
    exc_cause[0] = nl_mis ? EXC_LMISALIGN : nl_pf ? EXC_LPAGE : EXC_LACCESS;
    exc_rob[1]   = (CK_LD && lg_v_q && !ck_ok_q) ? lg_rob_q : lqc_rd[0].rob;   // (#13: last cycle's check's denial)
    exc_cause[1] = EXC_LACCESS;
    exc_rob[3]   = sn_rob;
    exc_cause[3] = sa_mis ? (sa_lr ? EXC_LMISALIGN : EXC_SMISALIGN) :
                   sa_pf  ? (sa_lr ? EXC_LPAGE : EXC_SPAGE) : (sa_lr ? EXC_LACCESS : EXC_SACCESS);
    // loads: AG checks of a new load, or a denied line at M2
    if (ln_v && !kill_t[t_ln] && nl_exc) exc_valid[0] = 1'b1;
    if (((m2_v_q && m2_out == O_FAULT) || lm_den) && !kill_t[t_m2]) exc_valid[1] = 1'b1;  // lm_lq is m2_lq_q
    if (lg_den) exc_valid[1] = 1'b1;               // (#13: M2's own denied line yields, O_RETRY)
    if (xs_q == X_WAIT && !x_st_q && !x_kill_q && mmio_d_valid_i && (mmio_d_i.denied || mmio_d_i.corrupt)
        && !kill_t[x_t]) begin
      exc_valid[2] = 1'b1;
      exc_rob[2]   = lqc_rd[1].rob;
      exc_cause[2] = EXC_LACCESS;
    end else if (CKR ? mhg_v_q && !ck_ok_q && !kill_t[mhg_t_q] : mh_gnt && !sa_chk[0] && !kill_t[mh_t_q]) begin
      exc_valid[2] = 1'b1;                        // DR-183: the head's MMIO load, PMP denied (#13: a cycle after its grant)
      exc_rob[2]   = CKR ? mhg_rob_q : mh_rob_q;
      exc_cause[2] = EXC_LACCESS;
    end else if ((am_req && am_den) || (am_st_q == AM_REQ && am_pden_q && !kill_t[am_t_q])) begin  // its line or PMP denied it
      exc_valid[2] = 1'b1;
      exc_rob[2]   = am_rob_q[am_t_q];
      exc_cause[2] = am_lr ? EXC_LACCESS : EXC_SACCESS;
    end
    if (sn_v && !kill_t[t_sn] && sa_exc) exc_valid[3] = 1'b1;
    // store completion: address arrives with the data present, or data arrives after the address
    // (the ROB indices go whether or not they complete: the ROB's tables take them as addresses)
    st_cmp_valid    = '0;
    st_cmp_rob[0]   = sn_rob;
    st_cmp_rob[1]   = sqrob_rd[0];
    if (sa_ok && !sa_amo && (sq_dv_q[sa_idx] || (cap_v && cap_idx == sa_idx))) st_cmp_valid[0] = 1'b1;
    if (cap_v && sq_av_q[cap_idx] && !sq_exc_q[cap_idx] && !sq_amo_q[cap_idx]) st_cmp_valid[1] = 1'b1;
  end

  // ================= Translation: the ROB head and the walker =================
  // TLB-missed loads (L_TLB) and stores (sq_tlb_q) wait for the head. If the DTLB translates the
  // head's VA now, the ROB refetches it; otherwise a non-speculative walk decides, once the
  // committed stores have drained (its PTE reads see them).
  // The head thread's (t_hd, the ROB's commit thread: M7's step 4), with its LQ head and SQ commit point
  logic [SIW-1:0] hs;
  logic           hd_ld, hd_st, hd_need, hd_tok;
  logic [NT-1:0]  hdf_q;                          // per thread: the deciding walk faulted
  logic [NT-1:0][3:0] hdc_q;
  acc_e           hd_at;
  assign hs       = sq_cmt_q[t_hd][SIW-1:0];
  assign hd_ld    = lq_v_q[hl] && lq_st_q[hl] == L_TLB && lqc_rd[2].rob == hd_rob;
  assign hd_st    = sq_v_q[hs] && sq_tlb_q[hs] && sqrob_rd[1] == hd_rob && sq_cmt_q[t_hd] != sq_tail_q[t_hd];
  assign hd_va    = hd_ld ? lqc_rd[2].va : sqva_rd[TRP];
  assign hd_at    = (hd_ld || (sq_amo_q[hs] && am_op_q[t_hd] == AMO_LR)) ? ACC_R : ACC_W;
  assign hd_tlb   = hd_ld || hd_st;
  assign hd_need  = hd_tlb && !kill_t[t_hd];
  // The head's DTLB check (DR-144, #9). The head is the same op in consecutive cycles that both
  // need a translation: a TLB-missed head leaves only through a flush. With two threads the ROB's
  // commit thread alternates, so the check's registers are per thread, each written in its thread's
  // cycles: consecutive cycles of the thread (its head cannot change between them but by its flush).
  logic [NT-1:0] hd_tok_q, hd_need_q;
  logic          hd_walk, hd_wtok;                // the walk request's lookup terms: it may walk; this cycle's lookup hit
  if (ROB_HEAD_TLB_LATE) begin : g_hd_late
    // B3: the lookup takes the head's VA as registered a cycle earlier, so it starts from
    // flip-flops; the check, and the walk request that waits for it, count from the second cycle
    logic [NT-1:0][26:0] hd_vpn_q;
    acc_e [NT-1:0]       hd_at_q;
    always_ff @(posedge clk) begin
      hd_vpn_q[t_hd] <= hd_va[38:12];
      hd_at_q[t_hd]  <= hd_at;
    end
    // The lookup's VPN and access, registered for next cycle's head thread (the ROB's ct_n): the values hd_vpn_q and
    // hd_at_q hold for it next cycle (asserted), so the lookup starts at one register, not at the commit thread's
    // select (timing: ct_q, fan-out 314, then 1.1 ns of wire into the DTLB headed the walker's family on the chip,
    // -1.953 ns to chk_pa_q; spikes §8.18)
    tid_t        t_hdn;
    logic [26:0] hd_vpn2_q;
    acc_e        hd_at2_q;
    assign t_hdn = (NT > 1 && SPLIT) ? hd_tid_n : RUN_TID;
    always_ff @(posedge clk) begin
      hd_vpn2_q <= (t_hdn == t_hd) ? hd_va[38:12] : hd_vpn_q[t_hdn];
      hd_at2_q  <= (t_hdn == t_hd) ? hd_at : hd_at_q[t_hdn];
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
      if (md_rs && !rst) assert (hd_vpn2_q == hd_vpn_q[t_hd] && hd_at2_q == hd_at_q[t_hd])
        else $error("tg_lsu: the head lookup's registered VPN differs from its thread's");
`endif
    assign dt_vpn[2] = hd_vpn2_q;
    assign hd_tok    = hd_need_q[t_hd] && !sta_ag_valid && dt_hit[2] &&
                       pte_ok(dt_pte[2], hd_at2_q, priv_d[t_hd], sum[t_hd], mxr[t_hd]);
    if (LSU_HDWALK_REG) begin : g_hdw_reg
      // #12 (DR-191; spikes §8.18, fix 4): the walk request takes the lookup as registered, a valid miss in the
      // thread's last cycle, so the walker's start (its request select, then chk_pa_q, va_q and base_q) no longer
      // follows the DTLB's match and leaf read (19 levels into chk_pa_q on the chip): a deciding walk starts a cycle
      // later. The head is the same op in both cycles (both need a translation). A fill of the thread's DTLB at
      // that lookup's edge or after holds the request a cycle (the lookup could not see it), so a prefetch's fill
      // of the head's page starts no second walk
      logic [NT-1:0] hd_ms_q, hd_fs_q;
      always_ff @(posedge clk) begin
        hd_ms_q[t_hd] <= hd_need && hd_need_q[t_hd] && !sta_ag_valid &&
                         !(dt_hit[2] && pte_ok(dt_pte[2], hd_at2_q, priv_d[t_hd], sum[t_hd], mxr[t_hd]));
        for (int t = 0; t < NT; t++)
          hd_fs_q[t] <= !rst && ((dt_fill && pw_dtid == tid_t'(t)) || (t_hd != tid_t'(t) && hd_fs_q[t]));
      end
      assign hd_walk = hd_ms_q[t_hd] && !hd_fs_q[t_hd];
      assign hd_wtok = 1'b0;
    end else begin : g_hdw_now
      assign hd_walk = hd_need_q[t_hd];
      assign hd_wtok = hd_tok;
    end
  end else begin : g_hd_two
    // B2: both candidates are looked up, the LQ head's VA (port 2) and the committing store's
    // (port 3), and hd_ld picks last, so the lookups do not wait for the head's selection (an LR
    // checks as a load)
    assign dt_vpn[2] = lqc_rd[2].va[38:12];
    assign dt_vpn[3] = sqva_rd[TRP][38:12];
    logic unused_hdn;                             // (next cycle's head thread: the late form's)
    assign unused_hdn = ^hd_tid_n;
    assign hd_tok    = !sta_ag_valid &&
                       (hd_ld ? dt_hit[2] && pte_ok(dt_pte[2], ACC_R, priv_d[t_hd], sum[t_hd], mxr[t_hd])
                              : dt_hit[3] && pte_ok(dt_pte[3], (sq_amo_q[hs] && am_op_q[t_hd] == AMO_LR) ? ACC_R : ACC_W,
                                                    priv_d[t_hd], sum[t_hd], mxr[t_hd]));
    assign hd_walk   = 1'b1;
    assign hd_wtok   = hd_tok;
  end
  // The ROB sees the head's DTLB retry a cycle later (DR-140 #3; timing: the head's DTLB lookup
  // leaves the commit redirect)
  always_ff @(posedge clk) begin
    hd_tok_q[t_hd]  <= hd_tok;
    hd_need_q[t_hd] <= hd_need;
  end
  assign hd_retry = hd_need && hd_need_q[t_hd] && hd_tok_q[t_hd];
  assign hd_fault = hd_need && hdf_q[t_hd];
  assign hd_cause = hdc_q[t_hd];
  assign hd_lva   = lqc_rd[2].va;
  assign hd_sva   = sqva_rd[TRP];

  // A DTLB miss at AG: the ROB entry replays at the head; the walker prefetches the translation
  assign tlbm_valid[0] = ln_v && !kill_t[t_ln] && nl_tm;
  assign tlbm_rob[0]   = ln_rob;
  assign tlbm_valid[1] = sn_v && !kill_t[t_sn] && sa_tm;
  assign tlbm_rob[1]   = sn_rob;
  // The walk prefetch's request: a DTLB miss is taken when the slot is free or the walker takes
  // it this cycle. Its address and access type live in two slots: every miss writes the slot not
  // presented, and the pointer moves to it when the miss is taken (timing, DR-145: the data's
  // enable does not wait for the walker's ack; the request is the one-slot form's, asserted)
  logic           dpf_v_q, dpf_p_q;
  logic [1:0][63:0] dpf_vas_q;
  acc_e [1:0]     dpf_ats_q;
  logic [63:0]    dpf_va_q;
  acc_e           dpf_at_q;
  tid_t [1:0]     dpf_tids_q;                     // each slot's access's thread
  tid_t           dpf_tid_q;
  assign dpf_va_q = dpf_vas_q[dpf_p_q];
  assign dpf_at_q = dpf_ats_q[dpf_p_q];
  assign dpf_tid_q = dpf_tids_q[dpf_p_q];

  // The walker: the head's deciding walk, fetch, data prefetch
  logic [2:0]       pw_req, pw_ack, pw_who;
  logic [2:0][63:0] pw_va;
  acc_e [2:0]       pw_at;
  priv_e [2:0]      pw_mode;
  logic             pw_done, pw_ok;
  logic [3:0]       pw_cause;
  assign pw_req[0]  = hd_need && hd_walk && !sta_ag_valid && !hd_wtok && !hdf_q[t_hd] && sq_drn[t_hd];
`ifndef SYNTHESIS
  // (#12, core-2's check) A deciding walk never asks while the DTLB already translates the head: the registered miss
  // and the fill guard keep the request off once a fill has made the head's page hit
  always_ff @(posedge clk)
    if (md_rs && !rst && ROB_HEAD_TLB_LATE && LSU_HDWALK_REG)
      assert (!(pw_req[0] && hd_tok)) else $error("tg_lsu: a deciding walk asks while the DTLB translates the head (#12)");
`endif
  assign pw_va[0]   = hd_va;
  assign pw_at[0]   = hd_at;
  assign pw_mode[0] = priv_d[t_hd];
  assign pw_req[1]  = iw_req && EXT_SU;
  assign pw_va[1]   = iw_va;
  assign pw_at[1]   = ACC_X;
  assign pw_mode[1] = priv[t_iw];
  assign pw_req[2]  = dpf_v_q;
  assign pw_va[2]   = dpf_va_q;
  assign pw_at[2]   = dpf_at_q;
  assign pw_mode[2] = priv_d[dpf_tid_q];
  // Each request's thread (the walk's, taken as it starts): the head's, fetch's (the running thread until step 5),
  // the prefetch's access's
  tid_t [2:0]       pw_tid;
  assign pw_tid[0]  = t_hd;
  assign pw_tid[1]  = t_iw;
  assign pw_tid[2]  = dpf_tid_q;
  // M9's counters (TG_HPM), each thread's events as they happen: a load's first miss at M2 (its replays while the line
  // comes do not count again; the walker's PTE reads aside), and a walk the walker takes for the head or the data
  // prefetch (a data access's), or for fetch. tg_ptw acks one request a cycle (by priority), so each is one pulse
  always_comb
    for (int t = 0; t < NT; t++) begin
      hpm_lsu[t][0] = lm_req && !m2_pt_q && !lq_mc_q[m2_lq_q] && t_m2 == tid_t'(t);
      hpm_lsu[t][1] = (pw_req[0] && pw_ack[0] && pw_tid[0] == tid_t'(t)) ||
                      (pw_req[2] && pw_ack[2] && pw_tid[2] == tid_t'(t));
      hpm_lsu[t][2] = pw_req[1] && pw_ack[1] && pw_tid[1] == tid_t'(t);
    end
  tg_ptw u_ptw (
    .clk, .rst, .flush, .flush_tid(t_fl), .satp_ppn, .sum, .mxr, .pmp_d, .pmp_pal,
    .chk_pa(pc_pa), .chk_lvl(pc_lvl), .chk_dbl(pc_dbl), .chk_tid(pc_t), .chk_req(pw_chk), .chk_gnt(!sn_v),
    .chk_ok(CKR ? ck_ok_q : sa_chk[0]), .chk_nh(CKR ? ck_nh_q : pg_nh),   // (#13: the answer a cycle after chk_gnt)
    .chk_hit(CKR ? ck_hit_q : pmp_hit_st), .chk_rwx(CKR ? ck_rwx_q : pmp_rwx_st),
    .req(pw_req), .req_va(pw_va), .req_acc(pw_at), .req_mode(pw_mode), .req_tid(pw_tid), .ack(pw_ack),
    .pt_req, .pt_pa, .pt_gnt, .pt_rsp, .pt_hit, .pt_den, .pt_data(m2_dword_q),
    .mshr_idle(DC_MSHRS == 1 ? mshr_idle : m_wake_any),   // (DR-149: any install, or none busy)
    .done(pw_done), .done_who(pw_who), .done_tid(pw_dtid), .done_ok(pw_ok), .done_cause(pw_cause),
    .fill_vpn(pw_vpn), .fill_lvl(pw_lvl), .fill_pte(pw_pte));
  assign dt_fill      = pw_done && pw_ok && !pw_who[1];
  assign iw_ack       = pw_ack[1];
  assign iw_done      = pw_done && pw_who[1];
  assign iw_ok        = pw_ok;
  assign iw_cause     = pw_cause;
  assign it_fill      = pw_done && pw_ok && pw_who[1];
  assign it_fill_vpn  = pw_vpn;
  assign it_fill_lvl  = pw_lvl;
  assign it_fill_pte  = pw_pte;
  assign it_fill_tid  = pw_dtid;

  always_ff @(posedge clk) begin
    // The deciding walk's fault, for its thread's head (a flush of the thread ends it)
    for (int t = 0; t < NT; t++) begin
      if (rst || kill_t[t]) begin
        hdf_q[t] <= 1'b0;
      end else if (pw_done && pw_who[0] && !pw_ok && pw_dtid == tid_t'(t)) begin
        hdf_q[t] <= 1'b1;
        hdc_q[t] <= pw_cause;
      end
    end
    // The prefetch (a hint) goes at any flush
    if (rst || flush) begin
      dpf_v_q <= 1'b0;
    end else begin
      if (pw_ack[2]) dpf_v_q <= 1'b0;
      if ((!dpf_v_q || pw_ack[2]) && (tlbm_valid[0] || tlbm_valid[1])) begin
        dpf_v_q <= 1'b1;
        dpf_p_q <= !dpf_p_q;
      end
    end
    // The slot not presented takes every miss
    if (tlbm_valid[0]) begin
      dpf_vas_q[!dpf_p_q]  <= ln_va;
      dpf_ats_q[!dpf_p_q]  <= ACC_R;
      dpf_tids_q[!dpf_p_q] <= dt_tid[0];
    end else if (tlbm_valid[1]) begin
      dpf_vas_q[!dpf_p_q]  <= sn_va;
      dpf_ats_q[!dpf_p_q]  <= sa_at;
      dpf_tids_q[!dpf_p_q] <= dt_tid[1];
    end
  end

`ifndef SYNTHESIS
  // The one-slot form: the request presents what it would have
  logic [63:0] dpf_va_o;
  acc_e        dpf_at_o;
  always @(posedge clk) begin
    if (!(rst || flush) && (!dpf_v_q || pw_ack[2])) begin
      if (tlbm_valid[0])      begin dpf_va_o <= ln_va; dpf_at_o <= ACC_R; end
      else if (tlbm_valid[1]) begin dpf_va_o <= sn_va; dpf_at_o <= sa_at; end
    end
    if (rs_q && !rst && dpf_v_q)
      assert (dpf_va_q == dpf_va_o && dpf_at_q == dpf_at_o) else $error("tg_lsu: the walk prefetch's slot differs from the one-slot form");
  end
`endif

  // Replay or PTE read pending: block IQ-LD's select so the AG slot frees. A held FP load (DR-179) blocks it at
  // fill+3 (FH_HOLE: M2 empty at fill+7), and IQ-FP's the cycle after the fill (P4's slot at fill+8 free). From its
  // 8th failed take both stay blocked until it takes: M2 empties, its replays aside, and so does P4's stream (its
  // pipelines and a divide's slot), so a stream of completing loads or of P4 writes to its bank cannot starve it
  // (core-2's review). IQ-FP's select is also blocked while an FP load's MMIO response meets P4
  always_ff @(posedge clk) begin
    if (rst || flush) ld_block <= 1'b0;
    else              ld_block <= |rp_ready || pt_req || (fh_stay && fh_w_q >= FH_LDB) ||
                                  (FH_HOLE && fh_stay && fh_w_q == 3'd1);
    fp_block <= !rst && ((fh_stay && fh_w_q == FH_BLK) || (xr_v_q && xr_fcol && !kill_t[x_t]) ||
                         (FH_HOLE && m2_ok && m2_fhold));
    fh_w_q   <= (rst || !fh_stay) ? 3'd0 : (fh_w_q == FH_BLK) ? FH_BLK : fh_w_q + 3'd1;
  end

  // ================= Cold storage: VAs and store data (LUTRAM) =================
  // A register written this cycle (DS of a store whose data is being written meanwhile)
  /* verilator lint_off UNUSEDSIGNAL */      // an FP tag is the low bits of preg_t
  function automatic logic fsnoop(input preg_t p, input logic [1:0] we,
                                  input logic [1:0][FPIDX_W-1:0] wi);
    logic h;
    h = 1'b0;
    for (int b = 0; b < 2; b++) if (we[b] && fpreg_bank(p) == 1'(b) && fpreg_idx(p) == wi[b]) h = 1'b1;
    return h;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  function automatic logic snoop(input preg_t p, input logic [INT_BANKS-1:0] we,
                                 input logic [INT_BANKS-1:0][PIDX_W-1:0] wi);
    logic h;
    h = 1'b0;
    for (int b = 0; b < INT_BANKS; b++) if (we[b] && preg_bank(p) == BANK_W'(b) && preg_idx(p) == wi[b]) h = 1'b1;
    return h;
  endfunction
  assign lqc_ra[0] = m2_lq_q;
  assign lqc_ra[1] = x_lq_q;
  assign lqc_ra[2] = hl;
  assign lqc_wd = '{rob: ld_ag_pl.rob, dv: ld_ag_pl.dst_en, fp: EXT_FD && ld_ag_pl.dst_fp,
                    fb: EXT_FD && ld_ag_pl.dst_fp && fpreg_bank(ld_ag_pl.dst),
                    uns: ld_ag_pl.mem_uns,
                    dst: (EXT_FD && ld_ag_pl.dst_fp) ? LDW'(fpreg_idx(ld_ag_pl.dst)) : LDW'(preg_idx(ld_ag_pl.dst)),
                    llt: ld_ag_pl.llt,
                    va: ld_ag_addr};
  tg_ram_lut #(.DEPTH(LQ_ENTRIES), .WIDTH($bits(lqc_t)), .NR(3)) u_lqc (
    .clk, .we(ld_ag_valid && !kill_t[t_ldag]), .waddr(ld_ag_pl.lq[LIW-1:0]), .wdata(lqc_wd), .raddr(lqc_ra),
    .rdata(lqc_rd));
  tg_ram_lut #(.DEPTH(LQ_ENTRIES), .WIDTH(ROBW), .NR(2)) u_lqrob (
    .clk, .we(ld_ag_valid && !kill_t[t_ldag]), .waddr(ld_ag_pl.lq[LIW-1:0]), .wdata(ld_ag_pl.rob), .raddr(lqr_ra),
    .rdata(lqr_rd));
  // LUTRAM copies of the address fields the CAMs keep in flip-flops, for the reads by index: a
  // replay's address and the MMIO load's (the LQ head); the SQ head's, for the drain, an MMIO
  // store and an atomic
  assign lqa_ra[0] = rp_idx;
  assign lqa_ra[1] = hl;
  tg_ram_lut #(.DEPTH(LQ_ENTRIES), .WIDTH($bits(lqa_t)), .NR(2)) u_lqa (
    .clk, .we(ln_v && !kill_t[t_ln]), .waddr(ln_lq),
    .wdata(lqa_t'{pa: nl_pa, size: ln_size}), .raddr(lqa_ra), .rdata(lqa_rd));
  // The SQ head's fields are kept in flip-flops (timing, DR-145: the drain's address into the D$
  // starts at a register, not at the LUTRAM's read): loaded with the entry that is the head in the
  // next cycle, the LUTRAM's read of the entry after the head when the drain pops (or of the other
  // thread's head when the drain's thread changes), the STA's write in this cycle bypassed
  // (simulation checks them against the entry whenever the head is valid)
  logic [0:0][SIW-1:0] sqh_ra;
  sqh_t [0:0]          sqh_rd;
  sqh_t                sqh_wd, sqh_q;
  logic                sqh_we;
  logic [SIW-1:0]      dh1, dho;                  // the slot after the drain's head (in its part); the other's head
  assign dh1       = SIW'(int'(dh) + 1 == part_base(SQ_ENTRIES, t_dr_q, md) + part_size(SQ_ENTRIES, md) ?
                         part_base(SQ_ENTRIES, t_dr_q, md) : int'(dh) + 1);
  assign dho       = sq_head_q[t_dro][SIW-1:0];
  logic           dhr;                      // (step 6) the split moves the drain's head: read its new entry
  assign dhr       = HART1_ON && mrs_i && t_dr_q == md.run;
  assign sqh_ra[0] = dhr ? SIW'(part_base(SQ_ENTRIES, md.run, mdn)) : (dr_sw ? dho : dh1);
  assign sqh_we    = sn_v && !kill_t[t_sn];
  assign sqh_wd    = sqh_t'{pa: sa_pa, mask: sa_mask, size: sn_size};
  tg_ram_lut #(.DEPTH(SQ_ENTRIES), .WIDTH($bits(sqh_t)), .NR(1)) u_sqh (
    .clk, .we(sqh_we), .waddr(sa_idx), .wdata(sqh_wd), .raddr(sqh_ra), .rdata(sqh_rd));
  always_ff @(posedge clk) begin
    if (dhr)         sqh_q <= sqh_rd[0];        // (its window is empty: nothing writes it now)
    else if (dr_sw)  sqh_q <= (sqh_we && sa_idx == dho) ? sqh_wd : sqh_rd[0];
    else if (dr_pop) sqh_q <= (sqh_we && sa_idx == dh1) ? sqh_wd : sqh_rd[0];
    else             sqh_q <= (sqh_we && sa_idx == dh)  ? sqh_wd : sqh_q;
  end
  assign sqh = sqh_q;
`ifndef SYNTHESIS
  sqh_t sqh_s [SQ_ENTRIES];                // the SQ's address fields, as the LUTRAM holds them
  always @(posedge clk) begin
    if (sqh_we) sqh_s[sa_idx] <= sqh_wd;
    if (rs_q && !rst && sq_v_q[dh])
      assert (sqh_q == sqh_s[dh]) else $error("tg_lsu: the SQ head's registered fields differ from the entry");
  end
`endif
  assign sqrob_ra[0] = cap_idx;
  assign sqrob_ra[1] = hs;
  tid_t t_staag;                                  // the STA port's store's thread (its AG)
  assign t_staag = sta_ag_pl.tid;                 // (its SQ entry's: asserted)
  tg_ram_lut #(.DEPTH(SQ_ENTRIES), .WIDTH(ROBW), .NR(2)) u_sqrob (
    .clk, .we(sta_ag_valid && !kill_t[t_staag]), .waddr(sa_idx_ag), .wdata(sta_ag_pl.rob), .raddr(sqrob_ra),
    .rdata(sqrob_rd));
  tg_ram_lut #(.DEPTH(SQ_ENTRIES), .WIDTH(2), .NR(TRP + 1)) u_sqsz (
    .clk, .we(sta_ag_valid && !kill_t[t_staag]), .waddr(sa_idx_ag), .wdata(sta_ag_pl.mem_size), .raddr(sqsz_ra),
    .rdata(sqsz_rd));
  assign sqva_ra[TRP]   = hs;            // at an atomic, hs is its entry and the head
  tg_ram_lut #(.DEPTH(SQ_ENTRIES), .WIDTH(64), .NR(SVR)) u_sqva (
    .clk, .we(sta_ag_valid && !kill_t[t_staag]), .waddr(sa_idx_ag), .wdata(sta_ag_addr), .raddr(sqva_ra),
    .rdata(sqva_rd));
  // Data: captured from the register file, or written by an atomic (the value it stored)
  assign sqd_ra[TRP]   = m2_fidx;
  assign sqd_ra[TRP+1] = dh;
  assign sqd_we = (am_req && am_ack) || cap_v;
  assign sqd_wa = (am_req && am_ack) ? dh : cap_idx;
  // The source as one encoded select from early terms, so a data bit is one LUT6 (P4's FP bank
  // select folds in here): 0 the atomic's value, 1 integer, 2 FP bank 0, 3 FP bank 1
  logic [1:0] sqd_s;
  assign sqd_s = (am_req && am_ack) ? 2'd0
               : (EXT_FD && cap_fp) ? {1'b1, fpreg_bank(fsd_tag)} : 2'd1;
  always_comb begin
    for (int i = 0; i < 64; i++) begin
      unique case (sqd_s)
        2'd0:    sqd_wd[i] = am_new[i];
        2'd1:    sqd_wd[i] = sd_data[i];
        2'd2:    sqd_wd[i] = fsd_data[0][i];
        default: sqd_wd[i] = fsd_data[1][i];
      endcase
    end
  end
  tg_ram_lut #(.DEPTH(SQ_ENTRIES), .WIDTH(64), .NR(SDR)) u_sqd (
    .clk, .we(sqd_we), .waddr(sqd_wa), .wdata(sqd_wd), .raddr(sqd_ra), .rdata(sqd_rd));

  // ================= Sequential =================
  always_ff @(posedge clk) begin
    if (rst) begin
      lq_v_q    <= '0;
      for (int t = 0; t < NT; t++) begin
        lq_head_q[t] <= lq_start(tid_t'(t), MD_C);
        lq_tail_q[t] <= lq_start(tid_t'(t), MD_C);
        sq_head_q[t] <= sq_start(tid_t'(t), MD_C);
        sq_cmt_q[t]  <= sq_start(tid_t'(t), MD_C);
        sq_tail_q[t] <= sq_start(tid_t'(t), MD_C);
      end
      sq_v_q    <= '0;
      sq_hge_q  <= sq_ge(part_base(SQ_ENTRIES, RUN_TID, MD_C));
      t_dr_q    <= RUN_TID;
      rp_turn_q <= 1'b0;
      m1_v_q    <= 1'b0;
      m2_v_q    <= 1'b0;
      m1_rck_q  <= 1'b0;
      m2_rck_q  <= 1'b0;
      ma3_v_q   <= 1'b0;
      ma4_v_q   <= 1'b0;
      r_v_q     <= 1'b0;
      r_fv_q    <= 1'b0;
      r_fb_q    <= 1'b0;
      fh_v_q    <= 1'b0;
      if (IMT) r_data_q <= '0;                    // (hart 1's homes take it as their zero: above)
      xs_q      <= X_IDLE;
      xr_v_q    <= 1'b0;
      x_kill_q  <= 1'b0;
      xd_q      <= 1'b0;
      am_v_q    <= '0;
      am_st_q   <= AM_IDLE;
      am_t_q    <= RUN_TID;
      rsv_v_q   <= '0;
    end else begin
      // ---- Commit ----
      for (int k = 0; k < COMMIT_WIDTH; k++) begin
        if (k < int'(cm_nld)) lq_v_q[lqi(lq_add_t(lq_head_q[t_cm], k, t_cm, md))] <= 1'b0;
      end
      lq_head_q[t_cm] <= lq_add_t(lq_head_q[t_cm], int'(cm_nld), t_cm, md);
      sq_cmt_q[t_cm]  <= sq_add_t(sq_cmt_q[t_cm], int'(cm_nst), t_cm, md);

      // ---- Drain ----
      if (dr_pop) begin
        sq_v_q[dh] <= 1'b0;
        sq_head_q[t_dr_q] <= sq_add_t(sq_head_q[t_dr_q], 1, t_dr_q, md);
        sq_hge_q   <= (int'(dh) + 1 == part_base(SQ_ENTRIES, t_dr_q, md) + part_size(SQ_ENTRIES, md)) ?
                      sq_ge(part_base(SQ_ENTRIES, t_dr_q, md)) : (sq_hge_q & ~(SQ_ENTRIES'(1) << dh));
      end
      if (dr_sw) begin                                 // the other thread's head next (its mask: the capture's order)
        t_dr_q   <= t_dro;
        sq_hge_q <= sq_ge(int'(dho));
      end
      // ---- Replays take turns ----
      if (ag_rp) rp_turn_q <= rp_t == tid_t'(0);

      // ---- MMIO ----
      unique case (xs_q)
        X_IDLE: begin
          if (dr_mmio_go) begin
            xs_q      <= X_REQ;
            x_st_q    <= 1'b1;
            x_t_q     <= t_dr_q;
            x_pa_q    <= sqh.pa;
            x_size_q  <= sqh.size;
            x_wdata_q <= sqd_rd[TRP+1];
          end else if (mm_go) begin
            xs_q      <= X_REQ;
            x_st_q    <= 1'b0;
            x_kill_q  <= 1'b0;
            x_lq_q    <= mm_idx;
            x_t_q     <= t_hd;
            x_pa_q    <= lqa_rd[1].pa;                // mm_idx is the LQ head
            x_size_q  <= lqa_rd[1].size;
          end
        end
        X_REQ: if (mmio_a_ready_i) xs_q <= X_WAIT;
        X_WAIT: if (mmio_d_valid_i) begin
          xs_q <= X_IDLE;
          if (!x_st_q && !x_kill_q && !kill_t[x_t]) begin
            if (mmio_d_i.denied || mmio_d_i.corrupt) begin
              lq_st_q[x_lq_q] <= L_EXC;
            end else begin
              xr_v_q    <= 1'b1;
              xr_data_q <= ext_al(x_pa_q[3] ? mmio_d_i.data[127:64] : mmio_d_i.data[63:0], x_pa_q[2:0],
                                  x_size_q, lqc_rd[1].uns);
            end
          end
        end
        default: xs_q <= X_IDLE;
      endcase
      if (xr_take) xr_v_q <= 1'b0;
      if (xr_take)                          xd_q <= 1'b1;
      else if (cm_nld != '0 && t_cm == x_t) xd_q <= 1'b0;

      // ---- Atomics ----
      rsv_v_q    <= rsv_v_d;
      rsv_line_q <= rsv_line_d;
      unique case (am_st_q)
        AM_IDLE: if (am_go) begin
          am_t_q    <= t_dr_q;
          am_pa_q   <= sqh.pa;
          am_size_q <= sqh.size;
          am_b_q    <= sqd_rd[TRP+1];
          am_pden_q <= pden_go;
          if (am_sc && !rsv_ok_go && !pden_go) begin
            am_res_q <= 64'd1;                    // SC without a reservation: fails, no access
            am_st_q  <= AM_RES;
          end else begin
            am_st_q  <= AM_REQ;
          end
        end
        AM_REQ: if (am_pden_q) begin
          am_st_q <= AM_DONE;                     // PMP denied it: access fault
        end else if (am_ack) begin
          am_res_q        <= am_sc ? {63'b0, !am_wr} : am_old;
          sq_amw_q[dh]    <= am_wr;
          am_st_q         <= AM_RES;
        end else if (am_den) begin
          am_st_q <= AM_DONE;                     // access fault
        end
        AM_RES: if (am_take) am_st_q <= AM_DONE;
        default: ;
      endcase

      // ---- Result register ----
      r_v_q <= 1'b0;
      r_fv_q <= 1'b0;
      // A held FP load leaves fh at its take, or with a flush of its thread; one meeting P4 in M2 enters it
      if (fh_take || kill_t[fh_tid_q]) fh_v_q <= 1'b0;
      if (m2_ok && m2_fhold) begin
        fh_v_q    <= 1'b1;
        fh_tid_q  <= t_m2;
        fh_fb_q   <= lqc_rd[0].fb;
        fh_dst_q  <= lqc_rd[0].dst;
        fh_data_q <= m2_val | {{32{lq_size_q[m2_lq_q] == 2'd2}}, 32'b0};
        fh_rob_q  <= lqc_rd[0].rob;
        fh_llt_q  <= lqc_rd[0].llt;
      end
      if (ch_take) begin                      // (#13: a held load's verdict allows it; M2 and the others wait)
        r_v_q    <= 1'b1;
        r_dv_q   <= ch_dv_q;
        r_fv_q   <= 1'b0;
        r_fb_q   <= 1'b0;
        r_dst_q  <= ch_dst_q;
        r_data_q <= ch_data_q;
        r_rob_q  <= lg_rob_q;
        r_llt_q  <= ch_llt_q;
        r_mmio_q <= 1'b0;
      end else if (m2_ok && !m2_fcol) begin
        r_v_q    <= 1'b1;
        r_dv_q   <= lqc_rd[0].dv;
        r_fv_q   <= EXT_FD && lqc_rd[0].dv && lqc_rd[0].fp;
        r_fb_q   <= lqc_rd[0].fb;
        r_dst_q  <= lqc_rd[0].dst;
        r_data_q <= m2_val | {{32{EXT_FD && lqc_rd[0].fp && lq_size_q[m2_lq_q] == 2'd2}}, 32'b0};
        r_rob_q  <= lqc_rd[0].rob;
        r_llt_q  <= lqc_rd[0].llt;
        r_mmio_q <= 1'b0;
      end else if (xr_take) begin
        r_v_q    <= 1'b1;
        r_dv_q   <= lqc_rd[1].dv;
        r_fv_q   <= EXT_FD && lqc_rd[1].dv && lqc_rd[1].fp;
        r_fb_q   <= lqc_rd[1].fb;
        r_dst_q  <= lqc_rd[1].dst;
        r_data_q <= xr_data_q | {{32{EXT_FD && lqc_rd[1].fp && lq_size_q[x_lq_q] == 2'd2}}, 32'b0};
        r_rob_q  <= lqc_rd[1].rob;
        r_llt_q  <= lqc_rd[1].llt;
        r_mmio_q <= 1'b1;
        lq_st_q[x_lq_q] <= L_DONE;
      end else if (am_take) begin
        r_v_q    <= 1'b1;
        r_dv_q   <= am_dv_q[am_t_q];
        r_fv_q   <= 1'b0;
        r_fb_q   <= 1'b0;
        r_dst_q  <= LDW'(am_dst_q[am_t_q]);
        r_data_q <= am_res_q;
        r_rob_q  <= am_rob_q[am_t_q];
        r_llt_q  <= am_llt_q[am_t_q];
        r_mmio_q <= 1'b0;
      end else if (fh_take) begin
        r_v_q    <= 1'b1;
        r_dv_q   <= 1'b1;
        r_fv_q   <= 1'b1;
        r_fb_q   <= fh_fb_q;
        r_dst_q  <= fh_dst_q;
        r_data_q <= fh_data_q;
        r_rob_q  <= fh_rob_q;
        r_llt_q  <= fh_llt_q;
        r_mmio_q <= 1'b0;
      end

      // ---- M2 outcome ----
      if (m2_v_q && !m2_pt_q && !kill_t[t_m2]) begin
        unique case (m2_out)
          O_OK:    lq_st_q[m2_lq_q] <= m2_fretry ? L_READY : L_DONE;   // (an FP load meeting P4 with fh full)
          O_STQ:   lq_st_q[m2_lq_q] <= L_STQ;
          O_MISS:  lq_st_q[m2_lq_q] <= L_MISS;
          O_RETRY: lq_st_q[m2_lq_q] <= L_READY;
          O_HOLD:  ;                                                   // (#13: L_PIPE until its verdict, below)
          default: lq_st_q[m2_lq_q] <= L_EXC;
        endcase
        // The blocking store's fields go in on the outcome before the PMP checker's verdict (timing:
        // l_den stays out of their enables): a load the checker denies goes to L_EXC in this cycle,
        // and they are read only in L_STQ (checked against the verdict's in simulation)
        if (m2_out_w == O_STQ) begin
          lq_blk_q[m2_lq_q]  <= m2_fid;
          lq_part_q[m2_lq_q] <= !m2_fcov_q;
        end
        // DR-149 (DC_MSHRS > 1): a missing load waits for any entry until the D$ answers (read only
        // in L_MISS, so the same holds for its enable)
        if (m2_out_w == O_MISS) lq_wany_q[m2_lq_q] <= 1'b1;
        if (PMP_FILL) lq_pck_q[m2_lq_q] <= l_nok;      // DR-183: its check still to come, or done
      end
      if (lm_st && !kill_t[lq_tid(int'(lm_lq), md)]) lq_st_q[lm_lq] <= L_EXC;    // an MMIO load the PMP checker denied
      // DR-183 (PMP_FILL): a parked MMIO load's check, and the head's (a denial is its exception, port 2)
      if (lmc_v) lq_pck_q[lmc_lq] <= !l_gnt;
      if (CKR ? mhg_v_q : mh_gnt) begin
        lq_pck_q[CKR ? mhg_lq_q : mh_lq_q] <= 1'b0;
        if (CKR ? !ck_ok_q && !kill_t[mhg_t_q] : !sa_chk[0] && !kill_t[mh_t_q])
          lq_st_q[CKR ? mhg_lq_q : mh_lq_q] <= L_EXC;
      end

      // ---- M1 -> M2 ----
      m2_v_q      <= m1_go && !kill_t[t_m1];
      ma3_v_q     <= lm_req && !m2_pt_q;            // (lm_req is not set under its thread's flush)
      ma3_lq_q    <= m2_lq_q;
      ma4_v_q     <= ma3_v_q && !kill_t[lq_tid(int'(ma3_lq_q), md)];
      ma4_lq_q    <= ma3_lq_q;
      m2_lq_q     <= m1_lq_q;
      m2_t_q      <= m1_t_q;
      m2_m_q      <= priv_d[m1_t_q] == PRIV_M;
      m2_pa_q     <= m1pa;
      m2_clash_q  <= m1_clash;
      m2_hit_q    <= dc_hit;
      m2_dword_q  <= dc_dword;
      m2_fhit_q   <= f_hit;
      m2_fcov_q   <= f_cover;
      m2_fdat_q   <= f_data;
      m2_foh_q    <= f_oh;
      m2_pt_q     <= m1_pt_q;
      m2_rck_q    <= PMP_FILL && m1_rck_q && m1_go && !kill_t[t_m1];

      // ---- AG -> M1 ----
      m1_v_q     <= ag_go;
      m1_pt_q    <= ag_pt;
      m1_lq_q    <= ag_lq;
      m1_t_q     <= ag_t;
      m1_pa_q    <= ag_pa;
      m1_rck_q   <= PMP_FILL && ag_rp && lq_pck_q[ag_lq];
      if (ld_ag_valid && !kill_t[t_ldag]) begin        // AG: into the pipe
        lq_pav_q[ag_lq]  <= 1'b0;
        lq_pck_q[ag_lq]  <= 1'b0;
        lq_st_q[ag_lq]   <= L_PIPE;
        lq_sq_q[ag_lq]   <= ld_ag_pl.sq;               // (the cold fields: u_lqc)
        lq_size_q[ag_lq] <= ld_ag_pl.mem_size;
      end else if (ag_rp) begin
        lq_st_q[ag_lq]  <= L_PIPE;
      end
      // A new load's PA and outcome where it decides: in AG (over the lines above), or in M1 with
      // the split. The outcome is the state write's data, not its enable, so nl_exc (after the PMA
      // and fault checks) stays out of each entry's enable (timing). A load going on keeps L_PIPE,
      // the state it has here: its AG write gave it, in this cycle without the split, the cycle
      // before with it (nothing else writes the entry in between: asserted in g_split)
      if (ln_v && !kill_t[t_ln]) begin
        lq_pa_q[ln_lqw]  <= nl_pa;
        lq_pav_q[ln_lqw] <= !nl_exc && !nl_tm;
        lq_io_q[ln_lqw]  <= nl_mmio;
        lq_st_q[ln_lqw]  <= (nl_exc || nl_tm || nl_mmio) ? (nl_exc ? L_EXC : nl_tm ? L_TLB : L_MMIO) : L_PIPE;
      end

      // ---- DR-149 (DC_MSHRS > 1): the D$'s answer to a load's miss, two cycles after it ----
      if (DC_MSHRS > 1 && lm_ans_v && ma4_v_q && !kill_t[lq_tid(int'(ma4_lq_q), md)] && lq_st_q[ma4_lq_q] == L_MISS) begin
        if (lm_ans_wait) begin
          lq_wany_q[ma4_lq_q] <= 1'b0;
          lq_we_q[ma4_lq_q]   <= lm_ans_e;
        end else begin
          lq_st_q[ma4_lq_q]   <= L_READY;           // its line is in, or installs now
        end
      end

      // ---- Waiting loads re-check their condition ----
      for (int i = 0; i < LQ_ENTRIES; i++) begin
        if (lq_v_q[i] && !(ag_v && !ag_pt && ag_lq == LIW'(i)) && !(m2_v_q && !m2_pt_q && m2_lq_q == LIW'(i))) begin
          if (lq_st_q[i] == L_MISS && (DC_MSHRS == 1 ? mshr_idle :
                                       lq_wany_q[i] ? m_wake_any : m_done[lq_we_q[i]]))
            lq_st_q[i] <= L_READY;
          if (lq_st_q[i] == L_STQ) begin
            // ... also on the store's data capture itself, a cycle before sq_dv_q: the replay then enters AG ahead
            // of the store's drain (it completes on the capture, commits the next cycle and drains the one after).
            // With sq_dv_q alone the replay's AG met the drain's D$ write to its row: a clash, O_RETRY and a second
            // replay (crc32's loop, the store completing as the ROB head: 12 cycles from its data's producer to the
            // load's dependant instead of 8)
            if (!sq_live(lq_blk_q[i], sqh_lh[i >= LQ_ENTRIES / 2], sqt_lh[i >= LQ_ENTRIES / 2]) ||
                (!lq_part_q[i] && sq_dvn[lq_blk_q[i][SIW-1:0]]))
              lq_st_q[i] <= L_READY;
          end
        end
      end
      if (mm_go) lq_st_q[mm_idx] <= L_PIPE;   // MMIO request out (not L_MMIO any more)
      // #13 (CK_LD): last cycle's granted check, its verdict: a denied load goes to L_EXC whatever its state took since
      // (here, after the waits); one allowed leaves the hold with its take (L_DONE) or replays without a check (L_READY)
      if (CK_LD && lg_v_q && !kill_t[lg_t_q]) begin
        if (!ck_ok_q)               lq_st_q[lg_lq_q] <= L_EXC;
        else if (lg_k_q == LG_HOLD) lq_st_q[lg_lq_q] <= L_DONE;
        else if (lg_k_q == LG_RDY)  lq_st_q[lg_lq_q] <= L_READY;
      end

      // ---- Store data capture ----
      if (cap_v) sq_dv_q[cap_idx] <= 1'b1;            // the data goes into the LUTRAM
      // Store data readiness: snoop the register-file writes (FP stores: the FP file's)
      for (int i = 0; i < SQ_ENTRIES; i++) begin
        if (EXT_FD && sq_fp_q[i]) begin
          if (fsnoop(sq_tag_q[i], fp_we, fp_widx)) sq_dr_q[i] <= 1'b1;
        end else if (snoop(sq_tag_q[i], rf_we, rf_widx)) begin
          sq_dr_q[i] <= 1'b1;
        end
      end

      // ---- STA ----
      if (sn_v && !kill_t[t_sn]) begin                 // where it decides (rob, size and VA: at AG)
        sq_av_q[sa_idx]   <= !sa_exc && !sa_tm;
        sq_exc_q[sa_idx]  <= sa_exc;
        sq_tlb_q[sa_idx]  <= sa_tm;
        sq_pa_q[sa_idx]   <= sa_pa;
        sq_mask_q[sa_idx] <= sa_mask;
        sq_mmio_q[sa_idx] <= sa_mmio;
      end
      if (s2_den && s2_amo_q) sq_pden_q[s2_idx_q] <= 1'b1;

      if (lm_req && !m2_pt_q) lq_mc_q[m2_lq_q] <= 1'b1;   // (M9's counters: a load's miss counts once)
      // ---- Dispatch: new LQ / SQ entries ----
      if (ds_fire) begin
        for (int k = 0; k < DISPATCH_WIDTH; k++) begin
          // A load's other fields come with it at AG (nothing reads them before)
          if (ds_valid[k] && ds_uop[k].d.cls == C_LD) begin
            logic [LIW-1:0] i;
            i = ds_ren[k].lq[LIW-1:0];
            lq_v_q[i]    <= 1'b1;
            lq_st_q[i]   <= L_WAIT;
            lq_pav_q[i]  <= 1'b0;
            lq_pck_q[i]  <= 1'b0;
            lq_mc_q[i]   <= 1'b0;
          end
          if (ds_valid[k] && ds_uop[k].d.cls == C_ST) begin
            logic [SIW-1:0] i;
            i = ds_ren[k].sq[SIW-1:0];
            sq_v_q[i]    <= 1'b1;
            sq_av_q[i]   <= 1'b0;
            sq_dv_q[i]   <= 1'b0;
            sq_exc_q[i]  <= 1'b0;
            sq_mmio_q[i] <= 1'b0;
            sq_tag_q[i]  <= ds_ren[k].src2;
            sq_fp_q[i]   <= EXT_FD && ds_uop[k].d.rs2_fp;
            sq_dr_q[i]   <= ds_src2_rdy[k] ||
                            ((EXT_FD && ds_uop[k].d.rs2_fp) ? fsnoop(ds_ren[k].src2, fp_we, fp_widx)
                                                            : snoop(ds_ren[k].src2, rf_we, rf_widx));
            sq_amo_q[i]  <= ds_uop[k].d.amo;
            sq_amw_q[i]  <= 1'b0;
            sq_tlb_q[i]  <= 1'b0;
            sq_pden_q[i] <= 1'b0;
            if (ds_uop[k].d.amo) begin                 // the dispatch group's thread's slot
              am_v_q[t_ds]   <= 1'b1;
              am_rob_q[t_ds] <= ds_ren[k].rob;
              am_sq_q[t_ds]  <= ds_ren[k].sq;
              am_dv_q[t_ds]  <= ds_uop[k].d.rd_en;
              am_dst_q[t_ds] <= preg_idx(ds_ren[k].dst);
              am_llt_q[t_ds] <= ds_ren[k].llt;
              am_op_q[t_ds]  <= ds_uop[k].d.amo_op;
            end
          end
        end
        lq_tail_q[t_ds] <= lq_add_t(lq_tail_q[t_ds], nld_ds(), t_ds, md);
        sq_tail_q[t_ds] <= sq_add_t(sq_tail_q[t_ds], nst_ds(), t_ds, md);
      end

      // ---- Flush: uncommitted loads and stores go ----
      if (flush) begin
        for (int i = 0; i < LQ_ENTRIES; i++) if (fl_lq[i]) lq_v_q[i] <= 1'b0;   // t_fl's half
        lq_tail_q[t_fl] <= lq_head_q[t_fl];
        for (int i = 0; i < SQ_ENTRIES; i++) begin
          if (fl_sq[i] && !sq_inwin(i, sq_head_q[t_fl], sq_cmt_q[t_fl])) sq_v_q[i] <= 1'b0;
        end
        sq_tail_q[t_fl] <= sq_cmt_q[t_fl];
        // (M1 and M2: their ops of the flushed thread do not go on, by kill_t above)
        // A request already out completes on its own; a flushed load's response is dropped.
        if (kill_t[x_t]) begin
          if (xs_q != X_IDLE && !x_st_q) x_kill_q <= 1'b1;
          xr_v_q    <= 1'b0;
          xd_q      <= 1'b0;
        end
        for (int t = 0; t < NT; t++) if (kill_t[t]) am_v_q[t] <= 1'b0;
        if (kill_t[am_t_q]) am_st_q <= AM_IDLE;
      end
      // ---- Step 6: a split with the running thread's window empty moves its pointers to its half's start ----
      if (HART1_ON && mrs_i) begin
        lq_head_q[md.run] <= lq_start(md.run, mdn);
        lq_tail_q[md.run] <= lq_start(md.run, mdn);
        sq_head_q[md.run] <= sq_start(md.run, mdn);
        sq_cmt_q[md.run]  <= sq_start(md.run, mdn);
        sq_tail_q[md.run] <= sq_start(md.run, mdn);
        if (t_dr_q == md.run) sq_hge_q <= sq_ge(part_base(SQ_ENTRIES, md.run, mdn));
      end
    end
  end

  function automatic int nld_ds();
    int n;
    n = 0;
    for (int k = 0; k < DISPATCH_WIDTH; k++) if (ds_valid[k] && ds_uop[k].d.cls == C_LD) n++;
    return n;
  endfunction
  function automatic int nst_ds();
    int n;
    n = 0;
    for (int k = 0; k < DISPATCH_WIDTH; k++) if (ds_valid[k] && ds_uop[k].d.cls == C_ST) n++;
    return n;
  endfunction

  // ================= Where a new load and a store address decide (DR-140 #4) =================
  if (LSU_AG_SPLIT) begin : g_split
    // M1, on registers. AG adds the address and issues the D$ read at the page-offset row.
    logic        ln_v_q, sn_v_q;           // M1 holds a new load / a store address
    logic [63:0] ln_va_q, sn_va_q;
    robid_t      ln_rob_q, sn_rob_q;        // the fields of the ports' payloads that M1 reads
    logic [1:0]  ln_size_q, sn_size_q;
    logic [SIW-1:0] sn_sq_q;               // (the index; the wrap bit is not read)
    tid_t        sn_t_q;
    logic        sn_m_q;                   // its data privilege is M (ck_ms)
    logic        sn_pck_q;                 // it takes the checker at its decision (sa_pck)
    logic        cl_v_q;                   // a store wrote the D$ in the AG cycle of M1's op ...
    logic [PA_W-1:4] cl_row_q;             // ... this row
    logic        cl2_v_q;                  // #11: ... or a cycle before it (the RAM is written a cycle late)
    logic [PA_W-1:4] cl2_row_q;
    always_ff @(posedge clk) begin
      ln_v_q    <= !rst && !kill_t[t_ldag] && ld_ag_valid;
      sn_v_q    <= !rst && !kill_t[t_staag] && sta_ag_valid;
      cl_v_q    <= !rst && st_ack && !st_dropped;
      ln_va_q   <= ld_ag_addr;
      ln_rob_q  <= ld_ag_pl.rob;
      ln_size_q <= ld_ag_pl.mem_size;
      sn_va_q   <= sta_ag_addr;
      sn_rob_q  <= sta_ag_pl.rob;
      sn_size_q <= sta_ag_pl.mem_size;
      sn_sq_q   <= sta_ag_pl.sq[SIW-1:0];
      sn_t_q    <= sta_ag_pl.tid;
      sn_m_q    <= priv_d[sta_ag_pl.tid] == PRIV_M;
      sn_pck_q  <= !xl_t[sta_ag_pl.tid] && !(PMP_FILL && priv_d[sta_ag_pl.tid] == PRIV_M && !pmp_lk_h[sta_ag_pl.tid]);
      cl_row_q  <= st_pa[PA_W-1:4];
      cl2_v_q   <= !rst && DC_PORTB_WREG && cl_v_q;
      cl2_row_q <= cl_row_q;
    end
    assign ln_v    = ln_v_q;
    assign ln_va   = ln_va_q;
    assign ln_rob  = ln_rob_q;
    assign ln_size = ln_size_q;
    assign sn_v    = sn_v_q;
    assign sn_va   = sn_va_q;
    assign sn_rob  = sn_rob_q;
    assign sn_size = sn_size_q;
    assign sn_sq   = sn_sq_q;
    assign sn_t    = sn_t_q;
    // A new load's PA comes in M1, and its D$ read needs only the page offset (VA[11:4]). Every AG
    // op goes on to M1; a new load stops there at a fault, a TLB miss or MMIO.
    assign ag_pa    = ld_ag_valid ? ld_ag_addr[PA_W-1:0] : ag_pt ? pt_pa : lqa_rd[0].pa;
    assign ag_go    = ag_v;
    assign m1pa     = ln_v_q ? nl_pa : m1_pa_q;
    assign m1_clash = (cl_v_q && cl_row_q == m1pa[PA_W-1:4]) || (cl2_v_q && cl2_row_q == m1pa[PA_W-1:4]);
    assign m1_go    = m1_v_q && (!ln_v_q || nl_go);
    assign ln_lq    = m1_lq_q;
    assign ln_lqw   = m1_lq_q;
    // A new load's PMP checker runs in M2 on m2_pa_q: for a load in the pipe, or an MMIO load parked
    // in M1 (check only; its issue can come no earlier than this cycle)
    // The 8-byte flag comes from M1's LQ read, registered (its AG wrote the size a cycle before)
    logic m2_pck_q, m2_mck_q, m2_dbl_q;
    always_ff @(posedge clk) begin
      m2_pck_q <= !rst && !kill_t[t_ln] && ln_v_q && nl_pmpd && nl_go;
      m2_mck_q <= !rst && !kill_t[t_ln] && ln_v_q && nl_pmpd && !nl_exc && !nl_tm && nl_mmio;
      m2_dbl_q <= lq_size_q[m1_lq_q] == 2'd3;
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
      if (rs_q && !rst && (m2_pck_q || m2_mck_q))
        assert (m2_dbl_q == (lq_size_q[m2_lq_q] == 2'd3)) else $error("tg_lsu: M2's 8-byte flag is stale");
`endif
    assign lck_pa  = m2_pa_q;
    assign lck_dbl = m2_dbl_q;
    assign t_lck   = m2_t_q;
    // The checkers' M-mode from registers, a stage ahead (timing: priv_dl_q selected by the thread had headed the
    // shared checker's M-mode compares, into the LQ state's enable; core-2's suggestion). Exact: the data privilege
    // changes only as a trap, an xRET or a serialising CSR write commits, and the flush the next cycle squashes the
    // access caught in between (asserted)
    assign ck_ms   = sn_m_q;
    assign ck_ml   = m2_m_q;
    assign sa_pck  = sn_pck_q;
`ifndef SYNTHESIS
    always_ff @(posedge clk)
      if (rs_q && !rst && (m2_pck_q || m2_mck_q || (m2_rck_q && m2_v_q)) && !kill_t[t_lck])
        assert (ck_ml == (priv_d[t_lck] == PRIV_M)) else $error("tg_lsu: the load check's M-mode flag differs from priv_d");
`endif
    // DR-183 (PMP_FILL): on the shared checker, in a cycle it grants (l_gnt); a replay whose check is pending asks
    // too. Not granted: the load does not complete (l_nok), an MMIO load keeps its check pending (lmc_*)
    assign l_ask   = PMP_FILL && (m2_pck_q || m2_mck_q || (m2_rck_q && m2_v_q));
    assign l_nok   = PMP_FILL && (m2_pck_q || m2_rck_q) && !l_gnt;
    assign lmc_v   = PMP_FILL && m2_mck_q;
    assign lmc_lq  = m2_lq_q;
    assign l_den   = !CK_LD && (PMP_FILL ? (m2_pck_q || m2_rck_q) && l_gnt : m2_pck_q) && !nl_chk[0];
    assign lm_den  = !CK_LD && (PMP_FILL ? m2_mck_q && l_gnt : m2_mck_q) && !nl_chk[0];
    assign m2_ck   = m2_pck_q || m2_rck_q;
    assign m2_mck  = m2_mck_q;
    if (CK_LD) begin : g_mck
      // #13: a parked MMIO load's denial comes the cycle after its grant (g_ckld; its state with the loads', above);
      // the head's issue waits while its load checks and the cycle after
      assign lm_st   = 1'b0;
      assign lm_lq   = lg_lq_q;
      assign mm_hold_p = (m2_mck_q && m2_lq_q == hl) || (lg_v_q && lg_k_q == LG_MMIO && lg_lq_q == hl);
    end else if (LSU_MMIO_PMP_REG) begin : g_mreg
      // #10: the verdict registered, for the state a cycle later; the head's issue waits while its
      // load checks, then on the registered denial (timing: the checker leaves the LQ state's
      // enables, through the issue)
      logic           lm_den_q;
      logic [LIW-1:0] lm_lq_q;
      always_ff @(posedge clk) begin
        lm_den_q <= !rst && !kill_t[t_m2] && lm_den;
        lm_lq_q  <= m2_lq_q;
      end
      assign lm_st   = lm_den_q;
      assign lm_lq   = lm_lq_q;
      assign mm_hold_p = (m2_mck_q && m2_lq_q == hl) || (lm_den_q && lm_lq_q == hl);
    end else begin : g_mnow
      assign lm_st   = lm_den;
      assign lm_lq   = m2_lq_q;
      // (DR-183, PMP_FILL: also while the check waits for the shared checker)
      assign mm_hold_p = (PMP_FILL ? m2_mck_q && !(l_gnt && nl_chk[0]) : lm_den) && m2_lq_q == hl;
    end
    // The store address in M1 this cycle counts as if it were in the SQ already: without the split
    // it would be (written at its AG), so this keeps ordering exact
    // It does not wait for its access-fault checks (PMP, PMA, the high bits): a store that faults
    // traps at commit, and the younger load goes with the flush. It is not in the SQ search (its
    // sq_av_q is written at the end of M1), and the search's result picks it last: it is the youngest
    // when it is in f_lim's region below the slot and the SQ's youngest is not, or in the same region
    // above it (fpu-2's Shannon expansion: byp, the store's DTLB lookup and compare, comes last)
    logic byp, s_lo, sel_s;
    assign byp   = sn_v && t_sn == t_m1 && !sa_mis && !sa_pf && !sa_tm && !kill_t[t_sn] && !sa_mmio && !sa_amo &&
                   sq_inwin(int'(sa_idx), sq_head_q[t_m1], f_lim) &&
                   sa_pa[PA_W-1:3] == m1pa[PA_W-1:3] && |(sa_mask & m1_mask);
    assign s_lo  = sa_idx < f_lim[SIW-1:0];
    // The M1 store is the youngest when no candidate is younger: fc_w has no bit at or above the
    // store's own position in it (its slot, in the upper half when the store is below f_lim's
    // slot), so fc_w < (1 << that position), one carry chain against a bit made from registers
    // (timing: no ORs over the candidates before the final select). SAT-proven equal to the
    // per-region form it replaces (no candidate at or above the store's slot in the youngest's
    // region) for slots below SQ_ENTRIES, and checked against it in simulation
    logic [SIW:0]            s_pos;
    logic [2*SQ_ENTRIES-1:0] s_bit;
    assign s_pos = s_lo ? (SIW+1)'(SQ_ENTRIES) + (SIW+1)'(sa_idx) : (SIW+1)'(sa_idx);
    assign s_bit = (2*SQ_ENTRIES)'(1) << s_pos;
    assign sel_s = byp && (fc_w < s_bit);
`ifndef SYNTHESIS
    logic [SQ_ENTRIES-1:0] ab_sa;                  // the slots at or above the M1 store's
    logic                  r_lo;
    always_comb for (int i = 0; i < SQ_ENTRIES; i++) ab_sa[i] = i >= int'(sa_idx);
    assign r_lo = |fc_lo;
    always_ff @(posedge clk) begin
      if (rs_q && !rst && m1_v_q && sn_v) begin
        assert (int'(sa_idx) < SQ_ENTRIES && int'(f_lim[SIW-1:0]) < SQ_ENTRIES)
          else $error("tg_lsu: an SQ slot beyond SQ_ENTRIES");
        assert (sel_s == (byp && (!q_hit || (s_lo && !r_lo) ||
                                  (s_lo == r_lo && (r_lo ? !(|(fc_lo & ab_sa)) : !(|(fc_sq & ab_sa)))))))
          else $error("tg_lsu: the M1 store's age compare differs from the per-region form");
      end
      // A new load's state write takes its outcome as data: where it decides in M1, its entry is
      // in L_PIPE and no earlier write in the LQ block meets it in this cycle
      if (rs_q && !rst && ln_v && !kill_t[t_ln])
        assert (lq_st_q[ln_lqw] == L_PIPE &&
                !(((ld_ag_valid && !kill_t[t_ldag]) || ag_rp) && ag_lq == ln_lqw) &&
                !(m2_v_q && !m2_pt_q && m2_lq_q == ln_lqw) && !(lm_st && lm_lq == ln_lqw) &&
                !(xr_take && x_lq_q == ln_lqw) &&
                !(xs_q == X_WAIT && !x_st_q && !x_kill_q && x_lq_q == ln_lqw))
          else $error("tg_lsu: another LQ state write meets a new load's where it decides");
    end
`endif
    assign f_hit   = q_hit || byp;
    assign f_oh    = sel_s ? SQ_ENTRIES'(1) << sa_idx : q_oh;
    assign f_cover = sel_s ? (sa_mask & m1_mask) == m1_mask : q_cover;
    assign f_data  = sel_s ? sq_dv_q[sa_idx] : q_data;
  end else begin : g_nosplit
    // AG, on its own signals
    assign ln_v    = ld_ag_valid;
    assign ln_va   = ld_ag_addr;
    assign ln_rob  = ld_ag_pl.rob;
    assign ln_size = ld_ag_pl.mem_size;
    assign sn_v    = sta_ag_valid;
    assign sn_va   = sta_ag_addr;
    assign sn_rob  = sta_ag_pl.rob;
    assign sn_size = sta_ag_pl.mem_size;
    assign sn_sq   = sta_ag_pl.sq[SIW-1:0];
    assign sn_t    = sta_ag_pl.tid;
    assign ag_pa   = ld_ag_valid ? nl_pa : ag_pt ? pt_pa : lqa_rd[0].pa;
    assign ag_go   = ag_v && (!ld_ag_valid || nl_go);
    // A store write to the same 16-byte row in the AG cycle: the load read old data
    logic ag_clash, m1_clash_q;
    logic st_wr_q;                                 // #11: a store wrote the cycle before (its RAM write is now)
    logic [PA_W-1:4] st_row_q;
    always_ff @(posedge clk) begin
      st_wr_q  <= !rst && DC_PORTB_WREG && st_ack && !st_dropped;
      st_row_q <= st_pa[PA_W-1:4];
    end
    assign ag_clash = (st_ack && !st_dropped && st_pa[PA_W-1:4] == ag_pa[PA_W-1:4]) ||
                      (st_wr_q && st_row_q == ag_pa[PA_W-1:4]);
    always_ff @(posedge clk) m1_clash_q <= ag_clash;
    assign m1pa     = m1_pa_q;
    assign m1_clash = m1_clash_q;
    assign m1_go    = m1_v_q;
    assign ln_lq    = ld_ag_pl.lq[LIW-1:0];
    assign ln_lqw   = ag_lq;                       // = ln_lq while a new load decides: one decoder with AG's writes
    // A new load's PMP checker runs in M1 on m1_pa_q (a load going on, or an MMIO load parked at AG:
    // its issue can come from this cycle, so it is held on the verdict here and in M2), and the
    // verdict takes effect in M2
    logic m1_pck_q, m1_mck_q, m2_lden_q, m2_mden_q;
    logic m2_lng_q;                                // DR-183 (PMP_FILL): the M2 load's check was not granted in M1
    always_ff @(posedge clk) begin
      m1_pck_q  <= !rst && !kill_t[t_ldag] && ld_ag_valid && nl_pmpd && nl_go;
      m1_mck_q  <= !rst && !kill_t[t_ldag] && ld_ag_valid && nl_pmpd && !nl_exc && !nl_tm && nl_mmio;
      m2_lden_q <= !rst && !kill_t[t_m1] && (PMP_FILL ? (m1_pck_q || m1_rck_q) && l_gnt : m1_pck_q) && !nl_chk[0];
      m2_mden_q <= !rst && !kill_t[t_m1] && (PMP_FILL ? m1_mck_q && l_gnt : m1_mck_q) && !nl_chk[0];
      m2_lng_q  <= PMP_FILL && !rst && (m1_pck_q || m1_rck_q) && !l_gnt;
    end
    // DR-183 (PMP_FILL): on the shared checker in M1, as in g_split in M2, with the outcome registered
    assign l_ask   = PMP_FILL && (m1_pck_q || m1_mck_q || (m1_rck_q && m1_v_q));
    assign l_nok   = m2_lng_q;
    logic unused_rck;                              // (the check is in M1 here)
    assign unused_rck = ^{m2_rck_q, m2_m_q};
    assign lmc_v   = PMP_FILL && m1_mck_q;
    assign lmc_lq  = m1_lq_q;
    assign lck_pa  = m1_pa_q;
    assign lck_dbl = lq_size_q[m1_lq_q] == 2'd3;
    assign t_lck   = m1_t_q;
    assign ck_ms   = priv_d[t_sn] == PRIV_M;
    assign ck_ml   = priv_d[t_lck] == PRIV_M;
    assign sa_pck  = !xl_s && !(PMP_FILL && priv_d[t_sn] == PRIV_M && !pmp_lk_h[t_sn]);
    assign l_den   = m2_lden_q;
    assign m2_ck   = 1'b0;                        // (#13's loads' side needs the split: CK_LD)
    assign m2_mck  = 1'b0;
    assign lm_den  = m2_mden_q;
    assign lm_st   = m2_mden_q;
    assign lm_lq   = m2_lq_q;
    // (#10 here: the hold in M1 does not wait for the verdict)
    assign mm_hold_p = (m1_mck_q && (LSU_MMIO_PMP_REG || !(PMP_FILL ? l_gnt && nl_chk[0] : nl_chk[0])) &&
                        m1_lq_q == hl) ||
                     (m2_mden_q && m2_lq_q == hl);
    assign f_hit    = q_hit;
    assign f_oh     = q_oh;
    assign f_cover  = q_cover;
    assign f_data   = q_data;
    logic unused_fc_w;                             // read by the split's age compare only
    assign unused_fc_w = ^fc_w;
  end

  logic unused;
  assign unused = ^{lm_ans_v, lm_ans_wait, lm_ans_e, m_done, m_wake_any, mshr_idle,  // DR-149's (one is read per DC_MSHRS)
                    ld_ag_pl, sta_ag_pl, mmio_d_i.opcode, mmio_d_i.param, mmio_d_i.size,
                    mmio_d_i.source, mmio_d_i.sink, lq_tail_q, pw_ack[0], pw_who[2],
                    pmp_hit_ld, pmp_rwx_ld};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && !flush) begin
      if (ld_ag_valid) assert (lq_v_q[ld_ag_pl.lq[LIW-1:0]]) else $error("tg_lsu: AG for a free LQ entry");
      if (sta_ag_valid) assert (sq_v_q[sa_idx_ag]) else $error("tg_lsu: STA for a free SQ entry");
      assert (!(am_req && am_ack && cap_v)) else $error("tg_lsu: atomic and data capture write together");
      if (rs_q)                     // two registers: from the first reset on (the SoC's core reset is a register)
        for (int i = 0; i < SQ_ENTRIES; i++)
          assert (sq_hge_q[i] == (i >= int'(sq_head_q[t_dr_q][SIW-1:0]))) else $error("tg_lsu: the SQ head's mask is stale");
      // ext_al and the head-port reads rest on these
      if (m2_v_q && !m2_pt_q)
        assert (!misal(m2_pa_q[2:0], lq_size_q[m2_lq_q])) else $error("tg_lsu: a misaligned load at M2");
      if (xs_q == X_WAIT && !x_st_q && mmio_d_valid_i)
        assert (!misal(x_pa_q[2:0], x_size_q)) else $error("tg_lsu: a misaligned MMIO load");
      if (am_st_q == AM_REQ || am_st_q == AM_RES)
        assert (t_dr_q == am_t_q && sq_head_q[am_t_q] == am_sq_q[am_t_q] && sq_cmt_q[am_t_q] == am_sq_q[am_t_q] &&
                !misal(am_pa[2:0], am_size))
          else $error("tg_lsu: an atomic that is not its thread's SQ head and commit point, or misaligned");
    end
  end
  // No flush meets an MMIO read whose request is out or whose value waits to retire (DR-176): the
  // read issues only at the ROB head, with every older instruction retired, so no mispredict,
  // replay, exception or serialising flush of an older one can come; its own access fault comes
  // with its response; and no interrupt is taken from its issue's cycle (mm_go waits for none) to
  // its retirement (mmio_busy). A flush of its thread here would have the read run twice (SD1's lost interrupt;
  // the other thread's flushes do not touch it, M7's step 4: tg_core's +xflush sends them here)
  logic x_out;                      // an MMIO read out: sent, or its value waiting to retire
  assign x_out = (xs_q != X_IDLE && !x_st_q) || xr_v_q || xd_q;
  always_ff @(posedge clk)
    if (rs_q && !rst)
      assert (!(kill_t[x_t] && x_out)) else $error("tg_lsu: a flush meets an MMIO read already sent (it would run twice)");
  // Shadows of the blocking store's fields, written on the verdict as before (m2_out == O_STQ),
  // match the fields wherever these are read (in L_STQ)
  sqid_t [LQ_ENTRIES-1:0] blk_chk_q;
  logic  [LQ_ENTRIES-1:0] part_chk_q;
  always_ff @(posedge clk) begin
    if (m2_v_q && !m2_pt_q && !kill_t[t_m2] && m2_out == O_STQ) begin
      blk_chk_q[m2_lq_q]  <= m2_fid;
      part_chk_q[m2_lq_q] <= !m2_fcov_q;
    end
    if (rs_q && !rst)
      for (int i = 0; i < LQ_ENTRIES; i++)
        if (lq_v_q[i] && lq_st_q[i] == L_STQ)
          assert (lq_blk_q[i] == blk_chk_q[i] && lq_part_q[i] == part_chk_q[i])
            else $error("tg_lsu: a blocked load's store fields differ from the verdict's");
  end
  // The probe hold is the one a count cleared at the reservation's end gives (per hart)
  logic [NT-1:0][6:0] rsv_hold_chk_q;
  always_ff @(posedge clk)
    for (int t = 0; t < NT; t++) begin
      if (rst || !rsv_v_d[t])                                    rsv_hold_chk_q[t] <= '0;
      else if (am_req && am_ack && am_lr && am_t_q == tid_t'(t)) rsv_hold_chk_q[t] <= 7'(RSV_HOLD);
      else if (rsv_hold_chk_q[t] != '0)                          rsv_hold_chk_q[t] <= rsv_hold_chk_q[t] - 1'b1;
      if (rs_q && !rst)
        assert (pr_hold_t[t] == (rsv_hold_chk_q[t] != '0)) else $error("tg_lsu: the probe hold differs from the cleared count's");
    end
  // The store-data capture's one-hot choices are sq_oldest's, and its tags and FP flag theirs
  always_ff @(posedge clk)
    if (rs_q && !rst)
      assert (cap_ia == sq_oldest(ca_s, sq_hge_q) && cap_if == sq_oldest(cf_s, sq_hge_q) &&
              sd_tag == sq_tag_q[cap_ia] && fsd_tag == sq_tag_q[cap_if] && cap_fp == sq_fp_q[cap_idx])
        else $error("tg_lsu: the store-data capture's one-hot choices differ from sq_oldest's");
`endif
  // Board debug (tg_core's dbg_o): the atomic's state, the SQ head's flags, the D$'s word
  assign dbg_o = {dc_dbg, sq_head_q[t_dr_q] != sq_tail_q[t_dr_q], sq_dr_q[dh], sq_dv_q[dh], sq_av_q[dh], sq_v_q[dh],
                  |am_v_q, 2'(am_st_q)};
`ifndef SYNTHESIS
  // (timing) the threads carried from the payloads and the registered masks are the entries' own, from the first
  // reset on: the masks every cycle, each thread while its stage holds a load or store
  always_ff @(posedge clk)
    if (md_rs && !rst) begin
      for (int t = 0; t < NT; t++)
        assert (lq_ot[t] == lq_own(tid_t'(t), md) && sq_ot[t] == sq_own(tid_t'(t), md))
          else $error("tg_lsu: a registered thread mask differs from the mode's");
      if (ld_ag_valid) assert (t_ldag == lq_tid(int'(ld_ag_pl.lq[LIW-1:0]), md))
        else $error("tg_lsu: a load's thread differs from its LQ entry's");
      if (sta_ag_valid) assert (t_staag == sq_tid(int'(sa_idx_ag), md))
        else $error("tg_lsu: a store's thread differs from its SQ entry's");
      if (m1_v_q && !m1_pt_q) assert (m1_t_q == lq_tid(int'(m1_lq_q), md))
        else $error("tg_lsu: M1's thread differs from its LQ entry's");
      if (m2_v_q && !m2_pt_q) assert (m2_t_q == lq_tid(int'(m2_lq_q), md))
        else $error("tg_lsu: M2's thread differs from its LQ entry's");
      if (sn_v) assert (sn_t == sq_tid(int'(sn_sq), md)) else $error("tg_lsu: a deciding store's thread differs from its SQ entry's");
    end
`endif
endmodule
