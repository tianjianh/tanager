// Commit-trace ring (docs/spec/host.md §Trace ring): keeps the last DEPTH commit records of one
// selected core in block RAM for the host to read back (post-mortem debugging on the board).
// Up to COMMIT_WIDTH records per cycle are kept: the core's retire records first, then deferred
// writebacks in the slots left; anything beyond is counted as lost. Records are 320 bits:
//   [31:0] header, [63:32] insn, [127:64] pc, [191:128] value (rd value; cause for traps and
//   interrupts; the value of a writeback), [255:192] address (store vaddr; tval for traps),
//   [319:256] store data.
// Header: [1:0] kind (0 retire, 1 trap, 2 irq, 3 deferred writeback), [3:2] hart, [5:4] priv, [6] rvc,
//   [7] rd_we, [8] rd_fp, [13:9] rd, [14] rd_deferred, [19:15] wb_tag, [20] mem_st, [22:21] mem_size,
//   [23] mmio_ld, [24] nondet.
// Capture runs while enabled; with the trigger armed it stops POST records after the first record
// whose pc equals trig_pc. Storage: COMMIT_WIDTH banks of BANK_DEPTH rows; record n sits in bank
// n % COMMIT_WIDTH, row (n / COMMIT_WIDTH) % BANK_DEPTH, so DEPTH = BANK_DEPTH * COMMIT_WIDTH.
module tg_trace_ring
  import tg_pkg::*, tg_trace_pkg::*;
