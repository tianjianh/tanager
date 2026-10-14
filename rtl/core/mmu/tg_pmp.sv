// PMP check (docs/spec/core-mmu.md): the 16 entries of tg_csr, OFF / TOR / NA4 / NAPOT, 4-byte
// granules. The lowest-numbered entry that matches any granule of the access decides and must
// match all of them; with no matching entry only M is allowed. Locked entries bind M too. As
// Spike's pmp_ok without Smepmp. Combinational; an access is at most 8 bytes, naturally aligned.
module tg_pmp
  import tg_pkg::*, tg_core_pkg::*;
(
  input  logic [PA_W-1:0]   pa,
  input  logic              dbl,          // an 8-byte access: two granules
  input  acc_e              acc,
  input  logic              m_mode,
  input  logic [15:0][7:0]  cfg,
  input  logic [15:0][53:0] addr,         // pmpaddr: address bits 55:2
  output logic              ok
);
  logic [53:0] g0, g1;
  assign g0 = 54'(pa[PA_W-1:2]);
  assign g1 = dbl ? (g0 | 54'd1) : g0;

  // Does entry i match granule g?
  function automatic logic m4(input int i, input logic [53:0] g, input logic [15:0][7:0] c,
                              input logic [15:0][53:0] a);
    logic [53:0] y, dc, base;
    base = (i == 0) ? '0 : a[(i + 15) % 16];
    y  = {a[i][52:0], 1'b1};
    dc = y & ~(y + 54'd1);                     // NAPOT: the trailing ones of {pmpaddr, 1}
    unique case (c[i][4:3])
      2'd0:    return 1'b0;
      2'd1:    return g >= base && g < a[i];   // TOR
      2'd2:    return g == a[i];               // NA4
      default: return ((g ^ a[i]) & ~dc) == '0;
    endcase
  endfunction

  logic [15:0] h0, h1;
  for (genvar i = 0; i < 16; i++) begin : g_m
    assign h0[i] = m4(i, g0, cfg, addr);
    assign h1[i] = m4(i, g1, cfg, addr);
  end
  logic unused;
  assign unused = ^pa[1:0];
  always_comb begin
    ok = m_mode;
    for (int i = 15; i >= 0; i--) begin
      if (h0[i] || h1[i]) begin
        ok = h0[i] && h1[i] &&
             ((m_mode && !cfg[i][7]) || (acc == ACC_R && cfg[i][0]) || (acc == ACC_W && cfg[i][1]) ||
              (acc == ACC_X && cfg[i][2]));
      end
    end
  end
endmodule
