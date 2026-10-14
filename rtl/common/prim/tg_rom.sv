// Read-only memory: one synchronous read port, contents from a parameter. Like every memory,
// it goes through rtl/common/prim so tools/tcl/tg_prim_check.tcl can count it (plan §8.3).
//   PRIM    "block": block RAM (RAMB18E2/RAMB36E2); "distributed": LUTs.
//   RD_LAT  1: data the cycle after the address; 2 adds an output register (for "block", the
//           RAM's own), which a deep ROM needs at 200 MHz.
//   INIT    the contents, entry 0 first, e.g. a package's localparam array.
// Synthesis infers the ROM with rom_style; simulation reads the same array. An address at or
// above DEPTH reads X in simulation (keep DEPTH a power of two, or the address below it).
(* keep_hierarchy = "yes" *)  // keeps the instance and its ports for the primitive check
module tg_rom #(
  parameter int   DEPTH  = 512,
  parameter int   WIDTH  = 8,
  parameter string PRIM  = "block",   // "block" or "distributed"
  parameter int   RD_LAT = 1,         // 1 or 2
  parameter logic [WIDTH-1:0] INIT [DEPTH] = '{default: '0},
  localparam int  AW     = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
  input  logic             clk,
  input  logic             re,      // read enable; the output holds while it is low
  input  logic [AW-1:0]    raddr,
  output logic [WIDTH-1:0] rdata
);
  logic [WIDTH-1:0] rd;
  if (PRIM == "distributed") begin : g_dist
    (* rom_style = "distributed" *) logic [WIDTH-1:0] rd_q;
    always_ff @(posedge clk) begin
      if (re) rd_q <= INIT[raddr];
    end
    assign rd = rd_q;
  end else begin : g_block
    (* rom_style = "block" *) logic [WIDTH-1:0] rd_q;
    always_ff @(posedge clk) begin
      if (re) rd_q <= INIT[raddr];
    end
    assign rd = rd_q;
  end

  if (RD_LAT == 2) begin : g_oreg
    logic [WIDTH-1:0] out_q;
    always_ff @(posedge clk) out_q <= rd;
    assign rdata = out_q;
  end else begin : g_noreg
    assign rdata = rd;
  end

  if (RD_LAT < 1 || RD_LAT > 2) begin : g_bad_lat
    $error("tg_rom: RD_LAT must be 1 or 2");
  end
  if (PRIM != "block" && PRIM != "distributed") begin : g_bad_prim
    $error("tg_rom: PRIM must be \"block\" or \"distributed\"");
  end
endmodule
