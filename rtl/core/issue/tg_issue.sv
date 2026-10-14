// Issue stage (docs/spec/core-pipeline.md §6): one tg_iq per port (ALU queues, LD, STA) sharing
// the woken vector W (tg_wake) over the wakeup columns: IQ_TAGS wakeup tags, then the LLTs
// (plan §4.6, AR-1). Spike S2 structures, predecoded wakeup IDs: LLT columns keep the guard
// for stale dependencies (STALE = 0, spikes.md §4.1: `busy` names the LLTs some row still
// depends on, and rename does not reallocate them); a tag column is cleared in every row when
// the tag returns (col_clr). Every wakeup arrives on wake_reg (MUL delay line, load and divide
// completions); 1-cycle producers wake their dependants through MX alone.
// The payload leaves in the RF stage. DUP_SEL, EARLY_W and MX are the S2 timing levers.
// Each queue stores its own payload format: only the iq_pl_t bits its port reads (the other
// fields leave as '0), so synthesis has no LUTRAM bit to trim.
// IQ-FP (EXT_FD) issues to P4 (tg_fp_exec). Its rows wait on 1-cycle integer producers until
// their rows are freed (no mx_issued), so an FP op's integer source is in the register file by
// P4's RF stage; FMISC ops with an FP destination are not selected while fp_misc_block is high
// (the F0 slot three cycles after an FMA).
module tg_issue
  import tg_pkg::*, tg_alu_pkg::*, tg_fpu_pkg::*, tg_core_pkg::*;
