// Rename map of 32 architectural registers in LUTRAM (plan §8.5 R3; docs/spec/core-pipeline.md
// §5.2). The speculative map has one bank per rename slot and the committed map one per commit
// slot, so every write port is a LUTRAM's; live-value tables in flip-flops name the bank that
// holds each register's latest entry. sv_q[r]: r was renamed since the last flush; otherwise the
// committed map answers, and its producer has committed (so the caller does not read the
// producer fields). A flush clears sv_q: the committed map is current in the next cycle, with
// no copy. After reset a sweep writes the identity (register r -> physical register r, bank 0)
// into committed bank 0; `ready` rises when it is done.
// tg_rename has one for the integer registers and, with EXT_FD, one for the FP registers.
module tg_rmap
  import tg_pkg::*;
#(
  parameter int W   = 2,         // rename slots: speculative write ports (a later slot wins)
  parameter int CW  = 2,         // commit slots: committed write ports (a later slot wins)
  parameter int PW  = 8,         // mapping width
  parameter int DW  = 8,         // producer fields width
  parameter int NR  = 6,         // mapping read ports
  parameter int NRD = 4,         // producer read ports: the first NRD mapping ports
  localparam int KSW = idx_w(W),
  localparam int CSW = idx_w(CW)
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   flush,
  output logic                   ready,
  input  logic [NR-1:0][4:0]     ra,
  output logic [NR-1:0][PW-1:0]  rd_p,
  output logic [NRD-1:0][DW-1:0] rd_d,
  input  logic [W-1:0]           we,      // RN writes (never in a flush cycle)
  input  logic [W-1:0][4:0]      wa,
  input  logic [W-1:0][PW-1:0]   wd_p,
  input  logic [W-1:0][DW-1:0]   wd_d,
  input  logic [CW-1:0]          cwe,     // commit writes
  input  logic [CW-1:0][4:0]     cwa,
  input  logic [CW-1:0][PW-1:0]  cwd
);
  logic [31:0]            sv_q;           // renamed since the last flush
  logic [31:0][KSW-1:0]   lvt_q;          // speculative bank with the latest entry
  logic [31:0][CSW-1:0]   lvtc_q;         // committed bank with the latest entry
  logic [5:0]             cinit_q;        // reset sweep into committed bank 0
  assign ready = cinit_q[5];

  logic [W-1:0][NR-1:0][PW-1:0]   ms_rd;
  logic [W-1:0][NRD-1:0][DW-1:0]  mp_rd;
  logic [CW-1:0][NR-1:0][PW-1:0]  mc_rd;
  for (genvar k = 0; k < W; k++) begin : g_ms
    tg_ram_lut #(.DEPTH(32), .WIDTH(PW), .NR(NR)) u_map (
      .clk, .we(we[k]), .waddr(wa[k]), .wdata(wd_p[k]), .raddr(ra), .rdata(ms_rd[k]));
    tg_ram_lut #(.DEPTH(32), .WIDTH(DW), .NR(NRD)) u_prod (
      .clk, .we(we[k]), .waddr(wa[k]), .wdata(wd_d[k]), .raddr(ra[NRD-1:0]), .rdata(mp_rd[k]));
  end
  for (genvar j = 0; j < CW; j++) begin : g_mc
    logic cw;
    logic [4:0] cwa_j;
    logic [PW-1:0] cwd_j;
    always_comb begin
      cw    = cwe[j];
      cwa_j = cwa[j];
      cwd_j = cwd[j];
      if (j == 0 && !cinit_q[5]) begin
        cw    = 1'b1;
        cwa_j = cinit_q[4:0];
        cwd_j = PW'(cinit_q[4:0]);
      end
    end
    tg_ram_lut #(.DEPTH(32), .WIDTH(PW), .NR(NR)) u_cmap (
      .clk, .we(cw), .waddr(cwa_j), .wdata(cwd_j), .raddr(ra), .rdata(mc_rd[j]));
  end
  for (genvar i = 0; i < NR; i++) begin : g_rd
    always_comb begin
      logic [4:0] r;
      r = ra[i];
      rd_p[i] = sv_q[r] ? ms_rd[lvt_q[r]][i] : mc_rd[lvtc_q[r]][i];
    end
    if (i < NRD) begin : g_pd
      assign rd_d[i] = mp_rd[lvt_q[ra[i]]][i];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      sv_q    <= '0;
      lvtc_q  <= '0;
      cinit_q <= '0;
    end else begin
      if (!cinit_q[5]) cinit_q <= cinit_q + 1'b1;
      for (int j = 0; j < CW; j++) if (cwe[j]) lvtc_q[cwa[j]] <= CSW'(j);
      if (flush) begin
        sv_q <= '0;
      end else begin
        for (int k = 0; k < W; k++) begin
          if (we[k]) begin
            sv_q[wa[k]]  <= 1'b1;
            lvt_q[wa[k]] <= KSW'(k);
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) assert (!(flush && |we)) else $error("tg_rmap: a rename write in a flush cycle");
  end
`endif
endmodule
