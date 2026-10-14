// Synthetic logic for the S6 floorplan dry run and fill test. It occupies LUTs, flip-flops,
// LUTRAM, block RAM and DSPs the way a block of real logic does: tiles of 32 LUT6 in four
// levels between registers (16 in, 16 out), wired mostly to neighbouring tiles with a few
// longer taps, so placement and routing see realistic local and global pressure. Every LUT
// has a pseudo-random function of six distinct signals, so synthesis cannot shrink it.
// Under SYNTHESIS the LUTs are LUT6 primitives (exact count); in simulation and lint they
// are their truth tables. Not a model of any real unit.
//   TILES  tiles (32 LUTs, 32 FFs; every 4th tile adds a 16-bit adder: CARRY8)
//   NRAM   LUTRAM blocks, 64 x 32 bits, 2 read ports (10 RAM64M8 = 80 LUTs each)
//   NBRAM  block RAMs, 512 x 64 (one RAMB36 each)
//   NDSP   27 x 18 multiply-accumulates (one DSP48E2 each)
module tg_s6_fill #(
  parameter int TILES = 16,
  parameter int NRAM  = 0,
  parameter int NBRAM = 0,
  parameter int NDSP  = 0,
  parameter int SEED  = 1,
  parameter int IN_W  = 64,
  parameter int OUT_W = 64
) (
  input  logic             clk,
  input  logic [IN_W-1:0]  in,
  output logic [OUT_W-1:0] out
);
  localparam int NT = (TILES < 2) ? 2 : TILES;

  function automatic logic [63:0] mix(input logic [63:0] x);
    logic [63:0] z;
    z = x + 64'h9e37_79b9_7f4a_7c15;
    z = (z ^ (z >> 30)) * 64'hbf58_476d_1ce4_e5b9;
    z = (z ^ (z >> 27)) * 64'h94d0_49bb_1331_11eb;
    return z ^ (z >> 31);
  endfunction

  logic [NT-1:0][15:0] tq;        // tile output registers

  // Side units (LUTRAM, BRAM, DSP): unit s is fed by tiles T0(s) .. T0(s)+5 and returns
  // into tile T0(s)+6, so it stays local.
  localparam int NSIDE = NRAM + NBRAM + NDSP;
  function automatic int side_t0(input int s);
    if (s < NRAM) return (s * 5) % NT;
    if (s < NRAM + NBRAM) return ((s - NRAM) * 11 + 3) % NT;
    return ((s - NRAM - NBRAM) * 13 + 5) % NT;
  endfunction
  logic [(NSIDE > 0 ? NSIDE : 1)-1:0][15:0] so;

  // A tile's 16 inputs: 8 from the previous tile, 4 from the next, 2 from a tile far
  // away, 2 from the block inputs and the side units returning here.
  // FAR is a permutation of the tiles (a multiplier coprime to NT), so every output bit of
  // every tile has a reader and nothing is trimmed.
  function automatic int far_mul();
    for (int m = 7; m < 64; m++) begin
      int a = m, b = NT;
      while (b != 0) begin int r = a % b; a = b; b = r; end
      if (a == 1) return m;
    end
    return 1;
  endfunction
  localparam int FMUL = far_mul();

  for (genvar t = 0; t < NT; t++) begin : g_tile
    localparam int FAR = (t * FMUL + NT / 2 + 1) % NT;
    logic [15:0] in_d, in_q;
    assign in_d[7:0]   = tq[(t + NT - 1) % NT][7:0];
    assign in_d[11:8]  = tq[(t + 1) % NT][11:8];
    assign in_d[13:12] = tq[FAR][13:12];
    logic [1:0] side;
    always_comb begin
      side = '0;
      for (int u = 0; u < NSIDE; u++)
        if ((side_t0(u) + 6) % NT == t) side ^= {^so[u][15:8], ^so[u][7:0]};
    end
    // block inputs: every bit j goes to tile (j / 2) mod NT, folded into two bits
    logic [1:0] fin;
    always_comb begin
      fin = '0;
      for (int j = 0; j < IN_W; j++) if ((j / 2) % NT == t) fin[j % 2] ^= in[j];
    end
    assign in_d[15:14] = tq[(t + 2) % NT][15:14] ^ fin ^ side;
    always_ff @(posedge clk) in_q <= in_d;

    // Four levels of 8 LUT6 (each level reads the previous one: not a loop)
    /* verilator lint_off UNOPTFLAT */
    logic [3:0][7:0] lv;
    /* verilator lint_on UNOPTFLAT */
    for (genvar l = 0; l < 4; l++) begin : g_lvl
      for (genvar k = 0; k < 8; k++) begin : g_lut
        localparam logic [63:0] H = mix(64'(SEED) * 64'h1_0000_0000 + 64'(t) * 64 + 64'(l * 8 + k));
        logic [5:0] i;
        if (l == 0) begin : g_l0
          for (genvar j = 0; j < 6; j++) begin : g_i
            assign i[j] = in_q[(k * 2 + j * 3 + j / 3) % 16];
          end
        end else begin : g_ln
          // three from the previous level, three from the tile inputs
          for (genvar j = 0; j < 3; j++) begin : g_p
            assign i[j] = lv[l - 1][(k + j * 3) % 8];
          end
          for (genvar j = 3; j < 6; j++) begin : g_q
            assign i[j] = in_q[(k * 5 + j * 2 + l) % 16];
          end
        end
