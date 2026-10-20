// The commit trace straight from tanager_soc's trace ports, for long lockstep boots (docs/spec/verification.md
// §4.7). Not product RTL. Every core's commit records and writebacks, taken where the uncore's trace stream
// takes them, written to +tap_out=FILE as the stream's 64-byte records (tg_trace_stream's pack_rec and pack_wb,
// the 32-bit cycle stamp in bits 351:320, the rest zero), so tanager-lockstep reads them as it reads the
// board's ring. Unlike tb_boot's +trace_out, the stream stays off and nothing holds the cores back: the stream's
// one AXI writer, a 64-byte burst per record, caps a traced run near IPC 0.15. Per cycle: core 0's retire lanes
// in slot order, then its writeback lanes, then core 1's.
module tg_soc_tap
  import tg_pkg::*, tg_trace_pkg::*;
#(
  parameter int N_CORES = 1
) (
  input  logic                                      clk,
  input  logic                                      rst,
  input  tr_rec_t [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace,
  input  logic    [N_CORES-1:0][COMMIT_WIDTH-1:0]   trace_v,
  input  tr_wb_t  [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb,
  input  logic    [N_CORES-1:0][TRACE_WB_PORTS-1:0] trace_wb_v
);

  // As tg_trace_stream packs them (docs/spec/host.md §Trace ring): a change there must come here too, and the
  // tap's check against the stream (verification.md §4.7) shows it
  function automatic logic [319:0] pack_rec(input tr_rec_t r);
    logic [319:0] x;
    x = '0;
    x[1:0]     = r.kind;
    x[3:2]     = 2'(r.hart);
    x[5:4]     = r.priv;
    x[6]       = r.rvc;
    x[7]       = r.rd_we;
    x[8]       = r.rd_fp;
    x[13:9]    = r.rd;
    x[14]      = r.rd_deferred;
    x[19:15]   = 5'(r.wb_tag);
    x[20]      = r.mem_st;
    x[22:21]   = r.mem_size;
    x[23]      = r.mmio_ld;
    x[24]      = r.nondet;
    x[25]      = r.mem_ld;
    x[63:32]   = r.insn;
    x[127:64]  = r.pc;
    x[191:128] = (r.kind == TR_RETIRE) ? r.rd_value : r.cause;
    x[255:192] = (r.kind == TR_TRAP) ? r.tval : r.mem_vaddr;
    x[319:256] = r.mem_wdata;
    return x;
  endfunction

  function automatic logic [319:0] pack_wb(input tr_wb_t w);
    logic [319:0] x;
    x = '0;
    x[1:0]     = 2'd3;
    x[3:2]     = 2'(w.hart);
    x[8]       = w.rd_fp;
    x[13:9]    = w.rd;
    x[19:15]   = 5'(w.wb_tag);
    x[191:128] = w.value;
    return x;
  endfunction

  int              fd = 0;
  logic [31:0]     cyc;          // the stream's stamp: clk cycles since the uncore's reset
  longint unsigned n_rec, n_wb;

  initial begin
    string path;
    if ($value$plusargs("tap_out=%s", path)) begin
      // DR-146: without the commit trace there is nothing to tap
      if (!COMMIT_TRACE)
        $fatal(1, "tg_soc_tap: this SoC was built with TG_COMMIT_TRACE=0 (DR-146): it has no commit trace to tap");
      if ($test$plusargs("trace_out="))
        $fatal(1, "tg_soc_tap: +tap_out and +trace_out together: the stream's back-pressure would slow the tapped run");
      fd = $fopen(path, "wb");
      if (fd == 0) $fatal(1, "tg_soc_tap: cannot open %s", path);
    end
  end

  always @(posedge clk) begin
    int unsigned nr, nw;
    nr = 0;
    nw = 0;
    if (rst) begin
      cyc   <= '0;
      n_rec <= 0;
      n_wb  <= 0;
    end else begin
      cyc <= cyc + 1'b1;
      if (fd != 0)
        for (int c = 0; c < N_CORES; c++) begin
          for (int k = 0; k < COMMIT_WIDTH; k++)
            if (trace_v[c][k]) begin
              $fwrite(fd, "%u", {160'd0, cyc, pack_rec(trace[c][k])});   // 64 bytes, little-endian as in DDR
              nr++;
            end
          for (int p = 0; p < TRACE_WB_PORTS; p++)
            if (trace_wb_v[c][p]) begin
              $fwrite(fd, "%u", {160'd0, cyc, pack_wb(trace_wb[c][p])});
              nw++;
            end
        end
      n_rec <= n_rec + longint'(nr);
      n_wb  <= n_wb + longint'(nw);
    end
  end

  final if (fd != 0) begin
    $fclose(fd);
    $display("tg_soc_tap: %0d records and %0d writebacks written", n_rec, n_wb);
  end
endmodule
