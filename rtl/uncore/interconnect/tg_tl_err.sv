// Error responder of the interconnect (docs/spec/uncore.md): answers requests that no target
// accepts. Get -> AccessAckData denied+corrupt (all beats); Put -> AccessAck denied after its last
// beat; Acquire -> Grant denied with sink SINK_ERR (the GrantAck is swallowed by the interconnect).
module tg_tl_err
  import tg_pkg::*, tg_tl_pkg::*, tg_uncore_pkg::*;
(
  input  logic  clk,
  input  logic  rst,
  input  tl_a_t a_i,
  input  logic  a_valid_i,
  output logic  a_ready_o,
  output tl_d_t d_o,
  output logic  d_valid_o,
  input  logic  d_ready_i
);
  logic                 busy_q;
  logic [1:0]           put_beat_q, left_q;
  tl_d_op_e             op_q;
  logic [TL_SIZE_W-1:0] size_q;
  logic [TL_SRC_W-1:0]  src_q;

  wire [1:0] lastb  = tl_a_last(a_i.opcode, a_i.size);
  wire       a_last = put_beat_q == lastb;
  wire       acq    = a_i.opcode == A_ACQUIRE_BLOCK || a_i.opcode == A_ACQUIRE_PERM;

  assign a_ready_o = !busy_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      busy_q     <= 1'b0;
      put_beat_q <= '0;
    end else if (!busy_q) begin
      if (a_valid_i) begin
        if (!a_last) put_beat_q <= put_beat_q + 1'b1;
        else begin
          busy_q     <= 1'b1;
          put_beat_q <= '0;
        end
      end
    end else if (d_ready_i && left_q == 2'd0) begin
      busy_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (!busy_q && a_valid_i && a_last) begin
      op_q   <= acq ? D_GRANT : (a_i.opcode == A_GET) ? D_ACCESS_ACK_DATA : D_ACCESS_ACK;
      left_q <= (a_i.opcode == A_GET) ? tl_last_beat(a_i.size) : 2'd0;
      size_q <= a_i.size;
      src_q  <= a_i.source;
    end else if (busy_q && d_ready_i && left_q != 2'd0) begin
      left_q <= left_q - 1'b1;
    end
  end

  always_comb begin
    d_o         = '0;
    d_o.opcode  = op_q;
    d_o.param   = (op_q == D_GRANT) ? TL_CAP_TO_N[1:0] : 2'd0;
    d_o.size    = size_q;
    d_o.source  = src_q;
    d_o.sink    = (op_q == D_GRANT) ? SINK_ERR : '0;
    d_o.denied  = 1'b1;
    d_o.corrupt = op_q == D_ACCESS_ACK_DATA;
  end
  assign d_valid_o = busy_q;

  wire unused = ^{a_i.param, a_i.address, a_i.mask, a_i.data, a_i.corrupt};
endmodule
