// Multi-read-port LUTRAM: NR asynchronous read ports, one synchronous write port.
// The only way RTL instantiates LUTRAM (plan §8.3).
//
// Read-during-write: a read of the address being written returns the old data until the
// clock edge and the new data after it (asynchronous read, synchronous write).
// Contents are not reset and power up undefined.
//
// Mapping. Synthesis (SYNTHESIS defined) builds the memory from explicit UltraScale+
// primitives, so the primitive count is deterministic; tools/tcl/tg_prim_check.tcl checks
// it after every synthesis run. Simulation uses the behavioural model below, unless
// TG_SIM_PRIMS is defined (unit tests of the mapping, with primitive models).
//   DEPTH <= 32:  RAM32M16. Ports A-G are 2-bit read ports, H is the write port.
//   DEPTH <= 64:  RAM64M8.  Ports A-G are 1-bit read ports, H is the write port.
//   DEPTH 65-96:  entries 0-63 in RAM64M8, as for 64, and 64-95 in RAM32M16, as for 32; each
//                 read port selects on address bit 6. About 1.5 times a 64-deep memory, where
//                 banks of 64 would be 2 (DR-175: the smt2 FP register banks of 96).
//   DEPTH >  96:  2^(AW-6) banks of 64 entries; each read port muxes the banks.
// A read slot is one read port's view of 1 bit (64-deep) or 2 bits (32-deep). Slots are
// packed port-major, 7 per primitive, so one read port's bits sit in few primitives
// (short address nets) and no slot is wasted:
//   RAM64M8 per bank  = ceil(NR * WIDTH / 7)
//   RAM32M16          = ceil(NR * ceil(WIDTH / 2) / 7)
// Example: a register-file bank, 64 x 64 bits with 7 read ports, is 64 RAM64M8 (512 LUTs);
// with 9 read ports it is 83.
// The H port's read output (data at waddr) is not used.
(* keep_hierarchy = "yes" *)  // keeps the instance and its ports for the primitive check
module tg_ram_lut #(
  parameter int DEPTH = 64,
  parameter int WIDTH = 8,
  parameter int NR    = 1,
  localparam int AW   = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
  input  logic                       clk,
  input  logic                       we,
  input  logic [AW-1:0]              waddr,
  input  logic [WIDTH-1:0]           wdata,
  input  logic [NR-1:0][AW-1:0]      raddr,
  output logic [NR-1:0][WIDTH-1:0]   rdata
);
  if (NR < 1 || WIDTH < 1 || DEPTH < 2) begin : g_bad_params
    $error("tg_ram_lut: needs NR >= 1, WIDTH >= 1, DEPTH >= 2");
  end

`ifdef SYNTHESIS
  `define TG_RAM_LUT_PRIMS
`elsif TG_SIM_PRIMS
  `define TG_RAM_LUT_PRIMS
