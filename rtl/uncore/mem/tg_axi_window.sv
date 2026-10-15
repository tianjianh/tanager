// DRAM window (docs/spec/uncore-mem.md, plan §5.5): maps the RISC-V DRAM window at DRAM_BASE onto
// the PS DDR carve-out [base, base + size) and keeps every RISC-V access inside it. Out-of-range
// bursts never leave: reads return SLVERR beats, writes absorb their W beats and return SLVERR.
// size is in bytes, a multiple of 64; bursts are at most 64 bytes and 64-byte aligned (the L2's),
// so a burst is in range exactly when its offset is below size. Error responses are merged with the
// downstream ones; the L2's IDs are unique among outstanding transactions, so no same-ID ordering
// is at stake.
module tg_axi_window
  import tg_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst,
  input  logic [AXI_ADDR_W-1:0] base_i,
  input  logic [AXI_ADDR_W-1:0] size_i,
  // upstream (from the latency injector)
  input  axi_ax_t s_ar_i,
  input  logic    s_ar_valid_i,
  output logic    s_ar_ready_o,
  output axi_r_t  s_r_o,
  output logic    s_r_valid_o,
  input  logic    s_r_ready_i,
  input  axi_ax_t s_aw_i,
  input  logic    s_aw_valid_i,
  output logic    s_aw_ready_o,
  input  axi_w_t  s_w_i,
  input  logic    s_w_valid_i,
  output logic    s_w_ready_o,
  output axi_b_t  s_b_o,
  output logic    s_b_valid_o,
  input  logic    s_b_ready_i,
  // downstream (to the PS port)
  output axi_ax_t m_ar_o,
  output logic    m_ar_valid_o,
  input  logic    m_ar_ready_i,
  input  axi_r_t  m_r_i,
  input  logic    m_r_valid_i,
  output logic    m_r_ready_o,
  output axi_ax_t m_aw_o,
  output logic    m_aw_valid_o,
  input  logic    m_aw_ready_i,
  output axi_w_t  m_w_o,
  output logic    m_w_valid_o,
  input  logic    m_w_ready_i,
  input  axi_b_t  m_b_i,
  input  logic    m_b_valid_i,
  output logic    m_b_ready_o
);
  localparam logic [AXI_ADDR_W-1:0] DBASE = AXI_ADDR_W'(DRAM_BASE);

  // a - DBASE < size exactly when a < size + DBASE (41 bits, so neither side wraps). The limit comes
  // from the size register, so the address passes one compare, not a subtract and then a compare:
  // the range check feeds s_ar_ready_o, the end of the L2's AR handshake path (200 MHz, DR-137)
  wire [AXI_ADDR_W:0] lim = {1'b0, size_i} + {1'b0, DBASE};
  function automatic logic in_range(input logic [AXI_ADDR_W-1:0] a, input logic [AXI_ADDR_W:0] limit);
    return a >= DBASE && {1'b0, a} < limit;
  endfunction

  // ---- Reads ----
  wire ar_ok = in_range(s_ar_i.addr, lim);
  // Error reads queue here (one burst outstanding at a time is plenty: errors are exceptional)
  logic          er_v_q;
  axi_ax_t       er_q;
  logic [7:0]    er_beat_q;

  always_comb begin
    m_ar_o      = s_ar_i;
    m_ar_o.addr = base_i + (s_ar_i.addr - DBASE);
  end
  assign m_ar_valid_o = s_ar_valid_i && ar_ok;
  assign s_ar_ready_o = ar_ok ? m_ar_ready_i : !er_v_q;

  axi_r_t er_r;
  always_comb begin
    er_r      = '0;
    er_r.id   = er_q.id;
    er_r.resp = AXI_SLVERR;
    er_r.last = er_beat_q == er_q.len;
  end
  logic [1:0] r_in_r;
  tg_arb #(.N(2), .T(axi_r_t)) u_rarb (
    .clk, .rst,
    .in_valid ({er_v_q, m_r_valid_i}), .in_last ({er_r.last, m_r_i.last}), .in_data ({er_r, m_r_i}),
    .in_ready (r_in_r), .out_valid (s_r_valid_o), .out_data (s_r_o), .out_idx (), .out_ready (s_r_ready_i)
  );
  assign m_r_ready_o = r_in_r[0];

  // ---- Writes: each accepted AW's fate (forwarded or absorbed) is queued for its W beats ----
  wire aw_ok = in_range(s_aw_i.addr, lim);
  logic       wf_in_r, wf_out_v, wf_out;
  logic [3:0] wf_cnt;
  always_comb begin
    m_aw_o      = s_aw_i;
    m_aw_o.addr = base_i + (s_aw_i.addr - DBASE);
  end
  assign m_aw_valid_o = s_aw_valid_i && aw_ok && wf_in_r;
  assign s_aw_ready_o = wf_in_r && (aw_ok ? m_aw_ready_i : 1'b1);
  wire aw_fire = s_aw_valid_i && s_aw_ready_o;

  // AW fate FIFO {forward, id}
  typedef struct packed { logic fwd; logic [AXI_ID_W-1:0] id; } wf_t;
  wf_t wf_in_d, wf_out_d;
  assign wf_in_d = '{fwd: aw_ok, id: s_aw_i.id};
  tg_fifo #(.T(wf_t), .DEPTH(8)) u_wf (
    .clk, .rst, .in_valid (aw_fire), .in_ready (wf_in_r), .in_data (wf_in_d),
    .out_valid (wf_out_v), .out_ready (s_w_valid_i && s_w_ready_o && s_w_i.last), .out_data (wf_out_d), .count (wf_cnt)
  );
  assign wf_out = wf_out_d.fwd;

  // Error B for absorbed writes
  logic   eb_v_q;
  axi_b_t eb_q;
  assign m_w_o       = s_w_i;
  assign m_w_valid_o = s_w_valid_i && wf_out_v && wf_out;
  assign s_w_ready_o = wf_out_v && (wf_out ? m_w_ready_i : !eb_v_q);

  logic [1:0] b_in_r;
  tg_arb #(.N(2), .T(axi_b_t)) u_barb (
    .clk, .rst,
    .in_valid ({eb_v_q, m_b_valid_i}), .in_last (2'b11), .in_data ({eb_q, m_b_i}),
    .in_ready (b_in_r), .out_valid (s_b_valid_o), .out_data (s_b_o), .out_idx (), .out_ready (s_b_ready_i)
  );
  assign m_b_ready_o = b_in_r[0];

  always_ff @(posedge clk) begin
    if (rst) begin
      er_v_q <= 1'b0;
      eb_v_q <= 1'b0;
    end else begin
      if (s_ar_valid_i && s_ar_ready_o && !ar_ok) begin
        er_v_q    <= 1'b1;
        er_q      <= s_ar_i;
        er_beat_q <= '0;
      end else if (er_v_q && r_in_r[1]) begin
        if (er_r.last) er_v_q <= 1'b0;
        else er_beat_q <= er_beat_q + 1'b1;
      end
      if (s_w_valid_i && s_w_ready_o && s_w_i.last && !wf_out) begin
        eb_v_q    <= 1'b1;
        eb_q.id   <= wf_out_d.id;
        eb_q.resp <= AXI_SLVERR;
      end else if (eb_v_q && b_in_r[1]) begin
        eb_v_q <= 1'b0;
      end
    end
  end

  wire unused = ^{wf_cnt, er_q.addr, er_q.size, er_q.burst};

`ifndef SYNTHESIS
  // The range check against the limit is the original subtract-and-compare
  always_ff @(posedge clk) if (!rst) begin
    if (s_ar_valid_i) assert (ar_ok == (s_ar_i.addr >= DBASE && (s_ar_i.addr - DBASE) < size_i))
      else $error("tg_axi_window: AR range check differs at %h", s_ar_i.addr);
    if (s_aw_valid_i) assert (aw_ok == (s_aw_i.addr >= DBASE && (s_aw_i.addr - DBASE) < size_i))
      else $error("tg_axi_window: AW range check differs at %h", s_aw_i.addr);
  end
`endif
endmodule
