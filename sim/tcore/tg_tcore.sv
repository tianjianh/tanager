// tg_tcore: a tiny in-order RV64IM test core with the tg_core ports (docs/spec/verification.md §5).
// Simulation only, never in a product filelist. It exists to exercise the harness, the TileLink
// models and the lockstep checker end to end before tg_core does.
//   ISA: RV64IM, Zicsr, Zicntr, Zifencei; M and U modes; no PMP (Spike: --pmp=0, where the PMP
//   CSRs do not exist).
//   Memory: one-line fetch buffer over l1i; an 8-line direct-mapped write-back data cache that is a
//   real TL-C client on l1d (Acquire/Grant/GrantAck, Release/ReleaseData, ProbeAck/ProbeAckData);
//   device and ROM data accesses on mmio.
//   Trace: records go through a small queue that can release several per cycle on any slot
//   (+tcore_spread=1), and loads and DIV/REM can report their value later through trace_wb
//   (+tcore_defer=<percent>), as an early-retiring core would. +tcore_seed=<n> seeds both.
//   trace_stall_i (interfaces.md §5) holds the queue, so commit stops once it is full; deferred
//   writebacks keep flowing. +tcore_stall_lat=<0|1|2>: cycles of extra
//   reaction latency (default 1, the interface's allowance; 2 breaks it), +tcore_stall_bug=1 drops
//   a record when the stall starts. Both exist to test the harness's checks.
module tg_tcore
  import tg_pkg::*, tg_tl_pkg::*, tg_trace_pkg::*, tg_map_pkg::*;
