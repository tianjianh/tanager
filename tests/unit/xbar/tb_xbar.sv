// Interconnect test (docs/spec/uncore.md §Verification): random TL-UL and TL-C messages from every
// initiator of a 2-core build with host DMA into stub targets that answer in order with random
// back-pressure. Checks routing of A (address, initiator type), C (address) and E (sink), return of
// D and B by source[9:6] with source[5:0] intact, contiguous multi-beat messages, no loss.
module tb_xbar;
  import tg_pkg::*, tg_tl_pkg::*, tg_map_pkg::*, tg_uncore_pkg::*;

  parameter bit SLICE_TB = 1'b0;     // the crossbar's slices: off as tg_uncore builds them (DR-186), or on (SLICE=1)

  localparam int NC = 2;
  localparam int NB = N_BANKS;

  logic clk = 1'b0, rst = 1'b1;
  always #5 clk = ~clk;
  longint unsigned cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // initiator side
  tl_a_t [NC-1:0] l1i_a, l1d_a, mmio_a;  logic [NC-1:0] l1i_av, l1i_ar, l1d_av, l1d_ar, mmio_av, mmio_ar;
  tl_d_t [NC-1:0] l1i_d, l1d_d, mmio_d;  logic [NC-1:0] l1i_dv, l1i_dr, l1d_dv, l1d_dr, mmio_dv, mmio_dr;
  tl_b_t [NC-1:0] l1d_b;  logic [NC-1:0] l1d_bv, l1d_br;
  tl_c_t [NC-1:0] l1d_c;  logic [NC-1:0] l1d_cv, l1d_cr;
  tl_e_t [NC-1:0] l1d_e;  logic [NC-1:0] l1d_ev, l1d_er;
  tl_a_t hdma_a; logic hdma_av, hdma_ar; tl_d_t hdma_d; logic hdma_dv, hdma_dr;
  // target side
  tl_a_t [NB-1:0] l2_a; logic [NB-1:0] l2_av, l2_ar;
  tl_b_t [NB-1:0] l2_b; logic [NB-1:0] l2_bv, l2_br;
  tl_c_t [NB-1:0] l2_c; logic [NB-1:0] l2_cv, l2_cr;
  tl_d_t [NB-1:0] l2_d; logic [NB-1:0] l2_dv, l2_dr;
  tl_e_t [NB-1:0] l2_e; logic [NB-1:0] l2_ev, l2_er;
  tl_a_t rom_a, dev_a; logic rom_av, rom_ar, dev_av, dev_ar;
  tl_d_t rom_d, dev_d; logic rom_dv, rom_dr, dev_dv, dev_dr;

  tg_xbar #(.N_CORES (NC), .HOST_DMA (1'b1), .SLICE (SLICE_TB)) dut (
    .clk, .rst,
    .l1i_a_i (l1i_a), .l1i_a_valid_i (l1i_av), .l1i_a_ready_o (l1i_ar),
    .l1i_d_o (l1i_d), .l1i_d_valid_o (l1i_dv), .l1i_d_ready_i (l1i_dr),
    .l1d_a_i (l1d_a), .l1d_a_valid_i (l1d_av), .l1d_a_ready_o (l1d_ar),
    .l1d_b_o (l1d_b), .l1d_b_valid_o (l1d_bv), .l1d_b_ready_i (l1d_br),
    .l1d_c_i (l1d_c), .l1d_c_valid_i (l1d_cv), .l1d_c_ready_o (l1d_cr),
    .l1d_d_o (l1d_d), .l1d_d_valid_o (l1d_dv), .l1d_d_ready_i (l1d_dr),
    .l1d_e_i (l1d_e), .l1d_e_valid_i (l1d_ev), .l1d_e_ready_o (l1d_er),
    .mmio_a_i (mmio_a), .mmio_a_valid_i (mmio_av), .mmio_a_ready_o (mmio_ar),
    .mmio_d_o (mmio_d), .mmio_d_valid_o (mmio_dv), .mmio_d_ready_i (mmio_dr),
    .hdma_a_i (hdma_a), .hdma_a_valid_i (hdma_av), .hdma_a_ready_o (hdma_ar),
    .hdma_d_o (hdma_d), .hdma_d_valid_o (hdma_dv), .hdma_d_ready_i (hdma_dr),
    .l2_a_o (l2_a), .l2_a_valid_o (l2_av), .l2_a_ready_i (l2_ar),
    .l2_b_i (l2_b), .l2_b_valid_i (l2_bv), .l2_b_ready_o (l2_br),
    .l2_c_o (l2_c), .l2_c_valid_o (l2_cv), .l2_c_ready_i (l2_cr),
    .l2_d_i (l2_d), .l2_d_valid_i (l2_dv), .l2_d_ready_o (l2_dr),
    .l2_e_o (l2_e), .l2_e_valid_o (l2_ev), .l2_e_ready_i (l2_er),
    .rom_a_o (rom_a), .rom_a_valid_o (rom_av), .rom_a_ready_i (rom_ar),
    .rom_d_i (rom_d), .rom_d_valid_i (rom_dv), .rom_d_ready_o (rom_dr),
    .dev_a_o (dev_a), .dev_a_valid_o (dev_av), .dev_a_ready_i (dev_ar),
    .dev_d_i (dev_d), .dev_d_valid_i (dev_dv), .dev_d_ready_o (dev_dr)
  );

  // Port signature: every cycle, every output of the DUT (payloads only while valid). Two builds with
  // the same seed and signature behave identically at the ports, cycle by cycle (the cycle-identity
  // check for rewrites, docs/perf/fpga_friendly.md).
  logic [63:0] psig = 64'hcbf2_9ce4_8422_2325;
  function automatic logic [63:0] fnv(input logic [63:0] h, input logic [255:0] x);
    for (int b = 0; b < 32; b++) h = (h ^ 64'(x[8*b +: 8])) * 64'h0000_0100_0000_01b3;
    return h;
  endfunction
  function automatic logic [255:0] pv(input logic v, input logic [255:0] x);
    return v ? x : '0;
  endfunction
  always @(posedge clk) if (!rst) begin
    logic [63:0] h;
    h = fnv(psig, 256'({cyc[15:0], l1i_ar, l1d_ar, mmio_ar, hdma_ar, l1d_cr, l1d_er, l2_br, l2_dr, rom_dr, dev_dr,
                        l1i_dv, l1d_dv, mmio_dv, hdma_dv, l1d_bv, l2_av, l2_cv, l2_ev, rom_av, dev_av}));
    for (int c = 0; c < NC; c++) begin
      h = fnv(h, pv(l1i_dv[c], 256'(l1i_d[c])));
      h = fnv(h, pv(l1d_dv[c], 256'(l1d_d[c])));
      h = fnv(h, pv(mmio_dv[c], 256'(mmio_d[c])));
      h = fnv(h, pv(l1d_bv[c], 256'(l1d_b[c])));
    end
    for (int b = 0; b < NB; b++) begin
      h = fnv(h, pv(l2_av[b], 256'(l2_a[b])));
      h = fnv(h, pv(l2_cv[b], 256'(l2_c[b])));
      h = fnv(h, pv(l2_ev[b], 256'(l2_e[b])));
    end
    h = fnv(h, pv(hdma_dv, 256'(hdma_d)));
    h = fnv(h, pv(rom_av, 256'(rom_a)));
    h = fnv(h, pv(dev_av, 256'(dev_a)));
    psig <= h;
  end

  int errors = 0;
  task automatic fail(input string m);
    errors++;
    $display("[%0d] ERROR: %s", cyc, m);
    if (errors > 20) begin $display("TEST FAILED"); $finish; end
  endtask

  // ---------------------------------------------------------------------------------------------
  // Expected routing (independent re-statement of the spec table)
  // ---------------------------------------------------------------------------------------------
  function automatic int exp_target(input int ini, input logic [33:0] addr);
    pma_e p;
    p = pma_of(addr);
    if (p == PMA_MEM) return T_L2B0 + int'(addr[6]);
    if (p == PMA_ROM && ini >= 4 && ini < 12) return T_ROM;
    if (p == PMA_DEVICE && ini >= 8 && ini < 12) return T_DEV;
    return T_ERR;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Initiators: per initiator a queue of A messages; responses matched by source
  // ---------------------------------------------------------------------------------------------
  localparam int NI = 16;
  typedef struct { tl_a_t hdr; int nbeats; int ini; int tgt; } amsg_t;
  amsg_t   iq [NI][$];                 // to send
  int      i_beat [NI];
  int      outst [NI][64];             // expected D beats left, by local source
  int      exp_d_tgt [NI][64];
  bit      present [NI];
  int      n_sent, n_resp, n_c, n_e, n_b;
  int      dbeats [NI][64];

  // Pending checks at targets: messages expected to arrive per target, keyed by full source
  int      t_expect [N_TGT][1024];     // count of messages expected

  // Random addresses that exercise every PMA class
  function automatic logic [33:0] rand_addr(input logic [2:0] size);
    int k;
    logic [33:0] a;
    k = int'($urandom_range(99));
    if (k < 50)      a = 34'h8000_0000 + 34'($urandom_range(1 << 20));
    else if (k < 62) a = 34'h1000 + 34'($urandom_range(4095));
    else if (k < 70) a = ACLINT_BASE + 34'($urandom_range(16'hFFFF));
    else if (k < 76) a = PLIC_BASE + 34'($urandom_range(32'hFFFFF));
    else if (k < 84) a = UART_BASE + 34'($urandom_range(4095));
    else if (k < 90) a = HOSTCTL_BASE + 34'($urandom_range(4095));
    else if (k < 95) a = 34'h2000_0000 + 34'($urandom_range(1 << 20));     // nothing there
    else             a = VIRTIO_BASE + 34'($urandom_range(16'h3FFF));
    return a & ~34'((1 << size) - 1);
  endfunction

  task automatic new_req(input int ini);
    amsg_t m;
    int ls;
    logic [2:0] sz;
    bit put;
    // a free local source
    ls = -1;
    for (int k = 0; k < 8; k++) begin
      int c;
      c = int'($urandom_range(63));
      if (outst[ini][c] == 0) begin ls = c; break; end
    end
    if (ls < 0) return;
    m.hdr = '0;
    m.ini = ini;
    if (ini < 4) begin                               // l1d: Acquire to memory
      m.hdr.opcode = ($urandom_range(1)) ? A_ACQUIRE_BLOCK : A_ACQUIRE_PERM;
      m.hdr.param  = TL_GROW_N_TO_T;
      sz = 3'd6;
      m.hdr.address = 34'h8000_0000 + 34'($urandom_range(1 << 20) << 6);
      if ($urandom_range(19) == 0) m.hdr.address = rand_addr(3'd6);   // occasionally misrouted
      put = 0;
    end else if (ini < 8) begin                      // l1i: line Gets
      m.hdr.opcode = A_GET;
      sz = 3'd6;
      m.hdr.address = rand_addr(sz);
      put = 0;
    end else if (ini < 12) begin                     // mmio: Get/Put <= 8 bytes
      sz  = 3'($urandom_range(3));
      put = $urandom_range(1);
      m.hdr.opcode = put ? A_PUT_FULL : A_GET;
      m.hdr.address = rand_addr(sz);
    end else begin                                   // host DMA: Gets and multi-beat Puts to memory
      sz  = 3'($urandom_range(6));
      put = $urandom_range(1);
      m.hdr.opcode = put ? A_PUT_FULL : A_GET;
      m.hdr.address = (34'h8000_0000 + 34'($urandom_range(1 << 20) << 6)) & ~34'((1 << sz) - 1);
    end
    m.hdr.size   = sz;
    m.hdr.source = TL_SRC_W'(ls);                    // the initiator drives [5:0] and zero above
    m.hdr.mask   = '1;
    m.nbeats     = put ? int'(tl_last_beat(sz)) + 1 : 1;
    m.tgt        = exp_target(ini, m.hdr.address);
    outst[ini][ls] = 1;                              // one response message
    exp_d_tgt[ini][ls] = m.tgt;
    t_expect[m.tgt][{4'(ini), 6'(ls)}]++;
    iq[ini].push_back(m);
    n_sent++;
  endtask

  // ---------------------------------------------------------------------------------------------
  // Target stubs: collect A messages, check routing and contiguity, answer in order
  // ---------------------------------------------------------------------------------------------
  typedef struct { tl_d_t hdr; int nbeats; } dresp_t;
  dresp_t tq [N_TGT][$];
  int     t_dbeat [N_TGT];
  int     t_abeat [N_TGT];
  logic [TL_SRC_W-1:0] t_asrc [N_TGT];
  int     sink_ctr [NB];

  task automatic target_got_a(input int t, input tl_a_t x);
    int ini;
    ini = int'(x.source[9:6]);
    if (t_abeat[t] == 0) begin
      if (t_expect[t][x.source] == 0) fail($sformatf("target %0d: unexpected A from source %h addr %h", t, x.source, x.address));
      else t_expect[t][x.source]--;
      t_asrc[t] = x.source;
    end else if (x.source != t_asrc[t]) fail($sformatf("target %0d: A beats interleaved", t));
    if (t_abeat[t] == int'(tl_a_last(x.opcode, x.size))) begin
      dresp_t r;
      t_abeat[t] = 0;
      r.hdr = '0;
      r.hdr.source = x.source;
      r.hdr.size   = x.size;
      if (x.opcode == A_ACQUIRE_BLOCK || x.opcode == A_ACQUIRE_PERM) begin
        r.hdr.opcode = (x.opcode == A_ACQUIRE_BLOCK) ? D_GRANT_DATA : D_GRANT;
        if (t < NB) begin
          r.hdr.sink = TL_SINK_W'({1'(t), 5'(sink_ctr[t] % 24)});
          sink_ctr[t]++;
        end else r.hdr.sink = SINK_ERR;
      end else begin
        r.hdr.opcode = (x.opcode == A_GET) ? D_ACCESS_ACK_DATA : D_ACCESS_ACK;
      end
      r.nbeats = int'(tl_d_last(r.hdr.opcode, r.hdr.size)) + 1;
      tq[t].push_back(r);
    end else t_abeat[t]++;
  endtask

  // Agents' C traffic, E acknowledgements and B probes
  typedef struct { tl_c_t hdr; int nbeats; } cmsg_t;
  cmsg_t cq [NC][$];
  int    c_beat [NC];
  int    c_rx_beat [NB];
  logic [TL_SRC_W-1:0] c_rx_src [NB];
  tl_e_t eq [NC][$];
  int    exp_c [NB];                  // C messages expected per bank
  int    exp_e [NB + 1];              // E per bank, [NB] = swallowed (SINK_ERR)
  int    exp_b [NC];
  int    rel_acks [NC];               // ReleaseAcks expected per agent
  tl_b_t bq [NB][$];

  // ---------------------------------------------------------------------------------------------
  // The TB process
  // ---------------------------------------------------------------------------------------------
  bit stop;
  always @(posedge clk) begin
    if (rst) begin
      l1i_av <= '0; l1d_av <= '0; mmio_av <= '0; hdma_av <= 1'b0; l1d_cv <= '0; l1d_ev <= '0;
      l2_bv <= '0; l2_dv <= '0; rom_dv <= 1'b0; dev_dv <= 1'b0;
      l2_ar <= '0; l2_cr <= '0; l2_er <= '0; rom_ar <= 1'b0; dev_ar <= 1'b0;
      l1i_dr <= '0; l1d_dr <= '0; mmio_dr <= '0; hdma_dr <= 1'b0; l1d_br <= '0;
    end else begin
      // ---- initiator A handshakes ----
      for (int i = 0; i < NI; i++) begin
        logic av, ar;
        av = 0; ar = 0;
        if (i < 4 && i < NC)              begin av = l1d_av[i];      ar = l1d_ar[i];      end
        else if (i >= 4 && i < 4 + NC)    begin av = l1i_av[i-4];    ar = l1i_ar[i-4];    end
        else if (i >= 8 && i < 8 + NC)    begin av = mmio_av[i-8];   ar = mmio_ar[i-8];   end
        else if (i == 12)                 begin av = hdma_av;        ar = hdma_ar;        end
        if (av && ar) begin
          if (i_beat[i] == iq[i][0].nbeats - 1) begin void'(iq[i].pop_front()); i_beat[i] = 0; end
          else i_beat[i]++;
        end
      end
      // ---- target A arrivals ----
      for (int b = 0; b < NB; b++) if (l2_av[b] && l2_ar[b]) target_got_a(T_L2B0 + b, l2_a[b]);
      if (rom_av && rom_ar) target_got_a(T_ROM, rom_a);
      if (dev_av && dev_ar) target_got_a(T_DEV, dev_a);
      // the error responder is inside the DUT: account for its responses at the initiators
      // ---- target D handshakes ----
      for (int b = 0; b < NB; b++) if (l2_dv[b] && l2_dr[b]) begin
        if (t_dbeat[T_L2B0+b] == tq[T_L2B0+b][0].nbeats - 1) begin void'(tq[T_L2B0+b].pop_front()); t_dbeat[T_L2B0+b] = 0; end
        else t_dbeat[T_L2B0+b]++;
      end
      if (rom_dv && rom_dr) begin
        if (t_dbeat[T_ROM] == tq[T_ROM][0].nbeats - 1) begin void'(tq[T_ROM].pop_front()); t_dbeat[T_ROM] = 0; end
        else t_dbeat[T_ROM]++;
      end
      if (dev_dv && dev_dr) begin
        if (t_dbeat[T_DEV] == tq[T_DEV][0].nbeats - 1) begin void'(tq[T_DEV].pop_front()); t_dbeat[T_DEV] = 0; end
        else t_dbeat[T_DEV]++;
      end
      // ---- initiator D arrivals ----
      for (int i = 0; i < NI; i++) begin
        logic dv, dr;
        tl_d_t x;
        dv = 0; dr = 0; x = '0;
        if (i < NC)                    begin dv = l1d_dv[i];   dr = l1d_dr[i];   x = l1d_d[i];   end
        else if (i >= 4 && i < 4 + NC) begin dv = l1i_dv[i-4]; dr = l1i_dr[i-4]; x = l1i_d[i-4]; end
        else if (i >= 8 && i < 8 + NC) begin dv = mmio_dv[i-8]; dr = mmio_dr[i-8]; x = mmio_d[i-8]; end
        else if (i == 12)              begin dv = hdma_dv;     dr = hdma_dr;     x = hdma_d;     end
        if (dv && dr) begin
          int ls;
          ls = int'(x.source[5:0]);
          if (int'(x.source[9:6]) != i) fail($sformatf("D for initiator %0d delivered to %0d", x.source[9:6], i));
          if (x.opcode == D_RELEASE_ACK) begin
            if (i >= NC || rel_acks[i] == 0) fail("unexpected ReleaseAck");
            else rel_acks[i]--;
          end else if (outst[i][ls] == 0) fail($sformatf("D to initiator %0d source %0d with nothing outstanding", i, ls));
          else begin
            // count beats; the last beat completes the request
            if (exp_d_tgt[i][ls] == T_ERR && !x.denied) fail("error target answered without denied");
            if (dbeats[i][ls] == int'(tl_d_last(x.opcode, x.size))) begin
              dbeats[i][ls] = 0;
              outst[i][ls] = 0;
              n_resp++;
              if (x.opcode == D_GRANT || x.opcode == D_GRANT_DATA) begin
                tl_e_t e;
                e.sink = x.sink;
                eq[i].push_back(e);
                if (x.sink == SINK_ERR) exp_e[NB]++; else exp_e[x.sink[5]]++;
              end
            end else dbeats[i][ls]++;
          end
        end
      end
      // ---- C, E, B ----
      for (int c = 0; c < NC; c++) begin
        if (l1d_cv[c] && l1d_cr[c]) begin
          if (c_beat[c] == cq[c][0].nbeats - 1) begin void'(cq[c].pop_front()); c_beat[c] = 0; end
          else c_beat[c]++;
        end
        if (l1d_ev[c] && l1d_er[c]) void'(eq[c].pop_front());
        if (l1d_bv[c] && l1d_br[c]) begin
          if (int'(l1d_b[c].source[7:6]) != c) fail("probe delivered to the wrong agent");
          if (exp_b[c] == 0) fail("unexpected probe"); else exp_b[c]--;
          n_b++;
        end
      end
      for (int b = 0; b < NB; b++) begin
        if (l2_cv[b] && l2_cr[b]) begin
          if (l2_c[b].address[6] != 1'(b)) fail("C routed to the wrong bank");
          if (c_rx_beat[b] == 0) c_rx_src[b] = l2_c[b].source;
          else if (l2_c[b].source != c_rx_src[b]) fail("C beats interleaved");
          if (c_rx_beat[b] == int'(tl_c_last(l2_c[b].opcode, l2_c[b].size))) begin
            c_rx_beat[b] = 0;
            if (exp_c[b] == 0) fail("unexpected C"); else exp_c[b]--;
            n_c++;
            if (l2_c[b].opcode == C_RELEASE || l2_c[b].opcode == C_RELEASE_DATA) begin
              dresp_t r;
              r.hdr = '0;
              r.hdr.opcode = D_RELEASE_ACK;
              r.hdr.source = l2_c[b].source;
              r.hdr.size   = 3'd6;
              r.nbeats     = 1;
              tq[T_L2B0 + b].push_back(r);
            end
          end else c_rx_beat[b]++;
        end
        if (l2_ev[b] && l2_er[b]) begin
          if (l2_e[b].sink[5] != 1'(b)) fail("E routed to the wrong bank");
          if (exp_e[b] == 0) fail("unexpected E"); else exp_e[b]--;
          n_e++;
        end
        if (l2_bv[b] && l2_br[b]) void'(bq[b].pop_front());
      end

      // ---- new traffic ----
      if (!stop) begin
        for (int i = 0; i < NI; i++)
          if (present[i] && iq[i].size() < 3 && $urandom_range(99) < 15) new_req(i);
        for (int c = 0; c < NC; c++)
          if (cq[c].size() < 3 && $urandom_range(99) < 5) begin
            cmsg_t m;
            int k;
            k = int'($urandom_range(3));
            m.hdr = '0;
            m.hdr.opcode  = (k == 0) ? C_RELEASE : (k == 1) ? C_RELEASE_DATA : (k == 2) ? C_PROBE_ACK : C_PROBE_ACK_DATA;
            m.hdr.size    = 3'd6;
            m.hdr.source  = TL_SRC_W'(6'($urandom_range(63)));
            m.hdr.address = 34'h8000_0000 + 34'($urandom_range(1 << 20) << 6);
            m.nbeats      = (k == 1 || k == 3) ? 4 : 1;
            exp_c[m.hdr.address[6]]++;
            if (k < 2) rel_acks[c]++;
            cq[c].push_back(m);
          end
        for (int b = 0; b < NB; b++)
          if (bq[b].size() < 2 && $urandom_range(99) < 4) begin
            tl_b_t p;
            int ag;
            ag = int'($urandom_range(NC - 1));
            p = '0;
            p.opcode  = B_PROBE_BLOCK;
            p.param   = TL_CAP_TO_N;
            p.size    = 3'd6;
            p.source  = TL_SRC_W'({4'(ag), 6'd0});
            p.address = 34'h8000_0000 + 34'(b << 6);
            exp_b[ag]++;
            bq[b].push_back(p);
          end
      end

      // ---- drive ----
      for (int i = 0; i < NI; i++) begin
        tl_a_t x;
        logic v;
        v = iq[i].size() > 0 && ($urandom_range(99) < 80);
        x = (iq[i].size() > 0) ? iq[i][0].hdr : '0;
        // the caches send no data on A (interfaces.md §2.2, §2.3: Gets and Acquires), and drive zeros
        x.data = (i < NC || (i >= 4 && i < 4 + NC)) ? '0 : {4{32'(i_beat[i])}};
        if (i < NC)                    begin l1d_a[i] <= x;   l1d_av[i] <= v;   end
        else if (i >= 4 && i < 4 + NC) begin l1i_a[i-4] <= x; l1i_av[i-4] <= v; end
        else if (i >= 8 && i < 8 + NC) begin mmio_a[i-8] <= x; mmio_av[i-8] <= v; end
        else if (i == 12)              begin hdma_a <= x;     hdma_av <= v;     end
      end
      for (int t = 0; t < N_TGT - 1; t++) begin
        tl_d_t x;
        logic v;
        v = tq[t].size() > 0 && ($urandom_range(99) < 80);
        x = (tq[t].size() > 0) ? tq[t][0].hdr : '0;
        if (t < NB)            begin l2_d[t] <= x; l2_dv[t] <= v; end
        else if (t == T_ROM)   begin rom_d <= x;   rom_dv <= v;   end
        else if (t == T_DEV)   begin dev_d <= x;   dev_dv <= v;   end
      end
      for (int c = 0; c < NC; c++) begin
        tl_c_t x;
        x = (cq[c].size() > 0) ? cq[c][0].hdr : '0;
        l1d_c[c]  <= x;
        l1d_cv[c] <= cq[c].size() > 0 && ($urandom_range(99) < 80);
        l1d_e[c]  <= (eq[c].size() > 0) ? eq[c][0] : '0;
        l1d_ev[c] <= eq[c].size() > 0 && ($urandom_range(99) < 80);
        l1d_br[c] <= ($urandom_range(99) < 70);
      end
      for (int b = 0; b < NB; b++) begin
        l2_b[b]  <= (bq[b].size() > 0) ? bq[b][0] : '0;
        l2_bv[b] <= bq[b].size() > 0 && ($urandom_range(99) < 80);
        l2_ar[b] <= ($urandom_range(99) < 70);
        l2_cr[b] <= ($urandom_range(99) < 70);
        l2_er[b] <= ($urandom_range(99) < 70);
      end
      rom_ar  <= ($urandom_range(99) < 70);
      dev_ar  <= ($urandom_range(99) < 70);
      l1i_dr  <= {NC{$urandom_range(99) < 70}};
      l1d_dr  <= {NC{$urandom_range(99) < 70}};
      mmio_dr <= {NC{$urandom_range(99) < 70}};
      hdma_dr <= ($urandom_range(99) < 70);
    end
  end

  int unsigned seed;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    for (int i = 0; i < NI; i++) begin
      present[i] = (i < NC) || (i >= 4 && i < 4 + NC) || (i >= 8 && i < 8 + NC) || i == 12;
      i_beat[i] = 0;
      for (int k = 0; k < 64; k++) begin outst[i][k] = 0; dbeats[i][k] = 0; end
    end
    stop = 0; n_sent = 0; n_resp = 0; n_c = 0; n_e = 0; n_b = 0;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    repeat (20000) @(posedge clk);
    stop = 1;
    repeat (3000) @(posedge clk);
    // everything delivered?
    for (int i = 0; i < NI; i++) for (int k = 0; k < 64; k++) if (outst[i][k] != 0) fail($sformatf("initiator %0d source %0d never answered", i, k));
    for (int b = 0; b < NB; b++) if (exp_c[b] != 0 || exp_e[b] != 0) fail($sformatf("bank %0d: %0d C / %0d E undelivered", b, exp_c[b], exp_e[b]));
    for (int c = 0; c < NC; c++) if (exp_b[c] != 0 || rel_acks[c] != 0) fail($sformatf("agent %0d: %0d probes / %0d ReleaseAcks undelivered", c, exp_b[c], rel_acks[c]));
    $display("xbar: %0d requests, %0d responses, %0d C, %0d E, %0d probes", n_sent, n_resp, n_c, n_e, n_b);
    $display("xbar: port signature %016h", psig);
    if (errors == 0) $display("TEST PASSED (seed %0d)", seed); else $display("TEST FAILED (seed %0d)", seed);
    $finish;
  end
endmodule
