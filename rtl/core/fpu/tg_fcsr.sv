// fcsr state per hart (docs/spec/fpu.md, "Core integration"; RISC-V F, "Floating-Point Control
// and Status Register"; plan §4.5): frm and fflags, for the core's CSR file to instantiate.
// - frm_o goes to decode, which resolves DYN there (every CSR write ends in a flush).
// - CSR reads are combinational; a write (at retirement) names the view by the low bits of its
//   address (fflags 0x001, frm 0x002, fcsr 0x003). The CSR file checks FS != Off and does the
//   csrrs/csrrc arithmetic.
// - fflags accumulate from retiring FP operations (cm_*, the ROB's per-entry flags) and from
//   early-retired divides when they complete (er_*). er_busy counts those divides: a CSR access
//   to fflags or fcsr waits until it is clear (plan §4.5).
// - fs_dirty pulses when FP state changes, as Spike sets mstatus.FS = Dirty: an f register
//   written by a retiring instruction, nonzero flags accumulated, or an fcsr view written.
module tg_fcsr
  import tg_pkg::*, tg_fpcore_pkg::*;
#(
  parameter int NT   = NUM_THREADS,
  parameter int NC   = COMMIT_WIDTH,
  parameter int ER_W = 4                       // early-retired divides pending per hart: < 2^ER_W
) (
  input  logic                  clk,
  input  logic                  rst,
  output logic [NT-1:0][2:0]    frm_o,
  // CSR read (combinational) and write (at retirement)
  input  tid_t                  csr_rtid,
  output logic [4:0]            csr_fflags,
  output logic [2:0]            csr_frm,
  input  logic                  csr_wvalid,
  input  tid_t                  csr_wtid,
  input  logic [1:0]            csr_waddr,
  input  logic [7:0]            csr_wdata,
  // Accumulation at commit: one entry per commit slot
  input  logic [NC-1:0]         cm_valid,
  input  tid_t [NC-1:0]         cm_tid,
  input  logic [NC-1:0][4:0]    cm_fflags,
  input  logic [NC-1:0]         cm_fpr,         // the instruction wrote an f register
  // Early-retired divides: retired before their result, then completed
  input  logic                  er_ret_valid,
  input  tid_t                  er_ret_tid,
  input  logic                  er_valid,
  input  tid_t                  er_tid,
  input  logic [4:0]            er_fflags,
  output logic [NT-1:0]         er_busy,
  output logic [NT-1:0]         fs_dirty
);
  logic [NT-1:0][2:0]      frm_q;
  logic [NT-1:0][4:0]      fflags_q;
  logic [NT-1:0][ER_W-1:0] er_cnt_q;

  assign frm_o      = frm_q;
  assign csr_fflags = fflags_q[csr_rtid];
  assign csr_frm    = frm_q[csr_rtid];

  for (genvar t = 0; t < NT; t++) begin : g_hart
    logic [4:0] acc;
    logic       wr, wr_ff, wr_rm, any_fpr, up, down;
    always_comb begin
      acc     = '0;
      any_fpr = 1'b0;
      for (int k = 0; k < NC; k++) begin
        if (cm_valid[k] && cm_tid[k] == tid_t'(t)) begin
          acc     = acc | cm_fflags[k];
          any_fpr = any_fpr || cm_fpr[k];
        end
      end
      if (er_valid && er_tid == tid_t'(t)) acc = acc | er_fflags;
      wr    = csr_wvalid && csr_wtid == tid_t'(t);
      wr_ff = wr && (csr_waddr == FCSR_A_FFLAGS || csr_waddr == FCSR_A_FCSR);
      wr_rm = wr && (csr_waddr == FCSR_A_FRM || csr_waddr == FCSR_A_FCSR);
      up    = er_ret_valid && er_ret_tid == tid_t'(t);
      down  = er_valid && er_tid == tid_t'(t);
    end
    assign er_busy[t]  = er_cnt_q[t] != '0;
    assign fs_dirty[t] = wr || any_fpr || acc != '0;

    always_ff @(posedge clk) begin
      if (rst) begin
        frm_q[t]    <= '0;
        fflags_q[t] <= '0;
        er_cnt_q[t] <= '0;
      end else begin
        if (wr_rm) frm_q[t] <= (csr_waddr == FCSR_A_FCSR) ? csr_wdata[7:5] : csr_wdata[2:0];
        fflags_q[t] <= (wr_ff ? csr_wdata[4:0] : fflags_q[t]) | acc;
        er_cnt_q[t] <= er_cnt_q[t] + ER_W'(up) - ER_W'(down);
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      for (int t = 0; t < NT; t++) begin
        assert (!(er_valid && er_tid == tid_t'(t) && er_cnt_q[t] == '0 &&
                  !(er_ret_valid && er_ret_tid == tid_t'(t))))
          else $error("tg_fcsr: early-retired completion with none pending");
        assert (!(er_ret_valid && er_ret_tid == tid_t'(t) && (&er_cnt_q[t])))
          else $error("tg_fcsr: early-retired counter overflow");
      end
    end
  end
`endif
endmodule