#(
  parameter int N_CORES    = NUM_CORES,
  parameter int BANK_DEPTH = 512         // rows per bank, a power of two; DEPTH = BANK_DEPTH * COMMIT_WIDTH
) (
  input  logic                                        clk,
  input  logic                                        rst,
  input  tr_rec_t [N_CORES-1:0][COMMIT_WIDTH-1:0]     trace_i,
  input  logic    [N_CORES-1:0][COMMIT_WIDTH-1:0]     trace_valid_i,
  input  tr_wb_t  [N_CORES-1:0][TRACE_WB_PORTS-1:0]   trace_wb_i,
  input  logic    [N_CORES-1:0][TRACE_WB_PORTS-1:0]   trace_wb_valid_i,
  // control (quasi-static, from the host)
  input  logic                                        enable_i,
  input  logic [1:0]                                  core_sel_i,
  input  logic                                        trig_arm_i,
  input  logic [63:0]                                 trig_pc_i,
  input  logic [15:0]                                 post_i,
  input  logic [15:0]                                 rd_idx_i,     // record to present on rd_rec_o
  // status
  output logic [31:0]                                 count_o,      // records written since enable
  output logic [31:0]                                 lost_o,
  output logic                                        frozen_o,     // stopped by the trigger
  output logic [15:0]                                 rd_idx_o,     // index rd_rec_o shows
  output logic [319:0]                                rd_rec_o
);
  localparam int CW  = COMMIT_WIDTH;
  localparam int NS  = CW + TRACE_WB_PORTS;       // candidate records per cycle
  localparam int BD  = BANK_DEPTH;
  localparam int BAW = idx_w(BD);
  localparam int KW  = idx_w(CW);

  if ((BD & (BD - 1)) != 0) begin : g_bad_depth
    $error("tg_trace_ring: BANK_DEPTH must be a power of two");
  end

  function automatic logic [319:0] pack_rec(input tr_rec_t r);
    logic [319:0] x;
    x = '0;
    x[1:0]   = r.kind;
    x[3:2]   = 2'(r.hart);
    x[5:4]   = r.priv;
    x[6]     = r.rvc;
    x[7]     = r.rd_we;
    x[8]     = r.rd_fp;
    x[13:9]  = r.rd;
    x[14]    = r.rd_deferred;
    x[19:15] = 5'(r.wb_tag);
    x[20]    = r.mem_st;
    x[22:21] = r.mem_size;
    x[23]    = r.mmio_ld;
    x[24]    = r.nondet;
    x[63:32] = r.insn;
    x[127:64] = r.pc;
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

  // ---- candidates of the selected core, retire records first ----
  logic [NS-1:0]        cv;
  logic [NS-1:0][319:0] cd;
  always_comb begin
    cv = '0;
    cd = '0;
    for (int c = 0; c < N_CORES; c++)
      if (int'(core_sel_i) == c) begin
        for (int k = 0; k < CW; k++) begin
          cv[k] = trace_valid_i[c][k];
          cd[k] = pack_rec(trace_i[c][k]);
        end
        for (int k = 0; k < TRACE_WB_PORTS; k++) begin
          cv[CW + k] = trace_wb_valid_i[c][k];
          cd[CW + k] = pack_wb(trace_wb_i[c][k]);
        end
      end
  end

  // ---- compaction: the first CW valid candidates, in order ----
  logic [CW-1:0]        sv;
  logic [CW-1:0][319:0] sd;
  logic [7:0]           n_valid;
  always_comb begin
    int n;
    sv = '0;
    sd = '0;
    n  = 0;
    for (int k = 0; k < NS; k++)
      if (cv[k]) begin
        if (n < CW) begin
          sv[n] = 1'b1;
          sd[n] = cd[k];
        end
        n++;
      end
    n_valid = 8'(n);
  end

  // ---- capture control ----
  logic          run_q, frozen_q, trig_seen_q;
  logic [15:0]   post_left_q;
  logic [KW-1:0] bank_q;                    // bank of the next record
  logic [BAW-1:0] row_q;                    // its row
  logic [31:0]   count_q, lost_q;
  logic          en_q;

  wire capture = run_q && !frozen_q;
  logic hit;
  always_comb begin
    hit = 1'b0;
    for (int k = 0; k < CW; k++)
      if (sv[k] && sd[k][1:0] != 2'd3 && sd[k][127:64] == trig_pc_i) hit = 1'b1;
  end

  // bank writes: record k of this cycle goes to bank (wp + k) % CW
  logic [CW-1:0]           bwe;
  logic [CW-1:0][BAW-1:0]  bwaddr;
  logic [CW-1:0][319:0]    bwdata;
  always_comb begin
    bwe    = '0;
    bwaddr = '0;
    bwdata = '0;
    for (int k = 0; k < CW; k++) begin
      int pos, b;
      pos = int'(bank_q) + k;              // < 2 * CW
      b   = (pos >= CW) ? pos - CW : pos;
      if (capture && sv[k]) begin
        bwe[b]    = 1'b1;
        bwaddr[b] = row_q + BAW'(pos >= CW);
        bwdata[b] = sd[k];
      end
    end
  end

  // ---- banks and the read port ----
  // Host reads (not timing critical): index -> (row, bank), registered, then one RAM cycle.
  logic [CW-1:0][319:0] brdata;
  logic [BAW-1:0] rrow_q;
  logic [KW-1:0]  rbank_q, rbank_qq;
  logic [15:0]    ridx_q, ridx_qq, ridx_qqq;
  always_ff @(posedge clk) begin
    rrow_q   <= BAW'(int'(rd_idx_i) / CW);
    rbank_q  <= KW'(int'(rd_idx_i) % CW);
    ridx_q   <= rd_idx_i;
    rbank_qq <= rbank_q;
    ridx_qq  <= ridx_q;
    ridx_qqq <= ridx_qq;
    rd_rec_o <= brdata[rbank_qq];
  end
  for (genvar b = 0; b < CW; b++) begin : g_bank
    tg_ram_sdp #(.DEPTH (BD), .WIDTH (320), .OUT_REG (1'b0), .PRIM ("block")) u_bank (
      .clk, .we (bwe[b]), .waddr (bwaddr[b]), .wdata (bwdata[b]),
      .re (1'b1), .raddr (rrow_q), .rdata (brdata[b])
    );
  end
  assign rd_idx_o = ridx_qqq;

  always_ff @(posedge clk) begin
    if (rst) begin
      run_q       <= 1'b0;
      frozen_q    <= 1'b0;
      trig_seen_q <= 1'b0;
      post_left_q <= '0;
      bank_q      <= '0;
      row_q       <= '0;
      count_q     <= '0;
      lost_q      <= '0;
      en_q        <= 1'b0;
    end else begin
      en_q <= enable_i;
      if (enable_i && !en_q) begin            // a new capture: clear
        run_q       <= 1'b1;
        frozen_q    <= 1'b0;
        trig_seen_q <= 1'b0;
        bank_q      <= '0;
        row_q       <= '0;
        count_q     <= '0;
        lost_q      <= '0;
      end else if (!enable_i) begin
        run_q <= 1'b0;
      end else if (capture) begin
        int n;
        n = 0;
        for (int k = 0; k < CW; k++) if (sv[k]) n++;
        begin
          int pos;
          pos = int'(bank_q) + n;
          bank_q <= KW'((pos >= CW) ? pos - CW : pos);
          row_q  <= row_q + BAW'(pos >= CW);
        end
        count_q <= count_q + 32'(n);
        if (n_valid > 8'(CW)) lost_q <= lost_q + 32'(n_valid - 8'(CW));
        if (trig_arm_i) begin
          if (!trig_seen_q && hit) begin
            trig_seen_q <= 1'b1;
            post_left_q <= post_i;
            if (post_i == '0) frozen_q <= 1'b1;
          end else if (trig_seen_q) begin
            if (post_left_q <= 16'(n)) frozen_q <= 1'b1;
            else post_left_q <= post_left_q - 16'(n);
          end
        end
      end
    end
  end

  assign count_o  = count_q;
  assign lost_o   = lost_q;
  assign frozen_o = frozen_q;
endmodule
