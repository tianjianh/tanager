// Uncore-wide identifiers, structs and helpers (docs/spec/uncore.md).
// Owned by the SoC track. Board-independent: no KV260 or PS constant here.
package tg_uncore_pkg;
  import tg_pkg::*;
  import tg_tl_pkg::*;

  // ---- Initiators: the value the interconnect puts in source[9:6] ----
  localparam int MAX_CORES   = 4;               // agents 0..3 = l1d of cores 0..3
  localparam int N_INIT      = 16;              // source[9:6] space
  localparam int SRC_HI_W    = TL_SRC_W - TL_SRC_LOCAL_W;  // 4
  localparam int SRC_L1D0    = 0;
  localparam int SRC_L1I0    = 4;
  localparam int SRC_MMIO0   = 8;
  localparam int SRC_HDMA    = 12;
  localparam int AGENT_W     = 2;               // agent index = source[7:6] of an l1d initiator

  // ---- Targets of the interconnect ----
  localparam int N_BANKS     = 2;               // L2 banks, interleaved on address bit 6
  localparam int BANK_BIT    = 6;
  localparam int T_L2B0      = 0;
  localparam int T_ROM       = N_BANKS;
  localparam int T_DEV       = N_BANKS + 1;
  localparam int T_ERR       = N_BANKS + 2;
  localparam int N_TGT       = N_BANKS + 3;

  // L2 sink encoding: {bank, mshr}; sink 6'h3F is the error responder's.
  localparam logic [TL_SINK_W-1:0] SINK_ERR = '1;
  localparam int SINK_MSHR_W = TL_SINK_W - 1;

  // ---- PLIC sources (docs/spec/uncore.md) ----
  localparam int PLIC_NSRC     = 32;            // sources 1..31; riscv,ndev = 31
  localparam int IRQ_VIRTIO0   = 1;             // 1..4
  localparam int IRQ_UART      = 10;
  localparam int IRQ_HOSTCTL   = 11;
  localparam int IRQ_MERR0     = 16;            // 16 + hart, edge-triggered
  localparam int IRQ_PS0       = 20;            // the PS window's controllers (tg_map_pkg PS_WINDOW): 20 + PS_IRQ_*
  localparam int PS_IRQ_UART1  = 0;             // the PS-to-PL interrupts, as kv260_top passes them (levels)
  localparam int PS_IRQ_SD1    = 1;
  localparam int PS_IRQ_GEM3   = 2;
  localparam int PS_IRQ_USB0   = 3;             // USB0's host line (ps_pl_irq_usb3_0_endpoint[0])
  localparam int PS_IRQ_TTC1   = 4;             // TTC1 counter 0: D1's test (the A53 doesn't use TTC1)
  localparam int PS_IRQS       = 5;

  // ---- AXI4 (memory ports) ----
  localparam int AXI_ID_W    = 6;
  localparam int AXI_ADDR_W  = 40;
  localparam int AXI_DATA_W  = 128;
  localparam int AXI_STRB_W  = AXI_DATA_W / 8;

  typedef struct packed {
    logic [AXI_ID_W-1:0]   id;
    logic [AXI_ADDR_W-1:0] addr;
    logic [7:0]            len;    // beats - 1
    logic [2:0]            size;   // log2 bytes per beat
    logic [1:0]            burst;  // 1 = INCR
  } axi_ax_t;                      // AR and AW

  typedef struct packed {
    logic [AXI_DATA_W-1:0] data;
    logic [AXI_STRB_W-1:0] strb;
    logic                  last;
  } axi_w_t;

  typedef struct packed {
    logic [AXI_ID_W-1:0]   id;
    logic [1:0]            resp;
  } axi_b_t;

  typedef struct packed {
    logic [AXI_ID_W-1:0]   id;
    logic [AXI_DATA_W-1:0] data;
    logic [1:0]            resp;
    logic                  last;
  } axi_r_t;

  localparam logic [1:0] AXI_OKAY = 2'b00, AXI_SLVERR = 2'b10, AXI_DECERR = 2'b11;
  localparam logic [1:0] AXI_INCR = 2'b01;

  // ---- The coherent host DMA port (docs/spec/soc.md §8.1, tg_hdma): an AXI4 slave for the PS ----
  localparam int HDMA_ID_W = 16;                // M_AXI_HPM1_FPD's ID width

  typedef struct packed {
    logic [HDMA_ID_W-1:0]  id;
    logic [AXI_ADDR_W-1:0] addr;
    logic [7:0]            len;
    logic [2:0]            size;
    logic [1:0]            burst;
  } hdma_ax_t;                                  // AR and AW (W is axi_w_t)

  typedef struct packed {
    logic [HDMA_ID_W-1:0]  id;
    logic [1:0]            resp;
  } hdma_b_t;

  typedef struct packed {
    logic [HDMA_ID_W-1:0]  id;
    logic [AXI_DATA_W-1:0] data;
    logic [1:0]            resp;
    logic                  last;
  } hdma_r_t;

  // ---- Device bus (tg_tl_dev -> devices) ----
  localparam int DEV_ACLINT  = 0;
  localparam int DEV_PLIC    = 1;
  localparam int DEV_UART    = 2;
  localparam int DEV_HOSTCTL = 3;
  localparam int DEV_VIRTIO  = 4;               // the forwarded virtio window (tg_uncore VIRTIO_WINDOW)
  localparam int DEV_PSWIN   = 5;               // the PS window (tg_map_pkg PS_WINDOW, tg_ps_window)
  localparam int DEV_N       = 6;
  localparam int DEV_W       = 3;

  typedef struct packed {
    logic [PA_W-1:0] addr;     // full physical address; devices use the bits inside their window
    logic            we;
    logic [63:0]     wdata;    // in address lanes (byte k of the doubleword at bits 8k+7:8k)
    logic [7:0]      be;
    logic [1:0]      size;
  } dev_req_t;

  typedef struct packed {
    logic [63:0]     rdata;    // the addressed doubleword
    logic            err;
  } dev_rsp_t;

  // ---- The forwarded virtio window (docs/spec/soc.md §8.1, tg_vio_window) ----
  localparam int VIO_SLOTS = 4;                 // 4 KiB virtio-mmio slots from VIRTIO_BASE

  typedef struct packed {                       // a RISC-V access the host serves (request queue)
    logic [1:0]      slot;
    logic [11:0]     off;      // byte offset in the slot
    logic [1:0]      size;     // log2 bytes: 0, 1 or 2
    logic            we;
    logic [31:0]     wdata;    // a write's value from bit 0 (0 for a read)
  } vio_req_t;

  typedef struct packed {                       // from the host (event queue)
    logic            irq;      // 0: the waiting read's value; 1: status bits, data[7:0] set, data[15:8] clear
    logic [31:0]     data;
  } vio_ev_t;

  // ---- TileLink helpers ----
  function automatic logic tl_a_has_data(input tl_a_op_e op);
    return op == A_PUT_FULL || op == A_PUT_PARTIAL;
  endfunction

  function automatic logic tl_c_has_data(input tl_c_op_e op);
    return op == C_PROBE_ACK_DATA || op == C_RELEASE_DATA;
  endfunction

  function automatic logic tl_d_has_data(input tl_d_op_e op);
    return op == D_ACCESS_ACK_DATA || op == D_GRANT_DATA;
  endfunction

  // Beats of a message of `size` that carries data (128-bit beats): max(1, 2^size / 16), at most 4.
  function automatic logic [1:0] tl_last_beat(input logic [TL_SIZE_W-1:0] size);
    return (size <= 3'd4) ? 2'd0 : (size == 3'd5) ? 2'd1 : 2'd3;
  endfunction

  function automatic logic [1:0] tl_a_last(input tl_a_op_e op, input logic [TL_SIZE_W-1:0] size);
    return tl_a_has_data(op) ? tl_last_beat(size) : 2'd0;
  endfunction

  function automatic logic [1:0] tl_c_last(input tl_c_op_e op, input logic [TL_SIZE_W-1:0] size);
    return tl_c_has_data(op) ? tl_last_beat(size) : 2'd0;
  endfunction

  function automatic logic [1:0] tl_d_last(input tl_d_op_e op, input logic [TL_SIZE_W-1:0] size);
    return tl_d_has_data(op) ? tl_last_beat(size) : 2'd0;
  endfunction

  // ---- Build switches' defaults: tg_uncore's, which tanager_soc and kv260_top pass on (DR-146) ----
  // (each switch's meaning is at its parameter in tg_uncore)
  localparam logic [63:0] UNCORE_DSP_DEF    = {20'd0, 2'b00, 5'b00100, 5'b00100, 32'h0308_0000};
  localparam int          L2_DATA_LAT_DEF   = 2;
  localparam bit          AR_SLICE_DEF      = 1'b1;     // on since 10-15 (the user, DR-143)
  localparam bit          B_SLICE_DEF       = 1'b0;
  localparam bit          D_SLICE_DEF       = 1'b0;
  localparam bit          W_SLICE_DEF       = 1'b0;
  localparam logic [3:0]  XBAR_IN_SLICE_DEF = 4'b0000;
  localparam bit          XBAR_SLICE_DEF    = 1'b0;     // off since 10-22 (the user, DR-186)
  localparam bit          MEM_SLICE_DEF     = 1'b0;     // off since 10-22 (the user, DR-186)
endpackage
