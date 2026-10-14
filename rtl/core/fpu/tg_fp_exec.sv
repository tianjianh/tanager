// Port P4 from the issue grant onward (docs/spec/fpu.md, "Core integration (P4 back end)"):
// register read and bypass, routing to the FPU's units (tg_fpu_pkg::fpu_unit_of), the F0
// writeback stream, wakeups, completions, the hand-off of integer results to the core's
// bank-1 arbiter, and squashing by thread. Contains tg_fprf and tg_fpu.
//   s     IQ-FP select (the core); fmisc_block masks FMISC rows with an FP destination
//   s+1   RF: tg_fprf read, bypass selects, the integer source through the core's shared port
//   s+2   EX0: operand multiplexers, the request to the FMA or FMISC, or into the FDIV queue
//   s+4   FMISC result: written to F0 at the end of the cycle, or into the B1 queue
//   s+7   FMA result: written to F0 at the end of the cycle
//   c     a divide result claims the free F0 slot c+1 (its wakeup fires); written in c+1
// F0 has one writer, the F0 stream, which is also the bypass source of every F0 result.
// Every operation the core issues goes through its unit; whether it is still live (not
// flushed) travels beside it, so each one also leaves its queue once and returns its credit.
module tg_fp_exec
  import tg_pkg::*, tg_core_pkg::*, tg_fpu_pkg::*, tg_fpu_util_pkg::*, tg_fpcore_pkg::*;
