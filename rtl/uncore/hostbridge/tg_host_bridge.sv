// Host bridge (docs/spec/host.md): the A53's AXI4-Lite register window (clk_host), the RISC-V
// host-control block at HOSTCTL_BASE (clk, device bus), and the crossings between them.
//   host -> core: configuration (one mirrored vector), core/uncore reset levels, MBOX_OUT pulse,
//                 console input bytes (async FIFO)
//   core -> host: status (mirrored vector), POWER / TOHOST / DOORBELL pulses, console output bytes
//   the forwarded virtio window (VIRTIO, tg_vio_window): its request and event queues, VQ_* registers
//   the host DMA port's completions (HDMA, tg_hdma in tg_uncore): a queue into clk_host, HDMA_* registers
// 64-bit host registers commit when their high half is written, so a 64-bit value never crosses torn.
// Release builds (tg_uncore RELEASE, DR-180) build no host console (HOST_CONSOLE = 0: the UART's serial line
// is the console alone), no DMA line counters (HDMA_STATS = 0) and, without the trace, no DMA completion
// queue (HDMA_CPL = 0); their registers read 0, writes are ignored, and CAPS[9], [10] and [11] say which.
// Their crossings carry only the fields of what is built (CDC_TRIM).
module tg_host_bridge
  import tg_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;
