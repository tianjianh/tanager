// The forwarded virtio window (docs/spec/soc.md §8.1, stage C's option C-b): the device bus's virtio
// slots, four 4 KiB virtio-mmio register sets at VIRTIO_BASE, served by the A53 (tanager-host).
//   - Every access but InterruptStatus and InterruptACK becomes an entry of the request queue (an
//     asynchronous FIFO into clk_host, 16 entries in LUTRAM), which the host pops through the host
//     bridge (VQ_REQ0, VQ_REQ1). A write is posted: the device bus is answered once its entry is
//     queued. A read holds the device bus (wait_o) until the host's value comes back (VQ_RSP).
//   - InterruptStatus (0x060) and InterruptACK (0x064) are answered here. Each slot has two status
//     bits, 0 used buffer and 1 configuration change: the host sets and clears them (VQ_IRQ), the
//     driver's InterruptACK clears them, and their OR is the slot's PLIC source (level).
//   - While the host doesn't serve the window (en_i low: VQ_CTRL.EN), the forwarded accesses are
//     answered here instead: reads return 0, so a driver finds no device (MagicValue 0), and writes
//     are dropped. EN is meant to change only while the uncore is in reset.
//   - 64-bit accesses answer denied: virtio-mmio's registers take 8-, 16- and 32-bit ones.
// The event queue (host -> core, 16 entries) carries the host's read values and status-bit changes
// in the host's order, and the core side takes one per cycle. A value with no read waiting is
// dropped. Both queues empty on the uncore reset (the host bridge resets the event queue's host
// side with the host's uncore reset request).
module tg_vio_window
  import tg_pkg::*, tg_uncore_pkg::*;
