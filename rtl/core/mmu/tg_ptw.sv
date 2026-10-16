// Sv39 page-table walker (docs/spec/core-mmu.md): one walk at a time, for the ROB head's
// deciding walk (requester 0), an ITLB miss (1) or a DTLB prefetch (2), in that priority.
// PTE reads go through the load pipe (pt_req until pt_gnt; the result comes back at M2); a
// missing line waits for the MSHR like a load. The checks follow Spike's walk(): the PTE
// address must be PMA_MEM below PA_W and allowed by PMP in S (else an access fault); then
// reserved bits, non-leaf flags, the U rule, invalid encodings, superpage alignment, the
// access permission and Svade's A/D (each a page fault). A success returns the leaf for the
// requester's TLB, with the page's PMP result cached (plan §4.10): one more cycle checks the
// page base, and the result holds for the whole page when no active PMP region boundary lies
// strictly inside the page (checked here against every entry). A flush ends the walk; its PTE
// read, if any, dies in the load pipe.
// The PMP checks (the PTE address, the page base) use the STA port's checker in a cycle the
// port leaves it free (chk_gnt); W_CHK and W_PMP wait for one, and say so (chk_req).
module tg_ptw
  import tg_pkg::*, tg_map_pkg::*, tg_core_pkg::*;
(
  input  logic              clk,
  input  logic              rst,
  input  logic              flush,
  input  logic [43:0]       satp_ppn,
  input  logic              sum,
  input  logic              mxr,
  input  pmp_d_t [15:0]     pmp_d,
  input  logic [15:0][2:0]  pmp_pal,      // each entry's address is aligned to a 1G / 2M / 4K page
  // PMP checks on a shared checker (S mode, ACC_R)
  output logic [PA_W-1:0]   chk_pa,
  output logic              chk_dbl,      // an 8-byte access (the PTE), else one granule
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
  output logic              done_ok,      // fill_* hold the leaf
  output logic [3:0]        done_cause,   // else the fault
  output logic [26:0]       fill_vpn,
  output logic [1:0]        fill_lvl,
  output tlb_pte_t          fill_pte
);
  typedef enum logic [2:0] { W_IDLE, W_CHK, W_REQ, W_WAIT, W_MISS, W_PMP, W_DONE } wstate_e;
  wstate_e     st_q;
  logic [2:0]  who_q;
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
  assign k = ack[0] ? 2'd0 : ack[1] ? 2'd1 : 2'd2;

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
  // The checks: the PTE address (8 bytes), or in W_PMP the leaf page's base
  logic pa_ok;
  assign chk_pa  = (st_q == W_PMP) ? {leaf_q.ppn, 12'b0} : pte_pa[PA_W-1:0];
  assign chk_dbl = st_q != W_PMP;
  assign chk_req = (st_q == W_CHK && va_canon(va_q)) || st_q == W_PMP;
  assign pa_ok   = pte_pa[55:PA_W] == '0 && pma_of(pte_pa[PA_W-1:0]) == PMA_MEM && chk_ok;
  assign pt_req = st_q == W_REQ;
  // The leaf page is PMP-homogeneous when no active region boundary lies strictly inside it: no
  // NAPOT region smaller than the page within it, and no TOR bound (an entry's address that tops
  // its TOR range or bottoms the next entry's) unaligned to the page within it
  logic leaf_nh;
  always_comb begin
    logic [PMP_GW-1:0] pg, km;
    logic              in_pg, sub_pg, bound;
    pg = PMP_GW'({leaf_q.ppn, 10'b0});            // the page base in 4-byte granules
    unique case (lvl_q)
      2'd2:    km = ~PMP_GW'((64'd1 << 28) - 1);
      2'd1:    km = ~PMP_GW'((64'd1 << 19) - 1);
      default: km = ~PMP_GW'((64'd1 << 10) - 1);
    endcase
    leaf_nh = 1'b0;
    for (int i = 0; i < 16; i++) begin
      in_pg = ((pmp_d[i].a ^ pg) & km) == '0;
      sub_pg = pmp_d[i].nap && !pmp_d[i].above &&
              ((lvl_q == 2'd2) ? pmp_d[i].mask[27] : (lvl_q == 2'd1) ? pmp_d[i].mask[18] : pmp_d[i].mask[9]);
      bound = (pmp_d[i].tor || (i < 15 && pmp_d[(i + 1) % 16].tor)) && !pmp_pal[i][lvl_q];
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
      if (pu ? (mode_q == PRIV_S && (acc_q == ACC_X || !sum)) : mode_q != PRIV_S) flt = 1'b1;
      if (!pv || (pw && !pr)) flt = 1'b1;
      if ((lvl_q == 2'd2 && ppn[17:0] != '0) || (lvl_q == 2'd1 && ppn[8:0] != '0)) flt = 1'b1;
      unique case (acc_q)
        ACC_X:   if (!px) flt = 1'b1;
        ACC_R:   if (!pr && !(mxr && px)) flt = 1'b1;
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
          lvl_q  <= 2'd2;
          base_q <= satp_ppn;
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
          leaf_q.ph <= !leaf_nh && !leaf_q.big;
          {leaf_q.pr, leaf_q.pw, leaf_q.px} <= chk_hit ? chk_rwx : 3'b000;
          st_q <= W_DONE;
        end
        default: st_q <= W_IDLE;                   // W_DONE
      endcase
    end
  end

  assign done       = st_q == W_DONE && !flush;
  assign done_who   = who_q;
  assign done_ok    = ok_q;
  assign done_cause = cause_q;
  assign fill_vpn   = va_q[38:12];
  assign fill_lvl   = lvl_q;
  assign fill_pte   = leaf_q;

  logic unused;
  assign unused = ^{pt_data[9:8], pte_pa[2:0]};
endmodule
