// Evaluation tops for the shared primitives of docs/perf/fpga_friendly.md (T2, T4, T5, T6).
//
// Price tops (tg_pp_*): every configuration of one family side by side, for one synthesis
//   with the hierarchy kept (fpga/budget/tcl/unit_synth.tcl -flatten none, plus DR-113's
//   AreaOptimized_high), so each instance's LUTs, LUTRAM, flip-flops and DSPs are exact in
//   util_hier.rpt. Inputs are shared ports; each instance's outputs are XOR-folded into one
//   output bit, which keeps all of its logic. The flip-flop baselines (tg_pb_*) are the
//   same structures built the usual way, for comparison.
// Timing tops (tg_pt_*): one configuration between input and output registers, for an
//   out-of-context place and route at 200 MHz (fpga/spikes/tcl/ooc_run.tcl).

// ---- flip-flop baselines -----------------------------------------------------------------

// Multi-write array in flip-flops: the highest-numbered writer wins, asynchronous reads.
module tg_pb_mw_ff #(
  parameter int DEPTH = 64, WIDTH = 8, NW = 2, NR = 4,
  localparam int AW = $clog2(DEPTH)
) (
  input  logic clk,
  input  logic [NW-1:0] wen,
  input  logic [NW-1:0][AW-1:0] waddr,
  input  logic [NW-1:0][WIDTH-1:0] wdata,
  input  logic [NR-1:0][AW-1:0] raddr,
  output logic [NR-1:0][WIDTH-1:0] rdata
);
  (* ram_style = "registers" *) logic [WIDTH-1:0] mem [DEPTH];
  always_ff @(posedge clk) begin
    for (int w = 0; w < NW; w++) if (wen[w]) mem[waddr[w]] <= wdata[w];
  end
  for (genvar r = 0; r < NR; r++) begin : g_rd
    assign rdata[r] = mem[raddr[r]];
  end
endmodule

// CAM in flip-flops: keys and valid bits in registers, one comparator per entry,
// single-cycle writes.
module tg_pb_cam_ff #(
  parameter int ENTRIES = 32, KEYW = 32,
  localparam int IW = $clog2(ENTRIES)
) (
  input  logic clk, rst,
  input  logic [KEYW-1:0] lk_key,
  output logic [ENTRIES-1:0] lk_match,
  output logic lk_hit,
  output logic [IW-1:0] lk_idx,
  input  logic wr_valid,
  input  logic [IW-1:0] wr_idx,
  input  logic [KEYW-1:0] wr_key,
  input  logic inv,
  input  logic [IW-1:0] inv_idx,
  input  logic flush
);
  logic [KEYW-1:0]    key_q [ENTRIES];
  logic [ENTRIES-1:0] valid_q;
  always_ff @(posedge clk) begin
    if (wr_valid) key_q[wr_idx] <= wr_key;
    if (rst || flush) valid_q <= '0;
    else begin
      if (inv) valid_q[inv_idx] <= 1'b0;
      if (wr_valid) valid_q[wr_idx] <= 1'b1;
    end
  end
  always_comb begin
    for (int e = 0; e < ENTRIES; e++) lk_match[e] = valid_q[e] && key_q[e] == lk_key;
    lk_hit = |lk_match;
    lk_idx = '0;
    for (int e = 0; e < ENTRIES; e++) if (lk_match[e]) lk_idx |= IW'(e);
  end
endmodule

// Comparator in fabric (LUTs and carry chain), result registered: tg_dsp_cmp LAT = 1.
module tg_pb_cmp_fab #(
  parameter int W = 32
) (
  input  logic clk,
  input  logic [W-1:0] opa, opb,
  output logic is_eq, is_lt
);
  always_ff @(posedge clk) begin
    is_eq <= opa == opb;
    is_lt <= opa < opb;
  end
endmodule

// ---- price tops --------------------------------------------------------------------------