#(
  parameter int unsigned CORE_ID = 0
) (
  input  logic                         clk,
  input  logic                         rst,
  input  paddr_t                       boot_addr_i,
  input  logic [NUM_THREADS-1:0]       irq_mei_i,
  input  logic [NUM_THREADS-1:0]       irq_sei_i,
  input  logic [NUM_THREADS-1:0]       irq_mti_i,
  input  logic [NUM_THREADS-1:0]       irq_msi_i,
  input  logic [NUM_THREADS-1:0]       irq_ssi_i,
  input  logic [63:0]                  mtime_i,
  input  logic [NUM_THREADS-1:0]       debug_req_i,
  output logic [NUM_THREADS-1:0]       merr_o,
  output tl_a_t                        l1i_a_o,
  output logic                         l1i_a_valid_o,
  input  logic                         l1i_a_ready_i,
  input  tl_d_t                        l1i_d_i,
  input  logic                         l1i_d_valid_i,
  output logic                         l1i_d_ready_o,
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
  output tl_a_t                        mmio_a_o,
  output logic                         mmio_a_valid_o,
  input  logic                         mmio_a_ready_i,
  input  tl_d_t                        mmio_d_i,
  input  logic                         mmio_d_valid_i,
  output logic                         mmio_d_ready_o,
  input  logic                         trace_stall_i,
  output tr_rec_t [COMMIT_WIDTH-1:0]   trace_o,
  output logic    [COMMIT_WIDTH-1:0]   trace_valid_o,
  output tr_wb_t  [TRACE_WB_PORTS-1:0] trace_wb_o,
  output logic    [TRACE_WB_PORTS-1:0] trace_wb_valid_o,
  // tg_core's board-debug port (DBG_WORD); the test core has no debug word
  input  logic [4:0]                   dbg_sel_i,
  output logic [31:0]                  dbg_o
);

  localparam hart_t HART   = hart_t'(CORE_ID * NUM_THREADS);
  assign dbg_o = '0;
  localparam int    NLINES = 8;
  localparam int    IDX_W  = 3;
  localparam int    LTAG_W = PA_W - 6;           // line number
  localparam int    TQ_N   = 8;                  // trace queue
  localparam int    WQ_N   = 16;                 // pending deferred writebacks
  localparam int    NTAGS  = 1 << WB_TAG_W;
  localparam logic [1:0] PRV_U2 = 2'd0, PRV_M2 = 2'd3;

  // ---- Run-time knobs (simulation only) ----
  int unsigned defer_pct, spread, seed, stall_lat, stall_bug;
  initial begin
    if (!$value$plusargs("tcore_defer=%d", defer_pct)) defer_pct = 0;
    if (!$value$plusargs("tcore_spread=%d", spread)) spread = 0;
    if (!$value$plusargs("tcore_seed=%d", seed)) seed = 1;
    if (!$value$plusargs("tcore_stall_lat=%d", stall_lat)) stall_lat = 1;
    if (!$value$plusargs("tcore_stall_bug=%d", stall_bug)) stall_bug = 0;
  end

  // ---- Architectural state ----
  typedef enum logic [4:0] {
    S_BOUND, S_FETCH, S_IGET, S_IWAIT, S_EXEC, S_MEM, S_EVICT, S_EVICT_WAIT, S_ACQ, S_GRANT,
    S_INSTALL, S_GACK, S_RETRY, S_MMIO_REQ, S_MMIO_WAIT, S_COMMIT, S_TRAP, S_WFI
  } state_e;
  state_e      st_q;
  logic [63:0] pc_q;
  logic [63:0] xr_q [32];
  logic [1:0]  prv_q;
  logic        mie_bit_q, mpie_q, mprv_q, tw_q;
  logic        misa_m_q;     // misa.M: software may clear it (Spike's write mask); MUL/DIV are then illegal
  logic [1:0]  mpp_q;
  logic [63:0] mtvec_q, mepc_q, mcause_q, mtval_q, mscratch_q, mcycle_q, minstret_q;
  logic [11:0] mie_q;
  logic [2:0]  mcounteren_q, mcountinhibit_q;
  logic [12:0] mcontext_q;

  // Fetch buffer and data cache
  logic              fb_valid_q;
  logic [LTAG_W-1:0] fb_line_q;
  logic [511:0]      fb_data_q;
  logic              dc_valid_q [NLINES];
  logic              dc_t_q     [NLINES];   // T (else B)
  logic              dc_dirty_q [NLINES];
  logic [LTAG_W-1:0] dc_line_q  [NLINES];
  logic [511:0]      dc_data_q  [NLINES];

  // The instruction in flight
  logic [31:0] insn_q;
  logic        rd_we_q, csr_we_q, mret_q, wfi_q, fencei_q, nondet_q, mmio_ld_q, mem_st_q, defer_ok_q;
  logic [4:0]  rd_q;
  logic [63:0] rd_val_q, npc_q, csr_wval_q, cause_q, tval_q;
  logic [11:0] csr_addr_q;
  logic        ld_q, st_q2, mun_q;
  logic [1:0]  msz_q;
  logic [63:0] maddr_q, mwdata_q;
  logic [2:0]  acq_param_q;
  logic [1:0]  gbeat_q;
  logic [511:0] gbuf_q;
  logic [2:0]  gcap_q;
  logic [TL_SINK_W-1:0] gsink_q;
  logic        gden_q, gdone_q;
  logic [1:0]  ibeat_q, cbeat_q;
  logic        iden_q;

  // Probe handling
  typedef enum logic {P_IDLE, P_ACK} pstate_e;
  pstate_e           ps_q;
  logic [TL_SRC_W-1:0] p_src_q;
  logic [LTAG_W-1:0] p_line_q;
  logic [IDX_W-1:0]  p_idx_q;
  logic              p_data_q, p_hit_q;
  logic [2:0]        p_param_q;
  logic [1:0]        p_beat_q;
  logic              p_nvalid_q, p_nt_q;

  // ---- Helpers ----
  function automatic logic [63:0] ld_ext(input logic [63:0] raw, input logic [1:0] sz, input logic uns);
    unique case (sz)
      2'd0: return uns ? {56'b0, raw[7:0]}  : {{56{raw[7]}}, raw[7:0]};
      2'd1: return uns ? {48'b0, raw[15:0]} : {{48{raw[15]}}, raw[15:0]};
      2'd2: return uns ? {32'b0, raw[31:0]} : {{32{raw[31]}}, raw[31:0]};
      default: return raw;
    endcase
  endfunction

  function automatic logic [63:0] sext32(input logic [31:0] v);
    return {{32{v[31]}}, v};
  endfunction

  function automatic logic [63:0] smask(input logic [1:0] sz);
    unique case (sz)
      2'd0: return 64'hff;
      2'd1: return 64'hffff;
      2'd2: return 64'hffff_ffff;
      default: return '1;
    endcase
  endfunction

  // Interrupts: MEI 11, MSI 3, MTI 7 (no S-mode)
  logic [11:0] mip;
  assign mip = {irq_mei_i[0], 3'b0, irq_mti_i[0], 3'b0, irq_msi_i[0], 3'b0};
  logic [11:0] irq_pend;
  logic        irq_take;
  logic [3:0]  irq_code;
  assign irq_pend = mip & mie_q;
  assign irq_take = |irq_pend && (prv_q != PRV_M2 || mie_bit_q);
  assign irq_code = irq_pend[11] ? 4'd11 : irq_pend[3] ? 4'd3 : 4'd7;

  logic [63:0] mstatus_rd;
  assign mstatus_rd = {30'b0, 2'b10, 10'b0, tw_q, 3'b0, mprv_q, 4'b0, mpp_q, 3'b0, mpie_q, 3'b0, mie_bit_q, 3'b0};

  // CSR read with existence and privilege (verification.md §5; Spike's CSR set for M+U, RV64IM)
  logic        csr_ok;
  logic [63:0] csr_val;
  logic        csr_nd;
  always_comb begin
    logic [11:0] a;
    a = insn_ex[31:20];
    csr_ok = 1'b1;
    csr_val = '0;
    csr_nd = 1'b0;
    unique casez (a)
      12'hF11, 12'hF13, 12'hF15: csr_val = '0;
      12'hF12: begin csr_val = '0; csr_nd = 1'b1; end            // marchid: adopted by the checker
      12'hF14: csr_val = 64'(HART);
      12'h300: csr_val = mstatus_rd;
      12'h301: csr_val = 64'h8000_0000_0010_0100 | {51'b0, misa_m_q, 12'b0};  // RV64 I (M) U
      12'h304: csr_val = {52'b0, mie_q};
      12'h305: csr_val = mtvec_q;
      12'h306: csr_val = {61'b0, mcounteren_q};
      12'h30A: csr_val = '0;                                       // menvcfg: no writable bits here
      12'h320: csr_val = {61'b0, mcountinhibit_q};
      12'h340: csr_val = mscratch_q;
      12'h341: csr_val = mepc_q;
      12'h342: csr_val = mcause_q;
      12'h343: csr_val = mtval_q;
      12'h344: begin csr_val = {52'b0, mip}; csr_nd = 1'b1; end
      12'h7A0, 12'h7A1, 12'h7A2, 12'h7A3, 12'h7A4: csr_val = '0;   // no triggers
      12'h7A8: csr_val = {51'b0, mcontext_q};
      12'hB00: begin csr_val = mcycle_q; csr_nd = 1'b1; end
      12'hB02: csr_val = minstret_q;
      12'hC00: begin csr_val = mcycle_q; csr_nd = 1'b1; csr_ok = prv_q == PRV_M2 || mcounteren_q[0]; end
      12'hC01: begin csr_val = mtime_i;  csr_nd = 1'b1; csr_ok = prv_q == PRV_M2 || mcounteren_q[1]; end
      12'hC02: begin csr_val = minstret_q; csr_ok = prv_q == PRV_M2 || mcounteren_q[2]; end
      default: begin
        // mhpmcounter3-31 read zero; mhpmevent3-31 read zero
        if ((a >= 12'hB03 && a <= 12'hB1F) || (a >= 12'h323 && a <= 12'h33F)) begin
          csr_val = '0;
          csr_nd = a[11:8] == 4'hB;
        end else begin
          csr_ok = 1'b0;
        end
      end
    endcase
    if (prv_q < a[9:8]) csr_ok = 1'b0;
  end

  // ---- Decode and execute (S_EXEC) ----
  logic [31:0] insn_ex;
  assign insn_ex = fb_data_q[pc_q[5:2]*32 +: 32];

  logic        ex_trap, ex_rd_we, ex_mem, ex_store, ex_csr_we, ex_mret, ex_wfi, ex_fencei, ex_nondet, ex_defer_ok;
  logic [63:0] ex_cause, ex_tval, ex_val, ex_npc, ex_maddr, ex_csr_wval;
  always_comb begin
    logic [6:0]  op;
    logic [2:0]  f3;
    logic [6:0]  f7;
    logic [63:0] a, b, imm_i, imm_s, imm_b, imm_u, imm_j, tgt, src;
    logic [127:0] prod;
    logic        take, csr_w;
    op = insn_ex[6:0];
    f3 = insn_ex[14:12];
    f7 = insn_ex[31:25];
    a  = xr_q[insn_ex[19:15]];
    b  = xr_q[insn_ex[24:20]];
    imm_i = {{52{insn_ex[31]}}, insn_ex[31:20]};
    imm_s = {{52{insn_ex[31]}}, insn_ex[31:25], insn_ex[11:7]};
    imm_b = {{51{insn_ex[31]}}, insn_ex[31], insn_ex[7], insn_ex[30:25], insn_ex[11:8], 1'b0};
    imm_u = {{32{insn_ex[31]}}, insn_ex[31:12], 12'b0};
    imm_j = {{43{insn_ex[31]}}, insn_ex[31], insn_ex[19:12], insn_ex[20], insn_ex[30:21], 1'b0};
    tgt = '0;
    src = '0;
    prod = '0;
    take = 1'b0;
    csr_w = 1'b0;
    ex_trap = 1'b0;
    ex_cause = 64'd2;                    // illegal instruction unless set otherwise
    ex_tval = {32'b0, insn_ex};
    ex_rd_we = 1'b0;
    ex_val = '0;
    ex_npc = pc_q + 64'd4;
    ex_mem = 1'b0;
    ex_store = 1'b0;
    ex_maddr = a + imm_i;
    ex_csr_we = 1'b0;
    ex_csr_wval = '0;
    ex_mret = 1'b0;
    ex_wfi = 1'b0;
    ex_fencei = 1'b0;
    ex_nondet = 1'b0;
    ex_defer_ok = 1'b0;
    if (insn_ex[1:0] != 2'b11) begin
      ex_trap = 1'b1;                    // compressed encodings: no C extension
      ex_tval = {48'b0, insn_ex[15:0]};
    end else begin
      unique case (op)
        7'h37: begin ex_rd_we = 1'b1; ex_val = imm_u; end
        7'h17: begin ex_rd_we = 1'b1; ex_val = pc_q + imm_u; end
        7'h6F: begin
          tgt = pc_q + imm_j;
          if (tgt[1]) begin ex_trap = 1'b1; ex_cause = 64'd0; ex_tval = tgt; end
          else begin ex_rd_we = 1'b1; ex_val = pc_q + 64'd4; ex_npc = tgt; end
        end
        7'h67: begin
          tgt = (a + imm_i) & ~64'd1;
          if (f3 != 3'd0) ex_trap = 1'b1;
          else if (tgt[1]) begin ex_trap = 1'b1; ex_cause = 64'd0; ex_tval = tgt; end
          else begin ex_rd_we = 1'b1; ex_val = pc_q + 64'd4; ex_npc = tgt; end
        end
        7'h63: begin
          unique case (f3)
            3'd0: take = a == b;
            3'd1: take = a != b;
            3'd4: take = $signed(a) < $signed(b);
            3'd5: take = $signed(a) >= $signed(b);
            3'd6: take = a < b;
            3'd7: take = a >= b;
            default: ex_trap = 1'b1;
          endcase
          tgt = pc_q + imm_b;
          if (!ex_trap && take) begin
            if (tgt[1]) begin ex_trap = 1'b1; ex_cause = 64'd0; ex_tval = tgt; end
            else ex_npc = tgt;
          end
        end
        7'h03: begin
          if (f3 == 3'd7) ex_trap = 1'b1;
          else begin ex_mem = 1'b1; ex_rd_we = 1'b1; ex_defer_ok = 1'b1; end
        end
        7'h23: begin
          if (f3[2]) ex_trap = 1'b1;
          else begin ex_mem = 1'b1; ex_store = 1'b1; ex_maddr = a + imm_s; end
        end
        7'h13: begin
          ex_rd_we = 1'b1;
          unique case (f3)
            3'd0: ex_val = a + imm_i;
            3'd2: ex_val = {63'b0, $signed(a) < $signed(imm_i)};
            3'd3: ex_val = {63'b0, a < imm_i};
            3'd4: ex_val = a ^ imm_i;
            3'd6: ex_val = a | imm_i;
            3'd7: ex_val = a & imm_i;
            3'd1: if (insn_ex[31:26] == 6'd0) ex_val = a << insn_ex[25:20]; else ex_trap = 1'b1;
            default: begin
              if (insn_ex[31:26] == 6'd0) ex_val = a >> insn_ex[25:20];
              else if (insn_ex[31:26] == 6'h10) ex_val = 64'($signed(a) >>> insn_ex[25:20]);
              else ex_trap = 1'b1;
            end
          endcase
        end
        7'h1B: begin
          ex_rd_we = 1'b1;
          unique case (f3)
            3'd0: ex_val = sext32(a[31:0] + imm_i[31:0]);
            3'd1: if (f7 == 7'd0) ex_val = sext32(a[31:0] << insn_ex[24:20]); else ex_trap = 1'b1;
            3'd5: begin
              if (f7 == 7'd0) ex_val = sext32(a[31:0] >> insn_ex[24:20]);
              else if (f7 == 7'h20) ex_val = sext32(32'($signed(a[31:0]) >>> insn_ex[24:20]));
              else ex_trap = 1'b1;
            end
            default: ex_trap = 1'b1;
          endcase
        end
        7'h33: begin
          ex_rd_we = 1'b1;
          if (f7 == 7'h00) begin
            unique case (f3)
              3'd0: ex_val = a + b;
              3'd1: ex_val = a << b[5:0];
              3'd2: ex_val = {63'b0, $signed(a) < $signed(b)};
              3'd3: ex_val = {63'b0, a < b};
              3'd4: ex_val = a ^ b;
              3'd5: ex_val = a >> b[5:0];
              3'd6: ex_val = a | b;
              default: ex_val = a & b;
            endcase
          end else if (f7 == 7'h20 && f3 == 3'd0) begin
            ex_val = a - b;
          end else if (f7 == 7'h20 && f3 == 3'd5) begin
            ex_val = 64'($signed(a) >>> b[5:0]);
          end else if (f7 == 7'h01) begin
            unique case (f3)
              3'd0: ex_val = a * b;
              3'd1: begin prod = 128'($signed({{64{a[63]}}, a}) * $signed({{64{b[63]}}, b})); ex_val = prod[127:64]; end
              3'd2: begin prod = 128'($signed({{64{a[63]}}, a}) * $signed({64'b0, b})); ex_val = prod[127:64]; end
              3'd3: begin prod = {64'b0, a} * {64'b0, b}; ex_val = prod[127:64]; end
              3'd4: begin
                ex_defer_ok = 1'b1;
                if (b == 0) ex_val = '1;
                else if (a == 64'h8000_0000_0000_0000 && b == '1) ex_val = a;
                else ex_val = 64'($signed(a) / $signed(b));
              end
              3'd5: begin ex_defer_ok = 1'b1; ex_val = (b == 0) ? '1 : a / b; end
              3'd6: begin
                ex_defer_ok = 1'b1;
                if (b == 0) ex_val = a;
                else if (a == 64'h8000_0000_0000_0000 && b == '1) ex_val = '0;
                else ex_val = 64'($signed(a) % $signed(b));
              end
              default: begin ex_defer_ok = 1'b1; ex_val = (b == 0) ? a : a % b; end
            endcase
          end else begin
            ex_trap = 1'b1;
          end
        end
        7'h3B: begin
          ex_rd_we = 1'b1;
          if (f7 == 7'h00 && f3 == 3'd0) ex_val = sext32(a[31:0] + b[31:0]);
          else if (f7 == 7'h20 && f3 == 3'd0) ex_val = sext32(a[31:0] - b[31:0]);
          else if (f7 == 7'h00 && f3 == 3'd1) ex_val = sext32(a[31:0] << b[4:0]);
          else if (f7 == 7'h00 && f3 == 3'd5) ex_val = sext32(a[31:0] >> b[4:0]);
          else if (f7 == 7'h20 && f3 == 3'd5) ex_val = sext32(32'($signed(a[31:0]) >>> b[4:0]));
          else if (f7 == 7'h01 && f3 == 3'd0) ex_val = sext32(a[31:0] * b[31:0]);
          else if (f7 == 7'h01 && f3 == 3'd4) begin
            ex_defer_ok = 1'b1;
            if (b[31:0] == 0) ex_val = '1;
            else if (a[31:0] == 32'h8000_0000 && b[31:0] == '1) ex_val = sext32(a[31:0]);
            else ex_val = sext32(32'($signed(a[31:0]) / $signed(b[31:0])));
          end else if (f7 == 7'h01 && f3 == 3'd5) begin
            ex_defer_ok = 1'b1;
            ex_val = (b[31:0] == 0) ? '1 : sext32(a[31:0] / b[31:0]);
          end else if (f7 == 7'h01 && f3 == 3'd6) begin
            ex_defer_ok = 1'b1;
            if (b[31:0] == 0) ex_val = sext32(a[31:0]);
            else if (a[31:0] == 32'h8000_0000 && b[31:0] == '1) ex_val = '0;
            else ex_val = sext32(32'($signed(a[31:0]) % $signed(b[31:0])));
          end else if (f7 == 7'h01 && f3 == 3'd7) begin
            ex_defer_ok = 1'b1;
            ex_val = (b[31:0] == 0) ? sext32(a[31:0]) : sext32(a[31:0] % b[31:0]);
          end else ex_trap = 1'b1;
        end
        7'h0F: begin
          if (f3 == 3'd1) ex_fencei = 1'b1;
          else if (f3 != 3'd0) ex_trap = 1'b1;
        end
        7'h73: begin
          if (f3 == 3'd0) begin
            if (insn_ex == 32'h0000_0073) begin
              ex_trap = 1'b1; ex_cause = (prv_q == PRV_M2) ? 64'd11 : 64'd8; ex_tval = '0;
            end else if (insn_ex == 32'h0010_0073) begin
              ex_trap = 1'b1; ex_cause = 64'd3; ex_tval = pc_q;
            end else if (insn_ex == 32'h3020_0073 && prv_q == PRV_M2) begin
              ex_mret = 1'b1; ex_npc = mepc_q;
            end else if (insn_ex == 32'h1050_0073 && !(prv_q == PRV_U2 && tw_q)) begin
              ex_wfi = 1'b1;
            end else begin
              ex_trap = 1'b1;
            end
          end else if (f3 == 3'd4) begin
            ex_trap = 1'b1;
          end else begin
            src = f3[2] ? {59'b0, insn_ex[19:15]} : a;
            csr_w = (f3[1:0] == 2'b01) || (insn_ex[19:15] != 5'd0);
            if (!csr_ok || (csr_w && insn_ex[31:30] == 2'b11)) begin
              ex_trap = 1'b1;
            end else begin
              ex_rd_we = 1'b1;
              ex_val = csr_val;
              ex_nondet = csr_nd;
              ex_csr_we = csr_w;
              unique case (f3[1:0])
                2'b01: ex_csr_wval = src;
                2'b10: ex_csr_wval = csr_val | src;
                default: ex_csr_wval = csr_val & ~src;
              endcase
            end
          end
        end
        default: ex_trap = 1'b1;
      endcase
      if ((op == 7'h33 || op == 7'h3B) && f7 == 7'h01 && !misa_m_q) ex_trap = 1'b1;  // M cleared in misa
    end
    if (insn_ex[11:7] == 5'd0) ex_rd_we = 1'b0;
  end

  // ---- Memory access helpers ----
  pma_e        m_pma;
  logic [IDX_W-1:0] m_idx;
  logic [LTAG_W-1:0] m_line;
  logic        m_hit, m_misal;
  assign m_pma   = pma_of(paddr_t'(maddr_q));
  assign m_idx   = maddr_q[6 +: IDX_W];
  assign m_line  = maddr_q[PA_W-1:6];
  assign m_hit   = dc_valid_q[m_idx] && dc_line_q[m_idx] == m_line && maddr_q[63:PA_W] == '0;
  assign m_misal = (maddr_q & ((64'd1 << msz_q) - 64'd1)) != 0;
  logic [63:0] m_raw;
  assign m_raw = dc_data_q[m_idx][maddr_q[5:0]*8 +: 64];

  // ---- Probe acceptance: never while the main FSM touches the cache or the C channel ----
  logic p_busy_main, b_fire, p_quiet;
  assign p_busy_main = st_q == S_MEM || st_q == S_INSTALL || st_q == S_EVICT;
  assign l1d_b_ready_o = ps_q == P_IDLE && !p_busy_main;
  assign b_fire  = l1d_b_valid_i && l1d_b_ready_o;
  assign p_quiet = ps_q == P_IDLE && !b_fire;   // main FSM may enter a cache-touching state

  // ---- Trace queue and deferred writebacks ----
  tr_rec_t   tq_q [TQ_N];
  logic [3:0] tq_cnt_q;
  logic [31:0] lfsr_q;
  logic [NTAGS-1:0] tag_busy_q;
  tr_wb_t    wq_q   [WQ_N];
  logic [63:0] wq_due_q [WQ_N];
  logic      wq_v_q [WQ_N];
  logic [63:0] cyc_q;

  // trace_stall_i, registered (stall_sh_q[0]) and delayed by +tcore_stall_lat more cycles.
  logic [2:0] stall_sh_q;
  logic       stall_eff, stall_eff_q, tq_drop;
  assign stall_eff = stall_sh_q[(stall_lat > 2) ? 2 : stall_lat];
  // +tcore_stall_bug=1: the head record vanishes when a stall starts (a lost record).
  assign tq_drop = stall_bug != 0 && stall_eff && !stall_eff_q && tq_cnt_q != '0;

  // How many records leave the queue this cycle (into slots 0..n-1); none while stalled.
  logic [3:0] tq_pop;
  always_comb begin
    int unsigned want;
    want = (spread != 0) ? int'(lfsr_q[3:0]) % (COMMIT_WIDTH + 1) : COMMIT_WIDTH;
    tq_pop = (int'(tq_cnt_q) < want) ? tq_cnt_q : 4'(want);
    if (stall_eff) tq_pop = '0;
  end
  logic tq_room;
  assign tq_room = (int'(tq_cnt_q) - int'(tq_pop)) < TQ_N;

  always_comb begin
    for (int i = 0; i < COMMIT_WIDTH; i++) begin
      trace_valid_o[i] = i < int'(tq_pop);
      trace_o[i] = (i < TQ_N) ? tq_q[i] : '0;
    end
  end

  // Writebacks due this cycle, at most TRACE_WB_PORTS.
  logic [WQ_N-1:0] wq_emit;
  always_comb begin
    int n;
    n = 0;
    wq_emit = '0;
    for (int i = 0; i < TRACE_WB_PORTS; i++) begin
      trace_wb_valid_o[i] = 1'b0;
      trace_wb_o[i] = '0;
    end
    for (int j = 0; j < WQ_N; j++) begin
      if (wq_v_q[j] && wq_due_q[j] <= cyc_q && n < TRACE_WB_PORTS) begin
        trace_wb_valid_o[n] = 1'b1;
        trace_wb_o[n] = wq_q[j];
        wq_emit[j] = 1'b1;
        n++;
      end
    end
  end

  // A record being created this cycle (S_COMMIT, S_TRAP, an interrupt at S_BOUND).
  logic    rec_push;
  tr_rec_t rec_new;
  logic    rec_defer;
  logic [WB_TAG_W-1:0] rec_tag;
  always_comb begin
    logic found;
    found = 1'b0;
    rec_tag = '0;
    for (int t = 0; t < NTAGS && t < LLT_ENTRIES; t++) begin  // at most LLT_ENTRIES pending
      if (!found && !tag_busy_q[t]) begin
        found = 1'b1;
        rec_tag = WB_TAG_W'(t);
      end
    end
    rec_defer = defer_ok_q && rd_we_q && !mmio_ld_q && found && defer_pct != 0 &&
                (int'(lfsr_q[15:8]) % 100) < int'(defer_pct);
    rec_new = '0;
    rec_new.hart = HART;
    rec_new.priv = priv_e'(prv_q);
    rec_new.pc = pc_q;
    rec_push = 1'b0;
    if (st_q == S_BOUND && irq_take) begin
      rec_push = 1'b1;
      rec_new.kind = TR_IRQ;
      rec_new.cause = {1'b1, 59'b0, irq_code};
    end else if (st_q == S_TRAP) begin
      rec_push = 1'b1;
      rec_new.kind = TR_TRAP;
      rec_new.insn = (cause_q == 64'd1) ? 32'b0 : insn_q;
      rec_new.rvc = insn_q[1:0] != 2'b11 && cause_q != 64'd1;
      if (rec_new.rvc) rec_new.insn = {16'b0, insn_q[15:0]};
      rec_new.cause = cause_q;
      rec_new.tval = tval_q;
    end else if (st_q == S_COMMIT) begin
      rec_push = 1'b1;
      rec_new.kind = TR_RETIRE;
      rec_new.insn = insn_q;
      rec_new.rd_we = rd_we_q;
      rec_new.rd = rd_q;
      rec_new.rd_value = rd_we_q ? rd_val_q : '0;
      rec_new.rd_deferred = rec_defer;
      rec_new.wb_tag = rec_defer ? rec_tag : '0;
      rec_new.mem_st = mem_st_q;
      rec_new.mem_vaddr = mem_st_q ? maddr_q : '0;
      rec_new.mem_wdata = mem_st_q ? (mwdata_q & smask(msz_q)) : '0;
      rec_new.mem_size = mem_st_q ? msz_q : '0;
      rec_new.mmio_ld = mmio_ld_q;
      rec_new.nondet = nondet_q;
    end
  end

  // ---- TileLink outputs ----
  always_comb begin
    l1i_a_o = '0;
    l1i_a_o.opcode = A_GET;
    l1i_a_o.size = 3'd6;
    l1i_a_o.address = {pc_q[PA_W-1:6], 6'b0};
    l1i_a_o.mask = '1;
    l1i_a_valid_o = st_q == S_IGET;
    l1i_d_ready_o = 1'b1;

    l1d_a_o = '0;
    l1d_a_o.opcode = A_ACQUIRE_BLOCK;
    l1d_a_o.param = acq_param_q;
    l1d_a_o.size = 3'd6;
    l1d_a_o.address = {m_line, 6'b0};
    l1d_a_o.mask = '1;
    l1d_a_valid_o = st_q == S_ACQ;
    l1d_d_ready_o = 1'b1;

    l1d_e_o.sink = gsink_q;
    l1d_e_valid_o = st_q == S_GACK;

    l1d_c_o = '0;
    l1d_c_valid_o = 1'b0;
    if (ps_q == P_ACK) begin
      l1d_c_valid_o = 1'b1;
      l1d_c_o.opcode = p_data_q ? C_PROBE_ACK_DATA : C_PROBE_ACK;
      l1d_c_o.param = p_param_q;
      l1d_c_o.size = 3'd6;
      l1d_c_o.source = p_src_q;
      l1d_c_o.address = {p_line_q, 6'b0};
      l1d_c_o.data = dc_data_q[p_idx_q][p_beat_q*128 +: 128];
    end else if (st_q == S_EVICT) begin
      l1d_c_valid_o = 1'b1;
      l1d_c_o.opcode = dc_dirty_q[m_idx] ? C_RELEASE_DATA : C_RELEASE;
      l1d_c_o.param = dc_t_q[m_idx] ? TL_SHRINK_T_TO_N : TL_SHRINK_B_TO_N;
      l1d_c_o.size = 3'd6;
      l1d_c_o.source = TL_SRC_W'(1);
      l1d_c_o.address = {dc_line_q[m_idx], 6'b0};
      l1d_c_o.data = dc_data_q[m_idx][cbeat_q*128 +: 128];
    end

    mmio_a_o = '0;
    mmio_a_o.opcode = st_q2 ? A_PUT_FULL : A_GET;
    mmio_a_o.size = {1'b0, msz_q};
    mmio_a_o.address = maddr_q[PA_W-1:0];
    mmio_a_o.mask = TL_MASK_W'(((32'd1 << (32'd1 << msz_q)) - 32'd1) << maddr_q[3:0]);
    mmio_a_o.data = 128'(mwdata_q & smask(msz_q)) << (maddr_q[3:0] * 8);
    mmio_a_valid_o = st_q == S_MMIO_REQ;
    mmio_d_ready_o = 1'b1;
  end

  assign merr_o = '0;

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    if (rst) begin
      st_q <= S_BOUND;
      pc_q <= 64'(boot_addr_i);
      prv_q <= PRV_M2;
      mie_bit_q <= 1'b0; mpie_q <= 1'b0; mprv_q <= 1'b0; tw_q <= 1'b0; mpp_q <= PRV_U2;
      mtvec_q <= '0; mepc_q <= '0; mcause_q <= '0; mtval_q <= '0; mscratch_q <= '0;
      mcycle_q <= '0; minstret_q <= '0; mie_q <= '0; mcounteren_q <= '0; mcountinhibit_q <= '0;
      mcontext_q <= '0;
      misa_m_q <= 1'b1;
      fb_valid_q <= 1'b0;
      for (int i = 0; i < NLINES; i++) begin
        dc_valid_q[i] <= 1'b0; dc_t_q[i] <= 1'b0; dc_dirty_q[i] <= 1'b0;
      end
      for (int i = 0; i < 32; i++) xr_q[i] <= '0;
      ps_q <= P_IDLE;
      tq_cnt_q <= '0;
      stall_sh_q <= '0;
      stall_eff_q <= 1'b0;
      tag_busy_q <= '0;
      for (int j = 0; j < WQ_N; j++) wq_v_q[j] <= 1'b0;
      lfsr_q <= (seed == 0) ? 32'h1 : seed;
      cyc_q <= '0;
      gdone_q <= 1'b0;
    end else begin
      cyc_q <= cyc_q + 64'd1;
      lfsr_q <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
      if (!mcountinhibit_q[0]) mcycle_q <= mcycle_q + 64'd1;

      stall_sh_q <= {stall_sh_q[1:0], trace_stall_i};
      stall_eff_q <= stall_eff;

      // Trace queue: pop (or drop), then push.
      begin
        int unsigned n, out;
        logic [WQ_N-1:0] taken;  // writeback slots claimed earlier in this cycle
        taken = '0;
        out = int'(tq_pop) + (tq_drop ? 1 : 0);
        n = int'(tq_cnt_q) - out;
        for (int i = 0; i < TQ_N; i++)
          if (i + out < TQ_N) tq_q[i] <= tq_q[i + out];
        for (int i = 0; i < COMMIT_WIDTH; i++) begin
          if (i < int'(tq_pop) && trace_o[i].rd_deferred) begin
            // Schedule its writeback 1..16 cycles from now.
            for (int j = 0; j < WQ_N; j++) begin
              if (!wq_v_q[j] && !taken[j]) begin
                taken[j] = 1'b1;
                wq_v_q[j] <= 1'b1;
                wq_q[j].hart <= HART;
                wq_q[j].wb_tag <= trace_o[i].wb_tag;
                wq_q[j].rd_fp <= 1'b0;
                wq_q[j].rd <= trace_o[i].rd;
                wq_q[j].value <= trace_o[i].rd_value;
                wq_due_q[j] <= cyc_q + 64'd1 + 64'(lfsr_q[3:0] ^ 4'(i));
                break;
              end
            end
          end
        end
        if (rec_push && tq_room) begin
          tq_q[n] <= rec_new;
          n++;
        end
        tq_cnt_q <= 4'(n);
      end
      for (int j = 0; j < WQ_N; j++) begin
        if (wq_emit[j]) begin
          wq_v_q[j] <= 1'b0;
          tag_busy_q[wq_q[j].wb_tag] <= 1'b0;
        end
      end

      // Probe FSM
      if (ps_q == P_IDLE && b_fire) begin
        logic [IDX_W-1:0] pi;
        logic hit;
        pi = l1d_b_i.address[6 +: IDX_W];
        hit = dc_valid_q[pi] && dc_line_q[pi] == l1d_b_i.address[PA_W-1:6];
        ps_q <= P_ACK;
        p_src_q <= l1d_b_i.source;
        p_line_q <= l1d_b_i.address[PA_W-1:6];
        p_idx_q <= pi;
        p_hit_q <= hit;
        p_beat_q <= '0;
        p_data_q <= 1'b0;
        p_nvalid_q <= hit;
        p_nt_q <= hit && dc_t_q[pi];
        if (!hit) begin
          p_param_q <= TL_REPORT_N_TO_N;
        end else if (dc_t_q[pi]) begin
          if (l1d_b_i.param == TL_CAP_TO_T) begin
            p_param_q <= TL_REPORT_T_TO_T;
          end else begin
            p_param_q <= (l1d_b_i.param == TL_CAP_TO_N) ? TL_SHRINK_T_TO_N : TL_SHRINK_T_TO_B;
            p_data_q <= dc_dirty_q[pi];
            p_nvalid_q <= l1d_b_i.param != TL_CAP_TO_N;
            p_nt_q <= 1'b0;
          end
        end else begin
          p_param_q <= (l1d_b_i.param == TL_CAP_TO_N) ? TL_SHRINK_B_TO_N : TL_REPORT_B_TO_B;
          p_nvalid_q <= l1d_b_i.param != TL_CAP_TO_N;
        end
      end else if (ps_q == P_ACK && l1d_c_ready_i) begin
        if (!p_data_q || p_beat_q == 2'd3) begin
          ps_q <= P_IDLE;
          if (p_hit_q) begin
            dc_valid_q[p_idx_q] <= p_nvalid_q;
            dc_t_q[p_idx_q] <= p_nt_q;
            if (p_data_q) dc_dirty_q[p_idx_q] <= 1'b0;
          end
        end else begin
          p_beat_q <= p_beat_q + 2'd1;
        end
      end

      // Main FSM
      unique case (st_q)
        S_BOUND: begin
          if (irq_take) begin
            if (tq_room) begin
              mepc_q <= pc_q;
              mcause_q <= {1'b1, 59'b0, irq_code};
              mtval_q <= '0;
              mpie_q <= mie_bit_q;
              mie_bit_q <= 1'b0;
              mpp_q <= prv_q;
              prv_q <= PRV_M2;
              pc_q <= {mtvec_q[63:2], 2'b0} + (mtvec_q[0] ? {58'b0, irq_code, 2'b0} : 64'd0);
            end
          end else begin
            st_q <= S_FETCH;
          end
        end
        S_FETCH: begin
          pma_e fp;
          fp = pma_of(paddr_t'(pc_q));
          if (pc_q[63:PA_W] != '0 || (fp != PMA_MEM && fp != PMA_ROM)) begin
            cause_q <= 64'd1; tval_q <= pc_q; insn_q <= '0;
            st_q <= S_TRAP;
          end else if (fb_valid_q && fb_line_q == pc_q[PA_W-1:6]) begin
            st_q <= S_EXEC;
          end else begin
            st_q <= S_IGET;
          end
        end
        S_IGET: if (l1i_a_ready_i) begin st_q <= S_IWAIT; ibeat_q <= '0; iden_q <= 1'b0; end
        S_IWAIT: begin
          if (l1i_d_valid_i) begin
            fb_data_q[ibeat_q*128 +: 128] <= l1i_d_i.data;
            if (l1i_d_i.denied || l1i_d_i.corrupt) iden_q <= 1'b1;
            ibeat_q <= ibeat_q + 2'd1;
            if (ibeat_q == 2'd3) begin
              if (iden_q || l1i_d_i.denied || l1i_d_i.corrupt) begin
                fb_valid_q <= 1'b0;
                cause_q <= 64'd1; tval_q <= pc_q; insn_q <= '0;
                st_q <= S_TRAP;
              end else begin
                fb_valid_q <= 1'b1;
                fb_line_q <= pc_q[PA_W-1:6];
                st_q <= S_FETCH;
              end
            end
          end
        end
        S_EXEC: begin
          insn_q <= insn_ex;
          rd_q <= insn_ex[11:7];
          rd_we_q <= ex_rd_we;
          rd_val_q <= ex_val;
          npc_q <= ex_npc;
          csr_we_q <= ex_csr_we;
          csr_addr_q <= insn_ex[31:20];
          csr_wval_q <= ex_csr_wval;
          mret_q <= ex_mret;
          wfi_q <= ex_wfi;
          fencei_q <= ex_fencei;
          nondet_q <= ex_nondet;
          defer_ok_q <= ex_defer_ok;
          mmio_ld_q <= 1'b0;
          mem_st_q <= 1'b0;
          ld_q <= ex_mem && !ex_store;
          st_q2 <= ex_store;
          msz_q <= insn_ex[13:12];
          mun_q <= insn_ex[14];
          maddr_q <= ex_maddr;
          mwdata_q <= xr_q[insn_ex[24:20]];
          cause_q <= ex_cause;
          tval_q <= ex_tval;
          if (ex_trap) st_q <= S_TRAP;
          else if (ex_mem) begin
            if (p_quiet) st_q <= S_MEM;
            else st_q <= S_EXEC;   // wait for the probe; S_EXEC recomputes the same values
          end else st_q <= S_COMMIT;
        end
        S_MEM: begin
          if (m_misal) begin
            cause_q <= st_q2 ? 64'd6 : 64'd4; tval_q <= maddr_q;
            st_q <= S_TRAP;
          end else if (maddr_q[63:PA_W] != '0 || m_pma == PMA_NONE || (st_q2 && m_pma == PMA_ROM)) begin
            cause_q <= st_q2 ? 64'd7 : 64'd5; tval_q <= maddr_q;
            st_q <= S_TRAP;
          end else if (m_pma != PMA_MEM) begin
            mmio_ld_q <= ld_q;
            st_q <= S_MMIO_REQ;
          end else if (m_hit && ld_q) begin
            rd_val_q <= ld_ext(m_raw, msz_q, mun_q);
            st_q <= S_COMMIT;
          end else if (m_hit && dc_t_q[m_idx]) begin
            for (int k = 0; k < 8; k++)
              if (k < (1 << msz_q)) dc_data_q[m_idx][(maddr_q[5:0] + 6'(k))*8 +: 8] <= mwdata_q[k*8 +: 8];
            dc_dirty_q[m_idx] <= 1'b1;
            mem_st_q <= 1'b1;
            st_q <= S_COMMIT;
          end else if (m_hit) begin
            acq_param_q <= TL_GROW_B_TO_T;
            st_q <= S_ACQ;
          end else if (dc_valid_q[m_idx]) begin
            cbeat_q <= '0;
            st_q <= S_EVICT;
          end else begin
            acq_param_q <= st_q2 ? TL_GROW_N_TO_T : TL_GROW_N_TO_B;
            st_q <= S_ACQ;
          end
        end
        S_EVICT: begin
          if (l1d_c_ready_i) begin
            if (!dc_dirty_q[m_idx] || cbeat_q == 2'd3) begin
              dc_valid_q[m_idx] <= 1'b0;
              dc_dirty_q[m_idx] <= 1'b0;
              st_q <= S_EVICT_WAIT;
            end else begin
              cbeat_q <= cbeat_q + 2'd1;
            end
          end
        end
        S_EVICT_WAIT: begin
          if (l1d_d_valid_i && l1d_d_i.opcode == D_RELEASE_ACK) begin
            acq_param_q <= st_q2 ? TL_GROW_N_TO_T : TL_GROW_N_TO_B;
            st_q <= S_ACQ;
          end
        end
        S_ACQ: if (l1d_a_ready_i) begin st_q <= S_GRANT; gbeat_q <= '0; gdone_q <= 1'b0; gden_q <= 1'b0; end
        S_GRANT: begin
          if (l1d_d_valid_i && !gdone_q) begin
            gbuf_q[gbeat_q*128 +: 128] <= l1d_d_i.data;
            gcap_q <= {1'b0, l1d_d_i.param};
            gsink_q <= l1d_d_i.sink;
            if (l1d_d_i.denied || l1d_d_i.corrupt) gden_q <= 1'b1;
            gbeat_q <= gbeat_q + 2'd1;
            if (gbeat_q == 2'd3 || l1d_d_i.opcode == D_GRANT) gdone_q <= 1'b1;
          end
          if (gdone_q && p_quiet) st_q <= S_INSTALL;
        end
        S_INSTALL: begin
          if (!gden_q) begin
            dc_valid_q[m_idx] <= 1'b1;
            dc_t_q[m_idx] <= gcap_q == TL_CAP_TO_T;
            dc_dirty_q[m_idx] <= 1'b0;
            dc_line_q[m_idx] <= m_line;
            dc_data_q[m_idx] <= gbuf_q;
          end
          st_q <= S_GACK;
        end
        S_GACK: begin
          if (l1d_e_ready_i) begin
            if (gden_q) begin
              cause_q <= st_q2 ? 64'd7 : 64'd5; tval_q <= maddr_q;
              st_q <= S_TRAP;
            end else begin
              st_q <= S_RETRY;
            end
          end
        end
        S_RETRY: if (p_quiet) st_q <= S_MEM;
        S_MMIO_REQ: if (mmio_a_ready_i) st_q <= S_MMIO_WAIT;
        S_MMIO_WAIT: begin
          if (mmio_d_valid_i) begin
            if (mmio_d_i.denied || mmio_d_i.corrupt) begin
              cause_q <= st_q2 ? 64'd7 : 64'd5; tval_q <= maddr_q;
              mmio_ld_q <= 1'b0;
              st_q <= S_TRAP;
            end else begin
              if (ld_q) rd_val_q <= ld_ext(64'(mmio_d_i.data >> (maddr_q[3:0] * 8)), msz_q, mun_q);
              mem_st_q <= st_q2;
              st_q <= S_COMMIT;
            end
          end
        end
        S_COMMIT: begin
          if (tq_room) begin
            if (rd_we_q) xr_q[rd_q] <= rd_val_q;
            if (rec_defer) tag_busy_q[rec_tag] <= 1'b1;
            pc_q <= npc_q;
            if (fencei_q) fb_valid_q <= 1'b0;
            if (!(csr_we_q && csr_addr_q == 12'hB02) && !mcountinhibit_q[2]) minstret_q <= minstret_q + 64'd1;
            if (mret_q) begin
              prv_q <= mpp_q;
              mie_bit_q <= mpie_q;
              mpie_q <= 1'b1;
              mpp_q <= PRV_U2;
              if (mpp_q != PRV_M2) mprv_q <= 1'b0;
            end
            if (csr_we_q) begin
              unique case (csr_addr_q)
                12'h300: begin
                  mie_bit_q <= csr_wval_q[3];
                  mpie_q <= csr_wval_q[7];
                  mpp_q <= (csr_wval_q[12:11] == PRV_M2) ? PRV_M2 : PRV_U2;
                  mprv_q <= csr_wval_q[17];
                  tw_q <= csr_wval_q[21];
                end
                12'h304: mie_q <= csr_wval_q[11:0] & 12'h888;
                12'h305: mtvec_q <= csr_wval_q & ~64'd2;
                12'h306: mcounteren_q <= csr_wval_q[2:0];
                12'h320: mcountinhibit_q <= csr_wval_q[2:0] & 3'b101;
                12'h340: mscratch_q <= csr_wval_q;
                12'h341: mepc_q <= csr_wval_q & ~64'd3;
                12'h342: mcause_q <= csr_wval_q;
                12'h343: mtval_q <= csr_wval_q;
                12'h7A8: mcontext_q <= csr_wval_q[12:0];
                12'h301: misa_m_q <= csr_wval_q[12];
                12'hB00: mcycle_q <= csr_wval_q;
                12'hB02: minstret_q <= csr_wval_q;
                default: ;
              endcase
            end
            st_q <= wfi_q ? S_WFI : S_BOUND;
          end
        end
        S_TRAP: begin
          if (tq_room) begin
            mepc_q <= pc_q;
            mcause_q <= cause_q;
            mtval_q <= tval_q;
            mpie_q <= mie_bit_q;
            mie_bit_q <= 1'b0;
            mpp_q <= prv_q;
            prv_q <= PRV_M2;
            pc_q <= {mtvec_q[63:2], 2'b0};
            st_q <= S_BOUND;
          end
        end
        S_WFI: if (|(mip & mie_q)) st_q <= S_BOUND;
        default: st_q <= S_BOUND;
      endcase
    end
  end

  // Inputs this core does not use
  logic unused;
  assign unused = ^{irq_sei_i, irq_ssi_i, debug_req_i, irq_mei_i, irq_mti_i, irq_msi_i, l1i_d_i.opcode,
                    l1i_d_i.param, l1i_d_i.size, l1i_d_i.source, l1i_d_i.sink, l1d_b_i.opcode, l1d_b_i.size,
                    l1d_d_i.size, l1d_d_i.source, mmio_d_i.opcode, mmio_d_i.param, mmio_d_i.size,
                    mmio_d_i.source, mmio_d_i.sink};
endmodule
