// Rename map of 32 architectural registers in LUTRAM (plan §8.5 R3; docs/spec/core-pipeline.md
// §5.2). The speculative map has one bank per rename slot and the committed map one per commit
// slot, so every write port is a LUTRAM's. The banks are XOR-banked (FPGA-friendly T2; LaForest
// et al., "Multi-ported memories for FPGAs via XOR", FPGA 2012): a register's entry is the XOR
// of its banks, and a slot writes its own bank with the new value XOR the other banks' entries
// at that register, so no live-value table names the bank that holds it. Of several slots
// writing one register in a cycle, only the last writes (a later slot wins). sv_q[r]: r was
// renamed since the last flush; otherwise the committed map answers, and its producer has
// committed (so the caller does not read the producer fields). A flush clears sv_q: the
// committed map is current in the next cycle, with no copy. After reset a sweep writes the
// identity (register r -> physical register r) into committed bank 0 and zeros into the other
// committed banks; `ready` rises when it is done.
// Per thread (M7's step 3, docs/spec/threading.md): every bank holds a map per thread at {tid, register}
// (RAM form, 64 deep), and sv_q is per thread. Reads and RN writes are the rename group's thread's (rtid),
// commit writes the commit group's (ctid), and a flush clears the flushed thread's sv_q only. The reset
// sweep writes the running thread's map (RUN_TID; the other thread's comes with the split mode).
// tg_rename has one for the integer registers and, with EXT_FD, one for the FP registers.
module tg_rmap
  import tg_pkg::*, tg_core_pkg::*;
