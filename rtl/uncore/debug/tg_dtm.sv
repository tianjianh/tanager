// The JTAG Debug Transport Module (docs/spec/soc.md §9.2; RISC-V Debug Specification 1.0, "JTAG Debug
// Transport Module"). TG_DEBUG builds only. Its two registers are plain data registers of the device's
// TAP, reached through BSCANE2 (UG974): dtmcs on JTAG_CHAIN 3 (USER3), dmi on JTAG_CHAIN 4 (USER4); OpenOCD
// selects them with `riscv set_ir dtmcs/dmi`. jtag_i carries the TAP's state outputs, which both BSCANE2s
// share, and each chain's SEL; a testbench drives them from a TAP model instead.
//   dtmcs (32 bits): version 1, abits 7, dmistat, idle IDLE, dmireset and dtmhardreset (write 1); errinfo 0.
//   dmi (41 bits: address 7, data 32, op 2): Update-DR starts a read (op 1) or write (op 2) unless the
//   status is sticky; Capture-DR returns the last answer, or op 3 (busy, sticky until dmireset) while a
//   request is still on its way.
// The request crosses to clk by a toggle and a two-flop synchronizer; its fields stay put until the
// answer has come back, which crosses the same way. IDLE (Run-Test/Idle cycles between scans) covers the
// round trip for TCK up to about 50 MHz with clk at 100 MHz; a debugger seeing busy waits longer.
module tg_dtm
  import tg_uncore_pkg::*;
