// Leading-zero count of a W-bit vector (W when the vector is zero), as a two-level tree: an
// 8-bit count per group and a one-hot select of the first non-zero group (docs/spec/fpu.md).
module tg_fpu_lzc #(
  parameter int  W  = 64,
  localparam int CW = $clog2(W + 1)
) (
  input  logic [W-1:0]  x,
  output logic [CW-1:0] cnt
);
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
endmodule
