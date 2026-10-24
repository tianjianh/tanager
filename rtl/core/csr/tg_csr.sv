// CSR file, privilege modes, traps and interrupts (docs/spec/core-pipeline.md §9 for M2,
// docs/spec/core-priv.md for M3). Field behaviour follows Spike's WARL rules for the configured
// ISA, so lockstep compares every read:
//   EXT_SU = 0 (M2): machine mode only, RV64IM + Zicsr + Zicntr + Zifencei, 16 PMP entries.
//   EXT_SU = 1 (M3): M, S and U modes, delegation, Sstc, Zihpm, satp (Sv39), envcfg.
// Per hart (M7's step 2, DR-175; docs/spec/threading.md): every hart has its own state (h_q, one
// csr_hart_t a thread), its own cold CSRs and pmpaddr (one more LUTRAM address bit: the tid), its own
// PMP descriptors, interrupt pending bits, timer compare, pending write and counters, and its own
// mhartid (CORE_ID x NUM_THREADS + tid; SOLO_TID's thread is hart 0). Writes go to the committing
// thread's state (cm_tid0: CSR writes, traps, MRET and SRET retire alone in slot 0). With hart 1
// (HART1_ON, step 5c) a CSR instruction reads its own thread's state (ex_pl.tid), interrupts, WFI's
// wake and an xRET's xepc are the commit head's thread's (hd_tid), and the reset sweep covers both
// harts' rows. Without it every read and output is the running thread's (RUN_TID), and the reset
// sweep covers its half of the LUTRAMs only, so the reset takes the cycles it did. The scalar
// outputs (misa, fs, priv, satp, pmp_d) are the running thread's either way; per-hart consumers
// take the _h vectors.
//
// CSR instructions are serialised: execute (P1, EX) reads and checks here combinationally and
// leaves the write pending; commit applies it. Traps, MRET and SRET are applied by commit; the
// flush that follows each of them refetches under the new mode and status.
module tg_csr
  import tg_pkg::*, tg_core_pkg::*;
