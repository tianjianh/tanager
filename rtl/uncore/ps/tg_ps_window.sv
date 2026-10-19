// The PS window (docs/spec/soc.md §8.2, stage D's first milestone D1): the PS's peripheral registers at
// their own addresses, PSWIN_BASE..+PSWIN_SIZE (0xFE00_0000-0xFFFF_FFFF), reached through the PS's
// S_AXI_LPD port, so the RISC-V can drive the SD, GEM, USB and UART controllers itself.
//   - One device access at a time becomes one single-beat AXI4 transaction (len 0, the access's size,
//     INCR, id 0; kv260_top adds device non-bufferable, unprivileged non-secure data) on the 128-bit
//     port: the device bus's doubleword goes to the half that address bit 3 names, its byte enables
//     with it, and a read returns that half. The device bus waits (wait_o) for the response.
//   - Only the apertures below pass: the controllers stage D takes over (the coordinator's condition:
//     blocks D0 confirms clocked) and IOU_SLCR, read-only. Any other address, a write to IOU_SLCR, an
//     error response, or no response within 2^TIMEOUT_LOG2 cycles answers denied, and the core takes
//     an access fault: an unclocked PS block can stall the interconnect, and the RISC-V must not hang
//     behind it. TTC0, the fan's PWM, stays out.
//   - After a timeout the transaction is still open: valids already raised stay up until accepted, the
//     late response is taken and dropped, and every access meanwhile is denied without a new transaction.
//   - The board's reset (docs/spec/soc-d4-modes.md, D4's RISC-V mode), only while rst_en_i (the host's
//     BOARD_CTRL[1]) is set, so with it clear the window is as before: CRL_APB RESET_CTRL (0xFF5E_0218)
//     passes, that word alone (no doubleword), so the RISC-V's reboot can write its SOFT_RESET bit; and
//     rst_req_i (the PMOD reset hook) makes the window write that bit itself, once, whatever the cores do:
//     at the first idle cycle, ahead of an access in it, and every access while it is open is denied.
//     rst_fired_o and rst_err_o (an error or no answer) say how it went, for the host's BOARD_CTRL; both
//     clear when rst_en_i does, so the host can arm the write again. A transaction that never ends (the
//     port blocked) holds the reset write back too: then only a power cycle helps.
module tg_ps_window
  import tg_pkg::*, tg_uncore_pkg::*;
