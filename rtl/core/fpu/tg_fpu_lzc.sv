// Leading-zero count of a W-bit vector (W when the vector is zero) (docs/spec/fpu.md). Two forms:
// - R4 = 0: a two-level tree, an 8-bit count per group and a one-hot select of the first
//   non-zero group. Every count bit waits for that select: at W = 165 in the core, about ten
//   LUT levels.
// - R4 = 1 (W < 255): a radix-4 tree (Oklobdzija, IEEE Trans. VLSI 2(1), 1994). Each node tells
//   whether its bits hold a one and counts the zeros above its first one: the index of its
//   first non-zero child, then that child's count. A node's index needs only its children's
//   ORs, so the count's top bits, from the widest ORs, come out first: the order in which the
//   FMA's normaliser shifts by them.
module tg_fpu_lzc #(
  parameter int  W  = 64,
  parameter bit  R4 = 1'b0,
  localparam int CW = $clog2(W + 1)
) (
  input  logic [W-1:0]  x,
  output logic [CW-1:0] cnt
);
  if (!R4) begin : g_r8
    localparam int G  = (W + 7) / 8;
    localparam int PW = G * 8;

    // Padding below the LSB is a single one, so a zero input counts exactly W.
    logic [PW-1:0] xp;
    if (PW > W) begin : g_pad
      assign xp = {x, 1'b1, {(PW - W - 1){1'b0}}};
    end else begin : g_nopad
      assign xp = x;
    end

    logic [G-1:0]       any;     // any[g]: group g (g = 0 holds the MSBs) has a one
    logic [G-1:0][2:0]  lz8;
    logic [G-1:0]       first;   // one-hot: the first non-zero group

    for (genvar g = 0; g < G; g++) begin : g_grp
      logic [7:0] grp;
      assign grp = xp[PW-1-8*g -: 8];
      assign any[g] = |grp;
      always_comb begin
        lz8[g] = 3'd7;
        for (int i = 0; i < 8; i++)
          if (grp[i]) lz8[g] = 3'(7 - i);
      end
      if (g == 0) begin : g_f0
        assign first[g] = any[g];
      end else begin : g_fn
        assign first[g] = any[g] && !(|any[g-1:0]);
      end
    end

    logic [CW+2:0] acc;
    always_comb begin
      acc = '0;
      for (int g = 0; g < G; g++)
        if (first[g]) acc = acc | ((CW+3)'(g) << 3 | (CW+3)'(lz8[g]));
      if (!(|any)) acc = (CW+3)'(W);
    end
    assign cnt = acc[CW-1:0];

    logic unused;
    assign unused = ^acc[CW+2:CW];
  end else begin : g_r4
    // 256 bits, the input then a single one (so a zero input counts exactly W) then zeros; the
    // constant nodes fold away. Child 0 of a node holds its most significant bits.
    logic [255:0]      xp;
    logic [63:0]       v0;               // nibbles
    logic [63:0][1:0]  c0;
    logic [15:0]       v1;               // 16 bits
    logic [15:0][3:0]  c1;
    logic [2:0]        v2;               // 64 bits (the root needs children 0-2's)
    logic [3:0][5:0]   c2;
    logic [7:0]        c3;
    assign xp = {x, 1'b1, {(255 - W){1'b0}}};

    // Which of a node's children holds its first one, from their "has a one" bits (child 0 first):
    // the first of children 0-2 that has one, else 3.
    function automatic logic [1:0] first4(input logic [2:0] v);
      return v[0] ? 2'd0 : v[1] ? 2'd1 : v[2] ? 2'd2 : 2'd3;
    endfunction

    always_comb begin
      for (int n = 0; n < 64; n++) begin
        logic [3:0] b;
        b     = xp[255-4*n -: 4];
        v0[n] = |b;
        c0[n] = first4({b[1], b[2], b[3]});
      end
      for (int n = 0; n < 16; n++) begin
        logic [1:0] j;
        j     = first4(v0[4*n +: 3]);
        v1[n] = |v0[4*n +: 4];
        c1[n] = {j, c0[4*n + int'(j)]};
      end
      for (int n = 0; n < 4; n++) begin
        logic [1:0] j;
        j     = first4(v1[4*n +: 3]);
        if (n < 3) v2[n] = |v1[4*n +: 4];
        c2[n] = {j, c1[4*n + int'(j)]};
      end
      begin
        logic [1:0] j;
        j  = first4(v2[2:0]);
        c3 = {j, c2[j]};
      end
    end
    assign cnt = c3[CW-1:0];

    if (CW < 8) begin : g_unused
      logic unused;
      assign unused = ^c3[7:CW];
    end
  end
endmodule
