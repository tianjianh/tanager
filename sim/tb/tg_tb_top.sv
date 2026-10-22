// Simulation top for tg_vsim (docs/spec/verification.md §2). Not product RTL.
// Instantiates one core and hands every port to the C++ models through DPI. Each input the
// harness drives is a register here, updated at the rising edge from the model's answer, so no
// combinational path runs from the core's outputs back to its inputs (verification.md §2.2).
module tg_tb_top
  import tg_pkg::*, tg_tl_pkg::*, tg_trace_pkg::*;
#(
  parameter int unsigned CORE_ID = 0
) (
  input logic clk,
  input logic rst
);

  // ---- DPI: the C++ side is sim/src/tb_dpi.cpp ----
  import "DPI-C" function void tg_dpi_config(
    input string cfg_name, input int commit_width, input int num_threads, input int core_id,
    input int hart_w, input int wb_tag_w, input int trace_wb_ports, input int pa_w,
    input int l1i_mshrs, input int l1d_mshrs, input int llt_entries, input int trace_stall_headroom,
    input int pmp_entries, input int hart1_on);

  // TL-UL responder (l1i = port 0, mmio = port 2): what the core presented this cycle, and the
  // responder's outputs for the next cycle.
  import "DPI-C" function void tg_dpi_tl_ul(
    input int port,
    input bit a_valid, input int a_opcode, input int a_param, input int a_size, input int a_source,
    input longint a_address, input bit [15:0] a_mask, input bit [127:0] a_data, input bit a_corrupt,
    input bit d_ready,
    output bit a_ready_n,
    output bit d_valid_n, output int d_opcode_n, output int d_param_n, output int d_size_n,
    output int d_source_n, output int d_sink_n, output bit d_denied_n, output bit [127:0] d_data_n,
    output bit d_corrupt_n);

  // TL-C manager for l1d (port 1).
  import "DPI-C" function void tg_dpi_tl_c(
    input bit a_valid, input int a_opcode, input int a_param, input int a_size, input int a_source,
    input longint a_address, input bit [15:0] a_mask, input bit [127:0] a_data, input bit a_corrupt,
    input bit b_ready,
    input bit c_valid, input int c_opcode, input int c_param, input int c_size, input int c_source,
    input longint c_address, input bit [127:0] c_data, input bit c_corrupt,
    input bit d_ready,
    input bit e_valid, input int e_sink,
    output bit a_ready_n,
    output bit b_valid_n, output int b_opcode_n, output int b_param_n, output int b_size_n,
    output int b_source_n, output longint b_address_n,
    output bit c_ready_n,
    output bit d_valid_n, output int d_opcode_n, output int d_param_n, output int d_size_n,
    output int d_source_n, output int d_sink_n, output bit d_denied_n, output bit [127:0] d_data_n,
    output bit d_corrupt_n,
    output bit e_ready_n);

  // Interrupt lines and mtime for the next cycle; one bit per hart of this core (index = tid).
  import "DPI-C" function void tg_dpi_irq(
    input int merr,
    output int mei_n, output int sei_n, output int mti_n, output int msi_n, output int ssi_n,
    output longint mtime_n);

  // Commit trace: one call per valid record, in slot order, then one per valid writeback.
  import "DPI-C" function void tg_dpi_trace(
    input int slot, input int kind, input int hart, input int priv, input longint pc, input int insn,
    input bit rvc, input bit rd_we, input bit rd_fp, input int rd, input bit rd_deferred,
    input int wb_tag, input longint rd_value, input bit mem_st, input longint mem_vaddr,
    input longint mem_wdata, input int mem_size, input bit mmio_ld, input bit nondet, input bit mem_ld,
    input longint cause, input longint tval);
  import "DPI-C" function void tg_dpi_trace_wb(
    input int port, input int hart, input int wb_tag, input bit rd_fp, input int rd,
    input longint value);
  // After the cycle's records: the trace sink's trace_stall_i for the next cycle (interfaces.md §5).
  import "DPI-C" function bit tg_dpi_trace_stall();

  import "DPI-C" function longint tg_dpi_boot_addr();

  // DR-167: the core's PMP entries, and so lockstep's Spike's PMP regions. sim/Makefile defines
  // TG_TB_PKG_PMP once tg_core_pkg has the switch (PMP_ENTRIES); before it the core had 16, and the test
  // core has none. TG_TB_PMP_RTL is the count sim/profile.mk read from the package (PMP_RTL), the default
  // of tg_replay and tanager-lockstep, which have no RTL: every run checks that reading here.
`ifdef TG_TCORE
  localparam int PMP_ENTRIES_TB = 0;
`elsif TG_TB_PKG_PMP
  localparam int PMP_ENTRIES_TB = tg_core_pkg::PMP_ENTRIES;
