// Synthesis test of tools/tcl/tg_prim_check.tcl: one instance of each memory wrapper, some
// with read fields nobody reads (Vivado trims them), and one memory outside the wrappers.
// Run tests/unit/prim/synth/run.sh; the expected report is in its header.
module tg_prim_synth_top (
  input  logic        clk,
  input  logic [63:0] in,
  output logic [63:0] out
);
  // a: LUTRAM 32 x 10, 2 read ports; port 1 reads only bits [3:0]. RAM32M16 slots (2 bits):
  // port 0 slots 0-4, port 1 slots 5-9; slots 7-9 (port 1 bits 4-9) are unread, which is all
  // of the second primitive: 1 RAM32M16 instead of 2.
  logic [1:0][4:0] a_ra;
  /* verilator lint_off UNUSEDSIGNAL */  // the test leaves fields unread
  logic [1:0][9:0] a_rd;
  /* verilator lint_on UNUSEDSIGNAL */
  assign a_ra[0] = in[4:0];
  assign a_ra[1] = in[9:5];
  tg_ram_lut #(.DEPTH(32), .WIDTH(10), .NR(2)) u_a (
    .clk, .we(in[10]), .waddr(in[15:11]), .wdata(in[25:16]), .raddr(a_ra), .rdata(a_rd));

  // b: LUTRAM 64 x 12, 3 read ports; port 2 is not read. RAM64M8 slots (1 bit): ports 0-1 are
  // slots 0-23, port 2 slots 24-35; primitives 0-3 hold a read slot, 4 and 5 only port 2's:
  // 4 RAM64M8 instead of 6.
  logic [2:0][5:0]  b_ra;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [2:0][11:0] b_rd;
  /* verilator lint_on UNUSEDSIGNAL */
  assign b_ra[0] = in[31:26];
  assign b_ra[1] = in[37:32];
  assign b_ra[2] = in[43:38];
  tg_ram_lut #(.DEPTH(64), .WIDTH(12), .NR(3)) u_b (
    .clk, .we(in[44]), .waddr(in[50:45]), .wdata(in[62:51]), .raddr(b_ra), .rdata(b_rd));

  // c: block RAM 1K x 200 with 8-bit byte writes: no parity bits, 6.5 RAMB36 equivalents
  logic [199:0] c_rd;
  tg_ram_sdp #(.DEPTH(1024), .WIDTH(200), .BYTE_W(8)) u_c (
    .clk, .we({25{in[63]}} & in[24:0]), .waddr(in[9:0]), .wdata({4{in[49:0]}}), .re(1'b1),
    .raddr(in[19:10]), .rdata(c_rd));

  // d: block ROM 2K x 9 with the output register (the FPU's seed table shape): one RAMB18
  typedef logic [8:0] d_t [2048];
  function automatic d_t d_init();
    d_t r;
    for (int i = 0; i < 2048; i++) r[i] = 9'((i * 37) ^ (i >> 3));
    return r;
  endfunction
  logic [8:0] d_rd;
  tg_rom #(.DEPTH(2048), .WIDTH(9), .RD_LAT(2), .INIT(d_init())) u_d (
    .clk, .re(1'b1), .raddr(in[10:0]), .rdata(d_rd));

  // e: distributed ROM 64 x 16: logic, no RAM primitive
  typedef logic [15:0] e_t [64];
  function automatic e_t e_init();
    e_t r;
    for (int i = 0; i < 64; i++) r[i] = 16'((i * 977) ^ (i << 7));
    return r;
  endfunction
  logic [15:0] e_rd;
  tg_rom #(.DEPTH(64), .WIDTH(16), .PRIM("distributed"), .INIT(e_init())) u_e (
    .clk, .re(in[0]), .raddr(in[21:16]), .rdata(e_rd));

  // f: a memory outside the wrappers (an inferred LUTRAM): reported as stray
  logic [15:0] f_mem [16];
  always_ff @(posedge clk) if (in[1]) f_mem[in[5:2]] <= in[21:6];
  logic [15:0] f_rd;
  assign f_rd = f_mem[in[25:22]];

  // every bit read, except the fields the test leaves unread (port 1 of a above bit 3, b's
  // port 2)
  logic [25:0] c_fold;
  always_comb begin
    c_fold = '0;
    for (int i = 0; i < 200; i++) c_fold[i % 26] ^= c_rd[i];
  end
  always_ff @(posedge clk) begin
    out <= {a_rd[0], a_rd[1][3:0], b_rd[0], b_rd[1], c_fold} ^ {d_rd, e_rd, f_rd, 23'd0};
  end
endmodule
