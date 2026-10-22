// L1 data cache for M2 (docs/spec/core-lsu.md): L1D_KIB, L1_WAYS ways, 64-byte lines, one MSHR,
// TL-C client on l1d.
//   Data: per way a tg_ram_tdp of SETS*4 rows x 128 bits with byte enables. Port A: load reads
//         (address in AG, data in M1). Port B: Grant writes, store writes, Release and
//         ProbeAckData reads. With DC_PORTB_WREG (DR-148 #11) port B's writes reach the RAMs a
//         cycle later from a register, its reads wait while one does, and the LSU retries a load
//         that read the row in either cycle.
//   Tags: per way a tg_ram_lut, read ports: load (M1), store drain, controller (probe/victim).
//   State per set in one tg_ram_lut: the round-robin victim pointer and valid, T (M/E) and
//   dirty per way. Four read ports (load, store/atomic, controller, the set being written) and
//   one write per cycle, a read-modify-write of one set, by priority: the reset sweep, a probe
//   update, an MSHR install, an allocation, a store or atomic setting dirty. The sweep clears
//   the sets after reset (SETS cycles, `ready`); probes wait for it.
//   MSHR: one line at a time (DC_MSHRS = 1), for a load miss (AcquireBlock NtoB) or a store
//         (NtoT, or BtoT for a line held in B). A valid victim is released first (state cleared
//         when the Release starts, so probes and stores see the line as gone); the Acquire waits
//         for ReleaseAck. With DC_MSHRS = 4 (DR-149) four lines are in flight: the entries, the
//         release engine and the loads' request register of g_mn (below; core-lsu.md). With
//         STORE_PF (DR-171) a store's line is also requested with T when its address decides
//         (pf_req), through a spare entry: g_mn's pending prefetch.
//   Probes: answered at the line's current permission, without waiting on A-channel progress.
//         They take B only while no Release is being sent (C beats are contiguous), and block
//         the MSHR from starting and the store path from writing while they run.
//   Atomics: the line is acquired with T like a store's; then one port B read and, the next
//         cycle, the write (am_ack). With DC_AMO_READ_REG (DR-140 #5) a cycle between them
//         registers the read data. Nothing else uses port B, the MSHR does not start and no probe
//         is accepted across these cycles, so the read-modify-write is atomic.
//   lose_v reports a line that left the cache or lost T (probe, eviction): it ends an LR
//         reservation on that line.
module tg_dcache
  import tg_pkg::*, tg_tl_pkg::*, tg_core_pkg::*;
