// Round-robin arbiter for a valid/ready channel, locked onto one input from the first beat of a
// multi-beat message to its last (in_last marks each input's last beat), so beats stay contiguous
// (docs/spec/uncore.md). The grant depends only on in_valid and registered state, never on
// out_ready. N = 1 degenerates to a wire.
module tg_arb
  import tg_pkg::*;
#(
  parameter int  N = 2,
  parameter type T = logic [7:0],
  localparam int IW = idx_w(N)
) (
  input  logic          clk,
  input  logic          rst,
  input  logic [N-1:0]  in_valid,
  input  logic [N-1:0]  in_last,
  input  T     [N-1:0]  in_data,
  output logic [N-1:0]  in_ready,
  output logic          out_valid,
  output T              out_data,
  output logic [IW-1:0] out_idx,
  input  logic          out_ready
);
  logic [IW-1:0] ptr_q, lock_idx_q, pick;
  logic          lock_q;

  // First valid input at or after ptr_q, wrapping.
  always_comb begin
    pick = ptr_q;
    for (int k = N - 1; k >= 0; k--) begin
      logic [IW-1:0] i;
      i = IW'((int'(ptr_q) + k) % N);
      if (in_valid[i]) pick = i;
    end
  end

  assign out_idx   = lock_q ? lock_idx_q : pick;
  assign out_valid = in_valid[out_idx];
  assign out_data  = in_data[out_idx];

  always_comb begin
    in_ready = '0;
    in_ready[out_idx] = out_ready;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ptr_q      <= '0;
      lock_q     <= 1'b0;
      lock_idx_q <= '0;
    end else if (out_valid && out_ready) begin
      if (in_last[out_idx]) begin
        lock_q <= 1'b0;
        ptr_q  <= (int'(out_idx) == N - 1) ? '0 : out_idx + 1'b1;
      end else begin
        lock_q     <= 1'b1;
        lock_idx_q <= out_idx;
      end
    end
  end
endmodule
