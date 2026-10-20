// Synthesis check of tg_ram_tdp's CASCADE_HEIGHT (spikes §7.1): two 2K x 36 true dual-port memories, TAGE's
// table shape. u_c0 keeps the default (0: synthesis chooses, and stacks two RAMB36 at 1K x 36 in a depth
// cascade); u_c1 sets 1 (no depth cascade: two RAMB36 at 2K x 18 side by side). Each port's read data goes
// straight into a register, so the RAM -> register paths show each form's read delay.
// Run tests/unit/prim/synth/casc.sh; the expected report is in its header.
module tg_prim_casc_top (
  input  logic         clk,
  input  logic [195:0] in,
  output logic [35:0]  out_a0,
  output logic [35:0]  out_b0,
  output logic [35:0]  out_a1,
  output logic [35:0]  out_b1
);
  logic [195:0] in_q;
  always_ff @(posedge clk) in_q <= in;

  // each instance's ports from its own 98 input bits: enable, write enable, 11 address bits, 36 data bits
  logic [1:0][35:0] rd_a, rd_b;
  for (genvar i = 0; i < 2; i++) begin : g_c
    logic [97:0] v;
    assign v = in_q[98*i +: 98];
    tg_ram_tdp #(.DEPTH(2048), .WIDTH(36), .CASCADE_HEIGHT(i)) u_c (
      .clk, .en_a(v[0]), .we_a(v[1]), .addr_a(v[12:2]), .wdata_a(v[48:13]), .rdata_a(rd_a[i]),
      .en_b(v[49]), .we_b(v[50]), .addr_b(v[61:51]), .wdata_b(v[97:62]), .rdata_b(rd_b[i]));
  end

  always_ff @(posedge clk) begin
    out_a0 <= rd_a[0];
    out_b0 <= rd_b[0];
    out_a1 <= rd_a[1];
    out_b1 <= rd_b[1];
  end
endmodule
