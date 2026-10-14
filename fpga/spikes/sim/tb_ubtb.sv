// Random test of tg_ubtb (S5) against a reference model, for both organisations: FA = 0
// (2-way set associative LUTRAM, partial tags) and FA = 1 (fully associative flip-flops).
// Updates name the way (FA = 0) or the entry (FA = 1), as the training logic would.
//   Vtb_ubtb +seed=<n> +iters=<n> ; parameter FA
module tb_ubtb
  import tg_pkg::*;
#(
  parameter bit FA = 1'b0
);
  localparam int NE    = UBTB_ENTRIES;
  localparam int NFA   = 32;
  localparam int TAG_W = 12;
  localparam int SETS  = NE / 2;
  localparam int SET_W = idx_w(SETS);
  localparam int SLOT_W = idx_w(FETCH_BYTES / 2);
  localparam int UW    = FA ? idx_w(NFA) : 1;
  localparam int NREF  = FA ? NFA : NE;

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic [38:4] pc, upd_pc;
  tid_t tid, upd_tid;
  logic hit, upd_valid, upd_inval;
  logic [38:1] target, upd_target;
  logic [SLOT_W-1:0] br_slot, upd_slot;
  logic [UW-1:0] upd_way;
  tg_ubtb #(.FA(FA), .NE(NE), .NFA(NFA), .TAG_W(TAG_W)) dut (.*);

  // Reference: one record per physical entry (set * 2 + way, or the FA index)
  typedef struct { bit v; int tid; logic [38:4] pc; logic [38:1] tgt; int slot; } ent_t;
  ent_t re [NREF];

  function automatic int slot_of(input logic [38:4] a, input int way);
    return FA ? way : int'(a[4 +: SET_W]) * 2 + way;
  endfunction
  // Does entry e predict block a? FA compares the whole block address; FA = 0 the index
  // (implied by the set) and the partial tag.
  function automatic bit ent_hit(input ent_t e, input int t, input logic [38:4] a);
    if (!e.v || e.tid != t) return 0;
    if (FA) return e.pc == a;
    return e.pc[4 + SET_W +: TAG_W] == a[4 + SET_W +: TAG_W] && e.pc[4 +: SET_W] == a[4 +: SET_W];
  endfunction

  // Block addresses from a small pool, so lookups hit and partial tags alias sometimes
  logic [38:4] pool [64];
  int errors = 0, nhit = 0;

  initial begin
    int seed = 1, iters = 100000;
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("iters=%d", iters));
    void'($urandom(seed));
    for (int i = 0; i < 64; i++) pool[i] = {$urandom, $urandom};
    for (int i = 0; i < NREF; i++) re[i].v = 0;
    upd_valid = 0; upd_inval = 0;
    // FA = 0 keeps its valid bits in LUTRAM: invalidate every entry first, as the front end
    // does after reset
    repeat (2) @(posedge clk);
    @(negedge clk) rst = 0;
    if (!FA) begin
      for (int s = 0; s < SETS; s++) begin
        for (int w = 0; w < 2; w++) begin
          @(negedge clk);
          upd_valid = 1; upd_inval = 1; upd_way = UW'(w);
          upd_pc = '0; upd_pc[4 +: SET_W] = SET_W'(s); upd_tid = '0;
        end
      end
      @(negedge clk) upd_valid = 0; upd_inval = 0;
    end
    for (int i = 0; i < iters; i++) begin
      @(negedge clk);
      // check the lookup presented in the previous cycle against the model
      begin
        automatic int m = -1;
        automatic int nm = 0;
        for (int e = 0; e < NREF; e++)
          if ((FA || e / 2 == int'(pc[4 +: SET_W])) && ent_hit(re[e], int'(tid), pc)) begin
            nm++;
            if (m < 0) m = e;      // way 0 first, as the RTL prefers it
          end
        if (hit != (nm > 0)) begin
          errors++;
          if (errors < 10) $display("ERROR hit %b want %b pc %h", hit, nm > 0, pc);
        end else if (hit && (target != re[m].tgt || int'(br_slot) != re[m].slot)) begin
          errors++;
          if (errors < 10) $display("ERROR target %h want %h", target, re[m].tgt);
        end
        if (hit) nhit++;
      end
      // an update (install or remove), then a new lookup
      upd_valid = ($urandom % 3) == 0;
      upd_inval = ($urandom % 8) == 0;
      upd_pc = pool[$urandom % 64];
      upd_tid = tid_t'($urandom % NUM_THREADS);
      upd_target = {$urandom, $urandom};
      upd_slot = SLOT_W'($urandom);
      upd_way = UW'($urandom % (FA ? NFA : 2));
      if (upd_valid) begin
        automatic int e = slot_of(upd_pc, int'(upd_way));
        // FA: the training logic never installs a block twice
        automatic bit dup = 0;
        if (FA && !upd_inval)
          for (int k = 0; k < NFA; k++)
            if (k != e && ent_hit(re[k], int'(upd_tid), upd_pc)) dup = 1;
        if (dup) upd_valid = 0;
        else begin
          re[e].v = !upd_inval; re[e].tid = int'(upd_tid); re[e].pc = upd_pc;
          re[e].tgt = upd_target; re[e].slot = int'(upd_slot);
        end
      end
      pc = pool[$urandom % 64];
      tid = tid_t'($urandom % NUM_THREADS);
      @(posedge clk);
    end
    if (errors == 0) $display("PASS tb_ubtb FA=%0d (%0d lookups, %0d hits)", FA, iters, nhit);
    else $display("FAIL tb_ubtb FA=%0d: %0d errors", FA, errors);
    $finish;
  end
endmodule
