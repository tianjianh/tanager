// Spike S1 PL design: two DDR traffic/latency engines (tg_s1_engine) on S_AXI_HP1_FPD and
// S_AXI_HP2_FPD, controlled through an AXI4-Lite slave on M_AXI_HPM0_FPD (engine k at byte
// offset k * 0x800, 32-bit registers). One clock (the
// block design's 200 MHz clk_core) for everything. The A53 program is fpga/spikes/s1/sw.
module tg_s1_top #(
  parameter int AW = 49,
  parameter int DW = 128,
  parameter int IW = 6
) (
  input  logic          clk,
  input  logic          rstn,
  // AXI4-Lite slave
  input  logic [11:0]   s_axi_awaddr,
  input  logic          s_axi_awvalid,
  output logic          s_axi_awready,
  input  logic [31:0]   s_axi_wdata,
  input  logic [3:0]    s_axi_wstrb,
  input  logic          s_axi_wvalid,
  output logic          s_axi_wready,
  output logic [1:0]    s_axi_bresp,
  output logic          s_axi_bvalid,
  input  logic          s_axi_bready,
  input  logic [11:0]   s_axi_araddr,
  input  logic          s_axi_arvalid,
  output logic          s_axi_arready,
  output logic [31:0]   s_axi_rdata,
  output logic [1:0]    s_axi_rresp,
  output logic          s_axi_rvalid,
  input  logic          s_axi_rready,
  // AXI4 masters m0 (HP1) and m1 (HP2)
  output logic [IW-1:0] m0_axi_arid,   m1_axi_arid,
  output logic [AW-1:0] m0_axi_araddr, m1_axi_araddr,
  output logic [7:0]    m0_axi_arlen,  m1_axi_arlen,
  output logic [2:0]    m0_axi_arsize, m1_axi_arsize,
  output logic [1:0]    m0_axi_arburst, m1_axi_arburst,
  output logic          m0_axi_arlock, m1_axi_arlock,
  output logic [3:0]    m0_axi_arcache, m1_axi_arcache,
  output logic [2:0]    m0_axi_arprot, m1_axi_arprot,
  output logic [3:0]    m0_axi_arqos,  m1_axi_arqos,
  output logic          m0_axi_arvalid, m1_axi_arvalid,
  input  logic          m0_axi_arready, m1_axi_arready,
  input  logic [IW-1:0] m0_axi_rid,    m1_axi_rid,
  input  logic [DW-1:0] m0_axi_rdata,  m1_axi_rdata,
  input  logic [1:0]    m0_axi_rresp,  m1_axi_rresp,
  input  logic          m0_axi_rlast,  m1_axi_rlast,
  input  logic          m0_axi_rvalid, m1_axi_rvalid,
  output logic          m0_axi_rready, m1_axi_rready,
  output logic [IW-1:0] m0_axi_awid,   m1_axi_awid,
  output logic [AW-1:0] m0_axi_awaddr, m1_axi_awaddr,
  output logic [7:0]    m0_axi_awlen,  m1_axi_awlen,
  output logic [2:0]    m0_axi_awsize, m1_axi_awsize,
  output logic [1:0]    m0_axi_awburst, m1_axi_awburst,
  output logic          m0_axi_awlock, m1_axi_awlock,
  output logic [3:0]    m0_axi_awcache, m1_axi_awcache,
  output logic [2:0]    m0_axi_awprot, m1_axi_awprot,
  output logic [3:0]    m0_axi_awqos,  m1_axi_awqos,
  output logic          m0_axi_awvalid, m1_axi_awvalid,
  input  logic          m0_axi_awready, m1_axi_awready,
  output logic [DW-1:0] m0_axi_wdata,  m1_axi_wdata,
  output logic [DW/8-1:0] m0_axi_wstrb, m1_axi_wstrb,
  output logic          m0_axi_wlast,  m1_axi_wlast,
  output logic          m0_axi_wvalid, m1_axi_wvalid,
  input  logic          m0_axi_wready, m1_axi_wready,
  input  logic [IW-1:0] m0_axi_bid,    m1_axi_bid,
  input  logic [1:0]    m0_axi_bresp,  m1_axi_bresp,
  input  logic          m0_axi_bvalid, m1_axi_bvalid,
  output logic          m0_axi_bready, m1_axi_bready
);
  logic rst;
  always_ff @(posedge clk) rst <= !rstn;

  // ---- AXI4-Lite slave: one access at a time ----
  logic        wr_go, rd_go, rd_pend_q, rd_wait_q;
  logic [11:0] rd_addr_q;
  assign s_axi_awready = !s_axi_bvalid && s_axi_awvalid && s_axi_wvalid;
  assign s_axi_wready  = s_axi_awready;
  assign wr_go = s_axi_awready;
  assign s_axi_bresp = 2'b00;
  assign s_axi_arready = !rd_pend_q && !s_axi_rvalid;
  assign rd_go = s_axi_arvalid && s_axi_arready;
  assign s_axi_rresp = 2'b00;
  always_ff @(posedge clk) begin
    if (rst) begin
      s_axi_bvalid <= 1'b0;
      s_axi_rvalid <= 1'b0;
      rd_pend_q    <= 1'b0;
      rd_wait_q    <= 1'b0;
    end else begin
      if (wr_go) s_axi_bvalid <= 1'b1;
      else if (s_axi_bready) s_axi_bvalid <= 1'b0;
      // read: address cycle, engine register cycle, data
      if (rd_go) begin
        rd_pend_q <= 1'b1;
        rd_addr_q <= s_axi_araddr;
      end
      rd_wait_q <= rd_pend_q && !rd_wait_q && !s_axi_rvalid;
      if (rd_wait_q) begin
        rd_pend_q    <= 1'b0;
        s_axi_rvalid <= 1'b1;
      end else if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
    end
  end

  logic [1:0][31:0] e_rdata;
  logic [1:0]       e_wr, e_rd;
  logic [8:0]       e_addr;
  assign e_addr = wr_go ? s_axi_awaddr[10:2] : rd_addr_q[10:2];
  for (genvar k = 0; k < 2; k++) begin : g_sel
    assign e_wr[k] = wr_go && s_axi_awaddr[11] == k[0] && s_axi_wstrb == 4'hf;
    assign e_rd[k] = rd_pend_q && !rd_wait_q && rd_addr_q[11] == k[0];
  end
  always_ff @(posedge clk) begin
    if (rd_wait_q) s_axi_rdata <= e_rdata[rd_addr_q[11]];
  end

  logic unused;
  assign unused = ^{s_axi_awaddr[1:0], rd_addr_q[1:0]};

  tg_s1_engine #(.AW(AW), .DW(DW), .IW(IW)) u_e0 (
    .clk, .rst, .reg_wr(e_wr[0]), .reg_rd(e_rd[0]), .reg_addr(e_addr), .reg_wdata(s_axi_wdata),
    .reg_rdata(e_rdata[0]),
    .arid(m0_axi_arid), .araddr(m0_axi_araddr), .arlen(m0_axi_arlen), .arsize(m0_axi_arsize),
    .arburst(m0_axi_arburst), .arlock(m0_axi_arlock), .arcache(m0_axi_arcache),
    .arprot(m0_axi_arprot), .arqos(m0_axi_arqos), .arvalid(m0_axi_arvalid),
    .arready(m0_axi_arready), .rid(m0_axi_rid), .rdata(m0_axi_rdata), .rresp(m0_axi_rresp),
    .rlast(m0_axi_rlast), .rvalid(m0_axi_rvalid), .rready(m0_axi_rready),
    .awid(m0_axi_awid), .awaddr(m0_axi_awaddr), .awlen(m0_axi_awlen), .awsize(m0_axi_awsize),
    .awburst(m0_axi_awburst), .awlock(m0_axi_awlock), .awcache(m0_axi_awcache),
    .awprot(m0_axi_awprot), .awqos(m0_axi_awqos), .awvalid(m0_axi_awvalid),
    .awready(m0_axi_awready), .wdata(m0_axi_wdata), .wstrb(m0_axi_wstrb), .wlast(m0_axi_wlast),
    .wvalid(m0_axi_wvalid), .wready(m0_axi_wready), .bid(m0_axi_bid), .bresp(m0_axi_bresp),
    .bvalid(m0_axi_bvalid), .bready(m0_axi_bready));

  tg_s1_engine #(.AW(AW), .DW(DW), .IW(IW)) u_e1 (
    .clk, .rst, .reg_wr(e_wr[1]), .reg_rd(e_rd[1]), .reg_addr(e_addr), .reg_wdata(s_axi_wdata),
    .reg_rdata(e_rdata[1]),
    .arid(m1_axi_arid), .araddr(m1_axi_araddr), .arlen(m1_axi_arlen), .arsize(m1_axi_arsize),
    .arburst(m1_axi_arburst), .arlock(m1_axi_arlock), .arcache(m1_axi_arcache),
    .arprot(m1_axi_arprot), .arqos(m1_axi_arqos), .arvalid(m1_axi_arvalid),
    .arready(m1_axi_arready), .rid(m1_axi_rid), .rdata(m1_axi_rdata), .rresp(m1_axi_rresp),
    .rlast(m1_axi_rlast), .rvalid(m1_axi_rvalid), .rready(m1_axi_rready),
    .awid(m1_axi_awid), .awaddr(m1_axi_awaddr), .awlen(m1_axi_awlen), .awsize(m1_axi_awsize),
    .awburst(m1_axi_awburst), .awlock(m1_axi_awlock), .awcache(m1_axi_awcache),
    .awprot(m1_axi_awprot), .awqos(m1_axi_awqos), .awvalid(m1_axi_awvalid),
    .awready(m1_axi_awready), .wdata(m1_axi_wdata), .wstrb(m1_axi_wstrb), .wlast(m1_axi_wlast),
    .wvalid(m1_axi_wvalid), .wready(m1_axi_wready), .bid(m1_axi_bid), .bresp(m1_axi_bresp),
    .bvalid(m1_axi_bvalid), .bready(m1_axi_bready));
endmodule