#(
  parameter int unsigned CLK_HZ          = 100_000_000,
  parameter logic [7:0]  CFG_CODE        = 8'd0,         // 0 st, 1 smt2, 2 st_w3, 3 smt2_w3
  parameter int          N_CORES_SOC     = NUM_CORES,
  parameter bit          CORE_RST_INIT   = 1'b1,
  parameter bit          UNCORE_RST_INIT = 1'b1,
  parameter logic [39:0] DRAM_BASE_INIT  = '0,
  parameter logic [39:0] DRAM_SIZE_INIT  = '0,
  parameter bit          TRACE           = 1'b1,         // the trace stream is built (tg_uncore TRACE; DR-146)
  parameter bit          DEBUG           = 1'b0,         // DBG_SEL / DBG_VAL reach tg_uncore's debug counters
  parameter bit          VIRTIO          = 1'b0,         // the forwarded virtio window (tg_uncore VIRTIO_WINDOW)
  parameter bit          HDMA            = 1'b0,         // the host DMA port's registers (tg_uncore HOST_DMA)
  parameter bit          LAT_INJ         = 1'b1,         // the latency injectors are built (tg_uncore LAT_INJ; DR-177): else
                                                         // CAPS[1] and the INJ_* registers read 0, writes ignored
  parameter bit          HOST_CONSOLE    = 1'b1,         // the console FIFOs to and from the host (UART_*; CAPS[9])
  parameter bit          HDMA_STATS      = 1'b1,         // the DMA port's line counters (HDMA_RD/WR_LINES; CAPS[10])
  parameter bit          HDMA_CPL        = 1'b1,         // the DMA port's completion queue (HDMA_CTRL, _STATUS, _CPL*; CAPS[11])
  parameter bit          TRAFGEN         = 1'b1,         // the cores may be traffic generators (their TG_* fields cross)
  parameter bit          CDC_TRIM        = 1'b0,         // the crossings carry only the fields of what is built
  parameter bit          L2_PACE_REG     = 1'b0,         // L2_PACE is built (tg_uncore L2_WB_PACE); else it reads 0
  parameter logic [15:0] L2_PACE_INIT    = {12'd64, 4'd1} // L2_PACE at reset (tg_uncore_pkg L2_PACE_INIT_DEF)
) (
  // ---- host domain ----
  input  logic        clk_host,
  input  logic        rst_host,
  input  logic [15:0] s_awaddr,
  input  logic        s_awvalid,
  output logic        s_awready,
  input  logic [31:0] s_wdata,
  input  logic [3:0]  s_wstrb,
  input  logic        s_wvalid,
  output logic        s_wready,
  output logic [1:0]  s_bresp,
  output logic        s_bvalid,
  input  logic        s_bready,
  input  logic [15:0] s_araddr,
  input  logic        s_arvalid,
  output logic        s_arready,
  output logic [31:0] s_rdata,
  output logic [1:0]  s_rresp,
  output logic        s_rvalid,
  input  logic        s_rready,
  output logic        host_irq_o,
  // ---- core domain ----
  input  logic        clk,
  input  logic        rst,               // SoC reset (not the uncore reset this block generates)
  input  logic        ndmreset_i,        // the debug module's ndmreset (docs/spec/soc.md §9.3): cores and uncore, as CTRL = 0x3
  output logic        core_rst_o,
  output logic        uncore_rst_o,
  input  dev_req_t    req_i,
  input  logic        req_valid_i,
  output dev_rsp_t    rsp_o,
  input  logic        vio_req_valid_i,   // the virtio window: the device bus's fifth device
  output dev_rsp_t    vio_rsp_o,
  output logic        vio_wait_o,
  output logic [VIO_SLOTS-1:0] vio_irq_o, // PLIC sources 1-4
  output logic        mbox_irq_o,        // PLIC source 11
  output logic [15:0] l2_pace_o,         // L2_PACE (core side 0x048): the L2's write-back batching (tg_l2_bank)
  output logic [39:0] dram_base_o,
  output logic [39:0] dram_size_o,
  output logic [9:0]  inj_rd_delay_o,
  output logic [9:0]  inj_wr_delay_o,
  output logic        inj_mode_o,
  output logic [8:0]  inj_bw_o,
  input  logic        l2_init_done_i,
  input  logic [31:0] inj_rd_count_i,
  input  logic [31:0] inj_lat_sum_i,
  input  logic [15:0] inj_lat_max_i,
  // traffic generators (bring-up builds; docs/spec/soc.md §2.3)
  output logic        tg_en_o,
  output logic [27:0] tg_base_o,
  output logic [23:0] tg_lines_o,
  input  logic [31:0] tg_ops_i,
  input  logic [15:0] tg_errs_i,
  input  logic [27:0] tg_err_line_i,
  input  logic [15:0] tg_pass_i,
  // commit-trace streaming (tg_trace_stream in the core domain, docs/spec/uncore-trace.md)
  output logic        trs_enable_o,
  output logic        trs_wrap_o,
  output logic        trs_stop_arm_o,
  output logic [63:0] trs_stop_pc_o,
  output logic [15:0] trs_post_o,
  output logic        trs_start_arm_o,
  output logic [63:0] trs_start_pc_o,
  output logic [39:0] trs_base_o,
  output logic [4:0]  trs_size_log2_o,
  output logic [63:0] trs_rp_o,
  input  logic [63:0] trs_wp_i,
  input  logic [4:0]  trs_flags_i,     // capturing, started, stopped, full, AXI error
  input  logic [15:0] trs_buffered_i,
  input  logic [31:0] trs_stalls_i,
  // CTRL.TFREEZE (core domain): tg_uncore holds mtime while the commit trace stalls a core
  output logic        tfreeze_o,
  // board debug (tg_uncore DEBUG_CNT): the counter the host selects, and its value (core domain)
  output logic [7:0]  dbg_sel_o,
  input  logic [31:0] dbg_val_i,
  // host DMA port (tg_hdma, core domain): completions {line, AccessAck cycle} while recording, line counts
  output logic        hdma_cpl_en_o,
  input  logic        hdma_cpl_valid_i,
  input  logic [57:0] hdma_cpl_i,
  output logic        hdma_cpl_ready_o,
  input  logic [31:0] hdma_rd_lines_i,
  input  logic [31:0] hdma_wr_lines_i,
  input  logic [31:0] hdma_wr_drops_i,   // write bursts not done in full (answered OKAY all the same)
  // the board's status word (core domain), read-only at FAN (0x1400): the fan's PL regulator on the KV260
  // (kv260_top's tg_fan, stage D's D2); 0 elsewhere
  input  logic [31:0] board_status_i,
  // BOARD_CTRL (0x1404, RW, reset 0; docs/spec/soc-d4-modes.md), into the core domain: [0] the fan regulator
  // ignores the A53's PWM, [1] the board's reset path is enabled (the PS window passes CRL_APB RESET_CTRL, and
  // the PMOD reset hook is armed). The A53's U-Boot sets both in RISC-V mode; it reads back [3:2] = the hook's
  // reset write {answered an error or nothing, went out} (board_hook_i)
  output logic [1:0]  board_ctrl_o,
  input  logic [1:0]  board_hook_i,
  // console streams (tg_uart side)
  input  logic        con_tx_valid_i,
  output logic        con_tx_ready_o,
  input  logic [7:0]  con_tx_byte_i,
  output logic        con_rx_valid_o,
  input  logic        con_rx_ready_i,
  output logic [7:0]  con_rx_byte_o
);
  localparam logic [31:0] ID      = 32'h5447_4E52;      // "TNGR"
  localparam logic [63:0] HCTL_ID = 64'h4C54_4348_5254_4E47;  // "TNGRHCTL"
  localparam logic [7:0]  VER_MAJ = 8'd1, VER_MIN = 8'd0;

  // =============================================================================================
  // Host domain registers
  // =============================================================================================
  logic [3:0]  ctrl_q;                           // [0] cores reset, [1] uncore reset, [2] lossless, [3] tfreeze
  logic [1:0]  board_ctrl_q;                     // BOARD_CTRL
  logic [63:0] dram_base_q, dram_size_q, entry_q, dtb_q, fromhost_q;
  logic [31:0] lo_shadow_q;                      // low halves of 64-bit registers wait here
  logic [9:0]  inj_rd_q, inj_wr_q;
  logic        inj_mode_q;
  logic [8:0]  inj_bw_q;
  logic [4:0]  irq_en_q;                         // [4] only with VIRTIO
  logic        vq_en_q;
  logic        hdma_cpl_en_q;
  logic        tg_en_q;
  logic [27:0] tg_base_q;
  logic [23:0] tg_lines_q;
  logic [9:0]  trs_ctrl_q;                      // [0] enable, [1] wrap, [8] stop armed, [9] start armed
  logic [63:0] trs_stop_pc_q, trs_start_pc_q, trs_base_q, trs_rp_q;
  logic [15:0] trs_post_q;
  logic [4:0]  trs_size_q;
  logic [7:0]  dbg_sel_q;
  logic        pwr_pend_q, mbox_in_q, tohost_new_q;

  // status mirrored from the core domain
  typedef struct packed {
    logic        l2_init;
    logic        cores_rst;
    logic        uncore_rst;
    logic [15:0] power_val;
    logic [63:0] tohost;
    logic [15:0] tohost_seq;
    logic [31:0] inj_cnt;
    logic [31:0] inj_sum;
    logic [15:0] inj_max;
    logic [31:0] tg_ops;
    logic [15:0] tg_errs;
    logic [27:0] tg_err_line;
    logic [15:0] tg_pass;
    logic [63:0] trs_wp;
    logic [4:0]  trs_flags;
    logic [15:0] trs_buffered;
    logic [31:0] trs_stalls;
    logic [31:0] dbg_val;
    logic [2*VIO_SLOTS-1:0] vq_stat;
    logic        vq_wait;
    logic [31:0] hdma_rd;
    logic [31:0] hdma_wr;
    logic [31:0] hdma_drops;
    logic [31:0] board;
    logic [1:0]  board_hook;
  } status_t;
  status_t st_h;

  // console FIFOs
  logic        txh_v, txh_pop;
  logic [7:0]  txh_b;
  logic [11:0] txh_level;
  logic        rxh_push, rxh_ready;
  logic [7:0]  rxh_b;
  logic [9:0]  rxh_wlevel;

  // pulses from the core domain
  logic pwr_pulse_h, tohost_pulse_h, bell_pulse_h, mbox_out_h;

  // the host DMA port's completion queue, host side
  logic        cpl_h_valid, cpl_h_pop;
  logic [57:0] cpl_h;
  logic [4:0]  cpl_h_level;

  // the virtio window's queues, host side
  logic        vq_valid, vq_pop, vq_ev_valid, vq_ev_ready;
  vio_req_t    vq_head;
  vio_ev_t     vq_ev;
  logic [4:0]  vq_level, vq_ev_level;

  // ---- AXI4-Lite write path: take AW and W together, answer OKAY ----
  logic        wr_go, b_pend_q;
  assign s_awready = s_awvalid && s_wvalid && !b_pend_q;
  assign s_wready  = s_awvalid && s_wvalid && !b_pend_q;
  assign wr_go     = s_awvalid && s_wvalid && !b_pend_q;
  assign s_bvalid  = b_pend_q;
  assign s_bresp   = 2'b00;
  wire [15:0] wa   = {s_awaddr[15:2], 2'b00};
  wire [31:0] wd   = s_wdata;

  // ---- AXI4-Lite read path ----
  logic        r_pend_q;
  logic [31:0] rdata_q;
  assign s_arready = !r_pend_q;
  assign s_rvalid  = r_pend_q;
  assign s_rdata   = rdata_q;
  assign s_rresp   = 2'b00;
  wire [15:0] ra   = {s_araddr[15:2], 2'b00};
  wire        rd_go = s_arvalid && s_arready;

  logic [31:0] rd_mux;
  always_comb begin
    rd_mux = '0;
    unique case (ra)
      16'h000: rd_mux = ID;
      16'h004: rd_mux = {VER_MAJ, VER_MIN, 4'(N_CORES_SOC), 4'(1 << TID_W), CFG_CODE};
      16'h008: rd_mux = 32'(CLK_HZ);
      // [0] L2, [1] injector, [2] virtio window, [3] trace streaming, [7:4] banks, [8] host DMA, [9] host console,
      // [10] DMA line counters, [11] DMA completion queue
      16'h00C: rd_mux = {20'd0, HDMA && HDMA_CPL, HDMA && HDMA_STATS, HOST_CONSOLE, HDMA, 4'(N_BANKS), TRACE, VIRTIO,
                         LAT_INJ, 1'b1};
      16'h010: rd_mux = {28'd0, ctrl_q};
      16'h014: rd_mux = {28'd0, pwr_pend_q, st_h.l2_init, st_h.uncore_rst, st_h.cores_rst};
      16'h018: rd_mux = {pwr_pend_q, 15'd0, st_h.power_val};
      16'h020: rd_mux = dram_base_q[31:0];
      16'h024: rd_mux = dram_base_q[63:32];
      16'h028: rd_mux = dram_size_q[31:0];
      16'h02C: rd_mux = dram_size_q[63:32];
      16'h030: rd_mux = entry_q[31:0];
      16'h034: rd_mux = entry_q[63:32];
      16'h038: rd_mux = dtb_q[31:0];
      16'h03C: rd_mux = dtb_q[63:32];
      16'h040: rd_mux = {22'd0, inj_rd_q};
      16'h044: rd_mux = {22'd0, inj_wr_q};
      16'h048: rd_mux = {7'd0, inj_bw_q, 15'd0, inj_mode_q};
      16'h050: rd_mux = LAT_INJ ? st_h.inj_cnt : '0;
      16'h054: rd_mux = LAT_INJ ? st_h.inj_sum : '0;
      16'h058: rd_mux = LAT_INJ ? {16'd0, st_h.inj_max} : '0;
      16'h060: rd_mux = st_h.tohost[31:0];
      16'h064: rd_mux = st_h.tohost[63:32];
      16'h068: rd_mux = fromhost_q[31:0];
      16'h06C: rd_mux = fromhost_q[63:32];
      16'h070: rd_mux = {31'd0, mbox_in_q};
      16'h080: rd_mux = {27'd0, vq_valid, tohost_new_q, pwr_pend_q, mbox_in_q, txh_v};
      16'h084: rd_mux = {27'd0, irq_en_q};
      16'h088: rd_mux = {16'd0, st_h.tohost_seq};
      16'h0C0: rd_mux = {31'd0, tg_en_q};
      16'h0C4: rd_mux = {4'd0, tg_base_q};
      16'h0C8: rd_mux = {8'd0, tg_lines_q};
      16'h0D0: rd_mux = st_h.tg_ops;
      16'h0D4: rd_mux = {16'd0, st_h.tg_errs};
      16'h0D8: rd_mux = {4'd0, st_h.tg_err_line};
      16'h0DC: rd_mux = {16'd0, st_h.tg_pass};
      16'h1000: rd_mux = {22'd0, trs_ctrl_q};
      16'h1008: rd_mux = trs_stop_pc_q[31:0];
      16'h100C: rd_mux = trs_stop_pc_q[63:32];
      16'h1010: rd_mux = {16'd0, trs_post_q};
      16'h1018: rd_mux = trs_start_pc_q[31:0];
      16'h101C: rd_mux = trs_start_pc_q[63:32];
      16'h1020: rd_mux = trs_base_q[31:0];
      16'h1024: rd_mux = trs_base_q[63:32];
      16'h1028: rd_mux = {27'd0, trs_size_q};
      16'h1030: rd_mux = trs_rp_q[31:0];
      16'h1034: rd_mux = trs_rp_q[63:32];
      16'h1038: rd_mux = st_h.trs_wp[31:0];
      16'h103C: rd_mux = st_h.trs_wp[63:32];
      16'h1040: rd_mux = {st_h.trs_buffered, 11'd0, st_h.trs_flags};
      16'h1044: rd_mux = st_h.trs_stalls;
      16'h1048: rd_mux = {16'd0, 8'(N_CORES_SOC), 8'd64};
      16'h1100: rd_mux = {31'd0, vq_en_q};
      16'h1104: rd_mux = {st_h.vq_stat, 7'd0, st_h.vq_wait, 3'd0, vq_ev_level, 3'd0, vq_level};
      16'h1108: rd_mux = {vq_valid, 12'd0, vq_head.we, vq_head.size, 2'd0, vq_head.slot, vq_head.off};
      16'h110C: rd_mux = vq_head.wdata;
      16'h1300: rd_mux = {31'd0, hdma_cpl_en_q};
      16'h1304: rd_mux = {27'd0, cpl_h_level};
      16'h1308: rd_mux = HDMA_STATS ? st_h.hdma_rd : '0;
      16'h130C: rd_mux = HDMA_STATS ? st_h.hdma_wr : '0;
      16'h1310: rd_mux = {cpl_h_valid, 5'd0, cpl_h[57:32]};
      16'h1314: rd_mux = cpl_h[31:0];
      16'h1318: rd_mux = st_h.hdma_drops;
      16'h1400: rd_mux = st_h.board;
      16'h1404: rd_mux = {28'd0, st_h.board_hook, board_ctrl_q};
      16'h1200: rd_mux = {24'd0, dbg_sel_q};
      16'h1204: rd_mux = st_h.dbg_val;
      16'h100: rd_mux = {23'd0, txh_v, txh_b};
      16'h104: rd_mux = {20'd0, txh_level};
      16'h10C: rd_mux = HOST_CONSOLE ? 32'(512) - 32'(rxh_wlevel) : '0;
      default: rd_mux = '0;
    endcase
  end
  assign txh_pop = rd_go && ra == 16'h100 && txh_v;
  assign vq_pop  = rd_go && ra == 16'h110C && vq_valid;      // reading VQ_REQ1 pops the entry
  assign cpl_h_pop = rd_go && ra == 16'h1314 && cpl_h_valid; // reading HDMA_CPL1 pops the completion

  // the virtio window's events: VQ_RSP answers the waiting read, VQ_IRQ sets and clears status bits
  assign vq_ev_valid = VIRTIO && wr_go && (wa == 16'h1110 || wa == 16'h1114);
  assign vq_ev.irq   = wa == 16'h1114;
  assign vq_ev.data  = (wa == 16'h1114) ? {16'd0, wd[15:0]} : wd;

  // console input: one byte per write of UART_RX
  assign rxh_push = HOST_CONSOLE && wr_go && wa == 16'h108 && s_wstrb[0];
  assign rxh_b    = wd[7:0];

  logic mbox_out_req;
  assign mbox_out_req = wr_go && wa == 16'h074 && s_wstrb[0] && wd[0];

  always_ff @(posedge clk_host) begin
    if (rst_host) begin
      ctrl_q       <= {2'b0, UNCORE_RST_INIT, CORE_RST_INIT};
      board_ctrl_q <= '0;
      dram_base_q  <= 64'(DRAM_BASE_INIT);
      dram_size_q  <= 64'(DRAM_SIZE_INIT);
      entry_q      <= 64'(DRAM_BASE);
      dtb_q        <= 64'(DRAM_BASE) + 64'h220_0000;
      fromhost_q   <= '0;
      lo_shadow_q  <= '0;
      inj_rd_q     <= '0;
      inj_wr_q     <= '0;
      inj_mode_q   <= 1'b0;
      inj_bw_q     <= '0;
      irq_en_q     <= '0;
      vq_en_q      <= 1'b0;
      hdma_cpl_en_q <= 1'b0;
      tg_en_q      <= 1'b0;
      tg_base_q    <= 28'(DRAM_BASE >> 6);
      tg_lines_q   <= 24'd16384;          // 1 MiB per generator: twice the L2
      dbg_sel_q    <= '0;
      trs_ctrl_q     <= '0;
      trs_stop_pc_q  <= '0;
      trs_start_pc_q <= '0;
      trs_base_q     <= '0;
      trs_rp_q       <= '0;
      trs_post_q     <= '0;
      trs_size_q     <= '0;
      pwr_pend_q   <= 1'b0;
      mbox_in_q    <= 1'b0;
      tohost_new_q <= 1'b0;
      b_pend_q     <= 1'b0;
      r_pend_q     <= 1'b0;
    end else begin
      if (wr_go) begin
        b_pend_q <= 1'b1;
        unique case (wa)
          16'h010: if (s_wstrb[0]) ctrl_q <= wd[3:0];
          16'h018: if (s_wstrb[3] && wd[31]) pwr_pend_q <= 1'b0;
          16'h020, 16'h028, 16'h030, 16'h038, 16'h068: lo_shadow_q <= wd;
          16'h024: dram_base_q <= {wd, lo_shadow_q};
          16'h02C: dram_size_q <= {wd, lo_shadow_q};
          16'h034: entry_q     <= {wd, lo_shadow_q};
          16'h03C: dtb_q       <= {wd, lo_shadow_q};
          16'h06C: fromhost_q  <= {wd, lo_shadow_q};
          16'h040: if (LAT_INJ) inj_rd_q <= wd[9:0];
          16'h044: if (LAT_INJ) inj_wr_q <= wd[9:0];
          16'h048: if (LAT_INJ) begin inj_mode_q <= wd[0]; inj_bw_q <= wd[24:16]; end
          16'h070: if (s_wstrb[0] && wd[0]) mbox_in_q <= 1'b0;
          16'h080: if (s_wstrb[0] && wd[3]) tohost_new_q <= 1'b0;
          16'h084: irq_en_q <= {VIRTIO && wd[4], wd[3:0]};
          16'h0C0: tg_en_q <= wd[0];
          16'h0C4: tg_base_q <= wd[27:0];
          16'h0C8: tg_lines_q <= wd[23:0];
          16'h1404: if (s_wstrb[0]) board_ctrl_q <= wd[1:0];
          16'h1000: if (TRACE) trs_ctrl_q <= {wd[9:8], 6'd0, wd[1:0]};
          16'h1008, 16'h1018, 16'h1020, 16'h1030: lo_shadow_q <= wd;
          16'h100C: if (TRACE) trs_stop_pc_q  <= {wd, lo_shadow_q};
          16'h1010: if (TRACE) trs_post_q     <= wd[15:0];
          16'h101C: if (TRACE) trs_start_pc_q <= {wd, lo_shadow_q};
          16'h1024: if (TRACE) trs_base_q     <= {wd, lo_shadow_q};
          16'h1028: if (TRACE) trs_size_q     <= wd[4:0];
          16'h1034: if (TRACE) trs_rp_q       <= {wd, lo_shadow_q};
          16'h1100: if (VIRTIO) vq_en_q <= wd[0];
          16'h1300: if (HDMA && HDMA_CPL) hdma_cpl_en_q <= wd[0];
          16'h1200: if (DEBUG) dbg_sel_q <= wd[7:0];
          default: ;
        endcase
      end else if (s_bvalid && s_bready) begin
        b_pend_q <= 1'b0;
      end
      if (rd_go) begin
        r_pend_q <= 1'b1;
        rdata_q  <= rd_mux;
      end else if (s_rvalid && s_rready) begin
        r_pend_q <= 1'b0;
      end
      // events from the core domain (set wins over a same-cycle clear)
      if (pwr_pulse_h)    pwr_pend_q   <= 1'b1;
      if (bell_pulse_h)   mbox_in_q    <= 1'b1;
      if (tohost_pulse_h) tohost_new_q <= 1'b1;
    end
  end

  assign host_irq_o = |({vq_valid, tohost_new_q, pwr_pend_q, mbox_in_q, txh_v} & irq_en_q);

  // =============================================================================================
  // Crossings
  // =============================================================================================
  typedef struct packed {
    logic [39:0] dram_base;
    logic [39:0] dram_size;
    logic [63:0] entry;
    logic [63:0] dtb;
    logic [63:0] fromhost;
    logic [9:0]  inj_rd;
    logic [9:0]  inj_wr;
    logic        inj_mode;
    logic [8:0]  inj_bw;
    logic        lossless;
    logic        tfreeze;
    logic        tg_en;
    logic [27:0] tg_base;
    logic [23:0] tg_lines;
    logic [9:0]  trs_ctrl;
    logic [63:0] trs_stop_pc;
    logic [15:0] trs_post;
    logic [63:0] trs_start_pc;
    logic [39:0] trs_base;
    logic [4:0]  trs_size;
    logic [63:0] trs_rp;
    logic [7:0]  dbg_sel;
    logic        vq_en;
    logic        hdma_cpl_en;
    logic [1:0]  board_ctrl;
  } cfg_t;
  cfg_t cfg_h, cfg_c;
  localparam cfg_t CFG_INIT = '{dram_base: DRAM_BASE_INIT, dram_size: DRAM_SIZE_INIT, entry: 64'(DRAM_BASE),
                                dtb: 64'(DRAM_BASE) + 64'h220_0000, fromhost: '0, inj_rd: '0, inj_wr: '0,
                                inj_mode: 1'b0, inj_bw: '0, lossless: 1'b0, tfreeze: 1'b0, tg_en: 1'b0,
                                tg_base: 28'(DRAM_BASE >> 6), tg_lines: 24'd16384,
                                trs_ctrl: '0, trs_stop_pc: '0, trs_post: '0, trs_start_pc: '0,
                                trs_base: '0, trs_size: '0, trs_rp: '0, dbg_sel: '0, vq_en: 1'b0,
                                hdma_cpl_en: 1'b0, board_ctrl: '0};
  always_comb begin
    cfg_h.dram_base = dram_base_q[39:0];
    cfg_h.dram_size = dram_size_q[39:0];
    cfg_h.entry     = entry_q;
    cfg_h.dtb       = dtb_q;
    cfg_h.fromhost  = fromhost_q;
    cfg_h.inj_rd    = inj_rd_q;
    cfg_h.inj_wr    = inj_wr_q;
    cfg_h.inj_mode  = inj_mode_q;
    cfg_h.inj_bw    = inj_bw_q;
    cfg_h.lossless  = ctrl_q[2];
    cfg_h.tfreeze   = ctrl_q[3];
    cfg_h.tg_en     = tg_en_q;
    cfg_h.tg_base   = tg_base_q;
    cfg_h.tg_lines  = tg_lines_q;
    cfg_h.trs_ctrl     = trs_ctrl_q;
    cfg_h.trs_stop_pc  = trs_stop_pc_q;
    cfg_h.trs_post     = trs_post_q;
    cfg_h.trs_start_pc = trs_start_pc_q;
    cfg_h.trs_base     = trs_base_q[39:0];
    cfg_h.trs_size     = trs_size_q;
    cfg_h.trs_rp       = trs_rp_q;
    cfg_h.dbg_sel      = dbg_sel_q;
    cfg_h.vq_en        = vq_en_q;
    cfg_h.hdma_cpl_en  = hdma_cpl_en_q;
    cfg_h.board_ctrl   = board_ctrl_q;
  end
  // The fields that cross: every one, unless CDC_TRIM (release builds, DR-180). Then a feature's fields cross only
  // when it is built (a trace, injectors, traffic generators, debug counters, the virtio window, the DMA
  // completion queue or line counters, the host console); the others are constants, read at their reset values
  localparam bit X_INJ = !CDC_TRIM || LAT_INJ,      X_TRS = !CDC_TRIM || TRACE,   X_TG  = !CDC_TRIM || TRAFGEN,
                 X_DBG = !CDC_TRIM || DEBUG,        X_VIO = !CDC_TRIM || VIRTIO,  X_CON = !CDC_TRIM || HOST_CONSOLE,
                 X_CPL = !CDC_TRIM || (HDMA && HDMA_CPL), X_HST = !CDC_TRIM || (HDMA && HDMA_STATS),
                 X_HDMA = !CDC_TRIM || HDMA;
  localparam cfg_t CFG_LIVE = '{dram_base: '1, dram_size: '1, entry: '1, dtb: '1, fromhost: '1,
                                inj_rd: {10{X_INJ}}, inj_wr: {10{X_INJ}}, inj_mode: X_INJ, inj_bw: {9{X_INJ}},
                                lossless: X_CON, tfreeze: X_TRS, tg_en: X_TG, tg_base: {28{X_TG}}, tg_lines: {24{X_TG}},
                                trs_ctrl: {10{X_TRS}}, trs_stop_pc: {64{X_TRS}}, trs_post: {16{X_TRS}},
                                trs_start_pc: {64{X_TRS}}, trs_base: {40{X_TRS}}, trs_size: {5{X_TRS}},
                                trs_rp: {64{X_TRS}}, dbg_sel: {8{X_DBG}}, vq_en: X_VIO, hdma_cpl_en: X_CPL,
                                board_ctrl: '1};
  tg_cdc_mirror #(.W ($bits(cfg_t)), .INIT (CFG_INIT), .LIVE (CFG_LIVE)) u_cfg (
    .src_clk (clk_host), .src_rst (rst_host), .src_in (cfg_h),
    .dst_clk (clk), .dst_rst (rst), .dst_out (cfg_c)
  );

  // Reset levels into the core domain
  logic core_rst_c, uncore_rst_c;
  tg_cdc_bit #(.INIT (CORE_RST_INIT))   u_crst (.src_in (ctrl_q[0]), .dst_clk (clk), .dst_out (core_rst_c));
  tg_cdc_bit #(.INIT (UNCORE_RST_INIT)) u_urst (.src_in (ctrl_q[1]), .dst_clk (clk), .dst_out (uncore_rst_c));
  logic urst_q, crst_q;
  always_ff @(posedge clk) begin
    urst_q <= rst || uncore_rst_c || ndmreset_i;
    crst_q <= rst || uncore_rst_c || core_rst_c || ndmreset_i;
  end
  assign uncore_rst_o = urst_q;
  assign core_rst_o   = crst_q;

  tg_cdc_pulse u_mbox (.src_clk (clk_host), .src_rst (rst_host), .src_pulse (mbox_out_req),
                       .dst_clk (clk), .dst_rst (rst), .dst_pulse (mbox_out_h));

  // =============================================================================================
  // Core domain: host-control registers (device bus)
  // =============================================================================================
  logic [63:0] tohost_q;
  logic [15:0] tohost_seq_q, power_val_q;
  logic        mbox_pend_q;
  logic        pwr_pulse_c, tohost_pulse_c, bell_pulse_c;
  logic [15:0] l2_pace_q;

  wire [11:0] off = req_i.addr[11:0];
  wire        wr  = req_valid_i && req_i.we;
  function automatic logic [63:0] merge64(input logic [63:0] old, input logic [63:0] d, input logic [7:0] be);
    logic [63:0] r;
    for (int b = 0; b < 8; b++) r[8*b +: 8] = be[b] ? d[8*b +: 8] : old[8*b +: 8];
    return r;
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      tohost_q       <= '0;
      tohost_seq_q   <= '0;
      power_val_q    <= '0;
      mbox_pend_q    <= 1'b0;
      pwr_pulse_c    <= 1'b0;
      tohost_pulse_c <= 1'b0;
      bell_pulse_c   <= 1'b0;
      l2_pace_q      <= L2_PACE_INIT;
    end else begin
      pwr_pulse_c    <= 1'b0;
      tohost_pulse_c <= 1'b0;
      bell_pulse_c   <= 1'b0;
      if (wr) begin
        unique case (off[11:3])
          9'h004: if (|req_i.be[3:0]) begin                          // 0x020 POWER
                    power_val_q <= req_i.wdata[15:0];
                    pwr_pulse_c <= 1'b1;
                  end
          9'h005: begin                                               // 0x028 TOHOST
                    tohost_q       <= merge64(tohost_q, req_i.wdata, req_i.be);
                    tohost_seq_q   <= tohost_seq_q + 1'b1;
                    tohost_pulse_c <= 1'b1;
                  end
          9'h007: bell_pulse_c <= 1'b1;                               // 0x038 DOORBELL
          9'h008: if (req_i.be[0] && req_i.wdata[0]) mbox_pend_q <= 1'b0;   // 0x040 W1C
          9'h009: if (L2_PACE_REG) begin                              // 0x048 L2_PACE
                    if (req_i.be[0]) l2_pace_q[7:0]  <= req_i.wdata[7:0];
                    if (req_i.be[1]) l2_pace_q[15:8] <= req_i.wdata[15:8];
                  end
          default: ;
        endcase
      end
      if (mbox_out_h) mbox_pend_q <= 1'b1;
    end
  end

  logic [63:0] crd;
  always_comb begin
    unique case (off[11:3])
      9'h000:  crd = HCTL_ID;
      9'h001:  crd = cfg_c.entry;
      9'h002:  crd = cfg_c.dtb;
      9'h005:  crd = tohost_q;
      9'h006:  crd = cfg_c.fromhost;
      9'h008:  crd = {63'd0, mbox_pend_q};
      9'h009:  crd = L2_PACE_REG ? {48'd0, l2_pace_q} : '0;
      default: crd = '0;
    endcase
  end
  always_ff @(posedge clk) begin
    rsp_o.rdata <= crd;
    rsp_o.err   <= 1'b0;
  end
  assign mbox_irq_o = mbox_pend_q;
  assign l2_pace_o  = l2_pace_q;

  // Events to the host. Core-side writes are at least a few cycles apart (one device-bus access at
  // a time), which the pulse synchronizers need.
  tg_cdc_pulse u_pwr (.src_clk (clk), .src_rst (rst), .src_pulse (pwr_pulse_c),
                      .dst_clk (clk_host), .dst_rst (rst_host), .dst_pulse (pwr_pulse_h));
  tg_cdc_pulse u_toh (.src_clk (clk), .src_rst (rst), .src_pulse (tohost_pulse_c),
                      .dst_clk (clk_host), .dst_rst (rst_host), .dst_pulse (tohost_pulse_h));
  tg_cdc_pulse u_bel (.src_clk (clk), .src_rst (rst), .src_pulse (bell_pulse_c),
                      .dst_clk (clk_host), .dst_rst (rst_host), .dst_pulse (bell_pulse_h));

  // =============================================================================================
  // The forwarded virtio window (docs/spec/soc.md §8.1)
  // =============================================================================================
  logic [2*VIO_SLOTS-1:0] vq_stat_c;
  logic                   vq_wait_c;
  if (VIRTIO) begin : g_vio
    // the event queue empties with the uncore: on the host's reset or its uncore reset request
    logic vq_flush_q;
    always_ff @(posedge clk_host) vq_flush_q <= rst_host || ctrl_q[1];
    tg_vio_window u_vio (
      .clk, .rst (urst_q), .req_i, .req_valid_i (vio_req_valid_i), .rsp_o (vio_rsp_o), .wait_o (vio_wait_o),
      .en_i (cfg_c.vq_en), .irq_o (vio_irq_o), .stat_o (vq_stat_c), .rd_wait_o (vq_wait_c),
      .clk_host, .rst_host (vq_flush_q),
      .q_valid_o (vq_valid), .q_head_o (vq_head), .q_pop_i (vq_pop), .q_level_o (vq_level),
      .ev_valid_i (vq_ev_valid), .ev_i (vq_ev), .ev_ready_o (vq_ev_ready), .ev_level_o (vq_ev_level)
    );
  end else begin : g_no_vio
    assign vio_rsp_o   = '0;
    assign vio_wait_o  = 1'b0;
    assign vio_irq_o   = '0;
    assign vq_stat_c   = '0;
    assign vq_wait_c   = 1'b0;
    assign vq_valid    = 1'b0;
    assign vq_head     = '0;
    assign vq_level    = '0;
    assign vq_ev_ready = 1'b0;
    assign vq_ev_level = '0;
    wire unused_vio = ^{vio_req_valid_i, vq_pop, vq_ev_valid, vq_ev, cfg_c.vq_en};
  end

  // =============================================================================================
  // The host DMA port's completions (docs/spec/soc.md §8.1): 16 entries into clk_host; the uncore
  // reset empties the queue. Not in release builds without the trace (HDMA_CPL = 0)
  // =============================================================================================
  if (HDMA && HDMA_CPL) begin : g_hdma
    logic [4:0] cpl_c_level;
    tg_afifo #(.W (58), .DEPTH (16), .MEM ("distributed")) u_cpl (
      .wr_clk (clk), .wr_rst (urst_q), .in_valid (hdma_cpl_valid_i), .in_ready (hdma_cpl_ready_o), .in_data (hdma_cpl_i),
      .wr_level (cpl_c_level),
      .rd_clk (clk_host), .out_valid (cpl_h_valid), .out_ready (cpl_h_pop), .out_data (cpl_h), .rd_level (cpl_h_level)
    );
    assign hdma_cpl_en_o = cfg_c.hdma_cpl_en;
    wire unused_cpl = ^cpl_c_level;
  end else begin : g_no_hdma
    assign hdma_cpl_ready_o = 1'b1;
    assign hdma_cpl_en_o    = 1'b0;
    assign cpl_h_valid      = 1'b0;
    assign cpl_h            = '0;
    assign cpl_h_level      = '0;
    wire unused_cpl = ^{hdma_cpl_valid_i, hdma_cpl_i, cpl_h_pop, cfg_c.hdma_cpl_en};
  end
  if (!HDMA) begin : g_no_hdma_st
    wire unused_hdma = ^{hdma_rd_lines_i, hdma_wr_lines_i, hdma_wr_drops_i};
  end else if (!HDMA_STATS) begin : g_no_hdma_stats
    wire unused_hdma = ^{hdma_rd_lines_i, hdma_wr_lines_i};
  end

  // Status to the host
  status_t st_c;
  always_comb begin
    st_c.l2_init    = l2_init_done_i;
    st_c.cores_rst  = crst_q;
    st_c.uncore_rst = urst_q;
    st_c.power_val  = power_val_q;
    st_c.tohost     = tohost_q;
    st_c.tohost_seq = tohost_seq_q;
    st_c.inj_cnt    = inj_rd_count_i;
    st_c.inj_sum    = inj_lat_sum_i;
    st_c.inj_max    = inj_lat_max_i;
    st_c.tg_ops     = tg_ops_i;
    st_c.tg_errs    = tg_errs_i;
    st_c.tg_err_line = tg_err_line_i;
    st_c.tg_pass    = tg_pass_i;
    st_c.trs_wp       = trs_wp_i;
    st_c.trs_flags    = trs_flags_i;
    st_c.trs_buffered = trs_buffered_i;
    st_c.trs_stalls   = trs_stalls_i;
    st_c.dbg_val      = DEBUG ? dbg_val_i : '0;
    st_c.vq_stat      = vq_stat_c;
    st_c.vq_wait      = vq_wait_c;
    st_c.hdma_rd      = (HDMA && HDMA_STATS) ? hdma_rd_lines_i : '0;
    st_c.hdma_wr      = (HDMA && HDMA_STATS) ? hdma_wr_lines_i : '0;
    st_c.hdma_drops   = HDMA ? hdma_wr_drops_i : '0;
    st_c.board        = board_status_i;
    st_c.board_hook   = board_hook_i;
  end
  localparam status_t ST_LIVE = '{l2_init: 1'b1, cores_rst: 1'b1, uncore_rst: 1'b1, power_val: '1, tohost: '1,
                                 tohost_seq: '1, inj_cnt: {32{X_INJ}}, inj_sum: {32{X_INJ}}, inj_max: {16{X_INJ}},
                                 tg_ops: {32{X_TG}}, tg_errs: {16{X_TG}}, tg_err_line: {28{X_TG}}, tg_pass: {16{X_TG}},
                                 trs_wp: {64{X_TRS}}, trs_flags: {5{X_TRS}}, trs_buffered: {16{X_TRS}},
                                 trs_stalls: {32{X_TRS}}, dbg_val: {32{X_DBG}}, vq_stat: {2*VIO_SLOTS{X_VIO}},
                                 vq_wait: X_VIO, hdma_rd: {32{X_HST}}, hdma_wr: {32{X_HST}}, hdma_drops: {32{X_HDMA}},
                                 board: '1, board_hook: '1};
  tg_cdc_mirror #(.W ($bits(status_t)), .LIVE (ST_LIVE)) u_status (
    .src_clk (clk), .src_rst (rst), .src_in (st_c),
    .dst_clk (clk_host), .dst_rst (rst_host), .dst_out (st_h)
  );

  if (HOST_CONSOLE) begin : g_con
    // Console: RISC-V -> host (2048 bytes); bytes are dropped while full unless lossless
    logic txc_ready;
    logic [11:0] txc_level;
    logic [9:0]  rxc_level;
    tg_afifo #(.W (8), .DEPTH (2048)) u_tx (
      .wr_clk (clk), .wr_rst (rst), .in_valid (con_tx_valid_i), .in_ready (txc_ready), .in_data (con_tx_byte_i),
      .wr_level (txc_level),
      .rd_clk (clk_host), .out_valid (txh_v), .out_ready (txh_pop), .out_data (txh_b), .rd_level (txh_level)
    );
    assign con_tx_ready_o = txc_ready || !cfg_c.lossless;

    // Console: host -> RISC-V (512 bytes)
    tg_afifo #(.W (8), .DEPTH (512)) u_rx (
      .wr_clk (clk_host), .wr_rst (rst_host), .in_valid (rxh_push), .in_ready (rxh_ready), .in_data (rxh_b),
      .wr_level (rxh_wlevel),
      .rd_clk (clk), .out_valid (con_rx_valid_o), .out_ready (con_rx_ready_i), .out_data (con_rx_byte_o),
      .rd_level (rxc_level)
    );
    wire unused_con = ^{txc_level, rxc_level, rxh_ready};
  end else begin : g_no_con
    // no console through the host (release builds): the UART's characters go to its serial line alone, and
    // nothing comes back this way
    assign con_tx_ready_o = 1'b1;
    assign con_rx_valid_o = 1'b0;
    assign con_rx_byte_o  = '0;
    assign txh_v          = 1'b0;
    assign txh_b          = '0;
    assign txh_level      = '0;
    assign rxh_ready      = 1'b0;
    assign rxh_wlevel     = '0;
    wire unused_con = ^{con_tx_valid_i, con_tx_byte_i, con_rx_ready_i, txh_pop, rxh_push, rxh_b, rxh_ready,
                        cfg_c.lossless};
  end

  // Core-domain configuration outputs
  assign dram_base_o    = cfg_c.dram_base;
  assign board_ctrl_o   = cfg_c.board_ctrl;
  assign dram_size_o    = cfg_c.dram_size;
  assign inj_rd_delay_o = cfg_c.inj_rd;
  assign inj_wr_delay_o = cfg_c.inj_wr;
  assign inj_mode_o     = cfg_c.inj_mode;
  assign inj_bw_o       = cfg_c.inj_bw;
  assign tg_en_o        = cfg_c.tg_en;
  assign tfreeze_o      = cfg_c.tfreeze;
  assign tg_base_o      = cfg_c.tg_base;
  assign tg_lines_o     = cfg_c.tg_lines;
  assign trs_enable_o    = cfg_c.trs_ctrl[0];
  assign trs_wrap_o      = cfg_c.trs_ctrl[1];
  assign trs_stop_arm_o  = cfg_c.trs_ctrl[8];
  assign trs_start_arm_o = cfg_c.trs_ctrl[9];
  assign trs_stop_pc_o   = cfg_c.trs_stop_pc;
  assign trs_post_o      = cfg_c.trs_post;
  assign trs_start_pc_o  = cfg_c.trs_start_pc;
  assign trs_base_o      = cfg_c.trs_base;
  assign trs_size_log2_o = cfg_c.trs_size;
  assign trs_rp_o        = cfg_c.trs_rp;
  assign dbg_sel_o       = cfg_c.dbg_sel;

  wire unused = ^{s_awaddr[1:0], s_araddr[1:0], s_wstrb[2:1], req_i.addr[PA_W-1:12], req_i.size, off[2:0],
                  cfg_c.trs_ctrl[7:2], vq_ev_ready};
endmodule
