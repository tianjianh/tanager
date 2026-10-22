// The coherent host DMA port (docs/spec/soc.md §8.1, DR-147 stage C): an AXI4 slave for the PS's
// M_AXI_HPM1_FPD (128-bit, on clk) that turns the A53's reads and writes of the RISC-V's memory into
// TileLink-UH messages on the crossbar's hdma initiator, so that the L2 serves them coherently: a read
// sees the cores' dirty lines (the L2 probes the owner first), and a write's B comes only after the
// L2's AccessAck, which follows the invalidation of every L1 copy.
//   - The window: AXI address bits [31:0] are an offset into the RISC-V's RAM (DRAM_BASE + offset)
//     below ram_size_i, the host's DRAM_SIZE. A read beat beyond it answers DECERR, and a write beat
//     there is dropped; neither is forwarded. Only INCR bursts: FIXED and WRAP read SLVERR on every
//     beat, and write nothing.
//   - A read takes each 64-byte line its burst touches with one Get of the line and returns its
//     beats from the AccessAckData in order; a narrow beat carries its 16-byte lane.
//   - A write gathers each line's beats in a line buffer, by byte strobe, then sends the line as one
//     PutFullData (every byte written) or PutPartialData (size 6, with the masks) and waits for its
//     AccessAck before it takes the next line's beats. B follows the last line's AccessAck, always OKAY:
//     on the A53 an error on a posted write is an asynchronous SError, which panics its Linux (the
//     Cortex-A53 has no RAS extension). A write burst that was not done in full (a beat outside the
//     window, a denied line, not INCR) counts in wr_drops_o instead, for the host to check. Reads keep
//     their error responses, which the A53 takes as a synchronous abort (SIGBUS to the reader).
//   - A read and a write run at the same time, one burst each, each with one message in flight; the
//     AXI responses are in order. The A channel goes to a Put's later beats first, then to a Get.
//   - Every write line's AccessAck is a completion, {line, cycle}: the line's offset / 64 and the
//     count of clk cycles since the uncore reset, the clock of the trace stream's capture stamps, for
//     lockstep's external writes (docs/spec/verification.md §3.10). While cpl_en_i is set, the
//     AccessAck waits for room in the completion queue (cpl_ready_i).
//   - Release builds (DR-180) leave out the line counters (STATS = 0: rd_lines_o and wr_lines_o read 0) and,
//     without the trace, the completions (CPL = 0: cpl_valid_o stays 0 and cpl_en_i is ignored).
module tg_hdma
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;
#(
  parameter int ID_W  = 16,
  parameter bit CPL   = 1'b1,                   // the completions (lockstep's external writes)
  parameter bit STATS = 1'b1                    // the line counters rd_lines_o and wr_lines_o
) (
  input  logic            clk,
  input  logic            rst,
  // ---- AXI4 slave (128-bit) ----
  input  logic [ID_W-1:0] s_awid,
  input  logic [39:0]     s_awaddr,
  input  logic [7:0]      s_awlen,
  input  logic [2:0]      s_awsize,
  input  logic [1:0]      s_awburst,
  input  logic            s_awvalid,
  output logic            s_awready,
  input  logic [127:0]    s_wdata,
  input  logic [15:0]     s_wstrb,
  input  logic            s_wlast,
  input  logic            s_wvalid,
  output logic            s_wready,
  output logic [ID_W-1:0] s_bid,
  output logic [1:0]      s_bresp,
  output logic            s_bvalid,
  input  logic            s_bready,
  input  logic [ID_W-1:0] s_arid,
  input  logic [39:0]     s_araddr,
  input  logic [7:0]      s_arlen,
  input  logic [2:0]      s_arsize,
  input  logic [1:0]      s_arburst,
  input  logic            s_arvalid,
  output logic            s_arready,
  output logic [ID_W-1:0] s_rid,
  output logic [127:0]    s_rdata,
  output logic [1:0]      s_rresp,
  output logic            s_rlast,
  output logic            s_rvalid,
  input  logic            s_rready,
  // ---- the RISC-V RAM the window covers (bytes, a multiple of 64) ----
  input  logic [39:0]     ram_size_i,
  // ---- TileLink-UH toward the crossbar's hdma initiator ----
  output tl_a_t           a_o,
  output logic            a_valid_o,
  input  logic            a_ready_i,
  input  tl_d_t           d_i,
  input  logic            d_valid_i,
  output logic            d_ready_o,
  // ---- completions: one per write line's AccessAck ----
  input  logic            cpl_en_i,
  output logic            cpl_valid_o,
  output logic [25:0]     cpl_line_o,
  output logic [31:0]     cpl_cycle_o,
  input  logic            cpl_ready_i,
  // ---- statistics: lines read (Gets) and written (Puts); write bursts not done in full; wrapping ----
  output logic [31:0]     rd_lines_o,
  output logic [31:0]     wr_lines_o,
  output logic [31:0]     wr_drops_o
);
  localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10, DECERR = 2'b11;

  // the next beat's offset in an INCR burst: aligned to the beat size, then one beat on
  function automatic logic [31:0] next_beat(input logic [31:0] a, input logic [2:0] size);
    logic [31:0] m;
    m = (32'd1 << size) - 32'd1;
    return (a & ~m) + (32'd1 << size);
  endfunction
  function automatic logic in_window(input logic [25:0] line, input logic [39:0] size);
    return {8'd0, line, 6'd0} < size;
  endfunction

  logic [31:0] cycle_q;                         // the trace stream's count: clk cycles since the uncore reset
  always_ff @(posedge clk) begin
    if (rst || !CPL) cycle_q <= '0;
    else             cycle_q <= cycle_q + 32'd1;
  end

  // =============================================================================================
  // Read engine: one burst; per line one Get, its four AccessAckData beats returned in order
  // =============================================================================================
  typedef enum logic [1:0] { R_IDLE, R_GET, R_DATA, R_ERR } rstate_e;
  rstate_e         rs_q;
  logic [ID_W-1:0] rid_q;
  logic [31:0]     raddr_q;                     // the next R beat's offset
  logic [2:0]      rsize_q;
  logic [8:0]      rleft_q;                     // beats still to return
  logic            rbad_q;                      // not INCR
  logic [1:0]      rbeat_q;                     // the AccessAckData beat expected next
  logic [25:0]     rline_q;                     // the line of the Get
  logic [31:0]     rlines_q;

  wire        r_d     = d_valid_i && !d_i.source[0];
  wire [31:0] r_next  = next_beat(raddr_q, rsize_q);
  // the R beat sits in the AccessAckData beat on offer
  wire        r_need  = rleft_q != 9'd0 && raddr_q[31:6] == rline_q && raddr_q[5:4] == rbeat_q;
  // this R beat is the last one that beat carries
  wire        r_chunk_end = rleft_q == 9'd1 || r_next[31:4] != raddr_q[31:4];
  wire        r_get   = rs_q == R_GET && !rbad_q && in_window(raddr_q[31:6], ram_size_i);
  logic       r_a_go;                           // the Get is taken

  always_comb begin
    s_arready = rs_q == R_IDLE;
    s_rid     = rid_q;
    s_rdata   = '0;
    s_rresp   = OKAY;
    s_rlast   = rleft_q == 9'd1;
    s_rvalid  = 1'b0;
    if (rs_q == R_DATA) begin
      s_rvalid = r_d && r_need;
      s_rdata  = d_i.data;
      s_rresp  = d_i.denied ? SLVERR : OKAY;
    end else if (rs_q == R_ERR) begin
      s_rvalid = 1'b1;
      s_rresp  = rbad_q ? SLVERR : DECERR;
    end
  end
  // an AccessAckData beat is taken once no R beat needs it any more
  wire r_d_ready = rs_q == R_DATA && (!r_need || (s_rready && r_chunk_end));

  always_ff @(posedge clk) begin
    if (rst) begin
      rs_q     <= R_IDLE;
      rlines_q <= '0;
    end else begin
      unique case (rs_q)
        R_IDLE: if (s_arvalid) begin
          rid_q   <= s_arid;
          raddr_q <= s_araddr[31:0];
          rsize_q <= (s_arsize > 3'd4) ? 3'd4 : s_arsize;
          rleft_q <= {1'b0, s_arlen} + 9'd1;
          rbad_q  <= s_arburst != AXI_INCR;
          rs_q    <= R_GET;
        end
        R_GET: if (!r_get) begin
          rs_q <= R_ERR;                        // outside the window, or not INCR
        end else if (r_a_go) begin
          rline_q  <= raddr_q[31:6];
          rbeat_q  <= 2'd0;
          rlines_q <= rlines_q + 32'd1;
          rs_q     <= R_DATA;
        end
        R_DATA: begin
          if (s_rvalid && s_rready) begin
            raddr_q <= r_next;
            rleft_q <= rleft_q - 9'd1;
          end
          if (r_d && r_d_ready) begin
            rbeat_q <= rbeat_q + 2'd1;
            if (rbeat_q == 2'd3)
              rs_q <= (rleft_q == 9'd0 || (rleft_q == 9'd1 && s_rvalid && s_rready)) ? R_IDLE : R_GET;
          end
        end
        R_ERR: if (s_rready) begin
          raddr_q <= r_next;
          rleft_q <= rleft_q - 9'd1;
          if (rleft_q == 9'd1)                       rs_q <= R_IDLE;
          else if (!rbad_q && r_next[31:6] != raddr_q[31:6]) rs_q <= R_GET;
        end
        default: rs_q <= R_IDLE;
      endcase
    end
  end

  // =============================================================================================
  // Write engine: one burst; each line gathered, then sent as one Put whose AccessAck comes back
  // before the next line's beats are taken
  // =============================================================================================
  typedef enum logic [2:0] { W_IDLE, W_DATA, W_PUT, W_ACK, W_B } wstate_e;
  wstate_e         ws_q;
  logic [ID_W-1:0] wid_q;
  logic [31:0]     waddr_q;                     // the next W beat's offset
  logic [2:0]      wsize_q;
  logic            wbad_q, wdec_q, wslv_q;      // not INCR; a beat outside the window; a line denied
  logic [25:0]     wline_q;                     // the line being gathered
  logic            wlast_q;                     // it holds the burst's last beat
  logic [1:0]      pbeat_q;                     // the Put's beat on offer
  logic [127:0]    buf_q [4];
  logic [15:0]     msk_q [4];
  logic [31:0]     wlines_q, wdrops_q;

  wire        w_d    = d_valid_i && d_i.source[0];
  wire [31:0] w_next = next_beat(waddr_q, wsize_q);
  // the line ends with this beat: the burst's last, or the next beat is in another line
  wire        w_end  = s_wlast || w_next[31:6] != wline_q;
  // the gathered line with this beat's strobes: is any byte written?
  logic       w_any;
  always_comb begin
    w_any = 1'b0;
    for (int k = 0; k < 4; k++) w_any |= |msk_q[k] || (waddr_q[5:4] == 2'(k) && |s_wstrb);
  end
  wire        w_send = !wbad_q && in_window(wline_q, ram_size_i) && w_any;
  wire        w_full = &{msk_q[0], msk_q[1], msk_q[2], msk_q[3]};
  logic       w_a_go;                           // a Put beat is taken
  wire        w_d_ready = ws_q == W_ACK && (!(CPL && cpl_en_i) || cpl_ready_i);

  assign s_awready = ws_q == W_IDLE;
  assign s_wready  = ws_q == W_DATA;
  assign s_bvalid  = ws_q == W_B;
  assign s_bid     = wid_q;
  assign s_bresp   = OKAY;

  always_ff @(posedge clk) begin
    if (rst) begin
      ws_q     <= W_IDLE;
      wlines_q <= '0;
      wdrops_q <= '0;
    end else begin
      unique case (ws_q)
        W_IDLE: if (s_awvalid) begin
          wid_q   <= s_awid;
          waddr_q <= s_awaddr[31:0];
          wsize_q <= (s_awsize > 3'd4) ? 3'd4 : s_awsize;
          wbad_q  <= s_awburst != AXI_INCR;
          wdec_q  <= 1'b0;
          wslv_q  <= 1'b0;
          wline_q <= s_awaddr[31:6];
          for (int k = 0; k < 4; k++) msk_q[k] <= '0;
          ws_q    <= W_DATA;
        end
        W_DATA: if (s_wvalid) begin
          for (int b = 0; b < 16; b++)
            if (s_wstrb[b]) buf_q[waddr_q[5:4]][8*b +: 8] <= s_wdata[8*b +: 8];
          msk_q[waddr_q[5:4]] <= msk_q[waddr_q[5:4]] | s_wstrb;
          waddr_q <= w_next;
          if (!wbad_q && !in_window(wline_q, ram_size_i)) wdec_q <= 1'b1;
          if (w_end) begin
            wlast_q <= s_wlast;
            pbeat_q <= 2'd0;
            if (w_send) begin
              ws_q <= W_PUT;
            end else if (s_wlast) begin
              ws_q <= W_B;
            end else begin
              wline_q <= w_next[31:6];
              for (int k = 0; k < 4; k++) msk_q[k] <= '0;
            end
          end
        end
        W_PUT: if (w_a_go) begin
          pbeat_q <= pbeat_q + 2'd1;
          if (pbeat_q == 2'd3) begin
            wlines_q <= wlines_q + 32'd1;
            ws_q     <= W_ACK;
          end
        end
        W_ACK: if (w_d && w_d_ready) begin
          if (d_i.denied) wslv_q <= 1'b1;
          if (wlast_q) begin
            ws_q <= W_B;
          end else begin
            wline_q <= waddr_q[31:6];
            for (int k = 0; k < 4; k++) msk_q[k] <= '0;
            ws_q    <= W_DATA;
          end
        end
        W_B: if (s_bready) begin
          ws_q <= W_IDLE;
          if (wbad_q || wslv_q || wdec_q) wdrops_q <= wdrops_q + 32'd1;
        end
        default: ws_q <= W_IDLE;
      endcase
    end
  end

  assign cpl_valid_o = CPL && ws_q == W_ACK && w_d && cpl_en_i;
  assign cpl_line_o  = wline_q;
  assign cpl_cycle_o = cycle_q;

  // =============================================================================================
  // The A channel: a Get before a Put that has not started. A message on offer keeps the channel
  // until its last beat is taken, so a beat never changes before its handshake and a Put's beats
  // stay together. D goes back by source[0]: 0 the read engine, 1 the write engine.
  // =============================================================================================
  wire  w_req = ws_q == W_PUT;
  logic a_busy_q, a_w_q;                        // a message holds the channel; it is the Put
  wire  pick_w = a_busy_q ? a_w_q : (w_req && !r_get);
  assign r_a_go = !pick_w && r_get && a_ready_i;
  assign w_a_go = pick_w && w_req && a_ready_i;
  always_ff @(posedge clk) begin
    if (rst) begin
      a_busy_q <= 1'b0;
    end else if (a_valid_o) begin
      if (a_ready_i && (!pick_w || pbeat_q == 2'd3)) begin
        a_busy_q <= 1'b0;                       // the message's last beat is taken
      end else begin
        a_busy_q <= 1'b1;
        a_w_q    <= pick_w;
      end
    end
  end

  always_comb begin
    a_o         = '0;
    a_o.size    = 3'd6;
    a_o.mask    = '1;
    a_valid_o   = pick_w ? w_req : r_get;
    if (pick_w) begin
      a_o.opcode  = w_full ? A_PUT_FULL : A_PUT_PARTIAL;
      a_o.source  = TL_SRC_W'(1);
      a_o.address = TL_ADDR_W'(DRAM_BASE) + TL_ADDR_W'({wline_q, 6'd0});
      a_o.mask    = msk_q[pbeat_q];
      a_o.data    = buf_q[pbeat_q];
    end else begin
      a_o.opcode  = A_GET;
      a_o.source  = TL_SRC_W'(0);
      a_o.address = TL_ADDR_W'(DRAM_BASE) + TL_ADDR_W'({raddr_q[31:6], 6'd0});
    end
  end

  assign d_ready_o  = d_i.source[0] ? w_d_ready : r_d_ready;
  assign rd_lines_o = STATS ? rlines_q : '0;
  assign wr_lines_o = STATS ? wlines_q : '0;
  assign wr_drops_o = wdrops_q;

`ifndef SYNTHESIS
  // a beat on offer stays as it is until its handshake (TileLink's flow control)
  tl_a_t a_prev;
  logic  a_held;
  always_ff @(posedge clk) begin
    a_held <= !rst && a_valid_o && !a_ready_i;
    a_prev <= a_o;
    if (a_held) assert (a_valid_o && a_o == a_prev) else $error("tg_hdma: an A beat changed before its handshake");
  end
  // every response is expected: an AccessAckData for the read engine's Get, an AccessAck for a Put
  always_ff @(posedge clk) if (!rst && d_valid_i && d_ready_o) begin
    if (!d_i.source[0]) assert (rs_q == R_DATA && d_i.opcode == D_ACCESS_ACK_DATA)
      else $error("tg_hdma: an unexpected response for the read engine");
    else                assert (ws_q == W_ACK && d_i.opcode == D_ACCESS_ACK)
      else $error("tg_hdma: an unexpected response for the write engine");
  end
`endif

  // a write burst ends at WLAST, so AWLEN is not needed
  wire unused = ^{s_awaddr[39:32], s_awlen, s_araddr[39:32], d_i.param, d_i.size, d_i.sink, d_i.corrupt,
                  d_i.source[TL_SRC_W-1:1]};
endmodule