// T2: tg_ram_lut_mw, DEPTH {32, 64, 128} x WIDTH {8, 32} x NW {2, 4} x NR {4, 8} x
// {lvt with a LUTRAM table, lvt with a flip-flop table, xor}. Output bit
// ((((d * 2 + w) * 2 + n) * 2 + r) * 3 + i).
module tg_pp_mw (
  input  logic clk,
  input  logic [3:0] wen,
  input  logic [3:0][6:0] waddr,
  input  logic [3:0][31:0] wdata,
  input  logic [7:0][6:0] raddr,
  output logic [71:0] out
);
  localparam int DS [3] = '{32, 64, 128};
  localparam int WS [2] = '{8, 32};
  localparam int NWS [2] = '{2, 4};
  localparam int NRS [2] = '{4, 8};
  for (genvar d = 0; d < 3; d++) begin : g_d
    for (genvar w = 0; w < 2; w++) begin : g_w
      for (genvar n = 0; n < 2; n++) begin : g_n
        for (genvar r = 0; r < 2; r++) begin : g_r
          for (genvar i = 0; i < 3; i++) begin : g_i
            localparam int D = DS[d], W = WS[w], NW = NWS[n], NR = NRS[r];
            localparam int AW = $clog2(D);
            localparam string IM = (i == 2) ? "xor" : "lvt";
            localparam string LV = (i == 1) ? "reg" : "lutram";
            logic [NW-1:0][AW-1:0] wa;
            logic [NW-1:0][W-1:0]  wd;
            logic [NR-1:0][AW-1:0] ra;
            logic [NR-1:0][W-1:0]  rd;
            for (genvar k = 0; k < NW; k++) begin : g_wp
              assign wa[k] = waddr[k][AW-1:0];
              assign wd[k] = wdata[k][W-1:0];
            end
            for (genvar k = 0; k < NR; k++) begin : g_rp
              assign ra[k] = raddr[k][AW-1:0];
            end
            tg_ram_lut_mw #(.DEPTH(D), .WIDTH(W), .NW(NW), .NR(NR), .IMPL(IM), .LVT(LV)) u (
              .clk, .wen(wen[NW-1:0]), .waddr(wa), .wdata(wd), .raddr(ra), .rdata(rd));
            assign out[(((d * 2 + w) * 2 + n) * 2 + r) * 3 + i] = ^rd;
          end
        end
      end
    end
  end
endmodule

// T2 baseline: tg_pb_mw_ff at WIDTH 8 for every DEPTH, NW and NR above, and one WIDTH 32
// shape (64 deep, 4 writers, 8 readers). Output bit ((d * 2 + n) * 2 + r), then 12.
module tg_pp_mwff (
  input  logic clk,
  input  logic [3:0] wen,
  input  logic [3:0][6:0] waddr,
  input  logic [3:0][31:0] wdata,
  input  logic [7:0][6:0] raddr,
  output logic [12:0] out
);
  localparam int DS [3] = '{32, 64, 128};
  localparam int NWS [2] = '{2, 4};
  localparam int NRS [2] = '{4, 8};
  for (genvar d = 0; d < 3; d++) begin : g_d
    for (genvar n = 0; n < 2; n++) begin : g_n
      for (genvar r = 0; r < 2; r++) begin : g_r
        localparam int D = DS[d], NW = NWS[n], NR = NRS[r];
        localparam int AW = $clog2(D);
        logic [NW-1:0][AW-1:0] wa;
        logic [NW-1:0][7:0]    wd;
        logic [NR-1:0][AW-1:0] ra;
        logic [NR-1:0][7:0]    rd;
        for (genvar k = 0; k < NW; k++) begin : g_wp
          assign wa[k] = waddr[k][AW-1:0];
          assign wd[k] = wdata[k][7:0];
        end
        for (genvar k = 0; k < NR; k++) begin : g_rp
          assign ra[k] = raddr[k][AW-1:0];
        end
        tg_pb_mw_ff #(.DEPTH(D), .WIDTH(8), .NW(NW), .NR(NR)) u (
          .clk, .wen(wen[NW-1:0]), .waddr(wa), .wdata(wd), .raddr(ra), .rdata(rd));
        assign out[(d * 2 + n) * 2 + r] = ^rd;
      end
    end
  end
  if (1) begin : g_w32
    logic [3:0][5:0]  wa;
    logic [7:0][5:0]  ra;
    logic [7:0][31:0] rd;
    for (genvar k = 0; k < 4; k++) begin : g_wp
      assign wa[k] = waddr[k][5:0];
    end
    for (genvar k = 0; k < 8; k++) begin : g_rp
      assign ra[k] = raddr[k][5:0];
    end
    tg_pb_mw_ff #(.DEPTH(64), .WIDTH(32), .NW(4), .NR(8)) u (
      .clk, .wen, .waddr(wa), .wdata, .raddr(ra), .rdata(rd));
    assign out[12] = ^rd;
  end
