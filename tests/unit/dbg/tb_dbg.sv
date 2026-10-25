// The debug module from JTAG to the harts (docs/spec/soc.md §9.6): a behavioural TAP with two BSCANE2-style chains,
// tg_dtm, tg_dm and two RV64I hart models (tb_dbg_harts) that run the debug ROM from the window. The sequences are
// written from the Debug Specification 1.0 and OpenOCD's documented flow: dtmcs, DMI reads and writes with the busy
// status, activation, hart discovery, halt, the GPRs by Access Register (32 and 64 bits, s0 and s1 included),
// the program buffer (dpc, memory reads and writes, an exception), cmderr's cases, step, resume, haltsum0,
// havereset, unavail, ndmreset and dmactive.   make -C tests/unit/dbg short
module tb_dbg
  import tg_pkg::*, tg_tl_pkg::*, tg_uncore_pkg::*;
;
  localparam int NH = 2;
  localparam logic [63:0] MEM = 64'h8000_0000;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = !clk;

  // ---- JTAG ----
  logic       jtck = 1'b0, jtms = 1'b1, jtdi = 1'b0;
  logic       jtdo;
  jtag_t      jtag;
  logic [1:0] user_tdo;
  tb_jtag_tap u_tap (.tck (jtck), .tms (jtms), .tdi (jtdi), .tdo (jtdo), .jtag_o (jtag), .user_tdo_i (user_tdo));

  logic        dmi_req, dmi_rsp;
  logic [6:0]  dmi_addr;
  logic [31:0] dmi_wdata, dmi_rdata;
  logic [1:0]  dmi_op, dmi_resp;
  tg_dtm u_dtm (
    .tck (jtck), .jtag_i (jtag), .tdo_o (user_tdo),
    .clk, .dmi_req_o (dmi_req), .dmi_addr_o (dmi_addr), .dmi_wdata_o (dmi_wdata), .dmi_op_o (dmi_op),
    .dmi_rsp_i (dmi_rsp), .dmi_rdata_i (dmi_rdata), .dmi_resp_i (dmi_resp)
  );

  tl_a_t a; logic av, ar;
  tl_d_t d; logic dv, dr;
  logic [NH-1:0] haltreq, unavail = '0;
  logic          hart_rst = 1'b1, ndmreset;
  tg_dm #(.NH (NH)) u_dm (
    .clk, .rst, .bus_rst (rst),
    .dmi_req_i (dmi_req), .dmi_addr_i (dmi_addr), .dmi_wdata_i (dmi_wdata), .dmi_op_i (dmi_op),
    .dmi_rsp_o (dmi_rsp), .dmi_rdata_o (dmi_rdata), .dmi_resp_o (dmi_resp),
    .a_i (a), .a_valid_i (av), .a_ready_o (ar), .d_o (d), .d_valid_o (dv), .d_ready_i (dr),
    .haltreq_o (haltreq), .unavail_i (unavail), .hart_rst_i (hart_rst), .ndmreset_o (ndmreset)
  );
  tb_dbg_harts #(.NH (NH)) u_harts (
    .clk, .rst, .haltreq_i (haltreq), .hart_rst_i ({NH{hart_rst}}),
    .a_o (a), .a_valid_o (av), .a_ready_i (ar), .d_i (d), .d_valid_i (dv), .d_ready_o (dr)
  );

  // the debugger over JTAG (tb_jtag_dmi.svh: the driver, DMI with OpenOCD's busy handling, the DM's helpers)
  `include "tb_jtag_dmi.svh"
  task automatic check(input bit ok, input string what);
    dbg_check(ok, what);
  endtask

  // A halted hart's GPR as the debugger sees it: the ROM keeps s0 and s1 in dscratch0 and dscratch1
  function automatic logic [63:0] gpr(input int h, input int r);
    return r == 8 ? u_harts.dscratch0[h] : r == 9 ? u_harts.dscratch1[h] : u_harts.x[h][r];
  endfunction

  // ---- the sequences ----
  logic [63:0] o, v, v2, dpc0;
  logic [31:0] r, s, cs;
  logic [2:0]  err;
  int          ret0, n_busy;

  initial begin
    repeat (20) @(posedge clk);
    rst = 1'b0;
    repeat (10) @(posedge clk);
    hart_rst = 1'b0;

    // The TAP: IDCODE after reset; dtmcs
    jreset();
    jdr(32, '0, o);
    jrti(0);
    check(o[31:0] == 32'h1474_6093, "IDCODE after Test-Logic-Reset");
    dtmcs_scan('0, r);
    check(r[3:0] == 4'd1 && r[9:4] == 6'd7 && r[14:12] == 3'd3 && r[11:10] == 2'd0 && r[20:18] == 3'd0,
          $sformatf("dtmcs %h: version 1, abits 7, idle 3, dmistat 0, errinfo 0", r));

    // Activation: dmactive takes the write; other bits ignored while inactive
    dmi_rd(DM_DMCONTROL, r);
    check(r == 32'd0, $sformatf("dmcontrol at reset %h", r));
    dmi_wr(DM_DMCONTROL, 32'h8000_0003);           // haltreq, ndmreset with dmactive: only dmactive applies
    dmi_rd(DM_DMCONTROL, r);
    check(r == 32'h0000_0001, $sformatf("dmcontrol after activation %h", r));
    check(haltreq == '0 && !ndmreset, "nothing but dmactive while inactive");

    // dmstatus, hartinfo, abstractcs
    dm_status(s);
    check(s[3:0] == 4'd3 && s[7] && s[22] && !s[23] && !s[5], $sformatf("dmstatus %h: version 3, authenticated, impebreak", s));
    check(s[11] && s[10] && !s[9] && !s[15] && !s[13], "hart 0 running");
    check(s[19] && s[18], "hart 0 havereset after the reset");
    dmi_wr(DM_DMCONTROL, ctl(0, 0, 0, 1));
    dm_status(s);
    check(!s[19] && !s[18], "havereset acknowledged");
    dmi_rd(DM_HARTINFO, r);
    check(r == 32'd0, "hartinfo 0");
    dmi_rd(DM_ABSTRACTCS, r);
    check(r[28:24] == 5'd2 && r[3:0] == 4'd2 && !r[12] && r[10:8] == 3'd0 && !r[11], $sformatf("abstractcs %h", r));

    // Hart discovery: HARTSELLEN from all ones; hart 1 exists, hart 2 does not
    dmi_wr(DM_DMCONTROL, {6'd0, 10'h3FF, 10'h3FF, 6'd1});
    dmi_rd(DM_DMCONTROL, r);
    check(r[25:16] == 10'd1 && r[15:6] == 10'd0, $sformatf("hartsel all ones reads %h (HARTSELLEN 1)", r));
    dm_status(s);
    check(!s[15] && s[11], "hart 1 exists and runs");
    dmi_wr(DM_DMCONTROL, ctl(1, 0, 0, 1));
    unavail[1] = 1'b1;
    dm_status(s);
    check(s[13] && s[12] && !s[11] && !s[9], "hart 1 unavailable");
    unavail[1] = 1'b0;
    dm_status(s);
    check(!s[13] && s[11], "hart 1 available again");

    // Halt hart 0
    ret0 = u_harts.retired[0];
    dmi_wr(DM_DMCONTROL, ctl(0, 1));
    check(haltreq == 2'b01, "haltreq reaches hart 0 alone");
    wait_halted(0);
    dmi_wr(DM_DMCONTROL, ctl(0));
    check(haltreq == 2'b00, "haltreq cleared");
    dm_status(s);
    check(s[9] && s[8] && !s[11] && !s[10], "hart 0 halted, not running");
    check(u_harts.dmode[0] && u_harts.dcsr[0][8:6] == 3'd3, "hart 0 in debug mode, cause 3");
    check(u_harts.retired[0] > ret0, "hart 0 ran before the halt");
    dmi_rd(DM_HALTSUM0, r);
    check(r == 32'd1, $sformatf("haltsum0 %h", r));

    // The GPRs, 64 bits: every one read against the model, then written and read back
    for (int k = 1; k < 32; k++) begin
      reg_rd(k, v);
      check(v == gpr(0, k), $sformatf("x%0d read %h, hart has %h", k, v, gpr(0, k)));
    end
    for (int k = 0; k < 32; k++) begin
      v = {32'hA5A5_0000 | 32'(k), 32'h1234_5600 | 32'(k)};
      reg_wr(k, v);
      check(gpr(0, k) == (k == 0 ? 64'd0 : v), $sformatf("x%0d after the write: %h", k, gpr(0, k)));
      reg_rd(k, v2);
      check(v2 == (k == 0 ? 64'd0 : v), $sformatf("x%0d read back %h", k, v2));
    end
    // 32 bits: arg0 alone; a write sign-extends
    dmi_wr(DM_DATA1, 32'hDEAD_BEEF);
    reg_rd(9, v, 2);
    dmi_rd(DM_DATA1, r);
    v2 = gpr(0, 9);
    check(v[31:0] == v2[31:0] && r == 32'hDEAD_BEEF, "32-bit read of s1: data0 alone");
    reg_wr(18, 64'h0000_0000_8000_0001, 2);
    check(u_harts.x[0][18] == 64'hFFFF_FFFF_8000_0001, "32-bit write sign-extends");

    // The program buffer: dpc into s0, then s0 back
    reg_rd(8, v);
    progbuf(32'h7B10_2473, RV_NOP, err);          // csrr s0, dpc
    check(err == 3'd0, "csrr s0, dpc");
    reg_rd(8, dpc0);
    check(dpc0 == u_harts.dpc[0] && dpc0 >= MEM && dpc0 < MEM + 12, $sformatf("dpc %h", dpc0));
    reg_wr(8, v);
    check(gpr(0, 8) == v, "s0 restored");
    // memory: a doubleword written and read through the program buffer
    reg_wr(8, MEM + 64'h800);
    reg_wr(9, 64'h0123_4567_89AB_CDEF);
    progbuf(32'h0094_3023, RV_NOP, err);          // sd s1, 0(s0)
    check(err == 3'd0 && u_harts.mem[256] == 64'h0123_4567_89AB_CDEF, "sd through the program buffer");
    u_harts.mem[257] = 64'h5555_AAAA_0F0F_F0F0;
    reg_wr(8, MEM + 64'h808);
    progbuf(32'h0004_3403, RV_NOP, err);          // ld s0, 0(s0)
    reg_rd(8, v);
    check(err == 3'd0 && v == 64'h5555_AAAA_0F0F_F0F0, $sformatf("ld through the program buffer: %h", v));
    // postexec after a transfer: write s0 = address, then load it, in one command
    dmi_wr(DM_DATA0, 32'(MEM + 64'h800));
    dmi_wr(DM_DATA1, 32'((MEM + 64'h800) >> 32));
    dmi_wr(DM_PROGBUF0, 32'h0004_3403);
    dmi_wr(DM_PROGBUF1, RV_NOP);
    cmd(ar_cmd(8, 1'b1, 1'b1, 1'b1), err);
    reg_rd(8, v);
    check(err == 3'd0 && v == 64'h0123_4567_89AB_CDEF, "transfer then postexec");
    // an exception in the program buffer: cmderr 3, the hart still halted, nothing else changed
    reg_wr(8, 64'h4000_0000);                   // nothing there
    v2 = u_harts.dpc[0];
    progbuf(32'h0004_3403, RV_NOP, err);
    check(err == 3'd3, $sformatf("exception: cmderr %0d", err));
    check(u_harts.exc_count[0] == 1 && u_harts.dpc[0] == v2 && u_harts.dmode[0], "exception: dpc kept, still in debug mode");
    cmd(ar_cmd(1, 1'b0, 1'b1, 1'b0), err);
    check(err == 3'd3, "no command runs while cmderr is set");
    clr_cmderr();
    reg_rd(8, v);
    check(v == 64'h4000_0000, "s0 kept through the exception");
    dm_status(s);
    check(s[9], "still halted after the exception");
    // an illegal instruction too
    progbuf(32'h0000_0000, RV_NOP, err);
    check(err == 3'd3, "illegal instruction: cmderr 3");
    clr_cmderr();

    // Commands this DM does not run: cmderr 2
    cmd(ar_cmd(0, 1'b0, 1'b1, 1'b0) & ~32'h0000_1000 | 32'h0000_0300, err);   // a CSR (mstatus)
    check(err == 3'd2, "CSR by Access Register: not supported");
    clr_cmderr();
    cmd(32'h0200_0000, err);                    // Access Memory
    check(err == 3'd2, "Access Memory: not supported");
    clr_cmderr();
    cmd(ar_cmd(1, 1'b0, 1'b1, 1'b0) | 32'h0008_0000, err);   // aarpostincrement
    check(err == 3'd2, "aarpostincrement: not supported");
    clr_cmderr();
    cmd(ar_cmd(1, 1'b0, 1'b1, 1'b0, 4), err);   // 128 bits
    check(err == 3'd2, "aarsize 4: not supported");
    clr_cmderr();
    cmd(ar_cmd(1, 1'b0, 1'b0, 1'b0, 4), err);   // no transfer: aarsize does not matter
    check(err == 3'd0, "no transfer, no postexec");

    // Busy: data0 written while a long program buffer runs; cmderr 1 and data0 unchanged
    reg_wr(8, 64'd5000);
    dmi_wr(DM_DATA0, 32'h1111_2222);
    dmi_wr(DM_PROGBUF0, 32'hFFF4_0413);            // addi s0, s0, -1
    dmi_wr(DM_PROGBUF1, 32'hFE04_1EE3);            // bnez s0, .-4
    dmi_wr(DM_COMMAND, ar_cmd(0, 1'b0, 1'b0, 1'b1));
    dmi_wr(DM_DATA0, 32'h3333_4444);
    dmi_rd(DM_ABSTRACTCS, r);
    check(r[12], "the loop is still running");
    cmd_wait(err);
    check(err == 3'd1, $sformatf("busy: cmderr %0d", err));
    dmi_rd(DM_DATA0, r);
    check(r == 32'h1111_2222, "data0 unchanged by the write while busy");
    clr_cmderr();
    reg_rd(8, v);
    check(v == 64'd0, "the loop ran to the end");

    // A command to a running hart: cmderr 4
    dmi_wr(DM_DMCONTROL, ctl(1));
    cmd(ar_cmd(1, 1'b0, 1'b1, 1'b0), err);
    check(err == 3'd4, "command to a running hart: cmderr 4");
    clr_cmderr();
    dmi_wr(DM_DMCONTROL, ctl(0));

    // Step: dcsr.step, resume, one instruction, back with cause 4
    progbuf(32'h7B02_6073, RV_NOP, err);           // csrsi dcsr, 4
    check(err == 3'd0, "csrsi dcsr, 4");
    ret0 = u_harts.retired[0];
    v2 = u_harts.dpc[0];
    dmi_wr(DM_DMCONTROL, ctl(0, 0, 1));
    wait_halted(0);
    dm_status(s);
    check(s[17] && s[16], "resumeack after the step");
    check(u_harts.retired[0] == ret0 + 1 && u_harts.dcsr[0][8:6] == 3'd4 && u_harts.dpc[0] != v2,
          $sformatf("one instruction stepped: %0d, cause %0d", u_harts.retired[0] - ret0, u_harts.dcsr[0][8:6]));
    progbuf(32'h7B02_7073, RV_NOP, err);           // csrci dcsr, 4

    // Hart 1 too: haltsum0 with both
    dmi_wr(DM_DMCONTROL, ctl(1, 1));
    wait_halted(1);
    dmi_wr(DM_DMCONTROL, ctl(1));
    dmi_rd(DM_HALTSUM0, r);
    check(r == 32'd3, $sformatf("haltsum0 with both halted %h", r));
    reg_rd(5, v);
    check(v == gpr(1, 5), "hart 1's x5");

    // The busy status: a dmi scan with no Run-Test/Idle at a fast TCK finds the read still on its way
    tck_half = 5;
    dmi_idle = -1;
    n_busy = busy_seen;
    for (int k = 0; k < 4; k++) dmi_rd(DM_DMSTATUS, s);
    check(busy_seen > n_busy, "busy seen with no idle cycles at 100 MHz TCK");
    check(s[9], "dmstatus read through the busy retries");
    begin
      logic [1:0]  rop;
      logic [31:0] rd2;
      dmi_idle = -1;
      dmi_scan(2'd1, DM_DMSTATUS, 32'd0, rop, rd2);
      dmi_scan(2'd1, DM_DMSTATUS, 32'd0, rop, rd2);   // finds the first on its way: busy, sticky
      dmi_scan(2'd0, 7'd0, 32'd0, rop, rd2);
      check(rop == 2'd3, "busy is sticky");
      dtmcs_scan('0, cs);
      check(cs[11:10] == 2'd3, "dtmcs.dmistat shows busy");
      dtmcs_scan(32'h0002_0000, cs);           // dtmhardreset
      dtmcs_scan('0, cs);
      check(cs[11:10] == 2'd0, "dtmhardreset clears it");
      dmi_idle = -1;
      dmi_scan(2'd1, DM_DMSTATUS, 32'd0, rop, rd2);
      dmi_scan(2'd0, 7'd0, 32'd0, rop, rd2);
      check(rop == 2'd3, "busy again");
      jreset();                                 // Test-Logic-Reset clears it too
      jir(JTAG_IR_USER4);
    end
    tck_half = 25;
    dmi_idle = 2;
    dtmcs_scan('0, cs);
    check(cs[11:10] == 2'd0, "Test-Logic-Reset clears the sticky status");

    // Resume both: resumeack, running, the loops go on
    dmi_wr(DM_DMCONTROL, ctl(1, 0, 1));
    dmi_wr(DM_DMCONTROL, ctl(0, 0, 1));
    dm_status(s);
    check(s[17] && s[11] && !s[9], "hart 0 resumed and running");
    ret0 = u_harts.retired[0];
    repeat (200) @(posedge clk);
    check(u_harts.retired[0] > ret0 && !u_harts.dmode[0] && !u_harts.dmode[1], "both harts run again");
    dmi_rd(DM_HALTSUM0, r);
    check(r == 32'd0, "haltsum0 empty");

    // ndmreset drives the reset out; havereset follows the harts' reset
    dmi_wr(DM_DMCONTROL, ctl(0, 0, 0, 0, 1));
    check(ndmreset, "ndmreset out");
    dm_status(s);
    check(s[24], "ndmresetpending");
    hart_rst = 1'b1;
    repeat (5) @(posedge clk);
    dm_status(s);
    check(s[13] && s[19], "harts unavailable and havereset in reset");
    dmi_wr(DM_DMCONTROL, ctl(0));
    check(!ndmreset, "ndmreset released");
    dm_status(s);
    check(s[24], "ndmresetpending while the cores' reset is still held");
    hart_rst = 1'b0;
    dm_status(s);
    check(s[11] && s[19] && !s[24], "running after the reset, havereset still set");
    dmi_wr(DM_DMCONTROL, ctl(0, 0, 0, 1));
    // a reset the host holds is no ndmreset
    hart_rst = 1'b1;
    dm_status(s);
    check(s[13] && !s[24], "the host's reset: unavailable, no ndmresetpending");
    hart_rst = 1'b0;
    dmi_wr(DM_DMCONTROL, ctl(0, 0, 0, 1));

    // dmactive 0: the DM's registers to their reset values, the halt requests dropped
    dmi_wr(DM_PROGBUF0, 32'hCAFE_F00D);
    dmi_wr(DM_DMCONTROL, ctl(1, 1));
    wait_halted(1);
    dmi_wr(DM_DMCONTROL, 32'd0);
    check(haltreq == '0, "dmactive 0 drops the halt requests");
    dmi_wr(DM_DMCONTROL, 32'd1);
    dmi_rd(DM_PROGBUF0, r);
    check(r == 32'd0, "progbuf0 reset by dmactive");
    dmi_wr(DM_DMCONTROL, ctl(1));
    dm_status(s);
    check(s[9], "hart 1 still halted across dmactive");
    dmi_wr(DM_DMCONTROL, ctl(1, 0, 1));
    dm_status(s);
    check(s[17] && s[11], "hart 1 resumed after the DM's reset");

    check(u_harts.bad == 0, $sformatf("the harts saw %0d traps or bad answers", u_harts.bad));
    if (dbg_errors == 0) $display("TEST PASSED (busy retries %0d)", busy_seen);
    else $display("TEST FAILED: %0d errors", dbg_errors);
    $finish;
  end

  initial begin
    #50ms;
    $display("TEST FAILED: timeout");
    $finish;
  end
endmodule