#(
  parameter int TIMEOUT_LOG2 = 16
) (
  input  logic     clk,
  input  logic     rst,
  input  dev_req_t req_i,
  input  logic     req_valid_i,
  output dev_rsp_t rsp_o,
  output logic     wait_o,
  // AXI4 master into S_AXI_LPD
  output axi_ax_t  m_aw_o,
  output logic     m_aw_valid_o,
  input  logic     m_aw_ready_i,
  output axi_w_t   m_w_o,
  output logic     m_w_valid_o,
  input  logic     m_w_ready_i,
  input  axi_b_t   m_b_i,
  input  logic     m_b_valid_i,
  output logic     m_b_ready_o,
  output axi_ax_t  m_ar_o,
  output logic     m_ar_valid_o,
  input  logic     m_ar_ready_i,
  input  axi_r_t   m_r_i,
  input  logic     m_r_valid_i,
  output logic     m_r_ready_o,
  output logic     timeout_o,                 // a pulse for each transaction that timed out
  input  logic     rst_en_i,                  // the board's reset passes (BOARD_CTRL[1]; quasi-static)
  input  logic     rst_req_i,                 // write RESET_CTRL's SOFT_RESET now (the PMOD reset hook)
  output logic     rst_fired_o,               // that write went out
  output logic     rst_err_o                  // and was answered with an error, or not at all
);
  // {passes, writable} for an address in the window, from its bits [31:16] (64 KiB granules)
  function automatic logic [1:0] aperture(input logic [15:0] hi);
    if (hi == 16'hFF01)        return 2'b11;    // UART1
    if (hi == 16'hFF0E)        return 2'b11;    // GEM3
    if (hi == 16'hFF12)        return 2'b11;    // TTC1
    if (hi == 16'hFF17)        return 2'b11;    // SD1
    if (hi[15:3] == 13'h1FE3)  return 2'b10;    // IOU_SLCR (0xFF18_0000, 512 KiB), read-only
    if (hi == 16'hFF9D)        return 2'b11;    // USB0's glue registers
    if (hi[15:4] == 12'hFE2)   return 2'b11;    // USB0's DWC3 core (0xFE20_0000, 1 MiB)
    return 2'b00;
  endfunction

  localparam logic [31:0] RESET_CTRL = 32'hFF5E_0218;   // CRL_APB: [4] SOFT_RESET, a system reset

  typedef enum logic [1:0] { P_IDLE, P_ADDR, P_RESP, P_DRAIN } pst_e;
  pst_e        st_q;
  logic        we_q, aw_q, w_q, ar_q;           // the access's direction; valids still up
  logic        busy_q;                          // the access on the device bus waits for its answer
  dev_rsp_t    rsp_q;
  logic [TIMEOUT_LOG2-1:0] tmo_q;
  axi_ax_t     ax_q;
  axi_w_t      w_dat_q;
  logic        hi_q;                            // the access's doubleword is the beat's upper half
  logic        int_q;                           // the open transaction is the reset write, not an access
  logic        fired_q, err_q;

  wire [1:0] ap    = aperture(req_i.addr[31:16]);
  wire       rst_w = rst_en_i && req_i.addr[31:2] == RESET_CTRL[31:2] && req_i.size != 2'd3;
  wire       allow = rst_w || (ap[1] && (!req_i.we || ap[0]));
  wire       go_rst = rst_en_i && rst_req_i && !fired_q;   // the reset write starts (from P_IDLE)
  wire       open  = st_q == P_ADDR || st_q == P_RESP;
  wire       b_hs  = m_b_valid_i && m_b_ready_o;
  wire       r_hs  = m_r_valid_i && m_r_ready_o;
  wire       resp  = we_q ? b_hs : r_hs;
  wire       tmo   = (busy_q || int_q) && open && !resp && &tmo_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      st_q   <= P_IDLE;
      busy_q <= 1'b0;
      aw_q   <= 1'b0;
      w_q    <= 1'b0;
      ar_q   <= 1'b0;
      rsp_q  <= '0;
      tmo_q  <= '0;
      int_q  <= 1'b0;
      fired_q <= 1'b0;
      err_q  <= 1'b0;
    end else begin
      if (m_aw_valid_o && m_aw_ready_i) aw_q <= 1'b0;
      if (m_w_valid_o && m_w_ready_i)   w_q  <= 1'b0;
      if (m_ar_valid_o && m_ar_ready_i) ar_q <= 1'b0;
      if (open) tmo_q <= tmo_q + 1'b1;
      if (!rst_en_i && !int_q) begin
        fired_q <= 1'b0;
        err_q   <= 1'b0;
      end
      unique case (st_q)
        P_IDLE: if (go_rst) begin                          // the reset write: AW and W, ahead of an access
          st_q    <= P_ADDR;
          int_q   <= 1'b1;
          fired_q <= 1'b1;
          aw_q    <= 1'b1;
          w_q     <= 1'b1;
          tmo_q   <= '0;
          if (req_valid_i) rsp_q <= '{rdata: 64'd0, err: 1'b1};
        end else if (req_valid_i) begin
          if (allow) begin
            st_q   <= P_ADDR;
            busy_q <= 1'b1;
            aw_q   <= req_i.we;
            w_q    <= req_i.we;
            ar_q   <= !req_i.we;
            tmo_q  <= '0;
          end else begin
            rsp_q  <= '{rdata: 64'd0, err: 1'b1};         // answered in the next cycle, no wait
          end
        end
        P_ADDR, P_RESP: begin
          if (st_q == P_ADDR && !aw_q && !w_q && !ar_q) st_q <= P_RESP;
          if (int_q && req_valid_i) rsp_q <= '{rdata: 64'd0, err: 1'b1};   // an access during the reset write
          if (resp && int_q) begin
            err_q  <= m_b_i.resp != AXI_OKAY;
            int_q  <= 1'b0;
            st_q   <= P_IDLE;
          end else if (tmo && int_q) begin
            err_q  <= 1'b1;
            int_q  <= 1'b0;
            st_q   <= P_DRAIN;
          end else if (resp) begin
            rsp_q  <= '{rdata: hi_q ? m_r_i.data[127:64] : m_r_i.data[63:0],
                        err:   (we_q ? m_b_i.resp : m_r_i.resp) != AXI_OKAY};
            busy_q <= 1'b0;
            st_q   <= P_IDLE;
          end else if (tmo) begin
            rsp_q  <= '{rdata: 64'd0, err: 1'b1};
            busy_q <= 1'b0;
            st_q   <= P_DRAIN;
          end
        end
        P_DRAIN: begin                                   // the timed-out transaction is still open
          if (req_valid_i) rsp_q <= '{rdata: 64'd0, err: 1'b1};
          if (!aw_q && !w_q && !ar_q && resp) st_q <= P_IDLE;
        end
        default: st_q <= P_IDLE;
      endcase
    end
  end

  // the transaction, captured with the access or for the reset write
  always_ff @(posedge clk) begin
    if (st_q == P_IDLE && go_rst) begin
      we_q         <= 1'b1;
      hi_q         <= RESET_CTRL[3];
      ax_q.id      <= '0;
      ax_q.addr    <= AXI_ADDR_W'(RESET_CTRL);
      ax_q.len     <= 8'd0;
      ax_q.size    <= 3'd2;                             // 4 bytes
      ax_q.burst   <= AXI_INCR;
      w_dat_q.data <= {2{64'h10}};                      // SOFT_RESET
      w_dat_q.strb <= RESET_CTRL[3] ? 16'h0F00 : 16'h000F;
      w_dat_q.last <= 1'b1;
    end else if (st_q == P_IDLE && req_valid_i && allow) begin
      we_q         <= req_i.we;
      hi_q         <= req_i.addr[3];
      ax_q.id      <= '0;
      ax_q.addr    <= AXI_ADDR_W'(req_i.addr[31:0]);
      ax_q.len     <= 8'd0;
      ax_q.size    <= {1'b0, req_i.size};
      ax_q.burst   <= AXI_INCR;
      w_dat_q.data <= {req_i.wdata, req_i.wdata};
      w_dat_q.strb <= req_i.addr[3] ? {req_i.be, 8'h00} : {8'h00, req_i.be};
      w_dat_q.last <= 1'b1;
    end
  end

  assign rsp_o        = rsp_q;
  assign wait_o       = busy_q;
  assign m_aw_o       = ax_q;
  assign m_aw_valid_o = aw_q;
  assign m_w_o        = w_dat_q;
  assign m_w_valid_o  = w_q;
  assign m_ar_o       = ax_q;
  assign m_ar_valid_o = ar_q;
  assign m_b_ready_o  = (open || st_q == P_DRAIN) && we_q;
  assign m_r_ready_o  = (open || st_q == P_DRAIN) && !we_q;
  assign timeout_o    = tmo;
  assign rst_fired_o  = fired_q;
  assign rst_err_o    = err_q;

  wire unused = ^{req_i.addr[PA_W-1:32], m_b_i.id, m_r_i.id, m_r_i.last};
endmodule