#(
  localparam int WAYS  = L1_WAYS,
  localparam int SETS  = (L1D_KIB * 1024) / (WAYS * 64),
  localparam int SET_W = idx_w(SETS),
  localparam int WAY_W = idx_w(WAYS),
  localparam int TAG_W = PA_W - 12,
  localparam int ROWS  = SETS * 4,
  localparam int ROW_W = idx_w(ROWS),
  localparam int MSW   = idx_w(DC_MSHRS)   // a miss entry's index
) (
  input  logic              clk,
  input  logic              rst,
  output logic              ready,        // the state sweep after reset is done
  // Load pipe: port A read issued in AG; lookup in M1 (combinational)
  input  logic              ld_rd_en,
  input  logic [PA_W-1:0]   ld_rd_pa,
  input  logic [PA_W-1:0]   ld_m1_pa,
  output logic              ld_hit,
  output logic [63:0]       ld_dword,
  // Load miss: take a miss entry for this line if one is free (DC_MSHRS > 1: through a request
  // register, answered two cycles after lm_req)
  input  logic              lm_req,
  input  logic [PA_W-1:0]   lm_pa,
  output logic              mshr_idle,    // registered state: no miss in flight
  output logic              lm_fdn,       // lm_pa's line: its last fill was denied
  output logic              lm_ans_v,     // DC_MSHRS > 1, registered: the request two cycles back
  output logic              lm_ans_wait,  //   waits for entry lm_ans_e to install (else: retry now)
  output logic [MSW-1:0]    lm_ans_e,
  output logic [DC_MSHRS-1:0] m_done,     //   registered: entry e installed last cycle
  output logic              m_wake_any,   //   registered: an entry installed, or none is busy
  // Store ownership prefetch (STORE_PF, DC_MSHRS > 1): this line, wanted with T, through a spare miss
  // entry if it is absent or held in B; a hint, with no answer
  input  logic              pf_req,
  input  logic [PA_W-1:0]   pf_pa,
  // Store drain: one request at a time, held until st_ack
  input  logic              st_req,
  input  logic [PA_W-1:0]   st_pa,
  input  logic [15:0]       st_mask,
  input  logic [63:0]       st_wdata,     // the bytes in their lanes of both dwords (st_mask picks)
  output logic              st_ack,
  output logic              st_dropped,   // acked without writing (denied Grant)
  // M7 (two threads, SPLIT): the store port's request (a store or an atomic) needs a new miss entry and gets none
  // this cycle; and a store waits for one (the LSU's per-thread record of st_wait): loads leave it the last entry
  output logic              st_wait,
  input  logic              st_resv,
  // Atomics: read-modify-write of one row with the line held in T (never with st_req)
  input  logic              am_req,       // held until am_ack or am_den
  input  logic              am_sel,       // the atomic holds the store port (its state: am_req
                                          // without the flush and its PMP flag)
  input  logic              pr_hold,      // probes wait: an LR's reservation is young (a register)
  input  logic [PA_W-1:0]   am_pa,
  input  logic [15:0]       am_wmask,     // in the am_ack cycle: bytes to write (0: none)
  input  logic [63:0]       am_wdata,     // as st_wdata
  output logic              am_ack,       // am_rdata valid; am_wmask/am_wdata written
  output logic [63:0]       am_rdata,     // the addressed dword before the write
  output logic              am_den,       // the line's last fill was denied
  output logic              lose_v,       // registered: lose_line left the cache or lost T
  output logic [PA_W-1:6]   lose_line,
  // l1d (TL-C)
  output tl_a_t             a_o,
  output logic              a_valid_o,
  input  logic              a_ready_i,
  input  tl_b_t             b_i,
  input  logic              b_valid_i,
  output logic              b_ready_o,
  output tl_c_t             c_o,
  output logic              c_valid_o,
  input  logic              c_ready_i,
  input  tl_d_t             d_i,
  input  logic              d_valid_i,
  output logic              d_ready_o,
  output tl_e_t             e_o,
  output logic              e_valid_o,
  input  logic              e_ready_i,
  output logic [7:0]        dbg_o,        // board debug: {ready, the miss side, ps_q} (tg_core's dbg_o)
  input  logic              split_i       // M7's step 6: the window is split (else one thread runs: the store
                                          // reservation below is off, as before M7)
);

  // ---- Arrays ----
  logic [WAYS-1:0]        b_en;          // port B's access as decided
  logic [15:0]            b_we;
  logic [ROW_W-1:0]       b_addr;
  logic [127:0]           b_wdata;
  logic [WAYS-1:0]        rb_en;         // ... at the RAMs (#11: the writes a cycle later)
  logic [15:0]            rb_we;
  logic [ROW_W-1:0]       rb_addr;
  logic [127:0]           rb_wdata;
  logic                   bw_busy;       // #11: a registered write takes port B this cycle
  logic [WAYS-1:0][127:0] a_rdata, b_rdata;
  for (genvar w = 0; w < WAYS; w++) begin : g_data
    tg_ram_tdp #(.DEPTH(ROWS), .WIDTH(128), .BYTE_W(8), .OUT_REG(1'b0), .PRIM("block")) u_data (
      .clk,
      .en_a(ld_rd_en), .we_a('0), .addr_a(ld_rd_pa[4 +: ROW_W]), .wdata_a('0), .rdata_a(a_rdata[w]),
      .en_b(rb_en[w]), .we_b(rb_we), .addr_b(rb_addr), .wdata_b(rb_wdata),
      .rdata_b(b_rdata[w]));
  end

  logic                         tag_we;
  logic [WAY_W-1:0]             tag_way;
  logic [SET_W-1:0]             tag_set;
  logic [TAG_W-1:0]             tag_wd;
  logic [WAYS-1:0][2:0][TAG_W-1:0] tag_rd;
  logic [2:0][SET_W-1:0]        tag_ra;
  logic [PA_W-1:0]              ctl_pa;     // controller lookup address
  logic                         sx_req;     // store or atomic: port 1 lookup and NtoT/BtoT
  logic [PA_W-1:0]              sx_pa;
  assign sx_req    = st_req || am_req;
  // The store port's address follows the atomic's state alone (a register): no store drains while
  // an atomic holds the port, and without a request the lookup is unused (timing, DR-145: in G6
  // the flush and the atomic's PMP flag reached the tag reads through am_req, -1.48 ns)
  assign sx_pa     = am_sel ? am_pa : st_pa;
  assign tag_ra[0] = ld_m1_pa[6 +: SET_W];
  assign tag_ra[1] = sx_pa[6 +: SET_W];
  assign tag_ra[2] = ctl_pa[6 +: SET_W];
  for (genvar w = 0; w < WAYS; w++) begin : g_tag
    tg_ram_lut #(.DEPTH(SETS), .WIDTH(TAG_W), .NR(3)) u_tag (
      .clk, .we(tag_we && tag_way == WAY_W'(w)), .waddr(tag_set), .wdata(tag_wd), .raddr(tag_ra),
      .rdata(tag_rd[w]));
  end

  // ---- State per set (LUTRAM) ----
  // Two RAMs written together: the valid bits, read by all four ports, and the rest, which the
  // load port does not read
  typedef struct packed {
    logic [WAY_W-1:0] rr;
    logic [WAYS-1:0]  v, t, d;
  } sst_t;
  localparam int SM_W = WAY_W + 2 * WAYS;     // rr, t, d
  logic [3:0][SET_W-1:0] st_ra;
  logic [3:0][WAYS-1:0]  sv_rd;
  logic [2:0][SM_W-1:0]  sm_rd;
  logic [WAYS-1:0]       sl_v;              // load port
  sst_t                  ss, sc, sw;        // store/atomic, controller, the written set
  logic                  st_we;
  logic [SET_W-1:0]      st_wa;
  sst_t                  st_wd;
  logic [SET_W:0]        init_q;
  assign ready = init_q[SET_W];
  assign st_ra[0] = ld_m1_pa[6 +: SET_W];
  assign st_ra[1] = sx_pa[6 +: SET_W];
  assign st_ra[2] = ctl_pa[6 +: SET_W];
  // Port 3 reads the set of a write whose set is a register: a probe update, an install, an
  // atomic's write. An allocation and a store take their set's state from their own ports (sa,
  // ss), which read it in the same cycle (timing, DR-145: the late arbitration selects the write
  // and no longer addresses a read before it; the data is the same, checked in simulation)
  logic [SET_W-1:0] ew_a;                   // (formed below the registers it reads)
  assign st_ra[3] = ew_a;
  tg_ram_lut #(.DEPTH(SETS), .WIDTH(WAYS), .NR(4)) u_valid (
    .clk, .we(st_we), .waddr(st_wa), .wdata(st_wd.v), .raddr(st_ra), .rdata(sv_rd));
  tg_ram_lut #(.DEPTH(SETS), .WIDTH(SM_W), .NR(3)) u_meta (
    .clk, .we(st_we), .waddr(st_wa), .wdata({st_wd.rr, st_wd.t, st_wd.d}), .raddr(st_ra[3:1]),
    .rdata(sm_rd));
  function automatic sst_t sst(input logic [WAYS-1:0] v, input logic [SM_W-1:0] m);
    return '{rr: m[2*WAYS +: WAY_W], v: v, t: m[WAYS +: WAYS], d: m[0 +: WAYS]};
  endfunction
  assign sl_v = sv_rd[0];
  assign ss   = sst(sv_rd[1], sm_rd[0]);
  assign sc   = sst(sv_rd[2], sm_rd[1]);
  assign sw   = sst(sv_rd[3], sm_rd[2]);

  // Lookups: hit vector per read port
  function automatic logic [WAYS-1:0] hits(input int port, input logic [TAG_W-1:0] tag,
                                          input logic [WAYS-1:0][2:0][TAG_W-1:0] tr,
                                          input logic [WAYS-1:0] v);
    logic [WAYS-1:0] h;
    for (int w = 0; w < WAYS; w++) h[w] = v[w] && tr[w][port] == tag;
    return h;
  endfunction
  function automatic logic [WAY_W-1:0] enc(input logic [WAYS-1:0] h);
    logic [WAY_W-1:0] r;
    r = '0;
    for (int w = 0; w < WAYS; w++) if (h[w]) r = WAY_W'(w);
    return r;
  endfunction

  // Load lookup (M1)
  logic [WAYS-1:0] lh;
  logic [127:0]    lrow;
  assign lh = hits(0, ld_m1_pa[12 +: TAG_W], tag_rd, sl_v);
  always_comb begin
    lrow = '0;
    for (int w = 0; w < WAYS; w++) lrow |= {128{lh[w]}} & a_rdata[w];
  end
  assign ld_hit   = |lh;
  assign ld_dword = ld_m1_pa[3] ? lrow[127:64] : lrow[63:0];

  // Store / atomic lookup
  logic [WAYS-1:0]  sh;
  logic [WAY_W-1:0] sh_way;
  logic             s_hit, s_hit_t;
  assign sh      = hits(1, sx_pa[12 +: TAG_W], tag_rd, ss.v);
  assign sh_way  = enc(sh);
  assign s_hit   = |sh;
  assign s_hit_t = |(sh & ss.t);           // one way at most hits (asserted): no way select

  // Controller lookup
  logic [WAYS-1:0]  ch;
  logic [WAY_W-1:0] ch_way;
  assign ch     = hits(2, ctl_pa[12 +: TAG_W], tag_rd, sc.v);
  assign ch_way = enc(ch);

  // ---- The miss side: one MSHR (DC_MSHRS = 1), or DC_MSHRS entries (DR-149) ----
  // The generate branch built (g_m1 or g_mn, after the sequential block) drives these; the rest of
  // the cache sees the miss side only through them
  logic             m_none;              // no miss in flight
  logic             m_on_c;              // a Release is being read or sent (port B's read register, C)
  logic             m_inst;              // an install waits for the state port
  logic             inst_go;             // ... and writes it this cycle (a probe update goes first)
  logic [PA_W-1:6]  mi_line;             // the install's line, way, denial, cap and kind
  logic [WAY_W-1:0] mi_way;
  logic             mi_den, mi_st;
  logic [2:0]       mi_cap;
  logic             pb_ev;               // the Release reads a beat through port B ...
  logic [WAY_W-1:0] mv_way;              // ... of this way, set and beat
  logic [SET_W-1:0] mv_set;
  logic [1:0]       mv_beat;
  logic             m_gwait;             // a Grant may come: D waits while a probe holds port B
  logic             grant_beat;          // a GrantData beat is accepted this cycle ...
  logic [WAY_W-1:0] mg_way;              // ... into this way, set and beat
  logic [SET_W-1:0] mg_set;
  logic [1:0]       mg_beat;
  logic             a_valid;             // the Acquire on A: its line, growth and source
  logic [PA_W-1:6]  a_line;
  logic [2:0]       a_grow;
  logic [TL_SRC_W-1:0] a_src;
  logic             e_valid;             // the GrantAck on E
  logic [TL_SINK_W-1:0] e_sink;
  logic             rel_send;            // the Release on C: dirty, from T, its line, source, data
  logic             rel_dirty, rel_t;
  logic [PA_W-1:6]  rel_line;
  logic [TL_SRC_W-1:0] rel_src;
  logic [127:0]     rel_data;
  logic             m_holdb;             // the Release's beat is port B's read output (held)
  logic             m_free_st, m_free_ld; // the miss side can take the store port's / a load's miss
  logic             c_req;               // the load miss the controller port looks up: lm_req, or
  logic [PA_W-1:0]  c_pa;                // DR-149's request register (or the pending prefetch: below)
  logic             m_free_pf;           // STORE_PF: the controller port looks up the pending prefetch,
                                         // and the miss side can take it (an entry to spare)
  logic             dn_hit;              // the store port's line: its last fill was denied
  logic [3:0]       m_dbg;               // board debug: the MSHR's state (DC_MSHRS = 1), or the release
                                         // engine busy and the number of busy entries
  assign mshr_idle = m_none;

  // ---- Probe FSM ----
  typedef enum logic [2:0] { P_IDLE, P_LOOK, P_RD, P_SEND, P_ACK, P_UPD } pstate_e;
  pstate_e          ps_q;
  logic [PA_W-1:0]  p_pa_q;
  logic [2:0]       p_cap_q;
  logic             p_perm_q;
  logic [TL_SRC_W-1:0] p_src_q;
  logic             p_hit_q, p_nv_q, p_nt_q;
  logic [2:0]       p_param_q;
  logic [WAY_W-1:0] p_way_q;
  logic [1:0]       p_beat_q;
  logic             probe_active;
  assign probe_active = ps_q != P_IDLE;

  assign ctl_pa = probe_active ? p_pa_q : c_pa;

  // ---- Atomic read-modify-write ----
  logic             pb_amr, amw_q;       // read cycle; write cycle
  logic             am_busy;             // the cycles from the read to the write
  logic             amw_d;               // the write comes next cycle
  logic [WAY_W-1:0] am_way_q;
  logic [ROW_W-1:0] am_row_q;
  logic             am_hi_q;
  assign am_ack = amw_q;

  // Port 3's address (above): the set of a probe update, an install or an atomic's write
  always_comb begin
    if (ps_q == P_UPD && p_hit_q) ew_a = p_pa_q[6 +: SET_W];
    else if (m_inst)              ew_a = mi_line[6 +: SET_W];
    else                          ew_a = am_row_q[ROW_W-1:2];
  end

  // ---- Forward progress under probes ----
  // A line installed for a store or an atomic keeps its first access: probes and other allocations
  // wait from the install until the store writes or the atomic reads it (am_busy then holds probes
  // until the atomic's write), at most FU_ST cycles. A load's line holds probes for FU_LD cycles,
  // its replay's time to M1. An LR's young reservation holds them too (pr_hold, the LSU's, up to
  // its SC). The holds come from registers, so b_ready_o stays a register function, and each wait
  // is bounded and independent of A-channel progress (TL-C rule 4). Without them, two cores whose
  // atomics or stores meet on one line could take it from each other forever: the probe for the
  // other's Acquire came in the install cycle, before the first access (the board's two-core
  // boot lottery, OpenSBI's amoswap)
  localparam int FU_ST = 8, FU_LD = 4;
  logic [3:0] fu_st_q, fu_ld_q;
  logic       fu_st, fu_hold;
  assign fu_st   = fu_st_q != '0;
  assign fu_hold = m_inst || fu_st || fu_ld_q != '0 || pr_hold;

  // ---- Allocation ----
  // A store's or an atomic's miss first, else a load's whose line is still absent (it may have
  // been filled since M1); never beside an atomic, which reads port B when it hits (pb_amr) and
  // allocates when it misses. Each port's victim and eviction fields come from its own state, and
  // the store port's miss selects last (timing, DR-145: in G6 the store port's compare -> the
  // allocation -> the MSHR's registers and the state write, -1.40 and -1.49 ns; the same decisions,
  // checked in simulation against the earlier form). m_free_st and m_free_ld say whether the miss
  // side can take each (one MSHR: when it is idle)
  // With two threads (M7's step 4, D8; smt2_report §13.10) a store or an atomic that needs a new entry keeps the last
  // free one from loads' requests until it allocates: in its own cycle (sx_new), and, as the drain takes turns between
  // the threads, while the LSU records its thread's head store waiting (st_resv). Else an entry that frees while the
  // store cannot take it (the release engine busy with its victim, or the drain presenting the other thread's store)
  // goes to the sibling's next load miss, and a pointer chase beside a store stream starves the drain. In merged mode
  // (SPLIT off, or with hart 1 while the sibling sleeps: split_i, step 6) the allocation is the one before M7.
  logic al_base;                         // nothing else holds the allocation's state write
  logic alloc_st, alloc_ld, alloc_pf;
  logic sx_new;                          // the store port's request needs a new entry (its line in none)
  logic m_spare;                         // the miss side has an entry to spare (DC_MSHRS > 1: two free)
  logic st_rsv;                          // loads leave the last entry to the store port
  logic st_rsvq;                         // ... from registers alone (the store port's request hits)
  assign al_base  = ps_q == P_IDLE && !b_valid_i && !am_busy && !fu_st && ready;
  assign alloc_st = al_base && m_free_st && sx_req && !s_hit_t;
  assign st_rsv   = SPLIT && split_i && (st_resv || (sx_req && !s_hit_t && !dn_hit && sx_new)) && !m_spare;
  assign st_rsvq  = SPLIT && split_i && st_resv && !m_spare;
  assign alloc_ld = al_base && m_free_ld && c_req && !(|ch) && !am_req && !(st_req && !s_hit_t && m_free_st) &&
                    !st_rsv;
  assign st_wait  = sx_req && !s_hit_t && !dn_hit && sx_new && !alloc_st;
  // A store's ownership prefetch (STORE_PF, DC_MSHRS > 1): its line, absent or held in B, through the
  // controller port in a cycle without a load's request; never for a line held with T, beside an
  // atomic, or when the store port writes or allocates (m_free_pf: the store port then has no request,
  // or waits for its own line in an entry, so it neither hits with T nor allocates)
  assign alloc_pf = al_base && m_free_pf && !(|(ch & sc.t)) && !am_req;
  logic [PA_W-1:0]  al_pa;
  assign al_pa = alloc_st ? sx_pa : c_pa;
  logic sx_drop;                         // a store/atomic whose line's fill was denied (below)
  logic al_go;                           // an allocation this cycle
  logic al_up;                           // ... a store's upgrade of its B line in place
  logic al_upc;                          // ... a prefetch's upgrade of its B line in place
  logic al_w;                            // ... with a victim, writing the set's state
  assign al_go   = (alloc_st && !dn_hit) || alloc_ld || alloc_pf;
  assign al_up   = alloc_st && !dn_hit && s_hit;
  assign al_upc  = alloc_pf && |ch;
  assign al_w    = (alloc_st && !dn_hit && !s_hit) || alloc_ld || (alloc_pf && !(|ch));
  // The victim: the first invalid way, else the round-robin pointer's. It is valid only when every
  // way is, so an eviction's way is the pointer's
  function automatic logic [WAY_W-1:0] vict(input logic [WAY_W-1:0] rr, input logic [WAYS-1:0] v);
    logic [WAY_W-1:0] r;
    logic found;
    found = 1'b0;
    r = rr;
    for (int w = 0; w < WAYS; w++) begin
      if (!found && !v[w]) begin
        r = WAY_W'(w);
        found = 1'b1;
      end
    end
    return r;
  endfunction
  // DC_MSHRS > 1: the first way from rr on (wrapping) that no entry holds, and the victim among the
  // ways no entry holds (an upgrade's B line stays valid; a fill's way was cleared at its
  // allocation). DC_MSHRS < WAYS, so there is one
  function automatic logic [WAY_W-1:0] from_rr(input logic [WAY_W-1:0] rr, input logic [WAYS-1:0] res);
    logic [WAY_W-1:0] r;
    logic found;
    found = 1'b0;
    r = rr;
    for (int i = 0; i < WAYS; i++) begin
      if (!found && !res[WAY_W'(rr + WAY_W'(i))]) begin
        r = WAY_W'(rr + WAY_W'(i));
        found = 1'b1;
      end
    end
    return r;
  endfunction
  function automatic logic [WAY_W-1:0] vict_r(input logic [WAY_W-1:0] rr, input logic [WAYS-1:0] v,
                                            input logic [WAYS-1:0] res);
    logic [WAY_W-1:0] r;
    logic found;
    found = 1'b0;
    r = from_rr(rr, res);
    for (int w = 0; w < WAYS; w++) begin
      if (!found && !v[w] && !res[w]) begin
        r = WAY_W'(w);
        found = 1'b1;
      end
    end
    return r;
  endfunction
  logic [WAY_W-1:0] victim_s, victim_c, victim;
  logic             ev_s, ev_c;          // the victim is valid: an eviction (store port, controller)
  logic [WAY_W-1:0] evw_s, evw_c;        // ... its way
  logic [TAG_W-1:0] evt_s, evt_c;        // ... and tag
  logic [WAYS-1:0]  res_s, res_c;        // the ways entries hold in the set (DC_MSHRS > 1)
  if (DC_MSHRS == 1) begin : g_vict1
    assign victim_s = vict(ss.rr, ss.v);
    assign victim_c = vict(sc.rr, sc.v);
    assign ev_s     = &ss.v;
    assign ev_c     = &sc.v;
    assign evw_s    = ss.rr;
    assign evw_c    = sc.rr;
  end else begin : g_victn
    assign victim_s = vict_r(ss.rr, ss.v, res_s);
    assign victim_c = vict_r(sc.rr, sc.v, res_c);
    assign ev_s     = &(ss.v | res_s);
    assign ev_c     = &(sc.v | res_c);
    assign evw_s    = from_rr(ss.rr, res_s);
    assign evw_c    = from_rr(sc.rr, res_c);
  end
  assign victim   = alloc_st ? victim_s : victim_c;
  assign evt_s    = tag_rd[evw_s][1];
  assign evt_c    = tag_rd[evw_c][2];

  // ---- Port B arbitration ----
  logic pb_probe, pb_grant, pb_st, pb_amw;
  assign pb_probe   = ps_q == P_RD && !bw_busy;
  // Port B's read register must hold while a beat waits on C, so nothing else enables port B
  // during P_SEND or a Release's send (the miss side's pb_ev and grant_beat keep to it)
  assign pb_grant   = grant_beat;
  // A store writes when the state port is free too: no install or allocation this cycle. A store
  // that hits allocates nothing, so only a load's allocation can take the state port then, and the
  // hit selects last
  logic pst_ok;
  // (a load's allocation, as alloc_ld decides it when the store port's request hits: st_rsvq)
  assign pst_ok     = !probe_active && !m_on_c && !pb_grant && !m_inst &&
                      !(al_base && m_free_ld && c_req && !(|ch) && !st_rsvq);
  assign pb_st      = st_req && s_hit_t && pst_ok;
  assign pb_amw     = amw_q && |am_wmask;
  // Port B's read data, selected once by the way it last read: a probe, an eviction or an
  // atomic. Port B makes one access per cycle and holds its output while a C beat waits, so
  // one multiplexer serves all three readers.
  logic             brd_en;
  logic [WAY_W-1:0] brd_way, brd_way_q;
  logic [127:0]     brow;
  assign brow       = b_rdata[brd_way_q];
  // The atomic's read and its data: the write the next cycle, or with DC_AMO_READ_REG (DR-140 #5;
  // timing: the D$ atomic path, block RAM to block RAM) a cycle that registers the data first
  if (DC_AMO_READ_REG) begin : g_amo_reg
    logic        amh_q;
    logic [63:0] am_rd_q;
    assign pb_amr   = am_req && s_hit_t && ps_q == P_IDLE && (!b_valid_i || fu_hold) && m_none && !bw_busy &&
                      !amh_q &&
                      !amw_q;
    assign am_busy  = amh_q || amw_q;
    assign amw_d    = amh_q;
    assign am_rdata = am_rd_q;
    always_ff @(posedge clk) begin
      if (rst) amh_q <= 1'b0;
      else     amh_q <= pb_amr;
      if (amh_q) am_rd_q <= am_hi_q ? brow[127:64] : brow[63:0];
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (!rst && amh_q) assert (ps_q == P_IDLE && m_none && brd_way_q == am_way_q)
        else $error("tg_dcache: atomic data held not exclusive, or from another way");
    end
