// The fan's PL regulator (docs/spec/soc.md §8.2, stage D's D2; DR-147 option F-a, DR-129, DR-150): fan_en_b
// (active low: low runs the fan) carries a 24.4 kHz PWM whose duty is the larger of two.
//   - A curve of the PL SYSMON's die temperature: fancontrol's as configured on the board, 15/255 at or below
//     35 C, linear to 255/255 at 45 C, full above. A rise moves it at once; a fall moves it only once the
//     temperature is 1 C under the level that set it.
//   - The A53's PWM (the TTC waveform Linux's pwm-fan drives, low = on, after FAN_INVERT in kv260_top): its
//     low time over each 2^18-cycle window (2.6 ms at 100 MHz, about 65 of its 40 us periods, so the window's
//     edges move the duty by about 2/256). A level that stays put counts as 0 or 255.
// So while the A53's fancontrol runs, the fan runs as it asks or faster; with fancontrol stopped and the TTC still
// running (pwm1 1 or more), the curve regulates alone. A disabled or reset TTC idles low, which reads as full (the
// board, 10-17), so D3's handover boot leaves pwm1 at 1.
// The temperature is the SYSMONE4's register 00h, read over DRP every 2^20 cycles. Every INIT attribute is zero:
// that is the state any bitstream load already leaves the PL SYSMON in (D2's probes, 10-17). The instance does
// take the PL SYSMON from the PS: while the bitstream is loaded the A53's AMS reads the PL channels as 0
// (AMS_PL_CSTS bit 0 is 0; the board, 10-17). fancontrol follows the PS SYSMON and is unaffected, so the
// coordinator kept it (docs/spec/soc.md §8.2).
// Until the first reading, and after a DRP read that never answers (2^16 cycles), the fan runs full.
// The code converts as the AMS driver does: T (C) = code x 509.314 / 2^16 - 280.231.
module tg_fan #(
  parameter int unsigned CLK_HZ = 100_000_000
) (
  input  logic        clk,
  input  logic        rst,                    // the PL's reset alone: not the uncore's or the cores'
  input  logic        ttc_wave_i,             // the A53's PWM, low = on; asynchronous
  output logic        fan_en_b_o,
  output logic [31:0] status_o                // [9:0] code[15:6], [17:10] TTC duty, [25:18] duty, [26] DRP
                                              // timeout, [27] a reading has come
);
  // ---- the curve's temperature codes (T + 280.231) x 2^16 / 509.314 ----
  localparam logic [15:0] C35  = 16'd40562;   // 35 C
  localparam logic [15:0] C45  = 16'd41849;   // 45 C
  localparam logic [15:0] HYST = 16'd129;     // 1 C
  localparam int unsigned MULT = 191;         // 240 / (C45 - C35) in 1/1024ths
  // ---- the PWM: 256 steps of PRE cycles, about 25 kHz (PRE 16 at 100 MHz: 24.4 kHz; 20 at 125 MHz) ----
  localparam int unsigned PRE = (CLK_HZ + 3_200_000) / 6_400_000;
  if (PRE < 2) begin : g_pre_check
    $error("tg_fan: CLK_HZ %0d is too slow for the PWM's prescaler", CLK_HZ);
  end

  // ---- the temperature: SYSMONE4 over DRP ----
  logic        den, drdy;
  logic [15:0] dout;
  SYSMONE4 #(.SIM_DEVICE ("ZYNQ_ULTRASCALE")) u_sysmon (
    .DCLK (clk), .DEN (den), .DADDR (8'h00), .DI (16'h0000), .DWE (1'b0), .DO (dout), .DRDY (drdy),
    .RESET (1'b0), .CONVST (1'b0), .CONVSTCLK (1'b0), .VAUXP (16'h0000), .VAUXN (16'h0000),
    .VP (), .VN (), .I2C_SCLK (), .I2C_SDA (),
    .ADC_DATA (), .ALM (), .BUSY (), .CHANNEL (), .EOC (), .EOS (), .I2C_SCLK_TS (), .I2C_SDA_TS (),
    .JTAGBUSY (), .JTAGLOCKED (), .JTAGMODIFIED (), .MUXADDR (), .OT (), .SMBALERT_TS ()
  );

  logic [19:0] tick_q;                        // a read every 2^20 cycles
  logic        wait_q, valid_q, tmo_q;
  logic [15:0] wcnt_q;
  logic [15:0] code_q, held_q;                // the last reading; the level the curve takes
  always_ff @(posedge clk) begin
    if (rst) begin
      tick_q  <= '0;
      wait_q  <= 1'b0;
      valid_q <= 1'b0;
      tmo_q   <= 1'b0;
      wcnt_q  <= '0;
      code_q  <= '0;
      held_q  <= '0;
    end else begin
      tick_q <= tick_q + 1'b1;
      if (wait_q) begin
        wcnt_q <= wcnt_q + 1'b1;
        if (drdy) begin
          wait_q  <= 1'b0;
          tmo_q   <= 1'b0;
          valid_q <= 1'b1;
          code_q  <= dout;
          if (!valid_q || dout > held_q)                  held_q <= dout;
          else if ({1'b0, dout} + {1'b0, HYST} < {1'b0, held_q}) held_q <= dout + HYST;
        end else if (&wcnt_q) begin
          wait_q <= 1'b0;
          tmo_q  <= 1'b1;
        end
      end else if (&tick_q) begin
        wait_q <= 1'b1;
        wcnt_q <= '0;
      end
    end
  end
  assign den = !rst && !wait_q && &tick_q;

  // the curve's duty from the held level
  logic [7:0] duty_curve;
  always_comb begin
    logic [25:0] p;
    p = 26'(held_q - C35) * 26'(MULT);
    if (!valid_q || tmo_q || held_q >= C45) duty_curve = 8'd255;
    else if (held_q <= C35)                 duty_curve = 8'd15;
    else                                    duty_curve = 8'd15 + 8'(p >> 10);
  end

  // ---- the A53's duty: low time per 2^18 cycles ----
  (* ASYNC_REG = "TRUE" *) logic [1:0] ttc_sync_q;
  logic [17:0] win_q;
  logic [18:0] low_q;
  logic [7:0]  duty_ttc_q;
  always_ff @(posedge clk) begin
    ttc_sync_q <= {ttc_sync_q[0], ttc_wave_i};
    if (rst) begin
      win_q      <= '0;
      low_q      <= '0;
      duty_ttc_q <= '0;
    end else begin
      win_q <= win_q + 1'b1;
      if (&win_q) begin
        duty_ttc_q <= low_q[18] ? 8'd255 : low_q[17:10];
        low_q      <= {18'd0, !ttc_sync_q[1]};
      end else begin
        low_q <= low_q + {18'd0, !ttc_sync_q[1]};
      end
    end
  end

  // ---- the PWM: the larger duty; 255 runs the fan all the time ----
  wire [7:0] duty = (duty_curve > duty_ttc_q) ? duty_curve : duty_ttc_q;
  logic [$clog2(PRE)-1:0] pre_q;
  logic [7:0] step_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      pre_q      <= '0;
      step_q     <= '0;
      fan_en_b_o <= 1'b0;                     // full speed until the regulator runs
    end else begin
      if (pre_q == $clog2(PRE)'(PRE - 1)) begin
        pre_q  <= '0;
        step_q <= step_q + 1'b1;
      end else begin
        pre_q <= pre_q + 1'b1;
      end
      fan_en_b_o <= !(duty == 8'd255 || step_q < duty);
    end
  end

  assign status_o = {4'd0, valid_q, tmo_q, duty, duty_ttc_q, code_q[15:6]};
  wire unused = ^code_q[5:0];
endmodule
