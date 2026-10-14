// Multi-write-port LUTRAM (docs/perf/fpga_friendly.md T2): NW synchronous write ports, NR
// asynchronous read ports, built from tg_ram_lut banks (one write port each).
//
// Behaviour: a read returns the data written by the last write to its address, as in
// tg_ram_lut (the old data until the clock edge, the new data after it). Writes to the same
// address in one cycle: the highest-numbered writer wins (the youngest, when writers are in
// program order). Contents are not reset; an address reads garbage until first written.
//
// IMPL "lvt" (replication plus a live-value table): a data bank per writer, written only by
//   that writer, with the NR read ports; the live-value table (LVT) records which bank holds
//   each address's last write, and each read port selects that bank.
//   LVT "lutram" (default): the table is itself an XOR-coded multi-write LUTRAM of
//     ceil(log2 NW) bits (below), so it is a few narrow banks rather than DEPTH registers
//     with a DEPTH:1 multiplexer per read port.
//   LVT "reg": the table in flip-flops (the classic form), for comparison.
// IMPL "xor": NW banks of the full width, and an address's value is the XOR of all banks.
//   Writer w stores its data XOR the other banks' current values at the address, so the XOR
//   of all banks becomes the new data. Each bank needs NW - 1 extra read ports for that.
// In both XOR codings a lower-numbered writer's write is dropped when a higher one writes the
// same address in the same cycle (the code assumes one writer per address per cycle; the
// dropped write would be overwritten anyway). The coding holds from any initial contents
// once an address is written; four-state simulators show X until every bank is written.
//
// Cost in tg_ram_lut primitives (S = read ports per bank; see tg_ram_lut for the packing):
//   "lvt": NW data banks of WIDTH bits with S = NR, plus NW LVT banks of ceil(log2 NW) bits
//          with S = NR + NW - 1 (or the flip-flop table), plus an NW:1 select per read bit.
//   "xor": NW banks of WIDTH bits with S = NR + NW - 1, plus an NW-input XOR per read bit
//          and per write bit.
// Sources (published; clean room, DR-001): C. E. LaForest and J. G. Steffan, "Efficient
// multi-ported memories for FPGAs", FPGA 2010 (the LVT); C. E. LaForest, M. G. Liu,
// E. Rapati and J. G. Steffan, "Multi-ported memories for FPGAs via XOR", FPGA 2012;
// A. M. S. Abdelhadi and G. G. F. Lemieux, "Modular multi-ported SRAM-based memories",
// FPGA 2014 (an LVT held in RAM, coded so it needs no flip-flop table).
module tg_ram_lut_mw #(
  parameter int    DEPTH = 64,
  parameter int    WIDTH = 8,
  parameter int    NW    = 2,
  parameter int    NR    = 4,
  parameter string IMPL  = "lvt",     // "lvt" or "xor"
  parameter string LVT   = "lutram",  // IMPL "lvt": "lutram" or "reg"
  localparam int   AW    = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
  input  logic                       clk,
  input  logic [NW-1:0]              wen,
  input  logic [NW-1:0][AW-1:0]      waddr,
  input  logic [NW-1:0][WIDTH-1:0]   wdata,
  input  logic [NR-1:0][AW-1:0]      raddr,
  output logic [NR-1:0][WIDTH-1:0]   rdata
);
  if (NW < 2 || NR < 1 || WIDTH < 1 || DEPTH < 2) begin : g_bad_params
    $error("tg_ram_lut_mw: needs NW >= 2, NR >= 1, WIDTH >= 1, DEPTH >= 2 (NW = 1 is tg_ram_lut)");
  end
  if (IMPL != "lvt" && IMPL != "xor") begin : g_bad_impl
    $error("tg_ram_lut_mw: IMPL must be \"lvt\" or \"xor\"");
  end
  if (LVT != "lutram" && LVT != "reg") begin : g_bad_lvt
    $error("tg_ram_lut_mw: LVT must be \"lutram\" or \"reg\"");
  end

  localparam int LW = $clog2(NW);   // writer number
  localparam int NX = NW - 1;       // extra read ports of an XOR-coded bank

  // Same-address writes: only the highest-numbered writer keeps its write in a coded table.
  logic [NW-1:0] wsole;
  always_comb begin
    for (int w = 0; w < NW; w++) begin
      wsole[w] = wen[w];
      for (int v = w + 1; v < NW; v++) begin
        if (wen[v] && waddr[v] == waddr[w]) wsole[w] = 1'b0;
      end
    end
  end

  // Read port of bank k at which writer w (w != k) reads its own address: after the NR
  // ports of the readers, in writer order without k.
  function automatic int xport(input int k, input int w);
    return NR + ((w < k) ? w : w - 1);
  endfunction

  if (IMPL == "xor") begin : g_xor
    logic [NW-1:0][NR+NX-1:0][WIDTH-1:0] brd;
    for (genvar k = 0; k < NW; k++) begin : g_bank
      logic [NR+NX-1:0][AW-1:0] ra;
      logic [WIDTH-1:0]         wd;
      for (genvar r = 0; r < NR; r++) begin : g_rp
        assign ra[r] = raddr[r];
      end
      for (genvar w = 0; w < NW; w++) begin : g_xp
        if (w != k) begin : g_other
          assign ra[xport(k, w)] = waddr[w];
        end
      end
      // the data XOR the other banks' values at the written address
      always_comb begin
        wd = wdata[k];
        for (int j = 0; j < NW; j++) begin
          if (j != k) wd ^= brd[j][xport(j, k)];
        end
      end
      tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(WIDTH), .NR(NR + NX)) u_mem (
        .clk, .we(wsole[k]), .waddr(waddr[k]), .wdata(wd), .raddr(ra), .rdata(brd[k]));
    end
    always_comb begin
      for (int r = 0; r < NR; r++) begin
        rdata[r] = '0;
        for (int k = 0; k < NW; k++) rdata[r] ^= brd[k][r];
      end
    end
  end else begin : g_lvt
    // Data banks: bank w holds writer w's writes.
    logic [NW-1:0][NR-1:0][WIDTH-1:0] drd;
    for (genvar w = 0; w < NW; w++) begin : g_data
      tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(WIDTH), .NR(NR)) u_mem (
        .clk, .we(wen[w]), .waddr(waddr[w]), .wdata(wdata[w]), .raddr(raddr), .rdata(drd[w]));
    end

    // Live-value table: sel[r] = the writer of raddr[r]'s last write.
    logic [NR-1:0][LW-1:0] sel;
    if (LVT == "reg") begin : g_lvt_reg
      (* ram_style = "registers" *) logic [LW-1:0] lvt [DEPTH];
      always_ff @(posedge clk) begin
        for (int w = 0; w < NW; w++) begin   // the highest writer is applied last
          if (wen[w]) lvt[waddr[w]] <= LW'(w);
        end
      end
      for (genvar r = 0; r < NR; r++) begin : g_rd
        assign sel[r] = lvt[raddr[r]];
      end
      /* verilator lint_off UNUSEDSIGNAL */
      logic unused_wsole;
      assign unused_wsole = ^wsole;   // the table applies the writers in order instead
      /* verilator lint_on UNUSEDSIGNAL */
    end else begin : g_lvt_ram
      // XOR-coded: an address's writer is the XOR of the NW tables' entries.
      logic [NW-1:0][NR+NX-1:0][LW-1:0] lrd;
      for (genvar k = 0; k < NW; k++) begin : g_bank
        logic [NR+NX-1:0][AW-1:0] ra;
        logic [LW-1:0]            wd;
        for (genvar r = 0; r < NR; r++) begin : g_rp
          assign ra[r] = raddr[r];
        end
        for (genvar w = 0; w < NW; w++) begin : g_xp
          if (w != k) begin : g_other
            assign ra[xport(k, w)] = waddr[w];
          end
        end
        always_comb begin
          wd = LW'(k);
          for (int j = 0; j < NW; j++) begin
            if (j != k) wd ^= lrd[j][xport(j, k)];
          end
        end
        tg_ram_lut #(.DEPTH(DEPTH), .WIDTH(LW), .NR(NR + NX)) u_lvt (
          .clk, .we(wsole[k]), .waddr(waddr[k]), .wdata(wd), .raddr(ra), .rdata(lrd[k]));
      end
      always_comb begin
        for (int r = 0; r < NR; r++) begin
          sel[r] = '0;
          for (int k = 0; k < NW; k++) sel[r] ^= lrd[k][r];
        end
      end
    end

    for (genvar r = 0; r < NR; r++) begin : g_out
      assign rdata[r] = drd[sel[r]][r];
    end
  end
endmodule
