// Sv39 page-table walker (docs/spec/core-mmu.md): one walk at a time, for the ROB head's
// deciding walk (requester 0), an ITLB miss (1) or a DTLB prefetch (2), in that priority.
// PTE reads go through the load pipe (pt_req until pt_gnt; the result comes back at M2); a
// missing line waits for the MSHR like a load. The checks follow Spike's walk(): the PTE
// address must be PMA_MEM below PA_W and allowed by PMP in S (else an access fault); then
// reserved bits, non-leaf flags, the U rule, invalid encodings, superpage alignment, the
// access permission and Svade's A/D (each a page fault). A success returns the leaf for the
// requester's TLB, with the page's PMP result cached (plan §4.10): one more cycle checks the
// page base, and the result holds for the whole page when no active PMP region boundary lies
// strictly inside the page: for a 2M page checked here against every entry, for 4K and 1G pages
// tg_csr's flag for every page of the size (pmp_al). A flush ends the walk; its PTE read, if any,
// dies in the load pipe.
// The PMP checks (the PTE address, the page base) use the STA port's checker in a cycle the
// port leaves it free (chk_gnt); W_CHK and W_PMP wait for one, and say so (chk_req). The request
// and its address come from flip-flops, set as the walk enters those states.
// Each walk is a hart's (M7's step 4, docs/spec/threading.md): the requester's thread, taken as the
// walk starts, selects its hart's satp, SUM, MXR and PMP state, and goes with the fill (done_tid)
// and with the checks (chk_tid: the shared checker takes that hart's PMP descriptors).
module tg_ptw
  import tg_pkg::*, tg_map_pkg::*, tg_core_pkg::*;
