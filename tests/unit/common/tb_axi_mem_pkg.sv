// Shared test helpers: the initial contents of the behavioural memories (tb_axi_mem), so reference
// models can predict reads of memory nobody wrote.
package tb_axi_mem_pkg;
  function automatic logic [127:0] init_beat(input longint unsigned ba);
    logic [31:0] b;
    b = ba[31:0];
    return {b ^ 32'hA5A5_0000, ~b, b * 32'h9E37_79B9, b + 32'h1234_5678};
  endfunction

  function automatic logic [511:0] init_line(input longint unsigned line);
    logic [511:0] r;
    for (int k = 0; k < 4; k++) r[128*k +: 128] = init_beat(line * 4 + longint'(k));
    return r;
  endfunction
endpackage
