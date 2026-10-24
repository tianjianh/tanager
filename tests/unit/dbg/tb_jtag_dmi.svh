// A debugger over JTAG for the debug module's benches (docs/spec/soc.md §9.6), included inside a testbench module:
// tests/unit/dbg's tb_dbg and tests/unit/boot's tb_boot. The module declares jtck, jtms, jtdi (driven here) and jtdo
// (tb_jtag_tap's TDO). The sequences follow the Debug Specification 1.0 and OpenOCD's documented flow: the request,
// then a nop whose capture returns its result; on busy, dmireset and both again with more Run-Test/Idle cycles.

localparam logic [5:0] JTAG_IR_IDCODE = 6'h09, JTAG_IR_USER3 = 6'h22, JTAG_IR_USER4 = 6'h23;
localparam logic [6:0] DM_DATA0 = 7'h04, DM_DATA1 = 7'h05, DM_DMCONTROL = 7'h10, DM_DMSTATUS = 7'h11, DM_HARTINFO = 7'h12,
                       DM_ABSTRACTCS = 7'h16, DM_COMMAND = 7'h17, DM_ABSTRACTAUTO = 7'h18, DM_PROGBUF0 = 7'h20,
                       DM_PROGBUF1 = 7'h21, DM_HALTSUM0 = 7'h40;
localparam logic [31:0] RV_NOP = 32'h0000_0013;

int dbg_errors = 0;
task automatic dbg_check(input bit ok, input string what);
  if (!ok) begin
    dbg_errors++;
    $display("FAIL: %s", what);
  end
endtask

// ---- the JTAG driver: TMS and TDI change while TCK is low, TDO is read just before it rises ----
int tck_half = 25;                            // ns
bit at_upd = 1'b0;                            // waiting in Update-DR (its action comes with the next edge)
task automatic jclk(input bit m, input bit di, output bit dout);
  jtms = m;
  jtdi = di;
  #(tck_half);
  dout = jtdo;
  jtck = 1'b1;
  #(tck_half);
  jtck = 1'b0;
endtask
task automatic jreset();
  bit dummy;
  repeat (6) jclk(1'b1, 1'b0, dummy);
  jclk(1'b0, 1'b0, dummy);                    // Run-Test/Idle
  at_upd = 1'b0;
endtask
task automatic jrti(input int idle);          // to Run-Test/Idle (the update edge), then idle more cycles there
  bit dummy;
  if (at_upd) jclk(1'b0, 1'b0, dummy);
  at_upd = 1'b0;
  repeat (idle) jclk(1'b0, 1'b0, dummy);
endtask
task automatic jir(input logic [5:0] v);
  bit dummy;
  jrti(0);
  jclk(1'b1, 1'b0, dummy);                    // Select-DR
  jclk(1'b1, 1'b0, dummy);                    // Select-IR
  jclk(1'b0, 1'b0, dummy);                    // Capture-IR
  jclk(1'b0, 1'b0, dummy);                    // Shift-IR
  for (int k = 0; k < 6; k++) jclk(k == 5, v[k], dummy);
  jclk(1'b1, 1'b0, dummy);                    // Update-IR
  jclk(1'b0, 1'b0, dummy);                    // Run-Test/Idle
endtask
// A DR scan from Run-Test/Idle or Update-DR, ending in Update-DR
task automatic jdr(input int n, input logic [63:0] vin, output logic [63:0] vout);
  bit b, dummy;
  vout = '0;
  jclk(1'b1, 1'b0, dummy);                    // Select-DR (from Update-DR: the last scan's update)
  at_upd = 1'b0;
  jclk(1'b0, 1'b0, dummy);                    // Capture-DR
  jclk(1'b0, 1'b0, dummy);                    // the capture, into Shift-DR
  for (int k = 0; k < n; k++) begin
    jclk(k == n - 1, vin[k], b);
    vout[k] = b;
  end
  jclk(1'b1, 1'b0, dummy);                    // Update-DR
  at_upd = 1'b1;
endtask

