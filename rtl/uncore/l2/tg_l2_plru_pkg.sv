// Tree pseudo-LRU for 8 ways and the L2's victim choice (docs/spec/l2.md §Transactions).
// Bit 0 is the root; a 0 bit points the victim search to the lower half.
package tg_l2_plru_pkg;
  function automatic logic [2:0] plru_victim(input logic [6:0] b);
    logic [2:0] w;
    w[2] = b[0];
    w[1] = b[1 + w[2]];
    w[0] = b[3 + {w[2], w[1]}];
    return w;
  endfunction

  // Point every node on the path to `w` away from it.
  function automatic logic [6:0] plru_touch(input logic [6:0] b, input logic [2:0] w);
    logic [6:0] r;
    r = b;
    r[0] = ~w[2];
    r[1 + w[2]] = ~w[1];
    r[3 + {w[2], w[1]}] = ~w[0];
    return r;
  endfunction

  function automatic logic [2:0] lowest8(input logic [7:0] v);
    for (int i = 0; i < 8; i++) if (v[i]) return 3'(i);
    return 3'd0;
  endfunction

  // Victim: an invalid unreserved way; else among unreserved ways prefer one no L1 holds
  // (the PLRU choice if it qualifies, else the lowest); else the PLRU choice if unreserved,
  // else the lowest unreserved way. The caller guarantees some way is unreserved.
  function automatic logic [2:0] pick_victim(input logic [7:0] valid, input logic [7:0] held,
                                             input logic [7:0] resv, input logic [6:0] plru);
    logic [7:0] inv, cand, cz;
    logic [2:0] pv;
    inv  = ~valid & ~resv;
    cand = ~resv;
    cz   = cand & ~held;
    pv   = plru_victim(plru);
    if (inv != '0) return lowest8(inv);
    if (cz != '0)  return cz[pv] ? pv : lowest8(cz);
    return cand[pv] ? pv : lowest8(cand);
  endfunction

  // pick_victim's choice one-hot, without the priority encoders: the lowest set bit is v & -v
  // (a carry chain), so the victim drives selects and way enables straight (200 MHz, DR-137).
  function automatic logic [7:0] pick_victim_oh(input logic [7:0] valid, input logic [7:0] held,
                                                input logic [7:0] resv, input logic [6:0] plru);
    logic [7:0] inv, cand, cz, pvo;
    inv  = ~valid & ~resv;
    cand = ~resv;
    cz   = cand & ~held;
    pvo  = 8'd1 << plru_victim(plru);
    if (inv != '0)          return inv & (~inv + 8'd1);
    if (cz != '0)           return ((cz & pvo) != '0) ? pvo : (cz & (~cz + 8'd1));
    if ((cand & pvo) != '0) return pvo;
    return (cand != '0) ? (cand & (~cand + 8'd1)) : 8'd1;   // none unreserved: way 0, as lowest8
  endfunction
endpackage
