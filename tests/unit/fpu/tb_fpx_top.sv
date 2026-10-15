// Test wrapper around tg_fp_exec (tests/unit/fpu/tb_fpx.cpp; docs/spec/fpu.md, "Core
// integration"): flattens the payload and record structs into plain ports for the C++ bench.
module tb_fpx_top
  import tg_pkg::*, tg_core_pkg::*, tg_fpu_pkg::*, tg_fpcore_pkg::*;
#(
  parameter bit  DIV_RADIX4 = FDIV_RADIX4,
  localparam int PW = $bits(preg_t)
) (
  input  logic                    clk,
  input  logic                    rst,
  input  logic                    flush,
  input  logic [TID_BITS-1:0]     flush_tid,
  input  logic                    init_we,
  input  logic                    init_bank,
  input  logic [FPIDX_W-1:0]      init_idx,
  input  logic                    iss_valid,
  input  logic [TID_BITS-1:0]     iss_tid,
  input  logic [ROBW-1:0]         iss_rob,
  input  logic [COL_W-1:0]        iss_wid,
  input  logic [LLT_IDX_W-1:0]    iss_llt,
  input  logic                    iss_dst_en,
  input  logic [PW-1:0]           iss_dst,
  input  logic [PW-1:0]           iss_src1,
  input  logic [PW-1:0]           iss_src2,
  input  logic [PW-1:0]           iss_src3,
  input  logic                    iss_src1_fp,
  input  logic [4:0]              iss_fop,
  input  logic [1:0]              iss_fmt,
  input  logic [1:0]              iss_src_fmt,
  input  logic [1:0]              iss_ifmt,
  input  logic [2:0]              iss_rm,
  input  logic                    iss_fp_int,
  input  logic                    iss_fp_div,
  output logic                    fmisc_block,
  output logic                    isrc_valid,
  output logic [PW-1:0]           isrc_tag,
  input  logic [63:0]             isrc_data,
  input  logic                    fld_m2_will,
  input  logic [FPIDX_W-1:0]      fld_m2_idx,
  input  logic                    fld_valid,
  input  logic [FPIDX_W-1:0]      fld_idx,
  input  logic [63:0]             fld_data,
  input  logic [PW-1:0]           fsd_tag,
  output logic [63:0]             fsd_data,
  input  logic [PW-1:0]           tr_tag,
  output logic [63:0]             tr_data,
  output logic                    f0_we_o,
  output logic [FPIDX_W-1:0]      f0_widx_o,
  output logic [NCOL-1:0]         wake_reg,
  output logic [LLT_ENTRIES-1:0]  llt_done,
  output logic                    cmp_valid,
  output logic [TID_BITS-1:0]     cmp_tid,
  output logic [ROBW-1:0]         cmp_rob,
  output logic [COL_W-1:0]        cmp_wid,
  output logic [4:0]              cmp_fflags,
  output logic                    fpi_valid,
  input  logic                    fpi_ready,
  output logic [TID_BITS-1:0]     fpi_tid,
  output logic [ROBW-1:0]         fpi_rob,
  output logic [COL_W-1:0]        fpi_wid,
  output logic [LLT_IDX_W-1:0]    fpi_llt,
  output logic                    fpi_dst_en,
  output logic [PW-1:0]           fpi_dst,
  output logic [63:0]             fpi_data,
  output logic [4:0]              fpi_fflags,
  output logic                    fpi_kill,
  output logic                    fpi_pop,
  output logic                    fdiv_done,
  input  logic                    fdiv_ret_valid,
  input  logic [TID_BITS-1:0]     fdiv_ret_tid,
  input  logic [LLT_IDX_W-1:0]    fdiv_ret_llt,
  output logic                    er_valid,
  output logic [TID_BITS-1:0]     er_tid,
  output logic [4:0]              er_fflags,
  output logic [15:0]             nfx_o       // fixed-latency (tag) wakeup columns
);
  assign nfx_o = 16'(NCOL - LLT_ENTRIES);
  fp_iss_t pl;
  always_comb begin
    pl.tid     = iss_tid;
    pl.rob     = iss_rob;
    pl.wid     = iss_wid;
    pl.llt     = iss_llt;
    pl.dst_en  = iss_dst_en;
    pl.dst     = iss_dst;
    pl.src1    = iss_src1;
    pl.src2    = iss_src2;
    pl.src3    = iss_src3;
    pl.src1_fp = iss_src1_fp;
    pl.fop     = fop_e'(iss_fop);
    pl.fmt     = ffmt_e'(iss_fmt);
    pl.src_fmt = ffmt_e'(iss_src_fmt);
    pl.ifmt    = ifmt_e'(iss_ifmt);
    pl.rm      = rm_e'(iss_rm);
    pl.fp_int  = iss_fp_int;
    pl.fp_div  = iss_fp_div;
  end
  fpi_t fpi;
  assign fpi_tid    = fpi.tid;
  assign fpi_rob    = fpi.rob;
  assign fpi_wid    = fpi.wid;
  assign fpi_llt    = fpi.llt;
  assign fpi_dst_en = fpi.dst_en;
  assign fpi_dst    = fpi.dst;
  assign fpi_data   = fpi.data;
  assign fpi_fflags = fpi.fflags;

  tg_fp_exec #(.NTR(1), .DIV_RADIX4(DIV_RADIX4)) u_dut (
    .clk, .rst, .flush, .flush_tid, .init_we, .init_bank, .init_idx,
    .iss_valid, .iss_pl(pl), .fmisc_block,
    .isrc_valid, .isrc_tag, .isrc_data,
    .fld_m2_will, .fld_m2_idx, .fld_valid, .fld_idx, .fld_data,
    .fsd_tag, .fsd_data, .tr_tag(tr_tag), .tr_data(tr_data),
    .f0_we_o, .f0_widx_o, .wake_reg, .llt_done,
    .cmp_valid, .cmp_tid, .cmp_rob, .cmp_wid, .cmp_fflags,
    .fpi_valid, .fpi_ready, .fpi_o(fpi), .fpi_kill, .fpi_pop,
    .fdiv_done, .fdiv_ret_valid, .fdiv_ret_tid, .fdiv_ret_llt,
    .er_valid, .er_tid, .er_fflags);
endmodule
