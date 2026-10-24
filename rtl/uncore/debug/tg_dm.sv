// The Debug Module (docs/spec/soc.md §9.3-9.5; RISC-V Debug Specification 1.0, chapter 3). TG_DEBUG builds
// only. Execution-based: a halted hart runs the debug ROM (tg_debugrom_img_pkg, sw/debugrom) from the debug
// window, and an abstract command is a few instructions the DM shows in the window's abstract area.
//   DMI registers: data0-1, dmcontrol, dmstatus, hartinfo (0), abstractcs, command (Access Register to the
//   GPRs, with postexec), progbuf0-1 with an implicit ebreak, haltsum0. Others read 0.
//   The window (DEBUG_BASE, a TL-UL target behind the boot ROM's crossbar port): Gets up to a line, from
//   the I$ and the hart's loads; single-beat Puts, the hart's stores. Offsets:
//     0x000 + 4h  FLAGS of hart h: [0] GO (run the abstract area), [1] RESUME          read
//     0x100 + 4h  HALTED, 0x140 + 4h GOING, 0x180 + 4h RESUMING, 0x1C0 + 4h EXCEPTION   write (any value)
//     0x200, 0x204  data0, data1                                                       read, write
//     0x300  the abstract area (8 words); 0x340 progbuf0, progbuf1, ebreak             fetch
//     0x800  the ROM's entry; 0x808 its exception entry                               fetch
// Harts are indexed by mhartid (hartsel), up to 16. The DM's state resets with rst and while dmactive is 0;
// the harts' halted, havereset and unavail states belong to the harts and survive dmactive. The DMI's
// answers never stop, so the DTM's handshake cannot hang on a reset.
module tg_dm
  import tg_pkg::*, tg_tl_pkg::*, tg_uncore_pkg::*, tg_debugrom_img_pkg::*;
