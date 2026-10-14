// Goldschmidt seed ROM in one BRAM18 (2K x 9; docs/spec/fpu.md, "Seed ROM"). The address is
// registered in the block RAM and the output register is used, so data appears two cycles after
// the address. An inferred block ROM: rtl/common/prim has no ROM wrapper yet.
module tg_fpu_seed_rom (
  input  logic        clk,
  input  logic [10:0] addr,
  output logic [8:0]  data
);
  import tg_fpu_seed_pkg::*;
  (* rom_style = "block" *) logic [8:0] rd_q;
  logic [8:0] out_q;
  always_ff @(posedge clk) begin
    rd_q  <= SEED_ROM[addr];
    out_q <= rd_q;
  end
  assign data = out_q;
endmodule
