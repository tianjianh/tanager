// Random test of tg_cam_lut against a reference (key and valid per entry), with the
// documented timing: a write is accepted, the entry stops matching at the end of that cycle,
// and it matches its new key from the cycle after the third; invalidate and flush act at the
// next edge, except that a write's last cycle wins for its own entry.
// Keys come from a small pool, with single slices changed, so entries share slice values and
// a write must clear only its own entry's bits. Resets happen mid-run (the sweep must clear
// every table). lk_match, lk_hit and lk_idx are checked whenever lk_valid is high.
//   Vtb_cam_lut +seed=<n> +cycles=<n> ; parameters ENTRIES, KEYW, SLICE, RMW_PORT
module tb_cam_lut #(
  parameter int ENTRIES  = 32,
  parameter int KEYW     = 32,
  parameter     PRIM     = "m16",
  parameter int SLICE    = 5,
  parameter bit RMW_PORT = 1'b1
);
  localparam int IW = $clog2(ENTRIES);
  localparam int NS = (KEYW + SLICE - 1) / SLICE;
  localparam bit SW = PRIM == "sw";
  localparam int SWEEP = SW ? ENTRIES : (1 << SLICE);   // reset sweep cycles

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic               rst, ready, lk_hit, lk_valid, wr_valid, wr_ready, inv, flush;
  logic [KEYW-1:0]    lk_key, wr_key;
  logic [ENTRIES-1:0] lk_match;
  logic [IW-1:0]      lk_idx, wr_idx, inv_idx;
  tg_cam_lut #(.ENTRIES(ENTRIES), .KEYW(KEYW), .PRIM(PRIM), .SLICE(SLICE), .RMW_PORT(RMW_PORT)) dut (.*);

  // reference
  logic [KEYW-1:0]    rkey [ENTRIES];
  logic [ENTRIES-1:0] rvalid;
  int                 pend = 0;          // cycles until the pending write completes (0: none)
  logic [IW-1:0]      pidx;
  logic [KEYW-1:0]    pkey;

  logic [KEYW-1:0] pool [16];
  function automatic logic [KEYW-1:0] pick_key();
    logic [KEYW-1:0] k;
    k = pool[$urandom % 16];
    if ($urandom % 3 == 0) begin        // change one slice
      automatic int s = $urandom % NS;
      for (int i = 0; i < SLICE; i++) begin
        if (s * SLICE + i < KEYW) k[s * SLICE + i] = 1'($urandom);
      end
    end
    return k;
  endfunction

  int seed = 1, cycles = 20000, errors = 0, nchk = 0, nhit = 0, nmulti = 0, nwr = 0, nrst = 0;
  int since_rst = 0;
  logic [ENTRIES-1:0] want;

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    void'($urandom(seed));
    for (int i = 0; i < 16; i++) pool[i] = KEYW'({$urandom, $urandom});
    rst = 1'b1; wr_valid = 1'b0; inv = 1'b0; flush = 1'b0;
    lk_key = '0; wr_key = '0; wr_idx = '0; inv_idx = '0;
    @(posedge clk);                    // the first reset
    rvalid = '0; pend = 0; since_rst = 1;
    for (int c = 0; c < cycles; c++) begin
      @(negedge clk);
      // ---- check the combinational outputs of this cycle ----
      if (since_rst > 0) begin
        if (ready != (since_rst > SWEEP)) begin
          errors++;
          if (errors < 10) $display("ERROR cycle %0d: ready %b, %0d cycles after reset", c, ready, since_rst);
        end
        if (ready && lk_valid != ((RMW_PORT && !SW) || !(pend == 1 || pend == 2))) begin
          errors++;
          if (errors < 10) $display("ERROR cycle %0d: lk_valid %b (write stage %0d)", c, lk_valid, pend);
        end
        if (lk_valid) begin
          for (int e = 0; e < ENTRIES; e++) want[e] = rvalid[e] && rkey[e] == lk_key;
          nchk++;
          if (lk_match !== want || lk_hit !== |want ||
              ($countones(want) == 1 && lk_idx !== IW'($clog2(want)))) begin
            errors++;
            if (errors < 10) $display("ERROR cycle %0d: key %h match %h want %h hit %b idx %0d",
                                      c, lk_key, lk_match, want, lk_hit, lk_idx);
          end
          if (|want) nhit++;
          if ($countones(want) > 1) nmulti++;
        end
      end
      // ---- drive the next cycle ----
      rst = ($urandom % 4000) == 0 || c == cycles / 2;   // at least one mid-run reset
      lk_key   = ($urandom % 8) ? pick_key() : KEYW'({$urandom, $urandom});
      wr_valid = ($urandom % 3) == 0;
      wr_idx   = IW'($urandom % ENTRIES);
      wr_key   = pick_key();
      inv      = ($urandom % 8) == 0;
      inv_idx  = IW'($urandom % ENTRIES);
      flush    = ($urandom % 300) == 0;
      // ---- reference update at the coming edge (wr_ready and the control are settled) ----
      #1;
      @(posedge clk);
      if (rst) begin
        rvalid = '0; pend = 0; since_rst = 1; nrst++;
      end else begin
        if (since_rst > 0) since_rst++;
        if (flush) rvalid = '0;
        else if (inv) rvalid[inv_idx] = 1'b0;
        if (pend == 1) begin           // the write's last cycle wins for its entry
          rkey[pidx] = pkey; rvalid[pidx] = 1'b1;
        end
        if (pend > 0) pend--;
        if (wr_valid && wr_ready) begin
          rvalid[wr_idx] = 1'b0; pidx = wr_idx; pkey = wr_key; pend = 3; nwr++;
        end
        if (pend == 3) pend = 2;      // the accept cycle has passed
      end
    end
    if (nhit < cycles / 100 || nmulti == 0 || nrst == 0) begin
      errors++;
      $display("ERROR poor coverage: %0d hits, %0d multiple hits, %0d resets", nhit, nmulti, nrst);
    end
    if (errors == 0) $display("PASS tb_cam_lut %s ENTRIES %0d KEYW %0d SLICE %0d RMW_PORT %0d (%0d lookups checked, %0d hits, %0d multi, %0d writes, %0d resets)",
                              PRIM, ENTRIES, KEYW, SLICE, RMW_PORT, nchk, nhit, nmulti, nwr, nrst);
    else $display("FAIL tb_cam_lut: %0d errors", errors);
    $finish;
  end
endmodule