endmodule

// T5: tg_cam_lut (SLICE 5) with and without the second read port, and the flip-flop CAM,
// ENTRIES {16, 32, 64} x KEYW {20, 30, 40}. Output bit ((e * 3 + k) * 3 + i), i: 0 LUTRAM
// with RMW_PORT, 1 LUTRAM without, 2 flip-flops.
module tg_pp_cam (
  input  logic clk, rst,
  input  logic [39:0] lk_key, wr_key,
  input  logic wr_valid, inv, flush,
  input  logic [5:0] wr_idx, inv_idx,
  output logic [26:0] out
);
  localparam int ES [3] = '{16, 32, 64};
  localparam int KS [3] = '{20, 30, 40};
  for (genvar e = 0; e < 3; e++) begin : g_e
    for (genvar k = 0; k < 3; k++) begin : g_k
      for (genvar i = 0; i < 3; i++) begin : g_i
        localparam int E = ES[e], K = KS[k], IW = $clog2(E);
        logic [E-1:0]  m;
        logic [IW-1:0] x;
        logic          h, v, wr, rd;
        if (i < 2) begin : g_lut
          tg_cam_lut #(.ENTRIES(E), .KEYW(K), .SLICE(5), .RMW_PORT(i == 0)) u (
            .clk, .rst, .ready(rd), .lk_key(lk_key[K-1:0]), .lk_match(m), .lk_hit(h),
            .lk_idx(x), .lk_valid(v), .wr_valid, .wr_ready(wr), .wr_idx(wr_idx[IW-1:0]),
            .wr_key(wr_key[K-1:0]), .inv, .inv_idx(inv_idx[IW-1:0]), .flush);
        end else begin : g_ff
          tg_pb_cam_ff #(.ENTRIES(E), .KEYW(K)) u (
            .clk, .rst, .lk_key(lk_key[K-1:0]), .lk_match(m), .lk_hit(h), .lk_idx(x),
            .wr_valid, .wr_idx(wr_idx[IW-1:0]), .wr_key(wr_key[K-1:0]), .inv,
            .inv_idx(inv_idx[IW-1:0]), .flush);
          assign v = 1'b1; assign wr = 1'b1; assign rd = 1'b1;
        end
        assign out[(e * 3 + k) * 3 + i] = ^{m, x, h, v, wr, rd};
      end
    end
  end
endmodule

// T4: tg_fifo, DEPTH {4, 8, 16, 32} x WIDTH {8, 32, 64} x STORAGE {srl, lutram, reg}.
// Output bit ((d * 3 + w) * 3 + s).
module tg_pp_fifo (
  input  logic clk, rst, in_valid, out_ready,
  input  logic [63:0] in_data,
  output logic [35:0] out
);
  localparam int DS [4] = '{4, 8, 16, 32};
  localparam int WS [3] = '{8, 32, 64};
  for (genvar d = 0; d < 4; d++) begin : g_d
    for (genvar w = 0; w < 3; w++) begin : g_w
      for (genvar s = 0; s < 3; s++) begin : g_s
        localparam int D = DS[d], W = WS[w];
        localparam string ST = (s == 0) ? "srl" : (s == 1) ? "lutram" : "reg";
        logic [W-1:0] od;
        logic ir, ov;
        logic [$clog2(D):0] c;
        tg_fifo #(.T(logic [W-1:0]), .DEPTH(D), .STORAGE(ST)) u (
          .clk, .rst, .in_valid, .in_ready(ir), .in_data(in_data[W-1:0]), .out_valid(ov),
          .out_ready, .out_data(od), .count(c));
        assign out[(d * 3 + w) * 3 + s] = ^{od, ir, ov, c};
      end
    end
  end
