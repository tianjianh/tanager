// CSR file, traps and interrupts for M2 (docs/spec/core-pipeline.md §9): machine mode only,
// RV64IM + Zicsr + Zicntr + Zifencei, 16 PMP entries (registers only; checks in M3), no
// triggers. Field behaviour follows Spike's WARL rules for that configuration, so lockstep
// compares every read. One hart (tid 0) in M2; per-hart arrays arrive with M7.
//
// CSR instructions are serialised: execute (P1, EX) reads and checks here combinationally and
// leaves the write pending; commit applies it. Traps and MRET are applied by commit.
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
  input  logic [idx_w(COMMIT_WIDTH + 1)-1:0] cm_n,   // instructions retiring this cycle
  input  logic                   tr_valid,     // trap entry
  input  logic                   tr_irq,
  input  logic [5:0]             tr_code,      // cause code (interrupt: without bit 63)
  input  logic [63:0]            tr_epc,
  input  logic [63:0]            tr_tval,
  input  logic                   mret,
  // State for commit and decode
  output logic [63:0]            trap_target,  // for tr_* given this cycle
  output logic [63:0]            mepc_o,
  output logic                   irq_take,     // an enabled interrupt is pending
  output logic [5:0]             irq_code,
  output logic                   wfi_wake,     // mip & mie != 0
  output logic                   misa_m,
  output logic                   misa_b,       // Zba/Zbb/Zbs enabled (Spike lets software clear B)
  // Interrupt inputs and time
  input  logic                   irq_mei,
  input  logic                   irq_mti,
  input  logic                   irq_msi,
  input  logic [63:0]            mtime
);
  localparam int NPMP = 16;
  localparam logic [63:0] HARTID = 64'(CORE_ID * NUM_THREADS);

  // ---- State ----
  logic        mie_bit_q, mpie_q, misa_m_q, misa_b_q;
  logic [63:0] mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q, mcycle_q, minstret_q;
  logic [11:0] mie_q;                 // bits 3, 7, 11
  logic [2:0]  mcountinhibit_q;       // bits 0 and 2
  logic [12:0] mcontext_q;
  logic [NPMP-1:0][7:0]  pmpcfg_q;
  logic [NPMP-1:0][53:0] pmpaddr_q;

  logic [11:0] mip;
  assign mip = {irq_mei, 3'b0, irq_mti, 3'b0, irq_msi, 3'b0};
  assign misa_m   = misa_m_q;
  assign misa_b   = misa_b_q;
  assign mepc_o   = {mepc_q[63:2], 2'b00};
  assign wfi_wake = |(mip & mie_q);
  always_comb begin
    logic [11:0] p;
    p = mip & mie_q;
    irq_take = mie_bit_q && |p;
    irq_code = p[11] ? 6'd11 : p[3] ? 6'd3 : 6'd7;
  end
  assign trap_target = {mtvec_q[63:2], 2'b00} + ((tr_irq && mtvec_q[0]) ? {56'b0, tr_code, 2'b00} : 64'd0);

  // ---- Read and legality ----
  logic [11:0] a;
  assign a = ex_pl.csr_addr;
  logic        exists;
  logic [63:0] rval;
  always_comb begin
    exists = 1'b1;
    rval = '0;
    unique casez (a)
      12'h300: rval = {51'b0, 2'b11, 3'b0, mpie_q, 3'b0, mie_bit_q, 3'b0};
      12'h301: rval = {2'b10, 49'b0, misa_m_q, 3'b0, 1'b1, 6'b0, misa_b_q, 1'b0};
      12'h304: rval = {52'b0, mie_q};
      12'h305: rval = mtvec_q;
      12'h320: rval = {61'b0, mcountinhibit_q};
      12'h340: rval = mscratch_q;
      12'h341: rval = {mepc_q[63:2], 2'b00};
      12'h342: rval = mcause_q;
      12'h343: rval = mtval_q;
      12'h344: rval = {52'b0, mip};
      12'h7A0, 12'h7A1, 12'h7A2, 12'h7A3, 12'h7A4: rval = '0;
      12'h7A8: rval = {51'b0, mcontext_q};
      12'hB00, 12'hC00: rval = mcycle_q;
      12'hB02, 12'hC02: rval = minstret_q;
      12'hC01: rval = mtime;
      12'hF11, 12'hF12, 12'hF13, 12'hF15: rval = '0;
      12'hF14: rval = HARTID;
      default: begin
        if (a >= 12'h3A0 && a <= 12'h3AF) begin                      // pmpcfg (even only)
          if (a[0]) exists = 1'b0;
          else if (a == 12'h3A0) rval = pmpcfg_q[7:0];
          else if (a == 12'h3A2) rval = pmpcfg_q[15:8];
          else rval = '0;
        end else if (a >= 12'h3B0 && a <= 12'h3EF) begin             // pmpaddr0-63
          rval = (a - 12'h3B0 < 12'(NPMP)) ? {10'b0, pmpaddr_q[a[3:0]]} : '0;
        end else if ((a >= 12'hB03 && a <= 12'hB1F) || (a >= 12'h323 && a <= 12'h33F)) begin
          rval = '0;                                                 // mhpmcounter*, mhpmevent*
        end else begin
          exists = 1'b0;
        end
      end
    endcase
  end

  // Write value and legality
  logic [63:0] wsrc, wval;
  always_comb begin
    wsrc = ex_pl.csr_imm ? {59'b0, ex_pl.csr_zimm} : ex_src;
    unique case (ex_pl.csr_op)
      CSR_RW:  wval = wsrc;
      CSR_RS:  wval = rval | wsrc;
      default: wval = rval & ~wsrc;
    endcase
  end
  assign ex_ill   = !exists || (ex_pl.csr_wr && a[11:10] == 2'b11);
  assign ex_rdata = rval;

  // Pending write, applied at commit
  logic        pw_v_q;
  logic [11:0] pw_a_q;
  logic [63:0] pw_d_q;

  // pmpcfg byte write (Spike's rules: locked entries keep their value; W needs R)
  function automatic logic [7:0] pmpcfg_w(input logic [7:0] old, input logic [7:0] nv);
    logic [7:0] c;
    if (old[7]) return old;
    c = nv & 8'b1001_1111;
    if (!c[0]) c[1] = 1'b0;
    return c;
  endfunction

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    if (rst) begin
      mie_bit_q <= 1'b0;
      mpie_q    <= 1'b0;
      misa_m_q  <= 1'b1;
      misa_b_q  <= EXT_B;
      mtvec_q   <= '0;
      mscratch_q <= '0;
      mepc_q    <= '0;
      mcause_q  <= '0;
      mtval_q   <= '0;
      mcycle_q  <= '0;
      minstret_q <= '0;
      mie_q     <= '0;
      mcountinhibit_q <= '0;
      mcontext_q <= '0;
      pmpcfg_q  <= '0;
      pmpaddr_q <= '0;
      // Spike's reset: entry 0 allows everything (NAPOT, RWX)
      pmpcfg_q[0]  <= 8'h1f;
      pmpaddr_q[0] <= '1;
      pw_v_q    <= 1'b0;
    end else begin
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
          12'h300: begin mie_bit_q <= pw_d_q[3]; mpie_q <= pw_d_q[7]; end
          12'h301: begin misa_m_q <= pw_d_q[12]; misa_b_q <= EXT_B && pw_d_q[1]; end
          12'h304: mie_q <= pw_d_q[11:0] & 12'h888;
          12'h305: mtvec_q <= pw_d_q & ~64'd2;
          12'h320: mcountinhibit_q <= pw_d_q[2:0] & 3'b101;
          12'h340: mscratch_q <= pw_d_q;
          12'h341: mepc_q <= pw_d_q & ~64'd1;
          12'h342: mcause_q <= pw_d_q;
          12'h343: mtval_q <= pw_d_q;
          12'h7A8: mcontext_q <= pw_d_q[12:0];
          12'hB00: mcycle_q <= pw_d_q;
          12'hB02: minstret_q <= pw_d_q;              // replaces this instruction's increment
          12'h3A0: for (int i = 0; i < 8; i++) pmpcfg_q[i] <= pmpcfg_w(pmpcfg_q[i], pw_d_q[8*i +: 8]);
          12'h3A2: for (int i = 0; i < 8; i++) pmpcfg_q[8+i] <= pmpcfg_w(pmpcfg_q[8+i], pw_d_q[8*i +: 8]);
          default: begin
            if (pw_a_q >= 12'h3B0 && pw_a_q <= 12'h3BF) begin
              int i;
              logic lk;
              i = int'(pw_a_q[3:0]);
              lk = pmpcfg_q[i][7] ||
                   (i + 1 < NPMP && pmpcfg_q[(i + 1) % NPMP][7] && pmpcfg_q[(i + 1) % NPMP][4:3] == 2'b01);
              if (!lk) pmpaddr_q[i] <= pw_d_q[53:0];
            end
          end
        endcase
      end

      // Trap entry and MRET
      if (tr_valid) begin
        mepc_q    <= tr_epc & ~64'd1;
        mcause_q  <= {tr_irq, 57'b0, tr_code};
        mtval_q   <= tr_irq ? 64'd0 : tr_tval;
        mpie_q    <= mie_bit_q;
        mie_bit_q <= 1'b0;
      end else if (mret) begin
        mie_bit_q <= mpie_q;
        mpie_q    <= 1'b1;
      end
    end
  end

  logic unused;
  assign unused = ^{ex_pl, mepc_q[1:0]};
endmodule
