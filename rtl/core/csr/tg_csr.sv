// CSR file, privilege modes, traps and interrupts (docs/spec/core-pipeline.md §9 for M2,
// docs/spec/core-priv.md for M3). Field behaviour follows Spike's WARL rules for the configured
// ISA, so lockstep compares every read:
//   EXT_SU = 0 (M2): machine mode only, RV64IM + Zicsr + Zicntr + Zifencei, 16 PMP entries.
//   EXT_SU = 1 (M3): M, S and U modes, delegation, Sstc, Zihpm, satp (Sv39), envcfg.
// One hart (tid 0); per-hart arrays arrive with M7.
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
  input  logic                   flush,        // drops a pending write
  // Execute (P1, EX)
  input  logic                   ex_valid,
  input  iq_pl_t                 ex_pl,
  input  logic [63:0]            ex_src,       // rs1
  output logic [63:0]            ex_rdata,
  output logic                   ex_ill,
  // Commit
  input  logic                   cm_csr,       // the CSR instruction retires: apply its write
  input  logic [63:0]            cm_pc,        // ... its PC
  input  logic [idx_w(COMMIT_WIDTH + 1)-1:0] cm_n,   // instructions retiring this cycle
  input  logic                   tr_valid,     // trap entry
  input  logic                   tr_irq,
  input  logic [5:0]             tr_code,      // cause code (interrupt: without bit 63)
  input  logic [63:0]            tr_epc,
  input  logic [63:0]            tr_tval,
  input  logic                   mret,
  input  logic                   sret,
  // State for commit, decode, fetch and the MMU
  output logic [63:0]            trap_target,  // for tr_* given this cycle
  output logic [63:0]            mepc_o,
  output logic [63:0]            sepc_o,
  output logic                   irq_take,     // an enabled interrupt is pending
  output logic [5:0]             irq_code,
  output logic                   wfi_wake,     // mip & mie != 0
  output logic                   misa_m,
  output logic                   misa_b,       // Zba/Zbb/Zbs enabled (Spike lets software clear B)
  output logic                   misa_c,       // compressed instructions enabled
  output logic                   misa_a,       // atomics enabled
  output priv_e                  priv,         // current mode
  output priv_e                  priv_d,       // mode of data accesses (MPRV)
  output logic                   tvm,
  output logic                   tw,
  output logic                   tsr,
  output logic                   sum,
  output logic                   mxr,
  output logic                   satp_sv39,
  output logic [15:0]            satp_asid,
  output logic [43:0]            satp_ppn,
  output logic                   satp_wr,      // a satp write that changes it commits: TLB flush
  output pmp_d_t [15:0]          pmp_d,        // PMP region descriptors (registered)
  output logic [2:0]             pmp_al,       // every 4K / 2M / 1G page is PMP-homogeneous
  output logic                   pmp_wr,       // a PMP CSR write commits: the TLBs flush
  output logic                   pmp_busy,     // descriptors being recomputed: fetch waits
  // Interrupt inputs and time
  input  logic                   irq_mei,
  input  logic                   irq_mti,
  input  logic                   irq_msi,
  input  logic                   irq_sei,
  input  logic                   irq_ssi,
  input  logic [63:0]            mtime
);
  localparam int NPMP = 16;
  localparam logic [63:0] HARTID = 64'(CORE_ID * NUM_THREADS);
  localparam bit SU = EXT_SU;

  // ---- State ----
  priv_e       priv_q;
  logic        mie_bit_q, mpie_q, sie_bit_q, spie_q, spp_q, mprv_q, sum_q, mxr_q, tvm_q, tw_q, tsr_q;
  logic [1:0]  mpp_q, fs_q;
  logic        misa_m_q, misa_b_q, misa_c_q, misa_a_q;
  logic [63:0] mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q, mcycle_q, minstret_q;
  logic [63:0] stvec_q, sscratch_q, sepc_q, scause_q, stval_q, stimecmp_q;
  logic [11:0] mie_q;
  logic        ssip_q, stip_sw_q, seip_sw_q;
  logic [19:0] medeleg_q;                      // bit 19: hardware error (Spike, with Zicntr)
  logic [11:0] mideleg_q;
  logic [31:0] mcounteren_q, scounteren_q, mcountinhibit_q;
  logic        menv_fiom_q, menv_stce_q, senv_fiom_q;
  logic        satp_mode_q;
  logic [15:0] satp_asid_q;
  logic [43:0] satp_ppn_q;
  logic [12:0] mcontext_q;
  logic [31:0] scontext_q;
  logic [NPMP-1:0][7:0]  pmpcfg_q;

  // ---- Interrupt pending bits ----
  logic        stip;
  assign stip = SU && (menv_stce_q ? (mtime >= stimecmp_q) : stip_sw_q);
  logic [11:0] mip;
  always_comb begin
    mip = '0;
    mip[3]  = irq_msi;
    mip[7]  = irq_mti;
    mip[11] = irq_mei;
    if (SU) begin
      mip[1] = ssip_q || irq_ssi;
      mip[5] = stip;
      mip[9] = seip_sw_q || irq_sei;
    end
  end

  // Interrupt selection (Spike's take_interrupt): M first, then those delegated to S.
  // Default priority: MEI, MSI, MTI, SEI, SSI, STI.
  logic [11:0] ipend, ien;
  always_comb begin
    logic m_en, s_en;
    ipend = mip & mie_q;
    m_en  = priv_q != PRIV_M || mie_bit_q;
    s_en  = priv_q == PRIV_U || (priv_q == PRIV_S && sie_bit_q);
    ien   = ipend & ~mideleg_q & {12{m_en}};
    if (ien == '0) ien = ipend & mideleg_q & {12{s_en}};
  end
  assign irq_take = |ien;
  assign irq_code = ien[11] ? 6'd11 : ien[3] ? 6'd3 : ien[7] ? 6'd7 :
                    ien[9]  ? 6'd9  : ien[1] ? 6'd1 : 6'd5;
  assign wfi_wake = |ipend;

  // ---- Outputs ----
  assign misa_m    = misa_m_q;
  assign misa_b    = misa_b_q;
  assign misa_c    = misa_c_q;
  assign misa_a    = misa_a_q;
  assign priv      = priv_q;
  assign priv_d    = (mprv_q && priv_q == PRIV_M) ? priv_e'(mpp_q) : priv_q;
  assign tvm       = tvm_q;
  assign tw        = tw_q;
  assign tsr       = tsr_q;
  assign sum       = sum_q;
  assign mxr       = mxr_q;
  assign satp_sv39 = satp_mode_q;
  assign satp_asid = satp_asid_q;
  assign satp_ppn  = satp_ppn_q;
  // ---- PMP region descriptors (core-mmu.md §PMP) ----
  // pmpaddr lives in LUTRAM. A PMP write marks the entries it changes, and one descriptor unit
  // recomputes a marked entry per cycle into pmp_d_q (flip-flops: every checker reads all 16);
  // pmp_al follows a cycle later. pmp_busy holds fetch meanwhile: the write's flush has emptied
  // the window, so nothing else checks PMP until fetch resumes. After reset a sweep writes the
  // reset values (entry 0: NAPOT over everything), then every entry is computed.
  // pmp_al[j]: no active region boundary lies strictly inside a page of 2^k granules (k = 10,
  // 19, 28: 4K, 2M, 1G), so such pages can cache one result.
  pmp_d_t [NPMP-1:0]     pmp_d_q;
  logic [NPMP-1:0][2:0]  pal_top_q;     // entry's address aligned to 1G / 2M / 4K pages
  logic [2:0]            pmp_al_n, pmp_al_q;
  logic [NPMP-1:0]       pdirty_q;
  logic                  pchg_q;        // a descriptor changed last cycle: pmp_al follows
  logic [4:0]            psw_q;         // reset sweep of the pmpaddr LUTRAM
  logic                  pa_we;
  logic [3:0]            pa_wa;
  logic [53:0]           pa_wd;
  logic [1:0][3:0]       pa_ra;         // CSR read, descriptor unit
  logic [1:0][53:0]      pa_rd;
  tg_ram_lut #(.DEPTH(NPMP), .WIDTH(54), .NR(2)) u_pmpaddr (
    .clk, .we(pa_we), .waddr(pa_wa), .wdata(pa_wd), .raddr(pa_ra), .rdata(pa_rd));
  localparam logic [PMP_GW-1:0] AL4K = PMP_GW'((64'd1 << 10) - 1);
  localparam logic [PMP_GW-1:0] AL2M = PMP_GW'((64'd1 << 19) - 1);
  localparam logic [PMP_GW-1:0] AL1G = PMP_GW'((64'd1 << 28) - 1);
  logic       psweep, pcalc;
  logic [3:0] pj;                       // the entry the unit computes
  pmp_d_t     pd_n;
  logic [2:0] ptop_n;
  logic [7:0] pcfg;
  assign psweep = !psw_q[4];
  always_comb begin
    pj = '0;
    for (int i = NPMP - 1; i >= 0; i--) if (pdirty_q[i]) pj = 4'(i);
  end
  assign pcalc = !psweep && |pdirty_q;
  assign pcfg  = pmpcfg_q[pj];
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
  assign pa_ra[1] = pj;
  always_comb begin
    pmp_al_n = '1;
    for (int i = 0; i < NPMP; i++) begin
      if (pmp_d_q[i].tor) pmp_al_n &= pal_top_q[i] & ((i == 0) ? 3'b111 : pal_top_q[(i + NPMP - 1) % NPMP]);
      if (pmp_d_q[i].nap && !pmp_d_q[i].above)
        pmp_al_n &= ~{pmp_d_q[i].mask[27], pmp_d_q[i].mask[18], pmp_d_q[i].mask[9]};
    end
  end
  always_ff @(posedge clk) begin
    if (pcalc) begin
      pmp_d_q[pj]   <= pd_n;
      pal_top_q[pj] <= ptop_n;
    end
    pmp_al_q <= pmp_al_n;
  end
  assign pmp_d    = pmp_d_q;
  assign pmp_al   = pmp_al_q;
  assign pmp_busy = psweep || |pdirty_q || pchg_q;
  assign mepc_o    = {mepc_q[63:2], mepc_q[1] && misa_c_q, 1'b0};
  assign sepc_o    = {sepc_q[63:2], sepc_q[1] && misa_c_q, 1'b0};

  // Trap target: S when delegated from S or U
  logic deleg;
  always_comb begin
    if (!SU || priv_q == PRIV_M)  deleg = 1'b0;
    else if (tr_irq)              deleg = tr_code < 6'd12 && mideleg_q[tr_code[3:0]];
    else                          deleg = tr_code < 6'd20 && medeleg_q[tr_code[4:0]];
  end
  logic [63:0] tvec;
  assign tvec = deleg ? stvec_q : mtvec_q;
  assign trap_target = {tvec[63:2], 2'b00} + ((tr_irq && tvec[0]) ? {56'b0, tr_code, 2'b00} : 64'd0);

  // ---- Status views ----
  logic [63:0] mstatus_rd, sstatus_rd, misa_rd;
  always_comb begin
    mstatus_rd = '0;
    mstatus_rd[3]     = mie_bit_q;
    mstatus_rd[7]     = mpie_q;
    mstatus_rd[12:11] = mpp_q;
    if (SU) begin
      mstatus_rd[1]     = sie_bit_q;
      mstatus_rd[5]     = spie_q;
      mstatus_rd[8]     = spp_q;
      mstatus_rd[14:13] = fs_q;
      mstatus_rd[17]    = mprv_q;
      mstatus_rd[18]    = sum_q;
      mstatus_rd[19]    = mxr_q;
      mstatus_rd[20]    = tvm_q;
      mstatus_rd[21]    = tw_q;
      mstatus_rd[22]    = tsr_q;
      mstatus_rd[33:32] = 2'd2;                  // UXL
      mstatus_rd[35:34] = 2'd2;                  // SXL
      mstatus_rd[63]    = fs_q == 2'd3;          // SD
    end
    sstatus_rd = '0;
    sstatus_rd[1]     = sie_bit_q;
    sstatus_rd[5]     = spie_q;
    sstatus_rd[8]     = spp_q;
    sstatus_rd[14:13] = fs_q;
    sstatus_rd[18]    = sum_q;
    sstatus_rd[19]    = mxr_q;
    sstatus_rd[33:32] = 2'd2;
    sstatus_rd[63]    = fs_q == 2'd3;
    misa_rd = '0;
    misa_rd[63:62] = 2'b10;
    misa_rd[0]  = misa_a_q;
    misa_rd[1]  = misa_b_q;
    misa_rd[2]  = misa_c_q;
    misa_rd[8]  = 1'b1;                          // I
    misa_rd[12] = misa_m_q;
    misa_rd[18] = SU;                            // S
    misa_rd[20] = SU;                            // U
  end

  // ---- Read and legality ----
  logic [11:0] a;
  assign a = ex_pl.csr_addr;
  logic        exists, deny;
  logic [63:0] rval, rval_w;                     // rval_w: the old value a csrrs/csrrc modifies
  always_comb begin
    exists = 1'b1;
    deny   = 1'b0;
    rval   = '0;
    unique casez (a)
      12'h300: rval = mstatus_rd;
      12'h301: rval = misa_rd;
      12'h304: rval = {52'b0, mie_q};
      12'h305: rval = mtvec_q;
      12'h320: rval = {32'b0, mcountinhibit_q};
      12'h340: rval = mscratch_q;
      12'h341: rval = mepc_o;
      12'h342: rval = mcause_q;
      12'h343: rval = mtval_q;
      12'h344: rval = {52'b0, mip};
      12'h7A0, 12'h7A1, 12'h7A2, 12'h7A3, 12'h7A4: rval = '0;
      12'h7A8: rval = {51'b0, mcontext_q};
      12'hB00: rval = mcycle_q;
      12'hB02: rval = minstret_q;
      12'hC00: rval = mcycle_q;
      12'hC01: rval = mtime;
      12'hC02: rval = minstret_q;
      12'hF11, 12'hF12, 12'hF13, 12'hF15: rval = '0;
      12'hF14: rval = HARTID;
      // ---- S and U (M3) ----
      12'h100: begin rval = sstatus_rd; exists = SU; end
      12'h104: begin rval = {52'b0, mie_q & mideleg_q}; exists = SU; end
      12'h105: begin rval = stvec_q; exists = SU; end
      12'h106: begin rval = {32'b0, scounteren_q}; exists = SU; end
      12'h10A: begin rval = {63'b0, senv_fiom_q}; exists = SU; end
      12'h140: begin rval = sscratch_q; exists = SU; end
      12'h141: begin rval = sepc_o; exists = SU; end
      12'h142: begin rval = scause_q; exists = SU; end
      12'h143: begin rval = stval_q; exists = SU; end
      12'h144: begin rval = {52'b0, mip & mideleg_q}; exists = SU; end
      12'h14D: begin                                                 // stimecmp (Sstc)
        rval = stimecmp_q; exists = SU;
        if (priv_q != PRIV_M && !(menv_stce_q && mcounteren_q[1])) deny = 1'b1;
      end
      12'h180: begin                                                 // satp
        rval = {satp_mode_q, 3'b0, satp_asid_q, satp_ppn_q}; exists = SU;
        if (priv_q == PRIV_S && tvm_q) deny = 1'b1;
      end
      12'h5A8: begin rval = {32'b0, scontext_q}; exists = SU; end
      12'h302: begin rval = {44'b0, medeleg_q}; exists = SU; end
      12'h303: begin rval = {52'b0, mideleg_q}; exists = SU; end
      12'h306: begin rval = {32'b0, mcounteren_q}; exists = SU; end
      12'h30A: begin rval = {menv_stce_q, 62'b0, menv_fiom_q}; exists = SU; end
      default: begin
        if (a >= 12'h3A0 && a <= 12'h3AF) begin                      // pmpcfg (even only)
          if (a[0]) exists = 1'b0;
          else if (a == 12'h3A0) rval = pmpcfg_q[7:0];
          else if (a == 12'h3A2) rval = pmpcfg_q[15:8];
          else rval = '0;
        end else if (a >= 12'h3B0 && a <= 12'h3EF) begin             // pmpaddr0-63
          rval = (a - 12'h3B0 < 12'(NPMP)) ? {10'b0, pa_rd[0]} : '0;
        end else if ((a >= 12'hB03 && a <= 12'hB1F) || (a >= 12'h323 && a <= 12'h33F)) begin
          rval = '0;                                                 // mhpmcounter*, mhpmevent*
        end else if (a >= 12'hC03 && a <= 12'hC1F) begin             // hpmcounter* (Zihpm)
          rval = '0;
          exists = SU;
        end else begin
          exists = 1'b0;
        end
      end
    endcase
    // Counter enables below M (cycle, time, instret, hpmcounter*)
    if (SU && a >= 12'hC00 && a <= 12'hC1F) begin
      if (priv_q != PRIV_M && !mcounteren_q[a[4:0]]) deny = 1'b1;
      if (priv_q == PRIV_U && !scounteren_q[a[4:0]]) deny = 1'b1;
    end
    if (2'(priv_q) < a[9:8]) deny = 1'b1;
    // Spike's read_for_write: mip's SEIP is the software bit alone
    rval_w = rval;
    if (a == 12'h344) rval_w[9] = SU && seip_sw_q;
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

  // Pending write, applied at commit
  logic        pw_v_q;
  logic [11:0] pw_a_q;
  logic [63:0] pw_d_q;
  // satp writes that change it flush the TLBs (as Spike: a rewrite of the same value does not)
  assign satp_wr = cm_csr && pw_v_q && pw_a_q == 12'h180 &&
                   (pw_d_q[63:60] == 4'd0 || pw_d_q[63:60] == 4'd8) &&
                   {pw_d_q[63], pw_d_q[59:44], pw_d_q[43:0]} != {satp_mode_q, satp_asid_q, satp_ppn_q};
  // PMP writes flush the TLBs, which cache PMP results (Spike flushes on them too)
  assign pmp_wr  = cm_csr && pw_v_q && (pw_a_q == 12'h3A0 || pw_a_q == 12'h3A2 ||
                                        (pw_a_q >= 12'h3B0 && pw_a_q <= 12'h3BF));

  // pmpaddr writes (entry i is locked by its own L, or by entry i + 1's L when that is TOR)
  // and the reset sweep
  assign pa_ra[0] = a[3:0];
  always_comb begin
    int i;
    i = int'(pw_a_q[3:0]);
    pa_we = cm_csr && pw_v_q && pw_a_q >= 12'h3B0 && pw_a_q <= 12'h3BF &&
            !(pmpcfg_q[i][7] ||
              (i + 1 < NPMP && pmpcfg_q[(i + 1) % NPMP][7] && pmpcfg_q[(i + 1) % NPMP][4:3] == 2'b01));
    pa_wa = pw_a_q[3:0];
    pa_wd = pw_d_q[53:0];
    if (psweep) begin                    // Spike's reset: entry 0 allows everything
      pa_we = 1'b1;
      pa_wa = psw_q[3:0];
      pa_wd = (psw_q[3:0] == '0) ? '1 : '0;
    end
  end

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

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    if (rst) begin
      priv_q    <= PRIV_M;
      mie_bit_q <= 1'b0;
      mpie_q    <= 1'b0;
      sie_bit_q <= 1'b0;
      spie_q    <= 1'b0;
      spp_q     <= 1'b0;
      mpp_q     <= SU ? 2'd0 : 2'd3;
      fs_q      <= 2'd0;
      mprv_q    <= 1'b0;
      sum_q     <= 1'b0;
      mxr_q     <= 1'b0;
      tvm_q     <= 1'b0;
      tw_q      <= 1'b0;
      tsr_q     <= 1'b0;
      misa_m_q  <= 1'b1;
      misa_b_q  <= EXT_B;
      misa_c_q  <= EXT_C;
      misa_a_q  <= EXT_A;
      mtvec_q   <= '0;
      mscratch_q <= '0;
      mepc_q    <= '0;
      mcause_q  <= '0;
      mtval_q   <= '0;
      stvec_q   <= '0;
      sscratch_q <= '0;
      sepc_q    <= '0;
      scause_q  <= '0;
      stval_q   <= '0;
      stimecmp_q <= '0;
      mcycle_q  <= '0;
      minstret_q <= '0;
      mie_q     <= '0;
      ssip_q    <= 1'b0;
      stip_sw_q <= 1'b0;
      seip_sw_q <= 1'b0;
      medeleg_q <= '0;
      mideleg_q <= '0;
      mcounteren_q <= '0;
      scounteren_q <= '0;
      mcountinhibit_q <= '0;
      menv_fiom_q <= 1'b0;
      menv_stce_q <= 1'b0;
      senv_fiom_q <= 1'b0;
      satp_mode_q <= 1'b0;
      satp_asid_q <= '0;
      satp_ppn_q  <= '0;
      mcontext_q <= '0;
      scontext_q <= '0;
      pmpcfg_q  <= '0;
      // Spike's reset: entry 0 allows everything (NAPOT, RWX)
      pmpcfg_q[0]  <= 8'h1f;
      psw_q     <= '0;
      pdirty_q  <= '1;
      pchg_q    <= 1'b0;
      pw_v_q    <= 1'b0;
    end else begin
      // PMP: reset sweep, then descriptor recomputation of the marked entries
      if (psweep) psw_q <= psw_q + 1'b1;
      pchg_q <= pcalc;
      if (pcalc) pdirty_q[pj] <= 1'b0;
      // Counters
      if (!mcountinhibit_q[0]) mcycle_q <= mcycle_q + 64'd1;
      if (!mcountinhibit_q[2]) minstret_q <= minstret_q + 64'(cm_n);

      // Execute: hold the write until commit
      if (flush) pw_v_q <= 1'b0;
      else if (ex_valid) begin
        pw_v_q <= !ex_ill && ex_pl.csr_wr;
        pw_a_q <= a;
        pw_d_q <= wval;
      end

      // Commit of the CSR instruction
      if (cm_csr && pw_v_q) begin
        pw_v_q <= 1'b0;
        unique casez (pw_a_q)
          12'h300: begin
            mie_bit_q <= pw_d_q[3];
            mpie_q    <= pw_d_q[7];
            mpp_q     <= legal_pp(pw_d_q[12:11]);
            if (SU) begin
              sie_bit_q <= pw_d_q[1];
              spie_q    <= pw_d_q[5];
              spp_q     <= pw_d_q[8];
              fs_q      <= pw_d_q[14:13];
              mprv_q    <= pw_d_q[17];
              sum_q     <= pw_d_q[18];
              mxr_q     <= pw_d_q[19];
              tvm_q     <= pw_d_q[20];
              tw_q      <= pw_d_q[21];
              tsr_q     <= pw_d_q[22];
            end
          end
          12'h100: begin
            sie_bit_q <= pw_d_q[1];
            spie_q    <= pw_d_q[5];
            spp_q     <= pw_d_q[8];
            fs_q      <= pw_d_q[14:13];
            sum_q     <= pw_d_q[18];
            mxr_q     <= pw_d_q[19];
          end
          12'h301: begin
            // Spike: clearing C is ignored when the CSR instruction's PC is not 4-byte aligned
            misa_m_q <= pw_d_q[12];
            misa_b_q <= EXT_B && pw_d_q[1];
            misa_a_q <= EXT_A && pw_d_q[0];
            if (!(misa_c_q && !pw_d_q[2] && cm_pc[1])) misa_c_q <= EXT_C && pw_d_q[2];
          end
          12'h302: medeleg_q <= pw_d_q[19:0] & {4'b1000, 4'b1011, 2'b00, 6'b11_1111, 3'b111, !misa_c_q};
          12'h303: mideleg_q <= pw_d_q[11:0] & 12'h222;
          12'h304: mie_q <= pw_d_q[11:0] & (SU ? 12'haaa : 12'h888);
          12'h104: mie_q <= (mie_q & ~mideleg_q) | (pw_d_q[11:0] & mideleg_q & 12'h222);
          12'h344: begin
            if (SU) begin
              ssip_q <= pw_d_q[1];
              if (!menv_stce_q) stip_sw_q <= pw_d_q[5];
              seip_sw_q <= pw_d_q[9];
            end
          end
          12'h144: if (mideleg_q[1]) ssip_q <= pw_d_q[1];
          12'h305: mtvec_q <= pw_d_q & ~64'd2;
          12'h105: stvec_q <= pw_d_q & ~64'd2;
          12'h306: mcounteren_q <= pw_d_q[31:0];
          12'h106: scounteren_q <= pw_d_q[31:0];
          12'h320: mcountinhibit_q <= pw_d_q[31:0] & (SU ? 32'hffff_fffd : 32'h0000_0005);
          12'h30A: begin menv_fiom_q <= pw_d_q[0]; menv_stce_q <= pw_d_q[63]; end
          12'h10A: senv_fiom_q <= pw_d_q[0];
          12'h340: mscratch_q <= pw_d_q;
          12'h140: sscratch_q <= pw_d_q;
          12'h341: mepc_q <= pw_d_q & ~64'd1;
          12'h141: sepc_q <= pw_d_q & ~64'd1;
          12'h342: mcause_q <= pw_d_q;
          12'h142: scause_q <= pw_d_q;
          12'h343: mtval_q <= pw_d_q;
          12'h143: stval_q <= pw_d_q;
          12'h14D: stimecmp_q <= pw_d_q;
          12'h180: begin
            // A write with an unsupported MODE has no effect at all (privileged spec, Spike);
            // Bare and Sv39 write MODE, ASID and PPN
            if (pw_d_q[63:60] == 4'd0 || pw_d_q[63:60] == 4'd8) begin
              satp_mode_q <= pw_d_q[63];
              satp_asid_q <= pw_d_q[59:44];
              satp_ppn_q  <= pw_d_q[43:0];
            end
          end
          12'h7A8: mcontext_q <= pw_d_q[12:0];
          12'h5A8: scontext_q <= pw_d_q[31:0];
          12'hB00: mcycle_q <= pw_d_q;
          12'hB02: minstret_q <= pw_d_q;              // replaces this instruction's increment
          12'h3A0: begin
            for (int i = 0; i < 8; i++) pmpcfg_q[i] <= pmpcfg_w(pmpcfg_q[i], pw_d_q[8*i +: 8]);
            pdirty_q[7:0] <= '1;
          end
          12'h3A2: begin
            for (int i = 0; i < 8; i++) pmpcfg_q[8+i] <= pmpcfg_w(pmpcfg_q[8+i], pw_d_q[8*i +: 8]);
            pdirty_q[15:8] <= '1;
          end
          default: if (pa_we) pdirty_q[pa_wa] <= 1'b1;      // pmpaddr (written in its LUTRAM)
        endcase
      end

      // Trap entry, MRET, SRET
      if (tr_valid) begin
        if (deleg) begin
          sepc_q    <= tr_epc & ~64'd1;
          scause_q  <= {tr_irq, 57'b0, tr_code};
          stval_q   <= tr_irq ? 64'd0 : tr_tval;
          spie_q    <= sie_bit_q;
          sie_bit_q <= 1'b0;
          spp_q     <= priv_q == PRIV_S;
          priv_q    <= PRIV_S;
        end else begin
          mepc_q    <= tr_epc & ~64'd1;
          mcause_q  <= {tr_irq, 57'b0, tr_code};
          mtval_q   <= tr_irq ? 64'd0 : tr_tval;
          mpie_q    <= mie_bit_q;
          mie_bit_q <= 1'b0;
          mpp_q     <= SU ? 2'(priv_q) : 2'd3;
          priv_q    <= PRIV_M;
        end
      end else if (mret) begin
        mie_bit_q <= mpie_q;
        mpie_q    <= 1'b1;
        priv_q    <= priv_e'(mpp_q);
        mpp_q     <= SU ? 2'd0 : 2'd3;
        if (mpp_q != 2'd3) mprv_q <= 1'b0;
      end else if (sret) begin
        sie_bit_q <= spie_q;
        spie_q    <= 1'b1;
        priv_q    <= spp_q ? PRIV_S : PRIV_U;
        spp_q     <= 1'b0;
        mprv_q    <= 1'b0;
      end
    end
  end

  logic unused;
  assign unused = ^{ex_pl, mepc_q[0], sepc_q[0], cm_pc[63:2], cm_pc[0], menv_fiom_q, senv_fiom_q, tvec[1],
                    pcfg[6:5]};
endmodule
