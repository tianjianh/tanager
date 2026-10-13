// Random test of tg_dtlb (S4) against a reference model: fills of 4 KiB, 2 MiB and 1 GiB
// pages, global and per-ASID entries, both threads; lookups with matching and non-matching
// VPNs; per-thread flushes (all, or one ASID's non-global entries).
//   Vtb_dtlb +seed=<n> +iters=<n>
module tb_dtlb;
  import tg_pkg::*;
  localparam int NE = DTLB_ENTRIES;
  localparam int PPN_W = PA_W - 12;
  localparam int EW = idx_w(NE);

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  tid_t tid, fill_tid, flush_tid;
  logic [15:0] asid, fill_asid, flush_asid;
  logic [38:12] vpn, fill_vpn;
  logic hit, fill_valid, fill_g, flush_valid, flush_all;
  logic [PPN_W-1:0] ppn, fill_ppn;
  logic [5:0] perm, fill_perm;
  logic [EW-1:0] fill_idx;
  logic [1:0] fill_lvl;
  tg_dtlb #(.NE(NE)) dut (.*);

  typedef struct { bit v; int tid; int asid; logic [38:12] vpn; int lvl; bit g;
                   logic [PPN_W-1:0] ppn; logic [5:0] perm; } ent_t;
  ent_t ref_e [NE];
  int errors = 0;

  function automatic bit ent_hit(input ent_t e, input int t, input int a, input logic [38:12] v);
    if (!e.v || e.tid != t || !(e.g || e.asid == a)) return 0;
    if (e.vpn[38:30] != v[38:30]) return 0;
    if (e.lvl < 2 && e.vpn[29:21] != v[29:21]) return 0;
    if (e.lvl < 1 && e.vpn[20:12] != v[20:12]) return 0;
    return 1;
  endfunction

  // Would a new entry overlap a valid one of the same thread and address space?
  function automatic bit has_clash(input ent_t nf, input int idx);
    for (int k = 0; k < NE; k++) begin
      if (k == idx || !ref_e[k].v || ref_e[k].tid != nf.tid) continue;
      if (!(ref_e[k].g || nf.g || ref_e[k].asid == nf.asid)) continue;
      if (ref_e[k].vpn[38:30] != nf.vpn[38:30]) continue;
      if (ref_e[k].lvl < 2 && nf.lvl < 2 && ref_e[k].vpn[29:21] != nf.vpn[29:21]) continue;
      if (ref_e[k].lvl < 1 && nf.lvl < 1 && ref_e[k].vpn[20:12] != nf.vpn[20:12]) continue;
      return 1;
    end
    return 0;
  endfunction

  // A small VPN space, so lookups often hit and superpages overlap 4 KiB pages
  function automatic logic [38:12] rvpn();
    logic [38:12] v;
    v = '0;
    v[38:30] = 9'($urandom % 3);
    v[29:21] = 9'($urandom % 4);
    v[20:12] = 9'($urandom % 8);
    return v;
  endfunction

  ent_t nf;
  int idx;
  bit clash;
  logic [PPN_W-1:0] want;
  initial begin
    int seed = 1, iters = 100000, nhit = 0;
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("iters=%d", iters));
    void'($urandom(seed));
    for (int e = 0; e < NE; e++) ref_e[e].v = 0;
    fill_valid = 0; flush_valid = 0;
    repeat (3) @(posedge clk);
    @(negedge clk) rst = 0;
    for (int i = 0; i < iters; i++) begin
      @(negedge clk);
      // check the lookup set up in the previous half cycle
      begin
        automatic int nm = 0, m = -1;
        for (int e = 0; e < NE; e++) if (ent_hit(ref_e[e], int'(tid), int'(asid), vpn)) begin nm++; m = e; end
        // overlapping fills are avoided below, so at most one entry matches
        if (hit != (nm == 1)) begin
          errors++;
          if (errors < 10) $display("ERROR hit %b want %b (vpn %h)", hit, nm == 1, vpn);
        end else if (hit) begin
          want = ref_e[m].ppn;
          nhit++;
          if (ref_e[m].lvl >= 1) want[8:0] = vpn[20:12];
          if (ref_e[m].lvl == 2) want[17:9] = vpn[29:21];
          if (ppn != want || perm != ref_e[m].perm) begin
            errors++;
            if (errors < 10) $display("ERROR ppn %h want %h", ppn, want);
          end
        end
      end
      // next: a fill, a flush or nothing, and a new lookup
      fill_valid = 0; flush_valid = 0;
      case ($urandom % 10)
        0, 1, 2: begin
          idx = $urandom % NE;
          nf.v = 1; nf.tid = $urandom % NUM_THREADS; nf.asid = $urandom % 3; nf.vpn = rvpn();
          nf.lvl = ($urandom % 4 == 0) ? (($urandom % 3 == 0) ? 2 : 1) : 0;
          nf.g = ($urandom % 5) == 0; nf.ppn = {$urandom, $urandom}; nf.perm = 6'($urandom);
          // the page walker never installs two translations of the same address
          clash = has_clash(nf, idx);
          if (!clash) begin
            fill_valid = 1; fill_idx = EW'(idx); fill_tid = tid_t'(nf.tid); fill_asid = 16'(nf.asid);
            fill_vpn = nf.vpn; fill_lvl = 2'(nf.lvl); fill_g = nf.g; fill_ppn = nf.ppn; fill_perm = nf.perm;
            ref_e[idx] = nf;
          end
        end
        3: if (($urandom % 4) == 0) begin
          flush_valid = 1; flush_tid = tid_t'($urandom % NUM_THREADS);
          flush_all = $urandom % 2; flush_asid = 16'($urandom % 3);
          for (int k = 0; k < NE; k++)
            if (ref_e[k].v && ref_e[k].tid == int'(flush_tid)
                && (flush_all || (!ref_e[k].g && ref_e[k].asid == int'(flush_asid)))) ref_e[k].v = 0;
          // a fill in the same cycle wins over the flush (matches the RTL's order)
        end
        default: ;
      endcase
      tid = tid_t'($urandom % NUM_THREADS); asid = 16'($urandom % 3); vpn = rvpn();
      @(posedge clk);
    end
    if (errors == 0) $display("PASS tb_dtlb (%0d lookups, %0d hits)", iters, nhit);
    else $display("FAIL tb_dtlb: %0d errors", errors);
    $finish;
  end
endmodule
