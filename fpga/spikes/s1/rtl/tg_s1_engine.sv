// Spike S1: PL -> PS DDR traffic and latency engine, one AXI4 master (128-bit data,
// 49-bit addresses, 6-bit IDs: a Zynq UltraScale+ S_AXI_HPx_FPD port). Control and results
// through a 32-bit register port (tg_s1_top maps it on AXI-Lite).
//
// Modes (CTRL[5:4]):
//   0 read:  COUNT read bursts of BEATS beats; at most OUTST in flight. With CHASE the next
//            address is the first 8 bytes of the previous burst's data, a physical address
//            (a pointer chase; OUTST is then 1): idle load-to-use latency as the L2 sees it.
//   1 write: COUNT write bursts, same addressing; data is a counter pattern.
// Addressing: sequential (BASE + k * STRIDE) or random (an LFSR) within SIZE bytes (a power
// of two), aligned to the burst. Every transaction gets a free slot (ID 0..31) with its issue
// time; latency is counted from the address handshake to the first data beat (reads) or the
// write response (writes), in clock cycles. Results: min, max, sum, count, a 256-bin
// histogram (bin = latency >> HSHIFT, saturating), total cycles and bytes, error count.
//
// Registers (word offsets): 0 ID, 1 CTRL, 2 STATUS, 3 BEATS, 4 OUTST, 5 COUNT, 6 BASE_LO,
// 7 BASE_HI, 8 SIZE, 9 STRIDE, 10 SEED, 11 HSHIFT, 12/13 CYCLES, 14 LAT_MIN, 15 LAT_MAX,
// 16/17 LAT_SUM, 18 DONE_CNT, 19/20 BYTES, 21 ERRORS, 22 LAST_ADDR_LO, 23 LAST_ADDR_HI,
// 24 FIRST_ERR (resp); 256..511 histogram bins. CTRL: bit 0 start (self-clearing),
// bit 1 abort, bit 2 chase, bit 3 random, bits 5:4 mode.
module tg_s1_engine #(
  parameter int AW = 49,
  parameter int DW = 128,
  parameter int IW = 6,
  parameter int NSLOT = 32
) (
  input  logic          clk,
  input  logic          rst,
  // Register port (single cycle write; read data one cycle after rd_en)
  input  logic          reg_wr,
  input  logic          reg_rd,
  input  logic [8:0]    reg_addr,      // word address
  input  logic [31:0]   reg_wdata,
  output logic [31:0]   reg_rdata,
  // AXI4 master: read
  output logic [IW-1:0] arid,
  output logic [AW-1:0] araddr,
  output logic [7:0]    arlen,
  output logic [2:0]    arsize,
  output logic [1:0]    arburst,
  output logic          arlock,
  output logic [3:0]    arcache,
  output logic [2:0]    arprot,
  output logic [3:0]    arqos,
  output logic          arvalid,
  input  logic          arready,
  input  logic [IW-1:0] rid,
  input  logic [DW-1:0] rdata,
  input  logic [1:0]    rresp,
  input  logic          rlast,
  input  logic          rvalid,
  output logic          rready,
  // AXI4 master: write
  output logic [IW-1:0] awid,
  output logic [AW-1:0] awaddr,
  output logic [7:0]    awlen,
  output logic [2:0]    awsize,
  output logic [1:0]    awburst,
  output logic          awlock,
  output logic [3:0]    awcache,
  output logic [2:0]    awprot,
  output logic [3:0]    awqos,
  output logic          awvalid,
  input  logic          awready,
  output logic [DW-1:0] wdata,
  output logic [DW/8-1:0] wstrb,
  output logic          wlast,
  output logic          wvalid,
  input  logic          wready,
  input  logic [IW-1:0] bid,
  input  logic [1:0]    bresp,
  input  logic          bvalid,
  output logic          bready
);
  localparam int SW = $clog2(NSLOT);
  localparam int BEAT_BYTES = DW / 8;

  // ---- Registers ----
  logic        chase_q, random_q, mode_wr_q, busy_q, done_q, clearing_q;
  logic [7:0]  beats_q;          // burst length - 1
  logic [5:0]  outst_q;
  logic [31:0] count_q, size_q, stride_q, seed_q;
  logic [AW-1:0] base_q;
  logic [4:0]  hshift_q;
  logic [63:0] cycles_q, lat_sum_q, bytes_q;
  logic [31:0] lat_min_q, lat_max_q, done_cnt_q, errors_q;
  logic [AW-1:0] last_addr_q;
  logic [1:0]  first_err_q;
  logic        start, abort;
  assign start = reg_wr && reg_addr == 9'd1 && reg_wdata[0];
  assign abort = reg_wr && reg_addr == 9'd1 && reg_wdata[1];

  // ---- Time ----
  logic [31:0] now_q;
  always_ff @(posedge clk) now_q <= rst ? '0 : now_q + 1'b1;

  // ---- Address generation ----
  logic [31:0] issued_q, offset_q, lfsr_q;
  logic [AW-1:0] chase_addr_q, next_addr;
  logic chase_ready_q;
  logic [31:0] mask, align_mask;
  assign mask = size_q - 1'b1;
  assign align_mask = ~((32'(beats_q) + 1) * BEAT_BYTES - 1);
  logic [31:0] off_rnd, off_seq;
  assign off_rnd = lfsr_q & mask & align_mask;
  assign off_seq = offset_q & mask & align_mask;
  always_comb begin
    if (chase_q)       next_addr = chase_addr_q;
    else if (random_q) next_addr = base_q + {{(AW-32){1'b0}}, off_rnd};
    else               next_addr = base_q + {{(AW-32){1'b0}}, off_seq};
  end

  // ---- Slots ----
  logic [NSLOT-1:0]       slot_busy_q, slot_first_q;
  logic [NSLOT-1:0][31:0] slot_t_q;
  logic [5:0]             inflight_q;
  logic [SW-1:0]          free_slot;
  logic                   have_free;
  always_comb begin
    free_slot = '0;
    have_free = 1'b0;
    for (int i = NSLOT - 1; i >= 0; i--) begin
      if (!slot_busy_q[i]) begin
        free_slot = SW'(i);
        have_free = 1'b1;
      end
    end
  end

  logic can_issue;
  assign can_issue = busy_q && !clearing_q && issued_q < count_q && have_free
                  && inflight_q < (chase_q ? 6'd1 : outst_q)
                  && (!chase_q || chase_ready_q);

  // Read address channel
  assign arid    = IW'(free_slot);
  assign araddr  = next_addr;
  assign arlen   = beats_q;
  assign arsize  = 3'($clog2(BEAT_BYTES));
  assign arburst = 2'b01;
  assign arlock  = 1'b0;
  assign arcache = 4'b0011;
  assign arprot  = 3'b000;
  assign arqos   = 4'h0;
  assign arvalid = can_issue && !mode_wr_q;
  assign rready  = 1'b1;

  // Write channels: one burst at a time on W, AW may run ahead by the slot limit
  logic [7:0]  w_beat_q;
  logic [31:0] w_pending_q;   // bursts whose address went out and data did not finish
  assign awid    = IW'(free_slot);
  assign awaddr  = next_addr;
  assign awlen   = beats_q;
  assign awsize  = 3'($clog2(BEAT_BYTES));
  assign awburst = 2'b01;
  assign awlock  = 1'b0;
  assign awcache = 4'b0011;
  assign awprot  = 3'b000;
  assign awqos   = 4'h0;
  assign awvalid = can_issue && mode_wr_q;
  assign wvalid  = w_pending_q != 0;
  assign wlast   = w_beat_q == beats_q;
  assign wstrb   = '1;
  assign wdata   = {DW/32{now_q}};
  assign bready  = 1'b1;

  logic ar_go, aw_go, w_go, w_done;
  assign ar_go  = arvalid && arready;
  assign aw_go  = awvalid && awready;
  assign w_go   = wvalid && wready;
  assign w_done = w_go && wlast;

  // ---- Completions: latency samples ----
  logic        smp_v;
  logic [31:0] smp_lat;
  logic        r_first;
  assign r_first = rvalid && !slot_first_q[rid[SW-1:0]];
  always_comb begin
    smp_v = 1'b0;
    smp_lat = '0;
    if (!mode_wr_q && r_first) begin
      smp_v = 1'b1;
      smp_lat = now_q - slot_t_q[rid[SW-1:0]];
    end else if (mode_wr_q && bvalid) begin
      smp_v = 1'b1;
      smp_lat = now_q - slot_t_q[bid[SW-1:0]];
    end
  end
  logic fin;          // a transaction finished this cycle
  logic [SW-1:0] fin_slot;
  assign fin      = mode_wr_q ? bvalid : (rvalid && rlast);
  assign fin_slot = mode_wr_q ? bid[SW-1:0] : rid[SW-1:0];
  logic resp_err;
  assign resp_err = (rvalid && rresp[1]) || (bvalid && bresp[1]);

  // ---- Histogram: BRAM read-modify-write, one sample per cycle, with forwarding ----
  logic [7:0]  h_bin, b_bin_q, c_bin_q, clr_idx_q;
  logic        b_v_q, c_v_q;
  logic [31:0] h_rd, b_cnt, c_cnt_q;
  logic [31:0] hshifted;
  assign hshifted = smp_lat >> hshift_q;
  assign h_bin = (hshifted > 32'd255) ? 8'd255 : hshifted[7:0];
  logic        reg_hist_rd;
  assign reg_hist_rd = reg_rd && reg_addr[8];
  tg_ram_sdp #(.DEPTH(256), .WIDTH(32), .OUT_REG(1'b0), .PRIM("block")) u_hist (
    .clk, .we(clearing_q || c_v_q), .waddr(clearing_q ? clr_idx_q : c_bin_q),
    .wdata(clearing_q ? 32'd0 : c_cnt_q), .re(1'b1),
    .raddr(smp_v ? h_bin : reg_addr[7:0]), .rdata(h_rd));
  // Stage B: the bin's count as read; forward the write of the previous sample
  assign b_cnt = (c_v_q && c_bin_q == b_bin_q) ? c_cnt_q : h_rd;
  always_ff @(posedge clk) begin
    b_v_q   <= smp_v && busy_q;
    b_bin_q <= h_bin;
    c_v_q   <= b_v_q;
    c_bin_q <= b_bin_q;
    c_cnt_q <= b_cnt + 1'b1;
  end

  // ---- Control and statistics ----
  always_ff @(posedge clk) begin
    if (rst) begin
      busy_q <= 1'b0; done_q <= 1'b0; clearing_q <= 1'b0;
      chase_q <= 1'b0; random_q <= 1'b0; mode_wr_q <= 1'b0;
      beats_q <= 8'd3; outst_q <= 6'd1; count_q <= 32'd1000; size_q <= 32'h0100_0000;
      stride_q <= 32'd64; seed_q <= 32'h1234_5678; base_q <= '0; hshift_q <= '0;
      slot_busy_q <= '0; inflight_q <= '0; w_pending_q <= '0; w_beat_q <= '0;
    end else begin
      if (reg_wr && !busy_q) begin
        unique case (reg_addr)
          9'd1:  begin chase_q <= reg_wdata[2]; random_q <= reg_wdata[3];
                       mode_wr_q <= reg_wdata[4]; end
          9'd3:  beats_q  <= reg_wdata[7:0];
          9'd4:  outst_q  <= (reg_wdata[5:0] > 6'(NSLOT)) ? 6'(NSLOT) :
                             (reg_wdata[5:0] == 0 ? 6'd1 : reg_wdata[5:0]);
          9'd5:  count_q  <= reg_wdata;
          9'd6:  base_q[31:0] <= reg_wdata;
          9'd7:  base_q[AW-1:32] <= reg_wdata[AW-33:0];
          9'd8:  size_q   <= reg_wdata;
          9'd9:  stride_q <= reg_wdata;
          9'd10: seed_q   <= reg_wdata;
          9'd11: hshift_q <= reg_wdata[4:0];
          default: ;
        endcase
      end
      if (start && !busy_q) begin
        busy_q <= 1'b1; done_q <= 1'b0; clearing_q <= 1'b1; clr_idx_q <= '0;
        issued_q <= '0; offset_q <= '0; lfsr_q <= seed_q | 32'd1;
        chase_addr_q <= base_q; chase_ready_q <= 1'b1;
        cycles_q <= '0; lat_sum_q <= '0; bytes_q <= '0; lat_min_q <= '1; lat_max_q <= '0;
        done_cnt_q <= '0; errors_q <= '0; first_err_q <= '0;
      end else if (busy_q) begin
        if (clearing_q) begin
          clr_idx_q <= clr_idx_q + 1'b1;
          if (clr_idx_q == 8'd255) clearing_q <= 1'b0;
        end else begin
          cycles_q <= cycles_q + 1'b1;
        end
        if (abort || (!clearing_q && issued_q == count_q && inflight_q == 0)) begin
          busy_q <= 1'b0;
          done_q <= 1'b1;
        end
      end
      // Issue
      if (ar_go || aw_go) begin
        issued_q <= issued_q + 1'b1;
        offset_q <= offset_q + stride_q;
        lfsr_q   <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
        last_addr_q <= next_addr;
        slot_busy_q[free_slot]  <= 1'b1;
        slot_first_q[free_slot] <= 1'b0;
        slot_t_q[free_slot]     <= now_q;
        if (chase_q) chase_ready_q <= 1'b0;
      end
      if (aw_go && !w_done)      w_pending_q <= w_pending_q + 1'b1;
      else if (w_done && !aw_go) w_pending_q <= w_pending_q - 1'b1;
      if (w_go) w_beat_q <= wlast ? 8'd0 : w_beat_q + 1'b1;
      // Responses
      if (r_first && !mode_wr_q) begin
        slot_first_q[rid[SW-1:0]] <= 1'b1;
        if (chase_q) begin
          // the node's first 8 bytes: the next node's physical address
          chase_addr_q  <= rdata[AW-1:0] & ~AW'(BEAT_BYTES - 1);
          chase_ready_q <= 1'b1;
        end
      end
      if (rvalid || w_go) bytes_q <= bytes_q + 64'(BEAT_BYTES);
      if (fin) begin
        slot_busy_q[fin_slot] <= 1'b0;
      end
      inflight_q <= inflight_q + ((ar_go || aw_go) ? 6'd1 : 6'd0) - (fin ? 6'd1 : 6'd0);
      if (smp_v && busy_q) begin
        done_cnt_q <= done_cnt_q + 1'b1;
        lat_sum_q  <= lat_sum_q + {32'd0, smp_lat};
        if (smp_lat < lat_min_q) lat_min_q <= smp_lat;
        if (smp_lat > lat_max_q) lat_max_q <= smp_lat;
      end
      if (resp_err) begin
        errors_q <= errors_q + 1'b1;
        if (errors_q == 0) first_err_q <= rvalid ? rresp : bresp;
      end
    end
  end

  // ---- Register reads (one cycle) ----
  logic [8:0] rd_addr_q;
  always_ff @(posedge clk) begin
    if (reg_rd) rd_addr_q <= reg_addr;
  end
  always_comb begin
    unique case (rd_addr_q)
      9'd0:  reg_rdata = 32'h7153_0001;
      9'd1:  reg_rdata = {26'd0, mode_wr_q, 1'b0, random_q, chase_q, 2'b00};
      9'd2:  reg_rdata = {29'd0, errors_q != 0, done_q, busy_q};
      9'd3:  reg_rdata = {24'd0, beats_q};
      9'd4:  reg_rdata = {26'd0, outst_q};
      9'd5:  reg_rdata = count_q;
      9'd6:  reg_rdata = base_q[31:0];
      9'd7:  reg_rdata = 32'(base_q[AW-1:32]);
      9'd8:  reg_rdata = size_q;
      9'd9:  reg_rdata = stride_q;
      9'd10: reg_rdata = seed_q;
      9'd11: reg_rdata = {27'd0, hshift_q};
      9'd12: reg_rdata = cycles_q[31:0];
      9'd13: reg_rdata = cycles_q[63:32];
      9'd14: reg_rdata = lat_min_q;
      9'd15: reg_rdata = lat_max_q;
      9'd16: reg_rdata = lat_sum_q[31:0];
      9'd17: reg_rdata = lat_sum_q[63:32];
      9'd18: reg_rdata = done_cnt_q;
      9'd19: reg_rdata = bytes_q[31:0];
      9'd20: reg_rdata = bytes_q[63:32];
      9'd21: reg_rdata = errors_q;
      9'd22: reg_rdata = last_addr_q[31:0];
      9'd23: reg_rdata = 32'(last_addr_q[AW-1:32]);
      9'd24: reg_rdata = {30'd0, first_err_q};
      default: reg_rdata = rd_addr_q[8] ? h_rd : 32'hdead_beef;
    endcase
  end

  logic unused;
  assign unused = ^{rdata[DW-1:AW], reg_hist_rd, rid[IW-1:SW], bid[IW-1:SW]};
endmodule
