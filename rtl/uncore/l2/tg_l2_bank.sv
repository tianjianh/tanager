// One bank of the shared L2 (docs/spec/l2.md). Inclusive, 8-way, MESI presence directory for
// N_AGENTS TL-C agents, one transaction per line, TL-C probes, AXI4 fills and write-backs.
//
// Structure:
//   A input  -> holding register (+ Put buffer)      \
//   C input  -> holding register (+ C data buffer)    }-> S0 arbiter -> S1 -> S2 (directory RAM
//   MSHR resume / invalidate commands                /    read-modify-write, MSHR allocation)
//   MSHRs drive the engines: probes (B), AXI reads, fills (R), victim read-out and write-back
//   (AW/W/B), Put writes, responses (D). GrantAck (E) completes Acquires.
//   Data array: 256-bit rows {set, way, half}; one beat (half row) written and one row read per cycle.
module tg_l2_bank
  import tg_pkg::*, tg_tl_pkg::*, tg_uncore_pkg::*, tg_l2_plru_pkg::*;
#(
  parameter int BANK     = 0,
  parameter int N_AGENTS = NUM_CORES,
  parameter int SETS     = 1024,
  parameter int N_MSHR   = 24,
  parameter int N_WB     = 4,
  parameter int N_PUTBUF = 4,
  parameter     DATA_PRIM = "ultra",
  parameter int DATA_LAT  = 2,        // data-array read latency, >= 2 (4 for the URAM cascade at 200 MHz)
  parameter bit RSLICE_DSP = 1'b0,    // the R slice's data register in DSP48E2s (tg_skid DSP; DR-136)
  parameter bit MWAY_OH    = 1'b1,    // each MSHR's way kept one-hot in flip-flops (else binary), so the
                                      // reservations and the ProbeAck search take it with no decode (DR-142)
  parameter bit DIR_S3     = 1'b1     // the directory RAM written a cycle after S2, from the newest history
                                      // entry, with a third entry in the bypass: no S2 path ends at the RAM's
                                      // pins (DR-142; cycle-identical either way)
) (
  input  logic    clk,
  input  logic    rst,

  input  tl_a_t   a_i,
  input  logic    a_valid_i,
  output logic    a_ready_o,
  output tl_b_t   b_o,
  output logic    b_valid_o,
  input  logic    b_ready_i,
  input  tl_c_t   c_i,
  input  logic    c_valid_i,
  output logic    c_ready_o,
  output tl_d_t   d_o,
  output logic    d_valid_o,
  input  logic    d_ready_i,
  input  tl_e_t   e_i,
  input  logic    e_valid_i,
  output logic    e_ready_o,

  output axi_ax_t ar_o,
  output logic    ar_valid_o,
  input  logic    ar_ready_i,
  input  axi_r_t  r_i,
  input  logic    r_valid_i,
  output logic    r_ready_o,
  output axi_ax_t aw_o,
  output logic    aw_valid_o,
  input  logic    aw_ready_i,
  output axi_w_t  w_o,
  output logic    w_valid_o,
  input  logic    w_ready_i,
  input  axi_b_t  bresp_i,
  input  logic    bresp_valid_i,
  output logic    bresp_ready_o,

  output logic    init_done_o,
  output logic    ev_hit_o,
  output logic    ev_miss_o,
  output logic    ev_wb_o,
  output logic    ev_probe_o,
  output logic    ev_err_o        // protocol or AXI error seen (sticky in the SoC's status)
);
  // ---------------------------------------------------------------------------------------------
  // Geometry and types
  // ---------------------------------------------------------------------------------------------
  localparam int WAYS   = 8;
  localparam int SET_W  = $clog2(SETS);
  localparam int LINE_W = PA_W - 6;
  localparam int TAG_W  = LINE_W - 1 - SET_W;
  localparam int MW     = idx_w(N_MSHR);
  localparam int PBW    = idx_w(N_PUTBUF);
  localparam int WBW    = idx_w(N_WB);
  localparam int RAW    = SET_W + 4;                 // data row address {set, way, half}
  localparam int DFIFO  = 8;                         // D output: beats of credit, FIFO entries

  if (SETS < 2 || (SETS & (SETS - 1)) != 0) begin : g_bad_sets
    $error("tg_l2_bank: SETS must be a power of two");
  end
  if (N_MSHR > 31 || N_MSHR > (1 << AXI_ID_W)) begin : g_bad_mshr
    $error("tg_l2_bank: N_MSHR must fit the sink and AXI ID encodings (<= 31)");
  end
  if (SETS < N_MSHR) begin : g_bad_sets_mshr
    $error("tg_l2_bank: the reset sequencer clears per-MSHR LUTRAM: SETS >= N_MSHR");
  end
  if (N_AGENTS < 1 || N_AGENTS > MAX_CORES) begin : g_bad_agents
    $error("tg_l2_bank: N_AGENTS must be 1..4");
  end

  typedef struct packed {
    logic [TAG_W-1:0]    tag;
    logic                valid;
    logic                dirty;
    logic [N_AGENTS-1:0] pres;
    logic                tip;
  } way_t;

  typedef struct packed {
    logic [6:0]          plru;
    way_t [WAYS-1:0]     way;
  } row_t;

  typedef enum logic [1:0] { K_ACQ, K_GET, K_PUT } kind_e;

  typedef enum logic [3:0] {
    MS_IDLE,
    MS_PROBE,      // probes outstanding; all acked -> MS_RESUME
    MS_RESUME,     // wants an MCMD pass (resume after probes)
    MS_INVAL,      // wants an MCMD pass (invalidate the way after a fill error)
    MS_PIPE_RES,   // MCMD resume in the pipeline
    MS_PIPE_INV,   // MCMD invalidate in the pipeline
    MS_VREAD,      // dirty victim to read out into a write-back buffer
    MS_VWAIT,      // victim read-out in progress
    MS_FILL,       // fill data from R accepted into the way
    MS_PUTW,       // Put data written into the way
    MS_RESP,       // D response
    MS_ACK,        // waiting for GrantAck
    MS_WBWAIT      // waiting for the victim write-back's B response
  } mstate_e;

  typedef enum logic [2:0] { PK_INIT, PK_REL, PK_PACK, PK_MCMD, PK_ACQ, PK_GET, PK_PUT } pkind_e;

  typedef struct packed {
    pkind_e               kind;
    logic [LINE_W-1:0]    line;
    logic [MW-1:0]        mshr;      // PK_MCMD
    tl_a_op_e             a_op;      // PK_ACQ/GET/PUT
    logic [2:0]           a_param;
    logic [TL_SIZE_W-1:0] a_size;
    logic [TL_SRC_W-1:0]  a_src;
    logic [5:0]           a_off;
    logic [PBW-1:0]       a_pb;
  } preq_t;

  // Field extractors: the bits they do not return are unused by design.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [SET_W-1:0] set_of(input logic [LINE_W-1:0] l);
    return l[1 +: SET_W];
  endfunction
  function automatic logic [TAG_W-1:0] tag_of(input logic [LINE_W-1:0] l);
    return l[LINE_W-1 -: TAG_W];
  endfunction
  function automatic logic [AGENT_W-1:0] agent_of(input logic [TL_SRC_W-1:0] s);
    return s[TL_SRC_LOCAL_W +: AGENT_W];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  function automatic logic [LINE_W-1:0] line_of(input logic [TAG_W-1:0] t, input logic [SET_W-1:0] s);
    return {t, s, 1'(BANK)};
  endfunction
  function automatic logic [N_AGENTS-1:0] onehot_ag(input logic [AGENT_W-1:0] a);
    return N_AGENTS'(1) << a;
  endfunction

  // Round-robin pick over a request vector: the first request at or after ptr, wrapping. Two lowest-
  // index searches (requests at or above ptr, and all requests) instead of a rotation. Each search is
  // a two-level tree, the lowest request in each group of four (a LUT per bit), then the lowest group,
  // because synthesis built the flat priority encoder (rr_pick_ref, kept for the assertions) 9 levels
  // deep, and the pick heads the L2's AR and probe handshakes (200 MHz, DR-142). The same function.
  localparam int NG = N_MSHR / 4;
  if (N_MSHR % 4 != 0) begin : g_bad_mshr
    $error("tg_l2_bank: N_MSHR must be a multiple of 4 (rr_pick's groups)");
  end
  function automatic logic [MW-1:0] lowest_idx(input logic [N_MSHR-1:0] v);
    logic [NG-1:0] any;
    logic [1:0]    off [NG];
    logic [MW-1:0] r;
    for (int g = 0; g < NG; g++) begin
      any[g] = |v[4*g +: 4];
      off[g] = v[4*g] ? 2'd0 : v[4*g + 1] ? 2'd1 : v[4*g + 2] ? 2'd2 : 2'd3;
    end
    r = '0;
    for (int g = NG - 1; g >= 0; g--) if (any[g]) r = MW'(4 * g) | MW'(off[g]);
    return r;
  endfunction
  function automatic logic [MW-1:0] rr_pick(input logic [N_MSHR-1:0] v, input logic [MW-1:0] ptr);
    logic [N_MSHR-1:0] hi;
    for (int i = 0; i < N_MSHR; i++) hi[i] = v[i] && i >= int'(ptr);
    return (hi != '0) ? lowest_idx(hi) : lowest_idx(v);
  endfunction
  function automatic logic [MW-1:0] rr_pick_ref(input logic [N_MSHR-1:0] v, input logic [MW-1:0] ptr);
    logic [MW-1:0] r_hi, r_all;
    logic          any_hi;
    r_hi   = '0;
    r_all  = '0;
    any_hi = 1'b0;
    for (int i = N_MSHR - 1; i >= 0; i--) begin
      if (v[i]) r_all = MW'(i);
      if (v[i] && i >= int'(ptr)) begin
        r_hi   = MW'(i);
        any_hi = 1'b1;
      end
    end
    return any_hi ? r_hi : r_all;
  endfunction
  function automatic logic [MW-1:0] rr_next(input logic [MW-1:0] i);
    return (int'(i) == N_MSHR - 1) ? '0 : i + 1'b1;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // MSHR file
  // ---------------------------------------------------------------------------------------------
  // State flags live in flip-flops. The payload written once at allocation and read by index
  // (line, victim line, way, request fields) is also kept in multi-read-port LUTRAM, so the engines
  // read it without wide N_MSHR:1 multiplexers; the flip-flop copies of line, victim line and way
  // remain only for the compares that look at every MSHR at once (admission, reservations).
  // The state is one-hot: ms[m][s] is set while MSHR m is in state s. m_st is the encoded copy for
  // the assertions and the testbench's dump; synthesis trims it.
  localparam int NMS = int'(MS_WBWAIT) + 1;
  logic    [N_MSHR-1:0] m_valid;                // !ms[m][MS_IDLE]
  logic [NMS-1:0]       ms        [N_MSHR];
  logic [NMS-1:0]       ms_d      [N_MSHR];
  mstate_e              m_st      [N_MSHR];
  logic [LINE_W-1:0]    m_line    [N_MSHR];
  logic [WAYS-1:0]      m_way_oh  [N_MSHR];     // the way, one-hot: stored (MWAY_OH), else decoded
  logic [N_MSHR-1:0]    m_hit;
  logic [N_MSHR-1:0]    m_grant_t;              // Grant param toT (else toB)
  logic [N_AGENTS-1:0]  m_ppend   [N_MSHR];     // probes awaiting ProbeAck
  logic [N_AGENTS-1:0]  m_psent   [N_MSHR];
  logic [N_MSHR-1:0]    m_pcap_n;               // probe cap toN (else toB)
  logic [N_MSHR-1:0]    m_pvict;                // probing the victim line (else the request line)
  logic [N_MSHR-1:0]    m_vact;                 // victim line still owned by this MSHR
  logic [TAG_W-1:0]     m_vtag    [N_MSHR];     // victim tag (the victim is in the request's set)
  logic [N_MSHR-1:0]    m_need_wb, m_wb_done;
  logic [N_MSHR-1:0]    m_need_fill, m_ar_sent, m_ferr;

  // LUTRAM read ports (instances near the end of the module, once the indices are declared).
  // Each LUTRAM holds the fields that the same engines read, so every read port uses every bit it
  // reads (tools/tcl/tg_prim_check.tcl counts the primitives after opt_design). Lines are stored
  // as set and tag; their bank bit is BANK.
  localparam int LP_S0 = 0, LP_PR = 1, LP_AR = 2, LP_PW = 3, LP_FL = 4, LP_VR = 5, LP_RS = 6;
  logic [6:0][SET_W-1:0] rl_set;       // line's set at: S0 resume pick, probe, AR, Put, fill, victim, response
  logic [3:0][TAG_W-1:0] rl_tag;       // line's tag at: S0 resume pick, S2 resume, probe, AR
  logic [1:0][TAG_W-1:0] rl_vtag;      // victim's tag at: probe, victim read-out start
  logic [4:0][2:0]       rl_way;       // way at: S2 resume, Put, fill, victim, response
  typedef struct packed {
    logic  grow;                       // Acquire NtoT / BtoT
    kind_e kind;
  } mkind_t;
  typedef struct packed {
    logic                 block;       // AcquireBlock (data in the Grant)
    logic [TL_SIZE_W-1:0] size;
    logic [1:0]           off;         // address bits 5:4: the row and the half of a short response
  } mrsp_t;
  mkind_t [2:0]                rl_kind;  // at: S2 resume, response, fill
  logic   [1:0][TL_SRC_W-1:0]  rl_src;   // at: S2 resume, response
  logic   [1:0][PBW-1:0]       rl_pb;    // at: response, Put
  mrsp_t  [0:0]                rl_rsp;   // at: response

  // ---------------------------------------------------------------------------------------------
  // Reset sequencer: write every set invalid
  // ---------------------------------------------------------------------------------------------
  logic [SET_W:0] init_cnt_q;
  logic           init_done_q;
  wire            init_issue = !init_cnt_q[SET_W];

  // ---------------------------------------------------------------------------------------------
  // Put buffers (data + byte mask per beat) and the A holding register
  // ---------------------------------------------------------------------------------------------
  typedef enum logic [1:0] { AI_EMPTY, AI_COLLECT, AI_READY } ain_st_e;
  ain_st_e          ain_st_q;
  tl_a_t            ain_q;
  logic [PBW-1:0]   ain_pb_q;
  logic [1:0]       ain_beat_q, ain_left_q;

  logic [N_PUTBUF-1:0] pb_free_q;
  logic [N_PUTBUF-1:0][3:0] pb_bv_q;            // beats present in each Put buffer (flip-flops)
  logic [PBW-1:0]      pb_slot;
  always_comb begin
    pb_slot = '0;
    for (int i = N_PUTBUF - 1; i >= 0; i--) if (pb_free_q[i]) pb_slot = PBW'(i);
  end

  logic                     pb_we;
  logic [PBW+1:0]           pb_waddr;
  logic [143:0]             pb_wdata;
  logic [0:0][PBW+1:0]      pb_raddr;
  logic [0:0][143:0]        pb_rdata;
  tg_ram_lut #(.DEPTH(N_PUTBUF * 4), .WIDTH(144), .NR(1)) u_putbuf (
    .clk, .we (pb_we), .waddr (pb_waddr), .wdata (pb_wdata), .raddr (pb_raddr), .rdata (pb_rdata)
  );

  wire a_is_put  = tl_a_has_data(a_i.opcode);
  wire a_accept  = a_valid_i && a_ready_o;
  assign a_ready_o = init_done_q && ((ain_st_q == AI_EMPTY && |pb_free_q) || ain_st_q == AI_COLLECT);

  // ---------------------------------------------------------------------------------------------
  // C holding register and C data buffer
  // ---------------------------------------------------------------------------------------------
  typedef enum logic [2:0] { CI_EMPTY, CI_COLLECT, CI_READY, CI_PIPE, CI_WRITE, CI_ACK } cin_st_e;
  cin_st_e          cin_st_q;
  tl_c_t            cin_q;
  logic [1:0]       cin_beat_q, cin_wcnt_q;
  logic [2:0]       cin_way_q;
  logic             cin_hit_q;
  logic             cin_mok_q;                  // a ProbeAck found its MSHR
  logic [MW-1:0]    cin_m_q;

  wire              cin_rel  = cin_q.opcode == C_RELEASE || cin_q.opcode == C_RELEASE_DATA;
  wire              cin_data = tl_c_has_data(cin_q.opcode);
  wire [AGENT_W-1:0] cin_ag  = agent_of(cin_q.source);
  wire [LINE_W-1:0] cin_line = cin_q.address[PA_W-1:6];

  logic                cb_we;
  logic [1:0]          cb_waddr;
  logic [127:0]        cb_wdata;
  logic [0:0][1:0]     cb_raddr;
  logic [0:0][127:0]   cb_rdata;
  tg_ram_lut #(.DEPTH(4), .WIDTH(128), .NR(1)) u_cbuf (
    .clk, .we (cb_we), .waddr (cb_waddr), .wdata (cb_wdata), .raddr (cb_raddr), .rdata (cb_rdata)
  );

  wire c_accept = c_valid_i && c_ready_o;
  assign c_ready_o = init_done_q && (cin_st_q == CI_EMPTY || cin_st_q == CI_COLLECT);
  assign cb_we     = c_accept && tl_c_has_data(c_i.opcode);
  assign cb_waddr  = (cin_st_q == CI_EMPTY) ? 2'd0 : cin_beat_q;
  assign cb_wdata  = c_i.data;

  // ---------------------------------------------------------------------------------------------
  // Pipeline: S0 (arbitrate, read directory) -> S1 -> S2 (decide, write directory)
  // ---------------------------------------------------------------------------------------------
  logic  p1_v_q, p2_v_q;
  preq_t p1_q, p2_q;

  // A-request admission checks against MSHRs and younger pipeline stages (spec rules 1-4)
  wire [LINE_W-1:0] ain_line = ain_q.address[PA_W-1:6];
  logic a_conflict, a_mshr_ok, a_set_ok;
  logic [MW:0] n_free_mshr;
  always_comb begin
    int n_set;
    a_conflict  = 1'b0;
    n_free_mshr = '0;
    n_set       = 0;
    for (int m = 0; m < N_MSHR; m++) begin
      logic set_eq;
      set_eq = m_valid[m] && set_of(m_line[m]) == set_of(ain_line);
      if (set_eq && (tag_of(m_line[m]) == tag_of(ain_line) || (m_vact[m] && m_vtag[m] == tag_of(ain_line))))
        a_conflict = 1'b1;
      if (!m_valid[m]) n_free_mshr = n_free_mshr + 1'b1;
      if (set_eq) n_set++;
    end
    // A Release/ProbeAck with data updates the directory at S2 and writes its beats afterwards:
    // a new request for the line waits until the data is in the array.
    if ((cin_st_q == CI_PIPE || cin_st_q == CI_WRITE) && cin_data && cin_line == ain_line) a_conflict = 1'b1;
    // An A request in S1/S2 of the same set may evict this line at its S2 (victims are chosen
    // there), so same-set A requests go through S0-S2 one at a time. Once the older one is past
    // S2, its MSHR's victim line is visible to the check above.
    if (p1_v_q && p1_q.kind inside {PK_ACQ, PK_GET, PK_PUT} && set_of(p1_q.line) == set_of(ain_line)) a_conflict = 1'b1;
    if (p2_v_q && p2_q.kind inside {PK_ACQ, PK_GET, PK_PUT} && set_of(p2_q.line) == set_of(ain_line)) a_conflict = 1'b1;
    a_mshr_ok = int'(n_free_mshr) > (int'(p1_v_q && p1_q.kind inside {PK_ACQ, PK_GET, PK_PUT}) +
                                     int'(p2_v_q && p2_q.kind inside {PK_ACQ, PK_GET, PK_PUT}));
    a_set_ok  = n_set < WAYS;          // same-set requests in S1/S2 already block (above)
  end

  // MCMD requests from MSHRs
  logic [N_MSHR-1:0] mcmd_req;
  logic [MW-1:0]     mcmd_ptr_q, mcmd_pick;
  always_comb
    for (int m = 0; m < N_MSHR; m++) mcmd_req[m] = ms[m][MS_RESUME] || ms[m][MS_INVAL];
  assign mcmd_pick = rr_pick(mcmd_req, mcmd_ptr_q);

  // S0 selection
  logic  s0_v;
  preq_t s0;
  logic  s0_take_c, s0_take_m, s0_take_a;
  always_comb begin
    s0        = '0;
    s0_v      = 1'b0;
    s0_take_c = 1'b0;
    s0_take_m = 1'b0;
    s0_take_a = 1'b0;
    if (init_issue) begin
      s0_v      = 1'b1;
      s0.kind   = PK_INIT;
      s0.line   = LINE_W'({init_cnt_q[SET_W-1:0], 1'(BANK)});
    end else if (cin_st_q == CI_READY) begin
      s0_v      = 1'b1;
      s0_take_c = 1'b1;
      s0.kind   = cin_rel ? PK_REL : PK_PACK;
      s0.line   = cin_line;
    end else if (|mcmd_req) begin
      s0_v      = 1'b1;
      s0_take_m = 1'b1;
      s0.kind   = PK_MCMD;
      s0.mshr   = mcmd_pick;
      s0.line   = line_of(rl_tag[0], rl_set[LP_S0]);
    end else if (ain_st_q == AI_READY && !a_conflict && a_mshr_ok && a_set_ok) begin
      s0_v      = 1'b1;
      s0_take_a = 1'b1;
      s0.kind   = (ain_q.opcode == A_GET) ? PK_GET : tl_a_has_data(ain_q.opcode) ? PK_PUT : PK_ACQ;
      s0.line   = ain_line;
      s0.a_op   = ain_q.opcode;
      s0.a_param = ain_q.param;
      s0.a_size = ain_q.size;
      s0.a_src  = ain_q.source;
      s0.a_off  = ain_q.address[5:0];
      s0.a_pb   = ain_pb_q;
    end
  end

  // Directory RAM: one row per set, read at S0, data at S2 (output register), written at S2, or with
  // DIR_S3 a cycle later (S3) from the newest history entry, which holds S2's write: the RAM's
  // write port then starts at flip-flops, and S2's paths end at flip-flops near its logic.
  // Each way entry and the PLRU bits fill whole bytes with their own write enables: S2 writes the
  // one entry it changes (and the PLRU), never a rebuilt row.
  localparam int WAY_W  = $bits(way_t);
  localparam int WAYB   = (WAY_W + 7) / 8;              // bytes per way entry
  localparam int DROW_W = 8 * (WAYS * WAYB + 1);        // the ways, then one PLRU byte
  logic [WAYS-1:0]      dir_wway;                       // way entries written
  logic                 dir_wplru;                      // PLRU written
  logic [SET_W-1:0]     dir_waddr;
  logic [SET_W-1:0]     dir_ws;                         // the RAM's write address
  way_t                 dir_went;                       // the entry written (every written way)
  logic [6:0]           dir_wplru_v;
  logic [WAYS*WAYB:0]   dir_be;
  logic [DROW_W-1:0]    dir_wraw;
  /* verilator lint_off UNUSEDSIGNAL */                 // byte padding is not read
  logic [DROW_W-1:0]    dir_rraw;
  /* verilator lint_on UNUSEDSIGNAL */
  row_t                 dir_rdata;
  // Write history (below): S2's writes, newest first
  logic [WAYS-1:0]  h0_way_q, h1_way_q;
  logic             h0_pl_q, h1_pl_q;
  logic [SET_W-1:0] h0_set_q, h1_set_q;
  way_t             h0_ent_q, h1_ent_q, h2_ent_q;
  logic [6:0]       h0_plru_q, h1_plru_q, h2_plru_q;
  always_comb begin
    logic [WAYS-1:0]  rw_way;                           // the RAM's write: S2's, or S3's (h0)
    logic             rw_pl;
    logic [SET_W-1:0] rw_set;
    way_t             rw_ent;
    logic [6:0]       rw_plru;
    if (DIR_S3) begin
      rw_way = h0_way_q;  rw_pl = h0_pl_q;   rw_set = h0_set_q;  rw_ent = h0_ent_q; rw_plru = h0_plru_q;
    end else begin
      rw_way = dir_wway;  rw_pl = dir_wplru; rw_set = dir_waddr; rw_ent = dir_went; rw_plru = dir_wplru_v;
    end
    dir_be   = '0;
    dir_wraw = '0;
    for (int w = 0; w < WAYS; w++) begin
      dir_be[w*WAYB +: WAYB]       = {WAYB{rw_way[w]}};
      dir_wraw[w*WAYB*8 +: WAY_W]  = rw_ent;
      dir_rdata.way[w]             = dir_rraw[w*WAYB*8 +: WAY_W];
    end
    dir_be[WAYS*WAYB]              = rw_pl;
    dir_wraw[WAYS*WAYB*8 +: 7]     = rw_plru;
    dir_rdata.plru                 = dir_rraw[WAYS*WAYB*8 +: 7];
    dir_ws                         = rw_set;
  end
  tg_ram_sdp #(.DEPTH(SETS), .WIDTH(DROW_W), .BYTE_W(8), .OUT_REG(1'b1), .PRIM("block")) u_dir (
    .clk, .we (dir_be), .waddr (dir_ws), .wdata (dir_wraw),
    .re (s0_v), .raddr (set_of(s0.line)), .rdata (dir_rraw)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      p1_v_q <= 1'b0;
      p2_v_q <= 1'b0;
    end else begin
      p1_v_q <= s0_v;
      p2_v_q <= p1_v_q;
    end
    p1_q <= s0;
    p2_q <= p1_q;
  end

  // Write history: S2's last writes, newest first, bypass the RAM's stale read. A request in S2
  // read the RAM at S0, two cycles ago, and missed the RAM writes of the last two cycles: S2's last
  // two writes, or with DIR_S3 (each a cycle late) its last three.
  wire [SET_W-1:0]  set2 = set_of(p2_q.line);
  wire [TAG_W-1:0]  tag2 = tag_of(p2_q.line);
  // The set compares S2 needs are made in S1, one cycle early, and registered (200 MHz, DR-137):
  // every operand is a register in the cycle before S2, so the result is the same compare, exactly
  // (always_ff below, checked by assertions).
  //   h0_hit: the newest history entry will be the S2 now in flight (dir_waddr is set2 every cycle);
  //   h1_hit: the older entry will be the newest now;
  //   sm1:    each MSHR's set against the next S2's. The MSHR the S2 in flight allocates takes that
  //           S2's line, whose compare is h0_hit's (newm_q marks it); one it frees drops out of
  //           m_valid;
  //   cin_seq: the C message's set; cin_q holds still while it is in CI_PIPE or CI_WRITE.
  wire [SET_W-1:0]   set1 = set_of(p1_q.line);
  wire [TAG_W-1:0]   tag1 = tag_of(p1_q.line);
  //   bsel, bpl: the bypass's per-way and PLRU selects themselves, binary: 0 the RAM, 1-3 the
  //           newest of h0-h2 that writes the way (the set compares and the history entries' way
  //           enables are known in S1), so row2 is one 4:1 select per bit;
  //   hc1, hc2: the hit compares of h1 and h2, which are entries already in S1 (h0 and h1 then);
  //           h0's is made in S2.
  logic              h0_hit_q, h1_hit_q, cin_seq_q;
  logic [N_MSHR-1:0] sm1_q, newm_q;
  logic [1:0]        bsel_q [WAYS];
  logic [1:0]        bpl_q;
  logic              hc1_q, hc2_q;
  row_t row2;
  always_comb begin
    row2 = dir_rdata;
    for (int w = 0; w < WAYS; w++)
      unique case (bsel_q[w])
        2'd1:    row2.way[w] = h0_ent_q;
        2'd2:    row2.way[w] = h1_ent_q;
        2'd3:    if (DIR_S3) row2.way[w] = h2_ent_q;
        default: ;
      endcase
    unique case (bpl_q)
      2'd1:    row2.plru = h0_plru_q;
      2'd2:    row2.plru = h1_plru_q;
      2'd3:    if (DIR_S3) row2.plru = h2_plru_q;
      default: ;
    endcase
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      h0_way_q <= '0;
      h1_way_q <= '0;
      h0_pl_q  <= 1'b0;
      h1_pl_q  <= 1'b0;
    end else begin
      h0_way_q <= dir_wway;
      h1_way_q <= h0_way_q;
      h0_pl_q  <= dir_wplru;
      h1_pl_q  <= h0_pl_q;
    end
    h0_set_q  <= dir_waddr;
    h0_ent_q  <= dir_went;
    h0_plru_q <= dir_wplru_v;
    h1_set_q  <= h0_set_q;
    h1_ent_q  <= h0_ent_q;
    h1_plru_q <= h0_plru_q;
    h2_ent_q  <= h1_ent_q;
    h2_plru_q <= h1_plru_q;
  end

  // ---------------------------------------------------------------------------------------------
  // S2: directory decision
  // ---------------------------------------------------------------------------------------------
  logic [WAYS-1:0] hitv, dhit, held, resv;
  logic [N_MSHR-1:0] smatch;           // active MSHRs in the S2 request's set
  logic            hit2;
  logic [2:0]      hw2, vw2;
  always_comb begin
    for (int w = 0; w < WAYS; w++) begin
      // compare, then select: the RAM's entry and h0 are compared at once, h1's and h2's in S1
      dhit[w] = dir_rdata.way[w].valid && dir_rdata.way[w].tag == tag2;
      unique case (bsel_q[w])
        2'd1:    hitv[w] = h0_ent_q.valid && h0_ent_q.tag == tag2;
        2'd2:    hitv[w] = hc1_q;
        2'd3:    hitv[w] = DIR_S3 ? hc2_q : dhit[w];
        default: hitv[w] = dhit[w];
      endcase
      held[w] = |row2.way[w].pres;
    end
    resv = '0;
    for (int m = 0; m < N_MSHR; m++) begin
      smatch[m] = m_valid[m] && (newm_q[m] ? h0_hit_q : sm1_q[m]);
      if (smatch[m]) resv = resv | m_way_oh[m];
    end
    // The way a Release/ProbeAck is still writing data into is not a victim candidate yet.
    if (cin_st_q == CI_WRITE && cin_seq_q) resv[cin_way_q] = 1'b1;
    hit2 = |hitv;
    hw2  = lowest8(hitv);
    vw2  = pick_victim({row2.way[7].valid, row2.way[6].valid, row2.way[5].valid, row2.way[4].valid,
                        row2.way[3].valid, row2.way[2].valid, row2.way[1].valid, row2.way[0].valid},
                       held, resv, row2.plru);
  end

  // A free MSHR for an allocating A request (admission guaranteed one)
  logic [MW-1:0] m_new;
  always_comb begin
    m_new = '0;
    for (int m = N_MSHR - 1; m >= 0; m--) if (!m_valid[m]) m_new = MW'(m);
  end

  // The way S2 reads and may write: the hit way, the MSHR's way for MCMD, the victim on a miss
  // The victim is the slowest of the three (it waits for the reservations and the PLRU), so it is
  // selected late (200 MHz, DR-137): the updates read e2, the entry of the fast choice (the hit way,
  // or the MCMD's way), and a miss reads only what it needs of the victim's entry (vic): whether
  // agents hold it, its tag and its dirty bit. A miss writes either the victim's entry unchanged or
  // a new one made from the request alone.
  logic [2:0] sw2, swf;
  way_t       e2, vic;
  wire        s2_miss = (p2_q.kind == PK_ACQ || p2_q.kind == PK_GET || p2_q.kind == PK_PUT) && !hit2;
  always_comb begin
    swf = (p2_q.kind == PK_MCMD) ? rl_way[0] : hw2;   // PK_REL, PK_PACK, a hit: the hit way
    sw2 = s2_miss ? vw2 : swf;
    e2  = row2.way[swf];
    vic = row2.way[vw2];
  end
  wire [WAYS-1:0] sw2_oh = WAYS'(1) << sw2;

  // Requester's final directory entry for an Acquire (spec §Transactions).
  function automatic way_t acq_final(input way_t e_in, input logic [AGENT_W-1:0] a, input logic grow_t);
    way_t                r;
    logic [N_AGENTS-1:0] me, others;
    r      = e_in;
    me     = N_AGENTS'(1) << a;
    others = r.pres & ~me;
    r.pres = r.pres | me;
    r.tip  = grow_t || (others == '0);
    return r;
  endfunction

  wire [AGENT_W-1:0] a2_ag    = agent_of(p2_q.a_src);
  wire               a2_growt = p2_q.a_param == TL_GROW_N_TO_T || p2_q.a_param == TL_GROW_B_TO_T;
  wire [MW-1:0]      mc2      = p2_q.mshr;
  wire [N_AGENTS-1:0] me2     = N_AGENTS'(1) << a2_ag;
  wire               full_put2 = p2_q.a_op == A_PUT_FULL && p2_q.a_size == 3'd6;

  // An allocation's consequences, per way, ahead of the late selects (200 MHz, DR-142): what a hit
  // in each way would probe, and whether each way as the victim is held by agents or dirty, are
  // made from row2 while the hit and the victim pick still form; the hit way and the victim then
  // select them, and the state the allocation enters is made from the selected bits directly
  // (one-hot, no state decode). The decision block below makes the same values from e2 and vic
  // (checked by assertions).
  logic [WAYS-1:0] hp_w, vp_w, vd_w;   // per way: a hit there probes; as the victim: held, dirty
  logic            hp_s, vp_s, vd_s;   // the hit way's and the victim's
  logic [NMS-1:0]  alloc_oh;           // the state an allocating request's MSHR enters
  always_comb begin
    for (int w = 0; w < WAYS; w++) begin
      logic [N_AGENTS-1:0] pw;
      unique case (p2_q.kind)
        PK_ACQ:  pw = a2_growt ? (row2.way[w].pres & ~me2) :
                      (row2.way[w].tip && row2.way[w].pres != me2) ? (row2.way[w].pres & ~me2) : '0;
        PK_GET:  pw = row2.way[w].tip ? row2.way[w].pres : '0;
        default: pw = row2.way[w].pres;
      endcase
      hp_w[w] = pw != '0;
      vp_w[w] = row2.way[w].valid && row2.way[w].pres != '0;
      vd_w[w] = row2.way[w].valid && row2.way[w].dirty;
    end
    hp_s = hp_w[hw2];
    vp_s = vp_w[vw2];
    vd_s = vd_w[vw2];
    alloc_oh = '0;
    alloc_oh[MS_PROBE] = hit2 ? hp_s : vp_s;
    alloc_oh[MS_RESP]  = hit2 && !hp_s && p2_q.kind != PK_PUT;
    alloc_oh[MS_PUTW]  = hit2 ? (!hp_s && p2_q.kind == PK_PUT) : (!vp_s && !vd_s && full_put2);
    alloc_oh[MS_VREAD] = !hit2 && !vp_s && vd_s;
    alloc_oh[MS_FILL]  = !hit2 && !vp_s && !vd_s && !full_put2;
  end

  // Decision outputs
  logic                s2_alloc;        // allocate MSHR m_new for an A request
  mstate_e             s2_alloc_st;
  logic                s2_alloc_hit, s2_alloc_vact, s2_alloc_wb, s2_alloc_fill, s2_alloc_grant_t;
  logic [2:0]          s2_alloc_way;
  logic [N_AGENTS-1:0] s2_alloc_probe;
  logic                s2_alloc_pcap_n, s2_alloc_pvict;
  logic [LINE_W-1:0]   s2_alloc_vline;
  logic                s2_mcmd;         // MCMD result for MSHR mc2
  mstate_e             s2_mcmd_st;
  logic                s2_mcmd_wb, s2_mcmd_vact_clr, s2_mcmd_grant_t;
  logic                s2_c;            // C message decided
  logic                s2_c_hit, s2_c_mok;
  logic [2:0]          s2_c_way;
  logic [MW-1:0]       s2_c_m;
  logic                s2_err;

  always_comb begin
    way_t   e;
    logic [N_AGENTS-1:0] me, p;
    logic   grow_t;
    // Every S2 request writes back its selected entry and the PLRU bits, changed or not, so the
    // RAM's write enables depend only on p2_v_q (the decision logic feeds the data inputs only).
    dir_wway         = '0;
    dir_wplru        = 1'b0;
    dir_wplru_v      = row2.plru;
    dir_waddr        = set2;
    s2_alloc         = 1'b0;
    s2_alloc_st      = MS_IDLE;
    s2_alloc_hit     = 1'b0;
    s2_alloc_vact    = 1'b0;
    s2_alloc_wb      = 1'b0;
    s2_alloc_fill    = 1'b0;
    s2_alloc_grant_t = 1'b0;
    s2_alloc_way     = '0;
    s2_alloc_probe   = '0;
    s2_alloc_pcap_n  = 1'b0;
    s2_alloc_pvict   = 1'b0;
    s2_alloc_vline   = '0;
    s2_mcmd          = 1'b0;
    s2_mcmd_st       = MS_IDLE;
    s2_mcmd_wb       = 1'b0;
    s2_mcmd_vact_clr = 1'b0;
    s2_mcmd_grant_t  = 1'b0;
    s2_c             = 1'b0;
    s2_c_hit         = 1'b0;
    s2_c_mok         = 1'b0;
    s2_c_way         = hw2;
    s2_c_m           = '0;
    s2_err           = 1'b0;
    ev_hit_o         = 1'b0;
    ev_miss_o        = 1'b0;
    me               = me2;
    grow_t           = 1'b0;
    e                = e2;
    p                = '0;

    if (p2_v_q) begin
      dir_wway  = (p2_q.kind == PK_INIT) ? '1 : sw2_oh;
      dir_wplru = 1'b1;
      unique case (p2_q.kind)
        PK_INIT: begin
          e           = '0;
          dir_wplru_v = '0;
        end

        PK_REL, PK_PACK: begin
          s2_c     = 1'b1;
          s2_c_hit = hit2;
          if (hit2) begin
            unique case (cin_q.param)
              TL_SHRINK_T_TO_B: begin e.pres = e.pres | onehot_ag(cin_ag);  e.tip = 1'b0; end
              TL_SHRINK_T_TO_N: begin e.pres = e.pres & ~onehot_ag(cin_ag); e.tip = 1'b0; end
              TL_SHRINK_B_TO_N, TL_REPORT_N_TO_N: e.pres = e.pres & ~onehot_ag(cin_ag);
              default: ;   // TtoT, BtoB reports: unchanged
            endcase
            if (e.pres == '0) e.tip = 1'b0;   // no holder left: no owner either
            if (cin_data) e.dirty = 1'b1;
          end else begin
            s2_err = 1'b1;   // a Release or ProbeAck for a line the inclusive L2 does not hold
          end
          if (p2_q.kind == PK_PACK) begin
            // The probing MSHR owns the way that holds the probed line (its request line on a hit,
            // its victim on a miss: the victim keeps its tag until resolved), and each (set, way)
            // belongs to at most one MSHR.
            for (int m = 0; m < N_MSHR; m++)
              if (hit2 && smatch[m] && (m_way_oh[m] & (WAYS'(1) << hw2)) != '0 && ms[m][MS_PROBE] && (m_ppend[m] & onehot_ag(cin_ag)) != '0) begin
                s2_c_mok = 1'b1;
                s2_c_m   = MW'(m);
              end
            if (!s2_c_mok) s2_err = 1'b1;
          end
        end

        PK_MCMD: begin
          s2_mcmd = 1'b1;
          if (ms[mc2][MS_PIPE_INV]) begin
            e.valid = 1'b0;
            e.dirty = 1'b0;
            e.pres  = '0;
            e.tip   = 1'b0;
            s2_mcmd_st = MS_RESP;
          end else if (m_hit[mc2]) begin
            unique case (rl_kind[0].kind)
              K_ACQ: begin
                grow_t = rl_kind[0].grow;
                e = acq_final(e, agent_of(rl_src[0]), grow_t);
                s2_mcmd_grant_t = e.tip;
                s2_mcmd_st = MS_RESP;
              end
              K_PUT: begin
                e.dirty    = 1'b1;
                s2_mcmd_st = MS_PUTW;
              end
              default: s2_mcmd_st = MS_RESP;
            endcase
          end else begin
            // Miss whose victim had to be probed: the victim's state is now final.
            if (e.pres != '0) s2_err = 1'b1;
            s2_mcmd_wb       = e.valid && e.dirty;
            s2_mcmd_vact_clr = !(e.valid && e.dirty);
            e.tag   = rl_tag[1];
            e.valid = 1'b1;
            e.dirty = rl_kind[0].kind == K_PUT;
            e.pres  = (rl_kind[0].kind == K_ACQ) ? N_AGENTS'(1) << agent_of(rl_src[0]) : '0;
            e.tip   = rl_kind[0].kind == K_ACQ;
            s2_mcmd_grant_t = 1'b1;
            s2_mcmd_st = (e.valid && s2_mcmd_wb) ? MS_VREAD : m_need_fill[mc2] ? MS_FILL : MS_PUTW;
          end
        end

        default: begin   // PK_ACQ, PK_GET, PK_PUT: allocate MSHR m_new
          s2_alloc     = 1'b1;
          s2_alloc_hit = hit2;
          if (hit2) begin
            ev_hit_o     = 1'b1;
            s2_alloc_way = hw2;
            unique case (p2_q.kind)
              PK_ACQ:  p = a2_growt ? (e.pres & ~me) : (e.tip && e.pres != me) ? (e.pres & ~me) : '0;
              PK_GET:  p = e.tip ? e.pres : '0;
              default: p = e.pres;
            endcase
            s2_alloc_probe  = p;
            s2_alloc_pcap_n = !(p2_q.kind == PK_GET || (p2_q.kind == PK_ACQ && !a2_growt));
            if (hp_s) begin                 // p != '0
              s2_alloc_st = MS_PROBE;
            end else begin
              unique case (p2_q.kind)
                PK_ACQ: begin
                  e = acq_final(e, a2_ag, a2_growt);
                  s2_alloc_grant_t = e.tip;
                  s2_alloc_st = MS_RESP;
                end
                PK_PUT: begin
                  e.dirty     = 1'b1;
                  s2_alloc_st = MS_PUTW;
                end
                default: s2_alloc_st = MS_RESP;
              endcase
            end
          end else begin
            ev_miss_o     = 1'b1;
            s2_alloc_way  = vw2;
            s2_alloc_fill = !full_put2;
            s2_alloc_vline = line_of(vic.tag, set2);
            if (vp_s) begin                 // vic.valid && vic.pres != '0
              // The victim is held by agents: probe them first; its tag stays until resolved.
              e               = vic;
              s2_alloc_probe  = vic.pres;
              s2_alloc_pcap_n = 1'b1;
              s2_alloc_pvict  = 1'b1;
              s2_alloc_vact   = 1'b1;
              s2_alloc_st     = MS_PROBE;
            end else begin
              s2_alloc_wb   = vd_s;           // vic.valid && vic.dirty
              s2_alloc_vact = vd_s;
              s2_alloc_st   = vd_s ? MS_VREAD : full_put2 ? MS_PUTW : MS_FILL;
              e.tag   = tag2;               // every field: the new entry does not depend on the victim's
              e.valid = 1'b1;
              e.dirty = p2_q.kind == PK_PUT;
              e.pres  = (p2_q.kind == PK_ACQ) ? me : '0;
              e.tip   = p2_q.kind == PK_ACQ;
              s2_alloc_grant_t = 1'b1;
            end
          end
          dir_wplru_v = plru_touch(row2.plru, sw2);
        end
      endcase
    end
    dir_went = e;
  end

  always_ff @(posedge clk) begin
    h0_hit_q  <= set2 == set1;
    h1_hit_q  <= h0_set_q == set1;
    if (rst) begin                     // as h0_way_q, h1_way_q, h0_pl_q and h1_pl_q
      for (int w = 0; w < WAYS; w++) bsel_q[w] <= 2'd0;
      bpl_q <= 2'd0;
    end else begin
      for (int w = 0; w < WAYS; w++)
        bsel_q[w] <= (set2 == set1 && dir_wway[w])               ? 2'd1 :
                     (h0_set_q == set1 && h0_way_q[w])           ? 2'd2 :
                     (DIR_S3 && h1_set_q == set1 && h1_way_q[w]) ? 2'd3 : 2'd0;
      bpl_q <= (set2 == set1 && dir_wplru)               ? 2'd1 :
               (h0_set_q == set1 && h0_pl_q)             ? 2'd2 :
               (DIR_S3 && h1_set_q == set1 && h1_pl_q)   ? 2'd3 : 2'd0;
    end
    hc1_q     <= h0_ent_q.valid && h0_ent_q.tag == tag1;
    hc2_q     <= h1_ent_q.valid && h1_ent_q.tag == tag1;
    cin_seq_q <= set_of(cin_line) == set1;
    for (int m = 0; m < N_MSHR; m++) sm1_q[m] <= set_of(m_line[m]) == set1;
    newm_q    <= s2_alloc ? N_MSHR'(1) << m_new : '0;
  end

  // ---------------------------------------------------------------------------------------------
  // Probe sender (B)
  // ---------------------------------------------------------------------------------------------
  logic [N_MSHR-1:0] pr_req;
  logic [MW-1:0]     pr_ptr_q, pr_m;
  logic [AGENT_W-1:0] pr_ag;
  always_comb begin
    logic [N_AGENTS-1:0] todo;
    for (int m = 0; m < N_MSHR; m++) pr_req[m] = ms[m][MS_PROBE] && (m_ppend[m] & ~m_psent[m]) != '0;
    pr_m  = rr_pick(pr_req, pr_ptr_q);
    todo  = m_ppend[pr_m] & ~m_psent[pr_m];
    pr_ag = '0;
    for (int a = N_AGENTS - 1; a >= 0; a--) if (todo[a]) pr_ag = AGENT_W'(a);
  end
  always_comb begin
    b_o         = '0;
    b_o.opcode  = B_PROBE_BLOCK;
    b_o.param   = m_pcap_n[pr_m] ? TL_CAP_TO_N : TL_CAP_TO_B;
    b_o.size    = 3'd6;
    b_o.source  = TL_SRC_W'({SRC_HI_W'(SRC_L1D0) + SRC_HI_W'(pr_ag), 6'd0});
    b_o.address = {line_of(m_pvict[pr_m] ? rl_vtag[0] : rl_tag[2], rl_set[LP_PR]), 6'd0};
  end
  assign b_valid_o  = |pr_req;
  assign ev_probe_o = b_valid_o && b_ready_i;
  // The probe handshake's effects (200 MHz, DR-142): the crossbar's ready arrives last (its B
  // arbiter weighs both banks' probes), so the flag each probe sets is selected ahead of it and kept
  // apart (synthesis merged the select with the ready and the allocation's clear, 3 LUT levels past
  // the ready), and the ready enters one LUT before each flag's enable; the pointer takes the
  // handshake as its clock enable. The probe on B is MSHR pr_m's, for its lowest agent still to
  // probe, so each MSHR's select is the pick's decode and that MSHR's own lowest agent (no 24:1
  // select of the agent).
  (* direct_enable = "yes" *) wire pr_fire = b_valid_o && b_ready_i;
  (* keep = "true" *) logic [N_MSHR-1:0]                ps_hit;   // the probe on B is MSHR m's
  (* keep = "true" *) logic [N_MSHR-1:0][N_AGENTS-1:0]  ps_sel;   // ... and for agent a
  always_comb
    for (int m = 0; m < N_MSHR; m++) begin
      logic [N_AGENTS-1:0] todo_m;
      todo_m    = m_ppend[m] & ~m_psent[m];
      ps_hit[m] = b_valid_o && pr_m == MW'(m);
      ps_sel[m] = ps_hit[m] ? todo_m & ~(todo_m - 1'b1) : '0;    // the lowest bit of todo_m
    end

  // Each MSHR's way in flip-flops, for the compares that look at every MSHR at once (the reservations,
  // the ProbeAck search). MWAY_OH stores it one-hot, so those compares take it without a decode; the
  // binary form decodes it there. Written at allocation, like the MSHR's LUTRAM copy (rl_way).
  if (MWAY_OH) begin : g_mway_oh
    always_ff @(posedge clk) if (!rst && s2_alloc) m_way_oh[m_new] <= WAYS'(1) << s2_alloc_way;
  end else begin : g_mway_bin
    logic [2:0] m_way [N_MSHR];
    always_ff @(posedge clk) if (!rst && s2_alloc) m_way[m_new] <= s2_alloc_way;
    always_comb for (int m = 0; m < N_MSHR; m++) m_way_oh[m] = WAYS'(1) << m_way[m];
  end

  // ---------------------------------------------------------------------------------------------
  // AXI read requests (fills)
  // ---------------------------------------------------------------------------------------------
  logic [N_MSHR-1:0] ar_req;
  logic [MW-1:0]     ar_ptr_q, ar_m;
  always_comb begin
    for (int m = 0; m < N_MSHR; m++) ar_req[m] = m_valid[m] && m_need_fill[m] && !m_ar_sent[m];
    ar_m = rr_pick(ar_req, ar_ptr_q);
  end
  always_comb begin
    ar_o       = '0;
    ar_o.id    = AXI_ID_W'(ar_m);
    ar_o.addr  = AXI_ADDR_W'({line_of(rl_tag[3], rl_set[LP_AR]), 6'd0});
    ar_o.len   = 8'd3;
    ar_o.size  = 3'd4;
    ar_o.burst = AXI_INCR;
  end
  assign ar_valid_o = |ar_req;

  // ---------------------------------------------------------------------------------------------
  // Data array: one half-row write and one row read per cycle
  // ---------------------------------------------------------------------------------------------
  logic             da_we_any;
  logic [31:0]      da_we;
  logic [RAW-1:0]   da_waddr;
  logic [255:0]     da_wdata;
  logic             da_re;
  logic [RAW-1:0]   da_raddr;
  logic [255:0]     da_rdata;
  // Read latency DATA_LAT: the output register (2), plus cascade pipeline stages above 2 (4 for the
  // 4-deep URAM cascade at 200 MHz). The read-tag pipeline below follows it.
  if (DATA_LAT < 2) begin : g_bad_lat
    $error("tg_l2_bank: DATA_LAT must be at least 2 (output register)");
  end
  tg_ram_sdp #(.DEPTH(SETS * WAYS * 2), .WIDTH(256), .BYTE_W(8), .OUT_REG(1'b1), .RD_LAT(DATA_LAT),
               .PRIM(DATA_PRIM)) u_data (
    .clk, .we (da_we), .waddr (da_waddr), .wdata (da_wdata), .re (da_re), .raddr (da_raddr), .rdata (da_rdata)
  );

  // Write sources, highest priority first: C data, Put data, fills.
  wire [LINE_W-1:0] cw_line = cin_line;
  wire c_wr = cin_st_q == CI_WRITE;

  // Put write engine
  logic [N_MSHR-1:0] pw_req;
  logic [MW-1:0]     pw_ptr_q, pw_m;
  logic              pw_busy_q;
  logic [MW-1:0]     pw_cur_q;
  logic [1:0]        pw_beat_q;
  always_comb begin
    for (int m = 0; m < N_MSHR; m++) pw_req[m] = ms[m][MS_PUTW];
    pw_m = rr_pick(pw_req, pw_ptr_q);
  end
  wire [3:0] pw_bv    = pb_bv_q[rl_pb[1]];
  wire       pw_wr    = pw_busy_q && !c_wr && pw_bv[pw_beat_q];
  wire       pw_adv   = pw_busy_q && (!c_wr || !pw_bv[pw_beat_q]);   // the current beat is written or skipped
  wire       pw_done  = pw_adv && pw_beat_q == 2'd3;
  assign pb_raddr[0] = {rl_pb[1], pw_beat_q};

  // Fills from R, through a register slice: RREADY toward the memory path comes from a flip-flop,
  // so the MSHR-state lookup below stays inside the bank.
  axi_r_t r_s;
  logic   r_s_v, r_s_r;
  tg_skid #(.T(axi_r_t), .DSP(RSLICE_DSP)) u_rslice (
    .clk, .rst, .in_valid (r_valid_i), .in_ready (r_ready_o), .in_data (r_i),
    .out_valid (r_s_v), .out_ready (r_s_r), .out_data (r_s)
  );
  wire [MW-1:0] r_m   = r_s.id[MW-1:0];
  wire          r_ok  = r_s_v && int'(r_s.id) < N_MSHR && ms[r_m][MS_FILL];
  assign r_s_r        = r_ok && !c_wr && !pw_wr;
  wire          f_wr  = r_s_v && r_s_r;

  // Fill beat counters, one per MSHR (R beats of different IDs interleave), in LUTRAM. A fill
  // always has four beats, so a finished fill leaves its counter at 0; the reset sequencer clears
  // them first.
  wire             fc_init = init_issue && int'(init_cnt_q) < N_MSHR;
  logic [0:0][1:0] fcnt_rd;
  tg_ram_lut #(.DEPTH(N_MSHR), .WIDTH(2), .NR(1)) u_fcnt (
    .clk, .we (f_wr || fc_init), .waddr (fc_init ? MW'(init_cnt_q) : r_m),
    .wdata (fc_init ? 2'd0 : fcnt_rd[0] + 2'd1), .raddr (r_m), .rdata (fcnt_rd)
  );
  always_comb begin
    da_we    = '0;
    da_waddr = '0;
    da_wdata = '0;
    if (c_wr) begin
      da_waddr = {set_of(cw_line), cin_way_q, cin_wcnt_q[1]};
      da_wdata = {cb_rdata[0], cb_rdata[0]};
      da_we    = cin_wcnt_q[0] ? {16'hFFFF, 16'h0} : {16'h0, 16'hFFFF};
    end else if (pw_wr) begin
      da_waddr = {rl_set[LP_PW], rl_way[1], pw_beat_q[1]};
      da_wdata = {pb_rdata[0][127:0], pb_rdata[0][127:0]};
      da_we    = pw_beat_q[0] ? {pb_rdata[0][143:128], 16'h0} : {16'h0, pb_rdata[0][143:128]};
    end else if (f_wr) begin
      da_waddr = {rl_set[LP_FL], rl_way[2], fcnt_rd[0][1]};
      da_wdata = {r_s.data, r_s.data};
      da_we    = fcnt_rd[0][0] ? {16'hFFFF, 16'h0} : {16'h0, 16'hFFFF};
    end
  end
  assign da_we_any = |da_we;
  assign cb_raddr[0] = cin_wcnt_q;

  // ---------------------------------------------------------------------------------------------
  // Victim read-out into write-back buffers, and the write-back engine (AW/W)
  // ---------------------------------------------------------------------------------------------
  logic [N_WB-1:0]   wb_free_q, wb_ready_q;
  logic [WBW-1:0]    wb_slot;
  always_comb begin
    wb_slot = '0;
    for (int i = N_WB - 1; i >= 0; i--) if (wb_free_q[i]) wb_slot = WBW'(i);
  end

  logic [N_MSHR-1:0] vr_req;
  logic [MW-1:0]     vr_ptr_q, vr_m;
  logic              vr_busy_q;
  logic [MW-1:0]     vr_cur_q;
  logic [WBW-1:0]    vr_buf_q;
  logic              vr_row_q;              // next row to read
  always_comb begin
    for (int m = 0; m < N_MSHR; m++) vr_req[m] = ms[m][MS_VREAD];
    vr_m = rr_pick(vr_req, vr_ptr_q);
  end
  wire vr_start = !vr_busy_q && |vr_req && |wb_free_q;
  wire vr_rd    = vr_busy_q;                // read port: victim read-out has priority

  // WB buffer storage: one 256-bit row per entry {buf, row}
  logic                wbm_we;
  logic [WBW:0]        wbm_waddr;
  logic [255:0]        wbm_wdata;
  logic [0:0][WBW:0]   wbm_raddr;
  logic [0:0][255:0]   wbm_rdata;
  tg_ram_lut #(.DEPTH(N_WB * 2), .WIDTH(256), .NR(1)) u_wbbuf (
    .clk, .we (wbm_we), .waddr (wbm_waddr), .wdata (wbm_wdata), .raddr (wbm_raddr), .rdata (wbm_rdata)
  );

  // Send engine
  logic           ws_busy_q, ws_aw_done_q;
  logic [WBW-1:0] ws_buf_q;
  logic [1:0]     ws_beat_q;
  logic [WBW-1:0] ws_pick;
  always_comb begin
    ws_pick = '0;
    for (int i = N_WB - 1; i >= 0; i--) if (wb_ready_q[i]) ws_pick = WBW'(i);
  end
  // Write-back buffer owner and line, written at the read-out start and read by the send engine
  typedef struct packed {
    logic [MW-1:0]    owner;
    logic [TAG_W-1:0] tag;
    logic [SET_W-1:0] set;
  } wbent_t;
  wbent_t              wbe_new;
  logic [0:0][$bits(wbent_t)-1:0] wbe_rd;
  wbent_t              wbe;
  assign wbe_new = '{owner: vr_m, tag: rl_vtag[1], set: rl_set[LP_VR]};   // VR port reads vr_m here
  tg_ram_lut #(.DEPTH(N_WB), .WIDTH($bits(wbent_t)), .NR(1)) u_wbent (
    .clk, .we (vr_start), .waddr (wb_slot), .wdata (wbe_new), .raddr (ws_buf_q), .rdata (wbe_rd)
  );
  assign wbe = wbe_rd[0];
  always_comb begin
    aw_o       = '0;
    aw_o.id    = AXI_ID_W'(wbe.owner);
    aw_o.addr  = AXI_ADDR_W'({line_of(wbe.tag, wbe.set), 6'd0});
    aw_o.len   = 8'd3;
    aw_o.size  = 3'd4;
    aw_o.burst = AXI_INCR;
  end
  assign aw_valid_o = ws_busy_q && !ws_aw_done_q;
  assign wbm_raddr[0] = {ws_buf_q, ws_beat_q[1]};
  always_comb begin
    w_o      = '0;
    w_o.data = ws_beat_q[0] ? wbm_rdata[0][255:128] : wbm_rdata[0][127:0];
    w_o.strb = '1;
    w_o.last = ws_beat_q == 2'd3;
  end
  assign w_valid_o = ws_busy_q && ws_aw_done_q;
  assign ev_wb_o   = aw_valid_o && aw_ready_i;
  assign bresp_ready_o = 1'b1;

  // ---------------------------------------------------------------------------------------------
  // Responses: rows read into the D FIFO through a 2-stage read pipeline (order preserved)
  // ---------------------------------------------------------------------------------------------
  typedef struct packed {
    tl_d_t d;
    logic  last;
  } dbeat_t;

  typedef struct packed {
    logic       v;
    logic       to_wb;     // victim read-out row
    logic [WBW:0] wb_addr;
    logic       vr_last;   // the second victim row: the MSHR may move on
    logic [MW-1:0] m;
    logic [1:0] nb;        // beats from this row: 1 or 2 (0 = none)
    logic       half;      // for nb = 1: which half
    logic       use_ram;   // else zero data (no-data or denied responses)
    logic       last;      // carries the message's last beat
    tl_d_t      hdr;
  } rtag_t;

  logic [N_MSHR-1:0] rs_req;
  logic [MW-1:0]     rs_ptr_q, rs_m;
  logic              rs_busy_q;
  logic [MW-1:0]     rs_cur_q;
  logic              rs_row_q;               // next row index (for 4-beat responses)
  logic [4:0]        d_credit_q;             // FIFO slots not yet reserved
  always_comb begin
    for (int m = 0; m < N_MSHR; m++) rs_req[m] = ms[m][MS_RESP];
    rs_m = rr_pick(rs_req, rs_ptr_q);
  end

  // The current response's shape
  wire          rs_acq    = rl_kind[1].kind == K_ACQ;
  wire          rs_data   = (rs_acq && rl_rsp[0].block) || rl_kind[1].kind == K_GET;
  wire          rs_den    = m_ferr[rs_cur_q];
  wire [2:0]    rs_size   = rl_rsp[0].size;
  wire          rs_two    = rs_data && rs_size == 3'd6;          // two rows
  wire [1:0]    rs_nb     = !rs_data ? 2'd1 : (rs_size <= 3'd4) ? 2'd1 : 2'd2;
  wire          rs_lastrow = !rs_two || rs_row_q;
  logic         rs_issue;
  rtag_t        rs_tag;
  always_comb begin
    rs_tag          = '0;
    rs_tag.v        = 1'b1;
    rs_tag.m        = rs_cur_q;
    rs_tag.nb       = rs_nb;
    rs_tag.half     = rl_rsp[0].off[0];
    rs_tag.use_ram  = rs_data && !rs_den;
    rs_tag.last     = rs_lastrow;
    rs_tag.hdr.opcode  = rs_acq ? (rs_data ? D_GRANT_DATA : D_GRANT) : rs_data ? D_ACCESS_ACK_DATA : D_ACCESS_ACK;
    rs_tag.hdr.param   = rs_acq ? (m_grant_t[rs_cur_q] ? TL_CAP_TO_T[1:0] : TL_CAP_TO_B[1:0]) : 2'd0;
    rs_tag.hdr.size    = rs_size;
    rs_tag.hdr.source  = rl_src[1];
    rs_tag.hdr.sink    = rs_acq ? TL_SINK_W'({1'(BANK), SINK_MSHR_W'(rs_cur_q)}) : '0;
    rs_tag.hdr.denied  = rs_den;
    rs_tag.hdr.corrupt = rs_den && rs_data;
  end
  assign rs_issue = rs_busy_q && !vr_rd && d_credit_q >= 5'(rs_nb);
  wire rs_done = rs_issue && rs_lastrow;

  always_comb begin
    da_re    = 1'b0;
    da_raddr = '0;
    if (vr_rd) begin
      da_re    = 1'b1;
      da_raddr = {rl_set[LP_VR], rl_way[3], vr_row_q};
    end else if (rs_issue && rs_tag.use_ram) begin
      da_re    = 1'b1;
      da_raddr = {rl_set[LP_RS], rl_way[4], rs_two ? rs_row_q : rl_rsp[0].off[1]};
    end
  end

  // Read tags travel with the data array's latency; rt_out meets the data.
  rtag_t rt_q [DATA_LAT];
  rtag_t rt_in, rt_out;
  always_comb begin
    rt_in = '0;
    if (vr_rd) begin
      rt_in.v       = 1'b1;
      rt_in.to_wb   = 1'b1;
      rt_in.wb_addr = {vr_buf_q, vr_row_q};
      rt_in.vr_last = vr_row_q;
      rt_in.m       = vr_cur_q;
      rt_in.use_ram = 1'b1;
    end else if (rs_issue) begin
      rt_in = rs_tag;
    end
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < DATA_LAT; i++) rt_q[i].v <= 1'b0;
    end else begin
      rt_q[0] <= rt_in;
      for (int i = 1; i < DATA_LAT; i++) rt_q[i] <= rt_q[i - 1];
    end
  end
  assign rt_out = rt_q[DATA_LAT - 1];

  assign wbm_we    = rt_out.v && rt_out.to_wb;
  assign wbm_waddr = rt_out.wb_addr;
  assign wbm_wdata = da_rdata;

  // D FIFO: one entry per row read (one or two beats, in LUTRAM), one beat out per cycle; the
  // beat's half and the zero data of data-less responses are chosen on the way out. Responses
  // reserve their beats (d_credit_q, DFIFO beats) when they issue, and every entry holds at least
  // one beat, so DFIFO entries never overflow.
  typedef struct packed {
    tl_d_op_e             opcode;
    logic [1:0]           param;
    logic [TL_SIZE_W-1:0] size;
    logic [TL_SRC_W-1:0]  source;
    logic [TL_SINK_W-1:0] sink;
    logic                 denied;
    logic                 corrupt;
    logic [1:0]           nb;
    logic                 half;
    logic                 use_ram;
    logic                 last;
  } dhdr_t;
  localparam int DQW = idx_w(DFIFO);

  dbeat_t       df_out;
  logic         df_out_v, df_out_r;
  logic [DQW:0] dq_wp_q, dq_rp_q;
  logic         dq_beat_q;                   // beat within the head entry
  wire  [DQW:0] dq_cnt = dq_wp_q - dq_rp_q;
  wire          rt_d   = rt_out.v && !rt_out.to_wb;
  dhdr_t        dh_in, dh_out;
  logic [255:0] dr_out;
  logic [0:0][DQW-1:0]                 dq_raddr;
  logic [0:0][$bits(dhdr_t)+256-1:0]   dq_rdata;
  always_comb begin
    dh_in.opcode  = rt_out.hdr.opcode;
    dh_in.param   = rt_out.hdr.param;
    dh_in.size    = rt_out.hdr.size;
    dh_in.source  = rt_out.hdr.source;
    dh_in.sink    = rt_out.hdr.sink;
    dh_in.denied  = rt_out.hdr.denied;
    dh_in.corrupt = rt_out.hdr.corrupt;
    dh_in.nb      = rt_out.nb;
    dh_in.half    = rt_out.half;
    dh_in.use_ram = rt_out.use_ram;
    dh_in.last    = rt_out.last;
  end
  tg_ram_lut #(.DEPTH(DFIFO), .WIDTH($bits(dhdr_t) + 256), .NR(1)) u_dfifo (
    .clk, .we (rt_d), .waddr (dq_wp_q[DQW-1:0]), .wdata ({dh_in, da_rdata}), .raddr (dq_raddr), .rdata (dq_rdata)
  );
  assign dq_raddr[0]      = dq_rp_q[DQW-1:0];
  assign {dh_out, dr_out} = dq_rdata[0];
  wire dq_two = dh_out.nb == 2'd2;
  wire dq_hi  = dq_two ? dq_beat_q : dh_out.half;
  always_comb begin
    df_out           = '0;
    df_out.d.opcode  = dh_out.opcode;
    df_out.d.param   = dh_out.param;
    df_out.d.size    = dh_out.size;
    df_out.d.source  = dh_out.source;
    df_out.d.sink    = dh_out.sink;
    df_out.d.denied  = dh_out.denied;
    df_out.d.corrupt = dh_out.corrupt;
    // data: added after the D arbiter
    df_out.last      = dh_out.last && (!dq_two || dq_beat_q);
  end
  assign df_out_v = dq_cnt != '0;
  always_ff @(posedge clk) begin
    if (rst) begin
      dq_wp_q   <= '0;
      dq_rp_q   <= '0;
      dq_beat_q <= 1'b0;
    end else begin
      if (rt_d) dq_wp_q <= dq_wp_q + 1'b1;
      if (df_out_v && df_out_r) begin
        dq_beat_q <= dq_two && !dq_beat_q;
        if (!dq_two || dq_beat_q) dq_rp_q <= dq_rp_q + 1'b1;
      end
    end
  end

  // ReleaseAck queue (from the C path). It holds only the fields that vary, so every stored bit is
  // read (a FIFO in LUTRAM loses primitives whose outputs are unused).
  typedef struct packed {
    logic [TL_SIZE_W-1:0] size;
    logic [TL_SRC_W-1:0]  source;
  } rack_t;
  rack_t rack_in, rack_q;
  tl_d_t rack_out;
  logic  rack_in_v, rack_in_r, rack_out_v, rack_out_r;
  logic [1:0] rack_cnt;
  tg_fifo #(.T(rack_t), .DEPTH(2)) u_rack (
    .clk, .rst,
    .in_valid (rack_in_v), .in_ready (rack_in_r), .in_data (rack_in),
    .out_valid (rack_out_v), .out_ready (rack_out_r), .out_data (rack_q), .count (rack_cnt)
  );
  assign rack_in = '{size: cin_q.size, source: cin_q.source};
  always_comb begin
    rack_out        = '0;
    rack_out.opcode = D_RELEASE_ACK;
    rack_out.size   = rack_q.size;
    rack_out.source = rack_q.source;
  end
  assign rack_in_v = cin_st_q == CI_ACK && cin_rel;

  // D output: response FIFO and ReleaseAcks, multi-beat messages kept contiguous. The arbiter
  // carries the headers; the data (ReleaseAcks have none) joins after it, so the FIFO's half
  // select and the arbiter's choice are one level of logic.
  logic [1:0] dsel_r;
  logic       d_idx;
  tl_d_t      d_hdr;
  tg_arb #(.N(2), .T(tl_d_t)) u_darb (
    .clk, .rst,
    .in_valid ({rack_out_v, df_out_v}), .in_last ({1'b1, df_out.last}), .in_data ({rack_out, df_out.d}),
    .in_ready (dsel_r), .out_valid (d_valid_o), .out_data (d_hdr), .out_idx (d_idx), .out_ready (d_ready_i)
  );
  always_comb begin
    d_o      = d_hdr;
    d_o.data = (d_idx == 1'b0 && dh_out.use_ram) ? (dq_hi ? dr_out[255:128] : dr_out[127:0]) : '0;
  end
  assign df_out_r   = dsel_r[0];
  assign rack_out_r = dsel_r[1];
  wire unused_d = ^{rack_cnt};

  // ---------------------------------------------------------------------------------------------
  // E (GrantAck) and AXI B (write-back responses)
  // ---------------------------------------------------------------------------------------------
  assign e_ready_o = 1'b1;
  wire [MW-1:0] e_m   = e_i.sink[MW-1:0];
  wire          e_hit = e_valid_i && int'(e_m) < N_MSHR && ms[e_m][MS_ACK];
  wire [MW-1:0] bw_m  = bresp_i.id[MW-1:0];
  wire          bw_v  = bresp_valid_i && int'(bresp_i.id) < N_MSHR;

  // ---------------------------------------------------------------------------------------------
  // MSHR payload LUTRAMs (written at allocation; read by index)
  // ---------------------------------------------------------------------------------------------
  mkind_t mkind_new;
  mrsp_t  mrsp_new;
  always_comb begin
    mkind_new.grow  = a2_growt;
    mkind_new.kind  = (p2_q.kind == PK_ACQ) ? K_ACQ : (p2_q.kind == PK_GET) ? K_GET : K_PUT;
    mrsp_new.block  = p2_q.a_op == A_ACQUIRE_BLOCK;
    mrsp_new.size   = p2_q.a_size;
    mrsp_new.off    = p2_q.a_off[5:4];
  end
  // The victim read-out reads its MSHR's set at the start (vr_m) and during the read-out (vr_cur_q).
  wire [MW-1:0] vr_ra = vr_busy_q ? vr_cur_q : vr_m;
  tg_ram_lut #(.DEPTH(N_MSHR), .WIDTH(SET_W), .NR(7)) u_mset (
    .clk, .we (s2_alloc), .waddr (m_new), .wdata (set2),
    .raddr ({rs_cur_q, vr_ra, r_m, pw_cur_q, ar_m, pr_m, mcmd_pick}), .rdata (rl_set)
  );
  tg_ram_lut #(.DEPTH(N_MSHR), .WIDTH(TAG_W), .NR(4)) u_mtag (
    .clk, .we (s2_alloc), .waddr (m_new), .wdata (tag2),
    .raddr ({ar_m, pr_m, mc2, mcmd_pick}), .rdata (rl_tag)
  );
  tg_ram_lut #(.DEPTH(N_MSHR), .WIDTH(TAG_W), .NR(2)) u_mvtag (
    .clk, .we (s2_alloc), .waddr (m_new), .wdata (tag_of(s2_alloc_vline)),
    .raddr ({vr_m, pr_m}), .rdata (rl_vtag)
  );
  tg_ram_lut #(.DEPTH(N_MSHR), .WIDTH(3), .NR(5)) u_mway (
    .clk, .we (s2_alloc), .waddr (m_new), .wdata (s2_alloc_way),
    .raddr ({rs_cur_q, vr_cur_q, r_m, pw_cur_q, mc2}), .rdata (rl_way)
  );
  tg_ram_lut #(.DEPTH(N_MSHR), .WIDTH($bits(mkind_t)), .NR(3)) u_mkind (
    .clk, .we (s2_alloc), .waddr (m_new), .wdata (mkind_new),
    .raddr ({r_m, rs_cur_q, mc2}), .rdata (rl_kind)
  );
  tg_ram_lut #(.DEPTH(N_MSHR), .WIDTH(TL_SRC_W), .NR(2)) u_msrc (
    .clk, .we (s2_alloc), .waddr (m_new), .wdata (p2_q.a_src),
    .raddr ({rs_cur_q, mc2}), .rdata (rl_src)
  );
  tg_ram_lut #(.DEPTH(N_MSHR), .WIDTH(PBW), .NR(2)) u_mpb (
    .clk, .we (s2_alloc), .waddr (m_new), .wdata (p2_q.a_pb),
    .raddr ({pw_cur_q, rs_cur_q}), .rdata (rl_pb)
  );
  tg_ram_lut #(.DEPTH(N_MSHR), .WIDTH($bits(mrsp_t)), .NR(1)) u_mrsp (
    .clk, .we (s2_alloc), .waddr (m_new), .wdata (mrsp_new),
    .raddr (rs_cur_q), .rdata (rl_rsp)
  );

  // ---------------------------------------------------------------------------------------------
  // Sequential state: holding registers, engines and the MSHR file
  // ---------------------------------------------------------------------------------------------
  assign pb_we    = a_accept && a_is_put;
  assign pb_waddr = (ain_st_q == AI_EMPTY) ? {pb_slot, a_i.address[5:4]} : {ain_pb_q, ain_beat_q};
  assign pb_wdata = {a_i.mask, a_i.data};

  always_ff @(posedge clk) begin
    if (rst) begin
      init_cnt_q  <= '0;
      init_done_q <= 1'b0;
      ain_st_q    <= AI_EMPTY;
      cin_st_q    <= CI_EMPTY;
      pb_free_q   <= '1;
      wb_free_q   <= '1;
      wb_ready_q  <= '0;
      mcmd_ptr_q  <= '0;
      pr_ptr_q    <= '0;
      ar_ptr_q    <= '0;
      pw_ptr_q    <= '0;
      vr_ptr_q    <= '0;
      rs_ptr_q    <= '0;
      pw_busy_q   <= 1'b0;
      vr_busy_q   <= 1'b0;
      rs_busy_q   <= 1'b0;
      ws_busy_q   <= 1'b0;
      ws_aw_done_q <= 1'b0;
      d_credit_q  <= 5'(DFIFO);
      for (int m = 0; m < N_MSHR; m++) ms[m] <= NMS'(1) << MS_IDLE;
    end else begin
      for (int m = 0; m < N_MSHR; m++) ms[m] <= ms_d[m];
      // ---- reset sequencer ----
      if (init_issue) init_cnt_q <= init_cnt_q + 1'b1;
      if (!init_issue && !p1_v_q && !p2_v_q) init_done_q <= 1'b1;

      // ---- A holding register ----
      unique case (ain_st_q)
        AI_EMPTY: if (a_accept) begin
          ain_q <= a_i;
          if (a_is_put) begin
            ain_pb_q              <= pb_slot;
            pb_free_q[pb_slot]    <= 1'b0;
            pb_bv_q[pb_slot]      <= 4'(1) << a_i.address[5:4];
            ain_beat_q            <= a_i.address[5:4] + 1'b1;
            ain_left_q            <= tl_last_beat(a_i.size);
            ain_st_q              <= (tl_last_beat(a_i.size) != 2'd0) ? AI_COLLECT : AI_READY;
          end else begin
            ain_st_q <= AI_READY;
          end
        end
        AI_COLLECT: if (a_accept) begin
          pb_bv_q[ain_pb_q][ain_beat_q] <= 1'b1;
          ain_beat_q <= ain_beat_q + 1'b1;
          ain_left_q <= ain_left_q - 1'b1;
          if (ain_left_q == 2'd1) ain_st_q <= AI_READY;
        end
        default: if (s0_take_a) ain_st_q <= AI_EMPTY;
      endcase

      // ---- C holding register ----
      unique case (cin_st_q)
        CI_EMPTY: if (c_accept) begin
          cin_q      <= c_i;
          cin_beat_q <= 2'd1;
          cin_st_q   <= (tl_c_has_data(c_i.opcode) && tl_last_beat(c_i.size) != 2'd0) ? CI_COLLECT : CI_READY;
        end
        CI_COLLECT: if (c_accept) begin
          cin_beat_q <= cin_beat_q + 1'b1;
          if (cin_beat_q == tl_last_beat(cin_q.size)) cin_st_q <= CI_READY;
        end
        CI_READY: if (s0_take_c) cin_st_q <= CI_PIPE;
        CI_PIPE: if (s2_c) begin
          cin_way_q  <= s2_c_way;
          cin_hit_q  <= s2_c_hit;
          cin_mok_q  <= s2_c_mok;
          cin_m_q    <= s2_c_m;
          cin_wcnt_q <= 2'd0;
          cin_st_q   <= (cin_data && s2_c_hit) ? CI_WRITE : CI_ACK;
        end
        CI_WRITE: begin
          cin_wcnt_q <= cin_wcnt_q + 1'b1;
          if (cin_wcnt_q == tl_last_beat(cin_q.size)) cin_st_q <= CI_ACK;
        end
        CI_ACK: if (!cin_rel || rack_in_r) cin_st_q <= CI_EMPTY;
        default: cin_st_q <= CI_EMPTY;
      endcase

      // ---- engine pointers and busy flags ----
      if (s0_take_m)                  mcmd_ptr_q <= rr_next(mcmd_pick);
      if (pr_fire)                    pr_ptr_q   <= rr_next(pr_m);
      if (ar_valid_o && ar_ready_i)   ar_ptr_q   <= rr_next(ar_m);

      if (!pw_busy_q && |pw_req) begin
        pw_busy_q <= 1'b1;
        pw_cur_q  <= pw_m;
        pw_beat_q <= 2'd0;
        pw_ptr_q  <= rr_next(pw_m);
      end else if (pw_adv) begin
        pw_beat_q <= pw_beat_q + 1'b1;
        if (pw_done) pw_busy_q <= 1'b0;
      end

      if (vr_start) begin
        vr_busy_q             <= 1'b1;
        vr_cur_q              <= vr_m;
        vr_buf_q              <= wb_slot;
        vr_row_q              <= 1'b0;
        vr_ptr_q              <= rr_next(vr_m);
        wb_free_q[wb_slot]    <= 1'b0;
      end else if (vr_rd) begin
        vr_row_q <= 1'b1;
        if (vr_row_q) vr_busy_q <= 1'b0;
      end
      if (rt_out.v && rt_out.to_wb && rt_out.vr_last) wb_ready_q[rt_out.wb_addr[WBW:1]] <= 1'b1;

      if (!ws_busy_q && |wb_ready_q) begin
        ws_busy_q            <= 1'b1;
        ws_aw_done_q         <= 1'b0;
        ws_buf_q             <= ws_pick;
        ws_beat_q            <= 2'd0;
        wb_ready_q[ws_pick]  <= 1'b0;
      end else if (ws_busy_q) begin
        if (aw_valid_o && aw_ready_i) ws_aw_done_q <= 1'b1;
        if (w_valid_o && w_ready_i) begin
          ws_beat_q <= ws_beat_q + 1'b1;
          if (ws_beat_q == 2'd3) begin
            ws_busy_q           <= 1'b0;
            wb_free_q[ws_buf_q] <= 1'b1;
          end
        end
      end

      if (!rs_busy_q && |rs_req) begin
        rs_busy_q <= 1'b1;
        rs_cur_q  <= rs_m;
        rs_row_q  <= 1'b0;
        rs_ptr_q  <= rr_next(rs_m);
      end else if (rs_issue) begin
        rs_row_q <= 1'b1;
        if (rs_lastrow) rs_busy_q <= 1'b0;
      end
      d_credit_q <= d_credit_q - (rs_issue ? 5'(rs_nb) : 5'd0) + ((df_out_v && df_out_r) ? 5'd1 : 5'd0);

      // ---- MSHR file ----
      // Allocation at S2
      if (s2_alloc) begin
        m_line[m_new]      <= p2_q.line;
        m_hit[m_new]       <= s2_alloc_hit;
        m_grant_t[m_new]   <= s2_alloc_grant_t;
        m_ppend[m_new]     <= s2_alloc_probe;
        m_psent[m_new]     <= '0;
        m_pcap_n[m_new]    <= s2_alloc_pcap_n;
        m_pvict[m_new]     <= s2_alloc_pvict;
        m_vact[m_new]      <= s2_alloc_vact;
        m_vtag[m_new]      <= tag_of(s2_alloc_vline);
        m_need_wb[m_new]   <= s2_alloc_wb;
        m_wb_done[m_new]   <= 1'b0;
        m_need_fill[m_new] <= s2_alloc_fill;
        m_ar_sent[m_new]   <= 1'b0;
        m_ferr[m_new]      <= 1'b0;
      end
      // MCMD result
      if (s2_mcmd) begin
        if (ms[mc2][MS_PIPE_RES]) begin
          if (rl_kind[0].kind == K_ACQ) m_grant_t[mc2] <= s2_mcmd_grant_t;
          if (!m_hit[mc2]) begin
            m_need_wb[mc2] <= s2_mcmd_wb;
            if (s2_mcmd_vact_clr) m_vact[mc2] <= 1'b0;
          end
        end
      end
      // Probes sent and acknowledged
      for (int m = 0; m < N_MSHR; m++) if (b_ready_i && ps_hit[m]) m_psent[m] <= m_psent[m] | ps_sel[m];
      if (ev_pack) m_ppend[cin_m_q] <= m_ppend[cin_m_q] & ~onehot_ag(cin_ag);
      // AXI reads
      if (ar_valid_o && ar_ready_i) m_ar_sent[ar_m] <= 1'b1;
      if (f_wr && r_s.resp != AXI_OKAY) m_ferr[r_m] <= 1'b1;
      // Put written: free its buffer
      if (pw_done) pb_free_q[rl_pb[1]] <= 1'b1;
      // Response issued in full (a Put whose fill failed never reached MS_PUTW: free its buffer here)
      if (rs_done && rl_kind[1].kind == K_PUT && m_ferr[rs_cur_q]) pb_free_q[rl_pb[0]] <= 1'b1;
      // Write-back response; an MSHR waiting only for it is freed the cycle after
      // (the B may arrive in the same cycle the MSHR enters MS_WBWAIT).
      if (bw_v) begin
        m_wb_done[bw_m] <= 1'b1;
        m_vact[bw_m]    <= 1'b0;
      end
    end
  end

  // MSHR state transitions. Every event applies to an MSHR in one state only, so the next state is
  // selected by the current state, without priority among the event sources. In the one-hot state
  // each event is qualified by its source state's bit, clears it and sets its target's.
  wire ev_pack = cin_st_q == CI_ACK && !cin_rel && cin_mok_q;    // a ProbeAck has been processed
  wire ev_vrf  = rt_out.v && rt_out.to_wb && rt_out.vr_last;     // victim read out
  wire ev_fill = f_wr && r_s.last;                               // last fill beat written
  wire [NMS-1:0] mcmd_oh  = NMS'(1) << s2_mcmd_st;
  wire           fill_put = rl_kind[2].kind == K_PUT;
  always_comb begin
    for (int m = 0; m < N_MSHR; m++) begin
      logic [NMS-1:0] c, n, lv;
      logic wbp, ferr, go_al, go_mp, go_mc, go_pk, go_vr, go_vf, go_fl, go_pw, go_rs, go_e, go_wb;
      c     = ms[m];
      wbp   = m_need_wb[m] && !m_wb_done[m];   // the victim write-back still waits for its B
      ferr  = r_s.resp != AXI_OKAY || m_ferr[m];
      go_al = c[MS_IDLE] && s2_alloc && m_new == MW'(m);
      go_mp = (c[MS_RESUME] || c[MS_INVAL]) && s0_take_m && mcmd_pick == MW'(m);
      go_mc = (c[MS_PIPE_RES] || c[MS_PIPE_INV]) && s2_mcmd && mc2 == MW'(m);
      go_pk = c[MS_PROBE] && ev_pack && cin_m_q == MW'(m) && (m_ppend[m] & ~onehot_ag(cin_ag)) == '0;
      go_vr = c[MS_VREAD] && vr_start && vr_m == MW'(m);
      go_vf = c[MS_VWAIT] && ev_vrf && rt_out.m == MW'(m);
      go_fl = c[MS_FILL] && ev_fill && r_m == MW'(m);
      go_pw = c[MS_PUTW] && pw_done && pw_cur_q == MW'(m);
      go_rs = c[MS_RESP] && rs_done && rs_cur_q == MW'(m);
      go_e  = c[MS_ACK] && e_valid_i && e_m == MW'(m);
      go_wb = c[MS_WBWAIT] && m_wb_done[m];
      lv    = '0;                              // the state left
      lv[MS_IDLE]     = go_al;
      lv[MS_RESUME]   = go_mp;
      lv[MS_INVAL]    = go_mp;
      lv[MS_PIPE_RES] = go_mc;
      lv[MS_PIPE_INV] = go_mc;
      lv[MS_PROBE]    = go_pk;
      lv[MS_VREAD]    = go_vr;
      lv[MS_VWAIT]    = go_vf;
      lv[MS_FILL]     = go_fl;
      lv[MS_PUTW]     = go_pw;
      lv[MS_RESP]     = go_rs;
      lv[MS_ACK]      = go_e;
      lv[MS_WBWAIT]   = go_wb;
      n = (c & ~lv) | ({NMS{go_al}} & alloc_oh) | ({NMS{go_mc}} & mcmd_oh);
      n[MS_PIPE_RES] = n[MS_PIPE_RES] || (go_mp && c[MS_RESUME]);
      n[MS_PIPE_INV] = n[MS_PIPE_INV] || (go_mp && c[MS_INVAL]);
      n[MS_RESUME]   = n[MS_RESUME]   || go_pk;
      n[MS_VWAIT]    = n[MS_VWAIT]    || go_vr;
      n[MS_FILL]     = n[MS_FILL]     || (go_vf && m_need_fill[m]);
      n[MS_PUTW]     = n[MS_PUTW]     || (go_vf && !m_need_fill[m]) || (go_fl && !ferr && fill_put);
      n[MS_INVAL]    = n[MS_INVAL]    || (go_fl && ferr);
      n[MS_RESP]     = n[MS_RESP]     || (go_fl && !ferr && !fill_put) || go_pw;
      n[MS_ACK]      = n[MS_ACK]      || (go_rs && rs_acq);
      n[MS_WBWAIT]   = n[MS_WBWAIT]   || (go_rs && !rs_acq && wbp) || (go_e && wbp);
      n[MS_IDLE]     = n[MS_IDLE]     || (go_rs && !rs_acq && !wbp) || (go_e && !wbp) || go_wb;
      ms_d[m] = n;
    end
  end
  always_comb
    for (int m = 0; m < N_MSHR; m++) begin
      m_valid[m] = !ms[m][MS_IDLE];
      m_st[m]    = MS_IDLE;
      for (int i = 0; i < NMS; i++) if (ms[m][i]) m_st[m] = mstate_e'(i);
    end

  assign init_done_o = init_done_q;
  assign ev_err_o    = s2_err || (bresp_valid_i && bresp_i.resp != AXI_OKAY) ||
                       (f_wr && r_s.resp != AXI_OKAY);

  wire unused = ^{da_we_any, ain_q.data, ain_q.mask, ain_q.corrupt, cin_q.data, cin_q.corrupt,
                  cin_hit_q, r_s.id, bresp_i.id, e_i.sink};

`ifndef SYNTHESIS
  logic [2:0] m_way_ref [N_MSHR];        // the allocated way, binary, for the check of m_way_oh
  always_ff @(posedge clk) if (!rst && s2_alloc) m_way_ref[m_new] <= s2_alloc_way;
  logic [WAYS-1:0]  h2_way_ref;          // h2's way and PLRU enables and set, for the checks of the
  logic             h2_pl_ref;           // bypass selects
  logic [SET_W-1:0] h2_set_ref;
  always_ff @(posedge clk) begin
    h2_way_ref <= rst ? '0 : h1_way_q;
    h2_pl_ref  <= !rst && h1_pl_q;
    h2_set_ref <= h1_set_q;
  end
  row_t dir_ref [SETS];                  // the directory as S2 writes it, at once
  always_ff @(posedge clk) begin
    for (int w = 0; w < WAYS; w++) if (dir_wway[w]) dir_ref[set2].way[w] <= dir_went;
    if (dir_wplru) dir_ref[set2].plru <= dir_wplru_v;
  end
  // ---- Invariants (docs/spec/l2.md §Verification) ----
  always_ff @(posedge clk) begin
    if (!rst && init_done_q) begin
      // No two active MSHRs on one line, nor on one (set, way): the ProbeAck lookup relies on it
      for (int i = 0; i < N_MSHR; i++)
        for (int j = i + 1; j < N_MSHR; j++)
          if (m_valid[i] && m_valid[j]) begin
            assert (m_line[i] != m_line[j])
              else $error("tg_l2_bank%0d: two MSHRs on line %h", BANK, m_line[i]);
            assert (set_of(m_line[i]) != set_of(m_line[j]) || m_way_oh[i] != m_way_oh[j])
              else $error("tg_l2_bank%0d: MSHRs %0d and %0d on set %0d way %b", BANK, i, j, set_of(m_line[i]), m_way_oh[i]);
          end
      // Directory rows written by S2 keep the MESI invariant: tip implies exactly one holder
      if (dir_wway != '0 && p2_q.kind != PK_INIT && dir_went.valid && dir_went.tip)
        assert ($onehot(dir_went.pres))
          else $error("tg_l2_bank%0d: tip without a single holder (set %0d way %0d)", BANK, set2, sw2);
      assert (!s2_err) else $error("tg_l2_bank%0d: protocol error at S2 (kind %0d line %h)", BANK, p2_q.kind, p2_q.line);
      // Requests reach the bank that address bit 6 selects (the MSHR LUTRAMs store no bank bit)
      if (a_valid_i) assert (a_i.address[6] == 1'(BANK)) else $error("tg_l2_bank%0d: A address %h of the other bank", BANK, a_i.address);
      if (c_valid_i) assert (c_i.address[6] == 1'(BANK)) else $error("tg_l2_bank%0d: C address %h of the other bank", BANK, c_i.address);
      for (int m = 0; m < N_MSHR; m++) assert ($onehot(ms[m])) else $error("tg_l2_bank%0d: MSHR %0d state %b", BANK, m, ms[m]);
      // The tree picks are the flat priority encoders' picks
      assert (ar_m == rr_pick_ref(ar_req, ar_ptr_q) && pr_m == rr_pick_ref(pr_req, pr_ptr_q) &&
              mcmd_pick == rr_pick_ref(mcmd_req, mcmd_ptr_q) && pw_m == rr_pick_ref(pw_req, pw_ptr_q) &&
              vr_m == rr_pick_ref(vr_req, vr_ptr_q) && rs_m == rr_pick_ref(rs_req, rs_ptr_q))
        else $error("tg_l2_bank%0d: a round-robin pick differs from the flat encoder's", BANK);
      // The way in flip-flops, either form, is the allocated way
      for (int m = 0; m < N_MSHR; m++)
        if (m_valid[m]) assert (m_way_oh[m] == WAYS'(1) << m_way_ref[m])
          else $error("tg_l2_bank%0d: MSHR %0d way %b, allocated as %0d", BANK, m, m_way_oh[m], m_way_ref[m]);
      // The S1 set compares are the S2 compares, registered
      assert (h0_hit_q == (h0_set_q == set2) && h1_hit_q == (h1_set_q == set2))
        else $error("tg_l2_bank%0d: history set compare made in S1 differs", BANK);
      for (int w = 0; w < WAYS; w++)
        assert (bsel_q[w] == ((h0_hit_q && h0_way_q[w]) ? 2'd1 : (h1_hit_q && h1_way_q[w]) ? 2'd2 :
                              (DIR_S3 && h2_set_ref == set2 && h2_way_ref[w]) ? 2'd3 : 2'd0))
          else $error("tg_l2_bank%0d: history bypass select of way %0d made in S1 differs", BANK, w);
      assert (bpl_q == ((h0_hit_q && h0_pl_q) ? 2'd1 : (h1_hit_q && h1_pl_q) ? 2'd2 :
                        (DIR_S3 && h2_set_ref == set2 && h2_pl_ref) ? 2'd3 : 2'd0))
        else $error("tg_l2_bank%0d: history PLRU select made in S1 differs", BANK);
      assert (hc1_q == (h1_ent_q.valid && h1_ent_q.tag == tag2) && hc2_q == (h2_ent_q.valid && h2_ent_q.tag == tag2))
        else $error("tg_l2_bank%0d: history hit compare made in S1 differs", BANK);
      // A probe presented is a request's, and its flag select is the agent the probe names
      if (b_valid_o) assert (pr_req[pr_m] && ps_sel[pr_m] == onehot_ag(pr_ag))
        else $error("tg_l2_bank%0d: probe of MSHR %0d agent %0d, flag select %b", BANK, pr_m, pr_ag, ps_sel[pr_m]);
      // The victim pick is the nested form's; the late-selected consequences are e2's and vic's
      assert (vw2 == pick_victim_ref({row2.way[7].valid, row2.way[6].valid, row2.way[5].valid, row2.way[4].valid,
                                      row2.way[3].valid, row2.way[2].valid, row2.way[1].valid, row2.way[0].valid},
                                     held, resv, row2.plru))
        else $error("tg_l2_bank%0d: victim pick differs from the nested form's", BANK);
      if (s2_alloc) begin
        assert (alloc_oh == NMS'(1) << s2_alloc_st)
          else $error("tg_l2_bank%0d: allocation state %b, decided %0d", BANK, alloc_oh, s2_alloc_st);
        if (hit2) assert (hp_s == (s2_alloc_probe != '0))
          else $error("tg_l2_bank%0d: hit way's probe flag differs", BANK);
        if (!hit2) assert (vp_s == (vic.valid && vic.pres != '0) && vd_s == (vic.valid && vic.dirty))
          else $error("tg_l2_bank%0d: victim's flags differ", BANK);
      end
      // The bypassed row is the directory as S2 has written it, either RAM write timing
      if (p2_v_q && p2_q.kind != PK_INIT) assert (row2 == dir_ref[set2])
        else $error("tg_l2_bank%0d: S2 row of set %0d differs from the directory written", BANK, set2);
      for (int w = 0; w < WAYS; w++)
        assert (hitv[w] == (row2.way[w].valid && row2.way[w].tag == tag2))
          else $error("tg_l2_bank%0d: way %0d hit differs", BANK, w);
      for (int m = 0; m < N_MSHR; m++)
        assert (smatch[m] == (m_valid[m] && set_of(m_line[m]) == set2))
          else $error("tg_l2_bank%0d: MSHR %0d set compare made in S1 differs", BANK, m);
      if (cin_st_q == CI_WRITE) assert (cin_seq_q == (set_of(cin_line) == set2))
        else $error("tg_l2_bank%0d: C set compare made in S1 differs", BANK);
      // Each MSHR event finds its MSHR in the one state the transition logic expects
      if (s2_alloc)  assert (m_st[m_new] == MS_IDLE) else $error("tg_l2_bank%0d: allocation of busy MSHR %0d", BANK, m_new);
      if (s0_take_m) assert (m_st[mcmd_pick] inside {MS_RESUME, MS_INVAL}) else $error("tg_l2_bank%0d: MCMD state", BANK);
      if (s2_mcmd)   assert (m_st[mc2] inside {MS_PIPE_RES, MS_PIPE_INV}) else $error("tg_l2_bank%0d: MCMD result state", BANK);
      if (ev_pack)   assert (m_st[cin_m_q] == MS_PROBE) else $error("tg_l2_bank%0d: ProbeAck for MSHR %0d not probing", BANK, cin_m_q);
      if (vr_start)  assert (m_st[vr_m] == MS_VREAD) else $error("tg_l2_bank%0d: victim read-out state", BANK);
      if (ev_vrf)    assert (m_st[rt_out.m] == MS_VWAIT) else $error("tg_l2_bank%0d: victim read-out end state", BANK);
      if (pw_done)   assert (m_st[pw_cur_q] == MS_PUTW) else $error("tg_l2_bank%0d: Put write state", BANK);
      if (rs_done)   assert (m_st[rs_cur_q] == MS_RESP) else $error("tg_l2_bank%0d: response state", BANK);
      if (e_valid_i) assert (e_hit) else $error("tg_l2_bank%0d: GrantAck for sink %h without a Grant", BANK, e_i.sink);
    end
  end
`endif
endmodule
