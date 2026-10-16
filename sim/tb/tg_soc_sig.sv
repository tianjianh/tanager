// Cycle signatures of tanager_soc for the cycle-identical check (docs/spec/verification.md §4.5).
// tools/ci/cycle_identical.py compiles this module and tg_soc_sig_bind.sv into a SoC testbench (the
// Linux boot's tb_boot), so the testbench does not change. Nothing happens without a plusarg:
//   +sig=FILE [+sig_window=N]      one line per N core cycles (1,024): the commit trace's records,
//                                  writebacks and hash, as tg_vsim --sig writes them (sim/src/sig.h);
//                                  then the SoC's memory-side events and hash, and its host-side
//                                  events and hash
//   +sig_log=FILE +sig_log_from=C  every event from core cycle C on, one line each
//   +sig_stop=C                    end the run ($finish) at core cycle C
// The hashes take, leaving out fields without meaning as sim/src/sig.h does:
//   - each commit record and writeback, with its cycle, core and slot or port;
//   - each beat the SoC drives on its memory and trace AXI ports (AR, AW, and W with only the bytes
//     its strobes enable), and its R and B ready in cycles when a beat is offered; status_o changes;
//   - on the host clock, the AXI4-Lite port's ready while a request is offered, its responses, and
//     host_irq_o changes.
// Cycles count from the release of rst: core cycles, and host cycles for the host side.
// A monitor, never synthesized: its counters update in place, and its state starts initialized.
/* verilator lint_off BLKSEQ */
/* verilator lint_off PROCASSINIT */
module tg_soc_sig
  import tg_pkg::*, tg_trace_pkg::*, tg_uncore_pkg::*;