#(
  parameter int unsigned CORE_ID = 0
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   flush,        // drops the flushed thread's pending write
  input  tid_t                   flush_tid,
  // Execute (P1, EX)
  input  logic                   ex_valid,
  input  iq_pl_t                 ex_pl,
  input  logic [63:0]            ex_src,       // rs1
  output logic [63:0]            ex_rdata,
  output logic                   ex_ill,
  // Commit
  input  tid_t                   cm_tid0,      // the thread of slot 0: a CSR write, trap, MRET or SRET
  input  tid_t                   hd_tid,       // the commit head's thread (the ROB's t_cm, a register): HART1_ON
  input  logic                   cm_csr,       // the CSR instruction retires: apply its write
  input  logic [63:0]            cm_pc,        // ... its PC
  input  logic [idx_w(COMMIT_WIDTH + 1)-1:0] cm_n,   // instructions retiring this cycle (cm_tid0's)
  input  logic                   tr_valid,     // trap entry
  input  logic                   tr_irq,
  input  logic [5:0]             tr_code,      // cause code (interrupt: without bit 63)
  input  logic [63:0]            tr_epc,
  input  logic [63:0]            tr_tval,
  input  logic                   mret,
  input  logic                   sret,
  // Debug mode (DEBUG_ON; core-priv.md "Debug mode"): commit's entry and dret, for slot 0's thread
  input  logic                   dbg_enter,    // entry: dcsr.cause, dcsr.prv and dpc take these; the hart goes to M
  input  logic [2:0]             dbg_cause,    // 1 ebreak, 3 the halt request, 4 a step
  input  logic [63:0]            dbg_epc,      // dpc
  input  logic                   dret,         // dret retires: the mode from dcsr.prv, debug mode ends
  input  logic [NUM_THREADS-1:0] dbg_req,      // each hart's halt request (it wakes a WFI)
  output logic [NUM_THREADS-1:0] dm_h,         // each hart in debug mode
  output logic [NUM_THREADS-1:0] dstep_h,      // each hart's dcsr.step
  output logic [NUM_THREADS-1:0] debk_h,       // each hart's ebreak enters debug mode (dcsr.ebreakm/s/u of its mode)
  // State for commit, decode, fetch and the MMU (the running thread's)
  output logic [63:0]            trap_target,  // an exception's, for tr_code given this cycle
  output logic [63:0]            irq_target,   // the pending interrupt's (irq_code)
  input  logic                   xret_v,       // an MRET or SRET is in flight (registered) ...
  input  logic                   xret_s,       // ... and it is SRET
  input  logic                   xret_d,       // ... it is dret (DEBUG_ON): xepc_o reads dpc
  output logic [63:0]            xepc_o,       // its xepc (mepc or sepc), for its commit
  output logic                   irq_take,     // an enabled interrupt is pending
  output logic [5:0]             irq_code,
  output logic                   wfi_wake,     // mip & mie != 0 (the head thread's)
  output logic [NUM_THREADS-1:0] wfi_wake_h,   // ... each hart's (the ROB's commit turns, with hart 1)
  output logic [NUM_THREADS-1:0] wfi_arm_h,    // each hart has an interrupt locally enabled (mie != 0): a sleeping
                                               // WFI may time out (tg_rob, step 6)
  output logic                   misa_m,
  output logic                   misa_b,       // Zba/Zbb/Zbs enabled (Spike lets software clear B)
  output logic                   misa_c,       // compressed instructions enabled
  output logic                   misa_a,       // atomics enabled
  output logic                   misa_f,       // F and D enabled (EXT_FD)
  output logic                   misa_d,
  output logic [1:0]             fs,           // mstatus.FS
  output priv_e                  priv,         // current mode
  output logic                   tvm,
  output logic                   tw,
  output logic                   tsr,
  output logic                   satp_sv39,
  output logic [15:0]            satp_asid,
  output logic                   satp_wr,      // a satp write that changes it commits: TLB flush
  output pmp_d_t [PMP_ENTRIES-1:0] pmp_d,      // PMP region descriptors (registered)
  output logic                   pmp_wr,       // a PMP CSR write commits: the TLBs flush
  output logic                   pmp_busy,     // descriptors being recomputed: fetch waits (with hart 1: either's)
  output logic                   cold_busy,    // a trap's cold-CSR writes run: with hart 1 the ROB holds commit
  // Per hart, for the LSU and the walker (M7's step 4: an access takes its thread's; the outputs above are the
  // running thread's, for fetch and decode)
  output dec_state_t [NUM_THREADS-1:0]              dst_h,       // each hart's decode state (frm: tg_fcsr's)
  output priv_e  [NUM_THREADS-1:0]                  priv_h,      // current mode
  output priv_e  [NUM_THREADS-1:0]                  priv_d_h,    // mode of data accesses (MPRV)
  output logic   [NUM_THREADS-1:0]                  sum_h,
  output logic   [NUM_THREADS-1:0]                  mxr_h,
  output logic   [NUM_THREADS-1:0]                  sv39_h,
  output logic   [NUM_THREADS-1:0][43:0]            satp_ppn_h,
  output pmp_d_t [NUM_THREADS-1:0][PMP_ENTRIES-1:0] pmp_d_h,     // PMP region descriptors (registered)
  output logic   [NUM_THREADS-1:0][PMP_ENTRIES-1:0][2:0] pmp_pal_h, // each entry's address aligned to a 1G/2M/4K page
  output logic   [NUM_THREADS-1:0] pmp_lk_h,   // DR-183 (PMP_FILL): the hart has an active locked entry (else 0)
  // Interrupt inputs (one per hart of the core, by hart: thread t takes line t ^ SOLO_TID) and time
  input  logic [NUM_THREADS-1:0] irq_mei,
  input  logic [NUM_THREADS-1:0] irq_mti,
  input  logic [NUM_THREADS-1:0] irq_msi,
  input  logic [NUM_THREADS-1:0] irq_sei,
  input  logic [NUM_THREADS-1:0] irq_ssi,
  input  logic [63:0]            mtime,
  // F and D (EXT_FD): fcsr lives in tg_fcsr (per hart); this file decodes fflags/frm/fcsr (illegal
  // while mstatus.FS is Off), hands it the writes at retirement (cm_tid0's), and sets each hart's FS
  // to Dirty on its pulse
  input  logic [4:0]             fc_fflags,
  input  logic [2:0]             fc_frm,
  output logic                   fc_wvalid,
  output logic [1:0]             fc_waddr,     // 1 fflags, 2 frm, 3 fcsr
  output logic [7:0]             fc_wdata,
  input  logic [NUM_THREADS-1:0] fs_dirty,
  // M9's counters (HPM_N > 0, tg_core_pkg): each hart's event pulses, registered in tg_core
  input  logic [NUM_THREADS-1:0][HPM_EV-1:0] hpm_ev,
  output logic                   h1off_o       // with hart 1 (step 6): mtgsmt.HART1_OFF, hart 1 kept asleep (tg_rob)
);
  localparam int NT   = NUM_THREADS;
  localparam int NPMP = PMP_ENTRIES;      // 8 or 16 (DR-167); pmpcfg0 holds entries 0-7, pmpcfg2 8-15
  localparam int PIW  = idx_w(NPMP);
  localparam int CAW  = 4 + TID_W;        // cold CSRs' address: {tid, csr[9], csr[2:0]}
  localparam int PAW  = PIW + TID_W;      // pmpaddr's: {tid, entry}
  if (NPMP != 8 && NPMP != 16) begin : g_bad_pmp
    $error("tg_csr: PMP_ENTRIES is 8 or 16");
  end
  localparam bit SU = EXT_SU;
  localparam bit HPM = HPM_N > 0;                // M9's counters (Sscofpmf), below
  localparam logic [13:0] LCOF = HPM ? 14'h2000 : 14'h0000;   // mip/mie/mideleg's LCOFI bit, when built
  // The committing thread (slot 0's) and the flushed one; without SMT thread 0, a constant whatever the
  // payloads' tid bit holds
  tid_t wt, ft;
  assign wt = (TID_W > 0) ? cm_tid0 : tid_t'(0);
  assign ft = (TID_W > 0) ? flush_tid : tid_t'(0);
  // With hart 1: the executing thread (the CSR instruction in EX) and the commit head's (interrupts, WFI's wake,
  // an xRET's xepc); without it both are the running thread, constants
  localparam bit MT = HART1_ON && NT > 1;
  tid_t et, ht;
  assign et = MT ? ex_pl.tid : RUN_TID;
  assign ht = MT ? hd_tid : RUN_TID;
  // mhartid: SOLO_TID's thread (tid 1) is hart 0, so software sees the core as before
  function automatic logic [63:0] hartid(input tid_t t);
    return 64'(CORE_ID * NT) + 64'(tid_t'(t ^ RUN_TID));
  endfunction
  function automatic logic [CAW-1:0] caddr(input tid_t t, input logic [3:0] lo);
    return CAW'({t, lo});                  // without SMT the tid's bit falls off
  endfunction
  function automatic logic [PAW-1:0] paddr_(input tid_t t, input logic [PIW-1:0] i);
    return PAW'({t, i});
  endfunction

  // ---- State, one per hart ----
  typedef struct packed {
    priv_e       priv;
    logic        mie_bit, mpie, sie_bit, spie, spp, mprv, sum, mxr, tvm, tw, tsr;
    logic [1:0]  mpp, fs;
    logic        misa_m, misa_b, misa_c, misa_a, misa_f, misa_d;
    logic [63:0] stimecmp;
    logic [13:0] mie;                          // bit 13: LCOFIE (HPM)
    logic        ssip, stip_sw, seip_sw;
    logic [19:0] medeleg;                      // bit 19: hardware error (Spike, with Zicntr)
    logic [13:0] mideleg;
    logic [31:0] mcounteren, scounteren, mcountinhibit;
    logic        menv_fiom, menv_stce, senv_fiom;
    logic        satp_mode;
    logic [15:0] satp_asid;
    logic [43:0] satp_ppn;
    logic [NPMP-1:0][7:0] pmpcfg;
  } csr_hart_t;
  function automatic csr_hart_t hart_reset();
    csr_hart_t h;
    h = '0;
    h.priv     = PRIV_M;
    h.mpp      = SU ? 2'd0 : 2'd3;
    h.misa_m   = 1'b1;
    h.misa_b   = EXT_B;
    h.misa_c   = EXT_C;
    h.misa_a   = EXT_A;
    h.misa_f   = EXT_FD;
    h.misa_d   = EXT_FD;
    h.pmpcfg[0] = 8'h1f;                       // Spike's reset: entry 0 allows everything (NAPOT, RWX)
    return h;
  endfunction
  csr_hart_t [NT-1:0] h_q, h_n;
  csr_hart_t          r, re, rh;               // the running thread's (outputs), the executing thread's (reads),
  assign r  = h_q[RUN_TID];                    // the head's (interrupts); commit's are h_q[wt]
  assign re = h_q[et];
  assign rh = h_q[ht];
  // R1: the cycle and instret counters are DSP48E2 pairs (tg_dsp_ctr: count, load from a CSR
  // write, reset), with no fabric register, adder or multiplexer; one pair per hart
  logic [NT-1:0][63:0] mcycle_q, minstret_q;
  logic [7:0][7:0]      pcfg_hi;       // the reading thread's pmpcfg2 entries, 8-15: zero with 8 entries
  if (NPMP > 8) begin : g_cfg_hi
    assign pcfg_hi = re.pmpcfg[15:8];
  end else begin : g_cfg_none
    assign pcfg_hi = '0;
  end

  // ---- Cold CSRs in LUTRAM (FPGA-friendly T1) ----
  // xtvec, xscratch, xepc, xcause and xtval of M and S, per hart: one (16 x NUM_THREADS) x 64
  // tg_ram_lut at {tid, csr[9], csr[2:0]}, M (csr[9] = 1) or S, then scratch 0, epc 1, cause 2,
  // tval 3, tvec 5 (32 deep fits the same RAM32M16 as 16).
  // Read ports: the CSR read (EX), or xepc while an MRET or SRET is in flight (it is serial, so
  // no CSR instruction executes meanwhile: asserted); an exception's trap vector; the pending
  // interrupt's trap vector.
  // One write port, taken by
  //   - the reset sweep (PMP's counter, 16 cycles: nothing reads these before fetch starts),
  //   - trap entry: xepc, xcause and xtval in the three cycles after the trap, from registers,
  //   - a CSR write at commit.
  // The trap's flush keeps the window empty for longer than that, so nothing sees the order:
  // nothing commits, no trap is taken and no CSR instruction executes (asserted). A CSR
  // instruction in EX in the flush cycle reads before the writes, but it is killed there: its
  // result is never written back.
  localparam logic [2:0] CX_EPC = 3'd1, CX_CAUSE = 3'd2, CX_TVAL = 3'd3, CX_TVEC = 3'd5;  // scratch: 0
  function automatic logic cold_csr(input logic [11:0] x);
    return x == 12'h305 || (x >= 12'h340 && x <= 12'h343) ||
           (SU && (x == 12'h105 || (x >= 12'h140 && x <= 12'h143))) || (DEBUG_ON && x >= 12'h7B1 && x <= 12'h7B3);
  endfunction
  // A cold CSR's row: {csr[9], csr[2:0]}; debug mode's dpc, dscratch0 and dscratch1 (DEBUG_ON) take M's free rows 4, 6
  // and 7 (dpc's low bits would meet mepc's)
  localparam logic [3:0] CR_DPC = 4'b1100;
  function automatic logic [3:0] crow(input logic [11:0] x);
    if (DEBUG_ON && x[11:2] == 10'h1EC && x[1:0] != 2'b00) return (x[1:0] == 2'b01) ? CR_DPC : {3'b111, x[0]};
    return {x[9], x[2:0]};
  endfunction
  logic [2:0]       ts_q;               // trap writes to do: epc, cause, tval (one-hot)
  logic             tdbg_q;             // ... debug mode's entry: one write, dpc, in tval's slot (DEBUG_ON)
  tid_t             ttid_q;             // ... the trapping thread's
  logic             tdel_q;             // ... into S's registers
  logic             tirq_q;
  logic [5:0]       tcode_q;
  logic [63:0]      tepc_q, ttval_q;
  logic             cw_we;
  logic [CAW-1:0]   cw_wa;
  logic [63:0]      cw_wd;
  logic [2:0][CAW-1:0] cw_ra;           // CSR read or xepc, exception vector, interrupt vector
  logic [2:0][63:0] cw_rd;
  tg_ram_lut #(.DEPTH(16 * NT), .WIDTH(64), .NR(3)) u_cold (
    .clk, .we(cw_we), .waddr(cw_wa), .wdata(cw_wd), .raddr(cw_ra), .rdata(cw_rd));

  // ---- Interrupt pending bits, per hart ----
  // Time is a core-local snapshot of the ACLINT's mtime (DR-146): mtime_q, mtime a cycle earlier,
  // so the ACLINT reaches the core register to register. The Sstc compare runs between registers
  // and its result is registered (stip_q), so the 64-bit compare leaves the interrupt selection
  // and the commit decision. STIP shows two cycles after mtime crosses stimecmp, and a cycle after
  // a write to stimecmp, menvcfg or mip; such a write retires alone and flushes, so no instruction
  // reaches the ROB head before STIP has settled (tg_rob asserts the margin). `time` reads the
  // snapshot too: monotonic, a cycle behind the ACLINT (a nondeterministic read in lockstep).
  logic [63:0]         mtime_q;
  logic [NT-1:0]       stip_q;
  logic [NT-1:0][13:0] mip, ipend, ien;
  logic [NT-1:0]       lcofip;                     // M9's LCOFIP, per hart (g_hpm; 0 without HPM)
  logic [63:0]         hpm_rd;                     // M9's counter CSRs as the executing thread reads them (g_hpm)
  always_ff @(posedge clk) begin
    mtime_q <= mtime;
    for (int t = 0; t < NT; t++)
      stip_q[t] <= !rst && SU && (h_q[t].menv_stce ? (mtime_q >= h_q[t].stimecmp) : h_q[t].stip_sw);
  end
  always_comb begin
    for (int t = 0; t < NT; t++) begin
      logic m_en, s_en;
      tid_t hl;                                  // the hart's lines (SOLO_TID's thread is hart 0)
      hl = tid_t'(t) ^ RUN_TID;
      mip[t] = '0;
      mip[t][3]  = irq_msi[hl];
      mip[t][7]  = irq_mti[hl];
      mip[t][11] = irq_mei[hl];
      mip[t][13] = HPM && lcofip[t];
      if (SU) begin
        mip[t][1] = h_q[t].ssip || irq_ssi[hl];
        mip[t][5] = stip_q[t];
        mip[t][9] = h_q[t].seip_sw || irq_sei[hl];
      end
      // Interrupt selection (Spike's take_interrupt): M first, then those delegated to S.
      // Default priority: MEI, MSI, MTI, SEI, SSI, STI.
      ipend[t] = mip[t] & h_q[t].mie;
      m_en     = h_q[t].priv != PRIV_M || h_q[t].mie_bit;
      s_en     = h_q[t].priv == PRIV_U || (h_q[t].priv == PRIV_S && h_q[t].sie_bit);
      ien[t]   = ipend[t] & ~h_q[t].mideleg & {14{m_en}};
      if (ien[t] == '0) ien[t] = ipend[t] & h_q[t].mideleg & {14{s_en}};
    end
  end
  logic [13:0] ien_r;
  assign ien_r    = ien[ht];
  assign irq_take = |ien_r;
  assign irq_code = ien_r[11] ? 6'd11 : ien_r[3] ? 6'd3 : ien_r[7] ? 6'd7 :
                    ien_r[9]  ? 6'd9  : ien_r[1] ? 6'd1 : (!HPM || ien_r[5]) ? 6'd5 : 6'd13;   // LCOFI last
  assign wfi_wake = |ipend[ht] || (DEBUG_ON && dbg_req[ht] && !dm_q[ht]);
  for (genvar t = 0; t < NT; t++) begin : g_wake
    assign wfi_wake_h[t] = |ipend[t] || (DEBUG_ON && dbg_req[t] && !dm_q[t]);
    assign wfi_arm_h[t]  = |h_q[t].mie;
  end

  // ---- Each hart's decode state (M7's step 5b: decode reads its group's hart's) ----
  for (genvar t = 0; t < NT; t++) begin : g_dst
    assign dst_h[t] = '{misa_m: h_q[t].misa_m, misa_b: h_q[t].misa_b, misa_c: h_q[t].misa_c, misa_a: h_q[t].misa_a,
                        misa_f: h_q[t].misa_f, misa_d: h_q[t].misa_d, fs: h_q[t].fs, frm: 3'd0, priv: h_q[t].priv,
                        tvm: h_q[t].tvm, tw: h_q[t].tw, tsr: h_q[t].tsr};
  end
  // ---- Outputs (the running thread's) ----
  assign misa_m    = r.misa_m;
  assign misa_b    = r.misa_b;
  assign misa_c    = r.misa_c;
  assign misa_a    = r.misa_a;
  assign misa_f    = r.misa_f;
  assign misa_d    = r.misa_d;
  assign fs        = r.fs;
  assign priv      = r.priv;
  assign tvm       = r.tvm;
  assign tw        = r.tw;
  assign tsr       = r.tsr;
  assign satp_sv39 = r.satp_mode;
  assign satp_asid = r.satp_asid;
  // ---- PMP region descriptors (core-mmu.md §PMP), per hart ----
  // pmpaddr lives in LUTRAM ({tid, entry}). A PMP write marks the entries it changes, and one
  // descriptor unit recomputes a marked entry per cycle (either hart's) into pmp_d_q (flip-flops:
  // every checker reads all of them), and its page alignment into pal_top_q; pmp_busy holds fetch
  // meanwhile, and for one cycle after (pchg_q). The write's flush has emptied the window, so nothing
  // else checks PMP until fetch resumes. After reset a sweep writes the reset values (entry 0: NAPOT
  // over everything), then every entry is computed.
  // pal_top_q[i]: entry i's address is aligned to a 1G / 2M / 4K page (or above every PA), for the
  // walker's check of a leaf of that size (tg_ptw: is the leaf's page PMP-homogeneous? DR-182).
  pmp_d_t [NT-1:0][NPMP-1:0]    pmp_d_q;
  logic   [NT-1:0][NPMP-1:0][2:0] pal_top_q;   // entry's address aligned to 1G / 2M / 4K pages
  logic   [NT-1:0][NPMP-1:0]    pdirty_q;
  logic   [NT-1:0]              pchg_q;        // a descriptor changed last cycle: fetch waits one cycle more
  localparam int SWB = MT ? 5 : 4;             // the sweep's length: 16 rows a hart (cold CSRs; pmpaddr 8 or 16)
  logic   [SWB:0]               psw_q;         // reset sweep of the LUTRAM rows: the running thread's, or both
  tid_t                         swt;           // ... the hart it writes
  logic                         pa_we;
  logic   [PAW-1:0]             pa_wa;
  logic   [53:0]                pa_wd;
  logic   [1:0][PAW-1:0]        pa_ra;         // CSR read, descriptor unit
  logic   [1:0][53:0]           pa_rd;
  tg_ram_lut #(.DEPTH(NPMP * NT), .WIDTH(54), .NR(2)) u_pmpaddr (
    .clk, .we(pa_we), .waddr(pa_wa), .wdata(pa_wd), .raddr(pa_ra), .rdata(pa_rd));
  localparam logic [PMP_GW-1:0] AL4K = PMP_GW'((64'd1 << 10) - 1);
  localparam logic [PMP_GW-1:0] AL2M = PMP_GW'((64'd1 << 19) - 1);
  localparam logic [PMP_GW-1:0] AL1G = PMP_GW'((64'd1 << 28) - 1);
  logic       psweep, pcalc;
  tid_t       pt;                       // the hart and entry the unit computes
  logic [PIW-1:0] pj;
  pmp_d_t     pd_n;
  logic [2:0] ptop_n;
  logic [7:0] pcfg;
  assign psweep = !psw_q[SWB];
  assign swt    = MT ? tid_t'(psw_q[4]) : RUN_TID;
  always_comb begin
    pt = '0;
    pj = '0;
    for (int t = NT - 1; t >= 0; t--)
      for (int i = NPMP - 1; i >= 0; i--)
        if (pdirty_q[t][i]) begin
          pt = tid_t'(t);
          pj = PIW'(i);
        end
  end
  assign pcalc = !psweep && |pdirty_q;
  assign pcfg  = h_q[pt].pmpcfg[pj];
  always_comb begin
    logic [53:0] y, dc;
    y  = {pa_rd[1][52:0], 1'b1};
    dc = (pcfg[4:3] == 2'b11) ? (y & ~(y + 54'd1)) : '0;    // NAPOT don't-care bits
    pd_n.tor   = pcfg[4:3] == 2'b01;
    pd_n.nap   = pcfg[4];
    pd_n.l     = pcfg[7];
    pd_n.x     = pcfg[2];
    pd_n.w     = pcfg[1];
    pd_n.r     = pcfg[0];
    pd_n.hi    = pa_rd[1][53:PMP_GW] != '0;
    pd_n.above = (pa_rd[1][53:PMP_GW] & ~dc[53:PMP_GW]) != '0;
    pd_n.mask  = ~dc[PMP_GW-1:0];
    pd_n.a     = pa_rd[1][PMP_GW-1:0];
    ptop_n = {pd_n.hi || (pd_n.a & AL1G) == '0, pd_n.hi || (pd_n.a & AL2M) == '0,
              pd_n.hi || (pd_n.a & AL4K) == '0};
  end
  assign pa_ra[1] = paddr_(pt, pj);
  always_ff @(posedge clk) begin
    if (pcalc) begin
      pmp_d_q[pt][pj]   <= pd_n;
      pal_top_q[pt][pj] <= ptop_n;
    end
  end
  assign pmp_d    = pmp_d_q[RUN_TID];
  // DR-183 (PMP_FILL): each hart's active locked entries (L, and A not OFF). M-mode is bound only by those, so while a
  // hart has none its M accesses need no check. Registered from the descriptors: it settles the cycle after the
  // last one changes, which fetch still waits out (pchg_q), and the write's flush has emptied the window
  if (PMP_FILL) begin : g_plk
    logic [NT-1:0] plk_q;
    always_ff @(posedge clk)
      for (int t = 0; t < NT; t++) begin
        plk_q[t] <= 1'b0;
        for (int i = 0; i < NPMP; i++) if (pmp_d_q[t][i].l && (pmp_d_q[t][i].tor || pmp_d_q[t][i].nap)) plk_q[t] <= 1'b1;
      end
    assign pmp_lk_h = plk_q;
  end else begin : g_noplk
    assign pmp_lk_h = '0;
  end
  // (with hart 1 fetch waits while either hart's descriptors change: rare, and each hart's are its own)
  assign pmp_busy = MT ? (psweep || |pdirty_q || |pchg_q) : (psweep || |pdirty_q[RUN_TID] || pchg_q[RUN_TID]);
  always_comb begin
    for (int t = 0; t < NT; t++) begin
      priv_h[t]     = h_q[t].priv;
      priv_d_h[t]   = (h_q[t].mprv && h_q[t].priv == PRIV_M && !dm_q[t]) ? priv_e'(h_q[t].mpp) : h_q[t].priv;
      sum_h[t]      = h_q[t].sum;
      mxr_h[t]      = h_q[t].mxr;
      sv39_h[t]     = h_q[t].satp_mode;
      satp_ppn_h[t] = h_q[t].satp_ppn;
      pmp_d_h[t]    = pmp_d_q[t];
      pmp_pal_h[t]  = pal_top_q[t];
    end
  end
  // An xRET's xepc: with hart 1 on port 1, so that port 0 serves the other thread's CSR read (a legal xRET is
  // serial and alone at its thread's head, so no exception there needs port 1's vector meanwhile); without it
  // on port 0 (nothing executes meanwhile)
  assign xepc_o    = MT ? {cw_rd[1][63:2], cw_rd[1][1] && rh.misa_c, 1'b0}
                        : {cw_rd[0][63:2], cw_rd[0][1] && r.misa_c, 1'b0};

  // Trap targets: S's vector when delegated from S or U. An exception's target is its vector's
  // base, chosen by its cause, which can arrive late (the ROB head's TLB check); its thread is the
  // head's (wt). An interrupt's adds 4 x its code in vectored mode, but its code and delegation
  // are this file's own, early, so the add stays off the exception's path. The ROB picks one
  // (do_irq); tr_code is irq_code when tr_irq.
  logic deleg, deleg_e, deleg_i;
  always_comb begin
    deleg_e = SU && h_q[wt].priv != PRIV_M && tr_code < 6'd20 && h_q[wt].medeleg[tr_code[4:0]];
    deleg_i = SU && rh.priv != PRIV_M && irq_code < 6'd14 && rh.mideleg[irq_code[3:0]];
    deleg   = tr_irq ? deleg_i : deleg_e;
  end
  assign cw_ra[1]    = (MT && xret_v) ? caddr(ht, (DEBUG_ON && xret_d) ? CR_DPC : {!xret_s, CX_EPC})
                                      : caddr(wt, {!deleg_e, CX_TVEC});
  assign cw_ra[2]    = caddr(ht, {!deleg_i, CX_TVEC});
  assign trap_target = {cw_rd[1][63:2], 2'b00};
  assign irq_target  = {cw_rd[2][63:2], 2'b00} + (cw_rd[2][0] ? {56'b0, irq_code, 2'b00} : 64'd0);

  // ---- Status views (the reading thread's) ----
  logic [63:0] mstatus_rd, sstatus_rd, misa_rd;
  always_comb begin
    mstatus_rd = '0;
    mstatus_rd[3]     = re.mie_bit;
    mstatus_rd[7]     = re.mpie;
    mstatus_rd[12:11] = re.mpp;
    if (SU) begin
      mstatus_rd[1]     = re.sie_bit;
      mstatus_rd[5]     = re.spie;
      mstatus_rd[8]     = re.spp;
      mstatus_rd[14:13] = re.fs;
      mstatus_rd[17]    = re.mprv;
      mstatus_rd[18]    = re.sum;
      mstatus_rd[19]    = re.mxr;
      mstatus_rd[20]    = re.tvm;
      mstatus_rd[21]    = re.tw;
      mstatus_rd[22]    = re.tsr;
      mstatus_rd[33:32] = 2'd2;                  // UXL
      mstatus_rd[35:34] = 2'd2;                  // SXL
      mstatus_rd[63]    = re.fs == 2'd3;          // SD
    end
    sstatus_rd = '0;
    sstatus_rd[1]     = re.sie_bit;
    sstatus_rd[5]     = re.spie;
    sstatus_rd[8]     = re.spp;
    sstatus_rd[14:13] = re.fs;
    sstatus_rd[18]    = re.sum;
    sstatus_rd[19]    = re.mxr;
    sstatus_rd[33:32] = 2'd2;
    sstatus_rd[63]    = re.fs == 2'd3;
    misa_rd = '0;
    misa_rd[63:62] = 2'b10;
    misa_rd[0]  = re.misa_a;
    misa_rd[1]  = re.misa_b;
    misa_rd[2]  = re.misa_c;
    misa_rd[8]  = 1'b1;                          // I
    misa_rd[12] = re.misa_m;
    misa_rd[3]  = re.misa_d;                      // D
    misa_rd[5]  = re.misa_f;                      // F
    misa_rd[18] = SU;                            // S
    misa_rd[20] = SU;                            // U
  end

  // ---- Read and legality (the executing thread's: the running one without hart 1) ----
  logic [11:0] a;
  assign a = ex_pl.csr_addr;
  logic [63:0] cold_rd;                          // xepc reads as xepc_o
  assign cw_ra[0] = MT ? caddr(et, crow(a))
                       : (xret_v ? caddr(RUN_TID, (DEBUG_ON && xret_d) ? CR_DPC : {!xret_s, CX_EPC})
                                 : caddr(RUN_TID, crow(a)));
  assign cold_rd  = (a[2:0] == CX_EPC) ? {cw_rd[0][63:2], cw_rd[0][1] && re.misa_c, 1'b0} : cw_rd[0];
  logic        exists, deny;
  logic        h1off_q;                          // mtgsmt.HART1_OFF (below)
  logic [63:0] rval, rval_w;                     // rval_w: the old value a csrrs/csrrc modifies
  always_comb begin
    exists = 1'b1;
    deny   = 1'b0;
    rval   = '0;
    unique casez (a)
      12'h300: rval = mstatus_rd;
      12'h301: rval = misa_rd;
      12'h304: rval = {50'b0, re.mie};
      12'h305, 12'h340, 12'h341, 12'h342, 12'h343: rval = cold_rd;
      12'h320: rval = {32'b0, re.mcountinhibit};
      12'h344: rval = {50'b0, mip[et]};
      // No Sdtrig (M9 section 10): tselect, tdata1-3, tinfo and the context CSRs (mcontext, scontext) do not exist,
      // so an access traps as illegal (the default below). A write of tselect that traps means no triggers (Debug spec
      // 5.1), so OpenSBI finds no sdtrig and registers no SBI dbtr; reading 0 had made it count one trigger
      12'h7B0: begin rval = dcsr_rd; exists = DEBUG_ON && dm_q[et]; end    // dcsr, in debug mode only
      12'h7B1, 12'h7B2, 12'h7B3: begin rval = cold_rd; exists = DEBUG_ON && dm_q[et]; end   // dpc, dscratch0/1
      12'h7C0: begin rval = {63'b0, h1off_q}; exists = HART1_ON; end      // mtgsmt (step 6), with hart 1
      // ---- F and D ----
      12'h001: begin rval = {59'b0, fc_fflags}; exists = EXT_FD; if (re.fs == 2'd0) deny = 1'b1; end
      12'h002: begin rval = {61'b0, fc_frm}; exists = EXT_FD; if (re.fs == 2'd0) deny = 1'b1; end
      12'h003: begin
        rval = {56'b0, fc_frm, fc_fflags}; exists = EXT_FD;
        if (re.fs == 2'd0) deny = 1'b1;
      end
      12'hB00: rval = mcycle_q[et];
      12'hB02: rval = minstret_q[et];
      12'hC00: rval = mcycle_q[et];
      12'hC01: rval = mtime_q;
      12'hC02: rval = minstret_q[et];
      12'hF11, 12'hF12, 12'hF13, 12'hF15: rval = '0;
      12'hF14: rval = hartid(et);
      // ---- S and U (M3) ----
      12'h100: begin rval = sstatus_rd; exists = SU; end
      12'h104: begin rval = {50'b0, re.mie & re.mideleg}; exists = SU; end
      12'h105, 12'h140, 12'h141, 12'h142, 12'h143: begin rval = cold_rd; exists = SU; end
      12'h106: begin rval = {32'b0, re.scounteren}; exists = SU; end
      12'h10A: begin rval = {63'b0, re.senv_fiom}; exists = SU; end
      12'h144: begin rval = {50'b0, mip[et] & re.mideleg}; exists = SU; end
      12'h14D: begin                                                 // stimecmp (Sstc)
        rval = re.stimecmp; exists = SU;
        if (re.priv != PRIV_M && !(re.menv_stce && re.mcounteren[1])) deny = 1'b1;
      end
      12'h180: begin                                                 // satp
        rval = {re.satp_mode, 3'b0, re.satp_asid, re.satp_ppn}; exists = SU;
        if (re.priv == PRIV_S && re.tvm) deny = 1'b1;
      end
      12'h302: begin rval = {44'b0, re.medeleg}; exists = SU; end
      12'h303: begin rval = {50'b0, re.mideleg}; exists = SU; end
      12'h306: begin rval = {32'b0, re.mcounteren}; exists = SU; end
      12'h30A: begin rval = {re.menv_stce, 62'b0, re.menv_fiom}; exists = SU; end
      default: begin
        if (a >= 12'h3A0 && a <= 12'h3AF) begin                      // pmpcfg (even only)
          if (a[0]) exists = 1'b0;
          else if (a == 12'h3A0) rval = re.pmpcfg[7:0];
          else if (a == 12'h3A2) rval = pcfg_hi;
          else rval = '0;
        end else if (a >= 12'h3B0 && a <= 12'h3EF) begin             // pmpaddr0-63
          rval = (a - 12'h3B0 < 12'(NPMP)) ? {10'b0, pa_rd[0]} : '0;
        end else if ((a >= 12'hB03 && a <= 12'hB1F) || (a >= 12'h323 && a <= 12'h33F)) begin
          rval = hpm_rd;                                             // mhpmcounter*, mhpmevent* (M9: HPM_N of them)
        end else if (a >= 12'hC03 && a <= 12'hC1F) begin             // hpmcounter* (Zihpm)
          rval = hpm_rd;
          exists = SU;
        end else if (HPM && SU && a == 12'hDA0) begin                // scountovf (Sscofpmf)
          rval = hpm_rd;
        end else begin
          exists = 1'b0;
        end
      end
    endcase
    // Counter enables below M (cycle, time, instret, hpmcounter*)
    if (SU && a >= 12'hC00 && a <= 12'hC1F) begin
      if (re.priv != PRIV_M && !re.mcounteren[a[4:0]]) deny = 1'b1;
      if (re.priv == PRIV_U && !re.scounteren[a[4:0]]) deny = 1'b1;
    end
    if (2'(re.priv) < a[9:8]) deny = 1'b1;
    // Spike's read_for_write: mip's SEIP is the software bit alone
    rval_w = rval;
    if (a == 12'h344) rval_w[9] = SU && re.seip_sw;
  end

  // Write value and legality
  logic [63:0] wsrc, wval;
  always_comb begin
    wsrc = ex_pl.csr_imm ? {59'b0, ex_pl.csr_zimm} : ex_src;
    unique case (ex_pl.csr_op)
      CSR_RW:  wval = wsrc;
      CSR_RS:  wval = rval_w | wsrc;
      default: wval = rval_w & ~wsrc;
    endcase
  end
  assign ex_ill   = !exists || deny || (ex_pl.csr_wr && a[11:10] == 2'b11);
  assign ex_rdata = rval;

  // Pending writes, one per hart, applied at commit (the committing thread's: pv, pa, pd)
  logic [NT-1:0]        pw_v_q;
  logic [NT-1:0][11:0]  pw_a_q;
  logic [NT-1:0][63:0]  pw_d_q;
  logic                 pv;
  logic [11:0]          pa;
  logic [63:0]          pd;
  assign pv = pw_v_q[wt];
  assign pa = pw_a_q[wt];
  assign pd = pw_d_q[wt];
  // satp writes that change it flush the TLBs (as Spike: a rewrite of the same value does not)
  assign satp_wr = cm_csr && pv && pa == 12'h180 &&
                   (pd[63:60] == 4'd0 || pd[63:60] == 4'd8) &&
                   {pd[63], pd[59:44], pd[43:0]} !=
                   {h_q[wt].satp_mode, h_q[wt].satp_asid, h_q[wt].satp_ppn};
  // The cold CSRs' write port: the sweep, then the trap's three writes, else a CSR write
  always_comb begin
    cw_we = cm_csr && pv && cold_csr(pa);
    cw_wa = caddr(wt, crow(pa));
    cw_wd = pd & ~{62'b0, pa[2:0] == CX_TVEC, pa[2:0] == CX_EPC};
    if (psweep) begin
      cw_we = 1'b1;
      cw_wa = caddr(swt, psw_q[3:0]);
      cw_wd = '0;
    end else if (ts_q != '0) begin
      cw_we = 1'b1;
      cw_wa = (DEBUG_ON && tdbg_q) ? caddr(ttid_q, CR_DPC)
                                   : caddr(ttid_q, {!tdel_q, ts_q[0] ? CX_EPC : ts_q[1] ? CX_CAUSE : CX_TVAL});
      cw_wd = ts_q[0] ? tepc_q : ts_q[1] ? {tirq_q, 57'b0, tcode_q} : ttval_q;
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    // (with hart 1 the other thread's commit waits for the trap's writes, cold_busy, and its CSR reads go to its
    // own rows)
    if (!rst && (psweep || ts_q != '0))
      assert (!tr_valid && !mret && !sret && !(cm_csr && pv) &&
              !(ex_valid && !flush && cold_csr(a) && (!MT || psweep || et == ttid_q)))
        else $error("tg_csr: the cold CSRs are used while their sweep or a trap's writes run");
    if (!rst && xret_v)
      assert (!(ex_valid && !flush && (!MT || et == ht)))
        else $error("tg_csr: a CSR instruction executes while its thread's xRET is in flight");
  end
`endif

  // A trap's three cold-CSR writes take the LUTRAM's one write port in the cycles after it: the trapping thread's
  // window is empty then (its flush), and with hart 1 the ROB holds the other's commit (a CSR write, a trap or an
  // xRET would need the port or reorder the writes)
  assign cold_busy = MT && ts_q != '0;

  // PMP writes flush the TLBs, which cache PMP results (Spike flushes on them too)
  assign pmp_wr  = cm_csr && pv && (pa == 12'h3A0 || pa == 12'h3A2 || (pa >= 12'h3B0 && pa <= 12'h3BF));

  // pmpaddr writes (entry i is locked by its own L, or by entry i + 1's L when that is TOR)
  // and the reset sweep
  assign pa_ra[0] = paddr_(et, a[PIW-1:0]);
  always_comb begin
    int i;
    i = int'(pa[PIW-1:0]);
    pa_we = cm_csr && pv && pa >= 12'h3B0 && pa < 12'h3B0 + 12'(NPMP) &&
            !(h_q[wt].pmpcfg[i][7] ||
              (i + 1 < NPMP && h_q[wt].pmpcfg[(i + 1) % NPMP][7] &&
               h_q[wt].pmpcfg[(i + 1) % NPMP][4:3] == 2'b01));
    pa_wa = paddr_(wt, pa[PIW-1:0]);
    pa_wd = pd[53:0];
    if (psweep) begin                    // Spike's reset: entry 0 allows everything
      pa_we = int'(psw_q[3:0]) < NPMP;   // (the sweep runs 16 cycles for the cold CSRs)
      pa_wa = paddr_(swt, psw_q[PIW-1:0]);
      pa_wd = (psw_q[3:0] == '0) ? '1 : '0;
    end
  end

  // fcsr writes go to tg_fcsr in the cycle the CSR instruction retires (wt's)
  assign fc_wvalid = EXT_FD && cm_csr && pv && pa[11:2] == '0 && pa[1:0] != 2'd0;
  assign fc_waddr  = pa[1:0];
  assign fc_wdata  = pd[7:0];

  // pmpcfg byte write (Spike's rules: locked entries keep their value; W needs R)
  function automatic logic [7:0] pmpcfg_w(input logic [7:0] old, input logic [7:0] nv);
    logic [7:0] c;
    if (old[7]) return old;
    c = nv & 8'b1001_1111;
    if (!c[0]) c[1] = 1'b0;
    return c;
  endfunction
  // MPP legalisation (Spike's legalize_privilege without H): M-only keeps M; 2 becomes U
  function automatic logic [1:0] legal_pp(input logic [1:0] p);
    if (!SU) return 2'd3;
    return (p == 2'd2) ? 2'd0 : p;
  endfunction

  // ---- Counters (R1), per hart: a CSR write replaces that cycle's increment ----
  localparam int CNW = idx_w(COMMIT_WIDTH + 1);
  logic cyc_wr, ins_wr;
  assign cyc_wr = cm_csr && pv && pa == 12'hB00;
  assign ins_wr = cm_csr && pv && pa == 12'hB02;
  // A write takes effect in the counter a cycle late (tg_dsp_ctr): in that cycle the write's
  // flush is on, so nothing reads the counter, and the pending write holds (a flush keeps EX from
  // writing it). The retiring instructions are all slot 0's thread's. In the next cycle nothing
  // commits, so slot 0's thread (wt, pd) need not be the writer's (with hart 1 the other one; with
  // SOLO_TID=1 thread 0, whose pending write is zero, so a write loaded 0): each hart's counters load
  // its own pending write
  for (genvar t = 0; t < NT; t++) begin : g_ctr
    logic ld_c, ld_i;
    assign ld_c = cyc_wr && wt == tid_t'(t);
    assign ld_i = ins_wr && wt == tid_t'(t);
    tg_dsp_ctr #(.IW(1)) u_mcycle (
      .clk, .rst, .ld(ld_c), .d(pw_d_q[t]), .inc(!h_q[t].mcountinhibit[0] && !dm_q[t]), .q(mcycle_q[t]));
    tg_dsp_ctr #(.IW(CNW)) u_minstret (
      .clk, .rst, .ld(ld_i),  .d(pw_d_q[t]),
      .inc((h_q[t].mcountinhibit[2] || wt != tid_t'(t) || dm_q[t]) ? '0 : CNW'(cm_n)), .q(minstret_q[t]));
  end
`ifndef SYNTHESIS
  logic ctr_wr_q;
  always_ff @(posedge clk) begin
    ctr_wr_q <= !rst && (cyc_wr || ins_wr);
    if (!rst && ctr_wr_q)
      assert (flush && !(cyc_wr || ins_wr)) else $error("tg_csr: a counter write not followed by its flush");
  end
  // Until two threads run (M7's step 5), nothing of the other thread commits: its state stays at reset.
  // Checked from the core's first reset on: in the SoC the reset comes from a register, so the first
  // cycles may see it low before any reset
  if (NT > 1 && !MT) begin : g_one_thread
    logic rs_q;
    initial rs_q = 1'b0;
    always @(posedge clk) if (rst) rs_q <= 1'b1;
    always_ff @(posedge clk)
      if (rs_q && !rst)
        assert (h_q[~RUN_TID] == hart_reset() && !pw_v_q[~RUN_TID] && pdirty_q[~RUN_TID] == '0)
          else $error("tg_csr: the other thread's CSR state changed while one thread runs");
  end
`endif

  // ---- M9's counters (HPM_N > 0; docs/spec/m9-plan.md §1, the prototype) ----
  // Per hart, HPM_N programmable counters (tg_dsp_ctr pairs, as mcycle) count mhpmevent's event: 1 cycles, 2 instructions
  // retired, 3 .. 2 + HPM_EV tg_core's hpm_ev, 0 or any other nothing. Sscofpmf: the mode inhibits (MINH, SINH, UINH;
  // the hart's mode) and mcountinhibit stop a counter; a counter's top bit falling sets its OF, and OF rising sets the
  // hart's LCOFIP (mip/sip bit 13, cleared by software); scountovf shows the OF bits (to S only where mcounteren allows).
  // A counter write loads it a cycle late, as mcycle's (tg_dsp_ctr): the replaced value's count in the cycle between, and
  // any wrap of it, are dropped; the written value's own wrap (one written as -1 wraps at its next count) is an overflow.
  if (HPM) begin : g_hpm
    localparam int EW = 8;                        // mhpmevent's event field
    logic [NT-1:0][HPM_N-1:0][EW-1:0] ev_q;
    logic [NT-1:0][HPM_N-1:0]         of_q, minh_q, sinh_q, uinh_q, msb_q, ld1_q;
    logic [NT-1:0]                    lcof_q;
    logic [NT-1:0][HPM_N-1:0][63:0]   cnt_q;
    for (genvar t = 0; t < NT; t++) begin : g_t
      for (genvar i = 0; i < HPM_N; i++) begin : g_i
        logic           ld, stop;
        logic [CNW-1:0] ev;
        logic [63:0]    ldv;
        assign ld  = cm_csr && pv && wt == tid_t'(t) && pa == 12'hB03 + 12'(i);
        // The hart's own pending write: in the load's second cycle nothing commits, so wt (and pd) may name the other
        // thread (SOLO_TID=1: thread 0, whose pw_d_q stays zero)
        assign ldv = pw_d_q[t];
        always_comb begin
          ev = '0;
          if (ev_q[t][i] == EW'(1))      ev = CNW'(1);                                   // cycles
          else if (ev_q[t][i] == EW'(2)) ev = (wt == tid_t'(t)) ? CNW'(cm_n) : '0;       // instructions retired
          else
            for (int e = 0; e < HPM_EV; e++)
              if (ev_q[t][i] == EW'(3 + e)) ev = CNW'(hpm_ev[t][e]);
          stop = h_q[t].mcountinhibit[3 + i] || dm_q[t] || (h_q[t].priv == PRIV_M && minh_q[t][i]) ||
                 (h_q[t].priv == PRIV_S && sinh_q[t][i]) || (h_q[t].priv == PRIV_U && uinh_q[t][i]);
        end
        tg_dsp_ctr #(.IW(CNW)) u_ctr (
          .clk, .rst, .ld, .d(ldv), .inc(stop ? '0 : ev), .q(cnt_q[t][i]));
        // The top bit the counter goes on from: in the load's second cycle the written value's (held there)
        always_ff @(posedge clk) begin
          msb_q[t][i] <= ld1_q[t][i] ? ldv[63] : cnt_q[t][i][63];
          ld1_q[t][i] <= ld;
        end
      end
    end
    always_ff @(posedge clk)
      for (int t = 0; t < NT; t++)
        if (rst) begin
          ev_q[t] <= '0; of_q[t] <= '0; minh_q[t] <= '0; sinh_q[t] <= '0; uinh_q[t] <= '0; lcof_q[t] <= 1'b0;
        end else begin
          for (int i = 0; i < HPM_N; i++)
            if (msb_q[t][i] && !cnt_q[t][i][63] && !ld1_q[t][i]) begin   // a wrap, not of a replaced value
              of_q[t][i] <= 1'b1;
              if (!of_q[t][i]) lcof_q[t] <= 1'b1;
            end
          // CSR writes (the committing thread's), after the overflows: software's value wins
          if (cm_csr && pv && wt == tid_t'(t)) begin
            for (int i = 0; i < HPM_N; i++)
              if (pa == 12'h323 + 12'(i)) begin
                ev_q[t][i]   <= pd[EW-1:0];
                of_q[t][i]   <= pd[63];
                minh_q[t][i] <= pd[62];
                sinh_q[t][i] <= pd[61];
                uinh_q[t][i] <= pd[60];
              end
            if (pa == 12'h344) lcof_q[t] <= pd[13];                              // mip.LCOFIP (M)
            if (pa == 12'h144 && h_q[t].mideleg[13]) lcof_q[t] <= pd[13];       // sip.LCOFIP (S, delegated)
          end
        end
    assign lcofip = lcof_q;
    // Reads: the executing thread's counter (mhpmcounter, hpmcounter), event (mhpmevent) or overflow bits (scountovf)
    always_comb begin
      int i;
      hpm_rd = '0;
      i = int'(a[4:0]) - 3;
      if (i >= 0 && i < HPM_N) begin
        if (a[11:8] == 4'hB || a[11:8] == 4'hC) hpm_rd = cnt_q[et][i];
        else if (a[11:8] == 4'h3)
          hpm_rd = {of_q[et][i], minh_q[et][i], sinh_q[et][i], uinh_q[et][i], 2'b00, (58 - EW)'(0), ev_q[et][i]};
      end
      if (a == 12'hDA0)
        for (int k = 0; k < HPM_N; k++) hpm_rd[3 + k] = of_q[et][k] && (re.priv == PRIV_M || re.mcounteren[3 + k]);
    end
  end else begin : g_no_hpm
    assign lcofip = '0;
    assign hpm_rd = '0;
    logic unused_hpm;
    assign unused_hpm = ^hpm_ev;
  end

  // ---- mtgsmt (0x7C0, custom M-mode read/write; M7's step 6, threading.md): one per core, with hart 1 ----
  // Bit 0, HART1_OFF: hart 1 does not wake once it sleeps in WFI (tg_rob), so hart 0 keeps the whole window (SMT off).
  // Other bits read 0.
  always_ff @(posedge clk)
    if (rst || !HART1_ON) h1off_q <= 1'b0;
    else if (cm_csr && pv && pa == 12'h7C0) h1off_q <= pd[0];
  assign h1off_o = h1off_q;

  // ---- Debug mode (DEBUG_ON; core-priv.md "Debug mode"): per hart, dcsr's writable fields and the mode bit ----
  // dcsr: debugver 4; ebreakm/s/u, step and prv written by the debugger (prv 2 writes as U, as MPP); cause and prv
  // set at entry; stepie 0, stopcount 1, stoptime 0, mprven 0 and the rest 0 hardwired. dpc, dscratch0 and dscratch1
  // are cold rows (crow). The CSRs exist in debug mode only.
  logic [NT-1:0]      dm_q, debm_q, debs_q, debu_q, dstep_q;
  logic [NT-1:0][1:0] dprv_q;
  logic [NT-1:0][2:0] dcause_q;
  logic [63:0]        dcsr_rd;
  if (DEBUG_ON) begin : g_dbg
    always_ff @(posedge clk)
      for (int t = 0; t < NT; t++)
        if (rst) begin
          dm_q[t]  <= 1'b0;
          debm_q[t] <= 1'b0;
          debs_q[t] <= 1'b0;
          debu_q[t] <= 1'b0;
          dstep_q[t] <= 1'b0;
          dprv_q[t]  <= 2'd3;
          dcause_q[t] <= 3'd0;
        end else if (wt == tid_t'(t)) begin
          if (dbg_enter) begin
            dm_q[t]     <= 1'b1;
            dprv_q[t]   <= 2'(h_q[t].priv);
            dcause_q[t] <= dbg_cause;
          end else if (dret) begin
            dm_q[t] <= 1'b0;
          end else if (cm_csr && pv && pa == 12'h7B0) begin
            debm_q[t]  <= pd[15];
            debs_q[t]  <= SU && pd[13];
            debu_q[t]  <= SU && pd[12];
            dstep_q[t] <= pd[2];
            dprv_q[t]  <= !SU ? 2'd3 : (pd[1:0] == 2'd2) ? 2'd0 : pd[1:0];
          end
        end
    assign dcsr_rd = {32'b0, 4'd4, 12'b0, debm_q[et], 1'b0, debs_q[et], debu_q[et], 1'b0, 1'b1, 1'b0, dcause_q[et],
                      3'b0, dstep_q[et], dprv_q[et]};
  end else begin : g_nodbg
    assign dm_q     = '0;
    assign debm_q   = '0;
    assign debs_q   = '0;
    assign debu_q   = '0;
    assign dstep_q  = '0;
    assign dprv_q   = '0;
    assign dcause_q = '0;
    assign dcsr_rd  = '0;
    logic unused_dbg;
    assign unused_dbg = ^{dbg_cause, dcause_q};
  end
  for (genvar t = 0; t < NT; t++) begin : g_dbg_o
    assign dm_h[t]    = dm_q[t];
    assign dstep_h[t] = dstep_q[t];
    assign debk_h[t]  = (h_q[t].priv == PRIV_M && debm_q[t]) || (h_q[t].priv == PRIV_S && debs_q[t]) ||
                        (h_q[t].priv == PRIV_U && debu_q[t]);
  end
  // ---- Next state of each hart ----
  always_comb begin
    for (int t = 0; t < NT; t++) begin
      csr_hart_t x;
      x = h_q[t];
      // F and D: FS becomes Dirty when tg_fcsr says so (and on an fcsr write)
      if (EXT_FD && (fs_dirty[t] || (fc_wvalid && wt == tid_t'(t)))) x.fs = 2'd3;
      if (wt == tid_t'(t)) begin
        // Commit of the CSR instruction
        if (cm_csr && pv) begin
          unique casez (pa)
            12'h300: begin
              x.mie_bit = pd[3];
              x.mpie    = pd[7];
              x.mpp     = legal_pp(pd[12:11]);
              if (SU) begin
                x.sie_bit = pd[1];
                x.spie    = pd[5];
                x.spp     = pd[8];
                x.fs      = pd[14:13];
                x.mprv    = pd[17];
                x.sum     = pd[18];
                x.mxr     = pd[19];
                x.tvm     = pd[20];
                x.tw      = pd[21];
                x.tsr     = pd[22];
              end
            end
            12'h100: begin
              x.sie_bit = pd[1];
              x.spie    = pd[5];
              x.spp     = pd[8];
              x.fs      = pd[14:13];
              x.sum     = pd[18];
              x.mxr     = pd[19];
            end
            12'h301: begin
              // Spike: clearing C is ignored when the CSR instruction's PC is not 4-byte aligned
              x.misa_m = pd[12];
              x.misa_b = EXT_B && pd[1];
              x.misa_a = EXT_A && pd[0];
              x.misa_f = EXT_FD && pd[5];
              x.misa_d = EXT_FD && pd[3] && pd[5];   // D needs F (Spike)
              if (!(h_q[t].misa_c && !pd[2] && cm_pc[1])) x.misa_c = EXT_C && pd[2];
            end
            12'h302: x.medeleg = pd[19:0] & {4'b1000, 4'b1011, 2'b00, 6'b11_1111, 3'b111, !h_q[t].misa_c};
            12'h303: x.mideleg = pd[13:0] & (14'h0222 | LCOF);
            12'h304: x.mie = pd[13:0] & (SU ? (14'h0aaa | LCOF) : 14'h0888);
            12'h104: x.mie = (h_q[t].mie & ~h_q[t].mideleg) | (pd[13:0] & h_q[t].mideleg & (14'h0222 | LCOF));
            12'h344: begin
              if (SU) begin
                x.ssip = pd[1];
                if (!h_q[t].menv_stce) x.stip_sw = pd[5];
                x.seip_sw = pd[9];
              end
            end
            12'h144: if (h_q[t].mideleg[1]) x.ssip = pd[1];
            12'h305, 12'h105, 12'h340, 12'h140, 12'h341, 12'h141, 12'h342, 12'h142, 12'h343,
            12'h143: ;                                       // u_cold (the cold CSRs above)
            12'h306: x.mcounteren = pd[31:0];
            12'h106: x.scounteren = pd[31:0];
            12'h320: x.mcountinhibit = pd[31:0] & (SU ? 32'hffff_fffd : 32'h0000_0005);
            12'h30A: begin x.menv_fiom = pd[0]; x.menv_stce = pd[63]; end
            12'h10A: x.senv_fiom = pd[0];
            12'h14D: x.stimecmp = pd;
            12'h180: begin
              // A write with an unsupported MODE has no effect at all (privileged spec, Spike);
              // Bare and Sv39 write MODE, ASID and PPN
              if (pd[63:60] == 4'd0 || pd[63:60] == 4'd8) begin
                x.satp_mode = pd[63];
                x.satp_asid = pd[59:44];
                x.satp_ppn  = pd[43:0];
              end
            end
            12'h3A0: for (int i = 0; i < 8; i++) x.pmpcfg[i] = pmpcfg_w(h_q[t].pmpcfg[i], pd[8*i +: 8]);
            12'h3A2: for (int i = 8; i < NPMP; i++)        // (entries 8-15: none with 8 entries)
                       x.pmpcfg[i] = pmpcfg_w(h_q[t].pmpcfg[i], pd[8*(i-8) +: 8]);
            default: ;                                       // pmpaddr: written in its LUTRAM
          endcase
        end
        // Trap entry (xepc, xcause and xtval follow in u_cold), MRET, SRET
        if (tr_valid) begin
          if (deleg) begin
            x.spie    = h_q[t].sie_bit;
            x.sie_bit = 1'b0;
            x.spp     = h_q[t].priv == PRIV_S;
            x.priv    = PRIV_S;
          end else begin
            x.mpie    = h_q[t].mie_bit;
            x.mie_bit = 1'b0;
            x.mpp     = SU ? 2'(h_q[t].priv) : 2'd3;
            x.priv    = PRIV_M;
          end
        end else if (DEBUG_ON && dbg_enter) begin           // debug mode: M, nothing else changes
          x.priv    = PRIV_M;
        end else if (DEBUG_ON && dret) begin                // dret: dcsr.prv's mode; MPRV cleared below M
          x.priv    = priv_e'(dprv_q[t]);
          if (dprv_q[t] != 2'd3) x.mprv = 1'b0;
        end else if (mret) begin
          x.mie_bit = h_q[t].mpie;
          x.mpie    = 1'b1;
          x.priv    = priv_e'(h_q[t].mpp);
          x.mpp     = SU ? 2'd0 : 2'd3;
          if (h_q[t].mpp != 2'd3) x.mprv = 1'b0;
        end else if (sret) begin
          x.sie_bit = h_q[t].spie;
          x.spie    = 1'b1;
          x.priv    = h_q[t].spp ? PRIV_S : PRIV_U;
          x.spp     = 1'b0;
          x.mprv    = 1'b0;
        end
      end
      h_n[t] = x;
    end
  end

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int t = 0; t < NT; t++) h_q[t] <= hart_reset();
      psw_q     <= '0;
      pdirty_q  <= '0;
      pdirty_q[RUN_TID] <= '1;            // the running thread's descriptors, after its sweep (with hart 1 both)
      if (MT) pdirty_q <= '1;
      pchg_q    <= '0;
      pw_v_q    <= '0;
      // The other thread's pending write is never set until two threads run (step 5), but commit reads it by the
      // committing thread: reset, it has a driver in synthesis (an undriven net in Vivado otherwise)
      for (int t = 0; t < NT; t++)
        if (tid_t'(t) != RUN_TID) begin
          pw_a_q[t] <= '0;
          pw_d_q[t] <= '0;
        end
      ts_q      <= '0;
    end else begin
      h_q <= h_n;
      // PMP: reset sweep, then descriptor recomputation of the marked entries
      if (psweep) psw_q <= psw_q + 1'b1;
      for (int t = 0; t < NT; t++) pchg_q[t] <= pcalc && pt == tid_t'(t);
      if (pcalc) pdirty_q[pt][pj] <= 1'b0;

      // Execute: hold the write until commit (the executing thread's: the running one without hart 1)
      if (flush) pw_v_q[ft] <= 1'b0;
      if (ex_valid && !(flush && (!MT || et == ft))) begin   // (with hart 1 the other thread's flush spares it)
        pw_v_q[et] <= !ex_ill && ex_pl.csr_wr;
        pw_a_q[et] <= a;
        pw_d_q[et] <= wval;
      end

      // Commit of the CSR instruction: it leaves the pending write; PMP writes mark their entries
      if (cm_csr && pv) begin
        pw_v_q[wt] <= 1'b0;
        if (pa == 12'h3A0) pdirty_q[wt][7:0] <= '1;
        else if (pa == 12'h3A2) for (int i = 8; i < NPMP; i++) pdirty_q[wt][i] <= 1'b1;
        else if (pa_we) pdirty_q[wt][pa[PIW-1:0]] <= 1'b1;
      end

      // Trap entry: xepc, xcause and xtval follow in u_cold, into the trapping thread's rows
      ts_q <= {ts_q[1:0], 1'b0};
      if (tr_valid) begin
        ts_q    <= 3'b001;
        tdbg_q  <= 1'b0;
        ttid_q  <= wt;
        tdel_q  <= deleg;
        tirq_q  <= tr_irq;
        tcode_q <= tr_code;
        tepc_q  <= tr_epc & ~64'd1;
        ttval_q <= tr_irq ? 64'd0 : tr_tval;
      end else if (DEBUG_ON && dbg_enter) begin             // debug mode's entry: dpc, one write in tval's slot
        ts_q    <= 3'b100;
        tdbg_q  <= 1'b1;
        ttid_q  <= wt;
        ttval_q <= dbg_epc & ~64'd1;
      end
    end
  end

  logic unused;
  assign unused = ^{ex_pl, cm_pc[63:2], cm_pc[0], r, re.menv_fiom, re.senv_fiom, re.ssip, re.stip_sw, rh, cw_rd[1][1:0],
                    cw_rd[2][1], pcfg[6:5]};
endmodule
