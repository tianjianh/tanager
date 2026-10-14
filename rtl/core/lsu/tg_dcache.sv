// L1 data cache for M2 (docs/spec/core-lsu.md): L1D_KIB, L1_WAYS ways, 64-byte lines, one MSHR,
// TL-C client on l1d.
//   Data: per way a tg_ram_tdp of SETS*4 rows x 128 bits with byte enables. Port A: load reads
//         (address in AG, data in M1). Port B: Grant writes, store writes, Release and
//         ProbeAckData reads.
//   Tags: per way a tg_ram_lut, read ports: load (M1), store drain, controller (probe/victim).
//   State per (set, way) in flip-flops: valid, T (M/E), dirty.
//   MSHR: one line at a time, for a load miss (AcquireBlock NtoB) or a store (NtoT, or BtoT for
//         a line held in B). A valid victim is released first (state cleared when the Release
//         starts, so probes and stores see the line as gone); the Acquire waits for ReleaseAck.
//   Probes: answered at the line's current permission, without waiting on A-channel progress.
//         They take B only while no Release is being sent (C beats are contiguous), and block
//         the MSHR from starting and the store path from writing while they run.
module tg_dcache
  import tg_pkg::*, tg_tl_pkg::*, tg_core_pkg::*;
#(
  localparam int WAYS  = L1_WAYS,
  localparam int SETS  = (L1D_KIB * 1024) / (WAYS * 64),
  localparam int SET_W = idx_w(SETS),
  localparam int WAY_W = idx_w(WAYS),
  localparam int TAG_W = PA_W - 12,
  localparam int ROWS  = SETS * 4,
  localparam int ROW_W = idx_w(ROWS)
) (
  input  logic              clk,
  input  logic              rst,
  // Load pipe: port A read issued in AG; lookup in M1 (combinational)
  input  logic              ld_rd_en,
  input  logic [PA_W-1:0]   ld_rd_pa,
  input  logic [PA_W-1:0]   ld_m1_pa,
  output logic              ld_hit,
  output logic [63:0]       ld_dword,
  // Load miss: take the MSHR for this line if it is free
  input  logic              lm_req,
  input  logic [PA_W-1:0]   lm_pa,
  output logic              mshr_idle,    // registered state
  output logic              deny_v,       // the last fill of deny_line was denied
  output logic [PA_W-1:6]   deny_line,
  // Store drain: one request at a time, held until st_ack
  input  logic              st_req,
  input  logic [PA_W-1:0]   st_pa,
  input  logic [15:0]       st_mask,
  input  logic [127:0]      st_wdata,
  output logic              st_ack,
  output logic              st_dropped,   // acked without writing (denied Grant)
  // l1d (TL-C)
  output tl_a_t             a_o,
  output logic              a_valid_o,
  input  logic              a_ready_i,
  input  tl_b_t             b_i,
  input  logic              b_valid_i,
  output logic              b_ready_o,
  output tl_c_t             c_o,
  output logic              c_valid_o,
  input  logic              c_ready_i,
  input  tl_d_t             d_i,
  input  logic              d_valid_i,
  output logic              d_ready_o,
  output tl_e_t             e_o,
  output logic              e_valid_o,
  input  logic              e_ready_i
);
  // ---- State ----
  logic [SETS-1:0][WAYS-1:0] st_v_q, st_t_q, st_d_q;
  logic [SETS-1:0][WAY_W-1:0] rr_q;

  // ---- Arrays ----
  logic [WAYS-1:0]        b_en;
  logic [15:0]            b_we;
  logic [ROW_W-1:0]       b_addr;
  logic [127:0]           b_wdata;
  logic [WAYS-1:0][127:0] a_rdata, b_rdata;
  logic [WAYS-1:0]        b_en_w;
  for (genvar w = 0; w < WAYS; w++) begin : g_data
    tg_ram_tdp #(.DEPTH(ROWS), .WIDTH(128), .BYTE_W(8), .OUT_REG(1'b0), .PRIM("block")) u_data (
      .clk,
      .en_a(ld_rd_en), .we_a('0), .addr_a(ld_rd_pa[4 +: ROW_W]), .wdata_a('0), .rdata_a(a_rdata[w]),
      .en_b(b_en[w]), .we_b(b_en_w[w] ? b_we : 16'h0), .addr_b(b_addr), .wdata_b(b_wdata),
      .rdata_b(b_rdata[w]));
  end

  logic                         tag_we;
  logic [WAY_W-1:0]             tag_way;
  logic [SET_W-1:0]             tag_set;
  logic [TAG_W-1:0]             tag_wd;
  logic [WAYS-1:0][2:0][TAG_W-1:0] tag_rd;
  logic [2:0][SET_W-1:0]        tag_ra;
  logic [PA_W-1:0]              ctl_pa;     // controller lookup address
  assign tag_ra[0] = ld_m1_pa[6 +: SET_W];
  assign tag_ra[1] = st_pa[6 +: SET_W];
  assign tag_ra[2] = ctl_pa[6 +: SET_W];
  for (genvar w = 0; w < WAYS; w++) begin : g_tag
    tg_ram_lut #(.DEPTH(SETS), .WIDTH(TAG_W), .NR(3)) u_tag (
      .clk, .we(tag_we && tag_way == WAY_W'(w)), .waddr(tag_set), .wdata(tag_wd), .raddr(tag_ra),
      .rdata(tag_rd[w]));
  end

  // Lookups: hit vector per read port
  function automatic logic [WAYS-1:0] hits(input int port, input logic [SET_W-1:0] set,
                                          input logic [TAG_W-1:0] tag,
                                          input logic [WAYS-1:0][2:0][TAG_W-1:0] tr,
                                          input logic [SETS-1:0][WAYS-1:0] v);
    logic [WAYS-1:0] h;
    for (int w = 0; w < WAYS; w++) h[w] = v[set][w] && tr[w][port] == tag;
    return h;
  endfunction
  function automatic logic [WAY_W-1:0] enc(input logic [WAYS-1:0] h);
    logic [WAY_W-1:0] r;
    r = '0;
    for (int w = 0; w < WAYS; w++) if (h[w]) r = WAY_W'(w);
    return r;
  endfunction

  // Load lookup (M1)
  logic [WAYS-1:0] lh;
  logic [127:0]    lrow;
  assign lh = hits(0, ld_m1_pa[6 +: SET_W], ld_m1_pa[12 +: TAG_W], tag_rd, st_v_q);
  always_comb begin
    lrow = '0;
    for (int w = 0; w < WAYS; w++) lrow |= {128{lh[w]}} & a_rdata[w];
  end
  assign ld_hit   = |lh;
  assign ld_dword = ld_m1_pa[3] ? lrow[127:64] : lrow[63:0];

  // Store lookup
  logic [WAYS-1:0]  sh;
  logic [WAY_W-1:0] sh_way;
  logic             s_hit, s_hit_t;
  assign sh      = hits(1, st_pa[6 +: SET_W], st_pa[12 +: TAG_W], tag_rd, st_v_q);
  assign sh_way  = enc(sh);
  assign s_hit   = |sh;
  assign s_hit_t = s_hit && st_t_q[st_pa[6 +: SET_W]][sh_way];

  // Controller lookup
  logic [WAYS-1:0]  ch;
  logic [WAY_W-1:0] ch_way;
  assign ch     = hits(2, ctl_pa[6 +: SET_W], ctl_pa[12 +: TAG_W], tag_rd, st_v_q);
  assign ch_way = enc(ch);

  // ---- MSHR ----
  typedef enum logic [3:0] {
    M_IDLE, M_EV_RD, M_EV_SEND, M_EV_WAIT, M_ACQ, M_GRANT, M_GACK, M_INSTALL
  } mstate_e;
  mstate_e          ms_q;
  logic [PA_W-1:6]  m_line_q;
  logic [2:0]       m_grow_q;
  logic             m_st_q;              // for a store
  logic [WAY_W-1:0] m_way_q;
  logic [PA_W-1:6]  m_vline_q;           // victim line
  logic             m_vdirty_q, m_vt_q;
  logic [1:0]       m_beat_q;
  logic             m_den_q;
  logic [2:0]       m_cap_q;
  logic [TL_SINK_W-1:0] m_sink_q;
  assign mshr_idle = ms_q == M_IDLE;

  // ---- Probe FSM ----
  typedef enum logic [2:0] { P_IDLE, P_LOOK, P_RD, P_SEND, P_ACK, P_UPD } pstate_e;
  pstate_e          ps_q;
  logic [PA_W-1:0]  p_pa_q;
  logic [2:0]       p_cap_q;
  logic             p_perm_q;
  logic [TL_SRC_W-1:0] p_src_q;
  logic             p_hit_q, p_nv_q, p_nt_q;
  logic [2:0]       p_param_q;
  logic [WAY_W-1:0] p_way_q;
  logic [1:0]       p_beat_q;
  logic             probe_active;
  assign probe_active = ps_q != P_IDLE;
  logic             mshr_on_c;           // a Release message is being sent
  assign mshr_on_c = ms_q == M_EV_RD || ms_q == M_EV_SEND;

  assign ctl_pa = probe_active ? p_pa_q : lm_pa;

  // ---- Allocation (from M_IDLE) ----
  logic alloc_st, alloc_ld;
  always_comb begin
    alloc_st = 1'b0;
    alloc_ld = 1'b0;
    // A load allocates only if its line is still absent (it may have been filled since M1).
    if (ms_q == M_IDLE && !probe_active && !(b_valid_i && ps_q == P_IDLE)) begin
      if (st_req && !s_hit_t)   alloc_st = 1'b1;
      else if (lm_req && !(|ch)) alloc_ld = 1'b1;
    end
  end
  logic [PA_W-1:0]  al_pa;
  assign al_pa = alloc_st ? st_pa : lm_pa;
  logic [WAYS-1:0]  al_hit;
  logic [WAY_W-1:0] al_hway, victim;
  logic             al_hb;               // line held in B (store upgrade)
  assign al_hit  = alloc_st ? sh : ch;
  assign al_hway = enc(al_hit);
  assign al_hb   = |al_hit;
  always_comb begin
    logic found;
    logic [SET_W-1:0] s;
    s = al_pa[6 +: SET_W];
    found = 1'b0;
    victim = rr_q[s];
    for (int w = 0; w < WAYS; w++) begin
      if (!found && !st_v_q[s][w]) begin
        victim = WAY_W'(w);
        found = 1'b1;
      end
    end
  end

  // ---- Port B arbitration ----
  logic pb_probe, pb_grant, pb_ev, pb_st;
  logic grant_beat;                      // a GrantData beat is accepted this cycle
  assign pb_probe   = ps_q == P_RD;
  assign pb_ev      = ms_q == M_EV_RD;
  // Port B's read register must hold while a beat waits on C, so nothing else enables port B
  // during P_SEND or M_EV_SEND.
  assign grant_beat = ms_q == M_GRANT && d_valid_i && !(ps_q == P_RD || ps_q == P_SEND) &&
                      d_i.opcode == D_GRANT_DATA;
  assign pb_grant   = grant_beat;
  assign pb_st      = st_req && s_hit_t && !probe_active && !mshr_on_c && !pb_grant;
  assign st_ack     = pb_st || st_drop;
  logic st_drop;
  assign st_dropped = st_drop;

  always_comb begin
    b_en = '0; b_en_w = '0; b_we = '0; b_addr = '0; b_wdata = '0;
    if (pb_probe) begin
      b_en[p_way_q] = 1'b1;
      b_addr = {p_pa_q[6 +: SET_W], p_beat_q};
    end else if (pb_grant) begin
      b_en[m_way_q] = 1'b1; b_en_w[m_way_q] = 1'b1;
      b_we = '1;
      b_addr = {m_line_q[6 +: SET_W], m_beat_q};
      b_wdata = d_i.data;
    end else if (pb_ev) begin
      b_en[m_way_q] = 1'b1;
      b_addr = {m_vline_q[6 +: SET_W], m_beat_q};
    end else if (pb_st) begin
      b_en[sh_way] = 1'b1; b_en_w[sh_way] = 1'b1;
      b_we = st_mask;
      b_addr = st_pa[4 +: ROW_W];
      b_wdata = st_wdata;
    end
  end

  // ---- Channels ----
  always_comb begin
    a_o = '0;
    a_o.opcode  = A_ACQUIRE_BLOCK;
    a_o.param   = m_grow_q;
    a_o.size    = 3'd6;
    a_o.source  = TL_SRC_W'(0);
    a_o.address = {m_line_q, 6'b0};
    a_o.mask    = '1;
    a_valid_o   = ms_q == M_ACQ;

    e_o.sink    = m_sink_q;
    e_valid_o   = ms_q == M_GACK;

    b_ready_o   = ps_q == P_IDLE && !mshr_on_c && !(ms_q == M_IDLE && (alloc_st || alloc_ld));

    c_o = '0;
    c_valid_o = 1'b0;
    if (ps_q == P_SEND || ps_q == P_ACK) begin
      c_valid_o   = 1'b1;
      c_o.opcode  = (ps_q == P_SEND) ? C_PROBE_ACK_DATA : C_PROBE_ACK;
      c_o.param   = p_param_q;
      c_o.size    = 3'd6;
      c_o.source  = p_src_q;
      c_o.address = {p_pa_q[PA_W-1:6], 6'b0};
      c_o.data    = (ps_q == P_SEND) ? b_rdata[p_way_q] : '0;   // held stable: see port B rules
    end else if (ms_q == M_EV_SEND) begin
      c_valid_o   = 1'b1;
      c_o.opcode  = m_vdirty_q ? C_RELEASE_DATA : C_RELEASE;
      c_o.param   = m_vt_q ? TL_SHRINK_T_TO_N : TL_SHRINK_B_TO_N;
      c_o.size    = 3'd6;
      c_o.source  = TL_SRC_W'(1);
      c_o.address = {m_vline_q, 6'b0};
      c_o.data    = m_vdirty_q ? b_rdata[m_way_q] : '0;
    end

    d_ready_o = 1'b1;
    if (ms_q == M_GRANT && (ps_q == P_RD || ps_q == P_SEND)) d_ready_o = 1'b0;
  end
  logic dn_v_q;
  logic [PA_W-1:6] dn_line_q;
  assign deny_v    = dn_v_q;
  assign deny_line = dn_line_q;

  // Grant with data or permission only
  logic d_fire;
  assign d_fire = d_valid_i && d_ready_o;

  // Store whose fill was denied: acknowledged without a write
  assign st_drop = st_req && ms_q == M_IDLE && dn_v_q && dn_line_q == st_pa[PA_W-1:6] && !s_hit_t
                   && !alloc_ld && !probe_active;

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    if (rst) begin
      st_v_q <= '0;
      st_t_q <= '0;
      st_d_q <= '0;
      rr_q   <= '0;
      ms_q   <= M_IDLE;
      ps_q   <= P_IDLE;
      dn_v_q <= 1'b0;
    end else begin
      // Store write: the line becomes dirty
      if (pb_st) st_d_q[st_pa[6 +: SET_W]][sh_way] <= 1'b1;

      // ---- MSHR ----
      unique case (ms_q)
        M_IDLE: if ((alloc_st || alloc_ld) && !st_drop) begin
          logic [SET_W-1:0] s;
          s = al_pa[6 +: SET_W];
          m_line_q <= al_pa[PA_W-1:6];
          m_st_q   <= alloc_st;
          m_beat_q <= '0;
          m_den_q  <= 1'b0;
          if (alloc_st && al_hb) begin
            // Upgrade a B line in place
            m_way_q  <= al_hway;
            m_grow_q <= TL_GROW_B_TO_T;
            ms_q     <= M_ACQ;
          end else begin
            m_way_q  <= victim;
            m_grow_q <= alloc_st ? TL_GROW_N_TO_T : TL_GROW_N_TO_B;
            rr_q[s]  <= rr_q[s] + 1'b1;
            if (st_v_q[s][victim]) begin
              // Release the victim; it is gone for probes and stores from now on
              m_vline_q  <= {tag_rd[victim][alloc_st ? 1 : 2], s};
              m_vdirty_q <= st_d_q[s][victim];
              m_vt_q     <= st_t_q[s][victim];
              st_v_q[s][victim] <= 1'b0;
              st_t_q[s][victim] <= 1'b0;
              st_d_q[s][victim] <= 1'b0;
              ms_q <= st_d_q[s][victim] ? M_EV_RD : M_EV_SEND;
            end else begin
              ms_q <= M_ACQ;
            end
          end
        end
        M_EV_RD: ms_q <= M_EV_SEND;                 // port B read of beat m_beat_q
        M_EV_SEND: if (c_ready_i) begin
          if (!m_vdirty_q || m_beat_q == 2'd3) begin
            m_beat_q <= '0;
            ms_q <= M_EV_WAIT;
          end else begin
            m_beat_q <= m_beat_q + 1'b1;
            ms_q <= M_EV_RD;
          end
        end
        M_EV_WAIT: if (d_fire && d_i.opcode == D_RELEASE_ACK) ms_q <= M_ACQ;
        M_ACQ: if (a_ready_i) begin
          ms_q <= M_GRANT;
          m_beat_q <= '0;
        end
        M_GRANT: if (d_fire && (d_i.opcode == D_GRANT_DATA || d_i.opcode == D_GRANT)) begin
          m_cap_q  <= {1'b0, d_i.param};
          m_sink_q <= d_i.sink;
          if (d_i.denied || d_i.corrupt) m_den_q <= 1'b1;
          if (d_i.opcode == D_GRANT || m_beat_q == 2'd3) ms_q <= M_GACK;
          m_beat_q <= m_beat_q + 1'b1;
        end
        M_GACK: if (e_ready_i) ms_q <= M_INSTALL;
        M_INSTALL: begin
          logic [SET_W-1:0] s;
          s = m_line_q[6 +: SET_W];
          ms_q <= M_IDLE;
          if (!m_den_q) begin
            st_v_q[s][m_way_q] <= 1'b1;
            st_t_q[s][m_way_q] <= m_cap_q == TL_CAP_TO_T;
            st_d_q[s][m_way_q] <= 1'b0;
            if (dn_v_q && dn_line_q == m_line_q) dn_v_q <= 1'b0;
          end else begin
            st_v_q[s][m_way_q] <= 1'b0;
            dn_v_q    <= 1'b1;
            dn_line_q <= m_line_q;
          end
        end
        default: ms_q <= M_IDLE;
      endcase

      // ---- Probes ----
      unique case (ps_q)
        P_IDLE: if (b_valid_i && b_ready_o) begin
          ps_q     <= P_LOOK;
          p_pa_q   <= b_i.address;
          p_cap_q  <= b_i.param;
          p_perm_q <= b_i.opcode == B_PROBE_PERM;
          p_src_q  <= b_i.source;
        end
        P_LOOK: begin
          logic [SET_W-1:0] s;
          logic t, d, hit;
          s = p_pa_q[6 +: SET_W];
          hit = |ch;
          t = st_t_q[s][ch_way];
          d = st_d_q[s][ch_way];
          p_way_q  <= ch_way;
          p_hit_q  <= hit;
          p_beat_q <= '0;
          p_nv_q   <= hit;
          p_nt_q   <= hit && t;
          if (!hit) begin
            p_param_q <= TL_REPORT_N_TO_N;
          end else if (t) begin
            if (p_cap_q == TL_CAP_TO_T) begin
              p_param_q <= TL_REPORT_T_TO_T;
            end else begin
              p_param_q <= (p_cap_q == TL_CAP_TO_N) ? TL_SHRINK_T_TO_N : TL_SHRINK_T_TO_B;
              p_nv_q    <= p_cap_q != TL_CAP_TO_N;
              p_nt_q    <= 1'b0;
            end
          end else begin
            p_param_q <= (p_cap_q == TL_CAP_TO_N) ? TL_SHRINK_B_TO_N : TL_REPORT_B_TO_B;
            p_nv_q    <= p_cap_q != TL_CAP_TO_N;
          end
          ps_q <= (hit && t && p_cap_q != TL_CAP_TO_T && d && !p_perm_q) ? P_RD : P_ACK;
        end
        P_RD: ps_q <= P_SEND;
        P_SEND: if (c_ready_i) begin
          if (p_beat_q == 2'd3) ps_q <= P_UPD;
          else begin
            p_beat_q <= p_beat_q + 1'b1;
            ps_q <= P_RD;
          end
        end
        P_ACK: if (c_ready_i) ps_q <= P_UPD;
        P_UPD: begin
          logic [SET_W-1:0] s;
          s = p_pa_q[6 +: SET_W];
          ps_q <= P_IDLE;
          if (p_hit_q) begin
            st_v_q[s][p_way_q] <= p_nv_q;
            st_t_q[s][p_way_q] <= p_nt_q;
            if (p_nv_q && !p_nt_q) st_d_q[s][p_way_q] <= 1'b0;   // to B: dirty data went with the ack
            if (!p_nv_q)           st_d_q[s][p_way_q] <= 1'b0;
          end
        end
        default: ps_q <= P_IDLE;
      endcase
    end
  end

  // Tag write at install
  assign tag_we  = ms_q == M_INSTALL && !m_den_q;
  assign tag_way = m_way_q;
  assign tag_set = m_line_q[6 +: SET_W];
  assign tag_wd  = m_line_q[PA_W-1:12];

  logic unused;
  assign unused = ^{m_st_q, b_i.size, d_i.size, d_i.source, ld_rd_pa[3:0], ld_rd_pa[PA_W-1:12],
                    ld_m1_pa[5:0], ctl_pa[5:0], lm_pa[5:0], st_pa[5:0], p_pa_q[5:0], m_cap_q[2], al_pa[5:0]};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      assert ($onehot0(lh)) else $error("tg_dcache: multiple way hits");
      assert ($onehot0({pb_probe, pb_grant, pb_ev, pb_st})) else $error("tg_dcache: port B conflict");
    end
  end
`endif
endmodule