#(
  parameter int FDIV_Q = 4,               // divides between rename and result (core: FDIV_INFLIGHT)
  parameter int FPI_Q  = 4,               // integer results queued for B1 (core: FPI_INFLIGHT)
  parameter int NTR    = COMMIT_WIDTH,    // trace read ports
  parameter bit DIV_RADIX4 = FDIV_RADIX4,
  localparam int DQW   = idx_w(FDIV_Q),
  localparam int NRP   = 4 + NTR          // operands a, b, c; store data; trace
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         flush,
  input  tid_t                         flush_tid,
  // Reset sequence: zero into the initial FP map
  input  logic                         init_we,
  input  logic                         init_bank,
  input  logic [FPIDX_W-1:0]           init_idx,
  // Issue (RF stage) and the select mask for IQ-FP
  input  logic                         iss_valid,
  input  fp_iss_t                      iss_pl,
  output logic                         fmisc_block,
  // Integer source (RF stage): the core's shared integer read port
  output logic                         isrc_valid,
  output preg_t                        isrc_tag,
  input  logic [63:0]                  isrc_data,
  // FP loads: written to F1 at the end of the fld_valid cycle, announced one cycle ahead
  input  logic                         fld_m2_will,
  input  logic [FPIDX_W-1:0]           fld_m2_idx,
  input  logic                         fld_valid,
  input  logic [FPIDX_W-1:0]           fld_idx,
  input  logic                         fld_single,
  input  logic [63:0]                  fld_data,
  // FP store data and trace reads (combinational)
  input  preg_t                        fsd_tag,
  output logic [63:0]                  fsd_data,
  input  preg_t [NTR-1:0]              tr_tag,
  output logic [NTR-1:0][63:0]         tr_data,
  // F0 writes, for the core's FP ready table
  output logic                         f0_we_o,
  output logic [FPIDX_W-1:0]           f0_widx_o,
  // Wakeups: W set at the end of this cycle; divide LLTs written this cycle
  output logic [NCOL-1:0]              wake_reg,
  output logic [LLT_ENTRIES-1:0]       llt_done,
  // Completion of F0 results (cmp_wid: the op's wakeup column, for the core's tag release)
  output logic                         cmp_valid,
  output tid_t                         cmp_tid,
  output robid_t                       cmp_rob,
  output wid_t                         cmp_wid,
  output logic [4:0]                   cmp_fflags,
  // Integer results for bank B1: the head stays until fpi_ready; fpi_kill marks a flushed head
  // (no write, wakeup or completion; the core still pops it with fpi_ready)
  output logic                         fpi_valid,
  input  logic                         fpi_ready,
  output fpi_t                         fpi_o,
  output logic                         fpi_kill,
  output logic                         fpi_pop,        // one entry left the queue: a credit
  // Divides: credit return, early retirement, early-retired completion
  output logic                         fdiv_done,
  input  logic                         fdiv_ret_valid,
  input  tid_t                         fdiv_ret_tid,
  input  llt_t                         fdiv_ret_llt,
  output logic                         er_valid,
  output tid_t                         er_tid,
  output logic [4:0]                   er_fflags
);
  localparam int ML = FMA_LAT;
  localparam int SL = FMISC_LAT;

  // What travels with an FMA or FMISC operation through the unit (the FPU tag)
  typedef struct packed {
    logic   fp_int;
    logic   dst_en;
    preg_t  dst;
    robid_t rob;
    wid_t   wid;
    llt_t   llt;
    tid_t   tid;
  } xtag_t;
  if ($bits(xtag_t) > FPU_TAG_W) begin : g_bad_tag
    $error("tg_fp_exec: the FPU tag (FPU_TAG_W) is too narrow for the P4 tag");
  end
  if (ML < 3 || SL < 2) begin : g_bad_lat
    $error("tg_fp_exec: the wakeup and slot schedule assumes FMA_LAT >= 3 and FMISC_LAT >= 2");
  end

  function automatic logic tid_hit(input logic f, input tid_t ft, input tid_t t);
    return f && ft == t;
  endfunction

  // ------------------------------------------------------------------------------------------
  // Register file
  // ------------------------------------------------------------------------------------------
  logic                       f0_we;
  logic [FPIDX_W-1:0]         f0_wa;
  logic [63:0]                f0_wd;
  logic [63:0]                fld_box;
  logic [NRP-1:0][FPTAG_W-1:0] rtag;
  logic [NRP-1:0][63:0]        rdata;
  assign fld_box = fp_box_load(fld_data, fld_single);
  tg_fprf #(.NR(NRP)) u_rf (
    .clk, .init_we, .init_bank, .init_idx,
    .f0_we, .f0_waddr(f0_wa), .f0_wdata(f0_wd),
    .f1_we(fld_valid), .f1_waddr(fld_idx), .f1_wdata(fld_box),
    .rtag, .rdata);
  assign rtag[0] = FPTAG_W'(iss_pl.src1);
  assign rtag[1] = FPTAG_W'(iss_pl.src2);
  assign rtag[2] = FPTAG_W'(iss_pl.src3);
  assign rtag[3] = FPTAG_W'(fsd_tag);
  assign fsd_data = rdata[3];
  for (genvar j = 0; j < NTR; j++) begin : g_tr
    assign rtag[4+j]  = FPTAG_W'(tr_tag[j]);
    assign tr_data[j] = rdata[4+j];
  end

  // ------------------------------------------------------------------------------------------
  // Shadow pipelines beside the fixed-latency units: valid, live, thread, F0 index and wakeup ID.
  // Stage k holds the operation that was in EX0 k+1 cycles ago; the unit answers when it
  // reaches stage LAT-1.
  // ------------------------------------------------------------------------------------------
  // Wakeup columns follow the core's layout: NFX columns for the fixed-latency producers (the
  // wakeup tags of AR-1, plan §4.6; ROB indices before it), then one per LLT (column NFX + llt),
  // which divides and integer-result ops use. Each decoder below covers only its own range.
  localparam int NFX = NCOL - LLT_ENTRIES;
  localparam int FXW = idx_w(NFX);
  typedef struct packed {
    logic               v;
    logic               live;
    logic               fpd;         // writes F0
    tid_t               tid;
    logic [FPIDX_W-1:0] idx;
    logic [FXW-1:0]     wid;         // fixed-latency wakeup column (tag)
  } sh_t;
  sh_t [ML-1:0] fsh_q;               // FMA
  sh_t [SL-1:0] msh_q;               // FMISC

  // ------------------------------------------------------------------------------------------
  // Divides: table (one entry per divide between RF and its result) and the queue in front of
  // the unit; the unit's tag is the table index.
  // ------------------------------------------------------------------------------------------
  typedef struct packed {
    logic               v;
    tid_t               tid;
    robid_t             rob;
    llt_t               llt;
    logic [FPIDX_W-1:0] idx;
    logic               retired;      // retired early: survives flushes, flags to tg_fcsr
    logic               squashed;     // flushed before retiring: its result is dropped
  } dte_t;
  dte_t [FDIV_Q-1:0] dt_q;

  // The divide result claimed last cycle, written to F0 this cycle
  logic               dv_q, dv_live_q;
  logic [DQW-1:0]     dv_i_q;
  logic [63:0]        dv_res_q;
  logic [4:0]         dv_fl_q;

  // ------------------------------------------------------------------------------------------
  // The F0 write of the next cycle (for the bypass selects and the divide claim)
  // ------------------------------------------------------------------------------------------
  logic               slot_busy;     // an FMA or FMISC FP result writes F0 next cycle
  logic               nx_we;
  logic [FPIDX_W-1:0] nx_idx;
  logic               fdv_v, fdv_rdy, fdv_claim, fdv_live;
  fpu_resp_t          fdv_resp;
  dte_t               fdv_e;
  assign fdv_e   = dt_q[fdv_resp.tag[DQW-1:0]];
  // A divide that retired early survives flushes. A retirement in this very cycle cannot meet a
  // flush of its thread (the core's contract, asserted below), so the registered bit suffices
  // here and the late fdiv_ret_* inputs stay off this path.
  assign fdv_live = !fdv_e.squashed && (fdv_e.retired || !tid_hit(flush, flush_tid, fdv_e.tid));
  assign slot_busy = fsh_q[ML-2].v || (msh_q[SL-2].v && msh_q[SL-2].fpd);
  // A squashed result is drained at once; a live one needs the free slot.
  assign fdv_rdy   = !fdv_live || !slot_busy;
  assign fdv_claim = fdv_v && fdv_rdy;
  always_comb begin
    nx_we  = 1'b0;
    nx_idx = '0;
    if (fsh_q[ML-2].v && fsh_q[ML-2].live) begin
      nx_we = 1'b1; nx_idx = fsh_q[ML-2].idx;
    end else if (msh_q[SL-2].v && msh_q[SL-2].fpd && msh_q[SL-2].live) begin
      nx_we = 1'b1; nx_idx = msh_q[SL-2].idx;
    end else if (fdv_claim && fdv_live) begin
      nx_we = 1'b1; nx_idx = fdv_e.idx;
    end
  end

  // ------------------------------------------------------------------------------------------
  // RF (s+1)
  // ------------------------------------------------------------------------------------------
  typedef enum logic [2:0] { BP_RF, BP_F0X, BP_F0W, BP_F1X, BP_F1W } bsel_e;
  function automatic bsel_e bsel(input logic [FPTAG_W-1:0] t, input logic nwe,
                                 input logic [FPIDX_W-1:0] nidx, input logic cwe,
                                 input logic [FPIDX_W-1:0] cidx);
    logic [FPIDX_W-1:0] i;
    i = t[FPIDX_W-1:0];
    if (!t[FPIDX_W]) begin
      if (nwe && nidx == i) return BP_F0X;      // F0 written next cycle (EX0's cycle)
      if (cwe && cidx == i) return BP_F0W;      // F0 written this cycle
    end else begin
      if (fld_m2_will && fld_m2_idx == i) return BP_F1X;
      if (fld_valid && fld_idx == i) return BP_F1W;
    end
    return BP_RF;
  endfunction

  logic       rf_live;
  fpu_unit_e  rf_unit;
  assign rf_live    = !tid_hit(flush, flush_tid, iss_pl.tid);
  assign rf_unit    = fpu_unit_of(iss_pl.fop);
  assign isrc_valid = iss_valid && !iss_pl.src1_fp;
  assign isrc_tag   = iss_pl.src1;

  logic             ex_v_q, ex_live_q;
  fp_iss_t          ex_pl_q;
  logic [2:0][63:0] ex_rf_q;
  bsel_e [2:0]      ex_sel_q;
  logic [DQW-1:0]   ex_di_q;          // a divide's table entry
  always_ff @(posedge clk) begin
    ex_pl_q     <= iss_pl;
    ex_rf_q[0]  <= iss_pl.src1_fp ? rdata[0] : isrc_data;
    ex_rf_q[1]  <= rdata[1];
    ex_rf_q[2]  <= rdata[2];
    ex_sel_q[0] <= iss_pl.src1_fp ? bsel(rtag[0], nx_we, nx_idx, f0_we, f0_wa) : BP_RF;
    ex_sel_q[1] <= bsel(rtag[1], nx_we, nx_idx, f0_we, f0_wa);
    ex_sel_q[2] <= bsel(rtag[2], nx_we, nx_idx, f0_we, f0_wa);
  end

  // A divide takes a free table entry in RF, so an early retirement can find it from then on.
  logic [DQW-1:0] dt_free_i;
  logic           dt_free_ok;
  always_comb begin
    dt_free_i  = '0;
    dt_free_ok = 1'b0;
    for (int k = FDIV_Q - 1; k >= 0; k--) begin
      if (!dt_q[k].v) begin dt_free_i = DQW'(k); dt_free_ok = 1'b1; end
    end
  end
  logic rf_div;
  assign rf_div = iss_valid && rf_unit == FU_DIV;

  // ------------------------------------------------------------------------------------------
  // EX0 (s+2)
  // ------------------------------------------------------------------------------------------
  logic        ex_live;
  fpu_unit_e   ex_unit;
  assign ex_live = ex_live_q && !tid_hit(flush, flush_tid, ex_pl_q.tid);
  assign ex_unit = fpu_unit_of(ex_pl_q.fop);

  logic [63:0] f0_wb_q, f1_wb_q;      // the F0 stream and the F1 write of last cycle
  logic [2:0][63:0] opnd;
  for (genvar k = 0; k < 3; k++) begin : g_op
    always_comb begin
      unique case (ex_sel_q[k])
        BP_F0X:  opnd[k] = f0_wd;
        BP_F0W:  opnd[k] = f0_wb_q;
        BP_F1X:  opnd[k] = fld_box;
        BP_F1W:  opnd[k] = f1_wb_q;
        default: opnd[k] = ex_rf_q[k];
      endcase
    end
  end

  xtag_t ex_tag;
  always_comb begin
    ex_tag.fp_int = ex_pl_q.fp_int;
    ex_tag.dst_en = ex_pl_q.dst_en;
    ex_tag.dst    = ex_pl_q.dst;
    ex_tag.rob    = ex_pl_q.rob;
    ex_tag.wid    = ex_pl_q.wid;
    ex_tag.llt    = ex_pl_q.llt;
    ex_tag.tid    = ex_pl_q.tid;
  end
  fpu_req_t ex_req;
  always_comb begin
    ex_req.op      = ex_pl_q.fop;
    ex_req.fmt     = ex_pl_q.fmt;
    ex_req.src_fmt = ex_pl_q.src_fmt;
    ex_req.ifmt    = ex_pl_q.ifmt;
    ex_req.rm      = ex_pl_q.rm;
    ex_req.a       = opnd[0];
    ex_req.b       = opnd[1];
    ex_req.c       = opnd[2];
    ex_req.tag     = FPU_TAG_W'(ex_tag);
  end

  // ---- Divide queue: falls through to the unit when it is empty and the unit is ready ----
  typedef struct packed {
    logic [DQW-1:0] di;
    fop_e           op;
    ffmt_e          fmt;
    rm_e            rm;
    logic [63:0]    a, b;
  } dq_t;
  logic ex_div, dq_in_v, dq_in_rdy, dq_out_v, dq_out_rdy;
  dq_t  dq_in, dq_out;
  logic [DQW:0] dq_cnt;
  logic        fdiv_req_v, fdiv_unit_rdy;
  fpu_req_t    fdiv_req;
  assign ex_div = ex_v_q && ex_unit == FU_DIV;
  always_comb begin
    dq_in.di  = ex_di_q;
    dq_in.op  = ex_pl_q.fop;
    dq_in.fmt = ex_pl_q.fmt;
    dq_in.rm  = ex_pl_q.rm;
    dq_in.a   = opnd[0];
    dq_in.b   = opnd[1];
  end
  logic dq_bypass;
  assign dq_bypass = ex_div && dq_cnt == '0 && fdiv_unit_rdy;
  assign dq_in_v   = ex_div && !dq_bypass;
  tg_fifo #(.T(dq_t), .DEPTH(FDIV_Q)) u_dq (
    .clk, .rst, .in_valid(dq_in_v), .in_ready(dq_in_rdy), .in_data(dq_in),
    .out_valid(dq_out_v), .out_ready(dq_out_rdy), .out_data(dq_out), .count(dq_cnt));
  always_comb begin
    dq_t d;
    d = dq_bypass ? dq_in : dq_out;
    fdiv_req_v       = dq_bypass || dq_out_v;
    fdiv_req         = '0;
    fdiv_req.op      = d.op;
    fdiv_req.fmt     = d.fmt;
    fdiv_req.src_fmt = d.fmt;
    fdiv_req.rm      = d.rm;
    fdiv_req.a       = d.a;
    fdiv_req.b       = d.b;
    fdiv_req.tag     = FPU_TAG_W'(d.di);
  end
  assign dq_out_rdy = fdiv_unit_rdy && !dq_bypass;

  // ------------------------------------------------------------------------------------------
  // The units
  // ------------------------------------------------------------------------------------------
  logic      fma_ov, misc_ov;
  fpu_resp_t fma_resp, misc_resp;
  tg_fpu #(.DIV_RADIX4(DIV_RADIX4), .DIV_TAG_W(DQW)) u_fpu (
    .clk, .rst,
    .fma_valid_i (ex_v_q && ex_unit == FU_FMA), .fma_req_i (ex_req),
    .fma_valid_o (fma_ov), .fma_resp_o (fma_resp),
    .fmisc_valid_i (ex_v_q && ex_unit == FU_MISC), .fmisc_req_i (ex_req),
    .fmisc_valid_o (misc_ov), .fmisc_resp_o (misc_resp),
    .fdiv_valid_i (fdiv_req_v), .fdiv_req_i (fdiv_req), .fdiv_ready_o (fdiv_unit_rdy),
    .fdiv_valid_o (fdv_v), .fdiv_resp_o (fdv_resp), .fdiv_ready_i (fdv_rdy)
  );

  // ------------------------------------------------------------------------------------------
  // The F0 stream
  // ------------------------------------------------------------------------------------------
  xtag_t fma_t, misc_t;
  assign fma_t  = xtag_t'(fma_resp.tag[$bits(xtag_t)-1:0]);
  assign misc_t = xtag_t'(misc_resp.tag[$bits(xtag_t)-1:0]);
  sh_t   fma_s, misc_s;
  assign fma_s  = fsh_q[ML-1];
  assign misc_s = msh_q[SL-1];
  logic fma_w, misc_w, misc_i, div_w, dv_ret;
  dte_t dv_e;
  assign dv_e   = dt_q[dv_i_q];
  // retired early, possibly in this very cycle: survives flushes, flags to tg_fcsr
  assign dv_ret = dv_e.retired || (fdiv_ret_valid && fdiv_ret_tid == dv_e.tid && fdiv_ret_llt == dv_e.llt);
  assign fma_w  = fma_s.v && fma_s.live && !tid_hit(flush, flush_tid, fma_s.tid);
  assign misc_w = misc_s.v && misc_s.fpd && misc_s.live && !tid_hit(flush, flush_tid, misc_s.tid);
  assign misc_i = misc_s.v && !misc_s.fpd;           // into the B1 queue (live or dead)
  assign div_w  = dv_q && dv_live_q && (dv_e.retired || !tid_hit(flush, flush_tid, dv_e.tid));

  // The data and index of the F0 stream are selected by the registered slot owners alone (at
  // most one is valid: the slots are reserved), so the late flush and retirement inputs reach
  // only the write enable, not the bypass path into the units.
  always_comb begin
    if (fma_s.v)                     begin f0_wa = fma_s.idx;  f0_wd = fma_resp.result;  end
    else if (misc_s.v && misc_s.fpd) begin f0_wa = misc_s.idx; f0_wd = misc_resp.result; end
    else                             begin f0_wa = dv_e.idx;   f0_wd = dv_res_q;         end
  end
  always_comb begin
    f0_we = 1'b0;
    cmp_valid = 1'b0; cmp_tid = '0; cmp_rob = '0; cmp_wid = '0; cmp_fflags = '0;
    er_valid = 1'b0; er_tid = '0; er_fflags = '0;
    llt_done = '0;
    if (fma_w) begin
      f0_we = 1'b1;
      cmp_valid = 1'b1; cmp_tid = fma_t.tid; cmp_rob = fma_t.rob; cmp_wid = fma_t.wid;
      cmp_fflags = fma_resp.fflags;
    end else if (misc_w) begin
      f0_we = 1'b1;
      cmp_valid = 1'b1; cmp_tid = misc_t.tid; cmp_rob = misc_t.rob; cmp_wid = misc_t.wid;
      cmp_fflags = misc_resp.fflags;
    end else if (div_w) begin
      f0_we = 1'b1;
      llt_done[dv_e.llt] = 1'b1;
      if (dv_ret) begin
        er_valid = 1'b1; er_tid = dv_e.tid; er_fflags = dv_fl_q;
      end else begin
        cmp_valid = 1'b1; cmp_tid = dv_e.tid; cmp_rob = dv_e.rob; cmp_wid = wid_t'(NFX + int'(dv_e.llt));
        cmp_fflags = dv_fl_q;
      end
    end
  end
  assign f0_we_o   = f0_we;
  assign f0_widx_o = f0_wa;
  assign fdiv_done = dv_q;

  // ------------------------------------------------------------------------------------------
  // Wakeups
  // ------------------------------------------------------------------------------------------
  logic [NFX-1:0]         wk_fx;
  logic [LLT_ENTRIES-1:0] wk_llt;
  always_comb begin
    wk_fx  = '0;
    wk_llt = '0;
    // FMISC with an FP destination: at RF, so dependants reach EX0 with the result
    if (iss_valid && rf_live && rf_unit == FU_MISC && !iss_pl.fp_int)
      wk_fx[iss_pl.wid[FXW-1:0]] = 1'b1;
    // FMA: ML-3 cycles after EX0 (s+4 for ML = 5)
    if (fsh_q[ML-4].v && fsh_q[ML-4].live && !tid_hit(flush, flush_tid, fsh_q[ML-4].tid))
      wk_fx[fsh_q[ML-4].wid] = 1'b1;
    // A divide: when it claims its slot
    if (fdv_claim && fdv_live) wk_llt[fdv_e.llt] = 1'b1;
  end
  assign wake_reg = {wk_llt, wk_fx};

  // ------------------------------------------------------------------------------------------
  // B1 queue: integer results, with a dead mark per entry for flushes. The head leaves only on
  // fpi_ready, so it stays stable between the core's slot claim and its write; a flushed head is
  // presented with fpi_kill and popped by the core without effects.
  // ------------------------------------------------------------------------------------------
  localparam int IQW = idx_w(FPI_Q);
  logic [IQW:0]          iq_wr_q, iq_rd_q;
  logic [FPI_Q-1:0]      iq_dead_q;
  tid_t [FPI_Q-1:0]      iq_tid_q;
  logic                  iq_push, iq_pop, iq_empty, iq_head_dead;
  fpi_t                  iq_in;
  logic [0:0][IQW-1:0]   iq_ra;
  logic [0:0][$bits(fpi_t)-1:0] iq_rd;
  assign iq_push = misc_i;
  always_comb begin
    iq_in.tid    = misc_t.tid;
    iq_in.rob    = misc_t.rob;
    iq_in.wid    = misc_t.wid;
    iq_in.llt    = misc_t.llt;
    iq_in.dst_en = misc_t.dst_en;
    iq_in.dst    = misc_t.dst;
    iq_in.data   = misc_resp.result;
    iq_in.fflags = misc_resp.fflags;
  end
  assign iq_ra[0] = iq_rd_q[IQW-1:0];
  tg_ram_lut #(.DEPTH(FPI_Q), .WIDTH($bits(fpi_t)), .NR(1)) u_iq (
    .clk, .we(iq_push), .waddr(iq_wr_q[IQW-1:0]), .wdata(iq_in), .raddr(iq_ra), .rdata(iq_rd));
  assign iq_empty     = iq_wr_q == iq_rd_q;
  assign iq_head_dead = iq_dead_q[iq_rd_q[IQW-1:0]] ||
                        tid_hit(flush, flush_tid, iq_tid_q[iq_rd_q[IQW-1:0]]);
  assign fpi_o     = fpi_t'(iq_rd[0]);
  assign fpi_valid = !iq_empty;
  assign fpi_kill  = !iq_empty && iq_head_dead;
  assign iq_pop    = !iq_empty && fpi_ready;
  assign fpi_pop   = iq_pop;

  // ------------------------------------------------------------------------------------------
  // Select mask: an FMA in EX0 now was selected two cycles ago; its F0 slot is the one an FMISC
  // selected next cycle would take (s+7 = s'+4 for s' = s+3).
  // ------------------------------------------------------------------------------------------
  logic fmisc_block_q;
  assign fmisc_block = fmisc_block_q;

  // ------------------------------------------------------------------------------------------
  // Sequential
  // ------------------------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    // Bypass copies
    f0_wb_q <= f0_wd;
    f1_wb_q <= fld_box;
    // Claimed divide result
    dv_i_q   <= fdv_resp.tag[DQW-1:0];
    dv_res_q <= fdv_resp.result;
    dv_fl_q  <= fdv_resp.fflags;
    if (rf_div) ex_di_q <= dt_free_i;

    if (rst) begin
      ex_v_q        <= 1'b0;
      ex_live_q     <= 1'b0;
      fsh_q         <= '0;
      msh_q         <= '0;
      dt_q          <= '0;
      dv_q          <= 1'b0;
      dv_live_q     <= 1'b0;
      iq_wr_q       <= '0;
      iq_rd_q       <= '0;
      iq_dead_q     <= '0;
      fmisc_block_q <= 1'b0;
    end else begin
      ex_v_q    <= iss_valid;
      ex_live_q <= iss_valid && rf_live;
      fmisc_block_q <= ex_v_q && ex_unit == FU_FMA;

      // Shadow pipelines: shift, then clear live for the flushed thread
      for (int k = ML - 1; k > 0; k--) fsh_q[k] <= fsh_q[k-1];
      for (int k = SL - 1; k > 0; k--) msh_q[k] <= msh_q[k-1];
      fsh_q[0].v    <= ex_v_q && ex_unit == FU_FMA;
      fsh_q[0].live <= ex_live;
      fsh_q[0].fpd  <= 1'b1;
      fsh_q[0].tid  <= ex_pl_q.tid;
      fsh_q[0].idx  <= fpreg_idx(ex_pl_q.dst);
      fsh_q[0].wid  <= ex_pl_q.wid[FXW-1:0];
      msh_q[0].v    <= ex_v_q && ex_unit == FU_MISC;
      msh_q[0].live <= ex_live;
      msh_q[0].fpd  <= !ex_pl_q.fp_int;
      msh_q[0].tid  <= ex_pl_q.tid;
      msh_q[0].idx  <= fpreg_idx(ex_pl_q.dst);
      msh_q[0].wid  <= ex_pl_q.wid[FXW-1:0];
      if (flush) begin
        for (int k = 0; k < ML - 1; k++) if (fsh_q[k].tid == flush_tid) fsh_q[k+1].live <= 1'b0;
        for (int k = 0; k < SL - 1; k++) if (msh_q[k].tid == flush_tid) msh_q[k+1].live <= 1'b0;
      end

      // Divide table: allocate in RF; retire early; squash on a flush; free when written
      if (rf_div) begin
        dt_q[dt_free_i].v        <= 1'b1;
        dt_q[dt_free_i].tid      <= iss_pl.tid;
        dt_q[dt_free_i].rob      <= iss_pl.rob;
        dt_q[dt_free_i].llt      <= iss_pl.llt;
        dt_q[dt_free_i].idx      <= fpreg_idx(iss_pl.dst);
        dt_q[dt_free_i].retired  <= fdiv_ret_valid && fdiv_ret_tid == iss_pl.tid &&
                                    fdiv_ret_llt == iss_pl.llt;
        dt_q[dt_free_i].squashed <= !rf_live;
      end
      for (int k = 0; k < FDIV_Q; k++) begin
        if (dt_q[k].v && !dt_q[k].squashed && fdiv_ret_valid && dt_q[k].tid == fdiv_ret_tid &&
            dt_q[k].llt == fdiv_ret_llt)
          dt_q[k].retired <= 1'b1;
        if (dt_q[k].v && !dt_q[k].retired && tid_hit(flush, flush_tid, dt_q[k].tid))
          dt_q[k].squashed <= 1'b1;
      end
      // An operation flushed in EX0 has its entry squashed above; one flushed in RF at
      // allocation gets squashed = !rf_live.
      dv_q      <= fdv_claim;
      dv_live_q <= fdv_claim && fdv_live;
      if (dv_q) dt_q[dv_i_q].v <= 1'b0;

      // B1 queue (a push overrides the flush marking of its slot's previous occupant)
      if (flush) begin
        for (int k = 0; k < FPI_Q; k++) if (iq_tid_q[k] == flush_tid) iq_dead_q[k] <= 1'b1;
      end
      if (iq_push) begin
        iq_dead_q[iq_wr_q[IQW-1:0]] <= !misc_s.live || tid_hit(flush, flush_tid, misc_s.tid);
        iq_tid_q[iq_wr_q[IQW-1:0]]  <= misc_s.tid;
        iq_wr_q <= iq_wr_q + 1'b1;
      end
      if (iq_pop) iq_rd_q <= iq_rd_q + 1'b1;
    end
  end

  logic unused;
  assign unused = ^{dq_in_rdy, misc_resp.int_dest, fma_resp.int_dest, fdv_resp.int_dest,
                    fdv_resp.tag[FPU_TAG_W-1:DQW], fma_resp.tag, misc_resp.tag, fma_t.fp_int,
                    fma_t.dst_en, fma_t.dst, fma_t.llt, misc_t.fp_int,
                    ex_pl_q.src1, ex_pl_q.src2, ex_pl_q.src3, ex_pl_q.src1_fp, ex_pl_q.fp_div,
                    iss_pl.fp_div, iss_pl.fp_int, iss_pl.dst_en, iss_pl.src_fmt, iss_pl.ifmt,
                    iss_pl.rm, iss_pl.fmt, ex_live_q, fma_s, misc_s, fdv_e, dv_e, fsd_tag,
                    tr_tag};