(
  input  logic              clk,
  input  logic              rst,
  input  logic              flush,
  // Each hart's state
  input  logic [NUM_THREADS-1:0][43:0]             satp_ppn,
  input  logic [NUM_THREADS-1:0]                   sum,
  input  logic [NUM_THREADS-1:0]                   mxr,
  input  pmp_d_t [NUM_THREADS-1:0][PMP_ENTRIES-1:0] pmp_d,
  input  logic [NUM_THREADS-1:0][2:0]              pmp_al,  // every 1G / 2M / 4K page is PMP-homogeneous
  input  logic [NUM_THREADS-1:0][PMP_ENTRIES-1:0]  pmp_p2m, // each entry's address is aligned to a 2M page
  // PMP checks on a shared checker (S mode, ACC_R)
  output logic [PA_W-1:0]   chk_pa,
  output logic              chk_dbl,      // an 8-byte access (the PTE), else one granule
  output tid_t              chk_tid,      // the hart whose PMP applies
  output logic              chk_req,      // a check is wanted this cycle (used if granted)
  input  logic              chk_gnt,      // the checker's result below is for chk_pa this cycle
  input  logic              chk_ok,
  input  logic              chk_hit,
  input  logic [2:0]        chk_rwx,
  // Requests, held until ack
  input  logic [2:0]        req,
  input  logic [2:0][63:0]  req_va,
  input  acc_e [2:0]        req_acc,
  input  priv_e [2:0]       req_mode,
  input  tid_t [2:0]        req_tid,
  output logic [2:0]        ack,
  // PTE reads through the load pipe
  output logic              pt_req,
  output logic [PA_W-1:0]   pt_pa,
  input  logic              pt_gnt,
  input  logic              pt_rsp,       // M2 of the read
  input  logic              pt_hit,
  input  logic              pt_den,       // the line's fill was denied
  input  logic [63:0]       pt_data,
  input  logic              mshr_idle,
  // Result, for one cycle
  output logic              done,
  output logic [2:0]        done_who,     // one-hot requester
  output tid_t              done_tid,     // the walk's thread (the fill's)
  output logic              done_ok,      // fill_* hold the leaf
  output logic [3:0]        done_cause,   // else the fault
  output logic [26:0]       fill_vpn,
  output logic [1:0]        fill_lvl,
  output tlb_pte_t          fill_pte
);
  typedef enum logic [2:0] { W_IDLE, W_CHK, W_REQ, W_WAIT, W_MISS, W_PMP, W_DONE } wstate_e;
  wstate_e     st_q;
  logic [2:0]  who_q;
  tid_t        tid_q;            // the walk's thread
  tid_t        wt, rt;           // ... as an index (0 without threads); the request's being taken
  logic [63:0] va_q;
  acc_e        acc_q;
  priv_e       mode_q;
  logic [1:0]  lvl_q;
  logic [43:0] base_q;           // PPN of the table at this level
  logic        ok_q;
  logic [3:0]  cause_q;
  tlb_pte_t    leaf_q;

  always_comb begin
    ack = '0;
    if (st_q == W_IDLE && !flush) begin
      if (req[0])      ack[0] = 1'b1;
      else if (req[1]) ack[1] = 1'b1;
      else if (req[2]) ack[2] = 1'b1;
    end
  end
  logic [1:0] k;
  assign k  = ack[0] ? 2'd0 : ack[1] ? 2'd1 : 2'd2;
  assign rt = (TID_W > 0) ? req_tid[k] : tid_t'(0);
  assign wt = (TID_W > 0) ? tid_q : tid_t'(0);

  // PTE address at this level, and its checks
  logic [8:0]  vpn_i;
  logic [55:0] pte_pa;
  always_comb begin
    unique case (lvl_q)
      2'd2:    vpn_i = va_q[38:30];
      2'd1:    vpn_i = va_q[29:21];
      default: vpn_i = va_q[20:12];
    endcase
  end
  assign pte_pa = {base_q, vpn_i, 3'b000};
  // The checks: the PTE address (8 bytes), or in W_PMP the leaf page's base. The request (W_CHK
  // with a canonical VA, or W_PMP) and the address are registered, each loaded with the value it
  // takes in the next cycle, so the checker's paths start at flip-flops, not at the VA (asserted
  // below)
  logic            pa_ok, chk_req_q;
  logic [PA_W-1:0] chk_pa_q;
  assign chk_pa  = chk_pa_q;
  assign chk_dbl = st_q != W_PMP;
  assign chk_req = chk_req_q;
  assign pa_ok   = pte_pa[55:PA_W] == '0 && pma_of(pte_pa[PA_W-1:0]) == PMA_MEM && chk_ok;
  assign pt_req = st_q == W_REQ;
  // A 2M leaf page is PMP-homogeneous when no active region boundary lies strictly inside it: no
  // NAPOT region smaller than 2M within it, and no TOR bound (an entry's address that tops its TOR
  // range or bottoms the next entry's) unaligned to 2M within it. A 4K or 1G leaf takes tg_csr's
  // flag for every page of its size: OpenSBI's regions are 4K-aligned, and its firmware region
  // splits the kernel's 2M pages, not its 4K ones
  localparam logic [PMP_GW-1:0] AL2M = PMP_GW'((64'd1 << 19) - 1);
  logic leaf_nh;
  always_comb begin
    logic [PMP_GW-1:0] pg;
    logic              in_pg, sub_pg, bound;
    pg = PMP_GW'({leaf_q.ppn, 10'b0});            // the page base in 4-byte granules
    leaf_nh = 1'b0;
    for (int i = 0; i < PMP_ENTRIES; i++) begin
      in_pg  = ((pmp_d[wt][i].a ^ pg) & ~AL2M) == '0;
      sub_pg = pmp_d[wt][i].nap && !pmp_d[wt][i].above && pmp_d[wt][i].mask[18];
      bound  = (pmp_d[wt][i].tor || (i < PMP_ENTRIES - 1 && pmp_d[wt][(i + 1) % PMP_ENTRIES].tor)) &&
               !pmp_p2m[wt][i];
      if (in_pg && (sub_pg || bound)) leaf_nh = 1'b1;
    end
  end
  assign pt_pa  = pte_pa[PA_W-1:0];

  // The PTE read
  logic [43:0] ppn;
  logic        pv, pr, pw, px, pu, pg, pa, pd, nonleaf, flt;
  assign ppn = pt_data[53:10];
  assign {pd, pa, pg, pu, px, pw, pr, pv} = pt_data[7:0];
  assign nonleaf = pv && !pr && !pw && !px;
  always_comb begin
    flt = 1'b0;
    if (pt_data[63:54] != '0) begin
      flt = 1'b1;                                  // reserved, PBMT, N (no Svpbmt / Svnapot)
    end else if (nonleaf) begin
      flt = pd || pa || pu || lvl_q == 2'd0;
    end else begin
      if (pu ? (mode_q == PRIV_S && (acc_q == ACC_X || !sum[wt])) : mode_q != PRIV_S) flt = 1'b1;
      if (!pv || (pw && !pr)) flt = 1'b1;
      if ((lvl_q == 2'd2 && ppn[17:0] != '0) || (lvl_q == 2'd1 && ppn[8:0] != '0)) flt = 1'b1;
      unique case (acc_q)
        ACC_X:   if (!px) flt = 1'b1;
        ACC_R:   if (!pr && !(mxr[wt] && px)) flt = 1'b1;
        default: if (!pw) flt = 1'b1;
      endcase
      if (!pa || (acc_q == ACC_W && !pd)) flt = 1'b1;   // Svade
    end
  end

  function automatic logic [3:0] pf_cause(input acc_e a);
    return (a == ACC_X) ? EXC_IPAGE : (a == ACC_R) ? EXC_LPAGE : EXC_SPAGE;
  endfunction
  function automatic logic [3:0] af_cause(input acc_e a);
    return (a == ACC_X) ? EXC_IACCESS : (a == ACC_R) ? EXC_LACCESS : EXC_SACCESS;
  endfunction

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      st_q <= W_IDLE;
    end else begin
      unique case (st_q)
        // The request's fields load in every idle cycle (nothing reads them before a walk starts:
        // the shared PMP checker's answer is used only in W_CHK and W_PMP), so only who_q and
        // st_q wait for the arbitration, which follows the ROB head's late DTLB check
        W_IDLE: begin
          va_q   <= req_va[k];
          acc_q  <= req_acc[k];
          mode_q <= req_mode[k];
          tid_q  <= req_tid[k];
          lvl_q  <= 2'd2;
          base_q <= satp_ppn[rt];
          if (|ack) begin
            who_q <= ack;
            st_q  <= W_CHK;
          end
        end
        W_CHK: begin
          if (!va_canon(va_q)) begin
            ok_q <= 1'b0; cause_q <= pf_cause(acc_q); st_q <= W_DONE;
          end else if (chk_gnt && !pa_ok) begin
            ok_q <= 1'b0; cause_q <= af_cause(acc_q); st_q <= W_DONE;
          end else if (chk_gnt) begin
            st_q <= W_REQ;
          end
        end
        W_REQ: if (pt_gnt) st_q <= W_WAIT;
        W_WAIT: if (pt_rsp) begin
          if (pt_hit) begin
            if (flt) begin
              ok_q <= 1'b0; cause_q <= pf_cause(acc_q); st_q <= W_DONE;
            end else if (nonleaf) begin
              base_q <= ppn;
              lvl_q  <= lvl_q - 1'b1;
              st_q   <= W_CHK;
            end else begin
              ok_q   <= 1'b1;
              leaf_q <= '{ppn: ppn[PPN_W-1:0], big: ppn[43:PPN_W] != '0, g: pg, d: pd, a: pa, u: pu,
                          x: px, w: pw, r: pr, ph: 1'b0, pr: 1'b0, pw: 1'b0, px: 1'b0};
              st_q   <= W_PMP;
            end
          end else if (pt_den) begin
            ok_q <= 1'b0; cause_q <= af_cause(acc_q); st_q <= W_DONE;
          end else begin
            st_q <= W_MISS;
          end
        end
        W_MISS: if (mshr_idle) st_q <= W_REQ;
        W_PMP: if (chk_gnt) begin                  // the page's PMP result, for S and U
          leaf_q.ph <= ((lvl_q == 2'd1) ? !leaf_nh : pmp_al[wt][lvl_q]) && !leaf_q.big;
          {leaf_q.pr, leaf_q.pw, leaf_q.px} <= chk_hit ? chk_rwx : 3'b000;
          st_q <= W_DONE;
        end
        default: st_q <= W_IDLE;                   // W_DONE
      endcase
    end
  end

  // The request in the next cycle: a new walk with a canonical VA, a check still waiting for the
  // port, or a PTE read whose result enters W_CHK (the VA passed its check) or W_PMP. The address:
  // the first PTE's, else the next level's PTE or the leaf page's base, from the read's PTE
  logic [2:0] req_cn;
  always_comb for (int i = 0; i < 3; i++) req_cn[i] = va_canon(req_va[i]);
  always_ff @(posedge clk) begin
    if (rst || flush) begin
      chk_req_q <= 1'b0;
    end else begin
      unique case (st_q)
        W_IDLE:  chk_req_q <= |(ack & req_cn);
        W_CHK:   chk_req_q <= chk_req_q && !chk_gnt;
        W_WAIT:  chk_req_q <= pt_rsp && pt_hit && !flt;
        W_PMP:   chk_req_q <= !chk_gnt;
        default: chk_req_q <= 1'b0;
      endcase
    end
    if (st_q == W_IDLE)
      chk_pa_q <= PA_W'({satp_ppn[rt], req_va[k][38:30], 3'b000});
    else if (st_q == W_WAIT)
      chk_pa_q <= nonleaf ? PA_W'({ppn, (lvl_q == 2'd2) ? va_q[29:21] : va_q[20:12], 3'b000})
                          : PA_W'({ppn, 12'b0});
  end
`ifndef SYNTHESIS
  logic rs_q;                     // the core has been reset: the check waits for it (tg_rob)
  initial rs_q = 1'b0;
  always @(posedge clk) if (rst) rs_q <= 1'b1;
  always_ff @(posedge clk) begin
    if (rs_q && !rst)
      assert (chk_req_q == ((st_q == W_CHK && va_canon(va_q)) || st_q == W_PMP) &&
              (!chk_req_q || chk_pa_q == ((st_q == W_PMP) ? {leaf_q.ppn, 12'b0} : pte_pa[PA_W-1:0])))
        else $error("tg_ptw: the registered check request or address differs from the walk's state");
  end
`endif

  assign done       = st_q == W_DONE && !flush;
  assign done_who   = who_q;
  assign done_tid   = wt;
  assign chk_tid    = wt;
  assign done_ok    = ok_q;
  assign done_cause = cause_q;
  assign fill_vpn   = va_q[38:12];
  assign fill_lvl   = lvl_q;
  assign fill_pte   = leaf_q;

  logic unused;
  assign unused = ^{pt_data[9:8], pte_pa[2:0]};
endmodule