`ifdef SYNTHESIS
        LUT6 #(.INIT(H)) u_lut (.O(lv[l][k]), .I0(i[0]), .I1(i[1]), .I2(i[2]), .I3(i[3]),
                                .I4(i[4]), .I5(i[5]));
`else
        assign lv[l][k] = H[i];
`endif
      end
    end

    logic [15:0] out_d;
    if (t % 4 == 0) begin : g_add
      assign out_d = {lv[3], lv[1]} + in_q;
    end else begin : g_noadd
      assign out_d = {lv[3], lv[1]};
    end
    always_ff @(posedge clk) tq[t] <= out_d;
  end

  // ---- Side units ----
  for (genvar r = 0; r < NRAM; r++) begin : g_ram
    localparam int T0 = side_t0(r);
    logic [1:0][5:0]  ra;
    logic [1:0][31:0] rd;
    assign ra[0] = tq[T0][5:0];
    assign ra[1] = tq[(T0 + 2) % NT][11:6];
    tg_ram_lut #(.DEPTH(64), .WIDTH(32), .NR(2)) u_ram (
      .clk, .we(tq[(T0 + 1) % NT][0]), .waddr(tq[(T0 + 1) % NT][6:1]),
      .wdata({tq[(T0 + 3) % NT], tq[(T0 + 4) % NT]}), .raddr(ra), .rdata(rd));
    always_ff @(posedge clk) so[r] <= rd[0][15:0] ^ rd[0][31:16] ^ rd[1][15:0] ^ rd[1][31:16];
  end
  for (genvar b = 0; b < NBRAM; b++) begin : g_bram
    localparam int T0 = side_t0(NRAM + b);
    logic [63:0] rd;
    tg_ram_sdp #(.DEPTH(512), .WIDTH(64), .OUT_REG(1'b1), .PRIM("block")) u_bram (
      .clk, .we(tq[T0][15]), .waddr(tq[T0][8:0]),
      .wdata({tq[(T0 + 1) % NT], tq[(T0 + 2) % NT], tq[(T0 + 3) % NT], tq[(T0 + 4) % NT]}),
      .re(1'b1), .raddr(tq[(T0 + 5) % NT][8:0]), .rdata(rd));
    always_ff @(posedge clk) so[NRAM + b] <= rd[15:0] ^ rd[31:16] ^ rd[47:32] ^ rd[63:48];
  end
  for (genvar d = 0; d < NDSP; d++) begin : g_dsp
    localparam int T0 = side_t0(NRAM + NBRAM + d);
    // signed 27 x 18: one DSP48E2 (unsigned operands of these widths would need two)
    logic signed [26:0] a_q;
    logic signed [17:0] b_q;
    logic signed [44:0] m_q;
    logic signed [47:0] acc_q;
    always_ff @(posedge clk) begin
      a_q   <= {tq[T0][10:0], tq[(T0 + 1) % NT]};
      b_q   <= {tq[(T0 + 2) % NT][1:0], tq[(T0 + 3) % NT]};
      m_q   <= a_q * b_q;
      acc_q <= acc_q + 48'(m_q);
    end
    always_ff @(posedge clk) so[NRAM + NBRAM + d] <= acc_q[47:32];
  end
  if (NSIDE == 0) begin : g_noside
    assign so = '0;
  end

  // ---- Outputs: the first tiles' registers. The tiles form a ring, so every tile reaches
  // them and nothing is trimmed. ----
  for (genvar o = 0; o < OUT_W; o += 16) begin : g_out
    assign out[o +: 16] = tq[(o / 16) % NT];
  end
  if (OUT_W % 16 != 0) begin : g_bad
    $error("tg_s6_fill: OUT_W must be a multiple of 16");
  end
endmodule