endmodule

// T6: tg_dsp_cmp (LAT 1 and 2) and the fabric comparator, unsigned, W {16, 32, 48}.
// Output bits 2 * ((w * 3 + i)) and the next: {is_lt, is_eq}.
module tg_pp_cmp (
  input  logic clk, ce,
  input  logic [47:0] opa, opb,
  output logic [17:0] out
);
  localparam int WS [3] = '{16, 32, 48};
  for (genvar w = 0; w < 3; w++) begin : g_w
    for (genvar i = 0; i < 3; i++) begin : g_i
      localparam int W = WS[w];
      logic e, l;
      if (i < 2) begin : g_dsp
        tg_dsp_cmp #(.W(W), .SIGNED(1'b0), .LAT(i + 1)) u (
          .clk, .ce, .opa(opa[W-1:0]), .opb(opb[W-1:0]), .is_eq(e), .is_lt(l));
      end else begin : g_fab
        tg_pb_cmp_fab #(.W(W)) u (.clk, .opa(opa[W-1:0]), .opb(opb[W-1:0]), .is_eq(e), .is_lt(l));
      end
      assign out[2 * (w * 3 + i) +: 2] = {l, e};
    end
  end
endmodule

// ---- timing tops (registered inputs and outputs) ------------------------------------------

// SEL (an integer, so it can be set from the synth_design command line): 0 lvt with a
// LUTRAM table, 1 lvt with a flip-flop table, 2 xor, 3 the flip-flop baseline.
module tg_pt_mw #(
  parameter int DEPTH = 128, WIDTH = 32, NW = 4, NR = 8, SEL = 0,
  localparam int AW = $clog2(DEPTH),
  localparam string IMPL = (SEL == 2) ? "xor" : "lvt",
  localparam string LVT = (SEL == 1) ? "reg" : "lutram"
) (
  input  logic clk,
  input  logic [NW-1:0] wen_i,
  input  logic [NW-1:0][AW-1:0] waddr_i,
  input  logic [NW-1:0][WIDTH-1:0] wdata_i,
  input  logic [NR-1:0][AW-1:0] raddr_i,
  output logic [NR-1:0][WIDTH-1:0] rdata_o
);
  logic [NW-1:0] wen;
  logic [NW-1:0][AW-1:0] waddr;
  logic [NW-1:0][WIDTH-1:0] wdata;
  logic [NR-1:0][AW-1:0] raddr;
  logic [NR-1:0][WIDTH-1:0] rdata;
  always_ff @(posedge clk) begin
    wen <= wen_i; waddr <= waddr_i; wdata <= wdata_i; raddr <= raddr_i; rdata_o <= rdata;
  end
  if (SEL == 3) begin : g_ff
    tg_pb_mw_ff #(.DEPTH(DEPTH), .WIDTH(WIDTH), .NW(NW), .NR(NR)) u (.*);
  end else begin : g_lut
    tg_ram_lut_mw #(.DEPTH(DEPTH), .WIDTH(WIDTH), .NW(NW), .NR(NR), .IMPL(IMPL), .LVT(LVT)) u (.*);
  end
endmodule