`endif

`ifdef TG_RAM_LUT_PRIMS
  `undef TG_RAM_LUT_PRIMS
  localparam int SLOTS_PER_PRIM = 7;   // ports A-G; H is the write port

  if (AW <= 5) begin : g_m32
    // RAM32M16: 2-bit slots. Slot s holds bits {2k+1, 2k} of read port s / SPP (k = s % SPP).
    localparam int SPP   = (WIDTH + 1) / 2;
    localparam int SLOTS = NR * SPP;
    localparam int NPRIM = (SLOTS + SLOTS_PER_PRIM - 1) / SLOTS_PER_PRIM;
    localparam int WPAD  = 2 * SPP;

    logic [4:0]      wa;
    logic [WPAD-1:0] wd;
    assign wa = 5'(waddr);
    assign wd = WPAD'(wdata);

    logic [NR-1:0][WPAD-1:0] rd;
    for (genvar r = 0; r < NR; r++) begin : g_rd
      assign rdata[r] = rd[r][WIDTH-1:0];
    end

    for (genvar p = 0; p < NPRIM; p++) begin : g_prim
      logic [7:0][4:0] a;
      logic [7:0][1:0] di;
      /* verilator lint_off UNUSEDSIGNAL */  // port H and unused slots are not read
      logic [7:0][1:0] dout;
      /* verilator lint_on UNUSEDSIGNAL */
      for (genvar j = 0; j < SLOTS_PER_PRIM; j++) begin : g_slot
        localparam int S = p * SLOTS_PER_PRIM + j;
        if (S < SLOTS) begin : g_used
          localparam int R = S / SPP;
          localparam int K = S % SPP;
          assign a[j]  = 5'(raddr[R]);
          assign di[j] = wd[2*K +: 2];
          assign rd[R][2*K +: 2] = dout[j];
        end else begin : g_unused
          assign a[j]  = wa;
          assign di[j] = 2'b00;
        end
      end
      assign a[7]  = wa;
      assign di[7] = 2'b00;

      RAM32M16 #(
        .INIT_A(64'h0), .INIT_B(64'h0), .INIT_C(64'h0), .INIT_D(64'h0),
        .INIT_E(64'h0), .INIT_F(64'h0), .INIT_G(64'h0), .INIT_H(64'h0)
      ) u_ram (
        .DOA(dout[0]), .DOB(dout[1]), .DOC(dout[2]), .DOD(dout[3]),
        .DOE(dout[4]), .DOF(dout[5]), .DOG(dout[6]), .DOH(dout[7]),
        .ADDRA(a[0]), .ADDRB(a[1]), .ADDRC(a[2]), .ADDRD(a[3]),
        .ADDRE(a[4]), .ADDRF(a[5]), .ADDRG(a[6]), .ADDRH(a[7]),
        .DIA(di[0]), .DIB(di[1]), .DIC(di[2]), .DID(di[3]),
        .DIE(di[4]), .DIF(di[5]), .DIG(di[6]), .DIH(di[7]),
        .WCLK(clk), .WE(we)
      );
    end
  end else if (DEPTH > 64 && DEPTH <= 96) begin : g_m96
    // Entries 0-63: RAM64M8 with 1-bit slots, as g_m64's one bank (slot s holds bit s % WIDTH of
    // read port s / WIDTH). Entries 64-95: RAM32M16 with 2-bit slots, as g_m32 (slot s holds bits
    // {2k+1, 2k} of read port s / SPP). A write goes to the bank its address bit 6 picks, a read
    // takes that bank's data; addresses 64-95 are 32 + bits [4:0].
    localparam int SLOTS_L = NR * WIDTH;
    localparam int NPRIM_L = (SLOTS_L + SLOTS_PER_PRIM - 1) / SLOTS_PER_PRIM;
    localparam int SPP     = (WIDTH + 1) / 2;
    localparam int SLOTS_H = NR * SPP;
    localparam int NPRIM_H = (SLOTS_H + SLOTS_PER_PRIM - 1) / SLOTS_PER_PRIM;
    localparam int WPAD    = 2 * SPP;

    logic            we_l, we_h;
    logic [4:0]      wa_h;
    logic [WPAD-1:0] wd_h;
    assign we_l = we && !waddr[6];
    assign we_h = we && waddr[6];
    assign wa_h = waddr[4:0];
    assign wd_h = WPAD'(wdata);

    logic [NR-1:0][WIDTH-1:0] rd_l;
    logic [NR-1:0][WPAD-1:0]  rd_h;

    for (genvar p = 0; p < NPRIM_L; p++) begin : g_lo
      logic [7:0][5:0] a;
      logic [7:0]      di;
      /* verilator lint_off UNUSEDSIGNAL */  // port H and unused slots are not read
      logic [7:0]      dout;
      /* verilator lint_on UNUSEDSIGNAL */
      for (genvar j = 0; j < SLOTS_PER_PRIM; j++) begin : g_slot
        localparam int S = p * SLOTS_PER_PRIM + j;
        if (S < SLOTS_L) begin : g_used
          localparam int R = S / WIDTH;
          localparam int K = S % WIDTH;
          assign a[j]  = raddr[R][5:0];
          assign di[j] = wdata[K];
          assign rd_l[R][K] = dout[j];
        end else begin : g_unused
          assign a[j]  = waddr[5:0];
          assign di[j] = 1'b0;
        end
      end
      assign a[7]  = waddr[5:0];
      assign di[7] = 1'b0;

      RAM64M8 #(
        .INIT_A(64'h0), .INIT_B(64'h0), .INIT_C(64'h0), .INIT_D(64'h0),
        .INIT_E(64'h0), .INIT_F(64'h0), .INIT_G(64'h0), .INIT_H(64'h0)
      ) u_ram (
        .DOA(dout[0]), .DOB(dout[1]), .DOC(dout[2]), .DOD(dout[3]),
        .DOE(dout[4]), .DOF(dout[5]), .DOG(dout[6]), .DOH(dout[7]),
        .ADDRA(a[0]), .ADDRB(a[1]), .ADDRC(a[2]), .ADDRD(a[3]),
        .ADDRE(a[4]), .ADDRF(a[5]), .ADDRG(a[6]), .ADDRH(a[7]),
        .DIA(di[0]), .DIB(di[1]), .DIC(di[2]), .DID(di[3]),
        .DIE(di[4]), .DIF(di[5]), .DIG(di[6]), .DIH(di[7]),
        .WCLK(clk), .WE(we_l)
      );
    end

    for (genvar p = 0; p < NPRIM_H; p++) begin : g_hi
      logic [7:0][4:0] a;
      logic [7:0][1:0] di;
      /* verilator lint_off UNUSEDSIGNAL */  // port H and unused slots are not read
      logic [7:0][1:0] dout;
      /* verilator lint_on UNUSEDSIGNAL */
      for (genvar j = 0; j < SLOTS_PER_PRIM; j++) begin : g_slot
        localparam int S = p * SLOTS_PER_PRIM + j;
        if (S < SLOTS_H) begin : g_used
          localparam int R = S / SPP;
          localparam int K = S % SPP;
          assign a[j]  = raddr[R][4:0];
          assign di[j] = wd_h[2*K +: 2];
          assign rd_h[R][2*K +: 2] = dout[j];
        end else begin : g_unused
          assign a[j]  = wa_h;
          assign di[j] = 2'b00;
        end
      end
      assign a[7]  = wa_h;
      assign di[7] = 2'b00;

      RAM32M16 #(
        .INIT_A(64'h0), .INIT_B(64'h0), .INIT_C(64'h0), .INIT_D(64'h0),
        .INIT_E(64'h0), .INIT_F(64'h0), .INIT_G(64'h0), .INIT_H(64'h0)
      ) u_ram (
        .DOA(dout[0]), .DOB(dout[1]), .DOC(dout[2]), .DOD(dout[3]),
        .DOE(dout[4]), .DOF(dout[5]), .DOG(dout[6]), .DOH(dout[7]),
        .ADDRA(a[0]), .ADDRB(a[1]), .ADDRC(a[2]), .ADDRD(a[3]),
        .ADDRE(a[4]), .ADDRF(a[5]), .ADDRG(a[6]), .ADDRH(a[7]),
        .DIA(di[0]), .DIB(di[1]), .DIC(di[2]), .DID(di[3]),
        .DIE(di[4]), .DIF(di[5]), .DIG(di[6]), .DIH(di[7]),
        .WCLK(clk), .WE(we_h)
      );
    end

    for (genvar r = 0; r < NR; r++) begin : g_rd
      assign rdata[r] = raddr[r][6] ? rd_h[r][WIDTH-1:0] : rd_l[r];
    end
  end else begin : g_m64
    // RAM64M8: 1-bit slots. Slot s holds bit s % WIDTH of read port s / WIDTH.
    // Banks of 64 entries are selected by address bits [AW-1:6].
    localparam int NBANK = 1 << (AW - 6);
    localparam int SLOTS = NR * WIDTH;
    localparam int NPRIM = (SLOTS + SLOTS_PER_PRIM - 1) / SLOTS_PER_PRIM;

    logic [NBANK-1:0][NR-1:0][WIDTH-1:0] rd;

    for (genvar b = 0; b < NBANK; b++) begin : g_bank
      logic web;
      if (NBANK > 1) begin : g_sel
        assign web = we && (waddr[AW-1:6] == (AW-6)'(b));
      end else begin : g_one
        assign web = we;
      end

      for (genvar p = 0; p < NPRIM; p++) begin : g_prim
        logic [7:0][5:0] a;
        logic [7:0]      di;
        /* verilator lint_off UNUSEDSIGNAL */  // port H and unused slots are not read
        logic [7:0]      dout;
        /* verilator lint_on UNUSEDSIGNAL */
        for (genvar j = 0; j < SLOTS_PER_PRIM; j++) begin : g_slot
          localparam int S = p * SLOTS_PER_PRIM + j;
          if (S < SLOTS) begin : g_used
            localparam int R = S / WIDTH;
            localparam int K = S % WIDTH;
            assign a[j]  = raddr[R][5:0];
            assign di[j] = wdata[K];
            assign rd[b][R][K] = dout[j];
          end else begin : g_unused
            assign a[j]  = waddr[5:0];
            assign di[j] = 1'b0;
          end
        end
        assign a[7]  = waddr[5:0];
        assign di[7] = 1'b0;

        RAM64M8 #(
          .INIT_A(64'h0), .INIT_B(64'h0), .INIT_C(64'h0), .INIT_D(64'h0),
          .INIT_E(64'h0), .INIT_F(64'h0), .INIT_G(64'h0), .INIT_H(64'h0)
        ) u_ram (
          .DOA(dout[0]), .DOB(dout[1]), .DOC(dout[2]), .DOD(dout[3]),
          .DOE(dout[4]), .DOF(dout[5]), .DOG(dout[6]), .DOH(dout[7]),
          .ADDRA(a[0]), .ADDRB(a[1]), .ADDRC(a[2]), .ADDRD(a[3]),
          .ADDRE(a[4]), .ADDRF(a[5]), .ADDRG(a[6]), .ADDRH(a[7]),
          .DIA(di[0]), .DIB(di[1]), .DIC(di[2]), .DID(di[3]),
          .DIE(di[4]), .DIF(di[5]), .DIG(di[6]), .DIH(di[7]),
          .WCLK(clk), .WE(web)
        );
      end
    end

    for (genvar r = 0; r < NR; r++) begin : g_rd
      if (NBANK > 1) begin : g_mux
        assign rdata[r] = rd[raddr[r][AW-1:6]][r];
      end else begin : g_one
        assign rdata[r] = rd[0][r];
      end
    end
  end
`else
  // Behavioural model (simulation).
  logic [WIDTH-1:0] mem [DEPTH];

  always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
  end

  for (genvar r = 0; r < NR; r++) begin : g_rd
    assign rdata[r] = mem[raddr[r]];
  end
`endif
endmodule