`else
  localparam int PMP_ENTRIES_TB = 16;
`endif

  paddr_t boot_addr;
  initial begin
`ifdef TG_TB_PMP_RTL
    if (PMP_ENTRIES_TB != `TG_TB_PMP_RTL)
      $fatal(1, "tg_tb_top: the core has %0d PMP entries, but sim/profile.mk expected %0d (PMP_ENTRIES, else the default line it reads in rtl/core/tg_core_pkg.sv, which tg_replay and tanager-lockstep take as theirs)",
             PMP_ENTRIES_TB, `TG_TB_PMP_RTL);
`endif
    // DR-146: without the commit trace there is nothing to check, so refuse rather than pass on nothing.
    if (!COMMIT_TRACE)
      $fatal(1, "tg_tb_top: this model was built with TG_COMMIT_TRACE=0 (DR-146): it has no commit trace, so lockstep cannot run; build it with the trace on");
    tg_dpi_config(CFG_NAME, COMMIT_WIDTH, NUM_THREADS, CORE_ID, HART_W, WB_TAG_W,
                  TRACE_WB_PORTS, PA_W, L1I_MSHRS, L1D_MSHRS, LLT_ENTRIES, TRACE_STALL_HEADROOM, PMP_ENTRIES_TB,
                  int'(tg_core_pkg::HART1_ON));
    boot_addr = paddr_t'(tg_dpi_boot_addr());
  end

  // ---- Core ports ----
  logic [NUM_THREADS-1:0] irq_mei_q, irq_sei_q, irq_mti_q, irq_msi_q, irq_ssi_q, merr;
  logic [63:0]            mtime_q;

  tl_a_t l1i_a;   logic l1i_a_valid,  l1i_a_ready_q;
  tl_d_t l1i_d_q; logic l1i_d_valid_q, l1i_d_ready;

  tl_a_t l1d_a;   logic l1d_a_valid,  l1d_a_ready_q;
  tl_b_t l1d_b_q; logic l1d_b_valid_q, l1d_b_ready;
  tl_c_t l1d_c;   logic l1d_c_valid,  l1d_c_ready_q;
  tl_d_t l1d_d_q; logic l1d_d_valid_q, l1d_d_ready;
  tl_e_t l1d_e;   logic l1d_e_valid,  l1d_e_ready_q;

  tl_a_t mmio_a;   logic mmio_a_valid,  mmio_a_ready_q;
  tl_d_t mmio_d_q; logic mmio_d_valid_q, mmio_d_ready;

  tr_rec_t [COMMIT_WIDTH-1:0]   trace;
  logic    [COMMIT_WIDTH-1:0]   trace_valid;
  tr_wb_t  [TRACE_WB_PORTS-1:0] trace_wb;
  logic    [TRACE_WB_PORTS-1:0] trace_wb_valid;
  logic                         trace_stall_q;
  logic    [31:0]               core_dbg;       // the board-debug word (tg_core DBG_WORD), unused here

`ifdef TG_TCORE
  tg_tcore #(.CORE_ID(CORE_ID)) u_core (
`else
  tg_core #(.CORE_ID(CORE_ID)) u_core (
`endif
    .clk, .rst,
    .boot_addr_i      (boot_addr),
    .irq_mei_i        (irq_mei_q),
    .irq_sei_i        (irq_sei_q),
    .irq_mti_i        (irq_mti_q),
    .irq_msi_i        (irq_msi_q),
    .irq_ssi_i        (irq_ssi_q),
    .mtime_i          (mtime_q),
    .debug_req_i      ('0),
    .merr_o           (merr),
    .l1i_a_o          (l1i_a),
    .l1i_a_valid_o    (l1i_a_valid),
    .l1i_a_ready_i    (l1i_a_ready_q),
    .l1i_d_i          (l1i_d_q),
    .l1i_d_valid_i    (l1i_d_valid_q),
    .l1i_d_ready_o    (l1i_d_ready),
    .l1d_a_o          (l1d_a),
    .l1d_a_valid_o    (l1d_a_valid),
    .l1d_a_ready_i    (l1d_a_ready_q),
    .l1d_b_i          (l1d_b_q),
    .l1d_b_valid_i    (l1d_b_valid_q),
    .l1d_b_ready_o    (l1d_b_ready),
    .l1d_c_o          (l1d_c),
    .l1d_c_valid_o    (l1d_c_valid),
    .l1d_c_ready_i    (l1d_c_ready_q),
    .l1d_d_i          (l1d_d_q),
    .l1d_d_valid_i    (l1d_d_valid_q),
    .l1d_d_ready_o    (l1d_d_ready),
    .l1d_e_o          (l1d_e),
    .l1d_e_valid_o    (l1d_e_valid),
    .l1d_e_ready_i    (l1d_e_ready_q),
    .mmio_a_o         (mmio_a),
    .mmio_a_valid_o   (mmio_a_valid),
    .mmio_a_ready_i   (mmio_a_ready_q),
    .mmio_d_i         (mmio_d_q),
    .mmio_d_valid_i   (mmio_d_valid_q),
    .mmio_d_ready_o   (mmio_d_ready),
    .trace_stall_i    (trace_stall_q),        // 0 unless tg_vsim runs with --trace-stall (§2.9)
    .trace_o          (trace),
    .trace_valid_o    (trace_valid),
    .trace_wb_o       (trace_wb),
    .trace_wb_valid_o (trace_wb_valid),
    .dbg_sel_i        ('0),
    .dbg_o            (core_dbg)
  );

  // ---- One DPI exchange per port per rising edge ----
  // The *_n variables only carry the DPI outputs to the non-blocking assignments below.
  bit         ul_a_ready_n, ul_d_valid_n, ul_d_denied_n, ul_d_corrupt_n;
  int         ul_d_opcode_n, ul_d_param_n, ul_d_size_n, ul_d_source_n, ul_d_sink_n;
  bit [127:0] ul_d_data_n;
  bit         c_a_ready_n, c_b_valid_n, c_c_ready_n, c_d_valid_n, c_d_denied_n, c_d_corrupt_n, c_e_ready_n;
  int         c_b_opcode_n, c_b_param_n, c_b_size_n, c_b_source_n;
  longint     c_b_address_n;
  int         c_d_opcode_n, c_d_param_n, c_d_size_n, c_d_source_n, c_d_sink_n;
  bit [127:0] c_d_data_n;
  int         mei_n, sei_n, mti_n, msi_n, ssi_n;
  longint     mtime_n;

  function automatic tl_d_t mk_d(int opcode, int param, int size, int source, int sink, bit denied,
                                 bit [127:0] data, bit corrupt);
    tl_d_t d;
    d.opcode  = tl_d_op_e'(opcode[2:0]);
    d.param   = param[1:0];
    d.size    = size[TL_SIZE_W-1:0];
    d.source  = source[TL_SRC_W-1:0];
    d.sink    = sink[TL_SINK_W-1:0];
    d.denied  = denied;
    d.data    = data;
    d.corrupt = corrupt;
    return d;
  endfunction

  always @(posedge clk) begin
    if (rst) begin
      l1i_a_ready_q  <= 1'b0;  l1i_d_valid_q  <= 1'b0;  l1i_d_q  <= '0;
      mmio_a_ready_q <= 1'b0;  mmio_d_valid_q <= 1'b0;  mmio_d_q <= '0;
      l1d_a_ready_q  <= 1'b0;  l1d_b_valid_q  <= 1'b0;  l1d_b_q  <= '0;
      l1d_c_ready_q  <= 1'b0;  l1d_d_valid_q  <= 1'b0;  l1d_d_q  <= '0;
      l1d_e_ready_q  <= 1'b0;
      irq_mei_q <= '0; irq_sei_q <= '0; irq_mti_q <= '0; irq_msi_q <= '0; irq_ssi_q <= '0;
      mtime_q   <= '0;
      trace_stall_q <= 1'b0;
    end else begin
      // mmio (port 2)
      tg_dpi_tl_ul(2, mmio_a_valid, int'(mmio_a.opcode), int'(mmio_a.param), int'(mmio_a.size),
                   int'(mmio_a.source), longint'(mmio_a.address), mmio_a.mask, mmio_a.data,
                   mmio_a.corrupt, mmio_d_ready,
                   ul_a_ready_n, ul_d_valid_n, ul_d_opcode_n, ul_d_param_n, ul_d_size_n,
                   ul_d_source_n, ul_d_sink_n, ul_d_denied_n, ul_d_data_n, ul_d_corrupt_n);
      mmio_a_ready_q <= ul_a_ready_n;
      mmio_d_valid_q <= ul_d_valid_n;
      mmio_d_q       <= mk_d(ul_d_opcode_n, ul_d_param_n, ul_d_size_n, ul_d_source_n, ul_d_sink_n,
                             ul_d_denied_n, ul_d_data_n, ul_d_corrupt_n);

      // l1i (port 0)
      tg_dpi_tl_ul(0, l1i_a_valid, int'(l1i_a.opcode), int'(l1i_a.param), int'(l1i_a.size),
                   int'(l1i_a.source), longint'(l1i_a.address), l1i_a.mask, l1i_a.data,
                   l1i_a.corrupt, l1i_d_ready,
                   ul_a_ready_n, ul_d_valid_n, ul_d_opcode_n, ul_d_param_n, ul_d_size_n,
                   ul_d_source_n, ul_d_sink_n, ul_d_denied_n, ul_d_data_n, ul_d_corrupt_n);
      l1i_a_ready_q <= ul_a_ready_n;
      l1i_d_valid_q <= ul_d_valid_n;
      l1i_d_q       <= mk_d(ul_d_opcode_n, ul_d_param_n, ul_d_size_n, ul_d_source_n, ul_d_sink_n,
                            ul_d_denied_n, ul_d_data_n, ul_d_corrupt_n);

      // l1d (port 1, TL-C)
      tg_dpi_tl_c(l1d_a_valid, int'(l1d_a.opcode), int'(l1d_a.param), int'(l1d_a.size),
                  int'(l1d_a.source), longint'(l1d_a.address), l1d_a.mask, l1d_a.data, l1d_a.corrupt,
                  l1d_b_ready,
                  l1d_c_valid, int'(l1d_c.opcode), int'(l1d_c.param), int'(l1d_c.size),
                  int'(l1d_c.source), longint'(l1d_c.address), l1d_c.data, l1d_c.corrupt,
                  l1d_d_ready,
                  l1d_e_valid, int'(l1d_e.sink),
                  c_a_ready_n,
                  c_b_valid_n, c_b_opcode_n, c_b_param_n, c_b_size_n, c_b_source_n, c_b_address_n,
                  c_c_ready_n,
                  c_d_valid_n, c_d_opcode_n, c_d_param_n, c_d_size_n, c_d_source_n, c_d_sink_n,
                  c_d_denied_n, c_d_data_n, c_d_corrupt_n,
                  c_e_ready_n);
      l1d_a_ready_q    <= c_a_ready_n;
      l1d_b_valid_q    <= c_b_valid_n;
      l1d_b_q.opcode   <= tl_b_op_e'(c_b_opcode_n[2:0]);
      l1d_b_q.param    <= c_b_param_n[2:0];
      l1d_b_q.size     <= c_b_size_n[TL_SIZE_W-1:0];
      l1d_b_q.source   <= c_b_source_n[TL_SRC_W-1:0];
      l1d_b_q.address  <= c_b_address_n[TL_ADDR_W-1:0];
      l1d_c_ready_q    <= c_c_ready_n;
      l1d_d_valid_q    <= c_d_valid_n;
      l1d_d_q          <= mk_d(c_d_opcode_n, c_d_param_n, c_d_size_n, c_d_source_n, c_d_sink_n,
                               c_d_denied_n, c_d_data_n, c_d_corrupt_n);
      l1d_e_ready_q    <= c_e_ready_n;

      // Interrupts and time
      tg_dpi_irq(int'(merr), mei_n, sei_n, mti_n, msi_n, ssi_n, mtime_n);
      irq_mei_q <= mei_n[NUM_THREADS-1:0];
      irq_sei_q <= sei_n[NUM_THREADS-1:0];
      irq_mti_q <= mti_n[NUM_THREADS-1:0];
      irq_msi_q <= msi_n[NUM_THREADS-1:0];
      irq_ssi_q <= ssi_n[NUM_THREADS-1:0];
      mtime_q   <= mtime_n;

      // Commit trace of the cycle that is ending
      for (int i = 0; i < COMMIT_WIDTH; i++) begin
        if (trace_valid[i]) begin
          tg_dpi_trace(i, int'(trace[i].kind), int'(trace[i].hart), int'(trace[i].priv), trace[i].pc,
                       trace[i].insn, trace[i].rvc, trace[i].rd_we, trace[i].rd_fp, int'(trace[i].rd),
                       trace[i].rd_deferred, int'(trace[i].wb_tag), trace[i].rd_value, trace[i].mem_st,
                       trace[i].mem_vaddr, trace[i].mem_wdata, int'(trace[i].mem_size), trace[i].mmio_ld,
                       trace[i].nondet, trace[i].mem_ld, trace[i].cause, trace[i].tval);
        end
      end
      for (int i = 0; i < TRACE_WB_PORTS; i++) begin
        if (trace_wb_valid[i]) begin
          tg_dpi_trace_wb(i, int'(trace_wb[i].hart), int'(trace_wb[i].wb_tag), trace_wb[i].rd_fp,
                          int'(trace_wb[i].rd), trace_wb[i].value);
        end
      end
      trace_stall_q <= tg_dpi_trace_stall();
    end
  end
endmodule
