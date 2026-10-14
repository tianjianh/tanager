// Serial line for tg_uart (docs/spec/uncore-periph.md §UART): the TX stream shifted out on txd and
// rxd shifted into the RX stream, 8N1, LSB first, at the baud the 16550's divisor sets:
// baud = REF_HZ / (16 x divisor); a divisor of 0 counts as 1.
// As in a 16550, a REF_HZ tick (from a fractional accumulator, so the error does not grow) is
// divided by the divisor into 16x ticks. Each direction has its own prescaler: TX restarts it with
// each character, RX at each start bit's falling edge, and RX samples mid-bit. RX starts only on a
// high-to-low edge, so after a framing error it waits for the line to idle before the next start
// bit. A received byte waits in one holding register until the UART takes it; one completed
// meanwhile is dropped (overrun), as is one with a framing error.
module tg_uart_phy #(
  parameter int unsigned CLK_HZ = 100_000_000,
  parameter int unsigned REF_HZ = 3_686_400
) (
  input  logic        clk,
  input  logic        rst,
  input  logic [15:0] div_i,
  // TX: one character at a time from the UART's TX FIFO
  input  logic        tx_valid_i,
  output logic        tx_ready_o,
  input  logic [7:0]  tx_byte_i,
  output logic        tx_busy_o,      // a character is on the line (LSR.TEMT stays 0)
  output logic        txd_o,
  // RX
  input  logic        rxd_i,          // asynchronous to clk
  output logic        rx_valid_o,
  input  logic        rx_ready_i,
  output logic [7:0]  rx_byte_o
);
  function automatic longint unsigned gcd(input longint unsigned a, input longint unsigned b);
    while (b != 0) begin
      longint unsigned t;
      t = a % b;
      a = b;
      b = t;
    end
    return a;
  endfunction
  localparam longint unsigned G     = gcd(64'(CLK_HZ), 64'(REF_HZ));
  localparam longint unsigned REF_K = 64'(REF_HZ) / G;     // REF_HZ / CLK_HZ in lowest terms
  localparam longint unsigned CLK_K = 64'(CLK_HZ) / G;
  localparam int BW = $clog2(CLK_K + REF_K + 1);

  if (REF_HZ * 2 > CLK_HZ) begin : g_bad_clk
    $error("tg_uart_phy: CLK_HZ must be at least twice REF_HZ");
  end

  // REF_HZ ticks
  logic [BW-1:0] bacc_q;
  wire           btick = bacc_q + BW'(REF_K) >= BW'(CLK_K);
  always_ff @(posedge clk) begin
    if (rst)        bacc_q <= '0;
    else if (btick) bacc_q <= bacc_q + BW'(REF_K) - BW'(CLK_K);
    else            bacc_q <= bacc_q + BW'(REF_K);
  end
  wire [15:0] div = (div_i == '0) ? 16'd1 : div_i;

  // ---- TX ----
  logic [15:0] tpre_q;                     // REF_HZ ticks left to the next 16x tick
  logic [3:0]  tsub_q;                     // 16x ticks within the bit
  logic [3:0]  tbit_q;                     // bit on the line: 0 start, 1-8 data, 9 stop
  logic [8:0]  tsh_q;                      // {stop, data} still to send after the start bit
  logic        tbusy_q, txd_q;
  wire         ttick = btick && tpre_q == 16'd1;

  assign tx_ready_o = !tbusy_q;
  assign tx_busy_o  = tbusy_q;
  assign txd_o      = txd_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      tbusy_q <= 1'b0;
      txd_q   <= 1'b1;
      tpre_q  <= 16'd1;
      tsub_q  <= '0;
      tbit_q  <= '0;
    end else if (!tbusy_q) begin
      if (tx_valid_i) begin
        tbusy_q <= 1'b1;
        txd_q   <= 1'b0;                   // start bit
        tsh_q   <= {1'b1, tx_byte_i};
        tpre_q  <= div;
        tsub_q  <= '0;
        tbit_q  <= '0;
      end
    end else begin
      if (btick) tpre_q <= (tpre_q == 16'd1) ? div : tpre_q - 1'b1;
      if (ttick) begin
        tsub_q <= tsub_q + 1'b1;
        if (tsub_q == 4'd15) begin
          if (tbit_q == 4'd9) begin
            tbusy_q <= 1'b0;               // the stop bit has had its full length
          end else begin
            txd_q  <= tsh_q[0];
            tsh_q  <= tsh_q >> 1;
            tbit_q <= tbit_q + 1'b1;
          end
        end
      end
    end
  end

  // ---- RX ----
  (* ASYNC_REG = "TRUE" *) logic [2:0] rsync_q;   // two-flop synchronizer, then the previous value
  wire         rxd_s = rsync_q[1];
  wire         rfall = rsync_q[2] && !rsync_q[1];
  logic [15:0] rpre_q;
  logic [3:0]  rsub_q;
  logic [3:0]  rbit_q;                     // 0 start, 1-8 data, 9 stop
  logic [7:0]  rsh_q;
  logic        ract_q;
  logic        hold_v_q;
  logic [7:0]  hold_q;
  wire         rtick = btick && rpre_q == 16'd1;

  assign rx_valid_o = hold_v_q;
  assign rx_byte_o  = hold_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      rsync_q  <= 3'b111;
      ract_q   <= 1'b0;
      hold_v_q <= 1'b0;
      rpre_q   <= 16'd1;
      rsub_q   <= '0;
      rbit_q   <= '0;
    end else begin
      rsync_q <= {rsync_q[1:0], rxd_i};
      if (hold_v_q && rx_ready_i) hold_v_q <= 1'b0;
      if (!ract_q) begin
        if (rfall) begin                   // falling edge: a start bit begins
          ract_q <= 1'b1;
          rpre_q <= div;
          rsub_q <= '0;
          rbit_q <= '0;
        end
      end else begin
        if (btick) rpre_q <= (rpre_q == 16'd1) ? div : rpre_q - 1'b1;
        if (rtick) begin
          rsub_q <= rsub_q + 1'b1;
          if (rsub_q == 4'd7) begin        // the middle of the bit
            rbit_q <= rbit_q + 1'b1;
            if (rbit_q == 4'd0) begin
              if (rxd_s) ract_q <= 1'b0;   // a glitch, not a start bit
            end else if (rbit_q <= 4'd8) begin
              rsh_q <= {rxd_s, rsh_q[7:1]};
            end else begin                 // the stop bit
              ract_q <= 1'b0;
              if (rxd_s && !(hold_v_q && !rx_ready_i)) begin
                hold_v_q <= 1'b1;
                hold_q   <= rsh_q;
              end
            end
          end
        end
      end
    end
  end
endmodule
