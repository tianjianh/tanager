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
  // The reservations arrive last, so every candidate and every condition is formed from them in
  // parallel and one priority select picks among them (200 MHz, DR-142): synthesis built the
  // nested form (pick_victim_ref, kept for the assertions) 7 LUT levels deep past the
  // reservations. The same function.
  function automatic logic [2:0] pick_victim(input logic [7:0] valid, input logic [7:0] held,
                                             input logic [7:0] resv, input logic [6:0] plru);
    logic [7:0] inv, cand, cz;
    logic [2:0] pv;
    inv  = ~valid & ~resv;
    cand = ~resv;
    cz   = cand & ~held;
    pv   = plru_victim(plru);
    casez ({inv != '0, cz[pv], cz != '0, cand[pv]})
      4'b1???: return lowest8(inv);
      4'b01??: return pv;
      4'b001?: return lowest8(cz);
      4'b0001: return pv;
      default: return lowest8(cand);
    endcase
  endfunction

  function automatic logic [2:0] pick_victim_ref(input logic [7:0] valid, input logic [7:0] held,
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
endpackage
