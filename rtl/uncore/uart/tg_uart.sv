// 16550A-compatible UART, reg-shift 0 (docs/spec/uncore-periph.md). The line is virtual: the
// TX FIFO drains into the host stream (or into RX in loopback) as fast as it is accepted, and RX
// fills from the host stream while there is room. Divisor and framing bits are stored only.
module tg_uart
  import tg_pkg::*, tg_uncore_pkg::*;
#(
  parameter int unsigned CLK_HZ = 100_000_000,
  parameter int unsigned REF_HZ = 3_686_400,     // device-tree clock-frequency
  parameter int          DEPTH  = 16
) (
  input  logic       clk,
  input  logic       rst,
  input  dev_req_t   req_i,
  input  logic       req_valid_i,
  output dev_rsp_t   rsp_o,
  output logic       irq_o,
  // host streams (through the host bridge)
  output logic       tx_valid_o,
  input  logic       tx_ready_i,
  output logic [7:0] tx_byte_o,
  input  logic       rx_valid_i,
  output logic       rx_ready_o,
  input  logic [7:0] rx_byte_i
);
  localparam int CW = $clog2(DEPTH) + 1;
  // Character timeout: 4 characters of 10 bits at the programmed divisor, at least 1024 cycles.
  localparam longint unsigned TO_MULT = (longint'(640) * longint'(CLK_HZ)) / longint'(REF_HZ);

  // ---- Registers ----
  logic [7:0] lcr_q, scr_q, dll_q, dlm_q;
  logic [3:0] ier_q;
  logic [4:0] mcr_q;
  logic       fifo_en_q;
  logic [1:0] trig_q;
  logic       thre_ip_q;

  // ---- FIFOs ----
  logic [0:0][7:0] txf_rd, rxf_rd;          // heads of the FIFOs (tg_ram_lut, below)
  logic [CW-1:0] tx_wp_q, tx_rp_q, rx_wp_q, rx_rp_q;
  wire  [CW-1:0] tx_cnt = tx_wp_q - tx_rp_q;
  wire  [CW-1:0] rx_cnt = rx_wp_q - rx_rp_q;
  wire  [CW-1:0] cap    = fifo_en_q ? CW'(DEPTH) : CW'(1);   // 16450 mode: one byte each way
  wire           tx_empty = tx_cnt == '0;
  wire           rx_empty = rx_cnt == '0;

  wire       dlab = lcr_q[7];
  wire       loop = mcr_q[4];
  wire [2:0] ri   = req_i.addr[2:0];                          // register index
  wire [7:0] wd   = req_i.wdata[{ri, 3'd0} +: 8];
  wire       wr   = req_valid_i && req_i.we && req_i.be[ri];
  wire       rd   = req_valid_i && !req_i.we;

  // ---- Interrupt identification ----
  logic [CW-1:0] trig_lvl;
  always_comb begin
    unique case (trig_q)
      2'd0: trig_lvl = CW'(1);
      2'd1: trig_lvl = CW'(4);
      2'd2: trig_lvl = CW'(8);
      default: trig_lvl = CW'(14);
    endcase
    if (!fifo_en_q) trig_lvl = CW'(1);
  end

  logic [31:0] idle_q;
  logic        cti_q;
  wire  [31:0] to_cycles_raw = 32'(TO_MULT * {dlm_q, dll_q});
  wire  [31:0] to_cycles     = (to_cycles_raw < 32'd1024) ? 32'd1024 : to_cycles_raw;

  wire rda  = ier_q[0] && rx_cnt >= trig_lvl;
  wire cti  = ier_q[0] && fifo_en_q && cti_q && !rx_empty;
  wire thre = ier_q[1] && thre_ip_q;
  logic [2:0] iid;
  logic       ipend;
  always_comb begin
    ipend = 1'b1;
    if (rda)       iid = 3'b010;
    else if (cti)  iid = 3'b110;
    else if (thre) iid = 3'b001;
    else begin
      iid   = 3'b000;
      ipend = 1'b0;
    end
  end
  wire [7:0] iir = {fifo_en_q, fifo_en_q, 2'b00, iid, !ipend};

  // ---- Data movement ----
  // TX drains to the host stream, or to RX in loopback while RX has room.
  wire tx_to_rx   = loop && !tx_empty && rx_cnt < cap;
  wire tx_to_host = !loop && !tx_empty && tx_ready_i;
  wire tx_pop     = tx_to_rx || tx_to_host;
  wire rx_from_host = !loop && rx_valid_i && rx_cnt < cap;
  wire rx_push    = tx_to_rx || rx_from_host;
  wire [7:0] rx_in = tx_to_rx ? txf_rd[0] : rx_byte_i;

  wire thr_wr   = wr && ri == 3'd0 && !dlab;
  wire rbr_rd   = rd && ri == 3'd0 && !dlab;
  wire iir_rd   = rd && ri == 3'd2;
  wire fcr_wr   = wr && ri == 3'd2;
  wire tx_push  = thr_wr && tx_cnt < cap;
  wire tx_reset = fcr_wr && (wd[2] || (wd[0] != fifo_en_q));
  wire rx_reset = fcr_wr && (wd[1] || (wd[0] != fifo_en_q));
  wire rx_pop   = rbr_rd && !rx_empty;

  assign tx_valid_o = !loop && !tx_empty;
  assign tx_byte_o  = txf_rd[0];

  // FIFO storage in LUTRAM; a FIFO reset (FCR) wins over a push in the same cycle
  tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(8), .NR(1)) u_txf (
    .clk, .we (!rst && !tx_reset && tx_push), .waddr (tx_wp_q[CW-2:0]), .wdata (wd),
    .raddr (tx_rp_q[CW-2:0]), .rdata (txf_rd)
  );
  tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(8), .NR(1)) u_rxf (
    .clk, .we (!rst && !rx_reset && rx_push), .waddr (rx_wp_q[CW-2:0]), .wdata (rx_in),
    .raddr (rx_rp_q[CW-2:0]), .rdata (rxf_rd)
  );
  assign rx_ready_o = !loop && rx_cnt < cap;

  always_ff @(posedge clk) begin
    if (rst) begin
      lcr_q     <= 8'h00;
      scr_q     <= 8'h00;
      dll_q     <= 8'h02;      // 115200 baud at 3.6864 MHz
      dlm_q     <= 8'h00;
      ier_q     <= '0;
      mcr_q     <= '0;
      fifo_en_q <= 1'b0;
      trig_q    <= '0;
      thre_ip_q <= 1'b0;
      tx_wp_q   <= '0;
      tx_rp_q   <= '0;
      rx_wp_q   <= '0;
      rx_rp_q   <= '0;
      idle_q    <= '0;
      cti_q     <= 1'b0;
    end else begin
      // Register writes
      if (wr) begin
        unique case (ri)
          3'd0: if (dlab) dll_q <= wd;
          3'd1: if (dlab) dlm_q <= wd;
                else begin
                  ier_q <= wd[3:0];
                  if (wd[1] && !ier_q[1] && tx_empty) thre_ip_q <= 1'b1;   // ETBEI 0 -> 1 while empty
                end
          3'd2: begin
                  fifo_en_q <= wd[0];
                  trig_q    <= wd[7:6];
                end
          3'd3: lcr_q <= wd;
          3'd4: mcr_q <= wd[4:0];
          3'd7: scr_q <= wd;
          default: ;
        endcase
      end
      // TX FIFO
      if (tx_reset) begin
        tx_wp_q <= '0;
        tx_rp_q <= '0;
      end else begin
        if (tx_push) tx_wp_q <= tx_wp_q + 1'b1;
        if (tx_pop) tx_rp_q <= tx_rp_q + 1'b1;
      end
      // THRE interrupt: raised when TX becomes empty; cleared by a THR write or by an IIR read
      // that reports it.
      if (thr_wr)                                         thre_ip_q <= 1'b0;
      else if (iir_rd && ipend && iid == 3'b001)          thre_ip_q <= 1'b0;
      else if ((tx_pop && tx_cnt == CW'(1) && !tx_push) || (tx_reset && !tx_empty))
                                                          thre_ip_q <= 1'b1;
      // RX FIFO
      if (rx_reset) begin
        rx_wp_q <= '0;
        rx_rp_q <= '0;
      end else begin
        if (rx_push) rx_wp_q <= rx_wp_q + 1'b1;
        if (rx_pop) rx_rp_q <= rx_rp_q + 1'b1;
      end
      // Character timeout: idle time since the last RX push or pop
      if (rx_push || rx_pop || rx_reset || rx_empty) begin
        idle_q <= '0;
        cti_q  <= 1'b0;
      end else if (idle_q >= to_cycles) begin
        cti_q <= 1'b1;
      end else begin
        idle_q <= idle_q + 1'b1;
      end
    end
  end

  // ---- Read data (registered); side effects above use the same decode ----
  logic [7:0] rv;
  always_comb begin
    unique case (ri)
      3'd0: rv = dlab ? dll_q : (rx_empty ? 8'h00 : rxf_rd[0]);
      3'd1: rv = dlab ? dlm_q : {4'b0, ier_q};
      3'd2: rv = iir;
      3'd3: rv = lcr_q;
      3'd4: rv = {3'b0, mcr_q};
      3'd5: rv = {1'b0, tx_empty, tx_empty, 4'b0, !rx_empty};          // TEMT, THRE, DR
      3'd6: rv = loop ? {mcr_q[3], mcr_q[2], mcr_q[0], mcr_q[1], 4'b0} : 8'hB0;   // DCD DSR CTS
      default: rv = scr_q;
    endcase
  end

  always_ff @(posedge clk) begin
    rsp_o.rdata <= 64'(rv) << {ri, 3'd0};
    rsp_o.err   <= 1'b0;
  end

  always_ff @(posedge clk) begin
    if (rst) irq_o <= 1'b0;
    else     irq_o <= ipend;
  end

  wire unused = ^{req_i.addr[PA_W-1:3], req_i.size, req_i.be};
endmodule
