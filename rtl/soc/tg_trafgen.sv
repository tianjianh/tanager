// Traffic generator in a core's place (docs/spec/soc.md §2.3): the tg_core ports plus a small
// control interface. When enabled it repeats passes over a region of lines through its l1d port:
//   write pass: AcquireBlock NtoT, fill the line with pattern(line, pass), ReleaseData TtoN;
//   read pass:  AcquireBlock NtoB, check the GrantData against the pattern, Release BtoN;
// then writes '.' (or 'E' after an error) to the UART through its mmio port. It answers probes by
// the TileLink rules (a ProbeAck waits for a pending ReleaseAck on the same line). It keeps the
// uncore busy for timing runs and tests the L2 and DDR path on the board before the core exists.
module tg_trafgen
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
  output tr_rec_t [COMMIT_WIDTH-1:0]   trace_o,
  output logic    [COMMIT_WIDTH-1:0]   trace_valid_o,
  output tr_wb_t  [TRACE_WB_PORTS-1:0] trace_wb_o,
  output logic    [TRACE_WB_PORTS-1:0] trace_wb_valid_o,
  // control (from the host bridge) and results
  input  logic                         tg_en_i,
  input  logic [27:0]                  tg_base_i,    // first line (line address) of the region
  input  logic [23:0]                  tg_lines_i,   // lines in the region (>= 1)
  output logic [31:0]                  tg_ops_o,     // lines checked
  output logic [15:0]                  tg_errs_o,
  output logic [27:0]                  tg_err_line_o,
  output logic [15:0]                  tg_pass_o
);
  localparam int LW = PA_W - 6;

  function automatic logic [511:0] pattern(input logic [LW-1:0] line, input logic [15:0] pass);
    logic [511:0] p;
    logic [31:0]  x;
    x = {line[15:0], pass} ^ 32'(CORE_ID * 32'h9E37_79B9);
    for (int k = 0; k < 16; k++) begin
      x = x ^ (x << 13);
      x = x ^ (x >> 17);
      x = x ^ (x << 5);
      p[32*k +: 32] = x ^ 32'(line);
    end
    return p;
  endfunction

  typedef enum logic [3:0] {
    G_IDLE, G_ACQ, G_GRANT, G_ACK, G_REL, G_RACK, G_NEXT, G_UART, G_UART_D
  } gst_e;
  gst_e          st_q;
  logic          wpass_q;            // 1: write pass, 0: read pass
  logic [15:0]   pass_q;
  logic [23:0]   idx_q;
  logic [LW-1:0] line_q;
  logic [1:0]    beat_q;
  logic [511:0]  buf_q;
  logic          held_t_q;           // holding line_q in T (else B, or nothing outside G_GRANT..G_REL)
  logic          holding_q;
  logic          pass_err_q;
  logic [TL_SINK_W-1:0] sink_q;
  logic [31:0]   ops_q;
  logic [15:0]   errs_q;
  logic [27:0]   err_line_q;

  // Probe handling: one probe at a time; held while a Release for its line is unacknowledged.
  logic          pr_v_q;
  tl_b_t         pr_q;
  logic          pr_send;
  wire [LW-1:0]  pr_line = pr_q.address[PA_W-1:6];
  wire           rel_pending = st_q == G_RACK || st_q == G_REL;
  wire           pr_block = rel_pending && pr_line == line_q;
  wire           pr_hit   = holding_q && pr_line == line_q && st_q != G_GRANT && st_q != G_ACQ;

  // ---- A: Acquire ----
  always_comb begin
    l1d_a_o         = '0;
    l1d_a_o.opcode  = A_ACQUIRE_BLOCK;
    l1d_a_o.param   = wpass_q ? TL_GROW_N_TO_T : TL_GROW_N_TO_B;
    l1d_a_o.size    = 3'd6;
    l1d_a_o.source  = TL_SRC_W'(6'd1);
    l1d_a_o.address = {line_q, 6'd0};
    l1d_a_o.mask    = '1;
  end
  assign l1d_a_valid_o = st_q == G_ACQ;
  assign l1d_d_ready_o = 1'b1;
  assign l1d_b_ready_o = !pr_v_q;

  // ---- C: Release or ProbeAck (a ProbeAck never interrupts a ReleaseData in flight) ----
  logic       c_rel;                 // C carries our Release
  logic [1:0] c_beat_q;
  logic       c_busy_q;              // a multi-beat message is in progress
  logic       c_is_rel_q;
  always_comb begin
    c_rel   = (st_q == G_REL) && holding_q && (!c_busy_q || c_is_rel_q);
    pr_send = pr_v_q && !pr_block && !c_rel && (!c_busy_q || !c_is_rel_q);
  end
  always_comb begin
    l1d_c_o         = '0;
    l1d_c_o.size    = 3'd6;
    if (c_rel) begin
      l1d_c_o.opcode  = wpass_q ? C_RELEASE_DATA : C_RELEASE;
      l1d_c_o.param   = held_t_q ? TL_SHRINK_T_TO_N : TL_SHRINK_B_TO_N;   // a NtoB may be granted T
      l1d_c_o.source  = TL_SRC_W'(6'd2);
      l1d_c_o.address = {line_q, 6'd0};
      l1d_c_o.data    = buf_q[128*c_beat_q +: 128];
    end else begin
      l1d_c_o.source  = TL_SRC_W'(6'd3);
      l1d_c_o.address = pr_q.address;
      if (pr_hit && held_t_q) begin
        l1d_c_o.opcode = C_PROBE_ACK_DATA;
        l1d_c_o.param  = (pr_q.param == TL_CAP_TO_B) ? TL_SHRINK_T_TO_B : TL_SHRINK_T_TO_N;
        l1d_c_o.data   = buf_q[128*c_beat_q +: 128];
      end else if (pr_hit) begin
        l1d_c_o.opcode = C_PROBE_ACK;
        l1d_c_o.param  = (pr_q.param == TL_CAP_TO_B) ? TL_REPORT_B_TO_B : TL_SHRINK_B_TO_N;
      end else begin
        l1d_c_o.opcode = C_PROBE_ACK;
        l1d_c_o.param  = TL_REPORT_N_TO_N;
      end
    end
  end
  assign l1d_c_valid_o = c_rel || pr_send;
  wire   c_fire      = l1d_c_valid_o && l1d_c_ready_i;
  wire   c_data      = l1d_c_o.opcode == C_RELEASE_DATA || l1d_c_o.opcode == C_PROBE_ACK_DATA;
  wire   c_last      = !c_data || c_beat_q == 2'd3;

  // ---- E ----
  assign l1d_e_o.sink  = sink_q;
  assign l1d_e_valid_o = st_q == G_ACK;

  // ---- mmio: one UART byte per pass ----
  always_comb begin
    mmio_a_o         = '0;
    mmio_a_o.opcode  = A_PUT_FULL;
    mmio_a_o.size    = 3'd0;
    mmio_a_o.source  = TL_SRC_W'(6'd4);
    mmio_a_o.address = UART_BASE;
    mmio_a_o.mask    = 16'h0001;
    mmio_a_o.data    = {120'd0, pass_err_q ? 8'h45 : 8'h2E};
  end
  assign mmio_a_valid_o = st_q == G_UART;
  assign mmio_d_ready_o = 1'b1;

  // l1i unused
  assign l1i_a_o       = '0;
  assign l1i_a_valid_o = 1'b0;
  assign l1i_d_ready_o = 1'b1;

  // ---- sequencing ----
  wire [23:0] nlines = (tg_lines_i == '0) ? 24'd1 : tg_lines_i;
  always_ff @(posedge clk) begin
    if (rst) begin
      st_q       <= G_IDLE;
      wpass_q    <= 1'b1;
      pass_q     <= '0;
      idx_q      <= '0;
      holding_q  <= 1'b0;
      held_t_q   <= 1'b0;
      pass_err_q <= 1'b0;
      ops_q      <= '0;
      errs_q     <= '0;
      err_line_q <= '0;
      pr_v_q     <= 1'b0;
      c_busy_q   <= 1'b0;
      c_beat_q   <= '0;
    end else begin
      // probes in
      if (l1d_b_valid_i && l1d_b_ready_o) begin
        pr_v_q <= 1'b1;
        pr_q   <= l1d_b_i;
      end
      // C beats
      if (c_fire) begin
        if (c_last) begin
          c_busy_q <= 1'b0;
          c_beat_q <= '0;
          if (!c_rel) begin
            // ProbeAck sent: apply the probe to our copy
            pr_v_q <= 1'b0;
            if (pr_hit) begin
              if (pr_q.param == TL_CAP_TO_B) held_t_q <= 1'b0;
              else holding_q <= 1'b0;
            end
          end
        end else begin
          c_busy_q   <= 1'b1;
          c_is_rel_q <= c_rel;
          c_beat_q   <= c_beat_q + 1'b1;
        end
      end
      unique case (st_q)
        G_IDLE: if (tg_en_i) begin
          line_q <= tg_base_i;
          idx_q  <= '0;
          st_q   <= G_ACQ;
        end
        G_ACQ: if (l1d_a_ready_i) begin
          beat_q <= '0;
          st_q   <= G_GRANT;
        end
        G_GRANT: if (l1d_d_valid_i && (l1d_d_i.opcode == D_GRANT_DATA || l1d_d_i.opcode == D_GRANT)) begin
          buf_q[128*beat_q +: 128] <= l1d_d_i.data;
          beat_q <= beat_q + 1'b1;
          if (l1d_d_i.opcode == D_GRANT || beat_q == 2'd3) begin
            sink_q    <= l1d_d_i.sink;
            holding_q <= !l1d_d_i.denied;
            held_t_q  <= l1d_d_i.param == TL_CAP_TO_T[1:0];
            st_q      <= G_ACK;
          end
        end
        G_ACK: if (l1d_e_ready_i) begin
          if (wpass_q) begin
            buf_q <= pattern(line_q, pass_q);
          end else begin
            ops_q <= ops_q + 1'b1;
            if (buf_q != pattern(line_q, pass_q - 16'd1)) begin
              errs_q     <= (errs_q == '1) ? errs_q : errs_q + 1'b1;
              err_line_q <= 28'(line_q);
              pass_err_q <= 1'b1;
            end
          end
          st_q <= G_REL;
        end
        G_REL: if (!holding_q && !c_busy_q) begin
          st_q <= G_NEXT;                 // probed away before our Release: nothing to release
        end else if (c_fire && c_rel && c_last) begin
          holding_q <= 1'b0;
          st_q      <= G_RACK;
        end
        G_RACK: if (l1d_d_valid_i && l1d_d_i.opcode == D_RELEASE_ACK) st_q <= G_NEXT;
        G_NEXT: begin
          if (idx_q + 1'b1 >= nlines) begin
            idx_q  <= '0;
            line_q <= tg_base_i;
            if (wpass_q) begin
              wpass_q <= 1'b0;
              pass_q  <= pass_q + 1'b1;   // the read pass checks what this write pass wrote
              st_q    <= tg_en_i ? G_ACQ : G_IDLE;
            end else begin
              wpass_q <= 1'b1;
              st_q    <= G_UART;
            end
          end else begin
            idx_q  <= idx_q + 1'b1;
            line_q <= line_q + 1'b1;
            st_q   <= G_ACQ;
          end
        end
        G_UART: if (mmio_a_ready_i) st_q <= G_UART_D;
        G_UART_D: if (mmio_d_valid_i) begin
          pass_err_q <= 1'b0;
          st_q       <= tg_en_i ? G_ACQ : G_IDLE;
        end
        default: st_q <= G_IDLE;
      endcase
    end
  end

  assign tg_ops_o      = ops_q;
  assign tg_errs_o     = errs_q;
  assign tg_err_line_o = err_line_q;
  assign tg_pass_o     = pass_q;

  assign merr_o           = '0;
  assign trace_o          = '0;
  assign trace_valid_o    = '0;
  assign trace_wb_o       = '0;
  assign trace_wb_valid_o = '0;

  wire unused = ^{boot_addr_i, irq_mei_i, irq_sei_i, irq_mti_i, irq_msi_i, irq_ssi_i, mtime_i, debug_req_i,
                  l1i_a_ready_i, l1i_d_i, l1i_d_valid_i, mmio_d_i, l1d_d_i.source, l1d_d_i.size,
                  l1d_d_i.corrupt, pr_q.size, pr_q.source, pr_q.opcode, c_is_rel_q, tg_base_i};
endmodule
