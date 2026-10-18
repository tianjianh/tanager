// Device bus (docs/spec/uncore.md): turns single-beat TL-UL accesses (size <= 3) into one register
// access at a time on the devices of the plan §5.4 map. Devices answer in the cycle after req_valid,
// or later: a device holds its wait_i bit high from that cycle on, and the bus takes its response
// in the first cycle with the bit low (the forwarded virtio window, which waits for the host, and the PS
// window, which waits for the PS). Absent devices (virtio unless VIRTIO, debug until M9), sizes above 3
// and misaligned accesses answer denied. The PS window is a region only when it is built (tg_map_pkg
// PS_WINDOW), so its addresses reach this bus only then.
module tg_tl_dev
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;
#(
  parameter bit VIRTIO = 1'b0             // the virtio slots are a device (tg_uncore VIRTIO_WINDOW)
) (
  input  logic                 clk,
  input  logic                 rst,
  input  tl_a_t                a_i,
  input  logic                 a_valid_i,
  output logic                 a_ready_o,
  output tl_d_t                d_o,
  output logic                 d_valid_o,
  input  logic                 d_ready_i,
  // Devices: 0 ACLINT, 1 PLIC, 2 UART, 3 host control, 4 the virtio window, 5 the PS window
  output dev_req_t             req_o,
  output logic [DEV_N-1:0]     req_valid_o,
  input  dev_rsp_t [DEV_N-1:0] rsp_i,
  input  logic [DEV_N-1:0]     wait_i
);
  typedef enum logic [1:0] { S_IDLE, S_REQ, S_WAIT, S_RESP } state_e;
  state_e            st_q;
  dev_req_t          req_q;
  logic [DEV_W-1:0]  dev_q;
  logic              err_q, get_q;
  logic [TL_SIZE_W-1:0] size_q;
  logic [TL_SRC_W-1:0]  src_q;
  logic [63:0]       rdata_q;
  logic              denied_q;

  function automatic logic [DEV_W:0] dev_of(input paddr_t a);   // DEV_N = none
    if (a >= ACLINT_BASE  && a - ACLINT_BASE  < ACLINT_SIZE)  return (DEV_W+1)'(DEV_ACLINT);
    if (a >= PLIC_BASE    && a - PLIC_BASE    < PLIC_SIZE)    return (DEV_W+1)'(DEV_PLIC);
    if (a >= UART_BASE    && a - UART_BASE    < UART_SIZE)    return (DEV_W+1)'(DEV_UART);
    if (a >= HOSTCTL_BASE && a - HOSTCTL_BASE < HOSTCTL_SIZE) return (DEV_W+1)'(DEV_HOSTCTL);
    if (VIRTIO && a >= VIRTIO_BASE && a - VIRTIO_BASE < VIRTIO_SIZE) return (DEV_W+1)'(DEV_VIRTIO);
    if (PS_WINDOW && a >= PSWIN_BASE && a - PSWIN_BASE < PSWIN_SIZE) return (DEV_W+1)'(DEV_PSWIN);
    return (DEV_W+1)'(DEV_N);
  endfunction

  wire [DEV_W:0] dev_a  = dev_of(a_i.address);
  wire           is_put = tl_a_has_data(a_i.opcode);
  wire           is_get = a_i.opcode == A_GET;
  wire [2:0]     amask  = (a_i.size == 3'd0) ? 3'b000 : (a_i.size == 3'd1) ? 3'b001 :
                          (a_i.size == 3'd2) ? 3'b011 : 3'b111;
  wire           bad    = (dev_a == (DEV_W+1)'(DEV_N)) || (a_i.size > 3'd3) ||
                          ((a_i.address[2:0] & amask) != 3'b000) || !(is_put || is_get);

  assign a_ready_o = st_q == S_IDLE;
  wire   wait_dev  = !err_q && wait_i[dev_q];

  always_ff @(posedge clk) begin
    if (rst) begin
      st_q <= S_IDLE;
    end else begin
      unique case (st_q)
        S_IDLE: if (a_valid_i) st_q <= S_REQ;
        S_REQ:  st_q <= S_WAIT;
        S_WAIT: if (!wait_dev) st_q <= S_RESP;
        S_RESP: if (d_ready_i) st_q <= S_IDLE;
        default: st_q <= S_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (st_q == S_IDLE && a_valid_i) begin
      req_q.addr  <= a_i.address;
      req_q.we    <= is_put;
      req_q.wdata <= a_i.data[{a_i.address[3], 6'd0} +: 64];
      req_q.be    <= a_i.mask[{a_i.address[3], 3'd0} +: 8];
      req_q.size  <= a_i.size[1:0];
      dev_q       <= bad ? '0 : dev_a[DEV_W-1:0];
      err_q       <= bad;
      get_q       <= is_get;
      size_q      <= a_i.size;
      src_q       <= a_i.source;
    end
    if (st_q == S_WAIT && !wait_dev) begin
      rdata_q  <= err_q ? 64'd0 : rsp_i[dev_q].rdata;
      denied_q <= err_q || rsp_i[dev_q].err;
    end
  end

  assign req_o = req_q;
  always_comb begin
    req_valid_o = '0;
    if (st_q == S_REQ && !err_q) req_valid_o[dev_q] = 1'b1;
  end

  always_comb begin
    d_o         = '0;
    d_o.opcode  = get_q ? D_ACCESS_ACK_DATA : D_ACCESS_ACK;
    d_o.size    = size_q;
    d_o.source  = src_q;
    d_o.denied  = denied_q;
    d_o.corrupt = denied_q && get_q;
    d_o.data    = {rdata_q, rdata_q};
  end
  assign d_valid_o = st_q == S_RESP;

  wire unused = ^{a_i.param, a_i.corrupt};
endmodule