module tg_pt_cam #(
  parameter int ENTRIES = 64, KEYW = 40, SLICE = 5,
  parameter bit RMW_PORT = 1'b1,
  parameter bit FF = 1'b0,
  localparam int IW = $clog2(ENTRIES)
) (
  input  logic clk, rst_i,
  input  logic [KEYW-1:0] lk_key_i, wr_key_i,
  input  logic wr_valid_i, inv_i, flush_i,
  input  logic [IW-1:0] wr_idx_i, inv_idx_i,
  output logic [ENTRIES-1:0] lk_match_o,
  output logic lk_hit_o, lk_valid_o, wr_ready_o, ready_o,
  output logic [IW-1:0] lk_idx_o
);
  logic rst, wr_valid, inv, flush, lk_hit, lk_valid, wr_ready, ready;
  logic [KEYW-1:0] lk_key, wr_key;
  logic [IW-1:0] wr_idx, inv_idx, lk_idx;
  logic [ENTRIES-1:0] lk_match;
  always_ff @(posedge clk) begin
    rst <= rst_i; lk_key <= lk_key_i; wr_key <= wr_key_i; wr_valid <= wr_valid_i;
    inv <= inv_i; flush <= flush_i; wr_idx <= wr_idx_i; inv_idx <= inv_idx_i;
    lk_match_o <= lk_match; lk_hit_o <= lk_hit; lk_valid_o <= lk_valid;
    wr_ready_o <= wr_ready; ready_o <= ready; lk_idx_o <= lk_idx;
  end
  if (FF) begin : g_ff
    tg_pb_cam_ff #(.ENTRIES(ENTRIES), .KEYW(KEYW)) u (
      .clk, .rst, .lk_key, .lk_match, .lk_hit, .lk_idx, .wr_valid, .wr_idx, .wr_key, .inv,
      .inv_idx, .flush);
    assign lk_valid = 1'b1; assign wr_ready = 1'b1; assign ready = 1'b1;
  end else begin : g_lut
    tg_cam_lut #(.ENTRIES(ENTRIES), .KEYW(KEYW), .SLICE(SLICE), .RMW_PORT(RMW_PORT)) u (.*);
  end
endmodule

// SEL: 0 srl, 1 lutram, 2 reg.
module tg_pt_fifo #(
  parameter int DEPTH = 32, WIDTH = 64, SEL = 0,
  localparam int AW = $clog2(DEPTH),
  localparam string STORAGE = (SEL == 0) ? "srl" : (SEL == 1) ? "lutram" : "reg"
) (
  input  logic clk, rst_i, in_valid_i, out_ready_i,
  input  logic [WIDTH-1:0] in_data_i,
  output logic in_ready_o, out_valid_o,
  output logic [WIDTH-1:0] out_data_o,
  output logic [AW:0] count_o
);
  logic rst, in_valid, out_ready, in_ready, out_valid;
  logic [WIDTH-1:0] in_data, out_data;
  logic [AW:0] count;
  always_ff @(posedge clk) begin
    rst <= rst_i; in_valid <= in_valid_i; out_ready <= out_ready_i; in_data <= in_data_i;
    in_ready_o <= in_ready; out_valid_o <= out_valid; out_data_o <= out_data; count_o <= count;
  end
  tg_fifo #(.T(logic [WIDTH-1:0]), .DEPTH(DEPTH), .STORAGE(STORAGE)) u (.*);
endmodule

// The comparator's operands come from fabric registers (LAT 1, and the fabric baseline) or
// straight from the ports into the DSP's own registers (LAT 2); the result goes to a fabric
// register either way.
module tg_pt_cmp #(
  parameter int W = 48,
  parameter int LAT = 1,
  parameter bit FAB = 1'b0
) (
  input  logic clk, ce_i,
  input  logic [W-1:0] opa_i, opb_i,
  output logic is_eq_o, is_lt_o
);
  logic [W-1:0] opa, opb;
  logic ce, is_eq, is_lt;
  if (LAT == 2 && !FAB) begin : g_direct
    assign opa = opa_i; assign opb = opb_i; assign ce = ce_i;
  end else begin : g_reg
    always_ff @(posedge clk) begin opa <= opa_i; opb <= opb_i; ce <= ce_i; end
  end
  always_ff @(posedge clk) begin is_eq_o <= is_eq; is_lt_o <= is_lt; end
  if (FAB) begin : g_fab
    tg_pb_cmp_fab #(.W(W)) u (.clk, .opa, .opb, .is_eq, .is_lt);
    wire unused = ce;
  end else begin : g_dsp
    tg_dsp_cmp #(.W(W), .SIGNED(1'b0), .LAT(LAT)) u (.clk, .ce, .opa, .opb, .is_eq, .is_lt);
  end
endmodule
