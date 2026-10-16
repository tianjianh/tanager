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
  input  logic                         flush,
  // Dispatch
  input  logic                         ds_fire,
  input  logic [DISPATCH_WIDTH-1:0]    ds_valid,
  input  uop_t [DISPATCH_WIDTH-1:0]    ds_uop,
  input  ren_t [DISPATCH_WIDTH-1:0]    ds_ren,
  output lqid_t                        lq_head_o,
  output sqid_t                        sq_head_o,
  output sqid_t                        sq_cmt_o,
  // Address generation from tg_exec (EX of the LD and STA ports)
  input  logic                         ld_ag_valid,
  input  iq_pl_t                       ld_ag_pl,
  input  logic [63:0]                  ld_ag_addr,
  input  logic                         sta_ag_valid,
  input  iq_pl_t                       sta_ag_pl,
  input  logic [63:0]                  sta_ag_addr,
  output logic                         ld_block,      // registered: IQ-LD select blocked
  // Load results
  output logic                         ld_m2_will,
  output logic [PIDX_W-1:0]            ld_m2_dst,
  output logic                         ld_res_valid,
  output logic [PIDX_W-1:0]            ld_res_dst,
  output logic [63:0]                  ld_res_data,
  output logic [NCOL-1:0]              wake_ld,       // LLTs confirmed this cycle
  output logic [LLT_ENTRIES-1:0]       llt_done,      // load bank written this cycle
  // FP loads (EXT_FD): F1 written by P4 straight from the result register, announced at M2
  output logic                         fld_m2_will,
  output logic [FPIDX_W-1:0]           fld_m2_idx,
  output logic                         fld_valid,
  output logic [FPIDX_W-1:0]           fld_idx,
  output logic [63:0]                  fld_data,
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
  output logic                         spx_valid,     // a store's PMP denial, found after it decided (S3)
  output robid_t                       spx_rob,
  output logic [1:0]                   sth_v,         // commit stops before these stores: S2, S3
  output robid_t [1:0]                 sth_rob,
  // From the ROB / commit
  input  robid_t                       rob_head,
  input  logic [idx_w(COMMIT_WIDTH + 1)-1:0] cm_nld,  // loads retiring this cycle
  input  logic [idx_w(COMMIT_WIDTH + 1)-1:0] cm_nst,  // stores retiring this cycle
  input  sqid_t [COMMIT_WIDTH-1:0]     tr_sq,          // trace: committed stores' fields
  output logic [COMMIT_WIDTH-1:0]      tr_st_wr,       // ... the store wrote memory (atomics)
  output logic [COMMIT_WIDTH-1:0][63:0] tr_st_va,
  output logic [COMMIT_WIDTH-1:0][63:0] tr_st_data,
  output logic [COMMIT_WIDTH-1:0][1:0] tr_st_size,
  output logic                         sq_drained,    // no committed store left
  output logic                         mmio_busy,     // an MMIO load or an atomic: no interrupt
  input  logic                         rsv_clr,       // trap or xRET: the LR reservation ends
  // Translation and PMP (M3)
  input  priv_e                        priv,          // fetch walks
  input  priv_e                        priv_d,        // loads and stores
  input  logic                         sum,
  input  logic                         mxr,
  input  logic                         satp_sv39,
  input  logic [43:0]                  satp_ppn,
  input  pmp_d_t [15:0]                pmp_d,
  input  logic [15:0][2:0]             pmp_pal,
  input  logic                         tlb_flush,
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
  output logic                         iw_ack,
  output logic                         iw_done,
  output logic                         iw_ok,
  output logic [3:0]                   iw_cause,
  output logic                         it_fill,
  output logic [26:0]                  it_fill_vpn,
  output logic [1:0]                   it_fill_lvl,
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
  output logic                         mmio_d_ready_o
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
  // result's destination, LLT and format.
  typedef struct packed {
    robid_t            rob;
    logic              dv;                         // writes a register
    logic              fp;                         // ... an f register (EXT_FD)
    logic              uns;                        // zero-extends (FP: raw bits)
    logic [PIDX_W-1:0] dst;
    llt_t              llt;
    logic [63:0]       va;
  } lqc_t;
  logic [2:0][LIW-1:0]               lqc_ra;       // M2, the MMIO load, the LQ head
  lqc_t [2:0]                        lqc_rd;
  lqc_t                              lqc_wd;
  logic [0:0][LIW-1:0]               lqr_ra;       // the ordering violation's ROB index
  robid_t [0:0]                      lqr_rd;
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
  sqid_t  [LQ_ENTRIES-1:0]           lq_blk_q;     // blocking store
  logic   [LQ_ENTRIES-1:0]           lq_part_q;    // ... partial overlap (wait until it leaves)
  lqid_t                             lq_head_q, lq_tail_q;

  // ---- SQ ----
  logic   [SQ_ENTRIES-1:0]           sq_v_q;
  // The ROB index and size, written at STA and read only by index, live in LUTRAM (u_sqrob,
  // u_sqsz): the store-data completion and the head's DTLB retry read the index; the trace and
  // forwarding read the size
  logic [1:0][SIW-1:0]               sqrob_ra;     // the captured store, the commit point
  robid_t [1:0]                      sqrob_rd;
  logic [COMMIT_WIDTH:0][SIW-1:0]    sqsz_ra;      // the trace's stores, the forwarding store
  logic [COMMIT_WIDTH:0][1:0]        sqsz_rd;
  logic   [SQ_ENTRIES-1:0]           sq_av_q, sq_dv_q, sq_mmio_q, sq_exc_q;
  // VA and data in LUTRAM: the VA for the trace, the head's walk and tval; the data for the
  // trace, forwarding, the drain and atomics. The CAMs use the PA and masks in flip-flops.
  localparam int SVR = COMMIT_WIDTH + 1;          // SQ VA reads: trace, the commit point (head walk, atomic)
  localparam int SDR = COMMIT_WIDTH + 2;          // SQ data reads: trace, forwarding, the head (drain, atomic)
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
  sqid_t                             sq_head_q, sq_cmt_q, sq_tail_q;

  assign lq_head_o = lq_head_q;
  logic [LIW-1:0] hl;                             // the LQ head's slot
  assign hl = lq_head_q[LIW-1:0];
  assign sq_head_o = sq_head_q;
  assign sq_cmt_o  = sq_cmt_q;
  assign sq_drained = sq_head_q == sq_cmt_q;

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
  function automatic logic [SIW-1:0] sq_oldest(input logic [SQ_ENTRIES-1:0] v, input logic [SIW-1:0] h);
    logic [SQ_ENTRIES-1:0] hi;
    for (int i = 0; i < SQ_ENTRIES; i++) hi[i] = v[i] && i >= int'(h);
    return |hi ? sq_first(hi) : sq_first(v);
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

  // ---- Commit-side trace reads ----
  for (genvar j = 0; j < COMMIT_WIDTH; j++) begin : g_tr
    assign sqva_ra[j]    = tr_sq[j][SIW-1:0];
    assign sqd_ra[j]     = tr_sq[j][SIW-1:0];
    assign tr_st_va[j]   = sqva_rd[j];
    assign tr_st_data[j] = sqd_rd[j];
    assign sqsz_ra[j]    = tr_sq[j][SIW-1:0];
    assign tr_st_size[j] = sqsz_rd[j];
    assign tr_st_wr[j]   = !sq_amo_q[tr_sq[j][SIW-1:0]] || sq_amw_q[tr_sq[j][SIW-1:0]];
  end

  // ---- D$ ----
  logic              dc_rd_en;
  logic [PA_W-1:0]   dc_rd_pa;
  logic [PA_W-1:0]   m1_pa;
  logic              dc_hit;
  logic [63:0]       dc_dword;
  logic              lm_req;
  logic [PA_W-1:0]   lm_pa;
  logic              mshr_idle, deny_v;
  logic [PA_W-1:6]   deny_line;
  logic              st_req, st_ack;
  logic [PA_W-1:0]   st_pa;
  logic [15:0]       st_mask;
  logic [63:0]       st_wdata;
  logic              am_req, am_ack, am_den, lose_v;
  logic [PA_W-1:0]   am_pa;
  logic [15:0]       am_wmask;
  logic [63:0]       am_wdata;
  logic [63:0]       am_rdata;
  logic [PA_W-1:6]   lose_line;
  tg_dcache u_dc (
    .clk, .rst, .ready,
    .ld_rd_en(dc_rd_en), .ld_rd_pa(dc_rd_pa), .ld_m1_pa(m1_pa), .ld_hit(dc_hit), .ld_dword(dc_dword),
    .lm_req, .lm_pa, .mshr_idle, .deny_v, .deny_line,
    .st_req, .st_pa, .st_mask, .st_wdata, .st_ack, .st_dropped,
    .am_req, .am_pa, .am_wmask, .am_wdata, .am_ack, .am_rdata, .am_den, .lose_v, .lose_line,
    .a_o(l1d_a_o), .a_valid_o(l1d_a_valid_o), .a_ready_i(l1d_a_ready_i),
    .b_i(l1d_b_i), .b_valid_i(l1d_b_valid_i), .b_ready_o(l1d_b_ready_o),
    .c_o(l1d_c_o), .c_valid_o(l1d_c_valid_o), .c_ready_i(l1d_c_ready_i),
    .d_i(l1d_d_i), .d_valid_i(l1d_d_valid_i), .d_ready_o(l1d_d_ready_o),
    .e_o(l1d_e_o), .e_valid_o(l1d_e_valid_o), .e_ready_i(l1d_e_ready_i));

  // ================= AG =================
  // A replay takes the AG slot when the LD port has nothing in EX.
  logic [LQ_ENTRIES-1:0] rp_ready;
  for (genvar i = 0; i < LQ_ENTRIES; i++) begin : g_rpr
    assign rp_ready[i] = lq_v_q[i] && lq_st_q[i] == L_READY;
  end
  logic             rp_any;
  logic [LIW-1:0]   rp_idx;
  assign rp_any = |rp_ready;
  assign rp_idx = lq_oldest(rp_ready, lqi(lq_head_q));

  // ---- DTLB: LD port, STA port, the ROB head ----
  logic xl_d;                                   // data accesses translate
  assign xl_d = EXT_SU && satp_sv39 && priv_d != PRIV_M;
  logic [2:0][26:0] dt_vpn;
  logic [2:0]       dt_hit;
  tlb_pte_t [2:0]   dt_pte;
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
  logic        s2_v_q, s2_go, s2_den;            // S2: a store's PMP check, the cycle after it decides (STA)
  logic [SIW-1:0] s2_idx_q;
  // Three lookups: the LD port, the STA port, and the ROB head's check. The head's check has a
  // port of its own (timing: on a shared port the head VA and the store's address reached each
  // other's checks, paths that are never live together), and still counts only when STA is
  // idle, as when it shared STA's port.
  assign dt_vpn[0] = ln_va[38:12];
  assign dt_vpn[1] = sn_va[38:12];
  assign dt_vpn[2] = hd_va[38:12];
  tg_tlb #(.NE(DTLB_ENTRIES), .NR(3), .CAM(1'b1)) u_dtlb (
    .clk, .rst, .vpn(dt_vpn), .hit(dt_hit), .pte(dt_pte), .fill(dt_fill),
    .fill_vpn(pw_vpn), .fill_lvl(pw_lvl), .fill_pte(pw_pte), .flush(tlb_flush));

  // ---- New load from the LD port: translate and check (replays reuse the LQ's PA) ----
  // A translated access to a PMP-homogeneous page uses the DTLB's cached PMP result (plan
  // §4.10) where it decides; bare-mode accesses and pages with a region boundary inside use the
  // checker, which runs on the registered PA after the decision (M1, or M2 with the split:
  // g_split / g_nosplit). A denial it finds faults the load in M2 (an MMIO load: L_MMIO -> L_EXC,
  // its issue held until then).
  logic [PA_W-1:0] nl_pa;
  logic        nl_mis, nl_pf, nl_tm, nl_acc, nl_mmio, nl_exc, nl_go, nl_pmpc, nl_pmpd;
  logic [0:0]  nl_chk;
  logic [PA_W-1:0] lck_pa;                        // the checker's access: a registered PA and size
  logic        lck_dbl;
  logic        l_den, lm_den, mm_hold;            // denied: the load in M2; an MMIO load (check only); the head's
  logic [LIW-1:0] lm_lq;                          // ... the MMIO load's LQ entry
  pma_e        nl_pma;
  assign nl_pa   = xl_d ? {dt_pte[0].ppn, ln_va[11:0]} : ln_va[PA_W-1:0];
  assign nl_mis  = misal(ln_va[2:0], ln_size);
  assign nl_pf   = xl_d && !nl_mis && !va_canon(ln_va);
  assign nl_tm   = xl_d && !nl_mis && !nl_pf && !(dt_hit[0] && pte_ok(dt_pte[0], ACC_R, priv_d, sum, mxr));
  assign nl_pma  = pma_of(nl_pa);
  logic       pmp_hit_ld, pmp_hit_st;
  logic [2:0] pmp_rwx_ld, pmp_rwx_st;
  tg_pmp #(.S(1)) u_pmp_ld (.pa(lck_pa), .dbl(lck_dbl), .acc(ACC_R),
                            .m_mode(priv_d == PRIV_M), .d(pmp_d), .ok(nl_chk), .hit(pmp_hit_ld),
                            .rwx(pmp_rwx_ld));
  assign nl_pmpc = xl_d && dt_pte[0].ph;          // the cached result applies
  assign nl_pmpd = !nl_pmpc;                      // ... else the checker decides, later
  assign nl_acc  = (xl_d ? dt_pte[0].big : ln_va[63:PA_W] != '0) || nl_pma == PMA_NONE ||
                   (nl_pmpc && !dt_pte[0].pr);
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
  assign ag_pt   = !ld_ag_valid && pt_req && !flush;
  assign ag_rp   = !ld_ag_valid && !pt_req && rp_any && !flush;
  assign ag_v    = (ld_ag_valid || ag_pt || ag_rp) && !flush;
  assign ag_lq   = ld_ag_valid ? ld_ag_pl.lq[LIW-1:0] : rp_idx;
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
  logic [PA_W-1:0]   m1_pa_q;
  logic [PA_W-1:0]   m1pa;                           // M1's PA (with the split: a new load's from the DTLB)
  logic              m1_clash, m1_go;                // the AG row clash; M1 goes on to M2
  logic [LIW-1:0]    ln_lq;                          // a new load's LQ entry where it decides
  logic [LIW-1:0]    ln_lqw;                         // ... as its LQ flip-flops are written (no split: AG's index)
  assign m1_pa    = m1pa;
  logic [7:0]        m1_mask;
  assign m1_mask = bmask(m1pa[2:0], lq_size_q[m1_lq_q]);

  // Youngest older store with a byte overlap in the same dword: the search over the SQ's stores
  // (q_*), and with the split, the store address in M1 selected last (g_split / g_nosplit)
  logic              f_hit, f_cover, f_data;
  logic [SQ_ENTRIES-1:0] f_oh;                      // the forwarding store, one-hot (encoded in M2)
  sqid_t                 f_lim;                     // the stores in [head, f_lim) are older
  logic [SQ_ENTRIES-1:0] fc_sq;                     // overlapping older stores in the SQ
  logic              q_hit, q_lo, q_cover, q_data;  // ... any; the youngest is below f_lim's slot; covers; data
  logic [SQ_ENTRIES-1:0] q_oh;                      // ... the youngest, one-hot
  assign f_lim = lq_sq_q[m1_lq_q];
  always_comb begin
    for (int i = 0; i < SQ_ENTRIES; i++)
      fc_sq[i] = sq_v_q[i] && sq_av_q[i] && !sq_mmio_q[i] && !sq_amo_q[i] && sq_inwin(i, sq_head_q, f_lim) &&
                 sq_pa_q[i][PA_W-1:3] == m1pa[PA_W-1:3] && |(sq_mask_q[i] & m1_mask);
  end
  // The youngest as a one-hot vector selects the per-entry cover and data-valid bits, formed in
  // parallel from flip-flops, and goes to M2 as it is, encoded there (timing: no index encode or
  // multiplexer after the search)
  always_comb begin
    logic [SQ_ENTRIES-1:0] fc_lo, oh_lo, oh_all, cov;
    logic                  run_lo, run_all;
    for (int i = 0; i < SQ_ENTRIES; i++) fc_lo[i] = fc_sq[i] && i < int'(f_lim[SIW-1:0]);
    run_lo  = 1'b0;
    run_all = 1'b0;
    for (int i = SQ_ENTRIES - 1; i >= 0; i--) begin
      oh_lo[i]  = fc_lo[i] && !run_lo;
      oh_all[i] = fc_sq[i] && !run_all;
      run_lo    = run_lo || fc_lo[i];
      run_all   = run_all || fc_sq[i];
    end
    for (int i = 0; i < SQ_ENTRIES; i++) cov[i] = (sq_mask_q[i] & m1_mask) == m1_mask;
    q_hit   = |fc_sq;
    q_lo    = |fc_lo;
    q_oh    = q_lo ? oh_lo : oh_all;
    q_cover = |(q_oh & cov);
    q_data  = |(q_oh & sq_dv_q);
  end


  // ================= M2 =================
  logic              m2_v_q, m2_clash_q, m2_hit_q, m2_fhit_q, m2_fcov_q, m2_fdat_q, m2_pt_q;
  logic [LIW-1:0]    m2_lq_q;
  logic [PA_W-1:0]   m2_pa_q;
  logic [63:0]       m2_dword_q, m2_fdword;
  logic [SQ_ENTRIES-1:0] m2_foh_q;                  // the forwarding store, one-hot
  logic [SIW-1:0]    m2_fidx;                       // ... its index
  always_comb begin
    m2_fidx = '0;
    for (int i = 0; i < SQ_ENTRIES; i++) if (m2_foh_q[i]) m2_fidx |= SIW'(i);
  end
  sqid_t             m2_fid;
  assign m2_fid = sq_id(int'(m2_fidx), sq_head_q);
  // The forwarded data, read in M2 at the forwarding store's index (timing: the M1 search ends at
  // m2_foh_q). Data that was in at M1 (m2_fdat_q) does not change; data captured since is not used.
  assign sqsz_ra[COMMIT_WIDTH] = m2_fidx;
  assign m2_fdword = rep(sqd_rd[COMMIT_WIDTH], sqsz_rd[COMMIT_WIDTH]);   // LUTRAM reads at m2_fidx

  typedef enum logic [2:0] { O_OK, O_STQ, O_MISS, O_RETRY, O_FAULT } m2_out_e;
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
      m2_out_w = (deny_v && deny_line == m2_pa_q[PA_W-1:6]) ? O_FAULT : O_MISS;
    end
    m2_val = ext_al(dw, m2_pa_q[2:0], lq_size_q[m2_lq_q], lqc_rd[0].uns);
  end
  assign m2_out = l_den ? O_FAULT : m2_out_w;     // a PMP denial found after the decision: first
  // PTE reads: the cache's dword (no forwarding: the deciding walk runs with the SQ drained)
  logic m2_ok, pt_rsp, pt_hit, pt_den;
  assign pt_rsp = m2_v_q && m2_pt_q && !flush;
  assign pt_hit = m2_hit_q && !m2_clash_q;
  assign pt_den = !m2_hit_q && deny_v && deny_line == m2_pa_q[PA_W-1:6];
  // The wakeups do not wait for the PMP checker (m2_okw): a load it denies faults, and the dependents
  // it woke read a stale value and go with the trap's flush (the flush frees its LLT)
  logic m2_okw;
  // (m2_out_w == O_OK, written out: the denied-line compare only chooses between two outcomes that
  // are not O_OK, so it stays off the wakeup path)
  assign m2_okw = m2_v_q && !m2_pt_q && !flush &&
                  (m2_fhit_q ? m2_fcov_q && m2_fdat_q : !m2_clash_q && m2_hit_q);
  assign m2_ok  = m2_okw && !l_den;
  // The miss request does not wait for the PMP checker either (timing: it feeds the D$'s port
  // arbitration): a load it denies faults, and only the line's refill may go ahead, a cacheable
  // line (device and unmapped addresses never reach M2's miss), its data written to no register
  assign lm_req = m2_v_q && !flush && (m2_pt_q ? !m2_hit_q && !m2_clash_q && !pt_den : m2_out_w == O_MISS);
  assign lm_pa  = m2_pa_q;
  assign ld_m2_will  = m2_okw && lqc_rd[0].dv && !lqc_rd[0].fp;
  assign ld_m2_dst   = lqc_rd[0].dst;
  assign fld_m2_will = EXT_FD && m2_okw && lqc_rd[0].dv && lqc_rd[0].fp;
  assign fld_m2_idx  = FPIDX_W'(lqc_rd[0].dst);

  // ================= MMIO =================
  typedef enum logic [1:0] { X_IDLE, X_REQ, X_WAIT } xstate_e;
  xstate_e         xs_q;
  logic            x_st_q;                 // the request is a store (from the drain)
  logic            x_kill_q;               // a load request whose load was flushed
  logic [LIW-1:0]  x_lq_q;
  logic [PA_W-1:0] x_pa_q;
  logic [1:0]      x_size_q;
  logic [63:0]     x_wdata_q;
  logic            xr_v_q;                 // a load response waits for the result register
  logic [63:0]     xr_data_q;
  logic            xd_q;                   // ... and has completed, until a load retires
  logic            am_v_q;                 // an atomic is in the window
  // An interrupt must not separate an MMIO load or an atomic from its commit (side effects)
  assign mmio_busy = (xs_q != X_IDLE && !x_st_q) || xr_v_q || xd_q || am_v_q;

  // MMIO load: the ROB head, no committed store left, port free. A load at the ROB head is
  // the oldest in the window, so it is the LQ head.
  logic            mm_go, mm_cand;
  logic [LIW-1:0]  mm_idx;
  assign mm_idx  = hl;
  assign mm_cand = lq_v_q[hl] && lq_st_q[hl] == L_MMIO && lqc_rd[2].rob == rob_head;

  // Drain: the SQ head once committed
  logic [SIW-1:0] dh;
  assign dh = sq_head_q[SIW-1:0];
  logic dr_v, dr_amo;
  assign dr_v   = sq_v_q[dh] && sq_head_q != sq_cmt_q;
  assign dr_amo = dr_v && sq_amo_q[dh];      // performed before commit: leaves without a write
  logic dr_mmio_go;
  assign dr_mmio_go = dr_v && sq_mmio_q[dh] && xs_q == X_IDLE && !xr_v_q;
  assign mm_go = mm_cand && !dr_v && xs_q == X_IDLE && !xr_v_q && !flush && !mm_hold;
  assign st_req   = dr_v && !sq_mmio_q[dh] && !sq_amo_q[dh];
  assign st_pa    = sqh.pa;
  assign st_mask  = {8'b0, sqh.mask} << {sqh.pa[3], 3'b000};
  assign st_wdata = rep(sqd_rd[COMMIT_WIDTH+1], sqh.size);
  logic dr_pop;
  assign dr_pop = (st_req && st_ack) || dr_amo ||
                  (xs_q == X_WAIT && x_st_q && mmio_d_valid_i);

  always_comb begin
    mmio_a_o = '0;
    mmio_a_o.opcode  = x_st_q ? A_PUT_FULL : A_GET;
    mmio_a_o.size    = {1'b0, x_size_q};
    mmio_a_o.source  = '0;
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
  logic            r_fv_q;                    // the result writes F1 (EXT_FD)
  logic [PIDX_W-1:0] r_dst_q;
  logic [63:0]     r_data_q;
  robid_t          r_rob_q;
  llt_t            r_llt_q;
  assign ld_res_valid = r_v_q && r_dv_q && !r_fv_q;
  assign fld_valid    = r_fv_q;
  assign fld_idx      = FPIDX_W'(r_dst_q);
  assign fld_data     = r_data_q;
  assign ld_res_dst   = r_dst_q;
  assign ld_res_data  = r_data_q;
  assign ld_cmp_valid = r_v_q;
  assign ld_cmp_rob   = r_rob_q;
  assign ld_cmp_mmio  = r_mmio_q;
  always_comb begin
    llt_done = '0;
    if (r_v_q && r_dv_q) llt_done[r_llt_q] = 1'b1;
  end
  // An MMIO response takes the result register when M2 does not
  logic xr_take;
  assign xr_take = xr_v_q && !m2_ok && !flush;

  // ================= Atomics =================
  // AM_IDLE -> (ROB head, address and data known, older stores drained) -> AM_REQ: the D$ holds
  // the line in T and reads and writes it in two cycles, or three with DC_AMO_READ_REG
  // (am_ack) -> AM_RES: rd through the result register -> AM_DONE until the flush that follows
  // its commit. An SC without a reservation for its line fails without touching memory.
  typedef enum logic [1:0] { AM_IDLE, AM_REQ, AM_RES, AM_DONE } amstate_e;
  amstate_e          am_st_q;
  robid_t            am_rob_q;
  sqid_t             am_sq_q;
  logic              am_dv_q;
  logic [PIDX_W-1:0] am_dst_q;
  llt_t              am_llt_q;
  logic [4:0]        am_op_q;
  logic [63:0]       am_res_q;              // rd: the old value, or the SC outcome
  logic              rsv_v_q;               // the LR reservation: one 64-byte line (Za64rs)
  logic [PA_W-1:6]   rsv_line_q;
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
  assign am_lr    = am_op_q == AMO_LR;
  assign am_sc    = am_op_q == AMO_SC;
  assign am_go    = am_v_q && am_st_q == AM_IDLE && sq_v_q[dh] && sq_av_q[dh] && sq_dv_q[dh] &&
                    sq_head_q == am_sq_q && rob_head == am_rob_q && !(s2_v_q && s2_idx_q == dh) && !flush;
  // Its PMP check (S2) denied it: it faults as it starts, without an access. It starts only after
  // that check (timing: the checker's verdict, which the walker's address also reaches, stays off
  // the atomic's start)
  logic            pden_go, am_pden_q;
  assign pden_go  = sq_pden_q[dh];
  // The reservation covers the SC's line and has not just been lost (probe, eviction)
  assign rsv_ok   = rsv_v_q && rsv_line_q == am_pa[PA_W-1:6] && !(lose_v && lose_line == rsv_line_q);
  assign rsv_ok_go = rsv_v_q && rsv_line_q == sqh.pa[PA_W-1:6] && !(lose_v && lose_line == rsv_line_q);
  assign am_req   = am_st_q == AM_REQ && !flush && !am_pden_q;
  assign am_old   = ext_al(am_rdata, am_pa[2:0], am_size, 1'b0);
  assign am_new   = amo_alu(am_op_q, am_size == 2'd2, am_old, am_b_q);
  assign am_wr    = !am_lr && (!am_sc || rsv_ok);
  assign am_wmask = (am_req && am_ack && am_wr) ? {8'b0, bmask(am_pa[2:0], am_size)} << {am_pa[3], 3'b000}
                                                 : 16'h0;
  assign am_wdata = rep(am_new, am_size);
  assign am_take  = am_st_q == AM_RES && !m2_ok && !xr_take && !flush;

  logic            rsv_v_d;
  logic [PA_W-1:6] rsv_line_d;
  always_comb begin
    rsv_v_d    = rsv_v_q;
    rsv_line_d = rsv_line_q;
    if (am_req && am_ack && am_lr) begin
      rsv_v_d    = 1'b1;
      rsv_line_d = am_pa[PA_W-1:6];
    end
    // every SC ends it
    if ((am_go && am_sc && !rsv_ok_go && !pden_go) || (am_req && (am_ack || am_den) && am_sc)) rsv_v_d = 1'b0;
    if (lose_v && lose_line == rsv_line_d) rsv_v_d = 1'b0;
    if (rsv_clr) rsv_v_d = 1'b0;
  end
  // Loads wake their LLT the cycle before the register file is written
  always_comb begin
    wake_ld = '0;
    if (m2_okw && lqc_rd[0].dv) wake_ld[llt_col(int'(lqc_rd[0].llt))] = 1'b1;
    if (xr_take && lqc_rd[1].dv) wake_ld[llt_col(int'(lqc_rd[1].llt))] = 1'b1;
    if (am_take && am_dv_q) wake_ld[llt_col(int'(am_llt_q))] = 1'b1;
  end

  // ================= Store data capture =================
  // The oldest store whose data is ready captures it; while P4 takes the shared read port
  // (sd_busy, late: P4's issue) only an FP store can, the oldest ready one. Both choices are
  // formed without sd_busy, which picks between them last. Each read tag takes its own choice:
  // sd_tag is read only when the port is free, and fsd_tag's value is used only when an FP store
  // captures, which is then the oldest ready FP store in either case.
  logic           cap_v;
  logic [SIW-1:0] cap_idx, cap_ia, cap_if;
  always_comb begin
    logic [SQ_ENTRIES-1:0] ca, cf;
    for (int i = 0; i < SQ_ENTRIES; i++) begin
      ca[i] = sq_v_q[i] && !sq_dv_q[i] && sq_dr_q[i];
      cf[i] = ca[i] && sq_fp_q[i];
    end
    cap_ia  = sq_oldest(ca, sq_head_q[SIW-1:0]);
    cap_if  = sq_oldest(cf, sq_head_q[SIW-1:0]);
    cap_v   = (sd_busy ? |cf : |ca) && !flush;
    cap_idx = sd_busy ? cap_if : cap_ia;
  end
  assign sd_tag  = sq_tag_q[cap_ia];
  assign fsd_tag = sq_tag_q[cap_if];

  // ================= STA =================
  logic [SIW-1:0] sa_idx;
  logic [7:0]     sa_mask;
  pma_e           sa_pma;
  logic           sa_mis, sa_pf, sa_tm, sa_acc, sa_exc, sa_mmio, sa_ok, sa_amo, sa_lr, sa_pmpc;
  logic [0:0]     sa_chk;
  logic [PA_W-1:0] sa_pa;
  acc_e           sa_at;
  logic [SIW-1:0] sa_idx_ag;                    // AG's entry (its ROB index, size and VA go in at AG)
  assign sa_idx_ag = sta_ag_pl.sq[SIW-1:0];
  assign sa_idx  = sn_sq;
  assign sa_amo  = sq_amo_q[sa_idx];
  assign sa_lr   = sa_amo && am_op_q == AMO_LR;    // LR faults and translates as a load
  assign sa_at   = sa_lr ? ACC_R : ACC_W;
  assign sa_mask = bmask(sn_va[2:0], sn_size);
  assign sa_pa   = xl_d ? {dt_pte[1].ppn, sn_va[11:0]} : sn_va[PA_W-1:0];
  assign sa_mis  = misal(sn_va[2:0], sn_size);
  assign sa_pf   = xl_d && !sa_mis && !va_canon(sn_va);
  assign sa_tm   = xl_d && !sa_mis && !sa_pf && !(dt_hit[1] && pte_ok(dt_pte[1], sa_at, priv_d, sum, mxr));
  assign sa_pma  = pma_of(sa_pa);
  // PMP: a translated store to a PMP-homogeneous page decides with the DTLB's cached result
  // (plan §4.10), and a bare-mode store with the checker on its VA (a register with the split; no
  // walk runs in bare mode, so the walker never wants the checker then). A translated store to a
  // page with a region boundary inside decides as if PMP allowed it, and the checker looks at its
  // registered PA in S2, the next cycle (below).
  assign sa_pmpc = xl_d && dt_pte[1].ph;
  // atomics only in main memory (interfaces.md §2.4)
  assign sa_acc  = (xl_d ? dt_pte[1].big : sn_va[63:PA_W] != '0) ||
                   (sa_pmpc && !(sa_lr ? dt_pte[1].pr : dt_pte[1].pw)) || (!xl_d && !sa_chk[0]) ||
                   sa_pma == PMA_NONE || sa_pma == PMA_ROM || (sa_amo && sa_pma != PMA_MEM);
  assign sa_exc  = sa_mis || sa_pf || (!sa_tm && sa_acc);
  assign sa_mmio = sa_pma == PMA_DEVICE && !sa_amo;
  assign sa_ok   = sn_v && !sa_exc && !sa_tm && !flush;

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
  // store uses the checker at its decision: data are bare, so no walk runs.
  logic [PA_W-1:0] pc_pa;
  logic            pc_dbl, pw_chk, w_use;
  logic            s2_amo_q, s2_m_q, s2_dbl_q, s3_den_q;
  acc_e            s2_at_q;
  logic [PA_W-1:0] s2_pa_q;
  robid_t          s2_rob_q, s3_rob_q;
  assign w_use  = pw_chk && !sn_v;
  assign s2_go  = s2_v_q && !w_use;
  assign s2_den = s2_go && !sa_chk[0] && !flush;
  tg_pmp #(.S(1)) u_pmp_st (.pa(!xl_d ? sn_va[PA_W-1:0] : w_use ? pc_pa : s2_pa_q),
                            .dbl(!xl_d ? sn_size == 2'd3 : w_use ? pc_dbl : s2_dbl_q),
                            .acc(!xl_d ? sa_at : w_use ? ACC_R : s2_at_q),
                            .m_mode(!xl_d ? priv_d == PRIV_M : !w_use && s2_m_q),
                            .d(pmp_d), .ok(sa_chk), .hit(pmp_hit_st), .rwx(pmp_rwx_st));
  always_ff @(posedge clk) begin
    s2_v_q   <= !rst && !flush && ((sa_ok && xl_d && !sa_pmpc) || (s2_v_q && !s2_go));
    if (sn_v) begin                                // (never while S2 waits: then no store decided)
      s2_pa_q  <= sa_pa;
      s2_dbl_q <= sn_size == 2'd3;
      s2_at_q  <= sa_at;
      s2_m_q   <= priv_d == PRIV_M;
      s2_amo_q <= sa_amo;
      s2_rob_q <= sn_rob;
      s2_idx_q <= sa_idx;
    end
    s3_den_q <= !rst && !flush && s2_den && !s2_amo_q;
    s3_rob_q <= s2_rob_q;
  end
  assign spx_valid  = s3_den_q;
  assign spx_rob    = s3_rob_q;
  assign sth_v[0]   = s2_v_q && !s2_amo_q;
  assign sth_rob[0] = s2_rob_q;
  assign sth_v[1]   = s3_den_q;
  assign sth_rob[1] = s3_rob_q;

  // Ordering check: the oldest younger load that has its value (or is in M1/M2) and overlaps
  // (a load is younger than the store when the store is in [head, the load's lq_sq))
  logic           rp_v_c, rp_v_q;
  logic [LIW-1:0] rp_ra_c, rp_ra_q;
  always_comb begin
    logic [LQ_ENTRIES-1:0] oc;
    for (int i = 0; i < LQ_ENTRIES; i++)
      oc[i] = lq_v_q[i] && lq_pav_q[i] && (lq_st_q[i] == L_DONE || lq_st_q[i] == L_PIPE) &&
              sq_inwin(int'(sa_idx), sq_head_q, lq_sq_q[i]) &&
              lq_pa_q[i][PA_W-1:3] == sa_pa[PA_W-1:3] &&
              |(bmask(lq_pa_q[i][2:0], lq_size_q[i]) & sa_mask);
    rp_v_c  = sa_ok && |oc;
    rp_ra_c = lq_oldest(oc, lqi(lq_head_q));
  end
  // The report goes out a cycle later from flip-flops: the load's LQ index, whose ROB index the
  // LUTRAM reads then (timing: the read leaves the search). No AG load writes that entry in the
  // search's cycle, as the load is live (asserted)
  always_ff @(posedge clk) begin
    rp_v_q  <= !rst && !flush && rp_v_c;
    rp_ra_q <= rp_ra_c;
  end
`ifndef SYNTHESIS
  logic rs_q;                       // the core has been reset: the checks wait for it (tg_rob)
  initial rs_q = 1'b0;
  always @(posedge clk) if (rst) rs_q <= 1'b1;
  always_ff @(posedge clk)
    if (rs_q && !rst && !flush && rp_v_c && ld_ag_valid)
      assert (ld_ag_pl.lq[LIW-1:0] != rp_ra_c) else $error("tg_lsu: an AG load writes a replayed load's LQ entry");
`endif
  assign lqr_ra[0]    = rp_ra_q;
  assign replay_valid = rp_v_q;
  assign replay_rob   = lqr_rd[0];

  // ================= ROB reports =================
  always_comb begin
    exc_valid = '0; exc_rob = '0; exc_cause = '0;      // (tval: the VA at the head, hd_lva/hd_sva)
    // The AG and M2 ports' ROB indices and causes do not wait for their fault decision: the ROB
    // reads them only with exc_valid, and its age compares then start early
    exc_rob[0]   = ln_rob;
    exc_cause[0] = nl_mis ? EXC_LMISALIGN : nl_pf ? EXC_LPAGE : EXC_LACCESS;
    exc_rob[1]   = lqc_rd[0].rob;
    exc_cause[1] = EXC_LACCESS;
    exc_rob[3]   = sn_rob;
    exc_cause[3] = sa_mis ? (sa_lr ? EXC_LMISALIGN : EXC_SMISALIGN) :
                   sa_pf  ? (sa_lr ? EXC_LPAGE : EXC_SPAGE) : (sa_lr ? EXC_LACCESS : EXC_SACCESS);
    // loads: AG checks of a new load, or a denied line at M2
    if (ln_v && !flush && nl_exc) exc_valid[0] = 1'b1;
    if (((m2_v_q && m2_out == O_FAULT) || lm_den) && !flush) exc_valid[1] = 1'b1;  // lm_lq is m2_lq_q
    if (xs_q == X_WAIT && !x_st_q && !x_kill_q && mmio_d_valid_i && (mmio_d_i.denied || mmio_d_i.corrupt)
        && !flush) begin
      exc_valid[2] = 1'b1;
      exc_rob[2]   = lqc_rd[1].rob;
      exc_cause[2] = EXC_LACCESS;
    end else if ((am_req && am_den) || (am_st_q == AM_REQ && am_pden_q && !flush)) begin  // its line or PMP denied it
      exc_valid[2] = 1'b1;
      exc_rob[2]   = am_rob_q;
      exc_cause[2] = am_lr ? EXC_LACCESS : EXC_SACCESS;
    end
    if (sn_v && !flush && sa_exc) exc_valid[3] = 1'b1;
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
  logic [SIW-1:0] hs;
  logic           hd_ld, hd_st, hd_need, hd_tok, hdf_q;
  logic [3:0]     hdc_q;
  acc_e           hd_at;
  assign hs       = sq_cmt_q[SIW-1:0];
  assign hd_ld    = lq_v_q[hl] && lq_st_q[hl] == L_TLB && lqc_rd[2].rob == rob_head;
  assign hd_st    = sq_v_q[hs] && sq_tlb_q[hs] && sqrob_rd[1] == rob_head && sq_cmt_q != sq_tail_q;
  assign hd_va    = hd_ld ? lqc_rd[2].va : sqva_rd[COMMIT_WIDTH];
  assign hd_at    = (hd_ld || (sq_amo_q[hs] && am_op_q == AMO_LR)) ? ACC_R : ACC_W;
  assign hd_tlb   = hd_ld || hd_st;
  assign hd_need  = hd_tlb && !flush;
  assign hd_tok   = !sta_ag_valid && dt_hit[2] && pte_ok(dt_pte[2], hd_at, priv_d, sum, mxr);
  // The ROB sees the head's DTLB retry a cycle later (DR-140 #3; timing: the head's DTLB lookup
  // leaves the commit redirect). The head is the same op in both cycles: a TLB-missed head leaves
  // only through a flush.
  logic hd_tok_q, hd_need_q;
  always_ff @(posedge clk) begin
    hd_tok_q  <= hd_tok;
    hd_need_q <= hd_need;
  end
  assign hd_retry = hd_need && hd_need_q && hd_tok_q;
  assign hd_fault = hd_need && hdf_q;
  assign hd_cause = hdc_q;
  assign hd_lva   = lqc_rd[2].va;
  assign hd_sva   = sqva_rd[COMMIT_WIDTH];

  // A DTLB miss at AG: the ROB entry replays at the head; the walker prefetches the translation
  assign tlbm_valid[0] = ln_v && !flush && nl_tm;
  assign tlbm_rob[0]   = ln_rob;
  assign tlbm_valid[1] = sn_v && !flush && sa_tm;
  assign tlbm_rob[1]   = sn_rob;
  logic        dpf_v_q;
  logic [63:0] dpf_va_q;
  acc_e        dpf_at_q;

  // The walker: the head's deciding walk, fetch, data prefetch
  logic [2:0]       pw_req, pw_ack, pw_who;
  logic [2:0][63:0] pw_va;
  acc_e [2:0]       pw_at;
  priv_e [2:0]      pw_mode;
  logic             pw_done, pw_ok;
  logic [3:0]       pw_cause;
  assign pw_req[0]  = hd_need && !sta_ag_valid && !hd_tok && !hdf_q && sq_drained;
  assign pw_va[0]   = hd_va;
  assign pw_at[0]   = hd_at;
  assign pw_mode[0] = priv_d;
  assign pw_req[1]  = iw_req && EXT_SU;
  assign pw_va[1]   = iw_va;
  assign pw_at[1]   = ACC_X;
  assign pw_mode[1] = priv;
  assign pw_req[2]  = dpf_v_q;
  assign pw_va[2]   = dpf_va_q;
  assign pw_at[2]   = dpf_at_q;
  assign pw_mode[2] = priv_d;
  tg_ptw u_ptw (
    .clk, .rst, .flush, .satp_ppn, .sum, .mxr, .pmp_d, .pmp_pal,
    .chk_pa(pc_pa), .chk_dbl(pc_dbl), .chk_req(pw_chk), .chk_gnt(!sn_v), .chk_ok(sa_chk[0]),
    .chk_hit(pmp_hit_st), .chk_rwx(pmp_rwx_st),
    .req(pw_req), .req_va(pw_va), .req_acc(pw_at), .req_mode(pw_mode), .ack(pw_ack),
    .pt_req, .pt_pa, .pt_gnt, .pt_rsp, .pt_hit, .pt_den, .pt_data(m2_dword_q), .mshr_idle,
    .done(pw_done), .done_who(pw_who), .done_ok(pw_ok), .done_cause(pw_cause),
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

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      hdf_q   <= 1'b0;
      dpf_v_q <= 1'b0;
    end else begin
      if (pw_done && pw_who[0] && !pw_ok) begin
        hdf_q <= 1'b1;
        hdc_q <= pw_cause;
      end
      if (pw_ack[2]) dpf_v_q <= 1'b0;
      if (!dpf_v_q || pw_ack[2]) begin
        if (tlbm_valid[0]) begin
          dpf_v_q  <= 1'b1;
          dpf_va_q <= ln_va;
          dpf_at_q <= ACC_R;
        end else if (tlbm_valid[1]) begin
          dpf_v_q  <= 1'b1;
          dpf_va_q <= sn_va;
          dpf_at_q <= sa_at;
        end
      end
    end
  end

  // Replay or PTE read pending: block IQ-LD's select so the AG slot frees
  always_ff @(posedge clk) begin
    if (rst || flush) ld_block <= 1'b0;
    else              ld_block <= |rp_ready || pt_req;
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
  if (EXT_FD && FPIDX_W > PIDX_W) begin : g_bad_fpidx
    $error("tg_lsu: the LQ keeps an FP load's F1 index in its PIDX_W-bit destination field");
  end
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
                    uns: ld_ag_pl.mem_uns, dst: preg_idx(ld_ag_pl.dst), llt: ld_ag_pl.llt,
                    va: ld_ag_addr};
  tg_ram_lut #(.DEPTH(LQ_ENTRIES), .WIDTH($bits(lqc_t)), .NR(3)) u_lqc (
    .clk, .we(ld_ag_valid && !flush), .waddr(ld_ag_pl.lq[LIW-1:0]), .wdata(lqc_wd), .raddr(lqc_ra),
    .rdata(lqc_rd));
  tg_ram_lut #(.DEPTH(LQ_ENTRIES), .WIDTH(ROBW), .NR(1)) u_lqrob (
    .clk, .we(ld_ag_valid && !flush), .waddr(ld_ag_pl.lq[LIW-1:0]), .wdata(ld_ag_pl.rob), .raddr(lqr_ra),
    .rdata(lqr_rd));
  // LUTRAM copies of the address fields the CAMs keep in flip-flops, for the reads by index: a
  // replay's address and the MMIO load's (the LQ head); the SQ head's, for the drain, an MMIO
  // store and an atomic
  assign lqa_ra[0] = rp_idx;
  assign lqa_ra[1] = hl;
  tg_ram_lut #(.DEPTH(LQ_ENTRIES), .WIDTH($bits(lqa_t)), .NR(2)) u_lqa (
    .clk, .we(ln_v && !flush), .waddr(ln_lq),
    .wdata(lqa_t'{pa: nl_pa, size: ln_size}), .raddr(lqa_ra), .rdata(lqa_rd));
  logic [0:0][SIW-1:0] sqh_ra;
  sqh_t [0:0]          sqh_rd;
  assign sqh_ra[0] = dh;
  tg_ram_lut #(.DEPTH(SQ_ENTRIES), .WIDTH($bits(sqh_t)), .NR(1)) u_sqh (
    .clk, .we(sn_v && !flush), .waddr(sa_idx),
    .wdata(sqh_t'{pa: sa_pa, mask: sa_mask, size: sn_size}), .raddr(sqh_ra), .rdata(sqh_rd));
  assign sqh = sqh_rd[0];
  assign sqrob_ra[0] = cap_idx;
  assign sqrob_ra[1] = hs;
  tg_ram_lut #(.DEPTH(SQ_ENTRIES), .WIDTH(ROBW), .NR(2)) u_sqrob (
    .clk, .we(sta_ag_valid && !flush), .waddr(sa_idx_ag), .wdata(sta_ag_pl.rob), .raddr(sqrob_ra),
    .rdata(sqrob_rd));
  tg_ram_lut #(.DEPTH(SQ_ENTRIES), .WIDTH(2), .NR(COMMIT_WIDTH + 1)) u_sqsz (
    .clk, .we(sta_ag_valid && !flush), .waddr(sa_idx_ag), .wdata(sta_ag_pl.mem_size), .raddr(sqsz_ra),
    .rdata(sqsz_rd));
  assign sqva_ra[COMMIT_WIDTH]   = hs;            // at an atomic, hs is its entry and the head
  tg_ram_lut #(.DEPTH(SQ_ENTRIES), .WIDTH(64), .NR(SVR)) u_sqva (
    .clk, .we(sta_ag_valid && !flush), .waddr(sa_idx_ag), .wdata(sta_ag_addr), .raddr(sqva_ra),
    .rdata(sqva_rd));
  // Data: captured from the register file, or written by an atomic (the value it stored)
  assign sqd_ra[COMMIT_WIDTH]   = m2_fidx;
  assign sqd_ra[COMMIT_WIDTH+1] = dh;
  assign sqd_we = (am_req && am_ack) || cap_v;
  assign sqd_wa = (am_req && am_ack) ? dh : cap_idx;
  // The source as one encoded select from early terms, so a data bit is one LUT6 (P4's FP bank
  // select folds in here): 0 the atomic's value, 1 integer, 2 FP bank 0, 3 FP bank 1
  logic [1:0] sqd_s;
  assign sqd_s = (am_req && am_ack) ? 2'd0
               : (EXT_FD && sq_fp_q[cap_idx]) ? {1'b1, fpreg_bank(fsd_tag)} : 2'd1;
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
      lq_head_q <= '0;
      lq_tail_q <= '0;
      sq_v_q    <= '0;
      sq_head_q <= '0;
      sq_cmt_q  <= '0;
      sq_tail_q <= '0;
      m1_v_q    <= 1'b0;
      m2_v_q    <= 1'b0;
      r_v_q     <= 1'b0;
      r_fv_q    <= 1'b0;
      xs_q      <= X_IDLE;
      xr_v_q    <= 1'b0;
      x_kill_q  <= 1'b0;
      xd_q      <= 1'b0;
      am_v_q    <= 1'b0;
      am_st_q   <= AM_IDLE;
      rsv_v_q   <= 1'b0;
    end else begin
      // ---- Commit ----
      for (int k = 0; k < COMMIT_WIDTH; k++) begin
        if (k < int'(cm_nld)) lq_v_q[lqi(lq_add(lq_head_q, k))] <= 1'b0;
      end
      lq_head_q <= lq_add(lq_head_q, int'(cm_nld));
      sq_cmt_q  <= sq_add(sq_cmt_q, int'(cm_nst));

      // ---- Drain ----
      if (dr_pop) begin
        sq_v_q[dh] <= 1'b0;
        sq_head_q  <= sq_add(sq_head_q, 1);
      end

      // ---- MMIO ----
      unique case (xs_q)
        X_IDLE: begin
          if (dr_mmio_go) begin
            xs_q      <= X_REQ;
            x_st_q    <= 1'b1;
            x_pa_q    <= sqh.pa;
            x_size_q  <= sqh.size;
            x_wdata_q <= sqd_rd[COMMIT_WIDTH+1];
          end else if (mm_go) begin
            xs_q      <= X_REQ;
            x_st_q    <= 1'b0;
            x_kill_q  <= 1'b0;
            x_lq_q    <= mm_idx;
            x_pa_q    <= lqa_rd[1].pa;                // mm_idx is the LQ head
            x_size_q  <= lqa_rd[1].size;
          end
        end
        X_REQ: if (mmio_a_ready_i) xs_q <= X_WAIT;
        X_WAIT: if (mmio_d_valid_i) begin
          xs_q <= X_IDLE;
          if (!x_st_q && !x_kill_q && !flush) begin
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
      if (xr_take)             xd_q <= 1'b1;
      else if (cm_nld != '0)   xd_q <= 1'b0;

      // ---- Atomics ----
      rsv_v_q    <= rsv_v_d;
      rsv_line_q <= rsv_line_d;
      unique case (am_st_q)
        AM_IDLE: if (am_go) begin
          am_pa_q   <= sqh.pa;
          am_size_q <= sqh.size;
          am_b_q    <= sqd_rd[COMMIT_WIDTH+1];
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
      if (m2_ok) begin
        r_v_q    <= 1'b1;
        r_dv_q   <= lqc_rd[0].dv;
        r_fv_q   <= EXT_FD && lqc_rd[0].dv && lqc_rd[0].fp;
        r_dst_q  <= lqc_rd[0].dst;
        r_data_q <= m2_val | {{32{EXT_FD && lqc_rd[0].fp && lq_size_q[m2_lq_q] == 2'd2}}, 32'b0};
        r_rob_q  <= lqc_rd[0].rob;
        r_llt_q  <= lqc_rd[0].llt;
        r_mmio_q <= 1'b0;
      end else if (xr_take) begin
        r_v_q    <= 1'b1;
        r_dv_q   <= lqc_rd[1].dv;
        r_fv_q   <= EXT_FD && lqc_rd[1].dv && lqc_rd[1].fp;
        r_dst_q  <= lqc_rd[1].dst;
        r_data_q <= xr_data_q | {{32{EXT_FD && lqc_rd[1].fp && lq_size_q[x_lq_q] == 2'd2}}, 32'b0};
        r_rob_q  <= lqc_rd[1].rob;
        r_llt_q  <= lqc_rd[1].llt;
        r_mmio_q <= 1'b1;
        lq_st_q[x_lq_q] <= L_DONE;
      end else if (am_take) begin
        r_v_q    <= 1'b1;
        r_dv_q   <= am_dv_q;
        r_fv_q   <= 1'b0;
        r_dst_q  <= am_dst_q;
        r_data_q <= am_res_q;
        r_rob_q  <= am_rob_q;
        r_llt_q  <= am_llt_q;
        r_mmio_q <= 1'b0;
      end

      // ---- M2 outcome ----
      if (m2_v_q && !m2_pt_q && !flush) begin
        unique case (m2_out)
          O_OK:    lq_st_q[m2_lq_q] <= L_DONE;
          O_STQ: begin
            lq_st_q[m2_lq_q]   <= L_STQ;
            lq_blk_q[m2_lq_q]  <= m2_fid;
            lq_part_q[m2_lq_q] <= !m2_fcov_q;
          end
          O_MISS:  lq_st_q[m2_lq_q] <= L_MISS;
          O_RETRY: lq_st_q[m2_lq_q] <= L_READY;
          default: lq_st_q[m2_lq_q] <= L_EXC;
        endcase
      end
      if (lm_den && !flush) lq_st_q[lm_lq] <= L_EXC;   // an MMIO load the PMP checker denied

      // ---- M1 -> M2 ----
      m2_v_q      <= m1_go && !flush;
      m2_lq_q     <= m1_lq_q;
      m2_pa_q     <= m1pa;
      m2_clash_q  <= m1_clash;
      m2_hit_q    <= dc_hit;
      m2_dword_q  <= dc_dword;
      m2_fhit_q   <= f_hit;
      m2_fcov_q   <= f_cover;
      m2_fdat_q   <= f_data;
      m2_foh_q    <= f_oh;
      m2_pt_q     <= m1_pt_q;

      // ---- AG -> M1 ----
      m1_v_q     <= ag_go;
      m1_pt_q    <= ag_pt;
      m1_lq_q    <= ag_lq;
      m1_pa_q    <= ag_pa;
      if (ld_ag_valid && !flush) begin                 // AG: into the pipe
        lq_pav_q[ag_lq]  <= 1'b0;
        lq_st_q[ag_lq]   <= L_PIPE;
        lq_sq_q[ag_lq]   <= ld_ag_pl.sq;               // (the cold fields: u_lqc)
        lq_size_q[ag_lq] <= ld_ag_pl.mem_size;
      end else if (ag_rp) begin
        lq_st_q[ag_lq]  <= L_PIPE;
      end
      // A new load's PA and outcome where it decides: in AG (over the lines above), or in M1 with
      // the split
      if (ln_v && !flush) begin
        lq_pa_q[ln_lqw]  <= nl_pa;
        lq_pav_q[ln_lqw] <= !nl_exc && !nl_tm;
        if (nl_exc || nl_tm || nl_mmio) lq_st_q[ln_lqw] <= nl_exc ? L_EXC : nl_tm ? L_TLB : L_MMIO;
      end

      // ---- Waiting loads re-check their condition ----
      for (int i = 0; i < LQ_ENTRIES; i++) begin
        if (lq_v_q[i] && !(ag_v && !ag_pt && ag_lq == LIW'(i)) && !(m2_v_q && !m2_pt_q && m2_lq_q == LIW'(i))) begin
          if (lq_st_q[i] == L_MISS && mshr_idle) lq_st_q[i] <= L_READY;
          if (lq_st_q[i] == L_STQ) begin
            if (!sq_live(lq_blk_q[i], sq_head_q, sq_tail_q) || (!lq_part_q[i] && sq_dv_q[lq_blk_q[i][SIW-1:0]]))
              lq_st_q[i] <= L_READY;
          end
        end
      end
      if (mm_go) lq_st_q[mm_idx] <= L_PIPE;   // MMIO request out (not L_MMIO any more)

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
      if (sn_v && !flush) begin                        // where it decides (rob, size and VA: at AG)
        sq_av_q[sa_idx]   <= !sa_exc && !sa_tm;
        sq_exc_q[sa_idx]  <= sa_exc;
        sq_tlb_q[sa_idx]  <= sa_tm;
        sq_pa_q[sa_idx]   <= sa_pa;
        sq_mask_q[sa_idx] <= sa_mask;
        sq_mmio_q[sa_idx] <= sa_mmio;
      end
      if (s2_den && s2_amo_q) sq_pden_q[s2_idx_q] <= 1'b1;

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
            if (ds_uop[k].d.amo) begin
              am_v_q   <= 1'b1;
              am_rob_q <= ds_ren[k].rob;
              am_sq_q  <= ds_ren[k].sq;
              am_dv_q  <= ds_uop[k].d.rd_en;
              am_dst_q <= preg_idx(ds_ren[k].dst);
              am_llt_q <= ds_ren[k].llt;
              am_op_q  <= ds_uop[k].d.amo_op;
            end
          end
        end
        lq_tail_q <= lq_add(lq_tail_q, nld_ds());
        sq_tail_q <= sq_add(sq_tail_q, nst_ds());
      end

      // ---- Flush: uncommitted loads and stores go ----
      if (flush) begin
        lq_v_q    <= '0;
        lq_tail_q <= lq_head_q;
        for (int i = 0; i < SQ_ENTRIES; i++) begin
          if (!sq_inwin(i, sq_head_q, sq_cmt_q)) sq_v_q[i] <= 1'b0;
        end
        sq_tail_q <= sq_cmt_q;
        m1_v_q    <= 1'b0;
        m2_v_q    <= 1'b0;
        // A request already out completes on its own; a flushed load's response is dropped.
        if (xs_q != X_IDLE && !x_st_q) x_kill_q <= 1'b1;
        if (xs_q == X_IDLE && mm_go) xs_q <= X_IDLE;
        xr_v_q    <= 1'b0;
        xd_q      <= 1'b0;
        am_v_q    <= 1'b0;
        am_st_q   <= AM_IDLE;
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
    logic        cl_v_q;                   // a store wrote the D$ in the AG cycle of M1's op ...
    logic [PA_W-1:4] cl_row_q;             // ... this row
    always_ff @(posedge clk) begin
      ln_v_q    <= !rst && !flush && ld_ag_valid;
      sn_v_q    <= !rst && !flush && sta_ag_valid;
      cl_v_q    <= !rst && st_ack && !st_dropped;
      ln_va_q   <= ld_ag_addr;
      ln_rob_q  <= ld_ag_pl.rob;
      ln_size_q <= ld_ag_pl.mem_size;
      sn_va_q   <= sta_ag_addr;
      sn_rob_q  <= sta_ag_pl.rob;
      sn_size_q <= sta_ag_pl.mem_size;
      sn_sq_q   <= sta_ag_pl.sq[SIW-1:0];
      cl_row_q  <= st_pa[PA_W-1:4];
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
    // A new load's PA comes in M1, and its D$ read needs only the page offset (VA[11:4]). Every AG
    // op goes on to M1; a new load stops there at a fault, a TLB miss or MMIO.
    assign ag_pa    = ld_ag_valid ? ld_ag_addr[PA_W-1:0] : ag_pt ? pt_pa : lqa_rd[0].pa;
    assign ag_go    = ag_v;
    assign m1pa     = ln_v_q ? nl_pa : m1_pa_q;
    assign m1_clash = cl_v_q && cl_row_q == m1pa[PA_W-1:4];
    assign m1_go    = m1_v_q && (!ln_v_q || nl_go);
    assign ln_lq    = m1_lq_q;
    assign ln_lqw   = m1_lq_q;
    // A new load's PMP checker runs in M2 on m2_pa_q: for a load in the pipe, or an MMIO load parked
    // in M1 (check only; its issue can come no earlier than this cycle)
    // The 8-byte flag comes from M1's LQ read, registered (its AG wrote the size a cycle before)
    logic m2_pck_q, m2_mck_q, m2_dbl_q;
    always_ff @(posedge clk) begin
      m2_pck_q <= !rst && !flush && ln_v_q && nl_pmpd && nl_go;
      m2_mck_q <= !rst && !flush && ln_v_q && nl_pmpd && !nl_exc && !nl_tm && nl_mmio;
      m2_dbl_q <= lq_size_q[m1_lq_q] == 2'd3;
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
      if (rs_q && !rst && (m2_pck_q || m2_mck_q))
        assert (m2_dbl_q == (lq_size_q[m2_lq_q] == 2'd3)) else $error("tg_lsu: M2's 8-byte flag is stale");
`endif
    assign lck_pa  = m2_pa_q;
    assign lck_dbl = m2_dbl_q;
    assign l_den   = m2_pck_q && !nl_chk[0];
    assign lm_den  = m2_mck_q && !nl_chk[0];
    assign lm_lq   = m2_lq_q;
    assign mm_hold = lm_den && m2_lq_q == hl;
    // The store address in M1 this cycle counts as if it were in the SQ already: without the split
    // it would be (written at its AG), so this keeps ordering exact
    // It does not wait for its access-fault checks (PMP, PMA, the high bits): a store that faults
    // traps at commit, and the younger load goes with the flush. It is not in the SQ search (its
    // sq_av_q is written at the end of M1), and the search's result picks it last: it is the youngest
    // when it is in f_lim's region below the slot and the SQ's youngest is not, or in the same region
    // above it (fpu-2's Shannon expansion: byp, the store's DTLB lookup and compare, comes last)
    logic byp, s_lo, sel_s;
    assign byp   = sn_v && !sa_mis && !sa_pf && !sa_tm && !flush && !sa_mmio && !sa_amo &&
                   sq_inwin(int'(sa_idx), sq_head_q, f_lim) &&
                   sa_pa[PA_W-1:3] == m1pa[PA_W-1:3] && |(sa_mask & m1_mask);
    assign s_lo  = sa_idx < f_lim[SIW-1:0];
    logic [SQ_ENTRIES-1:0] below_sa;               // the slots below the M1 store's
    always_comb for (int i = 0; i < SQ_ENTRIES; i++) below_sa[i] = i < int'(sa_idx);
    assign sel_s = byp && (!q_hit || (s_lo && !q_lo) || (s_lo == q_lo && |(q_oh & below_sa)));
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
    assign ag_pa   = ld_ag_valid ? nl_pa : ag_pt ? pt_pa : lqa_rd[0].pa;
    assign ag_go   = ag_v && (!ld_ag_valid || nl_go);
    // A store write to the same 16-byte row in the AG cycle: the load read old data
    logic ag_clash, m1_clash_q;
    assign ag_clash = st_ack && !st_dropped && st_pa[PA_W-1:4] == ag_pa[PA_W-1:4];
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
    always_ff @(posedge clk) begin
      m1_pck_q  <= !rst && !flush && ld_ag_valid && nl_pmpd && nl_go;
      m1_mck_q  <= !rst && !flush && ld_ag_valid && nl_pmpd && !nl_exc && !nl_tm && nl_mmio;
      m2_lden_q <= !rst && !flush && m1_pck_q && !nl_chk[0];
      m2_mden_q <= !rst && !flush && m1_mck_q && !nl_chk[0];
    end
    assign lck_pa  = m1_pa_q;
    assign lck_dbl = lq_size_q[m1_lq_q] == 2'd3;
    assign l_den   = m2_lden_q;
    assign lm_den  = m2_mden_q;
    assign lm_lq   = m2_lq_q;
    assign mm_hold = (m1_mck_q && !nl_chk[0] && m1_lq_q == hl) || (m2_mden_q && m2_lq_q == hl);
    assign f_hit    = q_hit;
    assign f_oh     = q_oh;
    assign f_cover  = q_cover;
    assign f_data   = q_data;
    logic unused_q_lo;                             // read by the split's age compare only
    assign unused_q_lo = q_lo;
  end

  logic unused;
  assign unused = ^{ld_ag_pl, sta_ag_pl, mmio_d_i.opcode, mmio_d_i.param, mmio_d_i.size,
                    mmio_d_i.source, mmio_d_i.sink, lq_tail_q, x_lq_q, pw_ack[0], pw_who[2],
                    pmp_hit_ld, pmp_rwx_ld};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && !flush) begin
      if (ld_ag_valid) assert (lq_v_q[ld_ag_pl.lq[LIW-1:0]]) else $error("tg_lsu: AG for a free LQ entry");
      if (sta_ag_valid) assert (sq_v_q[sa_idx_ag]) else $error("tg_lsu: STA for a free SQ entry");
      assert (!(am_req && am_ack && cap_v)) else $error("tg_lsu: atomic and data capture write together");
      // ext_al and the head-port reads rest on these
      if (m2_v_q && !m2_pt_q)
        assert (!misal(m2_pa_q[2:0], lq_size_q[m2_lq_q])) else $error("tg_lsu: a misaligned load at M2");
      if (xs_q == X_WAIT && !x_st_q && mmio_d_valid_i)
        assert (!misal(x_pa_q[2:0], x_size_q)) else $error("tg_lsu: a misaligned MMIO load");
      if (am_st_q == AM_REQ || am_st_q == AM_RES)
        assert (sq_head_q == am_sq_q && sq_cmt_q == am_sq_q && !misal(am_pa[2:0], am_size))
          else $error("tg_lsu: an atomic that is not the SQ head and commit point, or misaligned");
    end
  end
`endif
endmodule
