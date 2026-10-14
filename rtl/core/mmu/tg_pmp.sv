// PMP check (docs/spec/core-mmu.md §PMP) on the region descriptors tg_csr precomputes: 16
// entries, OFF / TOR / NA4 / NAPOT, 4-byte granules, as Spike's pmp_ok without Smepmp. The
// lowest-numbered entry matching any granule of the access decides and must match all of
// them; with no match only M is allowed; locked entries bind M too. Combinational.
// TOR shares one comparator per entry: entry i matches [top(i-1), top(i)), so A < top(i) is
// computed once and used by entries i and i+1. Only PA_W - 2 granule bits are compared.
//   S = 1: an access of one granule, or two (dbl: 8 bytes, naturally aligned): ok[0].
//   S = 2: a 16-byte fetch block, one result per 4-byte word: ok[3:0].
// `hit`/`rwx` (S = 1): the deciding entry for the first granule, for the TLB's cached result.
module tg_pmp
  import tg_pkg::*, tg_core_pkg::*;
#(
  parameter int S = 1,
  localparam int NW = (S == 2) ? 4 : 1
) (
  input  logic [PA_W-1:0]   pa,
  input  logic              dbl,          // S = 1: an 8-byte access
  input  acc_e              acc,
  input  logic              m_mode,
  input  pmp_d_t [15:0]     d,
  output logic [NW-1:0]     ok,
  output logic              hit,
  output logic [2:0]        rwx
);
  localparam int GW = PMP_GW;

  // Per entry and word: does the entry match the word's granule(s), any and all of them?
  logic [NW-1:0][15:0] any_m, all_m;
  if (S == 2) begin : g_blk
    // Block granules {B, w}: compare the block index once, then the two low bits per word
    logic [GW-3:0]   B;
    logic [15:0]     ltb, eqb, nhi;
    assign B = pa[PA_W-1:4];
    for (genvar i = 0; i < 16; i++) begin : g_e
      assign ltb[i] = d[i].hi || B < d[i].a[GW-1:2];
      assign eqb[i] = !d[i].hi && B == d[i].a[GW-1:2];
      assign nhi[i] = !d[i].above && ((B ^ d[i].a[GW-1:2]) & d[i].mask[GW-1:2]) == '0;
    end
    for (genvar w = 0; w < 4; w++) begin : g_w
      logic [15:0] lt;                     // granule {B, w} < top(i)
      for (genvar i = 0; i < 16; i++) begin : g_e
        /* verilator lint_off CMPCONST */   // word 3 is never below a top in its block
        assign lt[i] = ltb[i] || (eqb[i] && 2'(w) < d[i].a[1:0]);
        /* verilator lint_on CMPCONST */
        logic napm, torm;
        assign napm = nhi[i] && ((2'(w) ^ d[i].a[1:0]) & d[i].mask[1:0]) == '0;
        assign torm = lt[i] && (i == 0 || !lt[(i + 15) % 16]);
        assign any_m[w][i] = (d[i].nap && napm) || (d[i].tor && torm);
        assign all_m[w][i] = any_m[w][i];
      end
    end
  end else begin : g_acc
    // Granules A and, for dbl, A + 1 (A even)
    logic [GW-1:0] A;
    logic [15:0]   lt0, lt1;               // A < top(i), A + 1 < top(i) (lt1 = lt0 unless dbl)
    assign A = pa[PA_W-1:2];
    for (genvar i = 0; i < 16; i++) begin : g_e
      logic eqo;                           // top(i) = A + 1 (odd, the dword's second granule)
      assign lt0[i] = d[i].hi || A < d[i].a;
      assign eqo    = !d[i].hi && d[i].a[0] && A[GW-1:1] == d[i].a[GW-1:1];
      assign lt1[i] = lt0[i] && !(dbl && eqo);
      logic [GW-1:0] x;
      assign x = (A ^ d[i].a) & d[i].mask;
      logic nh, n0;
      assign nh = !d[i].above && x[GW-1:1] == '0;
      assign n0 = !x[0];
      // NAPOT: a 2-granule access matches entirely unless the region is one granule (NA4)
      logic nany, nall, tany, tall;
      assign nany = nh && (dbl || n0);
      assign nall = nh && (dbl ? !d[i].mask[0] : n0);
      // TOR [top(i-1), top(i)): any = A + 1 >= lo && A < hi; all = A >= lo && A + 1 < hi
      assign tany = lt0[i] && (i == 0 || !lt1[(i + 15) % 16]);
      assign tall = lt1[i] && (i == 0 || !lt0[(i + 15) % 16]);
      assign any_m[0][i] = (d[i].nap && nany) || (d[i].tor && tany);
      assign all_m[0][i] = (d[i].nap && nall) || (d[i].tor && tall);
    end
  end

  // The lowest matching entry decides
  for (genvar w = 0; w < NW; w++) begin : g_dec
    always_comb begin
      ok[w] = m_mode;
      for (int i = 15; i >= 0; i--) begin
        if (any_m[w][i]) begin
          ok[w] = all_m[w][i] &&
                  ((m_mode && !d[i].l) || (acc == ACC_R && d[i].r) || (acc == ACC_W && d[i].w) ||
                   (acc == ACC_X && d[i].x));
        end
      end
    end
  end
  always_comb begin
    hit = 1'b0;
    rwx = '0;
    for (int i = 15; i >= 0; i--) begin
      if (any_m[0][i]) begin
        hit = 1'b1;
        rwx = {d[i].r, d[i].w, d[i].x};
      end
    end
  end

  logic unused;
  assign unused = ^{pa[3:0], dbl};
endmodule