#(
  parameter int NH = 1                          // harts
) (
  input  logic          clk,
  input  logic          rst,                    // the SoC's reset: the DM's own state
  input  logic          bus_rst,                // the uncore's: the window's handshake

  // the DMI, from tg_dtm: one request at a time
  input  logic          dmi_req_i,
  input  logic [6:0]    dmi_addr_i,
  input  logic [31:0]   dmi_wdata_i,
  input  logic [1:0]    dmi_op_i,               // 1 read, 2 write
  output logic          dmi_rsp_o,              // the cycle after the request
  output logic [31:0]   dmi_rdata_o,
  output logic [1:0]    dmi_resp_o,             // 0: every request succeeds

  // the debug window
  input  tl_a_t         a_i,
  input  logic          a_valid_i,
  output logic          a_ready_o,
  output tl_d_t         d_o,
  output logic          d_valid_o,
  input  logic          d_ready_i,

  // the harts
  output logic [NH-1:0] haltreq_o,              // dbg_haltreq: a level per hart, taken at commit
  input  logic [NH-1:0] unavail_i,              // held off (hart_unavail)
  input  logic          hart_rst_i,             // the cores' reset: unavailable, havereset; an ndmreset's end
  output logic          ndmreset_o              // holds the cores and the uncore in reset
);
  localparam int HSW = (NH > 1) ? $clog2(NH) : 1;   // hartsel's width (HARTSELLEN)
  localparam int NHP = 1 << HSW;                     // hart slots; those from NH on do not exist
  localparam logic [NHP-1:0] EXISTS = NHP'((64'd1 << NH) - 64'd1);
  if (NH < 1 || NH > 16) begin : g_bad_nh
    $error("tg_dm: the debug window has room for 1..16 harts");
  end

  localparam logic [31:0] NOP = 32'h0000_0013, EBREAK = 32'h0010_0073;
  localparam logic [11:0] CSR_DSCRATCH0 = 12'h7b2, CSR_DSCRATCH1 = 12'h7b3;
  localparam logic [4:0]  S0 = 5'd8, S1 = 5'd9;
  localparam logic [15:0] W_ABS = 16'h0300, W_PROG = 16'h0340;

  // ---- the abstract area's instructions (s0 holds DEBUG_BASE there; data0 is at 0x200) ----
  function automatic logic [31:0] i_store(input logic [4:0] rs2, input logic d64);   // s{w,d} rs2, 0x200(s0)
    return {7'b0010000, rs2, S0, d64 ? 3'b011 : 3'b010, 5'd0, 7'b0100011};
  endfunction
  function automatic logic [31:0] i_load(input logic [4:0] rd, input logic d64);     // l{w,d} rd, 0x200(s0)
    return {12'h200, S0, d64 ? 3'b011 : 3'b010, rd, 7'b0000011};
  endfunction
  function automatic logic [31:0] i_csrr(input logic [4:0] rd, input logic [11:0] csr);
    return {csr, 5'd0, 3'b010, rd, 7'b1110011};
  endfunction
  function automatic logic [31:0] i_csrw(input logic [11:0] csr, input logic [4:0] rs1);
    return {csr, rs1, 3'b001, 5'd0, 7'b1110011};
  endfunction
  function automatic logic [31:0] i_j(input logic [15:0] from, input logic [15:0] to);  // jal x0, to - from
    logic [20:1] o;
    o = 20'(({5'd0, to} - {5'd0, from}) >> 1);
    return {o[20], o[10:1], o[11], o[19:12], 5'd0, 7'b1101111};
  endfunction

  // ---- state ----
  logic              dmactive_q, ndmreset_q, busy_q, go_q, taken_q;
  logic [HSW-1:0]    hartsel_q;
  logic [2:0]        cmderr_q;
  logic [31:0]       data0_q, data1_q, prog0_q, prog1_q;
  logic [NHP-1:0]    haltreq_q, resumeack_q, resume_q, havereset_q, halted_q;
  logic [4:0]        c_reg_q;                    // the running command: GPR, write, 64 bits, transfer, postexec
  logic              c_wr_q, c_d64_q, c_xfer_q, c_post_q;
  logic              ndmrp_q;                    // an ndmreset not over: from ndmreset until the cores leave reset
  logic              rsp_q;
  logic [31:0]       rdata_q;

  wire [NHP-1:0] unav    = (NHP'(unavail_i) & EXISTS) | {NHP{hart_rst_i}};
  wire           dm_rst  = rst || !dmactive_q;

  // ---- the window's handshake (as tg_bootrom's: one message at a time) ----
  logic                 wbusy_q, wget_q;
  logic [11:0]          wbeat_q;                 // window offset [15:4] of the beat being answered
  logic [1:0]           wleft_q, wput_beat_q;
  logic [TL_SIZE_W-1:0] wsize_q;
  logic [TL_SRC_W-1:0]  wsrc_q;
  wire [1:0]  a_lastb = tl_a_last(a_i.opcode, a_i.size);
  wire        a_last  = a_lastb == 2'd0 || wput_beat_q == a_lastb;
  wire [1:0]  nbeat   = tl_last_beat(a_i.size);
  wire        a_put   = tl_a_has_data(a_i.opcode);
  wire [15:0] a_off   = a_i.address[15:0];
  assign a_ready_o = !wbusy_q;

  always_ff @(posedge clk) begin
    if (bus_rst) begin
      wbusy_q     <= 1'b0;
      wput_beat_q <= '0;
    end else if (!wbusy_q) begin
      if (a_valid_i) begin
        if (a_put && !a_last) begin
          wput_beat_q <= wput_beat_q + 1'b1;
        end else begin
          wbusy_q     <= 1'b1;
          wput_beat_q <= '0;
        end
      end
    end else if (d_ready_i && wleft_q == 2'd0) begin
      wbusy_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (!wbusy_q && a_valid_i && a_last) begin
      wget_q  <= a_i.opcode == A_GET;
      wbeat_q <= a_off[15:4] & ~{10'd0, nbeat};
      wleft_q <= (a_i.opcode == A_GET) ? nbeat : 2'd0;
      wsize_q <= a_i.size;
      wsrc_q  <= a_i.source;
    end else if (wbusy_q && d_ready_i && wleft_q != 2'd0) begin
      wbeat_q <= wbeat_q + 1'b1;
      wleft_q <= wleft_q - 1'b1;
    end
  end

  // The hart's stores, single-beat Puts in the window's first page: the status words by address, data0-1
  wire        a_wr = a_valid_i && !wbusy_q && a_put && a_i.size <= 3'd4 && a_off[15:12] == 4'h0;
  logic [3:0] a_word;                            // the beat's words the Put writes
  logic [NHP-1:0] ev_halted, ev_going, ev_resuming, ev_exc;
  always_comb begin
    for (int w = 0; w < 4; w++) a_word[w] = |a_i.mask[4*w +: 4];
    ev_halted = '0; ev_going = '0; ev_resuming = '0; ev_exc = '0;
    for (int h = 0; h < NH; h++) begin
      if (a_wr && a_off[11:8] == 4'h1 && a_off[5:4] == 2'(h >> 2) && a_word[h & 3]) begin
        ev_halted[h]   = a_off[7:6] == 2'd0;
        ev_going[h]    = a_off[7:6] == 2'd1;
        ev_resuming[h] = a_off[7:6] == 2'd2;
        ev_exc[h]      = a_off[7:6] == 2'd3;
      end
    end
  end
  wire a_wdata = a_wr && a_off[11:4] == 8'h20;

  // ---- the window's contents ----
  wire        is_s01 = c_reg_q[4:1] == 4'b0100;          // s0 or s1: kept in dscratch0 or dscratch1
  wire [11:0] c_dscr = c_reg_q[0] ? CSR_DSCRATCH1 : CSR_DSCRATCH0;
  logic [7:0][31:0] aw;
  always_comb begin
    aw[0] = !c_xfer_q ? NOP :
            is_s01    ? (c_wr_q ? i_load(S1, c_d64_q) : i_csrr(S1, c_dscr)) :
                        (c_wr_q ? i_load(c_reg_q, c_d64_q) : i_store(c_reg_q, c_d64_q));
    aw[1] = (c_xfer_q && is_s01) ? (c_wr_q ? i_csrw(c_dscr, S1) : i_store(S1, c_d64_q)) : NOP;
    aw[2] = c_post_q ? i_csrr(S0, CSR_DSCRATCH0) : i_j(W_ABS + 16'h8, DBGROM_HALT);   // back to the loop
    aw[3] = i_csrr(S1, CSR_DSCRATCH1);                    // postexec: the hart's s0 and s1, then the buffer
    aw[4] = i_j(W_ABS + 16'h10, W_PROG);
    aw[5] = EBREAK;
    aw[6] = EBREAK;
    aw[7] = EBREAK;
  end

  logic [127:0] rbeat;
  always_comb begin
    rbeat = '0;
    if (wbeat_q[11:8] == 4'h0) begin
      case (wbeat_q[7:4])
        4'h0: for (int h = 0; h < NH; h++)
                if (wbeat_q[3:0] == 4'(h >> 2))
                  rbeat[32*(h & 3) +: 32] = {30'd0, resume_q[h], go_q && hartsel_q == HSW'(h)};
        4'h2: if (wbeat_q[3:0] == 4'h0) rbeat[63:0] = {data1_q, data0_q};
        4'h3: case (wbeat_q[3:0])
                4'h0: rbeat = {aw[3], aw[2], aw[1], aw[0]};
                4'h1: rbeat = {aw[7], aw[6], aw[5], aw[4]};
                4'h4: rbeat = {32'd0, EBREAK, prog1_q, prog0_q};
                default: ;
              endcase
        4'h8: for (int k = 0; k < DBGROM_BEATS; k++) if (wbeat_q[3:0] == 4'(k)) rbeat = DBGROM_IMG[k];
        default: ;
      endcase
    end
  end

  always_comb begin
    d_o        = '0;
    d_o.opcode = wget_q ? D_ACCESS_ACK_DATA : D_ACCESS_ACK;
    d_o.size   = wsize_q;
    d_o.source = wsrc_q;
    d_o.data   = wget_q ? rbeat : '0;
  end
  assign d_valid_o = wbusy_q;

  // ---- DMI ----
  wire [31:0] cw     = dmi_wdata_i;
  wire        dmi_wr = dmi_req_i && dmi_op_i == 2'd2;
  wire [HSW-1:0] sel = hartsel_q;
  wire        sel_ex = EXISTS[sel];
  wire        sel_un = unav[sel];
  wire        sel_ha = sel_ex && !sel_un && halted_q[sel];
  // an Access Register command this DM runs: GPRs only, 32 or 64 bits, no postincrement
  wire        cmd_ok = cw[31:24] == 8'd0 && !cw[23] && !cw[19] &&
                       (!cw[17] || ((cw[22:20] == 3'd2 || cw[22:20] == 3'd3) && cw[15:5] == 11'h080));
  wire        buf_acc  = dmi_req_i && (dmi_addr_i == 7'h04 || dmi_addr_i == 7'h05 ||
                                       dmi_addr_i == 7'h20 || dmi_addr_i == 7'h21);
  // reading or writing data or progbuf, or writing abstractcs, command or abstractauto, while a command runs
  wire        busy_err = busy_q && (buf_acc || (dmi_wr && (dmi_addr_i == 7'h16 || dmi_addr_i == 7'h17 ||
                                                           dmi_addr_i == 7'h18)));
  wire        ctl_wr   = dmi_wr && dmi_addr_i == 7'h10 && dmactive_q && !busy_q;   // the per-hart bits apply
  wire [HSW-1:0] new_sel = cw[16 +: HSW];

  wire  [NHP-1:0] hsum = halted_q & ~unav & EXISTS;   // haltsum0: unavailable harts are not halted
  logic [31:0] dmstatus, rd;
  always_comb begin
    logic hv, ra, ne, un, ru, ha;
    hv = sel_ex && havereset_q[sel];
    ra = sel_ex && resumeack_q[sel];
    ne = !sel_ex;
    un = sel_ex && sel_un;
    ha = sel_ha;
    ru = sel_ex && !sel_un && !halted_q[sel];
    dmstatus = {7'd0, ndmreset_q || ndmrp_q, 1'b0, 1'b1, 2'd0, hv, hv, ra, ra, ne, ne, un, un, ru, ru, ha, ha,
                1'b1, 1'b0, 1'b0, 1'b0, 4'd3};
    rd = '0;
    case (dmi_addr_i)
      7'h04: rd = data0_q;
      7'h05: rd = data1_q;
      7'h10: rd = {6'd0, 10'(hartsel_q), 10'd0, 4'd0, ndmreset_q, dmactive_q};
      7'h11: rd = dmstatus;
      7'h16: rd = {3'd0, 5'd2, 11'd0, busy_q, 1'b0, cmderr_q, 4'd0, 4'd2};
      7'h20: rd = prog0_q;
      7'h21: rd = prog1_q;
      7'h40: rd = 32'(hsum);
      default: ;
    endcase
  end

  // the answer, the cycle after the request; never held in reset
  always_ff @(posedge clk) begin
    rsp_q   <= dmi_req_i;
    rdata_q <= dmi_op_i == 2'd1 ? rd : '0;
  end
  assign dmi_rsp_o   = rsp_q;
  assign dmi_rdata_o = rdata_q;
  assign dmi_resp_o  = 2'd0;

  // dmactive: while it is 0, a write changes nothing else
  always_ff @(posedge clk) begin
    if (rst) dmactive_q <= 1'b0;
    else if (dmi_wr && dmi_addr_i == 7'h10) dmactive_q <= cw[0];
  end

  always_ff @(posedge clk) begin
    if (dm_rst) begin
      ndmreset_q <= 1'b0;
      ndmrp_q    <= 1'b0;
      hartsel_q  <= '0;
      haltreq_q  <= '0;
      resumeack_q <= '0;
      resume_q   <= '0;
      busy_q     <= 1'b0;
      go_q       <= 1'b0;
      taken_q    <= 1'b0;
      cmderr_q   <= '0;
      data0_q    <= '0;
      data1_q    <= '0;
      prog0_q    <= '0;
      prog1_q    <= '0;
    end else begin
      if (dmi_wr && dmi_addr_i == 7'h10) ndmreset_q <= cw[1];
      ndmrp_q <= ndmreset_q || (ndmrp_q && hart_rst_i);   // a reset the host holds is no ndmreset
      if (ctl_wr) hartsel_q <= new_sel;
      // haltreq, resumereq and ackhavereset apply to the new hartsel (one hart: hasel 0)
      for (int h = 0; h < NHP; h++) begin
        if (ctl_wr && new_sel == HSW'(h) && EXISTS[h]) begin
          haltreq_q[h] <= cw[31];
          if (cw[30] && !cw[31]) begin
            resumeack_q[h] <= 1'b0;
            if (halted_q[h] && !unav[h]) resume_q[h] <= 1'b1;
          end
        end
        if (ev_resuming[h]) begin
          resumeack_q[h] <= 1'b1;
          resume_q[h]    <= 1'b0;
        end
        if (unav[h]) resume_q[h] <= 1'b0;
      end

      if (dmi_wr && !busy_q) begin
        case (dmi_addr_i)
          7'h04: data0_q <= cw;
          7'h05: data1_q <= cw;
          7'h20: prog0_q <= cw;
          7'h21: prog1_q <= cw;
          default: ;
        endcase
      end
      if (a_wdata) begin                          // the hart's stores, only while a command runs
        for (int b = 0; b < 4; b++) begin
          if (a_i.mask[b])     data0_q[8*b +: 8] <= a_i.data[8*b +: 8];
          if (a_i.mask[4 + b]) data1_q[8*b +: 8] <= a_i.data[32 + 8*b +: 8];
        end
      end

      // abstract commands
      if (dmi_wr && dmi_addr_i == 7'h17 && !busy_q && cmderr_q == 3'd0) begin
        if (!cmd_ok) begin
          cmderr_q <= 3'd2;
        end else if (!sel_ha) begin
          cmderr_q <= 3'd4;
        end else begin
          busy_q   <= 1'b1;
          go_q     <= 1'b1;
          taken_q  <= 1'b0;
          c_reg_q  <= cw[4:0];
          c_wr_q   <= cw[16];
          c_d64_q  <= cw[22:20] == 3'd3;
          c_xfer_q <= cw[17];
          c_post_q <= cw[18];
        end
      end
      if (dmi_wr && dmi_addr_i == 7'h16 && !busy_q) cmderr_q <= cmderr_q & ~cw[10:8];
      if (busy_q) begin
        if (go_q && ev_going[sel]) begin           // the hart took the command
          go_q    <= 1'b0;
          taken_q <= 1'b1;
        end
        if (taken_q && ev_halted[sel]) busy_q <= 1'b0;   // back in the loop
        if (taken_q && ev_exc[sel]) begin
          busy_q <= 1'b0;
          if (cmderr_q == 3'd0 && !busy_err) cmderr_q <= 3'd3;
        end
        if (sel_un) begin                          // the hart went away (reset): the command ends
          busy_q <= 1'b0;
          go_q   <= 1'b0;
          if (cmderr_q == 3'd0 && !busy_err) cmderr_q <= 3'd4;
        end
      end
      if (busy_err && cmderr_q == 3'd0) cmderr_q <= 3'd1;
    end
  end

  // The harts' states: halted from the ROM's writes, cleared by its RESUMING write and by a reset;
  // havereset sticky until acknowledged (both kept while dmactive is 0)
  always_ff @(posedge clk) begin
    if (rst) begin
      halted_q    <= '0;
      havereset_q <= '0;
    end else begin
      halted_q <= (halted_q | ev_halted) & ~ev_resuming & ~unav;
      for (int h = 0; h < NHP; h++)
        if (ctl_wr && new_sel == HSW'(h) && cw[28]) havereset_q[h] <= 1'b0;
      if (hart_rst_i) havereset_q <= EXISTS;
    end
  end

  assign haltreq_o  = haltreq_q[NH-1:0];
  assign ndmreset_o = ndmreset_q;

  wire unused = ^{a_i.param, a_i.corrupt, a_i.address[PA_W-1:16], a_off[3:0], a_i.data[127:64], a_i.mask[15:8]};
endmodule
