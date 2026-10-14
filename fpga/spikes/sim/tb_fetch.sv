// Random test of the S5 IF2/IF3 path: tg_predecode and tg_fetch_compact.
//   Vtb_fetch +seed=<n> +blocks=<n> ; parameter WR (queue write width)
// A random stream of RVC and 32-bit instructions is laid out in 16-byte fetch blocks the way
// the front end would fetch them: sequential blocks (32-bit instructions straddle block
// ends), and predicted-taken branches that end a block early and continue at a random
// halfword of a new block. Decode takes 0..DECODE_WIDTH instructions per cycle. The queue
// output must be the stream, in order, with the right encodings and parcel offsets.
module tb_fetch
  import tg_pkg::*;
#(
  parameter int WR = 4
);
  localparam int NP = FETCH_BYTES / 2;
  localparam int SW = idx_w(NP);
  localparam int RD = DECODE_WIDTH;
  localparam int META_W = 8;
  localparam int IB_W = 32 + 1 + SW + 3 + META_W;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  int errors = 0, seed = 1, nblocks = 3000;

  // DUT: predecode -> (register) -> compact
  logic [NP-1:0][15:0] parcel;
  logic [SW-1:0] entry, exitp;
  logic carry_in;
  logic [NP-1:0] start, is32, is_br, is_jal, is_jalr, is_call, is_ret;
  logic carry_out;
  tg_predecode u_pd (.parcel, .entry_slot(entry), .exit_slot(exitp), .carry_in, .start, .is32,
                     .is_br, .is_jal, .is_jalr, .is_call, .is_ret, .carry_out);

  logic blk_valid, blk_ready;
  logic [NP-1:0][15:0] q_parcel;
  logic [NP-1:0] q_start;
  logic [NP-1:0][2:0] q_marks;
  logic q_carry;
  logic [META_W-1:0] q_meta;
  logic [RD-1:0] out_valid;
  logic [RD-1:0][IB_W-1:0] out_insn;
  logic [idx_w(RD + 1)-1:0] take;
  tg_fetch_compact #(.WR(WR), .RD(RD), .DEPTH(IBUF_ENTRIES), .META_W(META_W)) u_cmp (
    .clk, .rst, .flush(1'b0), .blk_valid, .parcel(q_parcel), .start(q_start), .marks(q_marks),
    .carry_out(q_carry), .meta(q_meta), .blk_ready, .out_valid, .out_insn, .take);

  // ---- Reference stream ----
  typedef struct { logic [31:0] bits; bit rvc; int slot; } ins_t;
  ins_t expq [$];          // instructions expected out of the queue, in order
  typedef struct { logic [NP-1:0][15:0] p; int entry, exitp; bit seq; } blk_t;
  blk_t blks [$];

  function automatic logic [31:0] rand_insn(input bit rvc);
    logic [31:0] v = $urandom;
    if (rvc) begin
      v[31:16] = 16'h0;
      if (v[1:0] == 2'b11) v[1:0] = 2'b01;
    end else v[1:0] = 2'b11;
    return v;
  endfunction

  // Build the blocks and the expected instruction list
  task automatic gen();
    int slot = 0;                // next free parcel of the block being built
    blk_t b;
    logic [15:0] pend_hi;        // second half of a straddling instruction
    bit have_pend = 0;
    b.p = '0; b.entry = 0; b.seq = 0;
    for (int n = 0; n < nblocks; n++) begin
      bit ended = 0;
      if (have_pend) begin
        b.p[0] = pend_hi;
        slot = 1;
        have_pend = 0;
      end
      while (!ended) begin
        bit rvc = ($urandom % 2) == 0;
        ins_t i;
        i.bits = rand_insn(rvc);
        i.rvc = rvc;
        i.slot = slot;
        b.p[slot] = i.bits[15:0];
        if (!rvc) begin
          if (slot == NP - 1) begin
            // straddles into the next (sequential) block
            pend_hi = i.bits[31:16];
            have_pend = 1;
            expq.push_back(i);
            b.exitp = NP - 1;
            ended = 1;
            break;
          end
          b.p[slot + 1] = i.bits[31:16];
          slot += 2;
        end else slot += 1;
        expq.push_back(i);
        // a predicted-taken branch ends the block early, sometimes
        if (slot < NP && ($urandom % 6) == 0) begin
          b.exitp = slot - 1;
          ended = 1;
        end else if (slot >= NP) begin
          b.exitp = NP - 1;
          ended = 1;
        end
      end
      blks.push_back(b);
      // next block: sequential after a straddle or a full block, else a branch target
      if (have_pend || b.exitp == NP - 1) begin
        b.p = '0;
        b.entry = 0;
        b.seq = 1;
        slot = 0;
      end else begin
        b.p = '0;
        b.entry = $urandom % NP;
        b.seq = 0;
        slot = b.entry;
        for (int k = 0; k < b.entry; k++) b.p[k] = $urandom;   // junk before the entry
      end
    end
  endtask

  // ---- Drive blocks (IF2 registered into IF3 when IF3 takes the previous one) ----
  int bi = 0;
  logic carry_q;
  always @(negedge clk) begin
    load_q = 0;
    if (!rst && bi < blks.size()) begin
      parcel   = blks[bi].p;
      entry    = SW'(blks[bi].entry);
      exitp    = SW'(blks[bi].exitp);
      carry_in = blks[bi].seq && carry_q;
      load_q   = 1;
    end
    // decode takes a random number of the valid instructions
    begin
      automatic int nv = 0;
      for (int j = 0; j < RD; j++) if (out_valid[j]) nv = j + 1;
      take = idx_w(RD + 1)'($urandom % (nv + 1));
    end
  end
  logic load_q = 0;
  always @(posedge clk) begin
    if (rst) begin
      blk_valid <= 0;
      carry_q <= 0;
    end else begin
      if (blk_ready) blk_valid <= 0;
      if (load_q && (!blk_valid || blk_ready)) begin
        blk_valid <= 1;
        q_parcel  <= parcel;
        q_start   <= start;
        q_carry   <= carry_out;
        for (int p = 0; p < NP; p++) q_marks[p] <= {is_br[p], is_jal[p], is_jalr[p]};
        q_meta    <= META_W'(bi);
        carry_q   <= carry_out;
        bi++;
      end
    end
  end

  // ---- Check the queue output ----
  int nout = 0;
  always @(posedge clk) begin
    if (!rst) begin
      for (int j = 0; j < int'(take); j++) begin
        if (!out_valid[j]) begin errors++; $display("ERROR take of an invalid slot"); end
        else if (expq.size() == 0) begin errors++; $display("ERROR extra instruction out"); end
        else begin
          automatic ins_t e = expq.pop_front();
          automatic logic [31:0] got = out_insn[j][31:0];
          automatic logic got_rvc = out_insn[j][32];
          automatic logic [SW-1:0] got_slot = out_insn[j][33 +: SW];
          if (got_rvc != e.rvc || (e.rvc ? got[15:0] != e.bits[15:0] : got != e.bits)
              || (got_slot != SW'(e.slot) && !(e.slot == NP - 1 && !e.rvc))) begin
            errors++;
            if (errors < 10) $display("ERROR instruction %0d: got %h rvc %0d slot %0d, want %h rvc %0d slot %0d",
                                      nout, got, got_rvc, got_slot, e.bits, e.rvc, e.slot);
          end
          nout++;
        end
      end
    end
  end

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("blocks=%d", nblocks));
    void'($urandom(seed));
    gen();
    $display("tb_fetch: WR %0d RD %0d, %0d blocks, %0d instructions, seed %0d", WR, RD,
             blks.size(), expq.size(), seed);
    blk_valid = 0;
    repeat (4) @(posedge clk);
    @(negedge clk) rst = 0;
    repeat (nblocks * 8) @(posedge clk);
    if (expq.size() != 0) begin errors++; $display("ERROR %0d instructions never came out", expq.size()); end
    if (errors == 0) $display("PASS tb_fetch (%0d instructions)", nout);
    else $display("FAIL tb_fetch: %0d errors", errors);
    $finish;
  end
endmodule