#(
  parameter int N_CORES = 1
) (
  input logic                                      clk,
  input logic                                      rst,
  input logic                                      clk_host,
  input logic                                      rst_host,
  input tr_rec_t [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace,
  input logic    [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace_v,
  input tr_wb_t  [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb,
  input logic    [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_v,
  input axi_ax_t [N_BANKS-1:0]                     ar,
  input logic    [N_BANKS-1:0]                     ar_v,
  input axi_ax_t [N_BANKS-1:0]                     aw,
  input logic    [N_BANKS-1:0]                     aw_v,
  input axi_w_t  [N_BANKS-1:0]                     w,
  input logic    [N_BANKS-1:0]                     w_v,
  input logic    [N_BANKS-1:0]                     r_v,
  input logic    [N_BANKS-1:0]                     r_rdy,
  input logic    [N_BANKS-1:0]                     b_v,
  input logic    [N_BANKS-1:0]                     b_rdy,
  input axi_ax_t                                   taw,
  input logic                                      taw_v,
  input axi_w_t                                    tw,
  input logic                                      tw_v,
  input logic                                      tb_v,
  input logic                                      tb_rdy,
  input logic                                      h_awvalid,
  input logic                                      h_awready,
  input logic                                      h_wvalid,
  input logic                                      h_wready,
  input logic                                      h_bvalid,
  input logic [1:0]                                h_bresp,
  input logic                                      h_arvalid,
  input logic                                      h_arready,
  input logic                                      h_rvalid,
  input logic [31:0]                               h_rdata,
  input logic [1:0]                                h_rresp,
  input logic                                      host_irq,
  input logic [7:0]                                status
);
  localparam int AXB = $bits(axi_ax_t);
  localparam int WB  = $bits(axi_w_t);

  int              fd = 0, lfd = 0;
  longint unsigned window = 1024, log_from = 0, stop = 0;
  longint unsigned cyc = 0, hcyc = 0, last_end = 0, total_recs = 0;
  logic [63:0]     h_tr = '0, h_mem = '0, h_host = '0;
  longint unsigned n_rec = 0, n_wb = 0, n_mem = 0, n_host = 0;
  logic [7:0]      status_q = '0;
  logic            irq_q = 1'b0;
  bit              lg = 1'b0;

  initial begin
    string path;
    if ($value$plusargs("sig=%s", path)) begin
      // DR-146: the signature hashes the commit trace; a model without it would sign nothing.
      if (!COMMIT_TRACE)
        $fatal(1, "tg_soc_sig: this SoC was built with TG_COMMIT_TRACE=0 (DR-146): it has no commit trace to sign; build it with the trace on");
      fd = $fopen(path, "w");
      if (fd == 0) $fatal(1, "tg_soc_sig: cannot open %s", path);
      if ($value$plusargs("sig_window=%d", window) && window == 0) window = 1;
      $fwrite(fd, "# tanager_soc cycle signature v1, %0d-cycle windows: end cycle, records, writebacks, trace hash, memory-side events, hash, host-side events, hash\n",
              window);
    end
    if ($value$plusargs("sig_log=%s", path)) begin
      lfd = $fopen(path, "w");
      if (lfd == 0) $fatal(1, "tg_soc_sig: cannot open %s", path);
      void'($value$plusargs("sig_log_from=%d", log_from));
    end
    void'($value$plusargs("sig_stop=%d", stop));
  end

  // The hash step of sim/src/sig.h
  function automatic logic [63:0] mix(input logic [63:0] h, input logic [63:0] x);
    logic [63:0] y;
    y = (h ^ x) * 64'hff51_afd7_ed55_8ccd;
    return y ^ (y >> 32);
  endfunction

  function automatic logic [63:0] size_mask(input logic [1:0] s);
    return (s == 2'd3) ? '1 : (64'd1 << (8 << s)) - 64'd1;
  endfunction

  function automatic string kind_s(input tr_kind_e k);
    return (k == TR_RETIRE) ? "retire" : (k == TR_TRAP) ? "trap  " : (k == TR_IRQ) ? "irq   " : "?     ";
  endfunction

  function automatic void rec(input int c, input int k, input tr_rec_t r);
    logic [63:0] h;
    string s;
    h = mix(h_tr, {8'h72, 8'(c), 8'(k), 8'(r.kind), 8'(r.priv), 24'd0});
    h = mix(h, 64'(cyc));
    h = mix(h, 64'(r.hart));
    h = mix(h, r.pc);
    if (r.kind != TR_IRQ) h = mix(h, {31'd0, r.rvc, r.rvc ? {16'd0, r.insn[15:0]} : r.insn});
    if (r.kind == TR_RETIRE) begin
      h = mix(h, {60'd0, r.rd_we, r.mem_st, r.mmio_ld, r.nondet});
      if (r.rd_we) begin
        h = mix(h, {23'd0, r.rd_fp, 7'd0, r.rd_deferred, 27'd0, r.rd});
        h = mix(h, r.rd_deferred ? 64'(r.wb_tag) : r.rd_value);
      end
      if (r.mem_st) begin
        h = mix(h, r.mem_vaddr);
        h = mix(h, r.mem_wdata & size_mask(r.mem_size));
        h = mix(h, 64'(r.mem_size));
      end
    end else begin
      h = mix(h, r.cause);
      if (r.kind == TR_TRAP) h = mix(h, r.tval);
    end
    h_tr = h;
    n_rec++;
    total_recs++;
    if (lg) begin
      s = $sformatf("%10d c%0d s%0d h%0d p%0d %s pc=%016h", cyc, c, k, r.hart, r.priv, kind_s(r.kind), r.pc);
      if (r.kind != TR_IRQ) s = {s, r.rvc ? $sformatf(" (%04h)    ", r.insn[15:0]) : $sformatf(" (%08h)", r.insn)};
      if (r.kind == TR_RETIRE) begin
        if (r.rd_we) s = {s, $sformatf(" %s%0d <- ", r.rd_fp ? "f" : "x", r.rd),
                          r.rd_deferred ? $sformatf("(wb tag %0d)", r.wb_tag) : $sformatf("%016h", r.rd_value)};
        if (r.mem_st) s = {s, $sformatf(" mem[%016h]/%0d <- %016h", r.mem_vaddr, 1 << r.mem_size,
                                        r.mem_wdata & size_mask(r.mem_size))};
        if (r.mmio_ld) s = {s, " mmio"};
        if (r.nondet) s = {s, " nondet"};
      end else begin
        s = {s, $sformatf(" cause=%016h", r.cause)};
        if (r.kind == TR_TRAP) s = {s, $sformatf(" tval=%016h", r.tval)};
      end
      $fwrite(lfd, "%s\n", s);
    end
  endfunction

  function automatic void wbk(input int c, input int p, input tr_wb_t x);
    logic [63:0] h;
    h = mix(h_tr, {8'h77, 8'(c), 8'(p), 7'd0, x.rd_fp, 27'd0, x.rd});
    h = mix(h, 64'(cyc));
    h = mix(h, {32'(x.hart), 32'(x.wb_tag)});
    h_tr = mix(h, x.value);
    n_wb++;
    if (lg) $fwrite(lfd, "%10d c%0d h%0d wb     tag %0d %s%0d <- %016h (port %0d)\n", cyc, c, x.hart, x.wb_tag,
                    x.rd_fp ? "f" : "x", x.rd, x.value, p);
  endfunction

  // One memory-side event: `id` names the port and channel, `v` its fields, the low `bits` bits.
  function automatic void mem_ev(input int id, input logic [255:0] v, input int bits, input string text);
    logic [63:0] h;
    h = mix(h_mem, 64'(cyc));
    h = mix(h, 64'(id));
    for (int i = 0; i < bits; i += 64) h = mix(h, v[i +: 64]);
    h_mem = h;
    n_mem++;
    if (lg) $fwrite(lfd, "%10d %s\n", cyc, text);
  endfunction

  function automatic string ax_s(input axi_ax_t a);
    return $sformatf("id=%0h addr=%0h len=%0d size=%0d burst=%0d", a.id, a.addr, a.len, a.size, a.burst);
  endfunction

  // A W beat: only the bytes its strobes enable
  function automatic axi_w_t w_masked(input axi_w_t x);
    axi_w_t m;
    m = x;
    for (int i = 0; i < AXI_STRB_W; i++) if (!x.strb[i]) m.data[8*i +: 8] = '0;
    return m;
  endfunction

  function automatic void w_ev(input int id, input string port, input axi_w_t x);
    axi_w_t m;
    m = w_masked(x);
    mem_ev(id, 256'(m), WB, $sformatf("%s W data=%0h strb=%0h%s", port, m.data, m.strb, m.last ? " last" : ""));
  endfunction

  function automatic void line(input longint unsigned e);
    $fwrite(fd, "%0d %0d %0d %016h %0d %016h %0d %016h\n", e, n_rec, n_wb, h_tr, n_mem, h_mem, n_host, h_host);
    h_tr = '0; h_mem = '0; h_host = '0;
    n_rec = 0; n_wb = 0; n_mem = 0; n_host = 0;
    last_end = e;
  endfunction

  always @(posedge clk) if (!rst && (fd != 0 || lfd != 0)) begin
    lg = lfd != 0 && cyc >= log_from;
    for (int c = 0; c < N_CORES; c++) begin
      for (int k = 0; k < COMMIT_WIDTH; k++) if (trace_v[c][k]) rec(c, k, trace[c][k]);
      for (int p = 0; p < TRACE_WB_PORTS; p++) if (trace_wb_v[c][p]) wbk(c, p, trace_wb[c][p]);
    end
    for (int k = 0; k < N_BANKS; k++) begin
      if (ar_v[k]) mem_ev(16 + k, 256'(ar[k]), AXB, $sformatf("mem%0d AR %s", k, ax_s(ar[k])));
      if (aw_v[k]) mem_ev(32 + k, 256'(aw[k]), AXB, $sformatf("mem%0d AW %s", k, ax_s(aw[k])));
      if (w_v[k]) w_ev(48 + k, $sformatf("mem%0d", k), w[k]);
      if (r_v[k]) mem_ev(64 + k, 256'(r_rdy[k]), 1, $sformatf("mem%0d R %s", k, r_rdy[k] ? "taken" : "refused"));
      if (b_v[k]) mem_ev(80 + k, 256'(b_rdy[k]), 1, $sformatf("mem%0d B %s", k, b_rdy[k] ? "taken" : "refused"));
    end
    if (taw_v) mem_ev(96, 256'(taw), AXB, $sformatf("trace AW %s", ax_s(taw)));
    if (tw_v) w_ev(97, "trace", tw);
    if (tb_v) mem_ev(98, 256'(tb_rdy), 1, $sformatf("trace B %s", tb_rdy ? "taken" : "refused"));
    if (status != status_q) mem_ev(99, 256'(status), 8, $sformatf("status %02h", status));
    status_q <= status;
    cyc++;
    if (fd != 0 && cyc % window == 0) line(cyc);
    if (stop != 0 && cyc >= stop) $finish;
  end

  function automatic void host_ev(input int id, input logic [63:0] v, input string text);
    h_host = mix(mix(mix(h_host, 64'(hcyc)), 64'(id)), v);
    n_host++;
    if (lfd != 0 && cyc >= log_from) $fwrite(lfd, "%10d host %s (host cycle %0d)\n", cyc, text, hcyc);
  endfunction

  always @(posedge clk_host) if (!rst_host && (fd != 0 || lfd != 0)) begin
    if (h_awvalid) host_ev(1, 64'(h_awready), $sformatf("AW %s", h_awready ? "taken" : "refused"));
    if (h_wvalid) host_ev(2, 64'(h_wready), $sformatf("W %s", h_wready ? "taken" : "refused"));
    if (h_bvalid) host_ev(3, 64'(h_bresp), $sformatf("B resp=%0d", h_bresp));
    if (h_arvalid) host_ev(4, 64'(h_arready), $sformatf("AR %s", h_arready ? "taken" : "refused"));
    if (h_rvalid) host_ev(5, {30'd0, h_rresp, h_rdata}, $sformatf("R resp=%0d data=%08h", h_rresp, h_rdata));
    if (host_irq != irq_q) host_ev(6, 64'(host_irq), $sformatf("irq %0d", host_irq));
    irq_q <= host_irq;
    hcyc++;
  end

  final begin
    if (fd != 0) begin
      if (cyc > last_end) line(cyc);
      $fwrite(fd, "end cycles=%0d records=%0d host_cycles=%0d status=RAN\n", cyc, total_recs, hcyc);
      $fclose(fd);
    end
    if (lfd != 0) $fclose(lfd);
  end
endmodule