`ifndef SYNTHESIS
  logic fmisc_block_d;               // the mask at the select of the operation now in RF
  always_ff @(posedge clk) fmisc_block_d <= rst ? 1'b0 : fmisc_block_q;
  always_ff @(posedge clk) begin
    if (!rst) begin
      assert ($onehot0({fma_s.v && fma_s.live, misc_s.v && misc_s.fpd && misc_s.live, dv_q && dv_live_q}))
        else $error("tg_fp_exec: two F0 writes in one cycle");
      if (iss_valid) begin
        assert (iss_pl.fmt != FMT_H) else $error("tg_fp_exec: FMT_H is not implemented");
        assert (!(fmisc_block_d && rf_unit == FU_MISC && !iss_pl.fp_int))
          else $error("tg_fp_exec: FMISC op with an FP destination selected under fmisc_block");
        assert (!rf_div || dt_free_ok) else $error("tg_fp_exec: more divides than FDIV_Q in flight");
        assert ((rf_unit == FU_DIV || iss_pl.fp_int) ?
                  int'(iss_pl.wid) == NFX + int'(iss_pl.llt) : int'(iss_pl.wid) < NFX)
          else $error("tg_fp_exec: wakeup column outside its range (a tag below NFX, or NFX + llt)");
        assert ((rf_unit == FU_DIV) == iss_pl.fp_div)
          else $error("tg_fp_exec: fp_div disagrees with fpu_unit_of");
        assert (!iss_pl.fp_int || rf_unit == FU_MISC)
          else $error("tg_fp_exec: an integer result from a unit other than FMISC");
      end
      assert (!dq_in_v || dq_in_rdy) else $error("tg_fp_exec: divide queue overflow");
      // A flush is registered from the commit before it, so nothing it kills retires with it
      assert (!(fdiv_ret_valid && flush && fdiv_ret_tid == flush_tid))
        else $error("tg_fp_exec: early retirement in its thread's flush cycle");
      assert (!(iq_push && !iq_empty && iq_wr_q[IQW-1:0] == iq_rd_q[IQW-1:0]))
        else $error("tg_fp_exec: B1 queue overflow");
      assert (fma_ov == fma_s.v) else $error("tg_fp_exec: FMA shadow out of step");
      assert (misc_ov == misc_s.v) else $error("tg_fp_exec: FMISC shadow out of step");
      assert (!fdv_v || dt_q[fdv_resp.tag[DQW-1:0]].v) else $error("tg_fp_exec: divide result without an entry");
    end
  end
`endif
endmodule
