// L2 bank random test against a reference memory (docs/spec/l2.md §Verification).
//   NA agents: behavioural TL-C L1D models (MESI, small caches) issuing AcquireBlock/AcquirePerm,
//              storing into owned lines, evicting with Release/ReleaseData, answering probes by the
//              TileLink rules (a ProbeAck waits for a pending ReleaseAck on the same line). ACQ_N > 1:
//              up to ACQ_N Acquires outstanding per agent (sources 0 .. ACQ_N-1, the Release source 4),
//              to different lines, as the 4-miss L1D sends them (DR-149); Grants may come in any order,
//              but one Grant's beats must not interleave with another's.
//   l1i client: line Gets (source[9:6] = 4).  mmio client: Get/PutFull/PutPartial of every size (8).
//   Memory: tb_axi_mem with random latency and out-of-order bursts.
// Checks every GrantData and AccessAckData against the reference, permission rules, inclusive
// completion, and a final read-back of every line. Plusargs: +seed=N +ops=N
module tb_l2;
  import tg_pkg::*, tg_tl_pkg::*, tg_uncore_pkg::*, tb_axi_mem_pkg::*;

  parameter int NA     = 1;
  parameter int SETS   = 16;
  parameter int N_MSHR = 8;
  parameter int DATA_LAT = 2;
  parameter bit DIR_S3 = 1'b1;       // the directory RAM written at S3 (else S2)
  parameter int NSETS_USED = 4;      // sets the line pool covers
  parameter int NTAGS  = 12;         // lines per set in the pool (> 8 ways forces evictions)
  parameter int CAP    = 6;          // lines an agent caches at most
  parameter int ACQ_N  = 1;          // Acquires an agent keeps outstanding at most (DR-149: 4)

  localparam int SET_W = $clog2(SETS);
  localparam int NLINES = NSETS_USED * NTAGS;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;

  // ---- DUT ----
  tl_a_t   a;   logic a_valid, a_ready;
  tl_b_t   b;   logic b_valid, b_ready;
  tl_c_t   c;   logic c_valid, c_ready;
  tl_d_t   d;   logic d_valid, d_ready;
  tl_e_t   e;   logic e_valid, e_ready;
  axi_ax_t ar, aw; logic ar_valid, ar_ready, aw_valid, aw_ready;
  axi_r_t  r;   logic r_valid, r_ready;
  axi_w_t  w;   logic w_valid, w_ready;
  axi_b_t  bresp; logic bresp_valid, bresp_ready;
  logic    init_done, ev_hit, ev_miss, ev_wb, ev_probe, ev_err;
  logic [31:0]     ev_err_info;
  logic [PA_W-7:0] ev_err_line;
  // the injected AXI errors are the only ones here: each comes described as a write or fill error
  always @(posedge clk) if (ev_err)
    assert (ev_err_info[2:0] == 3'd4 || ev_err_info[2:0] == 3'd5) else $error("L2 error described as kind %0d", ev_err_info[2:0]);

  tg_l2_bank #(.BANK(0), .N_AGENTS(NA), .SETS(SETS), .N_MSHR(N_MSHR), .DATA_PRIM("block"), .DATA_LAT(DATA_LAT),
               .DIR_S3(DIR_S3)) dut (
    .clk, .rst,
    .a_i (a), .a_valid_i (a_valid), .a_ready_o (a_ready),
    .b_o (b), .b_valid_o (b_valid), .b_ready_i (b_ready),
    .c_i (c), .c_valid_i (c_valid), .c_ready_o (c_ready),
    .d_o (d), .d_valid_o (d_valid), .d_ready_i (d_ready),
    .e_i (e), .e_valid_i (e_valid), .e_ready_o (e_ready),
    .ar_o (ar), .ar_valid_o (ar_valid), .ar_ready_i (ar_ready),
    .r_i (r), .r_valid_i (r_valid), .r_ready_o (r_ready),
    .aw_o (aw), .aw_valid_o (aw_valid), .aw_ready_i (aw_ready),
    .w_o (w), .w_valid_o (w_valid), .w_ready_i (w_ready),
    .bresp_i (bresp), .bresp_valid_i (bresp_valid), .bresp_ready_o (bresp_ready),
    .init_done_o (init_done), .ev_hit_o (ev_hit), .ev_miss_o (ev_miss), .ev_wb_o (ev_wb),
    .ev_probe_o (ev_probe), .ev_err_o (ev_err), .ev_err_info_o (ev_err_info), .ev_err_line_o (ev_err_line)
  );

  // Lines at or above ERR_BASE answer SLVERR (the +errlines mode puts some pool lines there).
  localparam longint unsigned ERR_BASE = 64'h3_0000_0000;
  tb_axi_mem #(.LAT_MIN(4), .LAT_MAX(60), .READY_PCT(75), .OOO(1'b1), .ERR_BASE(ERR_BASE), .NAME("l2mem")) mem (
    .clk, .rst,
    .ar_i (ar), .ar_valid_i (ar_valid), .ar_ready_o (ar_ready),
    .r_o (r), .r_valid_o (r_valid), .r_ready_i (r_ready),
    .aw_i (aw), .aw_valid_i (aw_valid), .aw_ready_o (aw_ready),
    .w_i (w), .w_valid_i (w_valid), .w_ready_o (w_ready),
    .b_o (bresp), .b_valid_o (bresp_valid), .b_ready_i (bresp_ready)
  );

  // ---- Line pool and reference memory ----
  longint unsigned pool [NLINES];
  logic [511:0] refm [longint unsigned];
  function automatic logic [511:0] ref_get(input longint unsigned l);
    return refm.exists(l) ? refm[l] : init_line(l);
  endfunction

  // ---- Agent state (key = line * 4 + agent) ----
  int           st   [longint unsigned];   // 0 N, 1 B, 2 T
  bit           drt  [longint unsigned];
  logic [511:0] dat  [longint unsigned];
  function automatic longint unsigned key(input int ag, input longint unsigned l);
    return l * 4 + longint'(ag);
  endfunction
  function automatic int st_of(input int ag, input longint unsigned l);
    return st.exists(key(ag, l)) ? st[key(ag, l)] : 0;
  endfunction

  bit              acq_busy [NA][ACQ_N];
  longint unsigned acq_line [NA][ACQ_N];
  bit              acq_perm [NA][ACQ_N];
  logic [2:0]      acq_param[NA][ACQ_N];
  int              acq_beats[NA][ACQ_N];
  logic [511:0]    acq_buf  [NA][ACQ_N];
  // an outstanding Acquire of agent ag: for line l; any; the first free slot (-1: none)
  function automatic bit acq_on(input int ag, input longint unsigned l);
    for (int k = 0; k < ACQ_N; k++) if (acq_busy[ag][k] && acq_line[ag][k] == l) return 1'b1;
    return 1'b0;
  endfunction
  function automatic bit acq_any(input int ag);
    for (int k = 0; k < ACQ_N; k++) if (acq_busy[ag][k]) return 1'b1;
    return 1'b0;
  endfunction
  function automatic int acq_free(input int ag);
    for (int k = 0; k < ACQ_N; k++) if (!acq_busy[ag][k]) return k;
    return -1;
  endfunction
  localparam logic [5:0] REL_SRC = (ACQ_N > 1) ? 6'd4 : 6'd2;
  bit              rel_busy [NA];
  longint unsigned rel_line [NA];
  typedef struct { longint unsigned line; logic [2:0] cap; } probe_t;
  probe_t          pq [NA][$];

  // ---- Message queues into the DUT ----
  typedef struct {
    tl_a_t hdr; int nbeats; logic [3:0][127:0] data; logic [3:0][15:0] mask;
  } amsg_t;
  typedef struct { tl_c_t hdr; int nbeats; logic [511:0] data; } cmsg_t;
  amsg_t aq[$];  int a_beat;
  cmsg_t cq[$];  int c_beat;
  tl_e_t eq[$];

  // ---- TL-UL clients ----
  bit              ic_busy [2];
  longint unsigned ic_line [2];
  logic [511:0]    ic_buf  [2];
  int              ic_beats[2];
  bit              mc_busy;
  amsg_t           mc_req;
  logic [511:0]    mc_buf;
  int              mc_beats;

  // ---- Bookkeeping ----
  int unsigned seed;
  bit errlines;
  function automatic bit is_err(input longint unsigned l);
    return (l << 6) >= ERR_BASE;
  endfunction
  int  ops, ops_target, errors, checks;
  int  n_probe, n_pack_data, n_grant_b, n_grant_t, n_upgrade, n_perm, n_rel_data, n_put, n_get_ul, n_denied;
  int  max_acq;                      // the most Acquires one agent had outstanding at once
  longint unsigned cyc, last_progress;
  bit  draining, final_phase, done;
  int  final_idx;

  task automatic fail(input string msg);
    errors++;
    $display("[%0d] ERROR: %s", cyc, msg);
    if (errors > 10) begin
      $display("TEST FAILED (seed %0d)", seed);
      $finish;
    end
  endtask

  function automatic logic [15:0] size_mask16(input logic [5:0] addr, input logic [2:0] size);
    // byte lanes of the 16-byte beat covered by an access of `size` at `addr` (size <= 4)
    logic [15:0] m;
    m = 16'((32'd1 << (32'd1 << size)) - 1) << addr[3:0];
    return (size >= 3'd4) ? 16'hFFFF : m;
  endfunction

  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("ops=%d", ops_target)) ops_target = 20000;
    errlines = $test$plusargs("errlines");
    void'($urandom(seed));
    $display("tb_l2: NA=%0d SETS=%0d N_MSHR=%0d DATA_LAT=%0d seed=%0d ops=%0d", NA, SETS, N_MSHR, DATA_LAT, seed, ops_target);
    for (int i = 0; i < NLINES; i++) begin
      int s, t;
      s = i % NSETS_USED;
      t = i / NSETS_USED;
      // bank 0 lines (line bit 0 = 0) inside the DRAM window, spread over the tag range
      pool[i] = (64'h8000_0000 >> 6) + (longint'(t * 37 + 5) << (1 + SET_W)) + (longint'(s * 3 % SETS) << 1);
      if (errlines && t >= NTAGS - 2)       // the last two tags of every set fault
        pool[i] = (ERR_BASE >> 6) + (longint'(t) << (1 + SET_W)) + (longint'(s * 3 % SETS) << 1);
    end
  end

  // ---- The single TB process: sample handshakes, update models, drive inputs ----
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (rst) begin
      a_valid <= 1'b0; c_valid <= 1'b0; e_valid <= 1'b0;
      b_ready <= 1'b0; d_ready <= 1'b0;
      a_beat = 0; c_beat = 0;
    end else begin
      // ======== 1. Completed handshakes (values from the cycle that just ended) ========
      if (a_valid && a_ready) begin
        if (a_beat == aq[0].nbeats - 1) begin void'(aq.pop_front()); a_beat = 0; end
        else a_beat++;
      end
      if (c_valid && c_ready) begin
        if (c_beat == cq[0].nbeats - 1) begin void'(cq.pop_front()); c_beat = 0; end
        else c_beat++;
      end
      if (e_valid && e_ready) void'(eq.pop_front());

      // Probes
      if (b_valid && b_ready) begin
        int ag;
        probe_t p;
        ag = int'(b.source[7:6]);
        if (b.opcode != B_PROBE_BLOCK || b.size != 3'd6 || ag >= NA) fail($sformatf("bad probe %p", b));
        p.line = b.address >> 6;
        p.cap  = b.param;
        n_probe++;
        pq[ag].push_back(p);
      end

      // Responses
      if (d_valid && d_ready) begin
        int hi;
        last_progress = cyc;
        hi = int'(d.source[9:6]);
        if (hi < NA) begin : agent_d
          int ag;
          ag = hi;
          if (d.opcode == D_RELEASE_ACK) begin
            if (!rel_busy[ag]) fail($sformatf("agent %0d: unexpected ReleaseAck", ag));
            rel_busy[ag] = 1'b0;
          end else if (d.opcode == D_GRANT || d.opcode == D_GRANT_DATA) begin
            longint unsigned l;
            int k;
            k = (ACQ_N > 1) ? int'(d.source[5:0]) : 0;     // the slot: the Acquire's source
            if (k >= ACQ_N) begin
              fail($sformatf("agent %0d: Grant to source %h", ag, d.source));
              k = 0;
            end
            l = acq_line[ag][k];
            if (!acq_busy[ag][k]) fail($sformatf("agent %0d: unexpected Grant (slot %0d)", ag, k));
            if (d.denied != is_err(l)) fail($sformatf("agent %0d: Grant for line %h denied=%0d", ag, l, d.denied));
            for (int j = 0; j < ACQ_N; j++)                 // one Grant's beats stay together (DR-149)
              if (j != k && acq_beats[ag][j] > 0 && acq_beats[ag][j] < 4)
                fail($sformatf("agent %0d: a Grant beat for slot %0d inside slot %0d's GrantData", ag, k, j));
            if (d.opcode == D_GRANT_DATA) begin
              acq_buf[ag][k][128*acq_beats[ag][k] +: 128] = d.data;
              acq_beats[ag][k]++;
            end
            if ((d.opcode == D_GRANT || acq_beats[ag][k] == 4) && d.denied) begin
              tl_e_t ge;
              n_denied++;
              acq_busy[ag][k]  = 1'b0;      // the line is not granted; GrantAck still goes back
              acq_beats[ag][k] = 0;
              ge.sink = d.sink;
              eq.push_back(ge);
            end else if (d.opcode == D_GRANT || acq_beats[ag][k] == 4) begin
              tl_e_t ge;
              bit want_t;
              want_t = acq_param[ag][k] != TL_GROW_N_TO_B;
              if (want_t && d.param != TL_CAP_TO_T[1:0]) fail($sformatf("agent %0d: Grant toB for a T request", ag));
              if (d.param == TL_CAP_TO_T[1:0]) n_grant_t++; else n_grant_b++;
              if (acq_param[ag][k] == TL_GROW_B_TO_T) n_upgrade++;
              if (acq_perm[ag][k]) n_perm++;
              if (acq_perm[ag][k]) begin
                if (d.opcode != D_GRANT) fail("AcquirePerm answered with data");
                dat[key(ag, l)] = {$urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom(),
                                   $urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom(), $urandom()};
                refm[l] = dat[key(ag, l)];
                drt[key(ag, l)] = 1'b1;
                st[key(ag, l)]  = 2;
              end else begin
                if (d.opcode != D_GRANT_DATA) fail("AcquireBlock answered without data");
                checks++;
                if (acq_buf[ag][k] !== ref_get(l))
                  fail($sformatf("agent %0d: GrantData for line %h\n  got  %h\n  want %h", ag, l, acq_buf[ag][k], ref_get(l)));
                dat[key(ag, l)] = acq_buf[ag][k];
                drt[key(ag, l)] = 1'b0;
                st[key(ag, l)]  = (d.param == TL_CAP_TO_T[1:0]) ? 2 : 1;
              end
              acq_busy[ag][k]  = 1'b0;
              acq_beats[ag][k] = 0;
              ge.sink = d.sink;
              eq.push_back(ge);
            end
          end else fail($sformatf("agent %0d: unexpected D %p", ag, d));
        end else if (hi == SRC_L1I0) begin : l1i_d
          int id;
          id = int'(d.source[0]);
          if (!ic_busy[id] || d.opcode != D_ACCESS_ACK_DATA || d.denied != is_err(ic_line[id])) fail($sformatf("l1i: unexpected D %p", d));
          ic_buf[id][128*ic_beats[id] +: 128] = d.data;
          ic_beats[id]++;
          if (ic_beats[id] == 4) begin
            checks++;
            if (!is_err(ic_line[id]) && ic_buf[id] !== ref_get(ic_line[id]))
              fail($sformatf("l1i: Get of line %h\n  got  %h\n  want %h", ic_line[id], ic_buf[id], ref_get(ic_line[id])));
            ic_busy[id] = 1'b0;
            if (final_phase) final_idx++;
          end
        end else if (hi == SRC_MMIO0) begin : mmio_d
          longint unsigned l;
          l  = mc_req.hdr.address >> 6;
          if (!mc_busy || d.denied != (is_err(l) && !(mc_req.hdr.opcode == A_PUT_FULL && mc_req.hdr.size == 3'd6)))
            fail($sformatf("mmio: D denied=%0d for line %h op %0d", d.denied, l, mc_req.hdr.opcode));
          if (mc_req.hdr.opcode == A_GET) begin
            int first;
            first = int'(mc_req.hdr.address[5:4]) & ~((mc_req.hdr.size == 3'd5) ? 1 : (mc_req.hdr.size == 3'd6) ? 3 : 0);
            mc_buf[128*(first + mc_beats) +: 128] = d.data;
            mc_beats++;
            if (d.opcode != D_ACCESS_ACK_DATA) fail("mmio: Get answered without data");
            if (mc_beats == ((mc_req.hdr.size <= 3'd4) ? 1 : (mc_req.hdr.size == 3'd5) ? 2 : 4)) begin
              logic [511:0] want;
              int nbytes, base;
              want   = ref_get(l);
              nbytes = 1 << mc_req.hdr.size;
              base   = int'(mc_req.hdr.address[5:0]);
              checks++;
              if (!d.denied) for (int k = 0; k < nbytes; k++)
                if (mc_buf[8*(base+k) +: 8] !== want[8*(base+k) +: 8])
                  fail($sformatf("mmio: Get size %0d at %h byte %0d got %h want %h", mc_req.hdr.size,
                                 mc_req.hdr.address, k, mc_buf[8*(base+k) +: 8], want[8*(base+k) +: 8]));
              mc_busy = 1'b0;
            end
          end else begin
            logic [511:0] v;
            if (d.opcode != D_ACCESS_ACK) fail("mmio: Put answered with data");
            v = ref_get(l);
            if (!d.denied) for (int bt = 0; bt < 4; bt++)
              for (int k = 0; k < 16; k++)
                if (mc_req.mask[bt][k]) v[128*bt + 8*k +: 8] = mc_req.data[bt][8*k +: 8];
            refm[l] = v;
            mc_busy = 1'b0;
          end
        end else fail($sformatf("D to unknown source %h", d.source));
      end

      // ======== 2. Agent behaviour ========
      for (int ag = 0; ag < NA; ag++) begin
        // Probes, in order; one waiting on a ReleaseAck for its line holds the queue.
        if (pq[ag].size() > 0 && !(rel_busy[ag] && rel_line[ag] == pq[ag][0].line) && cq.size() < 8) begin
          probe_t p;
          cmsg_t  m;
          int     s;
          p = pq[ag].pop_front();
          s = st_of(ag, p.line);
          m.hdr = '0;
          m.hdr.size    = 3'd6;
          m.hdr.source  = TL_SRC_W'({4'(ag), 6'd0});
          m.hdr.address = PA_W'(p.line << 6);
          m.nbeats      = 1;
          m.hdr.opcode  = C_PROBE_ACK;
          if (p.cap == TL_CAP_TO_N) begin
            m.hdr.param = (s == 2) ? TL_SHRINK_T_TO_N : (s == 1) ? TL_SHRINK_B_TO_N : TL_REPORT_N_TO_N;
          end else begin
            m.hdr.param = (s == 2) ? TL_SHRINK_T_TO_B : (s == 1) ? TL_REPORT_B_TO_B : TL_REPORT_N_TO_N;
          end
          if (s == 2 && drt[key(ag, p.line)]) begin
            n_pack_data++;
            m.hdr.opcode = C_PROBE_ACK_DATA;
            m.nbeats     = 4;
            m.data       = dat[key(ag, p.line)];
          end
          if (p.cap == TL_CAP_TO_N) st[key(ag, p.line)] = 0;
          else if (s == 2) st[key(ag, p.line)] = 1;
          drt[key(ag, p.line)] = 1'b0;
          cq.push_back(m);
        end

        if (!draining) begin
          int r;
          r = int'($urandom_range(99));
          if (r < 12 && acq_free(ag) >= 0 && aq.size() < 6) begin
            // Acquire, or store into a T line
            longint unsigned l;
            int s, nheld;
            l = pool[$urandom_range(NLINES - 1)];
            s = st_of(ag, l);
            nheld = 0;
            foreach (pool[i]) if (st_of(ag, pool[i]) != 0) nheld++;
            if (s == 2) begin
              int byte_i;
              byte_i = int'($urandom_range(63));
              dat[key(ag, l)][8*byte_i +: 8] = 8'($urandom());
              drt[key(ag, l)] = 1'b1;
              refm[l] = dat[key(ag, l)];
            end else if (!(rel_busy[ag] && rel_line[ag] == l) && !acq_on(ag, l) && (s == 1 || nheld < CAP)) begin
              amsg_t m;
              int k, slot;
              k = int'($urandom_range(99));
              slot = acq_free(ag);
              m.hdr = '0;
              m.hdr.size    = 3'd6;
              m.hdr.source  = TL_SRC_W'({4'(ag), (ACQ_N > 1) ? 6'(slot) : 6'd1});
              m.hdr.address = PA_W'(l << 6);
              m.hdr.mask    = '1;
              m.nbeats      = 1;
              if (s == 0) begin
                m.hdr.opcode = (k < 15) ? A_ACQUIRE_PERM : A_ACQUIRE_BLOCK;
                m.hdr.param  = (k < 15 || k >= 60) ? TL_GROW_N_TO_T : TL_GROW_N_TO_B;
              end else begin
                m.hdr.opcode = (k < 20) ? A_ACQUIRE_PERM : A_ACQUIRE_BLOCK;
                m.hdr.param  = TL_GROW_B_TO_T;
              end
              acq_busy[ag][slot]  = 1'b1;
              acq_line[ag][slot]  = l;
              acq_perm[ag][slot]  = m.hdr.opcode == A_ACQUIRE_PERM;
              acq_param[ag][slot] = m.hdr.param;
              acq_beats[ag][slot] = 0;
              begin
                int nb;
                nb = 0;
                for (int j = 0; j < ACQ_N; j++) nb += int'(acq_busy[ag][j]);
                if (nb > max_acq) max_acq = nb;
              end
              aq.push_back(m);
              ops++;
            end
          end else if (r >= 12 && r < 18 && !rel_busy[ag] && cq.size() < 8) begin
            // Evict a held line (not one with a Grant pending)
            longint unsigned cand [$];
            cand.delete();   // block-local variables are static in this process
            foreach (pool[i]) if (st_of(ag, pool[i]) != 0 && !acq_on(ag, pool[i])) cand.push_back(pool[i]);
            if (cand.size() > 0) begin
              longint unsigned l;
              int s;
              cmsg_t m;
              l = cand[$urandom_range(cand.size() - 1)];
              s = st_of(ag, l);
              m.hdr = '0;
              m.hdr.size    = 3'd6;
              m.hdr.source  = TL_SRC_W'({4'(ag), REL_SRC});
              m.hdr.address = PA_W'(l << 6);
              m.nbeats      = 1;
              m.hdr.opcode  = C_RELEASE;
              if (s == 2) begin
                m.hdr.param = ($urandom_range(99) < 70) ? TL_SHRINK_T_TO_N : TL_SHRINK_T_TO_B;
                if (drt[key(ag, l)]) begin
                  m.hdr.opcode = C_RELEASE_DATA;
                  m.nbeats     = 4;
                  m.data       = dat[key(ag, l)];
                  n_rel_data++;
                end
                st[key(ag, l)] = (m.hdr.param == TL_SHRINK_T_TO_B) ? 1 : 0;
              end else begin
                m.hdr.param = TL_SHRINK_B_TO_N;
                st[key(ag, l)] = 0;
              end
              drt[key(ag, l)] = 1'b0;
              rel_busy[ag] = 1'b1;
              rel_line[ag] = l;
              cq.push_back(m);
            end
          end
        end else if (!rel_busy[ag] && cq.size() < 8) begin
          // Draining: release everything (once Acquires have finished)
          longint unsigned cand [$];
          cand.delete();
          foreach (pool[i]) if (st_of(ag, pool[i]) != 0 && !acq_on(ag, pool[i])) cand.push_back(pool[i]);
          if (cand.size() > 0) begin
            longint unsigned l;
            cmsg_t m;
            l = cand[0];
            m.hdr = '0;
            m.hdr.size    = 3'd6;
            m.hdr.source  = TL_SRC_W'({4'(ag), REL_SRC});
            m.hdr.address = PA_W'(l << 6);
            m.nbeats      = 1;
            m.hdr.opcode  = C_RELEASE;
            m.hdr.param   = (st_of(ag, l) == 2) ? TL_SHRINK_T_TO_N : TL_SHRINK_B_TO_N;
            if (st_of(ag, l) == 2 && drt[key(ag, l)]) begin
              m.hdr.opcode = C_RELEASE_DATA;
              m.nbeats     = 4;
              m.data       = dat[key(ag, l)];
            end
            st[key(ag, l)]  = 0;
            drt[key(ag, l)] = 1'b0;
            rel_busy[ag] = 1'b1;
            rel_line[ag] = l;
            cq.push_back(m);
          end
        end
      end

      // ======== 3. TL-UL clients ========
      if (!draining) begin
        for (int id = 0; id < 2; id++) begin
          if (!ic_busy[id] && $urandom_range(99) < 6 && aq.size() < 6) begin
            amsg_t m;
            longint unsigned l;
            l = pool[$urandom_range(NLINES - 1)];
            m.hdr = '0;
            m.hdr.opcode  = A_GET;
            m.hdr.size    = 3'd6;
            m.hdr.source  = TL_SRC_W'({4'(SRC_L1I0), 6'(id)});
            m.hdr.address = PA_W'(l << 6);
            m.hdr.mask    = '1;
            m.nbeats      = 1;
            ic_busy[id]  = 1'b1;
            ic_line[id]  = l;
            ic_beats[id] = 0;
            aq.push_back(m);
            ops++;
          end
        end
        if (!mc_busy && $urandom_range(99) < 5 && aq.size() < 6) begin
          amsg_t m;
          longint unsigned l;
          logic [2:0] sz;
          logic [5:0] off;
          int kind, first, nb;
          l    = pool[$urandom_range(NLINES - 1)];
          sz   = 3'($urandom_range(6));
          off  = 6'($urandom_range(63)) & ~6'((1 << sz) - 1);
          kind = int'($urandom_range(2));     // 0 Get, 1 PutFull, 2 PutPartial
          // A whole-line PutFull needs no fill, so on an error line it would succeed into the L2
          // (only its write-back fails); keep that case out of the error-line checks.
          if (is_err(l) && kind == 1 && sz == 3'd6) kind = 2;
          nb   = (sz <= 3'd4) ? 1 : (sz == 3'd5) ? 2 : 4;
          first = int'(off[5:4]);
          m.hdr = '0;
          m.hdr.opcode  = (kind == 0) ? A_GET : (kind == 1) ? A_PUT_FULL : A_PUT_PARTIAL;
          m.hdr.size    = sz;
          m.hdr.source  = TL_SRC_W'({4'(SRC_MMIO0), 6'd3});
          m.hdr.address = PA_W'((l << 6) | longint'(off));
          m.nbeats      = (kind == 0) ? 1 : nb;
          m.data        = '0;
          m.mask        = '0;
          for (int bt = 0; bt < nb; bt++) begin
            logic [15:0] lanes;
            lanes = (sz <= 3'd4) ? size_mask16(off, sz) : 16'hFFFF;
            m.data[first + bt] = {$urandom(), $urandom(), $urandom(), $urandom()};
            m.mask[first + bt] = (kind == 2) ? (lanes & 16'($urandom())) : lanes;
          end
          m.hdr.mask = m.mask[first];
          // the beats of a Put are indexed from the first beat of the access
          if (kind != 0) begin
            amsg_t m2;
            m2 = m;
            for (int bt = 0; bt < 4; bt++) begin
              m2.data[bt] = (bt < nb) ? m.data[first + bt] : '0;
              m2.mask[bt] = (bt < nb) ? m.mask[first + bt] : '0;
            end
            aq.push_back(m2);
          end else begin
            aq.push_back(m);
          end
          mc_busy  = 1'b1;
          mc_req   = m;      // keep beats at their line positions for the reference update
          mc_beats = 0;
          mc_buf   = '0;
          ops++;
        end
      end

      // ======== 4. Phases ========
      if (!draining && ops >= ops_target) begin
        draining = 1'b1;
        $display("[%0d] tb_l2: %0d operations issued; draining", cyc, ops);
      end
      if (draining && !final_phase) begin
        bit quiet;
        quiet = aq.size() == 0 && cq.size() == 0 && eq.size() == 0 && !mc_busy && !ic_busy[0] && !ic_busy[1];
        for (int ag = 0; ag < NA; ag++) begin
          if (acq_any(ag) || rel_busy[ag] || pq[ag].size() > 0) quiet = 1'b0;
          foreach (pool[i]) if (st_of(ag, pool[i]) != 0) quiet = 1'b0;
        end
        if (quiet) begin
          final_phase = 1'b1;
          final_idx   = 0;
          $display("[%0d] tb_l2: agents empty; reading back %0d lines", cyc, NLINES);
        end
      end
      if (final_phase && !done) begin
        if (final_idx >= NLINES && !ic_busy[0]) begin
          done = 1'b1;
          $display("tb_l2: %0d ops, %0d data checks, %0d memory reads, %0d writes, %0d errors",
                   ops, checks, mem.n_reads, mem.n_writes, errors);
          $display("tb_l2: coverage: %0d probes (%0d ProbeAckData), grants %0d toT / %0d toB, %0d upgrades, %0d AcquirePerm, %0d ReleaseData, %0d denied, up to %0d Acquires outstanding per agent",
                   n_probe, n_pack_data, n_grant_t, n_grant_b, n_upgrade, n_perm, n_rel_data, n_denied, max_acq);
          if (errors == 0) $display("TEST PASSED (seed %0d)", seed);
          else             $display("TEST FAILED (seed %0d)", seed);
          $finish;
        end else if (!ic_busy[0] && aq.size() == 0 && final_idx < NLINES) begin
          amsg_t m;
          m.hdr = '0;
          m.hdr.opcode  = A_GET;
          m.hdr.size    = 3'd6;
          m.hdr.source  = TL_SRC_W'({4'(SRC_L1I0), 6'd0});
          m.hdr.address = PA_W'(pool[final_idx] << 6);
          m.hdr.mask    = '1;
          m.nbeats      = 1;
          ic_busy[0]  = 1'b1;
          ic_line[0]  = pool[final_idx];
          ic_beats[0] = 0;
          aq.push_back(m);
        end
      end

      // Watchdog
      if (cyc - last_progress > 20000) begin
        $display("---- state dump ----");
        $display("ain_st %0d ain line %h op %0d | cin_st %0d cin line %h op %0d", dut.ain_st_q, dut.ain_q.address >> 6,
                 dut.ain_q.opcode, dut.cin_st_q, dut.cin_q.address >> 6, dut.cin_q.opcode);
        for (int m = 0; m < N_MSHR; m++)
          $display("mshr %0d v%0d st %0d kind %h line %h way %b hit %0d ppend %b psent %b vact %0d vtag %h wb %0d/%0d fill %0d ar %0d",
                   m, dut.m_valid[m], dut.m_st[m], dut.u_mkind.mem[m], dut.m_line[m], dut.m_way_oh[m], dut.m_hit[m],
                   dut.m_ppend[m], dut.m_psent[m], dut.m_vact[m], dut.m_vtag[m], dut.m_need_wb[m], dut.m_wb_done[m],
                   dut.m_need_fill[m], dut.m_ar_sent[m]);
        $display("aq %0d cq %0d eq %0d | mem outstanding %0d | dq %0d credit %0d | vr_busy %0d rs_busy %0d pw_busy %0d ws_busy %0d",
                 aq.size(), cq.size(), eq.size(), mem.outstanding(), dut.dq_cnt, dut.d_credit_q, dut.vr_busy_q,
                 dut.rs_busy_q, dut.pw_busy_q, dut.ws_busy_q);
        for (int ag = 0; ag < NA; ag++)
        begin
          $display("agent %0d rel_busy %0d line %h | probes queued %0d", ag, rel_busy[ag], rel_line[ag], pq[ag].size());
          for (int k = 0; k < ACQ_N; k++)
            if (acq_busy[ag][k]) $display("  acquire slot %0d line %h, %0d beats in", k, acq_line[ag][k], acq_beats[ag][k]);
        end
        fail("no D progress for 20000 cycles (deadlock?)");
        $display("TEST FAILED (seed %0d)", seed);
        $finish;
      end
      if (ev_err && !errlines) fail("L2 reported a protocol or AXI error");

      // ======== 5. Drive the DUT's inputs ========
      if (aq.size() > 0) begin
        tl_a_t x;
        x = aq[0].hdr;
        x.data = aq[0].data[a_beat];
        if (tl_a_has_data(x.opcode)) x.mask = aq[0].mask[a_beat];
        a <= x;
        a_valid <= ($urandom_range(99) < 85);
      end else begin
        a_valid <= 1'b0;
      end
      if (cq.size() > 0) begin
        tl_c_t x;
        x = cq[0].hdr;
        x.data = cq[0].data[128*c_beat +: 128];
        c <= x;
        c_valid <= ($urandom_range(99) < 85);
      end else begin
        c_valid <= 1'b0;
      end
      if (eq.size() > 0) begin
        e <= eq[0];
        e_valid <= ($urandom_range(99) < 85);
      end else begin
        e_valid <= 1'b0;
      end
      b_ready <= ($urandom_range(99) < 80);
      d_ready <= ($urandom_range(99) < 80);
    end
  end

  // ---- Optional trace of one line: +trace_line=<hex line address> ----
  longint unsigned trace_line;
  bit trace_on;
  initial trace_on = $value$plusargs("trace_line=%h", trace_line);
  always @(posedge clk) if (trace_on && !rst) begin
    if (a_valid && a_ready && (a.address >> 6) == trace_line) $display("[%0d] A   %s param %0d src %h", cyc, a.opcode.name(), a.param, a.source);
    if (c_valid && c_ready && (c.address >> 6) == trace_line) $display("[%0d] C   %s param %0d src %h", cyc, c.opcode.name(), c.param, c.source);
    if (b_valid && b_ready && (b.address >> 6) == trace_line) $display("[%0d] B   probe cap %0d to %h", cyc, b.param, b.source);
    if (dut.p2_v_q && dut.p2_q.line == trace_line)
      $display("[%0d] S2  kind %0d hit %0d way %0d victim %0d", cyc, dut.p2_q.kind, dut.hit2, dut.hw2, dut.vw2);
    if (dut.p2_v_q && dut.p2_q.kind >= 4 && !dut.hit2 && dut.row2.way[dut.vw2].valid &&
        {dut.row2.way[dut.vw2].tag, dut.set2, 1'b0} == trace_line)
      $display("[%0d] S2  line chosen as victim by kind %0d of %h (pres %b dirty %b)", cyc, dut.p2_q.kind, dut.p2_q.line,
               dut.row2.way[dut.vw2].pres, dut.row2.way[dut.vw2].dirty);
  end

  initial begin
    cyc = 0; last_progress = 0; errors = 0; checks = 0; ops = 0;
    n_probe = 0; n_pack_data = 0; n_grant_b = 0; n_grant_t = 0; n_upgrade = 0; n_perm = 0; n_rel_data = 0; n_denied = 0;
    draining = 0; final_phase = 0; done = 0; max_acq = 0;
    for (int ag = 0; ag < NA; ag++) begin
      for (int k = 0; k < ACQ_N; k++) begin acq_busy[ag][k] = 0; acq_beats[ag][k] = 0; end
      rel_busy[ag] = 0;
    end
    ic_busy[0] = 0; ic_busy[1] = 0; mc_busy = 0;
    repeat (5) @(posedge clk);
    rst = 1'b0;
    wait (init_done);
    last_progress = cyc;
  end
endmodule
