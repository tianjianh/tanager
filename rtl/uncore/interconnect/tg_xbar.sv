// TileLink interconnect (docs/spec/uncore.md): routes the l1i, l1d and mmio ports of N_CORES cores
// and an optional host DMA port to the L2 banks, the boot ROM, the device bus and an error
// responder. Requests are routed by address (tg_map_pkg) and initiator type, C by address, E by
// sink; D and B return by source[9:6], which the interconnect sets on A and C.
// Arbiters lock onto multi-beat messages; register slices sit on every output when SLICE = 1.
module tg_xbar
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;
#(
  parameter int N_CORES  = NUM_CORES,
  parameter bit HOST_DMA = 1'b0,
  parameter bit SLICE    = 1'b1
) (
  input  logic                 clk,
  input  logic                 rst,

  // ---- Initiators (core ports) ----
  input  tl_a_t [N_CORES-1:0]  l1i_a_i,
  input  logic  [N_CORES-1:0]  l1i_a_valid_i,
  output logic  [N_CORES-1:0]  l1i_a_ready_o,
  output tl_d_t [N_CORES-1:0]  l1i_d_o,
  output logic  [N_CORES-1:0]  l1i_d_valid_o,
  input  logic  [N_CORES-1:0]  l1i_d_ready_i,

  input  tl_a_t [N_CORES-1:0]  l1d_a_i,
  input  logic  [N_CORES-1:0]  l1d_a_valid_i,
  output logic  [N_CORES-1:0]  l1d_a_ready_o,
  output tl_b_t [N_CORES-1:0]  l1d_b_o,
  output logic  [N_CORES-1:0]  l1d_b_valid_o,
  input  logic  [N_CORES-1:0]  l1d_b_ready_i,
  input  tl_c_t [N_CORES-1:0]  l1d_c_i,
  input  logic  [N_CORES-1:0]  l1d_c_valid_i,
  output logic  [N_CORES-1:0]  l1d_c_ready_o,
  output tl_d_t [N_CORES-1:0]  l1d_d_o,
  output logic  [N_CORES-1:0]  l1d_d_valid_o,
  input  logic  [N_CORES-1:0]  l1d_d_ready_i,
  input  tl_e_t [N_CORES-1:0]  l1d_e_i,
  input  logic  [N_CORES-1:0]  l1d_e_valid_i,
  output logic  [N_CORES-1:0]  l1d_e_ready_o,

  input  tl_a_t [N_CORES-1:0]  mmio_a_i,
  input  logic  [N_CORES-1:0]  mmio_a_valid_i,
  output logic  [N_CORES-1:0]  mmio_a_ready_o,
  output tl_d_t [N_CORES-1:0]  mmio_d_o,
  output logic  [N_CORES-1:0]  mmio_d_valid_o,
  input  logic  [N_CORES-1:0]  mmio_d_ready_i,

  input  tl_a_t                hdma_a_i,
  input  logic                 hdma_a_valid_i,
  output logic                 hdma_a_ready_o,
  output tl_d_t                hdma_d_o,
  output logic                 hdma_d_valid_o,
  input  logic                 hdma_d_ready_i,

  // ---- Targets ----
  output tl_a_t [N_BANKS-1:0]  l2_a_o,
  output logic  [N_BANKS-1:0]  l2_a_valid_o,
  input  logic  [N_BANKS-1:0]  l2_a_ready_i,
  input  tl_b_t [N_BANKS-1:0]  l2_b_i,
  input  logic  [N_BANKS-1:0]  l2_b_valid_i,
  output logic  [N_BANKS-1:0]  l2_b_ready_o,
  output tl_c_t [N_BANKS-1:0]  l2_c_o,
  output logic  [N_BANKS-1:0]  l2_c_valid_o,
  input  logic  [N_BANKS-1:0]  l2_c_ready_i,
  input  tl_d_t [N_BANKS-1:0]  l2_d_i,
  input  logic  [N_BANKS-1:0]  l2_d_valid_i,
  output logic  [N_BANKS-1:0]  l2_d_ready_o,
  output tl_e_t [N_BANKS-1:0]  l2_e_o,
  output logic  [N_BANKS-1:0]  l2_e_valid_o,
  input  logic  [N_BANKS-1:0]  l2_e_ready_i,

  output tl_a_t                rom_a_o,
  output logic                 rom_a_valid_o,
  input  logic                 rom_a_ready_i,
  input  tl_d_t                rom_d_i,
  input  logic                 rom_d_valid_i,
  output logic                 rom_d_ready_o,

  output tl_a_t                dev_a_o,
  output logic                 dev_a_valid_o,
  input  logic                 dev_a_ready_i,
  input  tl_d_t                dev_d_i,
  input  logic                 dev_d_valid_i,
  output logic                 dev_d_ready_o
);
  localparam int TW = idx_w(N_TGT);
  localparam int IW = SRC_HI_W;

  if (N_CORES < 1 || N_CORES > MAX_CORES) begin : g_bad_cores
    $error("tg_xbar: N_CORES must be 1..4");
  end

  function automatic logic present(input int i);
    if (i >= SRC_L1D0  && i < SRC_L1D0  + N_CORES) return 1'b1;
    if (i >= SRC_L1I0  && i < SRC_L1I0  + N_CORES) return 1'b1;
    if (i >= SRC_MMIO0 && i < SRC_MMIO0 + N_CORES) return 1'b1;
    if (i == SRC_HDMA) return HOST_DMA;
    return 1'b0;
  endfunction

  // Which targets an initiator's requests can reach (route_a below): the L2 banks and the error
  // responder from every initiator, the boot ROM from l1i and mmio, devices from mmio. Each
  // arbiter has only the inputs that can reach it, so no multiplexer spans the 16-entry
  // initiator index space.
  function automatic logic reaches(input int i, input int t);
    if (!present(i)) return 1'b0;
    if (t >= T_L2B0 && t < T_L2B0 + N_BANKS) return 1'b1;
    if (t == T_ROM) return (i >= SRC_L1I0 && i < SRC_L1I0 + MAX_CORES) || (i >= SRC_MMIO0 && i < SRC_MMIO0 + MAX_CORES);
    if (t == T_DEV) return i >= SRC_MMIO0 && i < SRC_MMIO0 + MAX_CORES;
    return t == T_ERR;
  endfunction
  function automatic int n_ini_of(input int t);       // initiators reaching target t
    int n;
    n = 0;
    for (int i = 0; i < N_INIT; i++) if (reaches(i, t)) n++;
    return n;
  endfunction
  function automatic int ini_of(input int t, input int k);   // the k-th of them
    int n;
    n = 0;
    for (int i = 0; i < N_INIT; i++)
      if (reaches(i, t)) begin
        if (n == k) return i;
        n++;
      end
    return 0;
  endfunction
  function automatic int n_tgt_of(input int i);       // targets answering initiator i
    int n;
    n = 0;
    for (int t = 0; t < N_TGT; t++) if (reaches(i, t)) n++;
    return n;
  endfunction
  function automatic int tgt_of(input int i, input int k);
    int n;
    n = 0;
    for (int t = 0; t < N_TGT; t++)
      if (reaches(i, t)) begin
        if (n == k) return t;
        n++;
      end
    return 0;
  endfunction

  function automatic logic [TW-1:0] route_a(input int i, input paddr_t addr);
    pma_e p;
    p = pma_of(addr);
    if (p == PMA_MEM) return TW'(T_L2B0 + int'(addr[BANK_BIT]));
    if (p == PMA_ROM && ((i >= SRC_L1I0 && i < SRC_L1I0 + MAX_CORES) ||
                         (i >= SRC_MMIO0 && i < SRC_MMIO0 + MAX_CORES))) return TW'(T_ROM);
    if (p == PMA_DEVICE && i >= SRC_MMIO0 && i < SRC_MMIO0 + MAX_CORES) return TW'(T_DEV);
    return TW'(T_ERR);
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Unified initiator view: index = source[9:6]
  // ---------------------------------------------------------------------------------------------
  tl_a_t [N_INIT-1:0] ia;
  logic  [N_INIT-1:0] ia_v, ia_r;
  tl_d_t [N_INIT-1:0] id;
  logic  [N_INIT-1:0] id_v, id_r;

  always_comb begin
    ia   = '0;
    ia_v = '0;
    id_r = '0;
    for (int c = 0; c < N_CORES; c++) begin
      ia[SRC_L1D0 + c]   = l1d_a_i[c];
      ia_v[SRC_L1D0 + c] = l1d_a_valid_i[c];
      id_r[SRC_L1D0 + c] = l1d_d_ready_i[c];
      ia[SRC_L1I0 + c]   = l1i_a_i[c];
      ia_v[SRC_L1I0 + c] = l1i_a_valid_i[c];
      id_r[SRC_L1I0 + c] = l1i_d_ready_i[c];
      ia[SRC_MMIO0 + c]   = mmio_a_i[c];
      ia_v[SRC_MMIO0 + c] = mmio_a_valid_i[c];
      id_r[SRC_MMIO0 + c] = mmio_d_ready_i[c];
    end
    if (HOST_DMA) begin
      ia[SRC_HDMA]   = hdma_a_i;
      ia_v[SRC_HDMA] = hdma_a_valid_i;
      id_r[SRC_HDMA] = hdma_d_ready_i;
    end
    for (int i = 0; i < N_INIT; i++)
      ia[i].source[TL_SRC_W-1:TL_SRC_LOCAL_W] = IW'(i);
  end

  always_comb begin
    for (int c = 0; c < N_CORES; c++) begin
      l1d_a_ready_o[c]  = ia_r[SRC_L1D0 + c];
      l1d_d_o[c]        = id[SRC_L1D0 + c];
      l1d_d_valid_o[c]  = id_v[SRC_L1D0 + c];
      l1i_a_ready_o[c]  = ia_r[SRC_L1I0 + c];
      l1i_d_o[c]        = id[SRC_L1I0 + c];
      l1i_d_valid_o[c]  = id_v[SRC_L1I0 + c];
      mmio_a_ready_o[c] = ia_r[SRC_MMIO0 + c];
      mmio_d_o[c]       = id[SRC_MMIO0 + c];
      mmio_d_valid_o[c] = id_v[SRC_MMIO0 + c];
    end
    hdma_a_ready_o = HOST_DMA ? ia_r[SRC_HDMA] : 1'b0;
    hdma_d_o       = HOST_DMA ? id[SRC_HDMA]   : '0;
    hdma_d_valid_o = HOST_DMA ? id_v[SRC_HDMA] : 1'b0;
  end

  // ---------------------------------------------------------------------------------------------
  // Channel A: initiators -> targets
  // ---------------------------------------------------------------------------------------------
  logic [N_INIT-1:0][TW-1:0] a_dst;
  logic [N_INIT-1:0]         a_last;

  for (genvar i = 0; i < N_INIT; i++) begin : g_ia
    logic [1:0] cnt_q;       // beats of the current message already sent
    assign a_dst[i]  = route_a(i, ia[i].address);
    assign a_last[i] = cnt_q == tl_a_last(ia[i].opcode, ia[i].size);
    always_ff @(posedge clk) begin
      if (rst || !present(i))      cnt_q <= '0;
      else if (ia_v[i] && ia_r[i]) cnt_q <= a_last[i] ? 2'd0 : cnt_q + 1'b1;
    end
  end

  tl_a_t [N_TGT-1:0] ta;          // arbiter outputs, before the slices
  logic  [N_TGT-1:0] ta_v, ta_r;
  logic  [N_TGT-1:0][N_INIT-1:0] ta_in_r;

  for (genvar t = 0; t < N_TGT; t++) begin : g_ta
    localparam int NS = n_ini_of(t);
    logic  [NS-1:0] req, last, rdy;
    tl_a_t [NS-1:0] din;
    for (genvar k = 0; k < NS; k++) begin : g_in
      localparam int I = ini_of(t, k);
      assign req[k]  = ia_v[I] && a_dst[I] == TW'(t);
      assign last[k] = a_last[I];
      assign din[k]  = ia[I];
    end
    tg_arb #(.N(NS), .T(tl_a_t)) u_arb (
      .clk, .rst,
      .in_valid (req), .in_last (last), .in_data (din), .in_ready (rdy),
      .out_valid (ta_v[t]), .out_data (ta[t]), .out_idx (), .out_ready (ta_r[t])
    );
    always_comb begin
      ta_in_r[t] = '0;
      for (int k = 0; k < NS; k++) ta_in_r[t][ini_of(t, k)] = rdy[k];
    end
  end

  always_comb begin
    ia_r = '0;
    for (int i = 0; i < N_INIT; i++)
      for (int t = 0; t < N_TGT; t++)
        if (a_dst[i] == TW'(t)) ia_r[i] = ia_r[i] | ta_in_r[t][i];
  end

  // Slices and target ports
  tl_a_t [N_TGT-1:0] to_a;
  logic  [N_TGT-1:0] to_a_v, to_a_r;
  for (genvar t = 0; t < N_TGT; t++) begin : g_ta_slice
    if (SLICE) begin : g_s
      tg_skid #(.T(tl_a_t)) u_s (.clk, .rst, .in_valid (ta_v[t]), .in_ready (ta_r[t]), .in_data (ta[t]),
                                 .out_valid (to_a_v[t]), .out_ready (to_a_r[t]), .out_data (to_a[t]));
    end else begin : g_w
      assign to_a[t]   = ta[t];
      assign to_a_v[t] = ta_v[t];
      assign ta_r[t]   = to_a_r[t];
    end
  end

  for (genvar b = 0; b < N_BANKS; b++) begin : g_l2a
    assign l2_a_o[b]          = to_a[T_L2B0 + b];
    assign l2_a_valid_o[b]    = to_a_v[T_L2B0 + b];
    assign to_a_r[T_L2B0 + b] = l2_a_ready_i[b];
  end
  assign rom_a_o       = to_a[T_ROM];
  assign rom_a_valid_o = to_a_v[T_ROM];
  assign to_a_r[T_ROM] = rom_a_ready_i;
  assign dev_a_o       = to_a[T_DEV];
  assign dev_a_valid_o = to_a_v[T_DEV];
  assign to_a_r[T_DEV] = dev_a_ready_i;

  // Error responder
  tl_d_t err_d;
  logic  err_d_v, err_d_r;
  tg_tl_err u_err (
    .clk, .rst,
    .a_i (to_a[T_ERR]), .a_valid_i (to_a_v[T_ERR]), .a_ready_o (to_a_r[T_ERR]),
    .d_o (err_d), .d_valid_o (err_d_v), .d_ready_i (err_d_r)
  );

  // ---------------------------------------------------------------------------------------------
  // Channel D: targets -> initiators
  // ---------------------------------------------------------------------------------------------
  tl_d_t [N_TGT-1:0] td;
  logic  [N_TGT-1:0] td_v, td_r;
  always_comb begin
    for (int b = 0; b < N_BANKS; b++) begin
      td[T_L2B0 + b]   = l2_d_i[b];
      td_v[T_L2B0 + b] = l2_d_valid_i[b];
    end
    td[T_ROM]   = rom_d_i;
    td_v[T_ROM] = rom_d_valid_i;
    td[T_DEV]   = dev_d_i;
    td_v[T_DEV] = dev_d_valid_i;
    td[T_ERR]   = err_d;
    td_v[T_ERR] = err_d_v;
  end
  for (genvar b = 0; b < N_BANKS; b++) begin : g_l2d
    assign l2_d_ready_o[b] = td_r[T_L2B0 + b];
  end
  assign rom_d_ready_o = td_r[T_ROM];
  assign dev_d_ready_o = td_r[T_DEV];
  assign err_d_r       = td_r[T_ERR];

  logic [N_TGT-1:0]          d_last;
  logic [N_TGT-1:0][IW-1:0]  d_dst;
  for (genvar t = 0; t < N_TGT; t++) begin : g_td
    logic [1:0] cnt_q;
    assign d_dst[t]  = td[t].source[TL_SRC_W-1:TL_SRC_LOCAL_W];
    assign d_last[t] = cnt_q == tl_d_last(td[t].opcode, td[t].size);
    always_ff @(posedge clk) begin
      if (rst)                     cnt_q <= '0;
      else if (td_v[t] && td_r[t]) cnt_q <= d_last[t] ? 2'd0 : cnt_q + 1'b1;
    end
  end

  logic [N_INIT-1:0][N_TGT-1:0] id_in_r;
  tl_d_t [N_INIT-1:0] ida;
  logic  [N_INIT-1:0] ida_v, ida_r;
  for (genvar i = 0; i < N_INIT; i++) begin : g_id
    if (present(i)) begin : g_p
      localparam int NT = n_tgt_of(i);
      logic  [NT-1:0] req, last, rdy;
      tl_d_t [NT-1:0] din;
      for (genvar k = 0; k < NT; k++) begin : g_in
        localparam int T = tgt_of(i, k);
        assign req[k]  = td_v[T] && d_dst[T] == IW'(i);
        assign last[k] = d_last[T];
        assign din[k]  = td[T];
      end
      tg_arb #(.N(NT), .T(tl_d_t)) u_arb (
        .clk, .rst,
        .in_valid (req), .in_last (last), .in_data (din), .in_ready (rdy),
        .out_valid (ida_v[i]), .out_data (ida[i]), .out_idx (), .out_ready (ida_r[i])
      );
      always_comb begin
        id_in_r[i] = '0;
        for (int k = 0; k < NT; k++) id_in_r[i][tgt_of(i, k)] = rdy[k];
      end
      if (SLICE) begin : g_s
        tg_skid #(.T(tl_d_t)) u_s (.clk, .rst, .in_valid (ida_v[i]), .in_ready (ida_r[i]), .in_data (ida[i]),
                                   .out_valid (id_v[i]), .out_ready (id_r[i]), .out_data (id[i]));
      end else begin : g_w
        assign id[i]    = ida[i];
        assign id_v[i]  = ida_v[i];
        assign ida_r[i] = id_r[i];
      end
    end else begin : g_np
      assign id_in_r[i] = '0;
      assign ida[i]     = '0;
      assign ida_v[i]   = 1'b0;
      assign ida_r[i]   = 1'b0;
      assign id[i]      = '0;
      assign id_v[i]    = 1'b0;
    end
  end

  always_comb begin
    td_r = '0;
    for (int t = 0; t < N_TGT; t++)
      for (int i = 0; i < N_INIT; i++)
        if (d_dst[t] == IW'(i)) td_r[t] = td_r[t] | id_in_r[i][t];
  end

  // ---------------------------------------------------------------------------------------------
  // Channel C: l1d -> L2 bank of the address
  // ---------------------------------------------------------------------------------------------
  function automatic tl_c_t c_with_src(input tl_c_t x, input logic [IW-1:0] hi);
    x.source[TL_SRC_W-1:TL_SRC_LOCAL_W] = hi;
    return x;
  endfunction

  tl_c_t [N_CORES-1:0] ic;
  logic  [N_CORES-1:0] c_last;
  logic  [N_CORES-1:0] c_bank;
  for (genvar c = 0; c < N_CORES; c++) begin : g_ic
    logic [1:0] cnt_q;
    assign ic[c]     = c_with_src(l1d_c_i[c], IW'(SRC_L1D0 + c));
    assign c_bank[c] = l1d_c_i[c].address[BANK_BIT];
    assign c_last[c] = cnt_q == tl_c_last(l1d_c_i[c].opcode, l1d_c_i[c].size);
    always_ff @(posedge clk) begin
      if (rst)                                       cnt_q <= '0;
      else if (l1d_c_valid_i[c] && l1d_c_ready_o[c]) cnt_q <= c_last[c] ? 2'd0 : cnt_q + 1'b1;
    end
  end

  logic [N_BANKS-1:0][N_CORES-1:0] c_in_r;
  for (genvar b = 0; b < N_BANKS; b++) begin : g_tc
    logic [N_CORES-1:0] req;
    tl_c_t cout;
    logic  cout_v, cout_r;
    for (genvar c = 0; c < N_CORES; c++) begin : g_req
      assign req[c] = l1d_c_valid_i[c] && c_bank[c] == 1'(b);
    end
    tg_arb #(.N(N_CORES), .T(tl_c_t)) u_arb (
      .clk, .rst,
      .in_valid (req), .in_last (c_last), .in_data (ic), .in_ready (c_in_r[b]),
      .out_valid (cout_v), .out_data (cout), .out_idx (), .out_ready (cout_r)
    );
    if (SLICE) begin : g_s
      tg_skid #(.T(tl_c_t)) u_s (.clk, .rst, .in_valid (cout_v), .in_ready (cout_r), .in_data (cout),
                                 .out_valid (l2_c_valid_o[b]), .out_ready (l2_c_ready_i[b]), .out_data (l2_c_o[b]));
    end else begin : g_w
      assign l2_c_o[b]       = cout;
      assign l2_c_valid_o[b] = cout_v;
      assign cout_r          = l2_c_ready_i[b];
    end
  end
  always_comb begin
    for (int c = 0; c < N_CORES; c++) begin
      l1d_c_ready_o[c] = 1'b0;
      for (int b = 0; b < N_BANKS; b++)
        if (c_bank[c] == 1'(b)) l1d_c_ready_o[c] = c_in_r[b][c];
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Channel E: l1d -> L2 bank in sink[5]; sink SINK_ERR is swallowed (error responder's Grants)
  // ---------------------------------------------------------------------------------------------
  logic [N_CORES-1:0] e_err, e_bank;
  for (genvar c = 0; c < N_CORES; c++) begin : g_ie
    assign e_err[c]  = l1d_e_i[c].sink == SINK_ERR;
    assign e_bank[c] = l1d_e_i[c].sink[TL_SINK_W-1];
  end
  logic [N_BANKS-1:0][N_CORES-1:0] e_in_r;
  for (genvar b = 0; b < N_BANKS; b++) begin : g_te
    logic [N_CORES-1:0] req;
    tl_e_t eout;
    logic  eout_v, eout_r;
    for (genvar c = 0; c < N_CORES; c++) begin : g_req
      assign req[c] = l1d_e_valid_i[c] && !e_err[c] && e_bank[c] == 1'(b);
    end
    tg_arb #(.N(N_CORES), .T(tl_e_t)) u_arb (
      .clk, .rst,
      .in_valid (req), .in_last ('1), .in_data (l1d_e_i), .in_ready (e_in_r[b]),
      .out_valid (eout_v), .out_data (eout), .out_idx (), .out_ready (eout_r)
    );
    if (SLICE) begin : g_s
      tg_skid #(.T(tl_e_t)) u_s (.clk, .rst, .in_valid (eout_v), .in_ready (eout_r), .in_data (eout),
                                 .out_valid (l2_e_valid_o[b]), .out_ready (l2_e_ready_i[b]), .out_data (l2_e_o[b]));
    end else begin : g_w
      assign l2_e_o[b]       = eout;
      assign l2_e_valid_o[b] = eout_v;
      assign eout_r          = l2_e_ready_i[b];
    end
  end
  always_comb begin
    for (int c = 0; c < N_CORES; c++) begin
      l1d_e_ready_o[c] = e_err[c];
      for (int b = 0; b < N_BANKS; b++)
        if (!e_err[c] && e_bank[c] == 1'(b)) l1d_e_ready_o[c] = e_in_r[b][c];
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Channel B: L2 banks -> l1d of agent source[7:6]
  // ---------------------------------------------------------------------------------------------
  logic [N_BANKS-1:0][AGENT_W-1:0] b_dst;
  for (genvar b = 0; b < N_BANKS; b++) begin : g_tb
    assign b_dst[b] = l2_b_i[b].source[TL_SRC_LOCAL_W +: AGENT_W];
  end
  logic [N_CORES-1:0][N_BANKS-1:0] b_in_r;
  for (genvar c = 0; c < N_CORES; c++) begin : g_ib
    logic [N_BANKS-1:0] req;
    tl_b_t bout;
    logic  bout_v, bout_r;
    for (genvar b = 0; b < N_BANKS; b++) begin : g_req
      assign req[b] = l2_b_valid_i[b] && b_dst[b] == AGENT_W'(c);
    end
    tg_arb #(.N(N_BANKS), .T(tl_b_t)) u_arb (
      .clk, .rst,
      .in_valid (req), .in_last ('1), .in_data (l2_b_i), .in_ready (b_in_r[c]),
      .out_valid (bout_v), .out_data (bout), .out_idx (), .out_ready (bout_r)
    );
    if (SLICE) begin : g_s
      tg_skid #(.T(tl_b_t)) u_s (.clk, .rst, .in_valid (bout_v), .in_ready (bout_r), .in_data (bout),
                                 .out_valid (l1d_b_valid_o[c]), .out_ready (l1d_b_ready_i[c]), .out_data (l1d_b_o[c]));
    end else begin : g_w
      assign l1d_b_o[c]       = bout;
      assign l1d_b_valid_o[c] = bout_v;
      assign bout_r           = l1d_b_ready_i[c];
    end
  end
  always_comb begin
    for (int b = 0; b < N_BANKS; b++) begin
      l2_b_ready_o[b] = 1'b0;
      for (int c = 0; c < N_CORES; c++)
        if (b_dst[b] == AGENT_W'(c)) l2_b_ready_o[b] = b_in_r[c][b];
    end
  end

  // Slots of absent initiators (source[9:6] values with no port in this build) are tied off.
  wire unused = ^{id_r, ida, ida_v, ida_r};

`ifndef SYNTHESIS
  // Probes go only to existing agents; E sinks name an existing bank or the error responder.
  always_ff @(posedge clk) begin
    if (!rst) begin
      for (int b = 0; b < N_BANKS; b++)
        if (l2_b_valid_i[b]) assert (int'(b_dst[b]) < N_CORES && l2_b_i[b].source[TL_SRC_W-1:TL_SRC_LOCAL_W+AGENT_W] == '0)
          else $error("tg_xbar: probe to a missing agent");
    end
  end
`endif
endmodule
