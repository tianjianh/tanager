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

  // First valid input at or after ptr_q, wrapping: two priority encoders (inputs at or above
  // ptr_q, and all inputs) instead of a rotation.
  always_comb begin
    logic [IW-1:0] p_hi, p_all;
    logic          any_hi;
    p_hi   = '0;
    p_all  = '0;
    any_hi = 1'b0;
    for (int i = N - 1; i >= 0; i--) begin
      if (in_valid[i]) p_all = IW'(i);
      if (in_valid[i] && i >= int'(ptr_q)) begin
        p_hi   = IW'(i);
        any_hi = 1'b1;
      end
    end
    pick = any_hi ? p_hi : p_all;
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