// ---- DMI over JTAG (USER4 selected) ----
int dmi_idle = 2;                             // Run-Test/Idle cycles after a dmi scan (dtmcs.idle - 1)
int busy_seen = 0;
task automatic dmi_scan(input logic [1:0] op, input logic [6:0] addr, input logic [31:0] data,
                        output logic [1:0] rop, output logic [31:0] rdata);
  logic [63:0] o;
  jdr(41, {23'd0, addr, data, op}, o);
  if (dmi_idle >= 0) jrti(dmi_idle);
  rop   = o[1:0];
  rdata = o[33:2];
endtask
task automatic dtmcs_scan(input logic [31:0] v, output logic [31:0] r);
  logic [63:0] o;
  jir(JTAG_IR_USER3);
  jdr(32, 64'(v), o);
  jrti(0);
  jir(JTAG_IR_USER4);
  r = o[31:0];
endtask
task automatic dmi(input logic [1:0] op, input logic [6:0] addr, input logic [31:0] data, output logic [31:0] rdata);
  logic [1:0]  rop;
  logic [31:0] rd, cs;
  for (int tries = 0; tries < 20; tries++) begin
    dmi_scan(op, addr, data, rop, rd);
    dmi_scan(2'd0, 7'd0, 32'd0, rop, rd);
    if (rop == 2'd0) begin
      rdata = rd;
      return;
    end
    dbg_check(rop == 2'd3, $sformatf("dmi status %0d", rop));
    busy_seen++;
    dmi_idle = dmi_idle < 0 ? 0 : dmi_idle + 1;   // more Run-Test/Idle, as OpenOCD does
    dtmcs_scan(32'h0001_0000, cs);            // dmireset
  end
  dbg_check(0, "dmi: busy for 20 tries");
endtask
task automatic dmi_wr(input logic [6:0] addr, input logic [31:0] data);
  logic [31:0] unused_rd;
  dmi(2'd2, addr, data, unused_rd);
endtask
task automatic dmi_rd(input logic [6:0] addr, output logic [31:0] data);
  dmi(2'd1, addr, 32'd0, data);
endtask

// ---- DM helpers ----
function automatic logic [31:0] ctl(input int h, input bit haltreq_b = 0, input bit resume = 0, input bit ackhr = 0,
                                    input bit ndm = 0);
  return {haltreq_b, resume, 1'b0, ackhr, 2'b00, 10'(h), 10'd0, 4'd0, ndm, 1'b1};
endfunction
function automatic logic [31:0] ar_cmd(input int r, input bit wr, input bit xfer, input bit post, input int sz = 3);
  return {8'd0, 1'b0, 3'(sz), 1'b0, post, xfer, wr, 16'h1000 + 16'(r)};
endfunction
task automatic cmd_wait(output logic [2:0] err);
  logic [31:0] cs;
  for (int k = 0; k < 200; k++) begin
    dmi_rd(DM_ABSTRACTCS, cs);
    if (!cs[12]) begin
      err = cs[10:8];
      return;
    end
  end
  dbg_check(0, "abstract command never finished");
  err = 3'd7;
endtask
task automatic cmd(input logic [31:0] c, output logic [2:0] err);
  dmi_wr(DM_COMMAND, c);
  cmd_wait(err);
endtask
task automatic clr_cmderr();
  dmi_wr(DM_ABSTRACTCS, 32'h0000_0700);
endtask
task automatic reg_rd(input int r, output logic [63:0] v, input int sz = 3);
  logic [2:0]  err;
  logic [31:0] lo, hi;
  cmd(ar_cmd(r, 1'b0, 1'b1, 1'b0, sz), err);
  dbg_check(err == 3'd0, $sformatf("read x%0d: cmderr %0d", r, err));
  dmi_rd(DM_DATA0, lo);
  dmi_rd(DM_DATA1, hi);
  v = sz == 3 ? {hi, lo} : {32'd0, lo};
endtask
task automatic reg_wr(input int r, input logic [63:0] v, input int sz = 3);
  logic [2:0] err;
  dmi_wr(DM_DATA0, v[31:0]);
  dmi_wr(DM_DATA1, v[63:32]);
  cmd(ar_cmd(r, 1'b1, 1'b1, 1'b0, sz), err);
  dbg_check(err == 3'd0, $sformatf("write x%0d: cmderr %0d", r, err));
endtask
task automatic progbuf(input logic [31:0] i0, input logic [31:0] i1, output logic [2:0] err);
  dmi_wr(DM_PROGBUF0, i0);
  dmi_wr(DM_PROGBUF1, i1);
  cmd(ar_cmd(0, 1'b0, 1'b0, 1'b1), err);
endtask
task automatic dm_status(output logic [31:0] s);
  dmi_rd(DM_DMSTATUS, s);
endtask
task automatic wait_halted(input int h, input int tries = 100);
  logic [31:0] s;
  for (int k = 0; k < tries; k++) begin
    dm_status(s);
    if (s[9]) return;
  end
  dbg_check(0, $sformatf("hart %0d never halted", h));
endtask
// A CSR through the program buffer, as OpenOCD reads one: s0 saved, csrr s0, s0 read, s0 restored
task automatic csr_rd(input logic [11:0] n, output logic [63:0] v);
  logic [63:0] s0;
  logic [2:0]  err;
  reg_rd(8, s0);
  progbuf({n, 5'd0, 3'b010, 5'd8, 7'b1110011}, RV_NOP, err);
  dbg_check(err == 3'd0, $sformatf("csrr s0, 0x%03h: cmderr %0d", n, err));
  reg_rd(8, v);
  reg_wr(8, s0);
endtask
// One instruction through the program buffer with s0 = a: ld s0, 0(s0); a's doubleword back
task automatic mem_rd(input logic [63:0] a, output logic [63:0] v, output logic [2:0] err);
  logic [63:0] s0;
  reg_rd(8, s0);
  reg_wr(8, a);
  progbuf(32'h0004_3403, RV_NOP, err);
  if (err == 3'd0) reg_rd(8, v);
  else clr_cmderr();
  reg_wr(8, s0);
endtask