`endif
  end else begin : g_amo_now
    assign pb_amr   = am_req && s_hit_t && ps_q == P_IDLE && (!b_valid_i || fu_hold) && m_none && !bw_busy &&
                      !amw_q;
    assign am_busy  = amw_q;
    assign amw_d    = pb_amr;
    assign am_rdata = am_hi_q ? brow[127:64] : brow[63:0];
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (!rst && amw_q) assert (brd_way_q == am_way_q) else $error("tg_dcache: atomic data from another way");
    end
`endif
  end
  logic st_drop;
  assign st_ack     = pb_st || st_drop;
  assign st_dropped = st_drop;

  // One way at most is enabled, and the byte write enables are zero for reads, so they are
  // shared by the ways: a disabled way neither reads nor writes. The accesses from registers and
  // the D channel select first, the store port's (a store's write, an atomic's read: its lookup is
  // late) last, and the address, byte enables and data default to the store port's, so only the
  // ways' enables wait for its hit (timing, DR-145: in G6 port B's address, byte enables and data,
  // -1.39, -1.34 and -1.17 ns; checked in simulation against the earlier form)
  logic             e_any;               // an access from registers or the D channel
  logic [WAYS-1:0]  e_en;
  logic [15:0]      e_we;
  logic [ROW_W-1:0] e_addr;
  logic             pb_x;                // the store port's: its way is sh
  assign e_any = pb_probe || pb_grant || pb_ev || pb_amw;
  assign pb_x  = pb_st || pb_amr;
  always_comb begin
    e_en = '0; e_we = '0; e_addr = sx_pa[4 +: ROW_W];
    if (pb_probe) begin
      e_en[p_way_q] = 1'b1;
      e_addr = {p_pa_q[6 +: SET_W], p_beat_q};
    end else if (pb_grant) begin
      e_en[mg_way] = 1'b1;
      e_we = '1;
      e_addr = {mg_set, mg_beat};
    end else if (pb_ev) begin
      e_en[mv_way] = 1'b1;
      e_addr = {mv_set, mv_beat};
    end else if (pb_amw) begin
      e_en[am_way_q] = 1'b1;
      e_we = am_wmask;
      e_addr = am_row_q;
    end
  end
  assign b_en    = e_en | (pb_x ? sh : '0);
  assign b_we    = e_any ? e_we : st_req ? st_mask : '0;
  assign b_addr  = e_addr;
  assign b_wdata = pb_grant ? d_i.data : amw_q ? {2{am_wdata}} : {2{st_wdata}};
  assign brd_en  = pb_probe || pb_ev || pb_amr;
  assign brd_way = pb_probe ? p_way_q : pb_ev ? mv_way : sh_way;
  // #11 (DC_PORTB_WREG): the writes (a grant beat, a store, an atomic) reach the RAMs from a
  // register a cycle later, and the reads (probe, eviction, atomic) wait while one does (bw_busy;
  // no write is decided while port B's output holds a read: P_RD/P_SEND, M_EV_RD/M_EV_SEND and an
  // atomic's read exclude them). Timing, DR-148: the RAMs' write inputs start at flip-flops
  if (DC_PORTB_WREG) begin : g_bwreg
    logic             wr_v_q;
    logic [WAYS-1:0]  wr_en_q;
    logic [15:0]      wr_we_q;
    logic [ROW_W-1:0] wr_addr_q;
    logic [127:0]     wr_data_q;
    logic             b_wr;
    assign b_wr = pb_grant || pb_st || pb_amw;
    always_ff @(posedge clk) begin
      wr_v_q    <= !rst && b_wr;
      wr_en_q   <= (!rst && b_wr) ? b_en : '0;
      wr_we_q   <= (!rst && b_wr) ? b_we : '0;
      wr_addr_q <= b_addr;
      wr_data_q <= b_wdata;
    end
    // The reads' enables and address come from the three readers alone: a probe's, a Release's and
    // an atomic's read, none ever beside a write. b_en and b_addr also carry the write decisions
    // (the store port's hit through pst_ok, an SC's mask through pb_amw), and only registers feed the
    // writes here (timing, DR-148 fn12: in G7 those decisions reached the RAMs' ENB, their WEBWE, into
    // which XPM folds enb, and ADDRB: -0.48, -0.82 and -0.78 ns, 13 levels at 80% wire). The same
    // values whenever a read enables port B (asserted below)
    logic [WAYS-1:0]  rd_en_v;
    logic [ROW_W-1:0] rd_addr;
    always_comb begin
      rd_en_v = '0;
      rd_addr = sx_pa[4 +: ROW_W];               // an atomic's read: the store port holds its address
      if (pb_probe) begin
        rd_en_v[p_way_q] = 1'b1;
        rd_addr = {p_pa_q[6 +: SET_W], p_beat_q};
      end else if (pb_ev) begin
        rd_en_v[mv_way] = 1'b1;
        rd_addr = {mv_set, mv_beat};
      end else if (pb_amr) begin
        rd_en_v = sh;
      end
    end
    assign bw_busy  = wr_v_q;
    assign rb_en    = wr_en_q | rd_en_v;
    assign rb_we    = wr_we_q;
    assign rb_addr  = wr_v_q ? wr_addr_q : rd_addr;
    assign rb_wdata = wr_data_q;
`ifndef SYNTHESIS
    always_ff @(posedge clk)
      if (!rst) begin
        assert (!(wr_v_q && (ps_q == P_SEND || m_holdb || brd_en)))
          else $error("tg_dcache: a registered write lands while port B's output holds a read");
        assert (rd_en_v == (brd_en ? b_en : '0) && (!brd_en || rd_addr == b_addr))
          else $error("tg_dcache: port B's read enable or address differs from b_en/b_addr");
      end
`endif
  end else begin : g_bwnow
    assign bw_busy  = 1'b0;
    assign rb_en    = b_en;
    assign rb_we    = b_we;
    assign rb_addr  = b_addr;
    assign rb_wdata = b_wdata;
  end

  // ---- Channels ----
  always_comb begin
    a_o = '0;
    a_o.opcode  = A_ACQUIRE_BLOCK;
    a_o.param   = a_grow;
    a_o.size    = 3'd6;
    a_o.source  = a_src;
    a_o.address = {a_line, 6'b0};
    a_o.mask    = '1;
    a_valid_o   = a_valid;

    e_o.sink    = e_sink;
    e_valid_o   = e_valid;

    // A probe is taken when the probe unit is idle, neither an eviction nor an atomic has the line
    // state, and no forward-progress hold is on (above). An MSHR allocation never competes: it
    // yields to a probe on offer (alloc_*), and an atomic's read to one that is taken, so the ready
    // comes from state registers alone (timing: the store drain's and the load miss's tag lookups
    // left the crossbar's B slice; the handshakes are the same, as ready only counts with b_valid_i)
    b_ready_o   = ps_q == P_IDLE && !m_on_c && !am_busy && !fu_hold && ready;

    c_o = '0;
    c_valid_o = 1'b0;
    if (ps_q == P_SEND || ps_q == P_ACK) begin
      c_valid_o   = 1'b1;
      c_o.opcode  = (ps_q == P_SEND) ? C_PROBE_ACK_DATA : C_PROBE_ACK;
      c_o.param   = p_param_q;
      c_o.size    = 3'd6;
      c_o.source  = p_src_q;
      c_o.address = {p_pa_q[PA_W-1:6], 6'b0};
      c_o.data    = (ps_q == P_SEND) ? brow : '0;   // held stable: see port B rules
    end else if (rel_send) begin
      c_valid_o   = 1'b1;
      c_o.opcode  = rel_dirty ? C_RELEASE_DATA : C_RELEASE;
      c_o.param   = rel_t ? TL_SHRINK_T_TO_N : TL_SHRINK_B_TO_N;
      c_o.size    = 3'd6;
      c_o.source  = rel_src;
      c_o.address = {rel_line, 6'b0};
      c_o.data    = rel_dirty ? rel_data : '0;
    end

    d_ready_o = 1'b1;
    if (m_gwait && (ps_q == P_RD || ps_q == P_SEND)) d_ready_o = 1'b0;
  end

  // Grant with data or permission only
  logic d_fire;
  assign d_fire = d_valid_i && d_ready_o;

  // Store whose fill was denied: acknowledged without a write. An atomic: am_den (access fault).
  // (a load's allocation never comes with a store port miss)
  assign sx_drop = sx_req && m_none && dn_hit && !s_hit_t && !probe_active;
  assign st_drop = sx_drop && st_req;
  assign am_den  = sx_drop && am_req;
  logic            lose_v_q;
  logic [PA_W-1:6] lose_line_q;
  assign lose_v    = lose_v_q;
  assign lose_line = lose_line_q;

  // ---- State writes: one read-modify-write per cycle ----
  // By priority: the reset sweep, a probe update, an install (registers); an allocation with a
  // victim or a store hit setting dirty (the store port's lookup is late: they select last, each
  // from its own port's state); else an atomic's write. The late writes exclude the others but
  // the sweep (timing, DR-145: in G6 the store port's compare -> the write's source -> the state
  // RAMs' data, -1.49 ns; checked in simulation against the earlier form)
  logic             we_e;
  logic [SET_W-1:0] wa_e;
  sst_t             wd_e, wd_as, wd_ac, wd_s;
  logic             w_as, w_ac, w_s;     // a store's or atomic's allocation, a load's, a store hit
  always_comb begin
    we_e = 1'b0;
    wa_e = am_row_q[ROW_W-1:2];
    wd_e = sw;
    if (!ready) begin
      we_e = 1'b1;
      wa_e = init_q[SET_W-1:0];
      wd_e = '0;
    end else if (ps_q == P_UPD && p_hit_q) begin
      we_e = 1'b1;
      wa_e = p_pa_q[6 +: SET_W];
      wd_e.v[p_way_q] = p_nv_q;
      wd_e.t[p_way_q] = p_nt_q;
      if (!p_nt_q) wd_e.d[p_way_q] = 1'b0;     // to B or N: dirty data went with the ack
    end else if (m_inst) begin                 // inst_go
      we_e = 1'b1;
      wa_e = mi_line[6 +: SET_W];
      wd_e.v[mi_way] = !mi_den;
      wd_e.t[mi_way] = !mi_den && mi_cap == TL_CAP_TO_T;
      wd_e.d[mi_way] = 1'b0;
    end else if (pb_amw) begin
      we_e = 1'b1;
      wd_e.d[am_way_q] = 1'b1;
    end
    wd_as = ss;
    wd_as.rr = ss.rr + 1'b1;
    wd_as.v[victim_s] = 1'b0;                   // the victim is released (or was invalid)
    wd_as.t[victim_s] = 1'b0;
    wd_as.d[victim_s] = 1'b0;
    wd_ac = sc;
    wd_ac.rr = sc.rr + 1'b1;
    wd_ac.v[victim_c] = 1'b0;
    wd_ac.t[victim_c] = 1'b0;
    wd_ac.d[victim_c] = 1'b0;
    wd_s = ss;
    wd_s.d = ss.d | sh;                         // the hit way's dirty bit (sh is one-hot)
  end
  assign w_as  = alloc_st && !dn_hit && !s_hit;
  assign w_ac  = alloc_ld || (alloc_pf && !al_upc);
  assign w_s   = pb_st && ready;
  assign st_we = we_e || w_as || w_ac || w_s;
  assign st_wa = (w_as || w_s) ? sx_pa[6 +: SET_W] : w_ac ? c_pa[6 +: SET_W] : wa_e;
  assign st_wd = w_as ? wd_as : w_ac ? wd_ac : w_s ? wd_s : wd_e;

  // ---- Sequential ----
  always_ff @(posedge clk) begin
    if (rst) begin
      init_q <= '0;
      ps_q   <= P_IDLE;
      amw_q  <= 1'b0;
      lose_v_q <= 1'b0;
      fu_st_q  <= '0;
      fu_ld_q  <= '0;
    end else begin
      // The holds after an install (forward progress, above). With entries (DC_MSHRS > 1) each
      // install starts its own kind's hold and the other one runs on
      if (DC_MSHRS == 1) begin
        if (inst_go && !mi_den) begin
          fu_st_q <= mi_st ? 4'(FU_ST) : '0;
          fu_ld_q <= mi_st ? '0 : 4'(FU_LD);
        end else begin
          if (fu_st) fu_st_q <= (pb_st || pb_amr) ? '0 : fu_st_q - 1'b1;
          if (fu_ld_q != '0) fu_ld_q <= fu_ld_q - 1'b1;
        end
      end else begin
        if (inst_go && !mi_den && mi_st) fu_st_q <= 4'(FU_ST);
        else if (fu_st)                  fu_st_q <= (pb_st || pb_amr) ? '0 : fu_st_q - 1'b1;
        if (inst_go && !mi_den && !mi_st) fu_ld_q <= 4'(FU_LD);
        else if (fu_ld_q != '0)           fu_ld_q <= fu_ld_q - 1'b1;
      end
      if (!ready) init_q <= init_q + 1'b1;
      if (brd_en) brd_way_q <= brd_way;
      // Atomic: read now, write next cycle (or the cycle after: DC_AMO_READ_REG)
      amw_q <= amw_d;
      if (!am_busy) begin                       // (held from the read, pb_amr, to the write)
        am_way_q <= sh_way;
        am_row_q <= am_pa[4 +: ROW_W];
        am_hi_q  <= am_pa[3];
      end
      lose_v_q <= 1'b0;

      // An eviction ends a reservation on the victim's line
      if (al_go && !al_up && !al_upc && (alloc_st ? ev_s : ev_c)) begin
        lose_v_q    <= 1'b1;
        lose_line_q <= {alloc_st ? evt_s : evt_c, al_pa[6 +: SET_W]};
      end

      // ---- Probes ----
      unique case (ps_q)
        P_IDLE: if (b_valid_i && b_ready_o) begin
          ps_q     <= P_LOOK;
          p_pa_q   <= b_i.address;
          p_cap_q  <= b_i.param;
          p_perm_q <= b_i.opcode == B_PROBE_PERM;
          p_src_q  <= b_i.source;
        end
        P_LOOK: begin
          logic t, d, hit;
          hit = |ch;
          t = sc.t[ch_way];
          d = sc.d[ch_way];
          p_way_q  <= ch_way;
          p_hit_q  <= hit;
          p_beat_q <= '0;
          p_nv_q   <= hit;
          p_nt_q   <= hit && t;
          if (!hit) begin
            p_param_q <= TL_REPORT_N_TO_N;
          end else if (t) begin
            if (p_cap_q == TL_CAP_TO_T) begin
              p_param_q <= TL_REPORT_T_TO_T;
            end else begin
              p_param_q <= (p_cap_q == TL_CAP_TO_N) ? TL_SHRINK_T_TO_N : TL_SHRINK_T_TO_B;
              p_nv_q    <= p_cap_q != TL_CAP_TO_N;
              p_nt_q    <= 1'b0;
            end
          end else begin
            p_param_q <= (p_cap_q == TL_CAP_TO_N) ? TL_SHRINK_B_TO_N : TL_REPORT_B_TO_B;
            p_nv_q    <= p_cap_q != TL_CAP_TO_N;
          end
          ps_q <= (hit && t && p_cap_q != TL_CAP_TO_T && d && !p_perm_q) ? P_RD : P_ACK;
        end
        P_RD: if (pb_probe) ps_q <= P_SEND;         // (#11: not beside a write)
        P_SEND: if (c_ready_i) begin
          if (p_beat_q == 2'd3) ps_q <= P_UPD;
          else begin
            p_beat_q <= p_beat_q + 1'b1;
            ps_q <= P_RD;
          end
        end
        P_ACK: if (c_ready_i) ps_q <= P_UPD;
        P_UPD: begin                               // the state write is in the comb block above
          ps_q <= P_IDLE;
          if (p_hit_q && !p_nt_q) begin
            lose_v_q    <= 1'b1;
            lose_line_q <= p_pa_q[PA_W-1:6];
          end
        end
        default: ps_q <= P_IDLE;
      endcase
    end
  end


  // ---- The miss side ----
  if (DC_MSHRS == 1) begin : g_m1
    // One MSHR: one line at a time, for a load miss (AcquireBlock NtoB) or a store (NtoT, or BtoT
    // for a line held in B). A valid victim is released first (state cleared when the Release
    // starts, so probes and stores see the line as gone); the Acquire waits for ReleaseAck
    typedef enum logic [3:0] {
      M_IDLE, M_EV_RD, M_EV_SEND, M_EV_WAIT, M_ACQ, M_GRANT, M_GACK, M_INSTALL
    } mstate_e;
    mstate_e          ms_q;
    logic [PA_W-1:6]  m_line_q;
    logic [2:0]       m_grow_q;
    logic             m_st_q;              // for a store
    logic [WAY_W-1:0] m_way_q;
    logic [PA_W-1:6]  m_vline_q;           // victim line
    logic             m_vdirty_q, m_vt_q;
    logic [1:0]       m_beat_q;
    logic             m_den_q;
    logic [2:0]       m_cap_q;
    logic [TL_SINK_W-1:0] m_sink_q;
    logic             dn_v_q;              // the last denied fill
    logic [PA_W-1:6]  dn_line_q;
    assign m_none     = ms_q == M_IDLE;
    assign m_on_c     = ms_q == M_EV_RD || ms_q == M_EV_SEND;
    assign m_inst     = ms_q == M_INSTALL;
    assign inst_go    = m_inst && !(ps_q == P_UPD && p_hit_q);    // a probe update goes first
    assign mi_line    = m_line_q;
    assign mi_way     = m_way_q;
    assign mi_den     = m_den_q;
    assign mi_st      = m_st_q;
    assign mi_cap     = m_cap_q;
    assign pb_ev      = ms_q == M_EV_RD && !bw_busy;     // (#11: not beside a write)
    assign mv_way     = m_way_q;
    assign mv_set     = m_vline_q[6 +: SET_W];
    assign mv_beat    = m_beat_q;
    assign m_gwait    = ms_q == M_GRANT;
    assign grant_beat = ms_q == M_GRANT && d_valid_i && !(ps_q == P_RD || ps_q == P_SEND) &&
                        d_i.opcode == D_GRANT_DATA;
    assign mg_way     = m_way_q;
    assign mg_set     = m_line_q[6 +: SET_W];
    assign mg_beat    = m_beat_q;
    assign a_valid    = ms_q == M_ACQ;
    assign a_line     = m_line_q;
    assign a_grow     = m_grow_q;
    assign a_src      = TL_SRC_W'(0);
    assign e_valid    = ms_q == M_GACK;
    assign e_sink     = m_sink_q;
    assign rel_send   = ms_q == M_EV_SEND;
    assign rel_dirty  = m_vdirty_q;
    assign rel_t      = m_vt_q;
    assign rel_line   = m_vline_q;
    assign rel_src    = TL_SRC_W'(1);
    assign rel_data   = brow;                // held by port B's output while it waits on C
    assign m_holdb    = rel_send;
    assign m_free_st  = m_none;
    assign m_free_ld  = m_none;
    assign m_free_pf  = 1'b0;                // (no prefetch with one MSHR: it is never to spare)
    assign sx_new     = 1'b1;                // (one MSHR: a waiting store's line is in no entry when it frees)
    assign m_spare    = 1'b0;
    assign m_dbg      = 4'(ms_q);
    assign c_req      = lm_req;
    assign c_pa       = lm_pa;
    assign dn_hit     = dn_v_q && dn_line_q == sx_pa[PA_W-1:6];
    assign lm_fdn     = dn_v_q && dn_line_q == lm_pa[PA_W-1:6];
    assign res_s      = '0;                  // (the victim search does not read them: one MSHR)
    assign res_c      = '0;
    assign lm_ans_v    = 1'b0;               // (DC_MSHRS > 1 only)
    assign lm_ans_wait = 1'b0;
    assign lm_ans_e    = '0;
    assign m_done      = '0;
    assign m_wake_any  = 1'b0;
    logic unused_m1;
    assign unused_m1 = ^{res_s, res_c, pf_req, pf_pa};
    always_ff @(posedge clk) begin
      if (rst) begin
        ms_q   <= M_IDLE;
        dn_v_q <= 1'b0;
      end else begin
        unique case (ms_q)
          M_IDLE: begin
            // The request's fields load in every idle cycle (they are read only once the MSHR has
            // left M_IDLE), so only the state and lose_v wait for the allocation (timing, DR-145).
            // An upgrade keeps its B line's way; else the victim's, released first when valid: it
            // is gone for probes and stores from then on
            m_line_q   <= al_pa[PA_W-1:6];
            m_st_q     <= alloc_st;
            m_beat_q   <= '0;
            m_den_q    <= 1'b0;
            m_way_q    <= al_up ? sh_way : victim;
            m_grow_q   <= al_up ? TL_GROW_B_TO_T : alloc_st ? TL_GROW_N_TO_T : TL_GROW_N_TO_B;
            m_vline_q  <= {alloc_st ? evt_s : evt_c, al_pa[6 +: SET_W]};
            m_vdirty_q <= alloc_st ? ss.d[ss.rr] : sc.d[sc.rr];
            m_vt_q     <= alloc_st ? ss.t[ss.rr] : sc.t[sc.rr];
            if (al_go) begin
              if (!al_up && (alloc_st ? ev_s : ev_c)) begin
                ms_q        <= (alloc_st ? ss.d[ss.rr] : sc.d[sc.rr]) ? M_EV_RD : M_EV_SEND;
              end else begin
                ms_q <= M_ACQ;
              end
            end
          end
          M_EV_RD: if (pb_ev) ms_q <= M_EV_SEND;      // port B read of beat m_beat_q (#11: not beside a write)
          M_EV_SEND: if (c_ready_i) begin
            if (!m_vdirty_q || m_beat_q == 2'd3) begin
              m_beat_q <= '0;
              ms_q <= M_EV_WAIT;
            end else begin
              m_beat_q <= m_beat_q + 1'b1;
              ms_q <= M_EV_RD;
            end
          end
          M_EV_WAIT: if (d_fire && d_i.opcode == D_RELEASE_ACK) ms_q <= M_ACQ;
          M_ACQ: if (a_ready_i) begin
            ms_q <= M_GRANT;
            m_beat_q <= '0;
          end
          M_GRANT: if (d_fire && (d_i.opcode == D_GRANT_DATA || d_i.opcode == D_GRANT)) begin
            m_cap_q  <= {1'b0, d_i.param};
            m_sink_q <= d_i.sink;
            if (d_i.denied || d_i.corrupt) m_den_q <= 1'b1;
            if (d_i.opcode == D_GRANT || m_beat_q == 2'd3) ms_q <= M_GACK;
            m_beat_q <= m_beat_q + 1'b1;
          end
          M_GACK: if (e_ready_i) ms_q <= M_INSTALL;
          M_INSTALL: if (inst_go) begin              // the state write is in the comb block above
            ms_q <= M_IDLE;
            if (!m_den_q) begin
              if (dn_v_q && dn_line_q == m_line_q) dn_v_q <= 1'b0;
            end else begin
              dn_v_q    <= 1'b1;
              dn_line_q <= m_line_q;
            end
          end
          default: ms_q <= M_IDLE;
        endcase
      end
    end
  end else begin : g_mn
    // DC_MSHRS entries (DR-149). Each holds one line in flight from its allocation to its install:
    // a load's (AcquireBlock NtoB), or a store's or an atomic's (NtoT, or BtoT for a line held in
    // B, which stays valid in B meanwhile). A valid victim goes through the one release engine:
    // its state is cleared at the allocation (probes and stores see the line as gone; its way is
    // the entry's), the engine reads and sends its beats, and the entry's Acquire goes out after
    // the last one. Each beat is read through port B, taken into the engine's own register the next
    // cycle and sent from it, so Grants for other entries write port B meanwhile (no D waits on C).
    // The engine alone waits for ReleaseAck (source DC_MSHRS); another allocation with a valid victim
    // waits for it. A way an entry holds is no other allocation's victim. Loads'
    // misses come through a request register: the next cycle each merges with the entry holding
    // its line, finds the line present, allocates, or gets no answer, and the answer is registered
    // (lm_ans_*, two cycles after lm_req). Grants come back in any order, demultiplexed by source
    // (the entry's index); a Grant's beats are contiguous, so port B writes one Grant at a time.
    // Installs take the state port one at a time, the lowest entry first, after a probe update, and
    // no allocation shares a cycle with one. An atomic's read waits until nothing is in flight
    localparam int N = DC_MSHRS;
    typedef enum logic [2:0] { E_IDLE, E_EV, E_ACQ, E_GRANT, E_GACK, E_INSTALL } estate_e;
    typedef enum logic [2:0] { R_IDLE, R_RD, R_CAP, R_SEND, R_WAIT } rstate_e;
    estate_e [N-1:0]                es_q;      // per entry: its state, line, way, growth, kind
    logic    [N-1:0][PA_W-1:6]      el_q;
    logic    [N-1:0][WAY_W-1:0]     ew_q;
    logic    [N-1:0][2:0]           eg_q;
    logic    [N-1:0]                est_q;     // for a store or an atomic
    logic    [N-1:0]                epf_q;     // for a store's ownership prefetch (STORE_PF)
    logic    [N-1:0][1:0]           eb_q;      // the Grant's beat
    logic    [N-1:0]                eden_q;    // the Grant was denied (or corrupt)
    logic    [N-1:0][2:0]           ecap_q;
    logic    [N-1:0][TL_SINK_W-1:0] esk_q;
    rstate_e                        rs_q;      // the release engine: the victim's line, way,
    logic    [PA_W-1:6]             rl_q;      //   dirty and T bits, its beat, and the entry whose
    logic    [WAY_W-1:0]            rw_q;      //   Acquire waits for the send
    logic                           rd_q, rt_q;
    logic    [1:0]                  rb_q;
    logic    [MSW-1:0]              re_q;
    logic    [127:0]                rbeat_q;   //   and the beat it sends
    logic                           rq_v_q;    // the loads' request register
    logic    [PA_W-1:0]             rq_pa_q;
    logic    [N-1:0]                dn_v_q;    // denied fills, one line per entry
    logic    [N-1:0][PA_W-1:6]      dn_l_q;
    logic    [N-1:0]                done_q;    // entry e installed last cycle
    logic                           none_q;    // nothing was in flight last cycle
    logic                           rack_q;    // ReleaseAck came last cycle
    logic                           ans_v_q, ans_w_q;
    logic    [MSW-1:0]              ans_e_q;
    function automatic logic [MSW-1:0] first(input logic [N-1:0] v);   // the lowest one set
      logic [MSW-1:0] r;
      r = '0;
      for (int i = N - 1; i >= 0; i--) if (v[i]) r = MSW'(i);
      return r;
    endfunction
    logic [N-1:0] busy, acq, gnt, gack, insv, st_m, rq_m, dn_s, dn_l;
    logic [MSW-1:0] f_i, a_i, g_i, i_i, rq_e, d_e;
    logic f_any, st_busy, rq_busy, d_for_e, ev_go, ev_dirty;
    always_comb begin
      for (int e = 0; e < N; e++) begin
        busy[e] = es_q[e] != E_IDLE;
        acq[e]  = es_q[e] == E_ACQ;
        gnt[e]  = es_q[e] == E_GRANT;
        gack[e] = es_q[e] == E_GACK;
        insv[e] = es_q[e] == E_INSTALL;
        st_m[e] = busy[e] && el_q[e] == sx_pa[PA_W-1:6];
        rq_m[e] = busy[e] && el_q[e] == c_pa[PA_W-1:6];
        dn_s[e] = dn_v_q[e] && dn_l_q[e] == sx_pa[PA_W-1:6];
        dn_l[e] = dn_v_q[e] && dn_l_q[e] == lm_pa[PA_W-1:6];
      end
      // The ways the entries hold in the store port's and the controller's sets
      res_s = '0;
      res_c = '0;
      for (int e = 0; e < N; e++) begin
        if (busy[e] && el_q[e][6 +: SET_W] == sx_pa[6 +: SET_W]) res_s[ew_q[e]] = 1'b1;
        if (busy[e] && el_q[e][6 +: SET_W] == c_pa[6 +: SET_W]) res_c[ew_q[e]] = 1'b1;
      end
    end
    assign f_i     = first(~busy);
    assign f_any   = |(~busy);
    // A and E keep the entry they present until it is taken (TileLink: a valid message's payload
    // holds until ready; a lower entry turning ready meanwhile waits)
    logic           a_hold_q, e_hold_q;
    logic [MSW-1:0] a_cur_q, e_cur_q;
    assign a_i     = a_hold_q ? a_cur_q : first(acq);
    assign g_i     = e_hold_q ? e_cur_q : first(gack);
    assign i_i     = first(insv);
    assign rq_e    = first(rq_m);
    // TL-C: no Acquire for a block while its Release is outstanding, so a line the release engine
    // holds (until ReleaseAck) is allocated to no entry: the store waits, the load gets no answer
    // (ReleaseAck wakes it)
    logic st_rel, rq_rel;
    assign st_rel  = rs_q != R_IDLE && rl_q == sx_pa[PA_W-1:6];
    assign rq_rel  = rs_q != R_IDLE && rl_q == c_pa[PA_W-1:6];
    assign st_busy = |st_m;
    assign rq_busy = |rq_m;
    assign d_e     = d_i.source[MSW-1:0];
    assign d_for_e = (d_i.opcode == D_GRANT_DATA || d_i.opcode == D_GRANT) && d_i.source[2:0] < 3'(N) &&
                     es_q[d_e] == E_GRANT;
    assign ev_go    = !al_up && !al_upc && (alloc_st ? ev_s : ev_c);
    assign ev_dirty = alloc_st ? ss.d[evw_s] : sc.d[evw_c];

    assign m_none     = !(|busy) && rs_q == R_IDLE;
    assign m_on_c     = rs_q == R_RD || rs_q == R_CAP || rs_q == R_SEND;
    assign m_inst     = |insv;
    assign inst_go    = m_inst && !(ps_q == P_UPD && p_hit_q);    // a probe update goes first
    assign mi_line    = el_q[i_i];
    assign mi_way     = ew_q[i_i];
    assign mi_den     = eden_q[i_i];
    assign mi_st      = est_q[i_i];
    assign mi_cap     = ecap_q[i_i];
    assign pb_ev      = rs_q == R_RD && !bw_busy && !grant_beat;   // (not beside a write)
    assign mv_way     = rw_q;
    assign mv_set     = rl_q[6 +: SET_W];
    assign mv_beat    = rb_q;
    assign m_gwait    = |gnt;
    assign grant_beat = d_valid_i && d_i.opcode == D_GRANT_DATA && d_for_e && !(ps_q == P_RD || ps_q == P_SEND);
    assign mg_way     = ew_q[d_e];
    assign mg_set     = el_q[d_e][6 +: SET_W];
    assign mg_beat    = eb_q[d_e];
    assign a_valid    = |acq;
    assign a_line     = el_q[a_i];
    assign a_grow     = eg_q[a_i];
    assign a_src      = TL_SRC_W'(a_i);
    assign e_valid    = |gack;
    assign e_sink     = esk_q[g_i];
    assign rel_send   = rs_q == R_SEND;
    assign rel_dirty  = rd_q;
    assign rel_t      = rt_q;
    assign rel_line   = rl_q;
    assign rel_src    = TL_SRC_W'(N);
    assign rel_data   = rbeat_q;
    assign m_holdb    = 1'b0;                // (the engine sends from its own register)
    // An allocation needs a free entry, no entry or Release for its line, no install this cycle (the
    // state port), and the release engine when its victim is valid
    assign m_free_st  = f_any && !m_inst && !st_busy && !st_rel && (rs_q == R_IDLE || s_hit || !ev_s);
    assign m_free_ld  = f_any && !m_inst && !rq_busy && !rq_rel && (rs_q == R_IDLE || !ev_c);
    assign c_req      = rq_v_q;
    // The store ownership prefetch (STORE_PF, DR-171): one pending line, the newest a store's address
    // decision sent (pf_req), looked up through the controller port in a cycle without a load's
    // request. It ends when it allocates, or when its line is held with T or in an entry; it waits
    // otherwise. It takes an entry only with another to spare, so a load always finds one, and only
    // while fewer than PF_MAX (STORE_PF_MAX) prefetches are in flight (SMT2's second hart adds misses),
    // and never while the store port writes or allocates: a store with its line in an entry does neither
    localparam int PF_MAX = STORE_PF_MAX;
    logic            pq_v_q, c_pf, f_two, pf_room;
    logic [PA_W-1:6] pq_l_q;
    assign c_pf       = STORE_PF && pq_v_q && !rq_v_q;
    assign c_pa       = (STORE_PF && !rq_v_q) ? {pq_l_q, 6'b0} : rq_pa_q;
    assign f_two      = $countones(~busy) >= 2;
    assign sx_new     = !st_busy;
    assign m_spare    = f_two;
    assign pf_room    = $countones(busy & epf_q) < PF_MAX;
    assign m_free_pf  = c_pf && f_two && pf_room && !m_inst && !rq_busy && !rq_rel &&
                        (rs_q == R_IDLE || |ch || !ev_c) && (!st_req || st_busy);
    assign m_dbg      = {rs_q != R_IDLE, 3'($countones(busy))};
    assign dn_hit     = |dn_s;
    assign lm_fdn     = |dn_l;
    // The request register's answer: its line is present (the controller port hits, outside a
    // probe), in an entry (wait for it; one installing now: retry), or allocated now; else none
    logic a_retry, a_wait;
    logic [MSW-1:0] a_e;
    always_comb begin
      a_retry = 1'b0;
      a_wait  = 1'b0;
      a_e     = f_i;
      if (!probe_active && |ch) begin
        a_retry = 1'b1;
      end else if (rq_busy) begin
        a_e = rq_e;
        if (insv[rq_e]) a_retry = 1'b1;
        else            a_wait  = 1'b1;
      end else if (alloc_ld) begin
        a_wait = 1'b1;
      end
    end
    assign lm_ans_v    = ans_v_q;
    assign lm_ans_wait = ans_w_q;
    assign lm_ans_e    = ans_e_q;
    assign m_done      = done_q;
    assign m_wake_any  = |done_q || rack_q || none_q;
    always_ff @(posedge clk) begin
      if (rst) begin
        for (int e = 0; e < N; e++) es_q[e] <= E_IDLE;
        rs_q    <= R_IDLE;
        rq_v_q  <= 1'b0;
        pq_v_q  <= 1'b0;
        dn_v_q  <= '0;
        done_q  <= '0;
        none_q  <= 1'b1;
        rack_q  <= 1'b0;
        ans_v_q <= 1'b0;
        a_hold_q <= 1'b0;
        e_hold_q <= 1'b0;
      end else begin
        a_hold_q <= a_valid && !a_ready_i;
        a_cur_q  <= a_i;
        e_hold_q <= e_valid && !e_ready_i;
        e_cur_q  <= g_i;
        rq_v_q  <= lm_req;                       // M2's miss: decided the next cycle
        rq_pa_q <= lm_pa;
        // The pending prefetch: the newest request replaces it; it ends once it allocated, or its line
        // is held with T or is in an entry (looked up outside a probe)
        if (pf_req && STORE_PF) begin
          pq_v_q <= 1'b1;
          pq_l_q <= pf_pa[PA_W-1:6];
        end else if (c_pf && !probe_active && (alloc_pf || |(ch & sc.t) || rq_busy)) begin
          pq_v_q <= 1'b0;
        end
        ans_v_q <= rq_v_q && (a_retry || a_wait);
        ans_w_q <= a_wait;
        ans_e_q <= a_e;
        done_q  <= '0;
        rack_q  <= 1'b0;
        none_q  <= m_none;
        // The first free entry's fields load in every cycle it is free (read only once it is
        // busy), so only its state waits for the allocation
        if (f_any) begin
          el_q[f_i]   <= al_pa[PA_W-1:6];
          est_q[f_i]  <= alloc_st;
          epf_q[f_i]  <= !alloc_st && c_pf;      // (a load's allocation comes with no prefetch lookup)
          eb_q[f_i]   <= '0;
          eden_q[f_i] <= 1'b0;
          ew_q[f_i]   <= al_up ? sh_way : (!alloc_st && c_pf && |ch) ? ch_way : victim;
          eg_q[f_i]   <= al_up ? TL_GROW_B_TO_T : alloc_st ? TL_GROW_N_TO_T :
                         c_pf ? (|ch ? TL_GROW_B_TO_T : TL_GROW_N_TO_T) : TL_GROW_N_TO_B;
          if (al_go) es_q[f_i] <= ev_go ? E_EV : E_ACQ;
        end
        // The release engine takes a valid victim at its allocation
        if (al_go && ev_go) begin
          rs_q <= ev_dirty ? R_RD : R_SEND;     // (a clean victim's Release has no data)
          rl_q <= {alloc_st ? evt_s : evt_c, al_pa[6 +: SET_W]};
          rw_q <= victim;
          rd_q <= ev_dirty;
          rt_q <= alloc_st ? ss.t[evw_s] : sc.t[evw_c];
          rb_q <= '0;
          re_q <= f_i;
        end
        unique case (rs_q)
          R_RD: if (pb_ev) rs_q <= R_CAP;       // port B read of beat rb_q
          R_CAP: begin                           // its data, taken before any later port-B access
            rbeat_q <= brow;
            rs_q    <= R_SEND;
          end
          R_SEND: if (c_ready_i) begin
            if (!rd_q || rb_q == 2'd3) begin
              rs_q       <= R_WAIT;
              es_q[re_q] <= E_ACQ;               // its line's Acquire may go
            end else begin
              rb_q <= rb_q + 1'b1;
              rs_q <= R_RD;
            end
          end
          R_WAIT: if (d_fire && d_i.opcode == D_RELEASE_ACK) begin
            rs_q   <= R_IDLE;
            rack_q <= 1'b1;
          end
          default: ;
        endcase
        if (a_valid && a_ready_i) begin
          es_q[a_i] <= E_GRANT;
          eb_q[a_i] <= '0;
        end
        if (d_fire && d_for_e) begin
          ecap_q[d_e] <= {1'b0, d_i.param};
          esk_q[d_e]  <= d_i.sink;
          if (d_i.denied || d_i.corrupt) eden_q[d_e] <= 1'b1;
          if (d_i.opcode == D_GRANT || eb_q[d_e] == 2'd3) es_q[d_e] <= E_GACK;
          eb_q[d_e] <= eb_q[d_e] + 1'b1;
        end
        if (e_valid && e_ready_i) es_q[g_i] <= E_INSTALL;
        if (inst_go) begin                       // the state write is in the comb block above
          es_q[i_i]   <= E_IDLE;
          done_q[i_i] <= 1'b1;
          // A denied prefetch records nothing: the store, or a load, then asks for the line itself
          if (mi_den) begin
            if (!epf_q[i_i]) begin
              dn_v_q[i_i] <= 1'b1;
              dn_l_q[i_i] <= mi_line;
            end
          end else begin
            for (int k = 0; k < N; k++) if (dn_v_q[k] && dn_l_q[k] == mi_line) dn_v_q[k] <= 1'b0;
          end
        end
      end
    end
    logic unused_mn;
    assign unused_mn = ^{rq_pa_q[5:0], pf_pa[5:0], d_i.source, al_w};   // al_w: the one-MSHR reference model's
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (!rst) begin
        for (int e = 0; e < N; e++)
          for (int k = e + 1; k < N; k++)
            assert (!(busy[e] && busy[k] && el_q[e] == el_q[k])) else $error("tg_dcache: two entries for one line");
        if (alloc_pf)
          assert (STORE_PF && !alloc_st && !alloc_ld && !pb_st && f_two && pf_room && !(|(ch & sc.t)))
            else $error("tg_dcache: a prefetch allocates beside a demand access, or without an entry to spare");
        assert ($countones(busy & epf_q) <= PF_MAX) else $error("tg_dcache: too many prefetches in flight");
        if (d_valid_i && (d_i.opcode == D_GRANT_DATA || d_i.opcode == D_GRANT))
          assert (d_for_e) else $error("tg_dcache: a Grant for no waiting entry (source %0d)", d_i.source);
        if (d_valid_i && d_i.opcode == D_RELEASE_ACK)
          assert (rs_q == R_WAIT) else $error("tg_dcache: ReleaseAck with no Release outstanding");
        if (al_go) assert (f_any && !m_inst) else $error("tg_dcache: an allocation with no free entry, or beside an install");
        if (a_valid && rs_q != R_IDLE)
          assert (a_line != rl_q) else $error("tg_dcache: an Acquire for the line being released");
      end
    end
    // The prefetch's statistics, on stderr with +stpf (stdout is compared with Spike): requests,
    // allocations (upgrades in place), lookups that ended with the line held with T or in an entry,
    // denied fills; the store port's allocations, and its cycles waiting for its line in a prefetch's
    // entry or in its own (or a load's)
    longint unsigned ps_req, ps_al, ps_up, ps_own, ps_ent, ps_den, ps_st_al, ps_st_wpf, ps_st_wo;
    longint unsigned ps_rep, ps_w_ld, ps_w_two, ps_w_room, ps_w_st, ps_w_oth;
    longint unsigned ps_w_prb, ps_w_inst, ps_w_rline, ps_w_eng, ps_w_base;
    longint unsigned ps_late, ps_sa_free, ps_sa_inst, ps_sa_rline, ps_sa_eng, ps_sa_base, ps_sa_oth;
    logic            ps_end;
    assign ps_end = c_pf && !probe_active && (alloc_pf || |(ch & sc.t) || rq_busy);
    bit ps_on;
    string ps_nm;
    initial begin
      ps_on = $test$plusargs("stpf");
      ps_nm = $sformatf("%m");
    end
    always_ff @(posedge clk) begin
      if (rst) begin
        {ps_req, ps_al, ps_up, ps_own, ps_ent, ps_den, ps_st_al, ps_st_wpf, ps_st_wo} <= '0;
        {ps_rep, ps_w_ld, ps_w_two, ps_w_room, ps_w_st, ps_w_oth} <= '0;
        {ps_w_prb, ps_w_inst, ps_w_rline, ps_w_eng, ps_w_base} <= '0;
        {ps_late, ps_sa_free, ps_sa_inst, ps_sa_rline, ps_sa_eng, ps_sa_base, ps_sa_oth} <= '0;
      end else if (ps_on) begin
        if (pf_req && STORE_PF) ps_req <= ps_req + 1;
        if (alloc_pf) ps_al <= ps_al + 1;
        if (al_upc) ps_up <= ps_up + 1;
        if (c_pf && !probe_active && |(ch & sc.t)) ps_own <= ps_own + 1;
        if (c_pf && !probe_active && rq_busy) ps_ent <= ps_ent + 1;
        if (inst_go && mi_den && epf_q[i_i]) ps_den <= ps_den + 1;
        if (alloc_st && st_req) ps_st_al <= ps_st_al + 1;
        if (st_req && st_busy) begin
          if (|(st_m & epf_q)) ps_st_wpf <= ps_st_wpf + 1;
          else                 ps_st_wo  <= ps_st_wo + 1;
        end
        // a pending prefetch replaced by another line before it ended; its waits, by the first reason
        if (pf_req && STORE_PF && pq_v_q && !ps_end && pf_pa[PA_W-1:6] != pq_l_q) ps_rep <= ps_rep + 1;
        if (STORE_PF && pq_v_q && !ps_end) begin
          if (rq_v_q)                   ps_w_ld   <= ps_w_ld + 1;
          else if (probe_active)        ps_w_prb  <= ps_w_prb + 1;
          else if (!f_two)              ps_w_two  <= ps_w_two + 1;
          else if (!pf_room)            ps_w_room <= ps_w_room + 1;
          else if (st_req && !st_busy)  ps_w_st   <= ps_w_st + 1;
          else if (m_inst)              ps_w_inst <= ps_w_inst + 1;
          else if (rq_rel)              ps_w_rline <= ps_w_rline + 1;
          else if (rs_q != R_IDLE && !(|ch) && ev_c) ps_w_eng <= ps_w_eng + 1;
          else if (!al_base)            ps_w_base <= ps_w_base + 1;
          else                          ps_w_oth  <= ps_w_oth + 1;
        end
        // a store that allocates its own line while that line's prefetch is still pending
        if (alloc_st && st_req && STORE_PF && pq_v_q && pq_l_q == sx_pa[PA_W-1:6]) ps_late <= ps_late + 1;
        // a store that misses and cannot allocate, by the first reason
        if (st_req && !s_hit_t && !st_busy && !alloc_st && !dn_hit) begin
          if (!f_any)                   ps_sa_free  <= ps_sa_free + 1;
          else if (m_inst)              ps_sa_inst  <= ps_sa_inst + 1;
          else if (st_rel)              ps_sa_rline <= ps_sa_rline + 1;
          else if (rs_q != R_IDLE && !s_hit && ev_s) ps_sa_eng <= ps_sa_eng + 1;
          else if (!al_base)            ps_sa_base  <= ps_sa_base + 1;
          else                          ps_sa_oth   <= ps_sa_oth + 1;
        end
      end
    end
    final if (ps_on)
      $fwrite(32'h8000_0002, "TG-STPF %s req=%0d alloc=%0d up=%0d end_owned=%0d end_entry=%0d denied=%0d st_alloc=%0d st_wait_pf=%0d st_wait_own=%0d replaced=%0d wait_ld=%0d wait_two=%0d wait_room=%0d wait_st=%0d wait_other=%0d wait_probe=%0d wait_inst=%0d wait_relline=%0d wait_engine=%0d wait_base=%0d late=%0d st_noalloc_free=%0d st_noalloc_inst=%0d st_noalloc_relline=%0d st_noalloc_engine=%0d st_noalloc_base=%0d st_noalloc_other=%0d\n",
              ps_nm, ps_req, ps_al, ps_up, ps_own, ps_ent, ps_den, ps_st_al, ps_st_wpf, ps_st_wo,
              ps_rep, ps_w_ld, ps_w_two, ps_w_room, ps_w_st, ps_w_oth,
              ps_w_prb, ps_w_inst, ps_w_rline, ps_w_eng, ps_w_base,
              ps_late, ps_sa_free, ps_sa_inst, ps_sa_rline, ps_sa_eng, ps_sa_base, ps_sa_oth);
`endif
  end

  // Tag write at install
  assign tag_we  = inst_go && !mi_den;
  assign tag_way = mi_way;
  assign tag_set = mi_line[6 +: SET_W];
  assign tag_wd  = mi_line[PA_W-1:12];

  logic unused;
  assign unused = ^{m_holdb,                    // m_holdb: read by #11's check only
                    b_i.size, d_i.size, d_i.source, ld_rd_pa[3:0], ld_rd_pa[PA_W-1:12],
                    ld_m1_pa[5:0], ctl_pa[5:0], lm_pa[5:0], st_pa[5:0], p_pa_q[5:0], mi_cap[2], al_pa[5:0],
                    sx_pa[5:0], am_pa[2:0]};

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      assert ($onehot0(lh)) else $error("tg_dcache: multiple way hits");
      assert ($onehot0({pb_probe, pb_grant, pb_ev, pb_st, pb_amr, pb_amw})) else $error("tg_dcache: port B conflict");
      assert (!(st_req && am_req)) else $error("tg_dcache: store and atomic requests together");
      assert (!(st_req && am_sel) && (!am_req || am_sel)) else $error("tg_dcache: a store drains while an atomic holds the store port");
      assert ($onehot0(sh) && $onehot0(ch)) else $error("tg_dcache: multiple way hits (store port, controller)");
      if (amw_q) assert (ps_q == P_IDLE && m_none) else $error("tg_dcache: atomic write not exclusive");
      // port B's read data belongs to the way its reader expects
      if (ps_q == P_SEND) assert (brd_way_q == p_way_q) else $error("tg_dcache: probe data from another way");
      if (rel_send && rel_dirty) assert (brd_way_q == mv_way) else $error("tg_dcache: release data from another way");
    end
  end
  // (one MSHR only: the entries of DC_MSHRS > 1 are a different arbitration)
  if (DC_MSHRS == 1) begin : g_ref
    // The arbitration as written before DR-145's restructure, on the same lookups: its decisions,
    // its port-B accesses, its state writes and its MSHR fields, checked against the restructured
    // logic every cycle
    sst_t             sa;                  // the allocation set: store port or controller port
    logic             r_s_hit_t, r_alloc_st, r_alloc_ld, r_sx_drop, r_al_go, r_pb_st, r_al_hb;
    logic [WAY_W-1:0] r_victim, r_al_hway;
    logic [WAYS-1:0]  r_b_en;
    logic [15:0]      r_b_we;
    logic [ROW_W-1:0] r_b_addr;
    logic [127:0]     r_b_wdata;
    logic             r_brd_en;
    logic [WAY_W-1:0] r_brd_way;
    logic             r_st_we;
    logic [SET_W-1:0] r_st_wa;
    sst_t             r_st_wd;
    always_comb begin
      logic found;
      r_s_hit_t  = s_hit && ss.t[sh_way];
      r_alloc_st = 1'b0;
      r_alloc_ld = 1'b0;
      if (m_none && !probe_active && !(b_valid_i && ps_q == P_IDLE) && !pb_amr && !am_busy && !fu_st && ready) begin
        if (sx_req && !r_s_hit_t)  r_alloc_st = 1'b1;
        else if (c_req && !(|ch) && !(SPLIT && split_i && st_resv)) r_alloc_ld = 1'b1;
      end
      r_sx_drop = sx_req && m_none && dn_hit && !r_s_hit_t
                  && !r_alloc_ld && !probe_active;
      r_al_go   = m_none && (r_alloc_st || r_alloc_ld) && !r_sx_drop;
      r_pb_st   = st_req && r_s_hit_t && !probe_active && !m_on_c && !pb_grant &&
                  !m_inst && !r_al_go;
      r_al_hb   = r_alloc_st ? |sh : |ch;
      r_al_hway = enc(r_alloc_st ? sh : ch);
      sa = r_alloc_st ? ss : sc;
      found = 1'b0;
      r_victim = sa.rr;
      for (int w = 0; w < WAYS; w++) begin
        if (!found && !sa.v[w]) begin
          r_victim = WAY_W'(w);
          found = 1'b1;
        end
      end
      r_b_en = '0; r_b_we = '0; r_b_addr = '0; r_b_wdata = '0;
      r_brd_en = 1'b0; r_brd_way = '0;
      if (pb_probe) begin
        r_brd_en = 1'b1; r_brd_way = p_way_q;
        r_b_en[p_way_q] = 1'b1;
        r_b_addr = {p_pa_q[6 +: SET_W], p_beat_q};
      end else if (pb_grant) begin
        r_b_en[mg_way] = 1'b1;
        r_b_we = '1;
        r_b_addr = {mg_set, mg_beat};
        r_b_wdata = d_i.data;
      end else if (pb_ev) begin
        r_brd_en = 1'b1; r_brd_way = mv_way;
        r_b_en[mv_way] = 1'b1;
        r_b_addr = {mv_set, mv_beat};
      end else if (r_pb_st) begin
        r_b_en[sh_way] = 1'b1;
        r_b_we = st_mask;
        r_b_addr = st_pa[4 +: ROW_W];
        r_b_wdata = {2{st_wdata}};
      end else if (pb_amr) begin
        r_brd_en = 1'b1; r_brd_way = sh_way;
        r_b_en[sh_way] = 1'b1;
        r_b_addr = am_pa[4 +: ROW_W];
      end else if (pb_amw) begin
        r_b_en[am_way_q] = 1'b1;
        r_b_we = am_wmask;
        r_b_addr = am_row_q;
        r_b_wdata = {2{am_wdata}};
      end
      r_st_we = 1'b0;
      r_st_wa = '0;
      r_st_wd = sw;
      if (!ready) begin
        r_st_we = 1'b1;
        r_st_wa = init_q[SET_W-1:0];
        r_st_wd = '0;
      end else if (ps_q == P_UPD && p_hit_q) begin
        r_st_we = 1'b1;
        r_st_wa = p_pa_q[6 +: SET_W];
        r_st_wd = sw;
        r_st_wd.v[p_way_q] = p_nv_q;
        r_st_wd.t[p_way_q] = p_nt_q;
        if (!p_nt_q) r_st_wd.d[p_way_q] = 1'b0;
      end else if (inst_go) begin
        r_st_we = 1'b1;
        r_st_wa = mi_line[6 +: SET_W];
        r_st_wd = sw;
        r_st_wd.v[mi_way] = !mi_den;
        r_st_wd.t[mi_way] = !mi_den && mi_cap == TL_CAP_TO_T;
        r_st_wd.d[mi_way] = 1'b0;
      end else if (r_al_go && !(r_alloc_st && r_al_hb)) begin
        r_st_we = 1'b1;
        r_st_wa = (r_alloc_st ? sx_pa[6 +: SET_W] : c_pa[6 +: SET_W]);
        r_st_wd = sa;
        r_st_wd.rr = sa.rr + 1'b1;
        r_st_wd.v[r_victim] = 1'b0;
        r_st_wd.t[r_victim] = 1'b0;
        r_st_wd.d[r_victim] = 1'b0;
      end else if (r_pb_st) begin
        r_st_we = 1'b1;
        r_st_wa = sx_pa[6 +: SET_W];
        r_st_wd = ss;
        r_st_wd.d[sh_way] = 1'b1;
      end else if (pb_amw) begin
        r_st_we = 1'b1;
        r_st_wa = am_row_q[ROW_W-1:2];
        r_st_wd = sw;
        r_st_wd.d[am_way_q] = 1'b1;
      end
    end
    always_ff @(posedge clk) begin
      if (!rst) begin
        assert (r_s_hit_t == s_hit_t && r_alloc_st == alloc_st && r_alloc_ld == alloc_ld &&
                r_sx_drop == sx_drop && r_al_go == al_go && r_pb_st == pb_st &&
                (r_al_go && !(r_alloc_st && r_al_hb)) == al_w && (r_al_go && r_alloc_st && r_al_hb) == al_up)
          else $error("tg_dcache: the arbitration decides otherwise than its earlier form");
        assert (r_b_en == b_en && r_brd_en == brd_en && (!brd_en || r_brd_way == brd_way))
          else $error("tg_dcache: port B's enables differ from the earlier form");
        if (|b_en) assert (r_b_addr == b_addr && r_b_we == b_we && (b_we == '0 || r_b_wdata == b_wdata))
          else $error("tg_dcache: a port-B access differs from the earlier form");
        assert (r_st_we == st_we && (!st_we || (r_st_wa == st_wa && r_st_wd == st_wd)))
          else $error("tg_dcache: a state write differs from the earlier form");
        if (al_go) begin
          assert ((al_up ? sh_way : victim) == (r_alloc_st && r_al_hb ? r_al_hway : r_victim))
            else $error("tg_dcache: the MSHR's way differs from the earlier form");
          if (!al_up)
            assert ((alloc_st ? ev_s : ev_c) == sa.v[r_victim] &&
                    (!sa.v[r_victim] || ((alloc_st ? evt_s : evt_c) == tag_rd[r_victim][r_alloc_st ? 1 : 2] &&
                                         (alloc_st ? ss.d[ss.rr] : sc.d[sc.rr]) == sa.d[r_victim] &&
                                         (alloc_st ? ss.t[ss.rr] : sc.t[sc.rr]) == sa.t[r_victim])))
              else $error("tg_dcache: the victim's fields differ from the earlier form");
        end
      end
    end
    // A state write starts from its set's state: a shadow of the state RAMs, written alike
    sst_t sh_q [SETS];
    logic rs_q;                     // the cache has been reset: the check waits for it
    initial rs_q = 1'b0;
    always @(posedge clk) begin
      if (rst) rs_q <= 1'b1;
      if (st_we) sh_q[st_wa] <= st_wd;
      if (rs_q && !rst && ready) begin
        if ((ps_q == P_UPD && p_hit_q) || inst_go || (pb_amw && !al_go && !pb_st))
          assert (!st_we || sw == sh_q[st_wa]) else $error("tg_dcache: port 3 read another set than the write's");
        else if (al_w)
          assert (sa == sh_q[st_wa]) else $error("tg_dcache: an allocation's state is not its set's");
        else if (pb_st)
          assert (ss == sh_q[st_wa]) else $error("tg_dcache: a store's state is not its set's");
      end
    end
  end
`endif
  assign dbg_o = {ready, m_dbg, 3'(ps_q)};
endmodule
