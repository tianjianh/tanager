// IF2 pre-decode of one fetch block (plan §3.2, §4.2): instruction boundaries and branch
// marks for the FETCH_BYTES / 2 halfword parcels of the block. Spike S5; combinational.
//
// Boundaries. Parcels before entry_slot (the fetch PC's offset) and after exit_slot (the
// predicted-taken branch's last parcel) are not part of the block. At entry_slot an
// instruction starts, unless carry_in says parcel 0 completes a 32-bit instruction begun
// in the previous block (sequential fetch). After it, parcel p starts an instruction
// unless parcel p-1 started a 32-bit one (low bits 11). The chain collapses to functions
// of at most NP + 4 inputs per parcel. carry_out: the block's last parcel starts a 32-bit
// instruction whose second half is in the next block.
// Marks, per starting parcel: conditional branch, direct jump, indirect jump, call (link
// register x1/x5), return (jalr to x1/x5 without link), for both encodings; and the return-address
// stack's pop (is_pop: a JALR reading a link, unless it writes the same one, as tg_core_pkg::ras_op;
// a return, or a coroutine swap, which is_call also marks).
module tg_predecode
  import tg_pkg::*;
#(
  localparam int NP = FETCH_BYTES / 2,
  localparam int SW = idx_w(NP)
) (
  input  logic [NP-1:0][15:0] parcel,
  input  logic [SW-1:0]       entry_slot,
  input  logic [SW-1:0]       exit_slot,
  input  logic                carry_in,
  output logic [NP-1:0]       start,
  output logic [NP-1:0]       is32,
  output logic [NP-1:0]       is_br,
  output logic [NP-1:0]       is_jal,
  output logic [NP-1:0]       is_jalr,
  output logic [NP-1:0]       is_call,
  output logic [NP-1:0]       is_ret,
  output logic [NP-1:0]       is_pop,
  output logic                carry_out
);
  logic [NP-1:0] wide, inr;
  for (genvar p = 0; p < NP; p++) begin : g_w
    assign wide[p] = parcel[p][1:0] == 2'b11;
    /* verilator lint_off CMPCONST */  // generic over p: the end parcels compare constant
    /* verilator lint_off UNSIGNED */
    assign inr[p]  = SW'(p) >= entry_slot && SW'(p) <= exit_slot;
    /* verilator lint_on UNSIGNED */
    /* verilator lint_on CMPCONST */
  end

  always_comb begin
    logic s;
    s = 1'b0;
    for (int p = 0; p < NP; p++) begin
      if (SW'(p) == entry_slot) s = !(carry_in && entry_slot == '0);
      else if (p > 0)           s = !(s && wide[p-1]);
      start[p] = s && inr[p];
    end
  end
  assign is32 = start & wide;
  assign carry_out = start[NP-1] && wide[NP-1] && exit_slot == SW'(NP - 1);

  // Marks. 32-bit: opcode = parcel[6:0], rd = [11:7], rs1 = [19:15] (rs1 spans parcels).
  // RVC (RV64C): c.j (101, q1), c.beqz/c.bnez (110/111, q1), c.jr/c.jalr (100, q2, rs2 = 0).
  for (genvar p = 0; p < NP; p++) begin : g_mark
    logic [15:0] lo, hi;
    logic [4:0]  rd, rs1;
    logic        link_rd, link_rs1;
    logic        c_jr, c_jalr;
    assign lo  = parcel[p];
    assign hi  = (p + 1 < NP) ? parcel[(p + 1) % NP] : 16'h0;
    assign rd  = lo[11:7];
    assign rs1 = {hi[3:0], lo[15]};
    logic unused;
    assign unused = ^hi[15:4];
    assign link_rd  = rd == 5'd1 || rd == 5'd5;
    assign link_rs1 = rs1 == 5'd1 || rs1 == 5'd5;
    assign c_jr   = lo[1:0] == 2'b10 && lo[15:13] == 3'b100 && !lo[12] && lo[11:7] != 0 && lo[6:2] == 0;
    assign c_jalr = lo[1:0] == 2'b10 && lo[15:13] == 3'b100 &&  lo[12] && lo[11:7] != 0 && lo[6:2] == 0;
    always_comb begin
      if (wide[p]) begin
        is_br[p]   = lo[6:0] == 7'b1100011;
        is_jal[p]  = lo[6:0] == 7'b1101111;
        is_jalr[p] = lo[6:0] == 7'b1100111;
        is_call[p] = (is_jal[p] || is_jalr[p]) && link_rd;
        is_ret[p]  = is_jalr[p] && !link_rd && link_rs1;
        is_pop[p]  = is_jalr[p] && link_rs1 && !(link_rd && rd == rs1);
      end else begin
        is_br[p]   = lo[1:0] == 2'b01 && lo[15:14] == 2'b11;
        is_jal[p]  = lo[1:0] == 2'b01 && lo[15:13] == 3'b101;
        is_jalr[p] = c_jr || c_jalr;
        is_call[p] = c_jalr;
        is_ret[p]  = c_jr && (lo[11:7] == 5'd1 || lo[11:7] == 5'd5);
        is_pop[p]  = (c_jr || c_jalr) && (lo[11:7] == 5'd1 || lo[11:7] == 5'd5) && !(c_jalr && lo[11:7] == 5'd1);
      end
      is_br[p]   = is_br[p]   && start[p];
      is_jal[p]  = is_jal[p]  && start[p];
      is_jalr[p] = is_jalr[p] && start[p];
      is_call[p] = is_call[p] && start[p];
      is_ret[p]  = is_ret[p]  && start[p];
      is_pop[p]  = is_pop[p]  && start[p];
    end
  end
endmodule
