// Harts for the debug module's bench (tests/unit/dbg; docs/spec/soc.md §9.4-9.6). A small RV64I interpreter
// per hart, enough for the debug ROM, tg_dm's abstract area and the program buffers the bench writes, with
// debug mode as core-2 gave it: a halt request (a level) is taken between instructions, entry jumps to
// DEBUG_BASE + 0x800 with dpc the next pc and dcsr.cause set; ebreak in debug mode jumps there again; an
// exception there goes to + 0x808 and changes nothing else; dret returns to dpc, and with dcsr.step one
// instruction later the hart is back with cause 4. The window can be reached in debug mode only.
// Outside debug mode each hart runs a three-instruction loop from its local memory (x5 += 1, x6 += 2). In
// debug mode it fetches the window through its own 8-line I$, which only fence.i invalidates, and its loads
// and stores there go over TL-UL to tg_dm. One process steps the harts in turn; a TL access holds them all.
module tb_dbg_harts
  import tg_pkg::*, tg_tl_pkg::*;
#(
  parameter int NH = 2
) (
  input  logic          clk,
  input  logic          rst,
  input  logic [NH-1:0] haltreq_i,
  input  logic [NH-1:0] hart_rst_i,       // back to the loop's start, out of debug mode
  output tl_a_t         a_o,
  output logic          a_valid_o,
  input  logic          a_ready_i,
  input  tl_d_t         d_i,
  input  logic          d_valid_i,
  output logic          d_ready_o
);
  localparam logic [63:0] DBG = 64'h1100_0000, MEM = 64'h8000_0000;
  localparam int MEMW = 1024;                 // 8 KiB of local memory, in doublewords

  // the harts' state, which the bench reads and writes
  logic [63:0] x [NH][32];
  logic [63:0] pc [NH], dpc [NH], dscratch0 [NH], dscratch1 [NH], mstatus [NH];
  logic [31:0] dcsr [NH];                     // [15] ebreakm, [8:6] cause, [2] step, [1:0] prv
  bit          dmode [NH], stepping [NH];
  int unsigned retired [NH];                  // instructions outside debug mode
  int unsigned dentries [NH];                 // entries to debug mode at 0x800 from outside it
  int unsigned exc_count [NH];                // exceptions in debug mode
  logic [63:0] mem [MEMW];
  int          bad;                           // a trap outside debug mode, or a TL answer out of place

  // the I$s
  logic [63:0]  ic_tag  [NH][8];
  bit           ic_v    [NH][8];
  logic [127:0] ic_data [NH][8][4];
  int           ic_next [NH];

  // ---- TL-UL, one access at a time: outputs change just after a rising edge, inputs are read at falling ones ----
  task automatic tl_send(input tl_a_t a);
    @(posedge clk); #1;
    a_o = a;
    a_valid_o = 1'b1;
    forever begin
      @(negedge clk);
      if (a_ready_i) break;
    end
    @(posedge clk); #1;
    a_valid_o = 1'b0;
  endtask

  task automatic tl_get(input int h, input logic [63:0] addr, input logic [2:0] size, output logic [127:0] b [4]);
    tl_a_t a;
    int n;
    n = size > 3'd4 ? 1 << (size - 3'd4) : 1;
    a = '0;
    a.opcode  = A_GET;
    a.size    = size;
    a.source  = TL_SRC_W'(h);
    a.address = PA_W'(addr);
    a.mask    = '1;
    tl_send(a);
    for (int k = 0; k < n; ) begin
      @(negedge clk);
      if (d_valid_i) begin
        if (d_i.opcode != D_ACCESS_ACK_DATA || d_i.source != TL_SRC_W'(h) || d_i.denied) begin
          $display("tb_dbg_harts: bad Get answer at %h", addr);
          bad++;
        end
        b[k] = d_i.data;
        k++;
      end
    end
  endtask

  task automatic tl_put(input int h, input logic [63:0] addr, input int bytes, input logic [63:0] v);
    tl_a_t a;
    a = '0;
    a.opcode  = A_PUT_FULL;
    a.size    = 3'($clog2(bytes));
    a.source  = TL_SRC_W'(h);
    a.address = PA_W'(addr);
    a.mask    = TL_MASK_W'(((1 << bytes) - 1) << addr[3:0]);
    a.data    = TL_DATA_W'(v) << (8 * addr[3:0]);
    tl_send(a);
    forever begin
      @(negedge clk);
      if (d_valid_i) break;
    end
    if (d_i.opcode != D_ACCESS_ACK || d_i.source != TL_SRC_W'(h) || d_i.denied) begin
      $display("tb_dbg_harts: bad Put answer at %h", addr);
      bad++;
    end
  endtask

  function automatic bit in_win(input logic [63:0] a);
    return a >= DBG && a < DBG + 64'h1_0000;
  endfunction
  function automatic bit in_mem(input logic [63:0] a);
    return a >= MEM && a < MEM + 64'(8 * MEMW);
  endfunction

  // ---- memory accesses (naturally aligned only) ----
  task automatic load(input int h, input logic [63:0] a, input int bytes, output logic [63:0] v, output bit ok);
    logic [127:0] b [4];
    logic [63:0]  w;
    ok = (a & 64'(bytes - 1)) == '0;
    v  = '0;
    if (!ok) return;
    if (in_win(a) && dmode[h]) begin
      tl_get(h, a, 3'($clog2(bytes)), b);
      v = 64'(b[0] >> (8 * a[3:0]));
    end else if (in_mem(a)) begin
      w = mem[(a - MEM) >> 3];
      v = w >> (8 * a[2:0]);
    end else begin
      ok = 1'b0;
      return;
    end
    if (bytes < 8) v &= (64'd1 << (8 * bytes)) - 1;
  endtask

  task automatic store(input int h, input logic [63:0] a, input int bytes, input logic [63:0] v, output bit ok);
    logic [63:0] m;
    ok = (a & 64'(bytes - 1)) == '0;
    if (!ok) return;
    if (in_win(a) && dmode[h]) begin
      tl_put(h, a, bytes, v);
    end else if (in_mem(a)) begin
      m = (bytes == 8 ? '1 : (64'd1 << (8 * bytes)) - 1) << (8 * a[2:0]);
      mem[(a - MEM) >> 3] = (mem[(a - MEM) >> 3] & ~m) | ((v << (8 * a[2:0])) & m);
    end else begin
      ok = 1'b0;
    end
  endtask

  task automatic fetch(input int h, input logic [63:0] a, output logic [31:0] insn, output bit ok);
    logic [127:0] b [4];
    logic [63:0]  line;
    int           k;
    ok   = a[1:0] == 2'd0;
    insn = '0;
    if (!ok) return;
    if (in_win(a) && dmode[h]) begin
      line = a & ~64'h3F;
      k = -1;
      for (int i = 0; i < 8; i++) if (ic_v[h][i] && ic_tag[h][i] == line) k = i;
      if (k < 0) begin                          // a line refill, as the I$'s
        tl_get(h, line, 3'd6, b);
        k = ic_next[h];
        ic_next[h] = (ic_next[h] + 1) % 8;
        ic_v[h][k]   = 1'b1;
        ic_tag[h][k] = line;
        for (int j = 0; j < 4; j++) ic_data[h][k][j] = b[j];
      end
      insn = ic_data[h][k][a[5:4]][32 * a[3:2] +: 32];
    end else if (in_mem(a)) begin
      insn = mem[(a - MEM) >> 3][32 * a[2] +: 32];
    end else begin
      ok = 1'b0;
    end
  endtask

  // ---- debug mode ----
  task automatic enter(input int h, input logic [2:0] cause);
    dpc[h]       = pc[h];
    dcsr[h][8:6] = cause;
    dmode[h]     = 1'b1;
    pc[h]        = DBG + 64'h800;
    dentries[h]++;
  endtask

  task automatic trap(input int h, input string why);
    if (dmode[h]) begin
      pc[h] = DBG + 64'h808;                    // nothing else changes
      exc_count[h]++;
    end else begin
      $display("tb_dbg_harts: hart %0d trapped outside debug mode (%s) at %h", h, why, pc[h]);
      bad++;
      pc[h] = pc[h] + 4;
    end
  endtask

  task automatic csr(input int h, input logic [11:0] n, input logic [2:0] f3, input logic [63:0] src,
                     input bit wr, output logic [63:0] old, output bit ok);
    logic [63:0] nv;
    ok  = 1'b1;
    old = '0;
    case (n)
      12'hF14: old = 64'(h);
      12'h300: old = mstatus[h];
      12'h7B0: old = dmode[h] ? 64'(dcsr[h]) : '0;
      12'h7B1: old = dpc[h];
      12'h7B2: old = dscratch0[h];
      12'h7B3: old = dscratch1[h];
      default: ok = 1'b0;
    endcase
    if (n[11:4] == 8'h7B && !dmode[h]) ok = 1'b0;   // the debug CSRs exist in debug mode only
    if (!ok || !wr) return;
    nv = f3[1:0] == 2'd1 ? src : f3[1:0] == 2'd2 ? old | src : old & ~src;
    case (n)
      12'hF14: ok = 1'b0;
      12'h300: mstatus[h] = nv;
      12'h7B0: dcsr[h] = {dcsr[h][31:16], nv[15], dcsr[h][14:3], nv[2], dcsr[h][1:0]};
      12'h7B1: dpc[h] = nv;
      12'h7B2: dscratch0[h] = nv;
      12'h7B3: dscratch1[h] = nv;
      default: ;
    endcase
  endtask

  function automatic logic [63:0] sx(input logic [63:0] v, input int bits);
    return 64'($signed(v << (64 - bits)) >>> (64 - bits));
  endfunction

  task automatic step(input int h);
    logic [31:0] i;
    logic [63:0] r1, r2, imm, a, v, old, npc;
    logic [4:0]  rd;
    logic [2:0]  f3;
    bit          ok, wb, after_dret;
    if (!dmode[h] && haltreq_i[h]) begin
      enter(h, 3'd3);
      return;
    end
    fetch(h, pc[h], i, ok);
    if (!ok) begin
      trap(h, "fetch");
      return;
    end
    rd = i[11:7];
    f3 = i[14:12];
    r1 = x[h][i[19:15]];
    r2 = x[h][i[24:20]];
    npc = pc[h] + 4;
    v  = '0;
    wb = 1'b0;
    after_dret = 1'b0;
    case (i[6:0])
      7'b0110111: begin v = sx({32'd0, i[31:12], 12'd0}, 32); wb = 1'b1; end                       // lui
      7'b0010111: begin v = pc[h] + sx({32'd0, i[31:12], 12'd0}, 32); wb = 1'b1; end               // auipc
      7'b1101111: begin                                                                              // jal
        v = npc; wb = 1'b1;
        npc = pc[h] + sx(64'({i[31], i[19:12], i[20], i[30:21], 1'b0}), 21);
      end
      7'b1100111: begin v = npc; wb = 1'b1; npc = (r1 + sx(64'(i[31:20]), 12)) & ~64'd1; end        // jalr
      7'b1100011: begin                                                                              // branches
        imm = sx(64'({i[31], i[7], i[30:25], i[11:8], 1'b0}), 13);
        case (f3)
          3'd0: if (r1 == r2) npc = pc[h] + imm;
          3'd1: if (r1 != r2) npc = pc[h] + imm;
          3'd4: if ($signed(r1) <  $signed(r2)) npc = pc[h] + imm;
          3'd5: if ($signed(r1) >= $signed(r2)) npc = pc[h] + imm;
          3'd6: if (r1 <  r2) npc = pc[h] + imm;
          3'd7: if (r1 >= r2) npc = pc[h] + imm;
          default: begin trap(h, "branch"); return; end
        endcase
      end
      7'b0000011: begin                                                                              // loads
        a = r1 + sx(64'(i[31:20]), 12);
        load(h, a, 1 << f3[1:0], v, ok);
        if (!ok || f3 == 3'd7) begin trap(h, "load"); return; end
        if (!f3[2]) v = sx(v, 8 << f3[1:0]);
        wb = 1'b1;
      end
      7'b0100011: begin                                                                              // stores
        a = r1 + sx(64'({i[31:25], i[11:7]}), 12);
        if (f3[2]) begin trap(h, "store"); return; end
        store(h, a, 1 << f3[1:0], r2, ok);
        if (!ok) begin trap(h, "store"); return; end
      end
      7'b0010011: begin                                                                              // op-imm
        imm = sx(64'(i[31:20]), 12);
        wb = 1'b1;
        case (f3)
          3'd0: v = r1 + imm;
          3'd1: v = r1 << i[25:20];
          3'd2: v = 64'($signed(r1) < $signed(imm));
          3'd3: v = 64'(r1 < imm);
          3'd4: v = r1 ^ imm;
          3'd5: v = i[30] ? 64'($signed(r1) >>> i[25:20]) : r1 >> i[25:20];
          3'd6: v = r1 | imm;
          default: v = r1 & imm;
        endcase
      end
      7'b0110011: begin                                                                              // op
        wb = 1'b1;
        case (f3)
          3'd0: v = i[30] ? r1 - r2 : r1 + r2;
          3'd1: v = r1 << r2[5:0];
          3'd4: v = r1 ^ r2;
          3'd5: v = i[30] ? 64'($signed(r1) >>> r2[5:0]) : r1 >> r2[5:0];
          3'd6: v = r1 | r2;
          3'd7: v = r1 & r2;
          default: begin trap(h, "op"); return; end
        endcase
      end
      7'b0001111: if (f3 == 3'd1) for (int k = 0; k < 8; k++) ic_v[h][k] = 1'b0;                  // fence.i
      7'b1110011: begin                                                                              // system
        if (f3 == 3'd0) begin
          if (i == 32'h0010_0073) begin                                                              // ebreak
            if (!dmode[h]) begin trap(h, "ebreak"); return; end
            pc[h] = DBG + 64'h800;
            return;
          end else if (i == 32'h7B20_0073 && dmode[h]) begin                                        // dret
            dmode[h]    = 1'b0;
            stepping[h] = dcsr[h][2];
            npc = dpc[h];
            after_dret = 1'b1;
          end else if (i == 32'h1050_0073) begin                                                     // wfi: a nop here
          end else begin
            trap(h, "system");
            return;
          end
        end else begin                                                                               // csr*
          csr(h, i[31:20], f3, f3[2] ? 64'(i[19:15]) : r1, f3[1:0] == 2'd1 || i[19:15] != 5'd0, old, ok);
          if (!ok) begin trap(h, "csr"); return; end
          v = old;
          wb = 1'b1;
        end
      end
      default: begin trap(h, "illegal"); return; end
    endcase
    if (wb && rd != 5'd0) x[h][rd] = v;
    pc[h] = npc;
    if (after_dret) return;
    if (!dmode[h]) begin
      retired[h]++;
      if (stepping[h]) begin                      // one instruction stepped: back in with cause 4
        stepping[h] = 1'b0;
        enter(h, 3'd4);
      end
    end
  endtask

  task automatic reset_hart(input int h);
    pc[h]       = MEM;
    dmode[h]    = 1'b0;
    stepping[h] = 1'b0;
    dcsr[h]     = {4'd4, 26'd0, 2'd3};
    for (int k = 0; k < 8; k++) ic_v[h][k] = 1'b0;
  endtask

  initial begin
    a_o       = '0;
    a_valid_o = 1'b0;
    d_ready_o = 1'b1;
    bad       = 0;
    for (int k = 0; k < MEMW; k++) mem[k] = '0;
    mem[0] = {32'h0023_0313, 32'h0012_8293};      // addi x5, x5, 1; addi x6, x6, 2
    mem[1] = {32'h0000_0013, 32'hFF9F_F06F};      // j .-8; nop
    for (int h = 0; h < NH; h++) begin
      for (int r = 0; r < 32; r++) x[h][r] = r == 0 ? '0 : {32'(h + 1), 32'(r * 32'h0101_0101)};
      mstatus[h] = '0;
      dpc[h] = '0;
      dscratch0[h] = '0;
      dscratch1[h] = '0;
      retired[h] = 0;
      dentries[h] = 0;
      exc_count[h] = 0;
      ic_next[h] = 0;
      reset_hart(h);
    end
    forever begin
      @(posedge clk); #1;
      for (int h = 0; h < NH; h++) begin
        if (rst || hart_rst_i[h]) reset_hart(h);
        else step(h);
      end
    end
  end
endmodule
