// Spike S4: the load path AG -> M1 -> M2 with 3-cycle load-to-use (plan §4.9, §4.11),
// registered inputs and outputs.
//   AG: base operand through a bypass mux, + sign-extended offset (CARRY8); VA[11:3]
//       goes straight to the address of the eight data ways (VIPT, index inside the page).
//   M1: data ways read (one RAMB36 per way, 512 x 64 simple dual port: port A reads for
//       loads, port B writes refills and stores); LUTRAM tags read at VA[11:6]; DTLB
//       lookup. ALIGN_M1 = 1 aligns and extends every way's word in M1, from the raw
//       BRAM outputs; ALIGN_M1 = 0 registers the raw words and aligns in M2.
//   M2: tag compare against the DTLB's physical page, way select, (align,) result
//       register; a miss raises the shadow cancel.
// Data ways: tg_ram_sdp (XPM). Tags: one tg_ram_lut per way, 64 sets x (2 state + tag
// bits), 2 read ports (loads, probes/refills).
module tg_s4_top
  import tg_pkg::*;
#(
  parameter bit ALIGN_M1 = 1'b1,
  localparam int WAYS  = L1_WAYS,
  localparam int SETS  = (L1D_KIB * 1024) / (WAYS * 64),
  localparam int SET_W = idx_w(SETS),
  localparam int WAY_W = idx_w(WAYS),
  localparam int PPN_W = PA_W - 12,
  localparam int TAG_W = PPN_W + 2,     // {state, physical page}; state 0 = invalid
  localparam int EW    = idx_w(DTLB_ENTRIES)
) (
  input  logic                  clk,
  input  logic                  rst_i,
  // AG inputs (from the issue/RF stage)
  input  logic                  ld_valid_i,
  input  logic [1:0]            base_sel_i,      // 0: RF, 1/2: ALU0/ALU1 result, 3: load result
  input  logic [3:0][63:0]      base_src_i,
  input  logic [11:0]           offset_i,
  input  logic [1:0]            size_i,          // log2 bytes
  input  logic                  unsigned_i,
  input  tid_t                  tid_i,
  input  logic [15:0]           asid_i,
  // Refill and store writes (port B), tag writes, probes
  input  logic [7:0]            dwe_i,
  input  logic [WAY_W-1:0]      dway_i,
  input  logic [8:0]            daddr_i,
  input  logic [63:0]           ddata_i,
  input  logic                  twe_i,
  input  logic [WAY_W-1:0]      tway_i,
  input  logic [SET_W-1:0]      tset_i,
  input  logic [TAG_W-1:0]      ttag_i,
  input  logic [SET_W-1:0]      probe_set_i,
  // DTLB fill and flush
  input  logic                  tf_valid_i,
  input  logic [EW-1:0]         tf_idx_i,
  input  logic [38:12]          tf_vpn_i,
  input  logic [1:0]            tf_lvl_i,
  input  logic                  tf_g_i,
  input  logic [PPN_W-1:0]      tf_ppn_i,
  input  logic                  tfl_valid_i,
  // Results (M2 output registers)
  output logic                  ld_valid_o,
  output logic                  ld_hit_o,
  output logic                  ld_cancel_o,
  output logic [63:0]           ld_data_o,
  output logic [WAYS-1:0][TAG_W-1:0] probe_tags_o
);
  // ---- Input registers ----
  logic                  rst, ag_valid_q, ag_unsigned_q;
  logic [1:0]            ag_sel_q, ag_size_q;
  logic [3:0][63:0]      ag_src_q;
  logic [11:0]           ag_off_q;
  tid_t                  ag_tid_q;
  logic [15:0]           ag_asid_q;
  logic [7:0]            dwe_q;
  logic [WAY_W-1:0]      dway_q, tway_q;
  logic [8:0]            daddr_q;
  logic [63:0]           ddata_q;
  logic                  twe_q, tf_valid_q, tf_g_q, tfl_valid_q;
  logic [SET_W-1:0]      tset_q, probe_set_q;
  logic [TAG_W-1:0]      ttag_q;
  logic [EW-1:0]         tf_idx_q;
  logic [38:12]          tf_vpn_q;
  logic [1:0]            tf_lvl_q;
  logic [PPN_W-1:0]      tf_ppn_q;
  always_ff @(posedge clk) begin
    rst <= rst_i;
    ag_valid_q <= ld_valid_i; ag_sel_q <= base_sel_i; ag_src_q <= base_src_i;
    ag_off_q <= offset_i; ag_size_q <= size_i; ag_unsigned_q <= unsigned_i;
    ag_tid_q <= tid_i; ag_asid_q <= asid_i;
    dwe_q <= dwe_i; dway_q <= dway_i; daddr_q <= daddr_i; ddata_q <= ddata_i;
    twe_q <= twe_i; tway_q <= tway_i; tset_q <= tset_i; ttag_q <= ttag_i;
    probe_set_q <= probe_set_i;
    tf_valid_q <= tf_valid_i; tf_idx_q <= tf_idx_i; tf_vpn_q <= tf_vpn_i;
    tf_lvl_q <= tf_lvl_i; tf_g_q <= tf_g_i; tf_ppn_q <= tf_ppn_i; tfl_valid_q <= tfl_valid_i;
  end

  // ---- AG ----
  logic [63:0] base, va;
  assign base = ag_src_q[ag_sel_q];
  assign va   = base + {{52{ag_off_q[11]}}, ag_off_q};

  logic        m1_valid_q, m1_unsigned_q;
  logic [63:0] m1_va_q;
  logic [1:0]  m1_size_q;
  tid_t        m1_tid_q;
  logic [15:0] m1_asid_q;
  always_ff @(posedge clk) begin
    if (rst) m1_valid_q <= 1'b0;
    else     m1_valid_q <= ag_valid_q;
    m1_va_q <= va; m1_size_q <= ag_size_q; m1_unsigned_q <= ag_unsigned_q;
    m1_tid_q <= ag_tid_q; m1_asid_q <= ag_asid_q;
  end

  // ---- Data ways: read address is the AG adder's VA[11:3] (registered inside the BRAM) ----
  logic [WAYS-1:0][63:0] way_data;
  for (genvar w = 0; w < WAYS; w++) begin : g_way
    tg_ram_sdp #(.DEPTH(512), .WIDTH(64), .BYTE_W(8), .OUT_REG(1'b0), .PRIM("block")) u_data (
      .clk, .we(dwe_q & {8{dway_q == WAY_W'(w)}}), .waddr(daddr_q), .wdata(ddata_q),
      .re(ag_valid_q), .raddr(va[11:3]), .rdata(way_data[w]));
  end

  // ---- Tags: one LUTRAM per way, read at VA[11:6] in M1 (loads) and for probes ----
  logic [WAYS-1:0][1:0][TAG_W-1:0] tag_rd;
  for (genvar w = 0; w < WAYS; w++) begin : g_tag
    logic [1:0][SET_W-1:0] ra;
    assign ra[0] = m1_va_q[6 +: SET_W];
    assign ra[1] = probe_set_q;
    tg_ram_lut #(.DEPTH(SETS), .WIDTH(TAG_W), .NR(2)) u_tag (
      .clk, .we(twe_q && tway_q == WAY_W'(w)), .waddr(tset_q), .wdata(ttag_q), .raddr(ra),
      .rdata(tag_rd[w]));
  end

  // ---- DTLB in M1 ----
  logic             tlb_hit;
  logic [PPN_W-1:0] tlb_ppn;
  logic [5:0]       tlb_perm;
  tg_dtlb #(.NE(DTLB_ENTRIES)) u_dtlb (
    .clk, .rst, .tid(m1_tid_q), .asid(m1_asid_q), .vpn(m1_va_q[38:12]),
    .hit(tlb_hit), .ppn(tlb_ppn), .perm(tlb_perm),
    .fill_valid(tf_valid_q), .fill_idx(tf_idx_q), .fill_tid(ag_tid_q), .fill_asid(ag_asid_q),
    .fill_vpn(tf_vpn_q), .fill_lvl(tf_lvl_q), .fill_g(tf_g_q), .fill_ppn(tf_ppn_q),
    .fill_perm(6'b111111), .flush_valid(tfl_valid_q), .flush_tid(ag_tid_q),
    .flush_all(1'b1), .flush_asid(ag_asid_q));

  // Align a 64-bit word to the access: shift right by the byte offset, then extend.
  function automatic logic [63:0] align(input logic [63:0] d, input logic [2:0] off,
                                        input logic [1:0] size, input logic uns);
    logic [63:0] s;
    s = d >> {off, 3'b0};
    unique case (size)
      2'd0:    return {{56{!uns && s[7]}},  s[7:0]};
      2'd1:    return {{48{!uns && s[15]}}, s[15:0]};
      2'd2:    return {{32{!uns && s[31]}}, s[31:0]};
      default: return s;
    endcase
  endfunction

  // ---- M1 -> M2 registers ----
  logic                         m2_valid_q, m2_tlb_hit_q, m2_unsigned_q;
  logic [PPN_W-1:0]             m2_ppn_q;
  logic [WAYS-1:0][TAG_W-1:0]   m2_tag_q;
  logic [WAYS-1:0][63:0]        m2_data_q;
  logic [2:0]                   m2_off_q;
  logic [1:0]                   m2_size_q;
  always_ff @(posedge clk) begin
    if (rst) m2_valid_q <= 1'b0;
    else     m2_valid_q <= m1_valid_q;
    m2_tlb_hit_q <= tlb_hit && tlb_perm[0];
    m2_ppn_q     <= tlb_ppn;
    m2_off_q     <= m1_va_q[2:0];
    m2_size_q    <= m1_size_q;
    m2_unsigned_q <= m1_unsigned_q;
    for (int w = 0; w < WAYS; w++) begin
      m2_tag_q[w]  <= tag_rd[w][0];
      m2_data_q[w] <= ALIGN_M1 ? align(way_data[w], m1_va_q[2:0], m1_size_q, m1_unsigned_q)
                               : way_data[w];
    end
  end

  // ---- M2: compare, way select (, align) ----
  logic [WAYS-1:0] way_hit;
  logic [63:0]     sel;
  for (genvar w = 0; w < WAYS; w++) begin : g_hit
    assign way_hit[w] = m2_tag_q[w][TAG_W-1 -: 2] != 2'b00 && m2_tag_q[w][PPN_W-1:0] == m2_ppn_q;
  end
  always_comb begin
    sel = '0;
    for (int w = 0; w < WAYS; w++) sel |= {64{way_hit[w]}} & m2_data_q[w];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ld_valid_o  <= 1'b0;
      ld_hit_o    <= 1'b0;
      ld_cancel_o <= 1'b0;
    end else begin
      ld_valid_o  <= m2_valid_q;
      ld_hit_o    <= m2_valid_q && m2_tlb_hit_q && |way_hit;
      ld_cancel_o <= m2_valid_q && !(m2_tlb_hit_q && |way_hit);
    end
    ld_data_o <= ALIGN_M1 ? sel : align(sel, m2_off_q, m2_size_q, m2_unsigned_q);
    for (int w = 0; w < WAYS; w++) probe_tags_o[w] <= tag_rd[w][1];
  end

  logic unused;
  assign unused = ^{tlb_perm[5:1], m1_va_q[63:39], m1_va_q[5:3]};
endmodule