#(
  parameter int W   = 2,         // rename slots: speculative write ports (a later slot wins)
  parameter int CW  = 2,         // commit slots: committed write ports (a later slot wins)
  parameter int PW  = 8,         // mapping width
  parameter int DW  = 8,         // producer fields width
  parameter int NR  = 6,         // mapping read ports
  parameter int NRD = 4          // producer read ports: the first NRD mapping ports
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   flush,
  input  tid_t                   flush_tid,
  output logic                   ready,
  input  tid_t                   rtid,    // the rename group's thread: reads and RN writes
  input  tid_t                   ctid,    // the commit group's thread: commit writes
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
  localparam int NT = NUM_THREADS;
  localparam int AW = 5 + ((NT > 1) ? 1 : 0);    // {tid, register}
  // The threads (without SMT thread 0, whatever the tid bits hold)
  tid_t rt, ct, ft;
  assign rt = (NT > 1) ? rtid : tid_t'(0);
  assign ct = (NT > 1) ? ctid : tid_t'(0);
  assign ft = (NT > 1) ? flush_tid : tid_t'(0);
  function automatic logic [AW-1:0] ma(input tid_t t, input logic [4:0] r);
    return AW'({t, r});                           // without SMT the tid's bit falls off
  endfunction
  logic [NT-1:0][31:0]    sv_q;           // renamed since the thread's last flush
  logic [5:0]             cinit_q;        // reset sweep into the committed banks
  assign ready = cinit_q[5];

  // The last writer of each register in a cycle (earlier slots on the same register drop out)
  logic [W-1:0]  wl;
  logic [CW-1:0] cwl;
  always_comb begin
    for (int k = 0; k < W; k++) begin
      wl[k] = we[k];
      for (int j = k + 1; j < W; j++) if (we[j] && wa[j] == wa[k]) wl[k] = 1'b0;
    end
    for (int k = 0; k < CW; k++) begin
      cwl[k] = cwe[k];
      for (int j = k + 1; j < CW; j++) if (cwe[j] && cwa[j] == cwa[k]) cwl[k] = 1'b0;
    end
  end

  // ---- Speculative banks: read ports 0..NR-1 (mapping) / 0..NRD-1 (producer), then the other
  // slots' write registers (for the XOR), in slot order ----
  localparam int NRS = NR + W - 1;
  localparam int NDS = NRD + W - 1;
  logic [W-1:0][NRS-1:0][PW-1:0] ms_rd;
  logic [W-1:0][NDS-1:0][DW-1:0] mp_rd;
  for (genvar k = 0; k < W; k++) begin : g_ms
    logic [NRS-1:0][AW-1:0] ar;
    logic [NDS-1:0][AW-1:0] dr;
    for (genvar i = 0; i < NR; i++) begin : g_ar
      assign ar[i] = ma(rt, ra[i]);
    end
    for (genvar i = 0; i < NRD; i++) begin : g_dr
      assign dr[i] = ma(rt, ra[i]);
    end
    for (genvar o = 0; o < W; o++) begin : g_o
      if (o != k) begin : g_x
        assign ar[NR + (o < k ? o : o - 1)]  = ma(rt, wa[o]);
        assign dr[NRD + (o < k ? o : o - 1)] = ma(rt, wa[o]);
      end
    end
    logic [PW-1:0] xp;
    logic [DW-1:0] xd;
    always_comb begin
      xp = wd_p[k];
      xd = wd_d[k];
      for (int o = 0; o < W; o++) begin
        if (o != k) begin
          xp ^= ms_rd[o][NR + (k < o ? k : k - 1)];
          xd ^= mp_rd[o][NRD + (k < o ? k : k - 1)];
        end
      end
    end
    tg_ram_lut #(.DEPTH(32 * NT), .WIDTH(PW), .NR(NRS)) u_map (
      .clk, .we(wl[k]), .waddr(ma(rt, wa[k])), .wdata(xp), .raddr(ar), .rdata(ms_rd[k]));
    tg_ram_lut #(.DEPTH(32 * NT), .WIDTH(DW), .NR(NDS)) u_prod (
      .clk, .we(wl[k]), .waddr(ma(rt, wa[k])), .wdata(xd), .raddr(dr), .rdata(mp_rd[k]));
  end

  // ---- Committed banks: read ports 0..NR-1, then the other commit slots' write registers ----
  localparam int NRC = NR + CW - 1;
  logic [CW-1:0][NRC-1:0][PW-1:0] mc_rd;
  for (genvar j = 0; j < CW; j++) begin : g_mc
    logic [NRC-1:0][AW-1:0] ar;
    for (genvar i = 0; i < NR; i++) begin : g_ar
      assign ar[i] = ma(rt, ra[i]);
    end
    for (genvar o = 0; o < CW; o++) begin : g_o
      if (o != j) begin : g_x
        assign ar[NR + (o < j ? o : o - 1)] = ma(ct, cwa[o]);
      end
    end
    logic          cw;
    logic [AW-1:0] cwa_j;
    logic [PW-1:0] cwd_j;
    always_comb begin
      cw    = cwl[j];
      cwa_j = ma(ct, cwa[j]);
      cwd_j = cwd[j];
      for (int o = 0; o < CW; o++)
        if (o != j) cwd_j ^= mc_rd[o][NR + (j < o ? j : j - 1)];
      if (!cinit_q[5]) begin
        cw    = 1'b1;
        cwa_j = ma(RUN_TID, cinit_q[4:0]);
        cwd_j = (j == 0) ? PW'(cinit_q[4:0]) : '0;
      end
    end
    tg_ram_lut #(.DEPTH(32 * NT), .WIDTH(PW), .NR(NRC)) u_cmap (
      .clk, .we(cw), .waddr(cwa_j), .wdata(cwd_j), .raddr(ar), .rdata(mc_rd[j]));
  end

  for (genvar i = 0; i < NR; i++) begin : g_rd
    always_comb begin
      logic [PW-1:0] s, c;
      s = '0;
      c = '0;
      for (int k = 0; k < W; k++)  s ^= ms_rd[k][i];
      for (int j = 0; j < CW; j++) c ^= mc_rd[j][i];
      rd_p[i] = sv_q[rt][ra[i]] ? s : c;
    end
    if (i < NRD) begin : g_pd
      always_comb begin
        rd_d[i] = '0;
        for (int k = 0; k < W; k++) rd_d[i] ^= mp_rd[k][i];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      sv_q    <= '0;
      cinit_q <= '0;
    end else begin
      if (!cinit_q[5]) cinit_q <= cinit_q + 1'b1;
      if (flush) begin
        sv_q[ft] <= '0;
      end else begin
        for (int k = 0; k < W; k++) if (we[k]) sv_q[rt][wa[k]] <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) assert (!(flush && |we)) else $error("tg_rmap: a rename write in a flush cycle");
  end
`endif
endmodule
