// MMIO peripheral tests through the device bus (docs/spec/uncore-periph.md, uncore.md):
// tg_tl_dev with tg_aclint, tg_plic, tg_uart and a stub host-control register; tg_bootrom directly.
// Directed checks per device plus a random PLIC test against a reference model. VIRTIO = 1 (make
// ... VIRTIO=1) adds a stub device at the virtio slots that holds the bus's wait for 0-40 cycles at
// random, the forwarded window's case, checked against a reference memory. REL = 1 (make ... REL=1) builds the
// PLIC as release builds do (DR-180: S_ONLY, PRIO_W = 1): the model keeps the M contexts empty and one bit of
// each priority and threshold, and directed checks find an M context's registers and claim reading 0.
module tb_periph #(parameter bit VIRTIO = 1'b0, parameter bit REL = 1'b0);
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*, tg_bootrom_img_pkg::*;

  localparam int NH = 4;                 // harts
  localparam int unsigned CLK_HZ = 100_000_000;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;
  longint unsigned cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ---- Device bus and devices ----
  tl_a_t a; logic a_v, a_r;
  tl_d_t d; logic d_v, d_r;
  dev_req_t req; logic [DEV_N-1:0] req_v, dwait; dev_rsp_t [DEV_N-1:0] rsp;

  tg_tl_dev #(.VIRTIO (VIRTIO)) u_dev (.clk, .rst, .a_i (a), .a_valid_i (a_v), .a_ready_o (a_r), .d_o (d),
                   .d_valid_o (d_v), .d_ready_i (d_r), .req_o (req), .req_valid_o (req_v), .rsp_i (rsp),
                   .wait_i (dwait));

  logic [NH-1:0] msi, mti;
  logic [63:0] mtime;
  logic        freeze = 1'b0;
  tg_aclint #(.N_HARTS (NH), .CLK_HZ (CLK_HZ)) u_aclint (
    .clk, .rst, .req_i (req), .req_valid_i (req_v[DEV_ACLINT]), .rsp_o (rsp[DEV_ACLINT]),
    .irq_msi_o (msi), .irq_mti_o (mti), .mtime_o (mtime), .freeze_i (freeze));

  logic [31:0] src;
  logic [2*NH-1:0] eip;
  localparam logic [31:0] EDGE = 32'h00FF_0000;    // sources 16..23 edge-triggered
  tg_plic #(.N_SRC (32), .N_CTX (2 * NH), .PRIO_W (REL ? 1 : 3), .EDGE_SRC (EDGE), .S_ONLY (REL)) u_plic (
    .clk, .rst, .req_i (req), .req_valid_i (req_v[DEV_PLIC]), .rsp_o (rsp[DEV_PLIC]), .src_i (src), .irq_o (eip));

  logic uirq, tx_v, tx_r, rx_v, rx_r;
  logic [7:0] tx_b, rx_b;
  tg_uart #(.CLK_HZ (CLK_HZ)) u_uart (
    .clk, .rst, .req_i (req), .req_valid_i (req_v[DEV_UART]), .rsp_o (rsp[DEV_UART]), .irq_o (uirq),
    .tx_valid_o (tx_v), .tx_ready_i (tx_r), .tx_byte_o (tx_b), .rx_valid_i (rx_v), .rx_ready_o (rx_r), .rx_byte_i (rx_b),
    .div_o (), .line_busy_i (1'b0));

  // stub host control: one 64-bit scratch register at offset 0x30, everything else 0
  logic [63:0] hc_scratch;
  always_ff @(posedge clk) begin
    if (rst) hc_scratch <= '0;
    else if (req_v[DEV_HOSTCTL] && req.we && req.addr[11:3] == 9'h6)
      for (int b = 0; b < 8; b++) if (req.be[b]) hc_scratch[8*b +: 8] <= req.wdata[8*b +: 8];
    rsp[DEV_HOSTCTL].rdata <= (req.addr[11:3] == 9'h6) ? hc_scratch : 64'h0;
    rsp[DEV_HOSTCTL].err   <= 1'b0;
  end

  // stub virtio device: answers after 0-40 cycles of wait at random (often none), from 16 KiB of
  // memory that starts as a pattern of the address and keeps what is written. While it waits its
  // response is garbage and denied, so a response taken early fails the test
  logic [63:0] vio_mem [2048];
  logic [63:0] vio_rd;
  int          vio_wait;
  int          vio_waits = 0;
  initial for (int i = 0; i < 2048; i++) vio_mem[i] = {32'(i) ^ 32'hA5A5_0000, 32'(i) ^ 32'h5A5A_0000};
  always_ff @(posedge clk) begin
    if (rst) begin
      vio_wait <= 0;
    end else if (req_v[DEV_VIRTIO]) begin
      vio_wait <= ($urandom_range(2) == 0) ? 0 : $urandom_range(40);
      if (req.we)
        for (int b = 0; b < 8; b++) if (req.be[b]) vio_mem[req.addr[13:3]][8*b +: 8] <= req.wdata[8*b +: 8];
      vio_rd <= vio_mem[req.addr[13:3]];
    end else if (vio_wait != 0) begin
      vio_wait  <= vio_wait - 1;
      vio_waits <= vio_waits + 1;
    end
  end
  always_comb begin
    dwait                 = '0;
    dwait[DEV_VIRTIO]     = vio_wait != 0;
    rsp[DEV_VIRTIO].rdata = (vio_wait != 0) ? 64'hBAD0_BAD0_BAD0_BAD0 : vio_rd;
    rsp[DEV_VIRTIO].err   = vio_wait != 0;
  end

  // ---- Boot ROM, driven directly ----
  tl_a_t ra; logic ra_v, ra_r;
  tl_d_t rd; logic rd_v, rd_r;
  tg_bootrom u_rom (.clk, .rst, .a_i (ra), .a_valid_i (ra_v), .a_ready_o (ra_r), .d_o (rd), .d_valid_o (rd_v), .d_ready_i (rd_r));

  int errors = 0;
  task automatic fail(input string m);
    errors++;
    $display("[%0d] ERROR: %s", cyc, m);
  endtask

  // ---- TL-UL access through the device bus ----
  task automatic tl(input logic [33:0] addr, input logic [2:0] size, input bit wr, input logic [63:0] wdata,
                    output logic [63:0] rdata, output bit denied);
    logic [15:0] lanes;
    lanes = 16'(((1 << (1 << size)) - 1) << addr[3:0]);
    @(negedge clk);
    a = '0;
    a.opcode  = wr ? A_PUT_FULL : A_GET;
    a.size    = size;
    a.source  = 10'h203;
    a.address = addr;
    a.mask    = lanes;
    a.data    = {wdata, wdata} << (8 * {addr[3], 3'b000});
    if (size < 3) a.data = {2{wdata}} << (8 * addr[3:0]);
    a_v = 1'b1;
    do @(posedge clk); while (!a_r);
    @(negedge clk) a_v = 1'b0;
    d_r = 1'b1;
    do @(posedge clk); while (!d_v);
    rdata  = d.data[64*addr[3] +: 64];
    denied = d.denied;
    if (d.opcode != (wr ? D_ACCESS_ACK : D_ACCESS_ACK_DATA)) fail("device bus: wrong D opcode");
    if (d.source != 10'h203) fail("device bus: wrong D source");
    @(negedge clk) d_r = 1'b0;
  endtask

  function automatic logic [63:0] lane(input logic [63:0] v, input logic [2:0] off, input logic [2:0] size);
    logic [63:0] m;
    m = (size >= 3) ? '1 : ((64'd1 << (8 << size)) - 1);
    return (v >> (8 * off)) & m;
  endfunction

  task automatic rd32(input logic [33:0] addr, output logic [31:0] v);
    logic [63:0] r; bit den;
    tl(addr, 3'd2, 0, '0, r, den);
    v = 32'(lane(r, addr[2:0], 3'd2));
    if (den) fail($sformatf("rd32 %h denied", addr));
  endtask
  task automatic wr32(input logic [33:0] addr, input logic [31:0] v);
    logic [63:0] r; bit den;
    tl(addr, 3'd2, 1, {v, v}, r, den);
    if (den) fail($sformatf("wr32 %h denied", addr));
  endtask
  task automatic rd8(input logic [33:0] addr, output logic [7:0] v);
    logic [63:0] r; bit den;
    tl(addr, 3'd0, 0, '0, r, den);
    v = 8'(lane(r, addr[2:0], 3'd0));
  endtask
  task automatic wr8(input logic [33:0] addr, input logic [7:0] v);
    logic [63:0] r; bit den;
    tl(addr, 3'd0, 1, {8{v}}, r, den);
  endtask
  task automatic rd64(input logic [33:0] addr, output logic [63:0] v);
    bit den;
    tl(addr, 3'd3, 0, '0, v, den);
    if (den) fail($sformatf("rd64 %h denied", addr));
  endtask
  task automatic wr64(input logic [33:0] addr, input logic [63:0] v);
    logic [63:0] r; bit den;
    tl(addr, 3'd3, 1, v, r, den);
    if (den) fail($sformatf("wr64 %h denied", addr));
  endtask

  // ---- UART host side: collect TX bytes, feed RX bytes ----
  logic [7:0] txq[$], rxq[$];
  bit tx_hold;
  always @(posedge clk) begin
    if (tx_v && tx_r) txq.push_back(tx_b);
    if (rx_v && rx_r) void'(rxq.pop_front());
    tx_r <= !tx_hold && ($urandom_range(99) < 70);
    rx_v <= rxq.size() > 0;
    rx_b <= (rxq.size() > 0) ? rxq[0] : 8'h00;
  end

  // =================================================================================================
  task automatic test_bus();
    logic [63:0] r; bit den;
    tl(34'h1001_0000, 3'd2, 0, '0, r, den);                 // virtio window: absent unless VIRTIO
    if (den != !VIRTIO) fail(VIRTIO ? "virtio stub denied" : "absent device not denied");
    tl(34'h1100_0000, 3'd3, 0, '0, r, den);                 // debug window: absent until M9
    if (!den) fail("debug window not denied");
    tl(34'h0200_0002, 3'd2, 0, '0, r, den);                 // misaligned word
    if (!den) fail("misaligned access not denied");
    wr64(34'h1000_1030, 64'h0123_4567_89AB_CDEF);
    rd64(34'h1000_1030, r);
    if (r != 64'h0123_4567_89AB_CDEF) fail("host-control scratch through the device bus");
    begin
      logic [31:0] w;
      rd32(34'h1000_1034, w);
      if (w != 32'h0123_4567) fail("upper word lane");
    end
    $display("device bus: ok");
  endtask

  // The virtio stub through the device bus: random sizes, offsets and waits against a reference copy
  // of its memory, the response taken only once the wait drops
  task automatic test_wait();
    logic [63:0] ref_mem [2048];
    logic [63:0] r, v;
    logic [33:0] addr;
    logic [2:0]  size;
    bit          den, wr;
    for (int i = 0; i < 2048; i++) ref_mem[i] = {32'(i) ^ 32'hA5A5_0000, 32'(i) ^ 32'h5A5A_0000};
    for (int n = 0; n < 600; n++) begin
      size = 3'($urandom_range(3));
      addr = VIRTIO_BASE + 34'($urandom_range(16383) & ~((1 << size) - 1));
      wr   = $urandom_range(1);
      v    = {$urandom, $urandom};
      tl(addr, size, wr, v, r, den);
      if (den) fail($sformatf("virtio stub %h denied", addr));
      if (wr) begin
        for (int b = 0; b < (1 << size); b++)
          ref_mem[addr[13:3]][8*(addr[2:0] + b) +: 8] = v[8*b +: 8];
      end else if (lane(r, addr[2:0], size) != lane(ref_mem[addr[13:3]], addr[2:0], size)) begin
        fail($sformatf("virtio stub read %h size %0d: %h, want %h", addr, size, lane(r, addr[2:0], size),
                       lane(ref_mem[addr[13:3]], addr[2:0], size)));
      end
    end
    if (vio_waits < 1000) fail($sformatf("only %0d cycles of wait", vio_waits));
    $display("device bus wait: ok (%0d cycles held)", vio_waits);
  endtask

  task automatic test_aclint();
    logic [63:0] t0, t1, v;
    logic [31:0] w;
    // tick rate: exactly CLK_HZ / TIMEBASE_HZ = 10 cycles per tick
    rd64(ACLINT_BASE + 34'hBFF8, t0);
    repeat (10000) @(posedge clk);
    rd64(ACLINT_BASE + 34'hBFF8, t1);
    if (t1 - t0 < 999 || t1 - t0 > 1002) fail($sformatf("mtime advanced %0d in 10000 cycles (want ~1000)", t1 - t0));
    // mtimecmp reset value and per-hart compare
    for (int h = 0; h < NH; h++) begin
      rd64(ACLINT_BASE + 34'h4000 + 8 * h, v);
      if (v != '1) fail($sformatf("mtimecmp[%0d] reset %h", h, v));
    end
    if (mti != '0) fail("mti set at reset");
    wr64(ACLINT_BASE + 34'hBFF8, 64'd1000);                 // write mtime
    rd64(ACLINT_BASE + 34'hBFF8, v);
    if (v < 1000 || v > 1003) fail("mtime write");
    wr64(ACLINT_BASE + 34'h4000 + 8 * 2, 64'd1100);        // hart 2 fires ~100 ticks later
    repeat (500) @(posedge clk);
    if (mti[2]) fail("mti[2] early");
    repeat (700) @(posedge clk);
    if (!mti[2] || mti[0] || mti[1] || mti[3]) fail($sformatf("mti %b after compare (want 0100)", mti));
    // 32-bit halves of mtimecmp
    wr32(ACLINT_BASE + 34'h4000 + 8 * 2 + 4, 32'hFFFF_FFFF);
    @(posedge clk); @(posedge clk);
    if (mti[2]) fail("mti[2] not cleared by a higher mtimecmp");
    rd32(ACLINT_BASE + 34'h4000 + 8 * 2, w);
    if (w != 32'd1100) fail("mtimecmp low half");
    // msip bits: harts 1 and 3
    wr32(ACLINT_BASE + 34'h4, 32'h1);
    wr32(ACLINT_BASE + 34'hC, 32'h1);
    if (msi != 4'b1010) fail($sformatf("msi %b (want 1010)", msi));
    rd32(ACLINT_BASE + 34'h4, w);
    if (w != 32'h1) fail("msip read");
    wr32(ACLINT_BASE + 34'h4, 32'h0);
    if (msi != 4'b1000) fail("msip clear");
    if (mtime != u_aclint.mtime_q) fail("mtime broadcast");
    // freeze_i (tg_uncore: CTRL.TFREEZE while the trace stalls a core) holds mtime; a write still lands,
    // and the rate is the same after
    rd64(ACLINT_BASE + 34'hBFF8, t0);
    freeze = 1'b1;
    repeat (5000) @(posedge clk);
    rd64(ACLINT_BASE + 34'hBFF8, t1);
    if (t1 - t0 > 1) fail($sformatf("mtime advanced %0d while frozen", t1 - t0));
    wr64(ACLINT_BASE + 34'hBFF8, 64'd5000);
    repeat (100) @(posedge clk);
    rd64(ACLINT_BASE + 34'hBFF8, v);
    if (v != 64'd5000) fail($sformatf("mtime %0d after a write while frozen (want 5000)", v));
    freeze = 1'b0;
    repeat (10000) @(posedge clk);
    rd64(ACLINT_BASE + 34'hBFF8, t1);
    if (t1 - 64'd5000 < 999 || t1 - 64'd5000 > 1004) fail($sformatf("mtime advanced %0d in 10000 cycles after the freeze", t1 - 64'd5000));
    $display("aclint: ok");
  endtask

  // ---- PLIC reference model ----
  bit [31:0] m_pend, m_busy;
  logic [2:0] m_prio [32];
  bit [31:0] m_en [2*NH];
  logic [2:0] m_thr [2*NH];
  bit [31:0] src_prev;

  // what the PLIC keeps of a priority or threshold written, and whether a context holds anything
  function automatic logic [2:0] pk(input logic [2:0] p); return REL ? (p & 3'd1) : p; endfunction
  function automatic bit live(input int c); return !REL || c % 2 == 1; endfunction

  function automatic int ref_best(input int c);
    int id; logic [2:0] p;
    id = 0; p = m_thr[c];
    for (int s = 31; s >= 1; s--)
      if (m_pend[s] && m_en[c][s] && m_prio[s] > m_thr[c] && m_prio[s] >= p) begin id = s; p = m_prio[s]; end
    return id;
  endfunction

  task automatic plic_settle();
    // the model's gateways, applied for the source values held this many cycles
    @(posedge clk); @(posedge clk);
    for (int s = 1; s < 32; s++) begin
      bit req;
      req = EDGE[s] ? (src[s] && !src_prev[s]) : src[s];
      if (req && !m_busy[s]) m_pend[s] = 1;
    end
    src_prev = src;
    @(posedge clk); @(posedge clk);
  endtask

  task automatic test_plic();
    logic [31:0] w;
    m_pend = 0; m_busy = 0; src_prev = 0;
    for (int s = 0; s < 32; s++) m_prio[s] = 0;
    for (int c = 0; c < 2*NH; c++) begin m_en[c] = 0; m_thr[c] = 0; end
    // directed: priority, enable, claim, complete
    wr32(PLIC_BASE + 4 * 10, 32'd5);    m_prio[10] = pk(5);
    wr32(PLIC_BASE + 34'h2000 + 34'h80 * 3, 32'h400);  m_en[3] = 32'h400;   // context 3 = hart 1 S
    rd32(PLIC_BASE + 4 * 10, w);
    if (w != 32'(pk(5))) fail($sformatf("plic priority readback %0d, want %0d", w, pk(5)));
    src[10] = 1'b1;
    plic_settle();
    if (eip != 8'b0000_1000) fail($sformatf("plic eip %b (want ctx 3)", eip));
    rd32(PLIC_BASE + 34'h1000, w);
    if (!w[10]) fail("plic pending bit");
    rd32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 3 + 4, w);     // claim
    if (w != 10) fail($sformatf("plic claim %0d (want 10)", w));
    m_pend[10] = 0; m_busy[10] = 1;
    @(posedge clk); @(posedge clk);
    if (eip[3]) fail("plic eip after claim");
    src[10] = 1'b0;
    wr32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 3 + 4, 32'd10); // complete
    m_busy[10] = 0;
    plic_settle();
    if (eip != 0) fail("plic eip after complete with the source low");
    // threshold masks
    src[10] = 1'b1;
    wr32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 3, 32'd5);  m_thr[3] = pk(5);
    plic_settle();
    if (eip[3]) fail("plic threshold did not mask");
    wr32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 3, 32'd4);  m_thr[3] = pk(4);
    plic_settle();
    if (!eip[3]) fail("plic threshold 4 masked priority 5");
    rd32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 3 + 4, w);  m_pend[10] = 0; m_busy[10] = 1;
    src[10] = 1'b0;
    wr32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 3 + 4, 32'd10); m_busy[10] = 0;
    plic_settle();
    if (REL) begin
      // a release build's M contexts (here hart 1's, 2) hold nothing: enables and threshold read 0 after writes,
      // and a claim there reads 0 with source 10 pending and enabled on both of hart 1's contexts
      wr32(PLIC_BASE + 34'h2000 + 34'h80 * 2, 32'hFFFF_FFFE);
      wr32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 2, 32'd1);
      rd32(PLIC_BASE + 34'h2000 + 34'h80 * 2, w);
      if (w != 0) fail($sformatf("plic release: context 2's enables read %h", w));
      rd32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 2, w);
      if (w != 0) fail($sformatf("plic release: context 2's threshold reads %0d", w));
      src[10] = 1'b1;
      plic_settle();
      if (eip != 8'b0000_1000) fail($sformatf("plic release: eip %b (want ctx 3 alone)", eip));
      rd32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 2 + 4, w);
      if (w != 0) fail($sformatf("plic release: context 2 claimed %0d", w));
      rd32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 3 + 4, w);  m_pend[10] = 0; m_busy[10] = 1;
      if (w != 10) fail($sformatf("plic release: context 3 claimed %0d (want 10)", w));
      src[10] = 1'b0;
      wr32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 2 + 4, 32'd10);   // a complete through context 2: ignored
      @(posedge clk); @(posedge clk);
      if (!u_plic.busy_q[10]) fail("plic release: a complete through context 2 was taken");
      wr32(PLIC_BASE + 34'h20_0000 + 34'h1000 * 3 + 4, 32'd10); m_busy[10] = 0;
      plic_settle();
      $display("plic: release form (M contexts empty, 1-bit priorities) ok");
    end
    // random: sources toggle, contexts claim and complete, all checked against the model
    for (int it = 0; it < 3000; it++) begin
      int op;
      op = int'($urandom_range(99));
      if (op < 30) begin
        int s;
        s = int'($urandom_range(31, 1));
        src[s] = ~src[s];
        plic_settle();
      end else if (op < 40) begin
        int s; logic [2:0] p;
        s = int'($urandom_range(31, 1)); p = 3'($urandom());
        wr32(PLIC_BASE + 4 * s, 32'(p)); m_prio[s] = pk(p);
      end else if (op < 50) begin
        int c; logic [31:0] e;
        c = int'($urandom_range(2*NH - 1)); e = $urandom() & ~32'h1;
        wr32(PLIC_BASE + 34'h2000 + 34'h80 * c, e); if (live(c)) m_en[c] = e;
      end else if (op < 55) begin
        int c; logic [2:0] t;
        c = int'($urandom_range(2*NH - 1)); t = 3'($urandom_range(3));
        wr32(PLIC_BASE + 34'h20_0000 + 34'h1000 * c, 32'(t)); if (live(c)) m_thr[c] = pk(t);
      end else if (op < 80) begin
        int c, want;
        c = int'($urandom_range(2*NH - 1));
        want = ref_best(c);
        rd32(PLIC_BASE + 34'h20_0000 + 34'h1000 * c + 4, w);
        if (int'(w) != want) fail($sformatf("plic random: ctx %0d claimed %0d, model %0d", c, w, want));
        if (want != 0) begin m_pend[want] = 0; m_busy[want] = 1; end
      end else begin
        int c, s;
        c = int'($urandom_range(2*NH - 1)); s = int'($urandom_range(31, 1));
        wr32(PLIC_BASE + 34'h20_0000 + 34'h1000 * c + 4, 32'(s));
        if (m_en[c][s]) m_busy[s] = 0;
        plic_settle();
      end
      // interrupt outputs follow the model
      @(posedge clk); @(posedge clk);
      for (int c = 0; c < 2*NH; c++)
        if (eip[c] != (ref_best(c) != 0)) begin
          fail($sformatf("plic random: eip[%0d]=%0d, model %0d", c, eip[c], ref_best(c) != 0));
          break;
        end
    end
    $display("plic: ok");
  endtask

  // ---- Directed sequences around claim and complete (the board's lost SD1 interrupt, 10-20; the coordinator's
  // list): a complete where the source is disabled, an enable written or a priority set to 0 while claimed, a
  // complete from another context, and an affinity move. Each against the PLIC spec ("a completion for a source
  // not enabled for the target is silently ignored"), then Linux 6.12.113's plic_irq_eoi (read the context's
  // enable bit; if clear, enable, complete, disable), which must recover every case but the last
  localparam logic [33:0] P_CTX = PLIC_BASE + 34'h20_0000;
  task automatic p_en(input int c, input logic [31:0] e); wr32(PLIC_BASE + 34'h2000 + 34'h80 * c, e); endtask
  task automatic p_rden(input int c, output logic [31:0] e); rd32(PLIC_BASE + 34'h2000 + 34'h80 * c, e); endtask
  task automatic p_claim(input int c, output logic [31:0] id); rd32(P_CTX + 34'h1000 * c + 4, id); endtask
  task automatic p_complete(input int c, input int s); wr32(P_CTX + 34'h1000 * c + 4, 32'(s)); endtask
  task automatic p_wait(); repeat (8) @(posedge clk); endtask
  task automatic linux_eoi(input int c, input int s);
    logic [31:0] e;
    p_rden(c, e);
    if (e[s]) begin
      p_complete(c, s);
    end else begin
      p_en(c, e | (32'h1 << s));
      p_complete(c, s);
      p_rden(c, e);
      p_en(c, e & ~(32'h1 << s));
    end
  endtask
  // A level source, as SD1's 21 is in tanager_soc (this bench makes 16..23 edge-triggered)
  localparam int SEQ_S = 26;
  task automatic seq_expect(input string name, input bit busy, input bit pend, input logic [2*NH-1:0] irq);
    p_wait();
    if (u_plic.busy_q[SEQ_S] != busy || u_plic.pend_q[SEQ_S] != pend || eip != irq)
      fail($sformatf("plic seq %s: busy %0d pending %0d eip %b, want %0d %0d %b", name, u_plic.busy_q[SEQ_S],
                     u_plic.pend_q[SEQ_S], eip, busy, pend, irq));
  endtask
  task automatic test_plic_seq();
    localparam int S = SEQ_S, C = 1, C2 = 3;         // hart 0's and hart 1's S-mode contexts
    localparam logic [2*NH-1:0] NONE = '0, ON_C = (2*NH)'(1) << C, ON_C2 = (2*NH)'(1) << C2;
    logic [31:0] w;
    // a clean slate after the random test: sources low, everything drained and completed, nothing enabled
    src = '0;
    p_wait();
    for (int k = 1; k < 32; k++) wr32(PLIC_BASE + 4 * k, 32'd1);
    for (int c = 0; c < 2*NH; c++) begin wr32(P_CTX + 34'h1000 * c, 32'd0); p_en(c, 32'hFFFF_FFFE); end
    for (int k = 1; k < 32; k++) p_complete(REL ? 1 : 0, k);            // a release build's context 0 holds nothing
    do begin p_claim(REL ? 1 : 0, w); if (w != 0) p_complete(REL ? 1 : 0, int'(w)); end while (w != 0);
    for (int c = 0; c < 2*NH; c++) p_en(c, 32'd0);
    p_wait();
    if (u_plic.pend_q != '0 || u_plic.busy_q != '0) fail("plic seq: no clean slate");
    // S1: claimed, then disabled on its context (plic_irq_disable on another CPU), then Linux's EOI: it finds
    // the bit clear, enables, completes, disables; the source pends again (its line still high), and enable_irq
    // delivers it
    p_en(C, 32'h1 << S); src[S] = 1'b1;
    seq_expect("S1 raised", 0, 1, ON_C);
    p_claim(C, w); if (w != S) fail($sformatf("plic seq S1: claimed %0d", w));
    p_en(C, 32'd0);
    linux_eoi(C, S);
    seq_expect("S1 after the EOI with the source disabled", 0, 1, NONE);
    p_en(C, 32'h1 << S);
    seq_expect("S1 enabled again", 0, 1, ON_C);
    p_claim(C, w); if (w != S) fail($sformatf("plic seq S1: claimed %0d again", w));
    src[S] = 1'b0; p_complete(C, S);
    seq_expect("S1 done", 0, 0, NONE);
    // S1b: the same with a plain complete: the spec ignores it and the source stays claimed (frozen) until a
    // complete arrives where it is enabled
    src[S] = 1'b1;
    seq_expect("S1b raised", 0, 1, ON_C);
    p_claim(C, w);
    p_en(C, 32'd0);
    p_complete(C, S);
    seq_expect("S1b plain complete while disabled (ignored)", 1, 0, NONE);
    p_en(C, 32'h1 << S);
    seq_expect("S1b enabled again: still claimed", 1, 0, NONE);
    linux_eoi(C, S);
    seq_expect("S1b the complete where enabled", 0, 1, ON_C);
    p_claim(C, w); src[S] = 1'b0; p_complete(C, S);
    seq_expect("S1b done", 0, 0, NONE);
    // S2: the enable word rewritten while claimed (another source's request_irq and free_irq)
    src[S] = 1'b1;
    seq_expect("S2 raised", 0, 1, ON_C);
    p_claim(C, w);
    p_en(C, (32'h1 << S) | (32'h1 << 23)); p_en(C, 32'h1 << S);
    linux_eoi(C, S);
    seq_expect("S2 completed", 0, 1, ON_C);
    p_claim(C, w); src[S] = 1'b0; linux_eoi(C, S);
    seq_expect("S2 done", 0, 0, NONE);
    // S3: priority 0 while claimed (mask_irq), completed, unmasked
    src[S] = 1'b1;
    seq_expect("S3 raised", 0, 1, ON_C);
    p_claim(C, w);
    wr32(PLIC_BASE + 4 * S, 32'd0);
    linux_eoi(C, S);
    seq_expect("S3 completed while masked", 0, 1, NONE);
    wr32(PLIC_BASE + 4 * S, 32'd1);
    seq_expect("S3 unmasked", 0, 1, ON_C);
    p_claim(C, w); src[S] = 1'b0; linux_eoi(C, S);
    seq_expect("S3 done", 0, 0, NONE);
    // S4: completed from another context where the source is enabled too: honored
    p_en(C2, 32'h1 << S); src[S] = 1'b1;
    seq_expect("S4 raised", 0, 1, ON_C | ON_C2);
    p_claim(C, w);
    p_complete(C2, S);
    seq_expect("S4 completed from C2", 0, 1, ON_C | ON_C2);
    p_claim(C, w); src[S] = 1'b0; p_complete(C, S); p_en(C2, 32'd0);
    seq_expect("S4 done", 0, 0, NONE);
    // S5: completed from a context where the source is not enabled: ignored, then the right one
    src[S] = 1'b1;
    seq_expect("S5 raised", 0, 1, ON_C);
    p_claim(C, w);
    p_complete(C2, S);
    seq_expect("S5 complete from C2, not enabled there (ignored)", 1, 0, NONE);
    p_complete(C, S);
    seq_expect("S5 completed from C", 0, 1, ON_C);
    p_claim(C, w); src[S] = 1'b0; p_complete(C, S);
    seq_expect("S5 done", 0, 0, NONE);
    // S6: an affinity move while claimed (plic_set_affinity on another CPU: off on C, on on C2), then the old
    // CPU's EOI: it finds the bit clear on C, so it enables, completes, disables; the source goes to C2
    src[S] = 1'b1;
    seq_expect("S6 raised", 0, 1, ON_C);
    p_claim(C, w);
    p_en(C, 32'd0); p_en(C2, 32'h1 << S);
    linux_eoi(C, S);
    seq_expect("S6 moved, completed by the old CPU", 0, 1, ON_C2);
    p_claim(C2, w); if (w != S) fail($sformatf("plic seq S6: C2 claimed %0d", w));
    src[S] = 1'b0; linux_eoi(C2, S); p_en(C2, 32'd0);
    seq_expect("S6 done", 0, 0, NONE);
    // S7: the race 6.12.113 leaves: the EOI reads the bit set, the move clears it, the complete is ignored. The
    // spec freezes the source (claimed, never completed): shown, not fixed, here
    p_en(C, 32'h1 << S); src[S] = 1'b1;
    seq_expect("S7 raised", 0, 1, ON_C);
    p_claim(C, w);
    p_rden(C, w); if (!w[S]) fail("plic seq S7: enable read");
    p_en(C, 32'd0); p_en(C2, 32'h1 << S);
    p_complete(C, S);
    seq_expect("S7 frozen as the spec has it", 1, 0, NONE);
    src[S] = 1'b0; p_wait();
    p_complete(C2, S); p_en(C2, 32'd0);
    seq_expect("S7 cleared", 0, 0, NONE);
    $display("plic sequences: ok");
  endtask

  task automatic test_uart();
    logic [7:0] v;
    localparam logic [33:0] U = UART_BASE;
    // reset values
    rd8(U + 2, v); if (v != 8'h01) fail($sformatf("uart IIR reset %h", v));
    rd8(U + 5, v); if (v != 8'h60) fail($sformatf("uart LSR reset %h", v));
    rd8(U + 3, v); if (v != 8'h00) fail("uart LCR reset");
    // scratch and DLAB banking
    wr8(U + 7, 8'h5A); rd8(U + 7, v); if (v != 8'h5A) fail("uart SCR");
    wr8(U + 3, 8'h83); wr8(U + 0, 8'h34); wr8(U + 1, 8'h12);
    rd8(U + 0, v); if (v != 8'h34) fail("uart DLL");
    rd8(U + 1, v); if (v != 8'h12) fail("uart DLM");
    wr8(U + 0, 8'h02); wr8(U + 1, 8'h00);
    wr8(U + 3, 8'h03);
    rd8(U + 1, v); if (v != 8'h00) fail("uart IER after DLAB");
    // FIFO mode
    wr8(U + 2, 8'hC7);                                   // enable + reset, trigger 14
    rd8(U + 2, v); if (v != 8'hC1) fail($sformatf("uart IIR FIFO mode %h", v));
    // THRE interrupt: ETBEI 0 -> 1 with an empty FIFO raises it; reading IIR clears it
    wr8(U + 1, 8'h02);
    rd8(U + 2, v); if (v != 8'hC2) fail($sformatf("uart THRE on enable: IIR %h", v));
    rd8(U + 2, v); if (v != 8'hC1) fail("uart THRE not cleared by the IIR read");
    // transmit: bytes reach the host stream in order; THRE re-arms when the FIFO drains
    tx_hold = 1;
    for (int i = 0; i < 16; i++) wr8(U + 0, 8'(8'h40 + i));
    rd8(U + 5, v); if (v[5]) fail("uart THRE set with a full FIFO");
    tx_hold = 0;
    repeat (100) @(posedge clk);
    if (txq.size() != 16) fail($sformatf("uart sent %0d bytes, want 16", txq.size()));
    foreach (txq[i]) if (txq[i] != 8'(8'h40 + i)) fail("uart TX order");
    txq.delete();
    if (!uirq) fail("uart irq after TX drained (THRE)");
    rd8(U + 2, v); if (v != 8'hC2) fail($sformatf("uart IIR after drain %h", v));
    wr8(U + 1, 8'h00);
    // receive: below the trigger level only the character timeout raises an interrupt
    wr8(U + 1, 8'h01);
    rxq.push_back(8'hA1); rxq.push_back(8'hB2);
    repeat (20) @(posedge clk);
    rd8(U + 5, v); if (!v[0]) fail("uart DR");
    if (uirq) fail("uart RDA below trigger");
    repeat (36000) @(posedge clk);                        // > 4 characters at divisor 2 (34.7k cycles)
    if (!uirq) fail("uart character timeout");
    rd8(U + 2, v); if (v != 8'hCC) fail($sformatf("uart IIR timeout %h", v));
    rd8(U + 0, v); if (v != 8'hA1) fail("uart RBR 0");
    rd8(U + 0, v); if (v != 8'hB2) fail("uart RBR 1");
    rd8(U + 5, v); if (v[0]) fail("uart DR after drain");
    // trigger level 4: four bytes raise RDA
    wr8(U + 2, 8'h41);
    for (int i = 0; i < 4; i++) rxq.push_back(8'(i));
    repeat (40) @(posedge clk);
    rd8(U + 2, v); if (v != 8'hC4) fail($sformatf("uart IIR RDA %h", v));
    for (int i = 0; i < 4; i++) begin rd8(U + 0, v); if (v != 8'(i)) fail("uart RX order"); end
    wr8(U + 1, 8'h00);
    // loopback: TX bytes come back on RX and do not reach the host
    wr8(U + 4, 8'h10);
    wr8(U + 0, 8'h77);
    repeat (10) @(posedge clk);
    rd8(U + 0, v); if (v != 8'h77) fail("uart loopback");
    if (txq.size() != 0) fail("uart loopback leaked to the host");
    rd8(U + 6, v); if (v[7:4] != 4'b0000) fail("uart MSR in loopback");
    wr8(U + 4, 8'h00);
    rd8(U + 6, v); if (v != 8'hB0) fail($sformatf("uart MSR %h", v));
    // stream 2000 random bytes each way under back-pressure
    begin
      logic [7:0] sent[$];
      for (int i = 0; i < 2000; i++) begin
        logic [7:0] b;
        b = 8'($urandom());
        do rd8(U + 5, v); while (!v[5]);
        wr8(U + 0, b);
        sent.push_back(b);
      end
      repeat (200) @(posedge clk);
      if (txq.size() != 2000) fail($sformatf("uart stream: %0d of 2000 bytes", txq.size()));
      foreach (sent[i]) if (txq[i] != sent[i]) begin fail("uart stream data"); break; end
      txq.delete();
      sent.delete();
      for (int i = 0; i < 300; i++) begin
        logic [7:0] b;
        b = 8'($urandom());
        rxq.push_back(b);
        sent.push_back(b);
      end
      for (int i = 0; i < 300; i++) begin
        do rd8(U + 5, v); while (!v[0]);
        rd8(U + 0, v);
        if (v != sent[i]) begin fail("uart RX stream data"); break; end
      end
    end
    $display("uart: ok");
  endtask

  task automatic test_rom();
    // Gets of every size at random offsets, against the image; Put denied
    for (int it = 0; it < 400; it++) begin
      logic [2:0] sz;
      logic [11:0] off;
      int nb, first;
      sz  = 3'($urandom_range(6));
      off = 12'($urandom_range(4095)) & ~12'((1 << sz) - 1);
      nb  = (sz <= 4) ? 1 : (sz == 5) ? 2 : 4;
      first = int'(off[11:4]) & ~(nb - 1);
      @(negedge clk);
      ra = '0; ra.opcode = A_GET; ra.size = sz; ra.source = 10'h101; ra.address = 34'h1000 + 34'(off);
      ra_v = 1;
      do @(posedge clk); while (!ra_r);
      @(negedge clk) ra_v = 0;
      rd_r = 1;
      for (int k = 0; k < nb; k++) begin
        logic [127:0] want;
        do @(posedge clk); while (!rd_v);
        want = (first + k < BOOTROM_IMG_BEATS) ? BOOTROM_IMG[first + k] : '0;
        if (rd.data != want || rd.opcode != D_ACCESS_ACK_DATA || rd.denied) fail($sformatf("rom Get size %0d off %h beat %0d", sz, off, k));
      end
      @(negedge clk) rd_r = 0;
    end
    @(negedge clk);
    ra = '0; ra.opcode = A_PUT_FULL; ra.size = 3'd2; ra.source = 10'h203; ra.address = 34'h1000;
    ra_v = 1;
    do @(posedge clk); while (!ra_r);
    @(negedge clk) ra_v = 0;
    rd_r = 1;
    do @(posedge clk); while (!rd_v);
    if (!rd.denied || rd.opcode != D_ACCESS_ACK) fail("rom Put not denied");
    @(negedge clk) rd_r = 0;
    $display("bootrom: ok");
  endtask

  int unsigned seed;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    a_v = 0; d_r = 0; ra_v = 0; rd_r = 0; src = 0; tx_hold = 0;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    repeat (2) @(posedge clk);
    test_bus();
    if (VIRTIO) test_wait();
    test_aclint();
    test_plic();
    test_plic_seq();
    test_uart();
    test_rom();
    if (errors == 0) $display("TEST PASSED (seed %0d)", seed);
    else             $display("TEST FAILED (seed %0d): %0d errors", seed, errors);
    $finish;
  end
endmodule
