// Boot ROM, 4 KiB at BOOTROM_BASE (docs/spec/uncore-periph.md). TL-UL target: Get of any size
// <= 6 returns AccessAckData (line refills from l1i, loads from mmio); Put returns denied.
// The image comes from tg_bootrom_img_pkg, generated from sw/bootrom/bootrom.S.
module tg_bootrom
  import tg_pkg::*, tg_tl_pkg::*, tg_uncore_pkg::*, tg_bootrom_img_pkg::*;
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
  logic                 busy_q, get_q;
  logic [7:0]           beat_q;        // 128-bit beat index inside the ROM
  logic [1:0]           left_q;        // beats left after the current one
  logic [TL_SIZE_W-1:0] size_q;
  logic [TL_SRC_W-1:0]  src_q;

  logic [1:0]           put_beat_q;    // beats of a multi-beat Put absorbed so far
  wire [1:0] a_lastb = tl_a_last(a_i.opcode, a_i.size);
  wire       a_last  = a_lastb == 2'd0 || put_beat_q == a_lastb;
  wire [1:0] nbeat  = tl_last_beat(a_i.size);

  // Accept A when idle; a multi-beat Put is absorbed beat by beat, then answered.
  assign a_ready_o = !busy_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      busy_q     <= 1'b0;
      put_beat_q <= '0;
    end else if (!busy_q) begin
      if (a_valid_i) begin
        if (tl_a_has_data(a_i.opcode) && !a_last) begin
          put_beat_q <= put_beat_q + 1'b1;
        end else begin
          busy_q     <= 1'b1;
          put_beat_q <= '0;
        end
      end
    end else if (d_ready_i) begin
      if (left_q == 2'd0) busy_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (!busy_q && a_valid_i && a_last) begin
      get_q  <= a_i.opcode == A_GET;
      beat_q <= a_i.address[11:4] & ~{6'd0, nbeat};
      left_q <= (a_i.opcode == A_GET) ? nbeat : 2'd0;
      size_q <= a_i.size;
      src_q  <= a_i.source;
    end else if (busy_q && d_ready_i && left_q != 2'd0) begin
      beat_q <= beat_q + 1'b1;
      left_q <= left_q - 1'b1;
    end
  end

  always_comb begin
    d_o         = '0;
    d_o.opcode  = get_q ? D_ACCESS_ACK_DATA : D_ACCESS_ACK;
    d_o.size    = size_q;
    d_o.source  = src_q;
    d_o.denied  = !get_q;
    d_o.data    = (int'(beat_q) < BOOTROM_IMG_BEATS) ? BOOTROM_IMG[beat_q] : '0;
  end
  assign d_valid_o = busy_q;

  wire unused = ^{a_i.param, a_i.mask, a_i.data, a_i.corrupt, a_i.address[PA_W-1:12], a_i.address[3:0]};
endmodule
