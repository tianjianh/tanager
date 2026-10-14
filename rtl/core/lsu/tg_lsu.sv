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
module tg_lsu
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_core_pkg::*;
#(
  localparam int NPR = INT_BANKS * INT_PREGS_PER_BANK,
  localparam int LIW = LQW - 1,
  localparam int SIW = SQW - 1
) (
  input  logic                         clk,
  input  logic                         rst,
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
  // Store data
  output preg_t                        sd_tag,
  input  logic [63:0]                  sd_data,
  input  logic [NPR-1:0]               ready_vec,
  // To the ROB
  output logic                         ld_cmp_valid,
  output robid_t                       ld_cmp_rob,
  output logic                         ld_cmp_mmio,
  output logic [1:0]                   st_cmp_valid,
  output robid_t [1:0]                 st_cmp_rob,
  output logic [3:0]                   exc_valid,     // new load (AG), denied line (M2), MMIO load, store
  output robid_t [3:0]                 exc_rob,
  output logic [3:0][3:0]              exc_cause,
  output logic [3:0][63:0]             exc_tval,
  output logic                         replay_valid,
  output robid_t                       replay_rob,
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
  function automatic logic [63:0] ext(input logic [63:0] raw, input logic [1:0] size, input logic uns);
    unique case (size)
      2'd0: return uns ? {56'b0, raw[7:0]}  : {{56{raw[7]}}, raw[7:0]};
      2'd1: return uns ? {48'b0, raw[15:0]} : {{48{raw[15]}}, raw[15:0]};
      2'd2: return uns ? {32'b0, raw[31:0]} : {{32{raw[31]}}, raw[31:0]};
      default: return raw;
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
  function automatic logic misal(input logic [2:0] a, input logic [1:0] size);
    unique case (size)
      2'd0: return 1'b0;
      2'd1: return a[0];
      2'd2: return a[1:0] != 2'b0;
      default: return a[2:0] != 3'b0;
    endcase
  endfunction

  // ---- LQ ----
  typedef enum logic [2:0] {
    L_WAIT  = 3'd0,   // allocated; address not generated yet
    L_PIPE  = 3'd1,   // in M1/M2
    L_DONE  = 3'd2,   // value obtained
    L_MISS  = 3'd3,   // waits for the MSHR to go idle
    L_STQ   = 3'd4,   // waits for a store
    L_MMIO  = 3'd5,   // waits to be the ROB head
    L_READY = 3'd6,   // replays when the AG slot is free
    L_EXC   = 3'd7
  } lstate_e;
  logic   [LQ_ENTRIES-1:0]           lq_v_q;
  lstate_e [LQ_ENTRIES-1:0]          lq_st_q;
  robid_t [LQ_ENTRIES-1:0]           lq_rob_q;
  sqid_t  [LQ_ENTRIES-1:0]           lq_sq_q;      // SQ tail at rename: older stores before it
  logic   [LQ_ENTRIES-1:0]           lq_dv_q;
  logic   [LQ_ENTRIES-1:0][PIDX_W-1:0] lq_dst_q;
  llt_t   [LQ_ENTRIES-1:0]           lq_llt_q;
  logic   [LQ_ENTRIES-1:0][1:0]      lq_size_q;
  logic   [LQ_ENTRIES-1:0]           lq_uns_q;
  logic   [LQ_ENTRIES-1:0][63:0]     lq_va_q;
  logic   [LQ_ENTRIES-1:0]           lq_pav_q;     // address known
  sqid_t  [LQ_ENTRIES-1:0]           lq_blk_q;     // blocking store
  logic   [LQ_ENTRIES-1:0]           lq_part_q;    // ... partial overlap (wait until it leaves)
  lqid_t                             lq_head_q, lq_tail_q;

  // ---- SQ ----
  logic   [SQ_ENTRIES-1:0]           sq_v_q;
  robid_t [SQ_ENTRIES-1:0]           sq_rob_q;
  logic   [SQ_ENTRIES-1:0]           sq_av_q, sq_dv_q, sq_mmio_q, sq_exc_q;
  logic   [SQ_ENTRIES-1:0][63:0]     sq_va_q, sq_data_q;
  logic   [SQ_ENTRIES-1:0][1:0]      sq_size_q;
  logic   [SQ_ENTRIES-1:0][7:0]      sq_mask_q;
  preg_t  [SQ_ENTRIES-1:0]           sq_tag_q;
  logic   [SQ_ENTRIES-1:0]           sq_amo_q;     // an atomic's entry: never forwards or drains
  logic   [SQ_ENTRIES-1:0]           sq_amw_q;     // ... the atomic wrote memory (trace)
  sqid_t                             sq_head_q, sq_cmt_q, sq_tail_q;

  assign lq_head_o = lq_head_q;
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
  function automatic lqid_t lq_id(input int i, input lqid_t head);
    logic w;
    w = (i >= int'(head[LIW-1:0])) ? head[LIW] : !head[LIW];
    return {w, LIW'(i)};
  endfunction

  // ---- Commit-side trace reads ----
  for (genvar j = 0; j < COMMIT_WIDTH; j++) begin : g_tr
    assign tr_st_va[j]   = sq_va_q[tr_sq[j][SIW-1:0]];
    assign tr_st_data[j] = sq_data_q[tr_sq[j][SIW-1:0]];
    assign tr_st_size[j] = sq_size_q[tr_sq[j][SIW-1:0]];
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
  logic [127:0]      st_wdata;
  logic              am_req, am_ack, am_den, lose_v;
  logic [PA_W-1:0]   am_pa;
  logic [15:0]       am_wmask;
  logic [127:0]      am_wdata;
  logic [63:0]       am_rdata;
  logic [PA_W-1:6]   lose_line;
  tg_dcache u_dc (
    .clk, .rst,
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
  always_comb begin
    int best;
    best = LQ_ENTRIES;
    rp_idx = '0;
    for (int i = 0; i < LQ_ENTRIES; i++) begin
      int a;
      a = lq_cnt(lq_id(i, lq_head_q), lq_head_q);
      if (rp_ready[i] && a < best) begin
        best = a;
        rp_idx = LIW'(i);
      end
    end
    rp_any = best != LQ_ENTRIES;
  end

  logic              ag_v, ag_rp;
  logic [LIW-1:0]    ag_lq;
  logic [63:0]       ag_va;
  logic [PA_W-1:0]   ag_pa;
  logic [1:0]        ag_size;
  assign ag_rp   = !ld_ag_valid && rp_any && !flush;
  assign ag_v    = (ld_ag_valid || ag_rp) && !flush;
  assign ag_lq   = ld_ag_valid ? ld_ag_pl.lq[LIW-1:0] : rp_idx;
  assign ag_va   = ld_ag_valid ? ld_ag_addr : lq_va_q[rp_idx];
  assign ag_pa   = ag_va[PA_W-1:0];
  assign ag_size = ld_ag_valid ? ld_ag_pl.mem_size : lq_size_q[rp_idx];
  pma_e ag_pma;
  assign ag_pma = pma_of(ag_pa);
  logic ag_mis, ag_acc, ag_mmio, ag_go;
  assign ag_mis  = misal(ag_va[2:0], ag_size);
  assign ag_acc  = ag_va[63:PA_W] != '0 || ag_pma == PMA_NONE;
  assign ag_mmio = ag_pma == PMA_DEVICE || ag_pma == PMA_ROM;
  assign ag_go   = ag_v && !ag_mis && !ag_acc && !ag_mmio;     // continues to M1
  assign dc_rd_en = ag_go;
  assign dc_rd_pa = ag_pa;

  // A store write to the same 16-byte row in the AG cycle: the load read old data
  logic ag_clash;
  assign ag_clash = st_ack && !st_dropped && st_pa[PA_W-1:4] == ag_pa[PA_W-1:4];

  // ================= M1 =================
  logic              m1_v_q, m1_clash_q;
  logic [LIW-1:0]    m1_lq_q;
  logic [PA_W-1:0]   m1_pa_q;
  assign m1_pa = m1_pa_q;
  logic [7:0]        m1_mask;
  assign m1_mask = bmask(m1_pa_q[2:0], lq_size_q[m1_lq_q]);

  // Youngest older store with a byte overlap in the same dword
  logic              f_hit, f_cover, f_data;
  logic [SIW-1:0]    f_idx;
  logic [63:0]       f_dword;
  always_comb begin
    int lim, best;
    lim = sq_cnt(lq_sq_q[m1_lq_q], sq_head_q);      // stores at distance < lim are older
    best = -1;
    f_idx = '0;
    for (int i = 0; i < SQ_ENTRIES; i++) begin
      int a;
      a = sq_cnt(sq_id(i, sq_head_q), sq_head_q);
      if (sq_v_q[i] && sq_av_q[i] && !sq_mmio_q[i] && !sq_amo_q[i] && a < lim && a > best &&
          sq_va_q[i][PA_W-1:3] == m1_pa_q[PA_W-1:3] && |(sq_mask_q[i] & m1_mask)) begin
        best = a;
        f_idx = SIW'(i);
      end
    end
    f_hit   = best >= 0;
    f_cover = (sq_mask_q[f_idx] & m1_mask) == m1_mask;
    f_data  = sq_dv_q[f_idx];
    f_dword = sq_data_q[f_idx] << {sq_va_q[f_idx][2:0], 3'b000};
  end

  // ================= M2 =================
  logic              m2_v_q, m2_clash_q, m2_hit_q, m2_fhit_q, m2_fcov_q, m2_fdat_q;
  logic [LIW-1:0]    m2_lq_q;
  logic [PA_W-1:0]   m2_pa_q;
  logic [63:0]       m2_dword_q, m2_fdword_q;
  logic [SIW-1:0]    m2_fidx_q;
  sqid_t             m2_fid;
  assign m2_fid = sq_id(int'(m2_fidx_q), sq_head_q);

  typedef enum logic [2:0] { O_OK, O_STQ, O_MISS, O_RETRY, O_FAULT } m2_out_e;
  m2_out_e   m2_out;
  logic [63:0] m2_val;
  always_comb begin
    logic [63:0] dw;
    m2_out = O_OK;
    dw = m2_dword_q;
    if (m2_fhit_q) begin
      if (m2_fcov_q && m2_fdat_q) dw = m2_fdword_q;
      else                        m2_out = O_STQ;
    end else if (m2_clash_q) begin
      m2_out = O_RETRY;
    end else if (!m2_hit_q) begin
      m2_out = (deny_v && deny_line == m2_pa_q[PA_W-1:6]) ? O_FAULT : O_MISS;
    end
    m2_val = ext(dw >> {m2_pa_q[2:0], 3'b000}, lq_size_q[m2_lq_q], lq_uns_q[m2_lq_q]);
  end
  logic m2_ok;
  assign m2_ok  = m2_v_q && m2_out == O_OK && !flush;
  assign lm_req = m2_v_q && m2_out == O_MISS && !flush;
  assign lm_pa  = m2_pa_q;
  assign ld_m2_will = m2_ok && lq_dv_q[m2_lq_q];
  assign ld_m2_dst  = lq_dst_q[m2_lq_q];

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

  // MMIO load: the ROB head, no committed store left, port free
  logic [LQ_ENTRIES-1:0] mm_cand;
  for (genvar i = 0; i < LQ_ENTRIES; i++) begin : g_mm
    assign mm_cand[i] = lq_v_q[i] && lq_st_q[i] == L_MMIO && lq_rob_q[i] == rob_head;
  end
  logic            mm_go;
  logic [LIW-1:0]  mm_idx;
  always_comb begin
    mm_idx = '0;
    for (int i = 0; i < LQ_ENTRIES; i++) if (mm_cand[i]) mm_idx = LIW'(i);
  end

  // Drain: the SQ head once committed
  logic [SIW-1:0] dh;
  assign dh = sq_head_q[SIW-1:0];
  logic dr_v, dr_amo;
  assign dr_v   = sq_v_q[dh] && sq_head_q != sq_cmt_q;
  assign dr_amo = dr_v && sq_amo_q[dh];      // performed before commit: leaves without a write
  logic dr_mmio_go;
  assign dr_mmio_go = dr_v && sq_mmio_q[dh] && xs_q == X_IDLE && !xr_v_q;
  assign mm_go = |mm_cand && !dr_v && xs_q == X_IDLE && !xr_v_q && !flush;
  assign st_req   = dr_v && !sq_mmio_q[dh] && !sq_amo_q[dh];
  assign st_pa    = sq_va_q[dh][PA_W-1:0];
  assign st_mask  = {8'b0, sq_mask_q[dh]} << {sq_va_q[dh][3], 3'b000};
  assign st_wdata = {64'b0, sq_data_q[dh] << {sq_va_q[dh][2:0], 3'b000}} << {sq_va_q[dh][3], 6'b000000};
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
  logic            r_v_q, r_dv_q, r_mmio_q;
  logic [PIDX_W-1:0] r_dst_q;
  logic [63:0]     r_data_q;
  robid_t          r_rob_q;
  llt_t            r_llt_q;
  assign ld_res_valid = r_v_q && r_dv_q;
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
  // the line in T and reads and writes it in two cycles (am_ack) -> AM_RES: rd through the
  // result register -> AM_DONE until the flush that follows its commit. An SC without a
  // reservation for its line fails without touching memory.
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
  logic [SIW-1:0]    am_i;
  logic [1:0]        am_size;
  logic              am_lr, am_sc, am_go, am_take, rsv_ok, am_wr;
  logic [63:0]       am_old, am_new;
  assign am_i     = am_sq_q[SIW-1:0];
  assign am_size  = sq_size_q[am_i];
  assign am_pa    = sq_va_q[am_i][PA_W-1:0];
  assign am_lr    = am_op_q == AMO_LR;
  assign am_sc    = am_op_q == AMO_SC;
  assign am_go    = am_v_q && am_st_q == AM_IDLE && sq_v_q[am_i] && sq_av_q[am_i] && sq_dv_q[am_i] &&
                    sq_head_q == am_sq_q && rob_head == am_rob_q && !flush;
  // The reservation covers the SC's line and has not just been lost (probe, eviction)
  assign rsv_ok   = rsv_v_q && rsv_line_q == am_pa[PA_W-1:6] && !(lose_v && lose_line == rsv_line_q);
  assign am_req   = am_st_q == AM_REQ && !flush;
  assign am_old   = ext(am_rdata >> {am_pa[2:0], 3'b000}, am_size, 1'b0);
  assign am_new   = amo_alu(am_op_q, am_size == 2'd2, am_old, sq_data_q[am_i]);
  assign am_wr    = !am_lr && (!am_sc || rsv_ok);
  assign am_wmask = (am_req && am_ack && am_wr) ? {8'b0, bmask(am_pa[2:0], am_size)} << {am_pa[3], 3'b000}
                                                 : 16'h0;
  assign am_wdata = {64'b0, am_new << {am_pa[2:0], 3'b000}} << {am_pa[3], 6'b000000};
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
    if ((am_go && am_sc && !rsv_ok) || (am_req && (am_ack || am_den) && am_sc)) rsv_v_d = 1'b0;
    if (lose_v && lose_line == rsv_line_d) rsv_v_d = 1'b0;
    if (rsv_clr) rsv_v_d = 1'b0;
  end
  // Loads wake their LLT the cycle before the register file is written
  always_comb begin
    wake_ld = '0;
    if (m2_ok && lq_dv_q[m2_lq_q]) wake_ld[ROB_ENTRIES + int'(lq_llt_q[m2_lq_q])] = 1'b1;
    if (xr_take && lq_dv_q[x_lq_q]) wake_ld[ROB_ENTRIES + int'(lq_llt_q[x_lq_q])] = 1'b1;
    if (am_take && am_dv_q) wake_ld[ROB_ENTRIES + int'(am_llt_q)] = 1'b1;
  end

  // ================= Store data capture =================
  logic           cap_v;
  logic [SIW-1:0] cap_idx;
  always_comb begin
    int best;
    best = SQ_ENTRIES;
    cap_idx = '0;
    for (int i = 0; i < SQ_ENTRIES; i++) begin
      int a;
      a = sq_cnt(sq_id(i, sq_head_q), sq_head_q);
      if (sq_v_q[i] && !sq_dv_q[i] && ready_vec[sq_tag_q[i]] && a < best) begin
        best = a;
        cap_idx = SIW'(i);
      end
    end
    cap_v = best != SQ_ENTRIES && !flush;
  end
  assign sd_tag = sq_tag_q[cap_idx];

  // ================= STA =================
  logic [SIW-1:0] sa_idx;
  logic [7:0]     sa_mask;
  pma_e           sa_pma;
  logic           sa_mis, sa_acc, sa_mmio, sa_ok, sa_amo, sa_lr;
  assign sa_idx  = sta_ag_pl.sq[SIW-1:0];
  assign sa_amo  = sq_amo_q[sa_idx];
  assign sa_lr   = sa_amo && am_op_q == AMO_LR;    // LR faults as a load
  assign sa_mask = bmask(sta_ag_addr[2:0], sta_ag_pl.mem_size);
  assign sa_pma  = pma_of(sta_ag_addr[PA_W-1:0]);
  assign sa_mis  = misal(sta_ag_addr[2:0], sta_ag_pl.mem_size);
  // atomics only in main memory (interfaces.md §2.4)
  assign sa_acc  = sta_ag_addr[63:PA_W] != '0 || sa_pma == PMA_NONE || sa_pma == PMA_ROM ||
                   (sa_amo && sa_pma != PMA_MEM);
  assign sa_mmio = sa_pma == PMA_DEVICE && !sa_amo;
  assign sa_ok   = sta_ag_valid && !sa_mis && !sa_acc && !flush;

  // Ordering check: the oldest younger load that has its value (or is in M1/M2) and overlaps
  always_comb begin
    int sdist, best;
    sdist = sq_cnt(sta_ag_pl.sq, sq_head_q);
    best = LQ_ENTRIES;
    replay_rob = '0;
    for (int i = 0; i < LQ_ENTRIES; i++) begin
      int a;
      a = lq_cnt(lq_id(i, lq_head_q), lq_head_q);
      if (lq_v_q[i] && lq_pav_q[i] && (lq_st_q[i] == L_DONE || lq_st_q[i] == L_PIPE) &&
          sq_cnt(lq_sq_q[i], sq_head_q) > sdist &&
          lq_va_q[i][PA_W-1:3] == sta_ag_addr[PA_W-1:3] &&
          |(bmask(lq_va_q[i][2:0], lq_size_q[i]) & sa_mask) && a < best) begin
        best = a;
        replay_rob = lq_rob_q[i];
      end
    end
    replay_valid = sa_ok && best != LQ_ENTRIES;
  end

  // ================= ROB reports =================
  always_comb begin
    exc_valid = '0; exc_rob = '0; exc_cause = '0; exc_tval = '0;
    // loads: AG checks of a new load, or a denied line at M2
    if (ld_ag_valid && !flush && (ag_mis || ag_acc)) begin
      exc_valid[0] = 1'b1;
      exc_rob[0]   = ld_ag_pl.rob;
      exc_cause[0] = ag_mis ? EXC_LMISALIGN : EXC_LACCESS;
      exc_tval[0]  = ag_va;
    end
    if (m2_v_q && m2_out == O_FAULT && !flush) begin
      exc_valid[1] = 1'b1;
      exc_rob[1]   = lq_rob_q[m2_lq_q];
      exc_cause[1] = EXC_LACCESS;
      exc_tval[1]  = lq_va_q[m2_lq_q];
    end
    if (xs_q == X_WAIT && !x_st_q && !x_kill_q && mmio_d_valid_i && (mmio_d_i.denied || mmio_d_i.corrupt)
        && !flush) begin
      exc_valid[2] = 1'b1;
      exc_rob[2]   = lq_rob_q[x_lq_q];
      exc_cause[2] = EXC_LACCESS;
      exc_tval[2]  = lq_va_q[x_lq_q];
    end else if (am_req && am_den) begin               // an atomic's line was denied
      exc_valid[2] = 1'b1;
      exc_rob[2]   = am_rob_q;
      exc_cause[2] = am_lr ? EXC_LACCESS : EXC_SACCESS;
      exc_tval[2]  = sq_va_q[am_i];
    end
    if (sta_ag_valid && !flush && (sa_mis || sa_acc)) begin
      exc_valid[3] = 1'b1;
      exc_rob[3]   = sta_ag_pl.rob;
      exc_cause[3] = sa_mis ? (sa_lr ? EXC_LMISALIGN : EXC_SMISALIGN) : (sa_lr ? EXC_LACCESS : EXC_SACCESS);
      exc_tval[3]  = sta_ag_addr;
    end
    // store completion: address arrives with the data present, or data arrives after the address
    st_cmp_valid = '0;
    st_cmp_rob   = '0;
    if (sa_ok && !sa_amo && (sq_dv_q[sa_idx] || (cap_v && cap_idx == sa_idx))) begin
      st_cmp_valid[0] = 1'b1;
      st_cmp_rob[0]   = sta_ag_pl.rob;
    end
    if (cap_v && sq_av_q[cap_idx] && !sq_exc_q[cap_idx] && !sq_amo_q[cap_idx]) begin
      st_cmp_valid[1] = 1'b1;
      st_cmp_rob[1]   = sq_rob_q[cap_idx];
    end
  end

  // Replay pending: block IQ-LD's select so the AG slot frees
  always_ff @(posedge clk) begin
    if (rst || flush) ld_block <= 1'b0;
    else              ld_block <= |rp_ready;
  end

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
            x_pa_q    <= sq_va_q[dh][PA_W-1:0];
            x_size_q  <= sq_size_q[dh];
            x_wdata_q <= sq_data_q[dh];
          end else if (mm_go) begin
            xs_q      <= X_REQ;
            x_st_q    <= 1'b0;
            x_kill_q  <= 1'b0;
            x_lq_q    <= mm_idx;
            x_pa_q    <= lq_va_q[mm_idx][PA_W-1:0];
            x_size_q  <= lq_size_q[mm_idx];
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
              xr_data_q <= ext(64'(mmio_d_i.data >> {x_pa_q[3:0], 3'b000}), x_size_q, lq_uns_q[x_lq_q]);
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
          if (am_sc && !rsv_ok) begin
            am_res_q <= 64'd1;                    // SC without a reservation: fails, no access
            am_st_q  <= AM_RES;
          end else begin
            am_st_q  <= AM_REQ;
          end
        end
        AM_REQ: if (am_ack) begin
          am_res_q        <= am_sc ? {63'b0, !am_wr} : am_old;
          sq_amw_q[am_i]  <= am_wr;
          sq_data_q[am_i] <= am_new;              // the value written (trace)
          am_st_q         <= AM_RES;
        end else if (am_den) begin
          am_st_q <= AM_DONE;                     // access fault
        end
        AM_RES: if (am_take) am_st_q <= AM_DONE;
        default: ;
      endcase

      // ---- Result register ----
      r_v_q <= 1'b0;
      if (m2_ok) begin
        r_v_q    <= 1'b1;
        r_dv_q   <= lq_dv_q[m2_lq_q];
        r_dst_q  <= lq_dst_q[m2_lq_q];
        r_data_q <= m2_val;
        r_rob_q  <= lq_rob_q[m2_lq_q];
        r_llt_q  <= lq_llt_q[m2_lq_q];
        r_mmio_q <= 1'b0;
      end else if (xr_take) begin
        r_v_q    <= 1'b1;
        r_dv_q   <= lq_dv_q[x_lq_q];
        r_dst_q  <= lq_dst_q[x_lq_q];
        r_data_q <= xr_data_q;
        r_rob_q  <= lq_rob_q[x_lq_q];
        r_llt_q  <= lq_llt_q[x_lq_q];
        r_mmio_q <= 1'b1;
        lq_st_q[x_lq_q] <= L_DONE;
      end else if (am_take) begin
        r_v_q    <= 1'b1;
        r_dv_q   <= am_dv_q;
        r_dst_q  <= am_dst_q;
        r_data_q <= am_res_q;
        r_rob_q  <= am_rob_q;
        r_llt_q  <= am_llt_q;
        r_mmio_q <= 1'b0;
      end

      // ---- M2 outcome ----
      if (m2_v_q && !flush) begin
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

      // ---- M1 -> M2 ----
      m2_v_q      <= m1_v_q && !flush;
      m2_lq_q     <= m1_lq_q;
      m2_pa_q     <= m1_pa_q;
      m2_clash_q  <= m1_clash_q;
      m2_hit_q    <= dc_hit;
      m2_dword_q  <= dc_dword;
      m2_fhit_q   <= f_hit;
      m2_fcov_q   <= f_cover;
      m2_fdat_q   <= f_data;
      m2_fdword_q <= f_dword;
      m2_fidx_q   <= f_idx;

      // ---- AG -> M1 ----
      m1_v_q     <= ag_go;
      m1_lq_q    <= ag_lq;
      m1_pa_q    <= ag_pa;
      m1_clash_q <= ag_clash;
      if (ag_v) begin
        lq_va_q[ag_lq]  <= ag_va;
        lq_pav_q[ag_lq] <= 1'b1;
        lq_st_q[ag_lq]  <= ag_mis || ag_acc ? L_EXC : ag_mmio ? L_MMIO : L_PIPE;
      end

      // ---- Waiting loads re-check their condition ----
      for (int i = 0; i < LQ_ENTRIES; i++) begin
        if (lq_v_q[i] && !(ag_v && ag_lq == LIW'(i)) && !(m2_v_q && m2_lq_q == LIW'(i))) begin
          if (lq_st_q[i] == L_MISS && mshr_idle) lq_st_q[i] <= L_READY;
          if (lq_st_q[i] == L_STQ) begin
            int d, n;
            logic gone;
            d = sq_cnt(lq_blk_q[i], sq_head_q);
            n = sq_cnt(sq_tail_q, sq_head_q);
            gone = d < 0 || d >= n;
            if (gone || (!lq_part_q[i] && sq_dv_q[lq_blk_q[i][SIW-1:0]])) lq_st_q[i] <= L_READY;
          end
        end
      end
      if (mm_go) lq_st_q[mm_idx] <= L_PIPE;   // MMIO request out (not L_MMIO any more)

      // ---- Store data capture ----
      if (cap_v) begin
        sq_dv_q[cap_idx]   <= 1'b1;
        sq_data_q[cap_idx] <= sd_data;
      end

      // ---- STA ----
      if (sta_ag_valid && !flush) begin
        sq_av_q[sa_idx]   <= !(sa_mis || sa_acc);
        sq_exc_q[sa_idx]  <= sa_mis || sa_acc;
        sq_va_q[sa_idx]   <= sta_ag_addr;
        sq_mask_q[sa_idx] <= sa_mask;
        sq_mmio_q[sa_idx] <= sa_mmio;
      end

      // ---- Dispatch: new LQ / SQ entries ----
      if (ds_fire) begin
        for (int k = 0; k < DISPATCH_WIDTH; k++) begin
          if (ds_valid[k] && ds_uop[k].d.cls == C_LD) begin
            logic [LIW-1:0] i;
            i = ds_ren[k].lq[LIW-1:0];
            lq_v_q[i]    <= 1'b1;
            lq_st_q[i]   <= L_WAIT;
            lq_rob_q[i]  <= ds_ren[k].rob;
            lq_sq_q[i]   <= ds_ren[k].sq;
            lq_dv_q[i]   <= ds_uop[k].d.rd_en;
            lq_dst_q[i]  <= preg_idx(ds_ren[k].dst);
            lq_llt_q[i]  <= ds_ren[k].llt;
            lq_size_q[i] <= ds_uop[k].d.mem_size;
            lq_uns_q[i]  <= ds_uop[k].d.mem_uns;
            lq_pav_q[i]  <= 1'b0;
          end
          if (ds_valid[k] && ds_uop[k].d.cls == C_ST) begin
            logic [SIW-1:0] i;
            i = ds_ren[k].sq[SIW-1:0];
            sq_v_q[i]    <= 1'b1;
            sq_rob_q[i]  <= ds_ren[k].rob;
            sq_av_q[i]   <= 1'b0;
            sq_dv_q[i]   <= 1'b0;
            sq_exc_q[i]  <= 1'b0;
            sq_mmio_q[i] <= 1'b0;
            sq_size_q[i] <= ds_uop[k].d.mem_size;
            sq_tag_q[i]  <= ds_ren[k].src2;
            sq_amo_q[i]  <= ds_uop[k].d.amo;
            sq_amw_q[i]  <= 1'b0;
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
          if (sq_cnt(sq_id(i, sq_head_q), sq_head_q) >= sq_cnt(sq_cmt_q, sq_head_q)) sq_v_q[i] <= 1'b0;
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

  logic unused;
  assign unused = ^{ld_ag_pl, sta_ag_pl, m2_fidx_q, mmio_d_i.opcode, mmio_d_i.param, mmio_d_i.size,
                    mmio_d_i.source, mmio_d_i.sink, lq_tail_q, sq_rob_q, x_lq_q};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && !flush) begin
      if (ld_ag_valid) assert (lq_v_q[ld_ag_pl.lq[LIW-1:0]]) else $error("tg_lsu: AG for a free LQ entry");
      if (sta_ag_valid) assert (sq_v_q[sa_idx]) else $error("tg_lsu: STA for a free SQ entry");
    end
  end
`endif
endmodule
