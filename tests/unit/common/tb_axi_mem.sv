// Behavioural AXI4 memory for unit tests (SoC track). Random latency and ready, read bursts
// returned out of order across IDs (OOO), write responses delayed. Checks the protocol subset the
// uncore uses: INCR bursts of 128-bit beats, WLAST on the last beat, IDs unique among outstanding
// reads and among outstanding writes (STRICT_ID), and no read of a line whose write is still
// outstanding. Unwritten memory reads as init_beat(beat address), which tb_axi_mem_pkg exports so a
// reference model can agree.
module tb_axi_mem
  import tg_uncore_pkg::*, tb_axi_mem_pkg::*;
#(
  parameter int LAT_MIN   = 4,
  parameter int LAT_MAX   = 40,
  parameter int READY_PCT = 80,
  parameter bit OOO       = 1'b1,
  parameter bit STRICT_ID = 1'b1,
  parameter longint unsigned ERR_BASE = 64'hFFFF_FFFF_FFFF_FFFF,  // reads at/above answer SLVERR
  parameter string NAME   = "mem"
) (
  input  logic    clk,
  input  logic    rst,
  input  axi_ax_t ar_i,
  input  logic    ar_valid_i,
  output logic    ar_ready_o,
  output axi_r_t  r_o,
  output logic    r_valid_o,
  input  logic    r_ready_i,
  input  axi_ax_t aw_i,
  input  logic    aw_valid_i,
  output logic    aw_ready_o,
  input  axi_w_t  w_i,
  input  logic    w_valid_i,
  output logic    w_ready_o,
  output axi_b_t  b_o,
  output logic    b_valid_o,
  input  logic    b_ready_i
);
  logic [127:0] mem [longint unsigned];

  function automatic logic [127:0] rd_beat(input longint unsigned ba);
    return mem.exists(ba) ? mem[ba] : init_beat(ba);
  endfunction

  typedef struct { axi_ax_t a; longint unsigned t_ready; longint unsigned t_issue; } rq_t;
  typedef struct { axi_b_t b; longint unsigned t; longint unsigned line; } bq_t;

  rq_t  rq[$];
  rq_t  cur;
  bit   cur_v;
  int   beat;
  longint unsigned now;
  axi_ax_t wq[$];
  bq_t  bq[$];
  int   wbeat;
  int   n_reads, n_writes;
  longint unsigned lat_sum, lat_max;    // per completed read: issue to last beat accepted
  bit   rd_out [int];
  bit   wr_out [int];
  int   wr_line_cnt [longint unsigned];  // lines with a write accepted but no B sent yet

  always @(posedge clk) begin
    if (rst) begin
      now        <= 0;
      ar_ready_o <= 1'b0;
      aw_ready_o <= 1'b0;
      w_ready_o  <= 1'b0;
      r_valid_o  <= 1'b0;
      b_valid_o  <= 1'b0;
      cur_v      = 1'b0;
      beat       = 0;
      wbeat      = 0;
      n_reads    = 0;
      n_writes   = 0;
      lat_sum    = 0;
      lat_max    = 0;
    end else begin
      now        <= now + 1;
      ar_ready_o <= ($urandom_range(99) < READY_PCT);
      aw_ready_o <= ($urandom_range(99) < READY_PCT);
      w_ready_o  <= ($urandom_range(99) < READY_PCT);

      // ---- AR ----
      if (ar_valid_i && ar_ready_o) begin
        rq_t x;
        longint unsigned line;
        line = ar_i.addr >> 6;
        assert (ar_i.burst == AXI_INCR && ar_i.size == 3'd4) else $error("%s: bad AR %p", NAME, ar_i);
        if (STRICT_ID) begin
          assert (!rd_out.exists(int'(ar_i.id))) else $error("%s: read ID %0d reused while outstanding", NAME, ar_i.id);
          rd_out[int'(ar_i.id)] = 1'b1;
        end
        assert (!wr_line_cnt.exists(line)) else $error("%s: read of line %h while its write is outstanding", NAME, line);
        x.a       = ar_i;
        x.t_issue = now;
        x.t_ready = now + longint'($urandom_range(LAT_MAX, LAT_MIN));
        rq.push_back(x);
        n_reads++;
      end

      // ---- R ----
      if (r_valid_o && r_ready_i) begin
        if (r_o.last) begin
          cur_v = 1'b0;
          if (STRICT_ID) rd_out.delete(int'(cur.a.id));
          lat_sum += now - cur.t_issue;
          if (now - cur.t_issue > lat_max) lat_max = now - cur.t_issue;
        end else begin
          beat++;
        end
      end
      if (!cur_v) begin
        int pick;
        pick = -1;
        foreach (rq[k]) begin
          if (rq[k].t_ready <= now && (pick < 0 || (OOO && $urandom_range(1) == 1))) pick = k;
          if (pick >= 0 && !OOO) break;
        end
        if (pick >= 0) begin
          cur   = rq[pick];
          cur_v = 1'b1;
          beat  = 0;
          rq.delete(pick);
        end
      end
      if (cur_v && (r_valid_o && !r_ready_i)) begin
        // hold the current beat
      end else if (cur_v && $urandom_range(99) < 85) begin
        longint unsigned ba;
        ba = (cur.a.addr >> 4) + longint'(beat);
        r_valid_o <= 1'b1;
        r_o.id    <= cur.a.id;
        r_o.data  <= rd_beat(ba);
        r_o.resp  <= (cur.a.addr >= ERR_BASE) ? AXI_SLVERR : AXI_OKAY;
        r_o.last  <= beat == int'(cur.a.len);
      end else begin
        r_valid_o <= 1'b0;
      end

      // ---- AW / W ----
      if (aw_valid_i && aw_ready_o) begin
        longint unsigned line;
        line = aw_i.addr >> 6;
        assert (aw_i.burst == AXI_INCR && aw_i.size == 3'd4) else $error("%s: bad AW %p", NAME, aw_i);
        if (STRICT_ID) begin
          assert (!wr_out.exists(int'(aw_i.id))) else $error("%s: write ID %0d reused while outstanding", NAME, aw_i.id);
          wr_out[int'(aw_i.id)] = 1'b1;
        end
        wq.push_back(aw_i);
        if (wr_line_cnt.exists(line)) wr_line_cnt[line]++;
        else wr_line_cnt[line] = 1;
      end
      if (w_valid_i && w_ready_o) begin
        if (wq.size() == 0) begin
          $error("%s: W beat before its AW", NAME);
        end else begin
          axi_ax_t a;
          longint unsigned ba;
          logic [127:0] old;
          a   = wq[0];
          ba  = (a.addr >> 4) + longint'(wbeat);
          old = rd_beat(ba);
          for (int k = 0; k < 16; k++) if (w_i.strb[k]) old[8*k +: 8] = w_i.data[8*k +: 8];
          mem[ba] = old;
          assert (w_i.last == (wbeat == int'(a.len))) else $error("%s: WLAST wrong at beat %0d", NAME, wbeat);
          if (w_i.last) begin
            bq_t x;
            x.b.id   = a.id;
            x.b.resp = AXI_OKAY;
            x.t      = now + longint'($urandom_range(LAT_MAX, LAT_MIN));
            x.line   = a.addr >> 6;
            bq.push_back(x);
            void'(wq.pop_front());
            wbeat = 0;
            n_writes++;
          end else begin
            wbeat++;
          end
        end
      end

      // ---- B ----
      if (b_valid_o && b_ready_i) b_valid_o <= 1'b0;
      if ((!b_valid_o || b_ready_i) && bq.size() > 0 && bq[0].t <= now) begin
        longint unsigned line;
        line = bq[0].line;
        b_valid_o <= 1'b1;
        b_o       <= bq[0].b;
        if (STRICT_ID) wr_out.delete(int'(bq[0].b.id));
        if (wr_line_cnt[line] == 1) wr_line_cnt.delete(line);
        else wr_line_cnt[line]--;
        void'(bq.pop_front());
      end
    end
  end

  function automatic int outstanding();
    return rq.size() + int'(cur_v) + wq.size() + bq.size() + int'(b_valid_o);
  endfunction
endmodule