#(
  parameter logic [2:0] IDLE = 3'd3
) (
  // JTAG side: TCK, the TAP's state outputs and the two chains' SEL; TDO per chain
  input  logic        tck,
  input  jtag_t       jtag_i,
  output logic [1:0]  tdo_o,          // [0] dtmcs (USER3), [1] dmi (USER4)

  // the DMI manager side (clk): one request at a time, answered by a pulse at least a cycle later
  input  logic        clk,
  output logic        dmi_req_o,      // one cycle
  output logic [6:0]  dmi_addr_o,
  output logic [31:0] dmi_wdata_o,
  output logic [1:0]  dmi_op_o,       // 1 read, 2 write
  input  logic        dmi_rsp_i,      // one cycle
  input  logic [31:0] dmi_rdata_i,
  input  logic [1:0]  dmi_resp_i      // 0 success, 2 failed
);
  localparam int ABITS = 7;
  localparam int DMI_W = ABITS + 34;

  // ---- TCK domain (FPGA power-up values; nothing here takes a reset but the sticky status) ----
  /* verilator lint_off PROCASSINIT */
  logic [31:0]      dtmcs_sr  = '0;
  logic [DMI_W-1:0] dmi_sr    = '0;
  logic [1:0]       stat_q    = 2'd0;   // dmistat: 0 none, 2 failed, 3 busy (both sticky)
  logic [ABITS-1:0] addr_q    = '0;     // the request on its way (or last sent), held for clk
  logic [31:0]      wdata_q   = '0;
  logic [1:0]       op_q      = 2'd0;
  logic [31:0]      rdata_q   = '0;     // the last answer's data
  logic             req_tog_q = 1'b0;   // flips for each request
  logic             rsp_seen_q = 1'b0;  // the answers taken, as a toggle
  /* verilator lint_on PROCASSINIT */
  logic             rsp_tog_t;          // clk's answer toggle, synchronized
  logic [31:0]      rsp_data_c;         // clk's answer, steady while rsp_tog_t settles
  logic [1:0]       rsp_resp_c;

  wire        sel_cs  = jtag_i.sel[0];
  wire        sel_dmi = jtag_i.sel[1];
  wire        rsp_new = rsp_tog_t != rsp_seen_q;
  wire        pend    = req_tog_q != rsp_tog_t;            // sent, not yet answered as of this edge
  wire [31:0] rdata_n = rsp_new ? rsp_data_c : rdata_q;
  wire [1:0]  dmi_op_in = dmi_sr[1:0];

  always_ff @(posedge tck) begin
    if (rsp_new) begin
      rsp_seen_q <= rsp_tog_t;
      rdata_q    <= rsp_data_c;
    end

    // dtmcs
    if (sel_cs && jtag_i.capture) dtmcs_sr <= {11'd0, 3'd0, 3'd0, IDLE, stat_q, 6'(ABITS), 4'd1};
    else if (sel_cs && jtag_i.shift) dtmcs_sr <= {jtag_i.tdi, dtmcs_sr[31:1]};

    // dmi
    if (sel_dmi && jtag_i.capture) dmi_sr <= {addr_q, rdata_n, stat_q != 2'd0 ? stat_q : pend ? 2'd3 : 2'd0};
    else if (sel_dmi && jtag_i.shift) dmi_sr <= {jtag_i.tdi, dmi_sr[DMI_W-1:1]};
    if (sel_dmi && jtag_i.update && stat_q == 2'd0 && !pend && (dmi_op_in == 2'd1 || dmi_op_in == 2'd2)) begin
      addr_q    <= dmi_sr[DMI_W-1:34];
      wdata_q   <= dmi_sr[33:2];
      op_q      <= dmi_op_in;
      req_tog_q <= !req_tog_q;
    end

    // sticky status: busy at a capture that finds the request on its way, failed from the answer;
    // dmireset, dtmhardreset and the TAP's Test-Logic-Reset clear it
    if (jtag_i.treset || (sel_cs && jtag_i.update && (dtmcs_sr[16] || dtmcs_sr[17]))) stat_q <= 2'd0;
    else if (sel_dmi && jtag_i.capture && pend && stat_q == 2'd0) stat_q <= 2'd3;
    else if (rsp_new && rsp_resp_c == 2'd2 && stat_q == 2'd0) stat_q <= 2'd2;

    // dtmhardreset: the registers to their reset values. A request on its way still completes (its
    // answer comes within a few clk cycles), so the handshake's toggles are left alone.
    if (sel_cs && jtag_i.update && dtmcs_sr[17]) begin
      addr_q  <= '0;
      rdata_q <= '0;
    end
  end
  assign tdo_o = {dmi_sr[0], dtmcs_sr[0]};

  // ---- clk domain ----
  logic        req_tog_c;
  /* verilator lint_off PROCASSINIT */
  logic        req_seen_q = 1'b0;
  logic        rsp_tog_q  = 1'b0;
  logic        req_q      = 1'b0;
  logic [6:0]  c_addr_q   = '0;
  logic [31:0] c_wdata_q  = '0;
  logic [1:0]  c_op_q     = 2'd0;
  logic [31:0] c_rdata_q  = '0;
  logic [1:0]  c_resp_q   = 2'd0;
  /* verilator lint_on PROCASSINIT */
  tg_cdc_bit #(.STAGES (2)) u_req_sync (.src_in (req_tog_q), .dst_clk (clk), .dst_out (req_tog_c));
  tg_cdc_bit #(.STAGES (2)) u_rsp_sync (.src_in (rsp_tog_q), .dst_clk (tck), .dst_out (rsp_tog_t));

  always_ff @(posedge clk) begin
    req_q <= 1'b0;
    if (req_tog_c != req_seen_q) begin      // the fields settled before the toggle crossed
      req_seen_q <= req_tog_c;
      req_q      <= 1'b1;
      c_addr_q   <= addr_q;
      c_wdata_q  <= wdata_q;
      c_op_q     <= op_q;
    end
    if (dmi_rsp_i) begin
      c_rdata_q <= dmi_rdata_i;
      c_resp_q  <= dmi_resp_i;
      rsp_tog_q <= !rsp_tog_q;
    end
  end
  assign dmi_req_o   = req_q;
  assign dmi_addr_o  = c_addr_q;
  assign dmi_wdata_o = c_wdata_q;
  assign dmi_op_o    = c_op_q;
  assign rsp_data_c  = c_rdata_q;
  assign rsp_resp_c  = c_resp_q;
endmodule
