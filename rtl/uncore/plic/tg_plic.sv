// PLIC, riscv,plic0 (docs/spec/uncore-periph.md): priorities at 4s, pending at 0x1000,
// enables at 0x2000 + 0x80c, threshold at 0x200000 + 0x1000c, claim/complete at +4.
// Context 2h is hart h's M-mode, 2h+1 its S-mode. Level gateways, or edge for EDGE_SRC sources.
// Release builds (DR-180) take S_ONLY and PRIO_W = 1: the M-mode contexts hold nothing (their enables and
// threshold read 0 and ignore writes, a claim there reads 0, their outputs stay 0), and priorities and
// thresholds are one bit (WARL: a write keeps bit 0). OpenSBI takes no external interrupt, and Linux writes
// priority 1 alone.
module tg_plic
  import tg_pkg::*, tg_uncore_pkg::*;
#(
  parameter int              N_SRC    = PLIC_NSRC,   // sources 1 .. N_SRC-1; <= 32
  parameter int              N_CTX    = 2 * NUM_HARTS,
  parameter int              PRIO_W   = 3,
  parameter logic [N_SRC-1:0] EDGE_SRC = '0,
  parameter bit              S_ONLY   = 1'b0           // the S-mode contexts alone (2h+1)
) (
  input  logic             clk,
  input  logic             rst,
  input  dev_req_t         req_i,
  input  logic             req_valid_i,
  output dev_rsp_t         rsp_o,
  input  logic [N_SRC-1:0] src_i,     // bit 0 unused
  output logic [N_CTX-1:0] irq_o
);
  localparam int SW = idx_w(N_SRC);
  localparam logic [N_CTX-1:0] CTX_LIVE = S_ONLY ? N_CTX'({N_CTX{2'b10}}) : '1;   // the contexts built

  logic [N_SRC-1:0][PRIO_W-1:0] prio_q;
  logic [N_SRC-1:0]             pend_q, busy_q, src_q;
  logic [N_CTX-1:0][N_SRC-1:0]  en_q;
  logic [N_CTX-1:0][PRIO_W-1:0] thr_q;

  wire [25:0] off = req_i.addr[25:0];
  wire        wr  = req_valid_i && req_i.we;
  wire        rd  = req_valid_i && !req_i.we;

  // Best pending, enabled source above threshold for a context (ties: lowest ID).
  function automatic logic [SW-1:0] best_of(input int c,
      input logic [N_SRC-1:0] pend, input logic [N_CTX-1:0][N_SRC-1:0] en,
      input logic [N_SRC-1:0][PRIO_W-1:0] pr, input logic [N_CTX-1:0][PRIO_W-1:0] thr);
    logic [SW-1:0]     id;
    logic [PRIO_W-1:0] p;
    id = '0;
    p  = thr[c];
    for (int s = N_SRC - 1; s >= 1; s--)
      if (pend[s] && en[c][s] && pr[s] > thr[c] && pr[s] >= p) begin
        id = SW'(s);
        p  = pr[s];
      end
    return id;
  endfunction

  // The context a register access addresses
  wire [13:0] en_ctx   = 14'(off[20:7] - 14'h40);          // (off - 0x2000) / 0x80
  wire        en_area  = off[25:21] == 5'd0 && off >= 26'h2000 && off < 26'h1F_0000;
  wire        ctx_area = off >= 26'h20_0000;
  wire [13:0] cx       = 14'(off[25:12] - 14'h200);        // (off - 0x200000) / 0x1000
  wire        ctx_ok   = int'(cx) < N_CTX;
  wire        enc_ok   = int'(en_ctx) < N_CTX;

  logic [SW-1:0] claim_id;
  always_comb begin
    claim_id = '0;
    for (int c = 0; c < N_CTX; c++)
      if (int'(cx) == c && CTX_LIVE[c]) claim_id = best_of(c, pend_q, en_q, prio_q, thr_q);
  end

  wire claim    = rd && ctx_area && ctx_ok && off[11:2] == 10'd1;
  wire complete = wr && ctx_area && ctx_ok && off[11:2] == 10'd1 && req_i.be[4];
  wire [SW-1:0] cpl_id = req_i.wdata[32 +: SW];
  logic cpl_en;
  always_comb begin
    cpl_en = 1'b0;
    for (int c = 0; c < N_CTX; c++)
      if (int'(cx) == c && CTX_LIVE[c] && int'(cpl_id) < N_SRC && en_q[c][cpl_id]) cpl_en = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      prio_q <= '0;
      pend_q <= '0;
      busy_q <= '0;
      src_q  <= '0;
      en_q   <= '0;
      thr_q  <= '0;
    end else begin
      src_q <= src_i;
      // Gateways
      for (int s = 1; s < N_SRC; s++) begin
        logic req;
        req = EDGE_SRC[s] ? (src_i[s] && !src_q[s]) : src_i[s];
        if (req && !busy_q[s]) pend_q[s] <= 1'b1;
      end
      if (claim && claim_id != '0) begin
        pend_q[claim_id] <= 1'b0;
        busy_q[claim_id] <= 1'b1;
      end
      if (complete && cpl_en && cpl_id != '0) busy_q[cpl_id] <= 1'b0;
      // Register writes
      if (wr && off < 26'h1000) begin
        for (int s = 1; s < N_SRC; s++)
          if (off[11:3] == 9'(s / 2) && req_i.be[4 * (s % 2)])
            prio_q[s] <= req_i.wdata[32 * (s % 2) +: PRIO_W];
      end
      if (wr && en_area && enc_ok && off[6:3] == 4'd0) begin
        for (int c = 0; c < N_CTX; c++)
          if (int'(en_ctx) == c && CTX_LIVE[c])
            for (int s = 1; s < N_SRC; s++)
              if (req_i.be[s / 8]) en_q[c][s] <= req_i.wdata[s];
      end
      if (wr && ctx_area && ctx_ok && off[11:3] == 9'd0 && req_i.be[0]) begin
        for (int c = 0; c < N_CTX; c++)
          if (int'(cx) == c && CTX_LIVE[c]) thr_q[c] <= req_i.wdata[PRIO_W-1:0];
      end
    end
  end

  // Read data (registered)
  logic [63:0] rdat;
  always_comb begin
    rdat = '0;
    if (off < 26'h1000) begin
      for (int s = 1; s < N_SRC; s++)
        if (off[11:3] == 9'(s / 2)) rdat[32 * (s % 2) +: PRIO_W] = prio_q[s];
    end else if (off[25:3] == 23'h200) begin                       // 0x1000: pending 0..31
      rdat[N_SRC-1:0] = pend_q;
    end else if (en_area && enc_ok && off[6:3] == 4'd0) begin
      for (int c = 0; c < N_CTX; c++)
        if (int'(en_ctx) == c && CTX_LIVE[c]) rdat[N_SRC-1:0] = en_q[c] & ~N_SRC'(1);
    end else if (ctx_area && ctx_ok && off[11:3] == 9'd0) begin
      for (int c = 0; c < N_CTX; c++)
        if (int'(cx) == c && CTX_LIVE[c]) rdat[PRIO_W-1:0] = thr_q[c];
      if (off[2]) rdat[32 +: SW] = claim_id;              // the claim word itself
    end
  end

  always_ff @(posedge clk) begin
    rsp_o.rdata <= rdat;
    rsp_o.err   <= 1'b0;
  end

  // Interrupt outputs
  always_ff @(posedge clk) begin
    if (rst) irq_o <= '0;
    else for (int c = 0; c < N_CTX; c++) irq_o[c] <= CTX_LIVE[c] && best_of(c, pend_q, en_q, prio_q, thr_q) != '0;
  end

  wire unused = ^{req_i.addr[PA_W-1:26], req_i.size, src_i[0]};
endmodule