#(
  parameter bit DUP_SEL = IQ_DUP_SEL,    // S2 lever: separate select copy for the wakeup
  parameter int EARLY_W = IQ_EARLY_W,    // S2 lever: the source tags in flip-flops (IQ_PL_W: all)
  parameter bit MX      = IQ_MX,         // S2 lever: matrix wakeup (dispatch names rows)
  parameter int STALE   = 0,             // 0 guard (spikes.md recommendation), 2 column clear
  localparam int DW     = DISPATCH_WIDTH
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         flush,
  input  tid_t                         flush_tid,
  // Dispatch (DS)
  input  logic [N_IQ-1:0][DW-1:0]      disp_we,
  input  logic [DW-1:0][NCOL-1:0]      disp_dep,
  input  iq_pl_t [DW-1:0]              disp_pl,
  input  logic [DW-1:0][RA-1:0]        disp_mdep,   // MX: sources named by ALU-queue row
  output logic [N_IQ-1:0][DW-1:0]      bank_free,
  // MX naming state: ALU-queue rows holding an op (and not freed this cycle), and the row each
  // dispatch port writes next in each ALU queue (global row numbers)
  output logic [RA-1:0]                mx_hold,
  output robid_t [RA-1:0]              mx_rob,      // the ROB ID each ALU-queue row holds
  output logic [N_ALU-1:0][DW-1:0][RA-1:0] mx_alloc,
  // Wakeup
  input  logic [NCOL-1:0]              alloc,       // IDs given out at RN: W cleared
  input  logic [NCOL-1:0]              wake_reg,    // W set at the end of this cycle
  input  logic [NCOL-1:0]              col_clr,     // returned tags (registered)
  output logic [NCOL-1:0]              w,
  output logic [NCOL-1:0]              busy,        // columns a waiting row depends on
  // Select blocks (registered by their sources)
  input  logic                         a1_block,
  input  logic                         ld_block,
  input  logic                         fp_misc_block,   // EXT_FD: P4's F0 slot is taken
  // RF stage
  output logic [N_IQ-1:0]              iss_valid,
  output iq_pl_t [N_IQ-1:0]            iss_pl
);
  function automatic int rows_of(input int q);
    if (q == 0) return IQ_A0;
    if (q == 1) return IQ_A1;
    if (q < N_ALU) return IQ_A2;
    if (q == Q_LD) return IQ_LD;
    if (q == Q_STA) return IQ_STA;
    return IQ_FP;
  endfunction

  logic [N_IQ-1:0][NCOL-1:0]  qbusy;
  logic [RA-1:0]              mx_issued, mx_free, mx_valid;
  logic [DW-1:0][NCOL-1:0]    no_ph;
  assign no_ph = '0;
  tid_t [DW-1:0]              dtid;
  robid_t [DW-1:0]            drob;
  for (genvar k = 0; k < DW; k++) begin : g_d
    assign dtid[k] = disp_pl[k].tid;
    assign drob[k] = disp_pl[k].rob;
  end

  // ---- Payload formats ----
  // ALU ports: the ALU control word without min/max (tg_alu MINMAX = 0: they ride P1's MUL slot,
  // which reads cmp_max), the destination's index (its bank is the port's). P0 adds the branch
  // fields, P1 the MUL/DIV/CSR fields; both keep the ROB wrap bit (exception and misprediction
  // age), the other ALU ports only the index (completion). LD: the LQ index, and the fields the
  // LQ entry takes at AG (the LSU writes them there, not at dispatch); STA: the SQ ID; both keep
  // the 12-bit offset (sign-extended at issue). The source tags are the low bits (EARLY_W).
  typedef struct packed {
    logic [NGRP-2:0] grp;          // every group but G_MINMX
    logic            word, sub;
    logic [1:0]      zba_sh;
    logic            uw, sh_left, sh_arith, sh_rot, cmp_unsigned;
    alu_lg_e         lg_fn;
    logic            lg_invb;
    alu_bit_e        bit_fn;
    alu_un_e         un_fn;
  } f_ctl_t;
  typedef struct packed {
    uclass_e           cls;
    f_ctl_t            alu;
    logic              b_imm;
    logic [63:0]       imm;
    logic              dst_en;
    logic [PIDX_W-1:0] dst;
    preg_t             src1, src2;
  } f_alu_t;
  typedef struct packed {
    robid_t      rob;
    logic [63:0] pc;
    br_kind_e    br_kind;
    logic [2:0]  br_f3;
    logic [63:0] br_target;
    logic [11:0] jalr_off;
    logic [63:0] pred_npc;
    logic        ubtb_hit, ubtb_way, dfix, rvc;
  } f_br_t;
  typedef struct packed {
    robid_t      rob;
    logic        cmp_max;
    mul_op_e     mul_op;
    div_op_e     div_op;
    logic        word, bcnt;
    wid_t        wid;                 // MUL: its tag; DIV: its LLT's column
    csr_op_e     csr_op;
    logic        csr_imm, csr_wr;
    logic [11:0] csr_addr;
    logic [4:0]  csr_zimm;
    logic [31:0] insn;
  } f_p1_t;
  typedef struct packed {
    logic [ROB_IDX_W-1:0] rob;
  } f_an_t;
  typedef struct packed {
    robid_t              rob;
    logic [11:0]         imm;
    logic [LQ_IDX_W-1:0] lq;
    logic [1:0]          mem_size;
    logic                mem_uns;       // zero-extend (an FP load: raw bits)
    sqid_t               sq;            // the stores before this SQ ID are older
    logic                dst_en, dst_fp;
    logic [PIDX_W-1:0]   dst;           // the destination's index (an FP load: F1's)
    llt_t                llt;
    preg_t               src1;
  } f_ld_t;
  typedef struct packed {
    robid_t      rob;
    logic [11:0] imm;
    sqid_t       sq;
    logic [1:0]  mem_size;
    preg_t       src1;
  } f_sta_t;

  /* verilator lint_off UNUSEDSIGNAL */      // the fields of the other formats
  function automatic f_alu_t pk_alu(input iq_pl_t p);
    f_ctl_t c;
    c = '{grp: {p.alu.grp[NGRP-1:G_MINMX+1], p.alu.grp[G_MINMX-1:0]}, word: p.alu.word,
          sub: p.alu.sub, zba_sh: p.alu.zba_sh, uw: p.alu.uw, sh_left: p.alu.sh_left,
          sh_arith: p.alu.sh_arith, sh_rot: p.alu.sh_rot, cmp_unsigned: p.alu.cmp_unsigned,
          lg_fn: p.alu.lg_fn, lg_invb: p.alu.lg_invb, bit_fn: p.alu.bit_fn, un_fn: p.alu.un_fn};
    return '{cls: p.cls, alu: c, b_imm: p.b_imm, imm: p.imm, dst_en: p.dst_en,
             dst: preg_idx(p.dst), src1: p.src1, src2: p.src2};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  function automatic iq_pl_t up_alu(input f_alu_t f, input int q);
    iq_pl_t p;
    p = '0;
    p.cls              = f.cls;
    p.alu.grp          = {f.alu.grp[NGRP-2:G_MINMX], 1'b0, f.alu.grp[G_MINMX-1:0]};
    p.alu.word         = f.alu.word;
    p.alu.sub          = f.alu.sub;
    p.alu.zba_sh       = f.alu.zba_sh;
    p.alu.uw           = f.alu.uw;
    p.alu.sh_left      = f.alu.sh_left;
    p.alu.sh_arith     = f.alu.sh_arith;
    p.alu.sh_rot       = f.alu.sh_rot;
    p.alu.cmp_unsigned = f.alu.cmp_unsigned;
    p.alu.lg_fn        = f.alu.lg_fn;
    p.alu.lg_invb      = f.alu.lg_invb;
    p.alu.bit_fn       = f.alu.bit_fn;
    p.alu.un_fn        = f.alu.un_fn;
    p.b_imm            = f.b_imm;
    p.imm              = f.imm;
    p.dst_en           = f.dst_en;
    p.dst              = mk_preg(q, f.dst);
    p.src1             = f.src1;
    p.src2             = f.src2;
    return p;
  endfunction
  // IQ-FP: what P4 reads (docs/spec/fpu.md, the P4 payload)
  typedef struct packed {
    tid_t        tid;
    robid_t      rob;
    wid_t        wid;
    llt_t        llt;
    logic        dst_en;
    preg_t       dst;
    logic        src1_fp;
    fop_e        fop;
    ffmt_e       fmt, src_fmt;
    ifmt_e       ifmt;
    rm_e         rm;
    logic        fp_int, fp_div;
    preg_t       src1, src2, src3;
  } f_fp_t;
  function automatic int fmt_w(input int q);
    if (q == 0)     return $bits(f_br_t) + $bits(f_alu_t);
    if (q == 1)     return $bits(f_p1_t) + $bits(f_alu_t);
    if (q < N_ALU)  return $bits(f_an_t) + $bits(f_alu_t);
    if (q == Q_LD)  return $bits(f_ld_t);
    if (q == Q_STA) return $bits(f_sta_t);
    return $bits(f_fp_t);
  endfunction

  for (genvar q = 0; q < N_IQ; q++) begin : g_q
    localparam int ROWS = rows_of(q);
    localparam int CAP  = (ROWS * IQ_CAP_PCT) / 100;
    logic [NCOL-1:0] wn;                // (no queue wakes at select)
    logic [ROWS-1:0] iss_o, free_o, val_o;
    logic [ROWS-1:0][ROBW-1:0] rob_o;
    logic [DW-1:0][ROWS-1:0] aoh;
    logic [NUM_THREADS-1:0][idx_w(DW + 1)-1:0] room;
    localparam int PW = fmt_w(q);
    localparam int EW = (EARLY_W < IQ_PL_W) ? ((q < N_ALU) ? 2 : (q == Q_FP) ? 3 : 1) * $bits(preg_t) : PW;
    logic [DW-1:0][PW-1:0] dpl;
    logic [PW-1:0] pl;
    iq_pl_t up;
    if (q == 0) begin : g_f0
      for (genvar k = 0; k < DW; k++) begin : g_k
        iq_pl_t p;
        assign p      = disp_pl[k];
        assign dpl[k] = {f_br_t'{rob: p.rob, pc: p.pc, br_kind: p.br_kind, br_f3: p.br_f3,
                                 br_target: p.br_target, jalr_off: p.jalr_off,
                                 pred_npc: p.pred_npc, ubtb_hit: p.ubtb_hit,
                                 ubtb_way: p.ubtb_way, dfix: p.dfix, rvc: p.rvc}, pk_alu(p)};
      end
      f_br_t b;
      f_alu_t a;
      assign {b, a} = pl;
      always_comb begin
        up           = up_alu(a, q);
        up.rob       = b.rob;
        up.pc        = b.pc;
        up.br_kind   = b.br_kind;
        up.br_f3     = b.br_f3;
        up.br_target = b.br_target;
        up.jalr_off  = b.jalr_off;
        up.pred_npc  = b.pred_npc;
        up.ubtb_hit  = b.ubtb_hit;
        up.ubtb_way  = b.ubtb_way;
        up.dfix      = b.dfix;
        up.rvc       = b.rvc;
      end
    end else if (q == 1) begin : g_f1
      for (genvar k = 0; k < DW; k++) begin : g_k
        iq_pl_t p;
        assign p      = disp_pl[k];
        assign dpl[k] = {f_p1_t'{rob: p.rob, cmp_max: p.alu.cmp_max, mul_op: p.mul_op,
                                 div_op: p.div_op, word: p.word, bcnt: p.bcnt, wid: p.wid, csr_op: p.csr_op, csr_imm: p.csr_imm,
                                 csr_wr: p.csr_wr, csr_addr: p.csr_addr, csr_zimm: p.csr_zimm,
                                 insn: p.insn}, pk_alu(p)};
      end
      f_p1_t b;
      f_alu_t a;
      assign {b, a} = pl;
      always_comb begin
        up             = up_alu(a, q);
        up.rob         = b.rob;
        up.alu.cmp_max = b.cmp_max;
        up.mul_op      = b.mul_op;
        up.div_op      = b.div_op;
        up.word        = b.word;
        up.bcnt        = b.bcnt;
        up.wid         = b.wid;
        up.csr_op      = b.csr_op;
        up.csr_imm     = b.csr_imm;
        up.csr_wr      = b.csr_wr;
        up.csr_addr    = b.csr_addr;
        up.csr_zimm    = b.csr_zimm;
        up.insn        = b.insn;
      end
    end else if (q < N_ALU) begin : g_fa
      for (genvar k = 0; k < DW; k++) begin : g_k
        assign dpl[k] = {f_an_t'{rob: disp_pl[k].rob[ROB_IDX_W-1:0]}, pk_alu(disp_pl[k])};
      end
      f_an_t b;
      f_alu_t a;
      assign {b, a} = pl;
      always_comb begin
        up     = up_alu(a, q);
        up.rob = {1'b0, b.rob};
      end
    end else if (q == Q_LD) begin : g_fl
      for (genvar k = 0; k < DW; k++) begin : g_k
        logic fp;
        assign fp = EXT_FD && disp_pl[k].dst_fp;
        assign dpl[k] = f_ld_t'{rob: disp_pl[k].rob, imm: disp_pl[k].imm[11:0],
                                lq: disp_pl[k].lq[LQ_IDX_W-1:0], mem_size: disp_pl[k].mem_size,
                                mem_uns: disp_pl[k].mem_uns || fp, sq: disp_pl[k].sq,
                                dst_en: disp_pl[k].dst_en, dst_fp: fp,
                                dst: fp ? PIDX_W'(fpreg_idx(disp_pl[k].dst)) : preg_idx(disp_pl[k].dst),
                                llt: disp_pl[k].llt, src1: disp_pl[k].src1};
      end
      f_ld_t b;
      assign b = pl;
      always_comb begin
        up          = '0;
        up.rob      = b.rob;
        up.imm      = {{52{b.imm[11]}}, b.imm};
        up.lq       = {1'b0, b.lq};
        up.mem_size = b.mem_size;
        up.mem_uns  = b.mem_uns;
        up.sq       = b.sq;
        up.dst_en   = b.dst_en;
        up.dst_fp   = b.dst_fp;
        up.dst      = preg_t'(b.dst);            // the index only: the LSU knows the bank
        up.llt      = b.llt;
        up.src1     = b.src1;
      end
    end else if (q == Q_STA) begin : g_fs
      for (genvar k = 0; k < DW; k++) begin : g_k
        assign dpl[k] = f_sta_t'{rob: disp_pl[k].rob, imm: disp_pl[k].imm[11:0], sq: disp_pl[k].sq,
                                 mem_size: disp_pl[k].mem_size, src1: disp_pl[k].src1};
      end
      f_sta_t b;
      assign b = pl;
      always_comb begin
        up          = '0;
        up.rob      = b.rob;
        up.imm      = {{52{b.imm[11]}}, b.imm};
        up.sq       = b.sq;
        up.mem_size = b.mem_size;
        up.src1     = b.src1;
      end
    end else begin : g_ffp
      for (genvar k = 0; k < DW; k++) begin : g_k
        assign dpl[k] = f_fp_t'{tid: disp_pl[k].tid, rob: disp_pl[k].rob, wid: disp_pl[k].wid,
                                llt: disp_pl[k].llt, dst_en: disp_pl[k].dst_en, dst: disp_pl[k].dst,
                                src1_fp: disp_pl[k].src1_fp, fop: disp_pl[k].fop,
                                fmt: disp_pl[k].fmt, src_fmt: disp_pl[k].src_fmt,
                                ifmt: disp_pl[k].ifmt, rm: disp_pl[k].rm, fp_int: disp_pl[k].fp_int,
                                fp_div: disp_pl[k].fp_div, src1: disp_pl[k].src1,
                                src2: disp_pl[k].src2, src3: disp_pl[k].src3};
      end
      f_fp_t b;
      assign b = pl;
      always_comb begin
        up         = '0;
        up.tid     = b.tid;
        up.rob     = b.rob;
        up.wid     = b.wid;
        up.llt     = b.llt;
        up.dst_en  = b.dst_en;
        up.dst     = b.dst;
        up.src1_fp = b.src1_fp;
        up.dst_fp  = !b.fp_int;
        up.fop     = b.fop;
        up.fmt     = b.fmt;
        up.src_fmt = b.src_fmt;
        up.ifmt    = b.ifmt;
        up.rm      = b.rm;
        up.fp_int  = b.fp_int;
        up.fp_div  = b.fp_div;
        up.src1    = b.src1;
        up.src2    = b.src2;
        up.src3    = b.src3;
        up.cls     = C_FP;
      end
    end
    logic blk;
    assign blk = (q == 1) ? a1_block : (q == Q_LD) ? ld_block : 1'b0;
    // IQ-FP: FMISC ops with an FP destination yield to fp_misc_block
    logic [DW-1:0] cblk;
    for (genvar k = 0; k < DW; k++) begin : g_cb
      assign cblk[k] = q == Q_FP && fpu_unit_of(disp_pl[k].fop) == FU_MISC && !disp_pl[k].fp_int;
    end
    tg_iq #(
      .ROWS(ROWS), .DW(DW), .NCOL(NCOL), .PAYLOAD_W(PW), .CAP(CAP), .STALE(STALE), .CBLK(q == Q_FP),
      .WAKE_NOW(1'b0), .WAKE_ENC(1), .ROBW(ROBW), .DUP_SEL(DUP_SEL), .EARLY_W(EW),
      .MX(MX), .RA(RA), .PRE_RDY(1'b0)
    ) u_iq (
      .clk, .rst,
      .disp_valid(disp_we[q]), .disp_tid(dtid), .disp_dep(disp_dep), .disp_dep_ph(no_ph),
      .disp_wake_oh('0), .disp_rob(drob), .disp_payload(dpl),
      .bank_free_q(bank_free[q]), .room_q(room),
      .w(w), .w_next('0), .w1('0), .col_clr(col_clr), .cancel(1'b0), .sel_block(blk),
      .disp_cblk(cblk), .cls_block(fp_misc_block),
      .wake_now(wn), .busy(qbusy[q]),
      .disp_mdep(MX ? disp_mdep : '0), .mx_issued(q == Q_FP ? '0 : mx_issued), .mx_free, .issued_o(iss_o), .free_o(free_o),
      .valid_o(val_o), .rob_o(rob_o), .alloc_oh_o(aoh),
      .flush_valid(flush), .flush_tid(flush_tid), .flush_all(1'b1), .flush_rob('0),
      .iss_valid_q(iss_valid[q]), .iss_payload(pl)
    );
    assign iss_pl[q] = up;
    if (q < N_ALU) begin : g_now
      localparam int B = alu_row_base(q);
      assign mx_issued[B +: ROWS] = iss_o;
      assign mx_free[B +: ROWS]   = free_o;
      assign mx_valid[B +: ROWS]  = val_o;
      assign mx_rob[B +: ROWS]    = rob_o;
      for (genvar k = 0; k < DW; k++) begin : g_al
        always_comb begin
          mx_alloc[q][k] = '0;
          mx_alloc[q][k][B +: ROWS] = aoh[k];
        end
      end
    end else begin : g_nonow
      logic unused;
      assign unused = ^{iss_o, free_o, val_o, aoh, rob_o};
    end
    logic unused;
    assign unused = ^{room, wn};
  end
  assign mx_hold = mx_valid & ~mx_free;
  always_comb begin
    busy = '0;
    for (int q = 0; q < N_IQ; q++) busy |= qbusy[q];
  end

  logic [NCOL-1:0] w1_unused, ph_unused, wd_unused;
  tg_wake #(.NCOL(NCOL), .NNOW(1), .STALE(STALE), .HIST(MX ? 1 : 2)) u_wake (
    .clk, .rst, .wake_now('0), .wake_reg, .alloc, .cancel(1'b0), .cancel_ids('0),
    .w_q(w), .w1_q(w1_unused), .phase_q(ph_unused), .w_d(wd_unused));

  logic unused;
  assign unused = ^{w1_unused, ph_unused, wd_unused};

`ifndef SYNTHESIS
  // Loads and stores (and atomics) have 12-bit offsets: the LD and STA formats keep 12 bits
  always_ff @(posedge clk) begin
    for (int k = 0; k < DW; k++) begin
      if (!rst && (disp_we[Q_LD][k] || disp_we[Q_STA][k]))
        assert (disp_pl[k].imm == {{52{disp_pl[k].imm[11]}}, disp_pl[k].imm[11:0]})
          else $error("tg_issue: memory offset wider than 12 bits");
    end
  end
`endif
endmodule
