#!/usr/bin/env python3
"""Measurement-only patch for spike G5 (DR-145): adds hart 1's area to kv260_top as synthetic
filler, in a snapshot's copy of fpga/kv260/rtl/kv260_top.sv (never in the repo's RTL).

Until M7 builds hart 1's state, the smt2 cores run hart 0 only; the area plan puts hart 1 at
about 3.7K LUTs per core in RAM form (area_recovery.md 7.7). G5 times the full chip at that
fill. The patch adds two tg_s6_fill blocks (fpga/spikes/rtl/tg_s6_fill.sv: tiles of LUT6
logic and LUTRAM blocks), one per core, clocked by clk_core and fed from a free-running LFSR.
Their outputs fold into one register XORed onto pmod_uart_txd, so nothing is trimmed. With
FILL_TILES = 0 (the default) the patched top builds as before.
  g5_fill_patch.py <snapshot>/fpga/kv260/rtl/kv260_top.sv
"""
import sys

p = sys.argv[1]
s = open(p).read()
params_old = "  parameter logic [63:0] UNCORE_DSP = {20'd0, 2'b00, 5'b00100, 5'b00100, 32'h0308_0000}  // slices in DSPs (tg_uncore; build.tcl TG_UNCORE_DSP)\n) ("
params_new = ("  parameter logic [63:0] UNCORE_DSP = {20'd0, 2'b00, 5'b00100, 5'b00100, 32'h0308_0000},  // slices in DSPs (tg_uncore; build.tcl TG_UNCORE_DSP)\n"
              "  parameter int    FILL_TILES = 0,     // measurement only (spike G5): filler tiles per core\n"
              "  parameter int    FILL_NRAM  = 0      // measurement only (spike G5): filler LUTRAM blocks per core\n"
              ") (")
assert params_old in s, "kv260_top's parameter list changed"
s = s.replace(params_old, params_new, 1)
txd_old = "  assign pmod_uart_txd = PMOD_UART ? uart_txd : 1'bz;\nendmodule"
txd_new = """  // ---- measurement only (spike G5, DR-145): hart 1's area as synthetic filler ----
  logic fill_bit;
  if (FILL_TILES > 0) begin : g_fill
    logic [63:0] lfsr_q;
    logic [1:0][63:0] fo;
    always_ff @(posedge clk_core)
      if (rst_core) lfsr_q <= 64'h1;
      else          lfsr_q <= {lfsr_q[62:0], lfsr_q[63] ^ lfsr_q[62] ^ lfsr_q[60] ^ lfsr_q[59]};
    for (genvar i = 0; i < 2; i++) begin : g_f
      tg_s6_fill #(.TILES (FILL_TILES), .NRAM (FILL_NRAM), .SEED (i + 7)) u_fill (
        .clk (clk_core), .in (lfsr_q ^ 64'(i)), .out (fo[i]));
    end
    logic fill_q;
    always_ff @(posedge clk_core) fill_q <= ^fo;
    assign fill_bit = fill_q;
  end else begin : g_nofill
    assign fill_bit = 1'b0;
  end
  assign pmod_uart_txd = PMOD_UART ? (uart_txd ^ fill_bit) : 1'bz;
endmodule"""
assert txd_old in s, "kv260_top's console output changed"
s = s.replace(txd_old, txd_new, 1)
open(p, "w").write(s)
print("patched", p)
