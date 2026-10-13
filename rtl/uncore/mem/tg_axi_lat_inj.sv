// Latency injector (docs/spec/uncore-mem.md, plan §5.6): between an L2 bank's AXI master and the
// DRAM window. Reads get a slot at AR time; R beats from downstream are always accepted into the
// slot's buffer and released in issue order once complete and due:
//   mode 0: now - t_issue >= rd_delay     (delivered latency = max(native, rd_delay))
//   mode 1: now - t_arrival >= rd_delay   (delivered latency = native + rd_delay)
// Write responses are held until wr_delay after their AW. A token bucket can cap released read
// beats (bw_rate/256 beats per cycle; 0 = no cap). Native read latency is measured per burst.
// Requires IDs unique among outstanding reads and among outstanding writes (the L2 uses MSHR ids).
module tg_axi_lat_inj
  import tg_pkg::*, tg_uncore_pkg::*;
#(
  parameter int SLOTS = 32,
  parameter int BEATS = 4
) (
  input  logic        clk,
  input  logic        rst,
  // configuration
  input  logic [9:0]  rd_delay_i,
  input  logic [9:0]  wr_delay_i,
  input  logic        mode_i,
  input  logic [8:0]  bw_rate_i,
  // statistics
  output logic [31:0] st_rd_count_o,
  output logic [31:0] st_lat_sum_o,
  output logic [15:0] st_lat_max_o,
  // upstream (slave side, from the L2)
  input  axi_ax_t     s_ar_i,
  input  logic        s_ar_valid_i,
  output logic        s_ar_ready_o,
  output axi_r_t      s_r_o,
  output logic        s_r_valid_o,
  input  logic        s_r_ready_i,
  input  axi_ax_t     s_aw_i,
  input  logic        s_aw_valid_i,
  output logic        s_aw_ready_o,
  input  axi_w_t      s_w_i,
  input  logic        s_w_valid_i,
  output logic        s_w_ready_o,
  output axi_b_t      s_b_o,
  output logic        s_b_valid_o,
  input  logic        s_b_ready_i,
  // downstream (master side)
  output axi_ax_t     m_ar_o,
  output logic        m_ar_valid_o,
  input  logic        m_ar_ready_i,
  input  axi_r_t      m_r_i,
  input  logic        m_r_valid_i,
  output logic        m_r_ready_o,
  output axi_ax_t     m_aw_o,
  output logic        m_aw_valid_o,
  input  logic        m_aw_ready_i,
  output axi_w_t      m_w_o,
  output logic        m_w_valid_o,
  input  logic        m_w_ready_i,
  input  axi_b_t      m_b_i,
  input  logic        m_b_valid_i,
  output logic        m_b_ready_o
);
  localparam int SW  = idx_w(SLOTS);
  localparam int BW  = idx_w(BEATS);
  localparam int NID = 1 << AXI_ID_W;

  logic [15:0] now_q;

  // ---------------------------------------------------------------------------------------------
  // Read slots
  // ---------------------------------------------------------------------------------------------
  logic [SLOTS-1:0]    free_q, done_q;
  logic [15:0]         t_iss_q [SLOTS];
  logic [15:0]         t_arr_q [SLOTS];
  logic [AXI_ID_W-1:0] sid_q   [SLOTS];
  logic [BW-1:0]       slen_q  [SLOTS];     // beats - 1
  logic [BW-1:0]       scnt_q  [SLOTS];     // beats received
  logic [SW-1:0]       id2slot_q [NID];

  logic [SW-1:0] alloc;
  always_comb begin
    alloc = '0;
    for (int i = SLOTS - 1; i >= 0; i--) if (free_q[i]) alloc = SW'(i);
  end

  // Issue-order queue of slots
  logic [SW-1:0] oq_q [SLOTS];
  logic [SW:0]   oq_wp_q, oq_rp_q;
  wire           oq_empty = oq_wp_q == oq_rp_q;
  wire [SW-1:0]  head     = oq_q[oq_rp_q[SW-1:0]];

  assign m_ar_o       = s_ar_i;
  assign m_ar_valid_o = s_ar_valid_i && |free_q;
  assign s_ar_ready_o = m_ar_ready_i && |free_q;
  wire   ar_fire      = s_ar_valid_i && s_ar_ready_o;

  // R beats from downstream into the slot buffer
  assign m_r_ready_o = 1'b1;
  wire [SW-1:0] r_slot = id2slot_q[m_r_i.id];
  wire          r_fire = m_r_valid_i;

  logic                 buf_we;
  logic [SW+BW-1:0]     buf_waddr, buf_raddr;
  logic [AXI_DATA_W+1:0] buf_wdata, buf_rdata;
  logic                 buf_re;
  tg_ram_sdp #(.DEPTH(SLOTS * BEATS), .WIDTH(AXI_DATA_W + 2), .OUT_REG(1'b0), .PRIM("block")) u_buf (
    .clk, .we (buf_we), .waddr (buf_waddr), .wdata (buf_wdata), .re (buf_re), .raddr (buf_raddr), .rdata (buf_rdata)
  );
  assign buf_we    = r_fire;
  assign buf_waddr = {r_slot, scnt_q[r_slot]};
  assign buf_wdata = {m_r_i.resp, m_r_i.data};

  // ---------------------------------------------------------------------------------------------
  // Release engine: the oldest slot, when complete and due; one beat read per cycle into a
  // 2-entry output buffer, gated by the bandwidth tokens.
  // ---------------------------------------------------------------------------------------------
  logic [10:0] tokens_q;
  wire         bw_cap  = bw_rate_i != '0;
  wire         tok_ok  = !bw_cap || tokens_q >= 11'd256;

  wire [15:0] el_iss = now_q - t_iss_q[head];
  wire [15:0] el_arr = now_q - t_arr_q[head];
  wire        due    = mode_i ? (el_arr >= 16'(rd_delay_i)) : (el_iss >= 16'(rd_delay_i));

  logic          rel_q;              // releasing the head slot
  logic [BW-1:0] rel_beat_q;         // next beat to read
  logic          pend_q;             // a read issued last cycle, data now on buf_rdata
  logic          pend_last_q;
  logic [SW-1:0] pend_slot_q;

  // Output buffer (2 entries)
  axi_r_t ob_in;
  logic   ob_in_v, ob_in_r;
  logic [1:0] ob_cnt;
  tg_fifo #(.T(axi_r_t), .DEPTH(2)) u_ob (
    .clk, .rst, .in_valid (ob_in_v), .in_ready (ob_in_r), .in_data (ob_in),
    .out_valid (s_r_valid_o), .out_ready (s_r_ready_i), .out_data (s_r_o), .count (ob_cnt)
  );

  // Room: entries in the buffer plus the read in flight must stay below 2.
  wire room  = (int'(ob_cnt) + int'(pend_q) - int'(s_r_valid_o && s_r_ready_i)) < 2;
  wire start = !rel_q && !oq_empty && done_q[head] && due;
  wire issue = (rel_q || start) && room && tok_ok;
  wire [BW-1:0] beat_now = rel_q ? rel_beat_q : '0;
  wire          last_now = beat_now == slen_q[head];
  assign buf_re    = issue;
  assign buf_raddr = {head, beat_now};

  assign ob_in_v       = pend_q;
  always_comb begin
    ob_in      = '0;
    ob_in.id   = sid_q[pend_slot_q];
    ob_in.data = buf_rdata[AXI_DATA_W-1:0];
    ob_in.resp = buf_rdata[AXI_DATA_W +: 2];
    ob_in.last = pend_last_q;
  end

  // ---------------------------------------------------------------------------------------------
  // Writes: AW and W pass through; B held until wr_delay after its AW (or its arrival, mode 1)
  // ---------------------------------------------------------------------------------------------
  assign m_aw_o       = s_aw_i;
  assign m_aw_valid_o = s_aw_valid_i;
  assign s_aw_ready_o = m_aw_ready_i;
  assign m_w_o        = s_w_i;
  assign m_w_valid_o  = s_w_valid_i;
  assign s_w_ready_o  = m_w_ready_i;

  logic [15:0] wt_q [NID];
  typedef struct packed {
    axi_b_t      b;
    logic [15:0] t;      // reference time for the delay
  } bq_t;
  bq_t        bq_in, bq_out;
  logic       bq_out_v;
  logic [5:0] bq_cnt;
  logic       bq_in_r;
  always_comb begin
    bq_in.b = m_b_i;
    bq_in.t = mode_i ? now_q : wt_q[m_b_i.id];
  end
  tg_fifo #(.T(bq_t), .DEPTH(32)) u_bq (
    .clk, .rst, .in_valid (m_b_valid_i), .in_ready (bq_in_r), .in_data (bq_in),
    .out_valid (bq_out_v), .out_ready (s_b_valid_o && s_b_ready_i), .out_data (bq_out), .count (bq_cnt)
  );
  assign m_b_ready_o = bq_in_r;
  wire [15:0] el_b = now_q - bq_out.t;
  assign s_b_valid_o = bq_out_v && el_b >= 16'(wr_delay_i);
  assign s_b_o       = bq_out.b;

  // ---------------------------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      now_q         <= '0;
      free_q        <= '1;
      done_q        <= '0;
      oq_wp_q       <= '0;
      oq_rp_q       <= '0;
      rel_q         <= 1'b0;
      pend_q        <= 1'b0;
      tokens_q      <= 11'd1024;
      st_rd_count_o <= '0;
      st_lat_sum_o  <= '0;
      st_lat_max_o  <= '0;
    end else begin
      now_q <= now_q + 1'b1;
      // allocation at AR
      if (ar_fire) begin
        free_q[alloc]        <= 1'b0;
        done_q[alloc]        <= 1'b0;
        t_iss_q[alloc]       <= now_q;
        sid_q[alloc]         <= s_ar_i.id;
        slen_q[alloc]        <= BW'(s_ar_i.len);
        scnt_q[alloc]        <= '0;
        id2slot_q[s_ar_i.id] <= alloc;
        oq_q[oq_wp_q[SW-1:0]] <= alloc;
        oq_wp_q              <= oq_wp_q + 1'b1;
      end
      // beats arriving
      if (r_fire) begin
        scnt_q[r_slot] <= scnt_q[r_slot] + 1'b1;
        if (m_r_i.last) begin
          done_q[r_slot]  <= 1'b1;
          t_arr_q[r_slot] <= now_q;
          st_rd_count_o   <= st_rd_count_o + 1'b1;
          st_lat_sum_o    <= st_lat_sum_o + 32'(now_q - t_iss_q[r_slot]);
          if (now_q - t_iss_q[r_slot] > st_lat_max_o) st_lat_max_o <= now_q - t_iss_q[r_slot];
        end
      end
      // release
      if (issue) begin
        rel_q      <= !last_now;
        rel_beat_q <= beat_now + 1'b1;
      end
      pend_q      <= issue;
      pend_last_q <= last_now;
      pend_slot_q <= head;
      if (issue && last_now) begin
        free_q[head] <= 1'b1;        // its last beat is read this cycle; a new burst cannot
        oq_rp_q      <= oq_rp_q + 1'b1;  // land in it before the next cycle
      end
      // tokens
      if (bw_cap) begin
        logic [11:0] t;
        t = 12'(tokens_q) + 12'(bw_rate_i) - ((issue) ? 12'd256 : 12'd0);
        tokens_q <= (t > 12'd1024) ? 11'd1024 : t[10:0];
      end else begin
        tokens_q <= 11'd1024;
      end
    end
    if (s_aw_valid_i && s_aw_ready_o) wt_q[s_aw_i.id] <= now_q;
  end

  wire unused = ^{bq_cnt, ob_in_r};

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (!rst) begin
    if (ar_fire) assert (int'(s_ar_i.len) < BEATS) else $error("tg_axi_lat_inj: burst longer than BEATS");
    if (r_fire)  assert (!free_q[r_slot] && !done_q[r_slot]) else $error("tg_axi_lat_inj: R beat for no outstanding read (id %0d)", m_r_i.id);
    if (pend_q)  assert (ob_in_r) else $error("tg_axi_lat_inj: output buffer overflow");
  end
`endif
endmodule
