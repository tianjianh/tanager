// Commit-trace ring test (docs/spec/host.md §Trace ring): random retire and writeback records on
// two cores, capture of the selected one, read-back of the kept records against a model, the lost
// counter, and the pc trigger.
module tb_trace;
  import tg_pkg::*, tg_trace_pkg::*;

  localparam int NC = 2;
  localparam int CW = COMMIT_WIDTH;
  localparam int BD = 64;                         // small banks for the test
  localparam int DEPTH = BD * CW;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;

  tr_rec_t [NC-1:0][CW-1:0]             tr;
  logic    [NC-1:0][CW-1:0]             trv;
  tr_wb_t  [NC-1:0][TRACE_WB_PORTS-1:0] wb;
  logic    [NC-1:0][TRACE_WB_PORTS-1:0] wbv;
  logic        en, arm, frozen;
  logic [1:0]  csel;
  logic [63:0] tpc;
  logic [15:0] post, ridx, ridx_o;
  logic [31:0] count, lost;
  logic [319:0] rec;

  tg_trace_ring #(.N_CORES (NC), .BANK_DEPTH (BD)) dut (
    .clk, .rst, .trace_i (tr), .trace_valid_i (trv), .trace_wb_i (wb), .trace_wb_valid_i (wbv),
    .enable_i (en), .core_sel_i (csel), .trig_arm_i (arm), .trig_pc_i (tpc), .post_i (post), .rd_idx_i (ridx),
    .count_o (count), .lost_o (lost), .frozen_o (frozen), .rd_idx_o (ridx_o), .rd_rec_o (rec)
  );

  int errors = 0;
  logic [63:0] kept_pc [$];        // model: pc (or wb value) of every kept record, in order
  int          kept_kind [$];
  int          exp_lost;
  bit          capturing;

  task automatic fail(input string m);
    errors++;
    $display("[%0t] ERROR: %s", $time, m);
  endtask

  task automatic drive(input int cycles, input bit stop_model_at_trigger, input logic [63:0] trig, input int post_n);
    int left;
    bit seen;
    left = -1;
    seen = 0;
    for (int c = 0; c < cycles; c++) begin
      @(negedge clk);
      tr = '0; trv = '0; wb = '0; wbv = '0;
      for (int core = 0; core < NC; core++) begin
        int nr, nw;
        nr = int'($urandom_range(CW));
        nw = ($urandom_range(9) == 0) ? 1 : 0;
        for (int k = 0; k < nr; k++) begin
          trv[core][k] = 1'b1;
          tr[core][k].kind = TR_RETIRE;
          tr[core][k].pc   = {32'(core), 32'($urandom())} & ~64'h1;
          tr[core][k].insn = $urandom();
          tr[core][k].rd_value = {$urandom(), $urandom()};
        end
        for (int k = 0; k < nw; k++) begin
          wbv[core][k] = 1'b1;
          wb[core][k].value = {32'hB0B0_0000 | 32'(core), $urandom()};
        end
        if (core == 0 && capturing && !(stop_model_at_trigger && left == 0)) begin
          int n;
          n = 0;
          for (int k = 0; k < nr; k++) if (n < CW) begin
            kept_pc.push_back(tr[core][k].pc); kept_kind.push_back(0); n++;
            if (stop_model_at_trigger && !seen && tr[core][k].pc == trig) begin seen = 1; left = post_n; end
            else if (seen && left > 0) left--;
          end
          for (int k = 0; k < nw; k++) begin
            if (n < CW) begin
              kept_pc.push_back(wb[core][k].value); kept_kind.push_back(3); n++;
              if (seen && left > 0) left--;
            end else exp_lost++;
          end
        end
      end
    end
    @(negedge clk);
    trv = '0; wbv = '0;
  endtask

  task automatic read_rec(input int idx, output logic [319:0] r);
    @(negedge clk) ridx = 16'(idx);
    do @(posedge clk); while (ridx_o != 16'(idx));
    @(posedge clk);
    r = rec;
  endtask

  task automatic check_ring(input string what);
    int n, first;
    logic [319:0] r;
    n = kept_pc.size();
    if (count != 32'(n)) fail($sformatf("%s: count %0d, model %0d", what, count, n));
    if (lost != 32'(exp_lost)) fail($sformatf("%s: lost %0d, model %0d", what, lost, exp_lost));
    first = (n > DEPTH) ? n - DEPTH : 0;
    for (int i = first; i < n; i++) begin
      read_rec(i % DEPTH, r);
      if (r[1:0] != 2'(kept_kind[i])) begin fail($sformatf("%s: record %0d kind %0d, model %0d", what, i, r[1:0], kept_kind[i])); break; end
      if (kept_kind[i] == 0 && r[127:64] != kept_pc[i]) begin fail($sformatf("%s: record %0d pc %h, model %h", what, i, r[127:64], kept_pc[i])); break; end
      if (kept_kind[i] == 3 && r[191:128] != kept_pc[i]) begin fail($sformatf("%s: record %0d wb value", what, i)); break; end
    end
  endtask

  initial begin
    tr = '0; trv = '0; wb = '0; wbv = '0; en = 0; arm = 0; csel = 0; tpc = '0; post = '0; ridx = '0;
    exp_lost = 0; capturing = 0;
    repeat (4) @(posedge clk);
    rst = 0;
    // free-running capture, longer than the ring
    @(negedge clk) begin en = 1; capturing = 1; end
    @(negedge clk);
    drive(500, 0, '0, 0);
    capturing = 0;
    @(negedge clk) en = 0;
    repeat (3) @(posedge clk);
    check_ring("free-running");
    $display("free-running: %0d records, %0d lost", count, lost);
    // trigger: stop 10 records after a known pc
    kept_pc.delete(); kept_kind.delete(); exp_lost = 0;
    tpc = 64'h8000_1234;                       // random pcs never equal it (bit 0 differs? no: forced below)
    @(negedge clk) begin en = 1; arm = 1; post = 16'd10; end
    @(negedge clk);
    capturing = 1;
    drive(20, 0, '0, 0);
    begin
      int k;
      logic [319:0] r;
      k = kept_pc.size();                      // index the trigger record will take
      @(negedge clk);
      tr = '0; trv = '0; wb = '0; wbv = '0;
      trv[0][0] = 1'b1; tr[0][0].kind = TR_RETIRE; tr[0][0].pc = 64'h8000_1234;
      @(negedge clk);
      trv = '0;
      capturing = 0;
      drive(100, 0, '0, 0);
      repeat (3) @(posedge clk);
      if (!frozen) fail("trigger did not freeze the ring");
      if (count < 32'(k + 1 + 10) || count > 32'(k + 1 + 10 + CW - 1))
        fail($sformatf("trigger: %0d records kept, want %0d..%0d", count, k + 11, k + 10 + CW));
      read_rec(k % DEPTH, r);
      if (r[127:64] != 64'h8000_1234) fail($sformatf("trigger record at %0d has pc %h", k, r[127:64]));
      $display("trigger: frozen after %0d records (trigger at %0d)", count, k);
    end
    @(negedge clk) begin en = 0; arm = 0; end
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
endmodule