(
  // ---- core domain ----
  input  logic                   clk,
  input  logic                   rst,          // the uncore reset
  input  dev_req_t               req_i,
  input  logic                   req_valid_i,
  output dev_rsp_t               rsp_o,
  output logic                   wait_o,
  input  logic                   en_i,         // the host serves the window
  output logic [VIO_SLOTS-1:0]   irq_o,        // PLIC sources IRQ_VIRTIO0 + slot
  output logic [2*VIO_SLOTS-1:0] stat_o,       // the status bits, slot s at [2s+1:2s]
  output logic                   rd_wait_o,    // a read waits for the host's value
  // ---- host domain ----
  input  logic                   clk_host,
  input  logic                   rst_host,     // empties the event queue
  output logic                   q_valid_o,    // the request queue's head
  output vio_req_t               q_head_o,
  input  logic                   q_pop_i,
  output logic [4:0]             q_level_o,
  input  logic                   ev_valid_i,
  input  vio_ev_t                ev_i,
  output logic                   ev_ready_o,
  output logic [4:0]             ev_level_o    // entries in use, as the host sees them
);
  // ---- the access on the device bus ----
  wire [1:0]  slot = req_i.addr[13:12];
  wire [11:0] off  = req_i.addr[11:0];
  wire        lreg = off[11:3] == 9'h00C;           // 0x060 InterruptStatus, 0x064 InterruptACK
  wire        wide = req_i.size == 2'd3;
  wire        fwd  = en_i && !lreg && !wide;

  // the written value from bit 0 (accesses are naturally aligned, at most 32 bits)
  wire [31:0] w32  = req_i.addr[2] ? req_i.wdata[63:32] : req_i.wdata[31:0];
  wire [15:0] w16  = off[1] ? w32[31:16] : w32[15:0];
  wire [7:0]  w8   = off[0] ? w16[15:8] : w16[7:0];
  wire [31:0] wval = (req_i.size == 2'd2) ? w32 : (req_i.size == 2'd1) ? {16'd0, w16} : {24'd0, w8};

  // ---- queues ----
  vio_req_t ent_q;                                  // the access, kept for the queue and the read's answer
  logic     pend_q;                                 // ent_q waits for room in the request queue
  logic     rdw_q;                                  // a forwarded read waits for the host's value
  logic     q_in_ready;
  logic     evc_v;
  vio_ev_t  evc;
  logic [4:0] q_wr_level, ev_rd_level;

  tg_afifo #(.W ($bits(vio_req_t)), .DEPTH (16), .MEM ("distributed")) u_req (
    .wr_clk (clk), .wr_rst (rst), .in_valid (pend_q && en_i), .in_ready (q_in_ready), .in_data (ent_q),
    .wr_level (q_wr_level),
    .rd_clk (clk_host), .out_valid (q_valid_o), .out_ready (q_pop_i), .out_data (q_head_o), .rd_level (q_level_o)
  );
  tg_afifo #(.W ($bits(vio_ev_t)), .DEPTH (16), .MEM ("distributed")) u_ev (
    .wr_clk (clk_host), .wr_rst (rst_host), .in_valid (ev_valid_i), .in_ready (ev_ready_o), .in_data (ev_i),
    .wr_level (ev_level_o),
    .rd_clk (clk), .out_valid (evc_v), .out_ready (1'b1), .out_data (evc), .rd_level (ev_rd_level)
  );
  wire ev_val = evc_v && !evc.irq;
  wire ev_irq = evc_v && evc.irq;

  // ---- status bits: a set from the host wins over a clear in the same cycle ----
  logic [2*VIO_SLOTS-1:0] stat_q, ack_clr, ev_set, ev_clr;
  always_comb begin
    ack_clr = '0;
    if (req_valid_i && req_i.we && lreg && off[2] && off[1:0] == 2'b00 && !wide)
      ack_clr[2*slot +: 2] = wval[1:0];
    ev_set = ev_irq ? evc.data[2*VIO_SLOTS-1:0] : '0;
    ev_clr = ev_irq ? evc.data[8 +: 2*VIO_SLOTS] : '0;
  end

  // InterruptStatus as a read value from bit 0: the slot's bits in byte 0 of 0x060
  logic [1:0] st_slot;
  always_comb st_slot = stat_q[2*slot +: 2];
  wire [31:0] lval = (!off[2] && off[1:0] == 2'b00) ? {30'd0, st_slot} : 32'd0;

  // a value from bit 0 in every lane of its size, so the requester finds it at its own address
  function automatic logic [63:0] lanes(input logic [31:0] v, input logic [1:0] size);
    return (size == 2'd2) ? {2{v}} : (size == 2'd1) ? {4{v[15:0]}} : {8{v[7:0]}};
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      pend_q <= 1'b0;
      rdw_q  <= 1'b0;
      stat_q <= '0;
    end else begin
      if (req_valid_i && fwd)              pend_q <= 1'b1;
      else if (q_in_ready || !en_i)        pend_q <= 1'b0;
      if (pend_q && q_in_ready && en_i && !ent_q.we) rdw_q <= 1'b1;
      else if (ev_val || !en_i)            rdw_q <= 1'b0;
      stat_q <= (stat_q & ~(ack_clr | ev_clr)) | ev_set;
    end
    if (req_valid_i) begin
      ent_q.slot  <= slot;
      ent_q.off   <= off;
      ent_q.size  <= req_i.size;
      ent_q.we    <= req_i.we;
      ent_q.wdata <= req_i.we ? wval : 32'd0;
      rsp_o.rdata <= (lreg && !req_i.we && !wide) ? lanes(lval, req_i.size) : 64'd0;
      rsp_o.err   <= wide;
    end else if (rdw_q && ev_val) begin
      rsp_o.rdata <= lanes(evc.data, ent_q.size);
    end
  end

  assign wait_o    = pend_q || rdw_q;
  assign stat_o    = stat_q;
  assign rd_wait_o = rdw_q;
  always_comb for (int s = 0; s < VIO_SLOTS; s++) irq_o[s] = |stat_q[2*s +: 2];

  wire unused = ^{req_i.addr[PA_W-1:14], req_i.be, evc.data[31:16], q_wr_level, ev_rd_level};
endmodule
