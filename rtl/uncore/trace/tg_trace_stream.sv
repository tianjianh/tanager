// Commit-trace streaming into a DDR ring (docs/spec/uncore-trace.md): every record of every core,
// none lost, for the lockstep checker on the A53 and as the post-mortem trace.
// Per core: one LUTRAM FIFO per trace port (COMMIT_WIDTH retire lanes, TRACE_WB_PORTS writeback
// lanes) and an order FIFO of per-cycle valid masks; the drain replays each cycle's records in
// lane order. One AXI writer, shared by the cores, writes each record as a 64-byte burst.
// trace_stall_o follows interfaces.md §5, per lane.
module tg_trace_stream
  import tg_pkg::*, tg_trace_pkg::*, tg_uncore_pkg::*;
#(
  parameter int N_CORES = NUM_CORES
) (
  input  logic                                        clk,
  input  logic                                        rst,
  input  tr_rec_t [N_CORES-1:0][COMMIT_WIDTH-1:0]     trace_i,
  input  logic    [N_CORES-1:0][COMMIT_WIDTH-1:0]     trace_valid_i,
  input  tr_wb_t  [N_CORES-1:0][TRACE_WB_PORTS-1:0]   trace_wb_i,
  input  logic    [N_CORES-1:0][TRACE_WB_PORTS-1:0]   trace_wb_valid_i,
  output logic    [N_CORES-1:0]                       trace_stall_o,

  // configuration (from the host; quasi-static except rp)
  input  logic                                        enable_i,
  input  logic                                        wrap_i,
  input  logic                                        stop_arm_i,
  input  logic [63:0]                                 stop_pc_i,
  input  logic [15:0]                                 post_i,
  input  logic                                        start_arm_i,
  input  logic [63:0]                                 start_pc_i,
  input  logic [AXI_ADDR_W-1:0]                       base_i,        // 64-byte aligned
  input  logic [4:0]                                  size_log2_i,   // ring of 2^n records
  input  logic [63:0]                                 rp_i,          // records consumed

  // status
  output logic [63:0]                                 wp_o,          // records written and complete
  output logic                                        capturing_o,
  output logic                                        started_o,
  output logic                                        stopped_o,
  output logic                                        full_o,        // waiting for the consumer
  output logic                                        axi_err_o,
  output logic [15:0]                                 buffered_o,    // records in the lanes
  output logic [31:0]                                 stall_cycles_o,

  // AXI4 write master (one ID, bursts of four 128-bit beats)
  output axi_ax_t                                     aw_o,
  output logic                                        aw_valid_o,
  input  logic                                        aw_ready_i,
  output axi_w_t                                      w_o,
  output logic                                        w_valid_o,
  input  logic                                        w_ready_i,
  input  axi_b_t                                      b_i,
  input  logic                                        b_valid_i,
  output logic                                        b_ready_o
);
  localparam int CW   = COMMIT_WIDTH;
  localparam int NWB  = TRACE_WB_PORTS;
  localparam int NL   = CW + NWB;                                   // lanes per core
  localparam int BD   = (LLT_ENTRIES + 2 * CW + 2 <= 32) ? 32 : 64; // lane depth
  localparam int BAW  = $clog2(BD);
  localparam int OD   = 64;                                         // order FIFO depth
  localparam int OAW  = $clog2(OD);
  localparam int WBR  = $bits(tr_wb_t);
  localparam int LW   = idx_w(NL);
  localparam int CIW  = idx_w(N_CORES);
  localparam int MAX_OUT = 16;                                      // records in flight on AXI
  // Stall thresholds (free entries), interfaces.md §5 applied per lane
  localparam int TH_RET = 2;
  localparam int TH_WB  = LLT_ENTRIES + 2 * CW;
  localparam int TH_ORD = LLT_ENTRIES + 2 * CW + 2;

  if (TH_WB >= BD || TH_ORD >= OD) begin : g_bad_depth
    $error("tg_trace_stream: lane or order FIFO too shallow for the stall headroom");
  end

  // The 320-bit record of docs/spec/host.md §Trace ring
  function automatic logic [319:0] pack_rec(input tr_rec_t r);
    logic [319:0] x;
    x = '0;
    x[1:0]     = r.kind;
    x[3:2]     = 2'(r.hart);
    x[5:4]     = r.priv;
    x[6]       = r.rvc;
    x[7]       = r.rd_we;
    x[8]       = r.rd_fp;
    x[13:9]    = r.rd;
    x[14]      = r.rd_deferred;
    x[19:15]   = 5'(r.wb_tag);
    x[20]      = r.mem_st;
    x[22:21]   = r.mem_size;
    x[23]      = r.mmio_ld;
    x[24]      = r.nondet;
    x[63:32]   = r.insn;
    x[127:64]  = r.pc;
    x[191:128] = (r.kind == TR_RETIRE) ? r.rd_value : r.cause;
    x[255:192] = (r.kind == TR_TRAP) ? r.tval : r.mem_vaddr;
    x[319:256] = r.mem_wdata;
    return x;
  endfunction

  function automatic logic [319:0] pack_wb(input tr_wb_t w);
    logic [319:0] x;
    x = '0;
    x[1:0]     = 2'd3;
    x[3:2]     = 2'(w.hart);
    x[8]       = w.rd_fp;
    x[13:9]    = w.rd;
    x[19:15]   = 5'(w.wb_tag);
    x[191:128] = w.value;
    return x;
  endfunction

  function automatic logic [LW-1:0] lowest(input logic [NL-1:0] m);
    logic [LW-1:0] r;
    r = '0;
    for (int i = NL - 1; i >= 0; i--) if (m[i]) r = LW'(i);
    return r;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Capture control (all cores)
  // ---------------------------------------------------------------------------------------------
  logic        en_q, started_q, stopped_q, trig_seen_q;
  logic [15:0] post_left_q;
  logic [31:0] cycle_q;
  wire         active = en_q && !stopped_q;                // capture may run
  wire         live   = active && started_q;               // records are taken

  // Start trigger: the first matching retire/trap/interrupt record, and the later slots of its cycle
  logic                         start_hit;
  logic [N_CORES-1:0][CW-1:0]   start_from;                // slots taken in the start cycle
  always_comb begin
    start_hit  = 1'b0;
    start_from = '0;
    for (int c = 0; c < N_CORES; c++) begin
      logic seen;
      seen = 1'b0;
      for (int k = 0; k < CW; k++) begin
        if (trace_valid_i[c][k] && trace_i[c][k].pc == start_pc_i) seen = 1'b1;
        start_from[c][k] = seen;
      end
      if (seen) start_hit = 1'b1;
    end
  end
  wire starting = active && !started_q && start_hit;

  // Records taken this cycle, per core and lane
  logic [N_CORES-1:0][NL-1:0] take;
  always_comb begin
    for (int c = 0; c < N_CORES; c++)
      for (int l = 0; l < NL; l++) begin
        if (l < CW) take[c][l] = trace_valid_i[c][l] && (live || (starting && start_from[c][l]));
        else        take[c][l] = trace_wb_valid_i[c][l - CW] && live;
      end
  end

  // Stop trigger (cycle granularity: the cycle that reaches POST is kept whole)
  logic       stop_hit;
  logic [7:0] n_taken;
  always_comb begin
    stop_hit = 1'b0;
    n_taken  = '0;
    for (int c = 0; c < N_CORES; c++) begin
      for (int k = 0; k < CW; k++)
        if (take[c][k] && trace_i[c][k].pc == stop_pc_i) stop_hit = 1'b1;
      for (int l = 0; l < NL; l++) n_taken = n_taken + 8'(take[c][l]);
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Lanes and order FIFOs, per core
  // ---------------------------------------------------------------------------------------------
  typedef struct packed {
    logic [31:0]   stamp;     // low cycle count of the cycle
    logic [NL-1:0] mask;      // lanes holding a record of that cycle
  } ord_t;

  logic [N_CORES-1:0]                 rec_v;          // a record is ready at the head
  logic [N_CORES-1:0][319:0]          rec;            // that record
  logic [N_CORES-1:0][31:0]           rec_stamp;
  logic [N_CORES-1:0]                 done;           // the writer finished the head record
  logic [N_CORES-1:0][15:0]           n_buf;          // records held per core

  for (genvar c = 0; c < N_CORES; c++) begin : g_core
    logic [NL-1:0][BAW:0]   lwp_q, lrp_q;
    logic [OAW:0]           owp_q, orp_q;
    logic [NL-1:0][319:0]   head;
    logic [NL-1:0]          lane_ok;                  // free entries above the lane's threshold

    for (genvar l = 0; l < NL; l++) begin : g_lane
      wire [BAW:0] used = lwp_q[l] - lrp_q[l];
      if (l < CW) begin : g_ret
        logic [0:0][319:0] rd;
        tg_ram_lut #(.DEPTH (BD), .WIDTH (320), .NR (1)) u_lane (
          .clk, .we (take[c][l]), .waddr (lwp_q[l][BAW-1:0]), .wdata (pack_rec(trace_i[c][l])),
          .raddr (lrp_q[l][BAW-1:0]), .rdata (rd)
        );
        assign head[l]    = rd[0];
        assign lane_ok[l] = (BD - int'(used)) >= TH_RET;
      end else begin : g_wb
        logic [0:0][WBR-1:0] rd;
        tg_ram_lut #(.DEPTH (BD), .WIDTH (WBR), .NR (1)) u_lane (
          .clk, .we (take[c][l]), .waddr (lwp_q[l][BAW-1:0]), .wdata (trace_wb_i[c][l - CW]),
          .raddr (lrp_q[l][BAW-1:0]), .rdata (rd)
        );
        assign head[l]    = pack_wb(rd[0]);
        assign lane_ok[l] = (BD - int'(used)) >= TH_WB;
      end
    end

    // order FIFO
    ord_t         ord_in;
    logic [0:0][$bits(ord_t)-1:0] ord_rd;
    ord_t         ord_head;
    wire          ord_push = |take[c];
    wire [OAW:0]  ord_used = owp_q - orp_q;
    assign ord_in   = '{stamp: cycle_q, mask: take[c]};
    tg_ram_lut #(.DEPTH (OD), .WIDTH ($bits(ord_t)), .NR (1)) u_order (
      .clk, .we (ord_push), .waddr (owp_q[OAW-1:0]), .wdata (ord_in), .raddr (orp_q[OAW-1:0]), .rdata (ord_rd)
    );
    assign ord_head = ord_rd[0];

    // drain: the remaining lanes of the cycle being replayed, else the order FIFO's head
    logic [NL-1:0] cur_mask_q;
    logic          cur_v_q;
    logic [31:0]   cur_stamp_q;
    wire           ord_v     = owp_q != orp_q;
    wire [NL-1:0]  eff_mask  = cur_v_q ? cur_mask_q : ord_head.mask;
    wire [31:0]    eff_stamp = cur_v_q ? cur_stamp_q : ord_head.stamp;
    wire [LW-1:0]  lane      = lowest(eff_mask);
    assign rec_v[c]     = cur_v_q || ord_v;
    assign rec[c]       = head[lane];
    assign rec_stamp[c] = eff_stamp;

    always_ff @(posedge clk) begin
      if (rst) begin
        lwp_q    <= '0;
        lrp_q    <= '0;
        owp_q   <= '0;
        orp_q   <= '0;
        cur_v_q <= 1'b0;
      end else begin
        for (int l = 0; l < NL; l++) if (take[c][l]) lwp_q[l] <= lwp_q[l] + 1'b1;
        if (ord_push) owp_q <= owp_q + 1'b1;
        if (done[c]) begin
          logic [NL-1:0] rest;
          rest = eff_mask & ~(NL'(1) << lane);
          lrp_q[lane]  <= lrp_q[lane] + 1'b1;
          if (!cur_v_q) orp_q <= orp_q + 1'b1;     // the head entry is now being replayed
          cur_mask_q  <= rest;
          cur_v_q     <= rest != '0;
          cur_stamp_q <= eff_stamp;
        end
      end
    end

    always_comb begin
      int n;
      n = 0;
      for (int l = 0; l < NL; l++) begin
        logic [BAW:0] d;
        d = lwp_q[l] - lrp_q[l];
        n += int'(d);
      end
      n_buf[c] = 16'(n);
    end

    // Stall while capture can run: a lane or the order FIFO is near full (interfaces.md §5)
    assign trace_stall_o[c] = active && (!(&lane_ok) || (OD - int'(ord_used)) < TH_ORD);

`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst) begin
      for (int l = 0; l < NL; l++)
        if (take[c][l]) assert (lwp_q[l] - lrp_q[l] < (BAW+1)'(BD))
          else $error("tg_trace_stream: core %0d lane %0d overflow", c, l);
      if (ord_push) assert (int'(ord_used) < OD) else $error("tg_trace_stream: core %0d order FIFO overflow", c);
      if (rec_v[c]) assert (eff_mask != '0) else $error("tg_trace_stream: empty order entry");
    end
`endif
  end

  // ---------------------------------------------------------------------------------------------
  // AXI writer: one record (64 bytes, four beats) at a time, cores in round-robin
  // ---------------------------------------------------------------------------------------------
  logic           busy_q, aw_done_q, w_done_q;
  logic [1:0]     beat_q;
  logic [CIW-1:0] core_q, rr_q;
  logic [63:0]    issued_q, wp_q;
  logic [4:0]     out_q;                  // records issued whose B has not returned
  logic           err_q;

  wire [31:0] ring_used = issued_q[31:0] - rp_i[31:0];
  wire        room      = (wrap_i || ring_used < (32'(1) << size_log2_i)) && int'(out_q) < MAX_OUT;
  assign full_o = !wrap_i && ring_used >= (32'(1) << size_log2_i);

  logic [CIW-1:0] pick;
  logic           pick_v;
  always_comb begin
    pick   = '0;
    pick_v = 1'b0;
    for (int k = N_CORES - 1; k >= 0; k--) begin
      logic [CIW-1:0] c;
      c = CIW'((int'(rr_q) + k) % N_CORES);
      if (rec_v[c]) begin
        pick   = c;
        pick_v = 1'b1;
      end
    end
  end

  wire [319:0] wrec   = rec[core_q];
  wire [31:0]  wstamp = rec_stamp[core_q];
  wire         aw_hs  = aw_valid_o && aw_ready_i;
  wire         w_hs   = w_valid_o && w_ready_i;
  wire         w_last = w_hs && beat_q == 2'd3;
  wire         rec_done = busy_q && (aw_done_q || aw_hs) && (w_done_q || w_last);

  wire [25:0] idx_mask = (26'(1) << size_log2_i) - 26'd1;      // ring index bits
  always_comb begin
    aw_o       = '0;
    aw_o.addr  = base_i + (AXI_ADDR_W'(issued_q[25:0] & idx_mask) << 6);
    aw_o.len   = 8'd3;
    aw_o.size  = 3'd4;
    aw_o.burst = AXI_INCR;
  end
  assign aw_valid_o = busy_q && !aw_done_q;

  always_comb begin
    w_o      = '0;
    w_o.strb = '1;
    w_o.last = beat_q == 2'd3;
    unique case (beat_q)
      2'd0: w_o.data = wrec[127:0];
      2'd1: w_o.data = wrec[255:128];
      2'd2: w_o.data = {32'd0, wstamp, wrec[319:256]};
      default: w_o.data = '0;
    endcase
  end
  assign w_valid_o = busy_q && !w_done_q;
  assign b_ready_o = 1'b1;

  always_comb begin
    done = '0;
    if (rec_done) done[core_q] = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      busy_q   <= 1'b0;
      rr_q     <= '0;
      issued_q <= '0;
      wp_q     <= '0;
      out_q    <= '0;
      err_q    <= 1'b0;
    end else begin
      if (!busy_q) begin
        if (pick_v && room) begin
          busy_q    <= 1'b1;
          core_q    <= pick;
          aw_done_q <= 1'b0;
          w_done_q  <= 1'b0;
          beat_q    <= 2'd0;
          rr_q      <= (int'(pick) == N_CORES - 1) ? '0 : pick + 1'b1;
        end
      end else begin
        if (aw_hs) aw_done_q <= 1'b1;
        if (w_hs) begin
          beat_q <= beat_q + 1'b1;
          if (beat_q == 2'd3) w_done_q <= 1'b1;
        end
        if (rec_done) busy_q <= 1'b0;
      end
      if (aw_hs) issued_q <= issued_q + 1'b1;
      out_q <= out_q + 5'(aw_hs) - 5'(b_valid_i);
      if (b_valid_i) begin
        wp_q <= wp_q + 1'b1;
        if (b_i.resp != AXI_OKAY) err_q <= 1'b1;
      end
      // A new capture restarts the counters; the host starts one only when the stream is idle
      // (TRS_STATUS: nothing buffered, WP = issued). Disabling stops taking records only.
      if (enable_i && !en_q) begin
        issued_q <= '0;
        wp_q     <= '0;
        err_q    <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Capture state and counters
  // ---------------------------------------------------------------------------------------------
  logic [31:0] stall_cyc_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      en_q        <= 1'b0;
      started_q   <= 1'b0;
      stopped_q   <= 1'b0;
      trig_seen_q <= 1'b0;
      post_left_q <= '0;
      cycle_q     <= '0;
      stall_cyc_q <= '0;
    end else begin
      cycle_q <= cycle_q + 1'b1;
      en_q    <= enable_i;
      if (enable_i && !en_q) begin
        started_q   <= !start_arm_i;
        stopped_q   <= 1'b0;
        trig_seen_q <= 1'b0;
        stall_cyc_q <= '0;
      end else begin
        if (starting) started_q <= 1'b1;
        if (|trace_stall_o) stall_cyc_q <= stall_cyc_q + 1'b1;
        if (stop_arm_i && live) begin
          if (!trig_seen_q && stop_hit) begin
            trig_seen_q <= 1'b1;
            post_left_q <= post_i;
            if (post_i == '0) stopped_q <= 1'b1;
          end else if (trig_seen_q) begin
            if (post_left_q <= 16'(n_taken)) stopped_q <= 1'b1;
            else post_left_q <= post_left_q - 16'(n_taken);
          end
        end
      end
    end
  end

  always_comb begin
    int n;
    n = 0;
    for (int c = 0; c < N_CORES; c++) n += int'(n_buf[c]);
    buffered_o = 16'(n);
  end
  assign wp_o           = wp_q;
  assign capturing_o    = live;
  assign started_o      = started_q;
  assign stopped_o      = stopped_q;
  assign axi_err_o      = err_q;
  assign stall_cycles_o = stall_cyc_q;

  wire unused = ^{b_i.id, rp_i[63:32]};

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (!rst) begin
    if (b_valid_i) assert (out_q != '0) else $error("tg_trace_stream: B without an outstanding write");
  end
`endif
endmodule
