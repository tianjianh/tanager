// A behavioural JTAG TAP with two BSCANE2-style user chains (tests/unit/dbg; docs/spec/soc.md §9.6). The IEEE 1149.1
// state machine on TCK and TMS, a 6-bit IR with UltraScale's codes (IDCODE 0x09, USER3 0x22, USER4 0x23, BYPASS
// otherwise), and the outputs UG974 gives a BSCANE2: CAPTURE, SHIFT and UPDATE high in Capture-DR, Shift-DR and
// Update-DR, RESET in Test-Logic-Reset, SEL while the chain's USER instruction is in IR, TDI as it comes. The user
// logic acts on TCK's rising edge, as on the device. TDO here is combinational from the selected register.
module tb_jtag_tap
  import tg_uncore_pkg::*;
(
  input  logic       tck,
  input  logic       tms,
  input  logic       tdi,
  output logic       tdo,
  output jtag_t      jtag_o,           // to tg_dtm
  input  logic [1:0] user_tdo_i        // [0] USER3's TDO, [1] USER4's
);
  typedef enum logic [3:0] {
    TLR, RTI, SEL_DR, CAP_DR, SH_DR, EX1_DR, PAU_DR, EX2_DR, UPD_DR,
    SEL_IR, CAP_IR, SH_IR, EX1_IR, PAU_IR, EX2_IR, UPD_IR
  } st_e;
  localparam logic [5:0] IR_IDCODE = 6'h09, IR_USER3 = 6'h22, IR_USER4 = 6'h23;
  localparam logic [31:0] IDCODE = 32'h1474_6093;     // any value with bit 0 set

  st_e        st = TLR;
  logic [5:0] ir = IR_IDCODE, ir_sr = '0;
  logic [31:0] id_sr = '0;
  logic       byp = 1'b0;

  always_ff @(posedge tck) begin
    case (st)
      TLR:    st <= tms ? TLR    : RTI;
      RTI:    st <= tms ? SEL_DR : RTI;
      SEL_DR: st <= tms ? SEL_IR : CAP_DR;
      CAP_DR: st <= tms ? EX1_DR : SH_DR;
      SH_DR:  st <= tms ? EX1_DR : SH_DR;
      EX1_DR: st <= tms ? UPD_DR : PAU_DR;
      PAU_DR: st <= tms ? EX2_DR : PAU_DR;
      EX2_DR: st <= tms ? UPD_DR : SH_DR;
      UPD_DR: st <= tms ? SEL_DR : RTI;
      SEL_IR: st <= tms ? TLR    : CAP_IR;
      CAP_IR: st <= tms ? EX1_IR : SH_IR;
      SH_IR:  st <= tms ? EX1_IR : SH_IR;
      EX1_IR: st <= tms ? UPD_IR : PAU_IR;
      PAU_IR: st <= tms ? EX2_IR : PAU_IR;
      EX2_IR: st <= tms ? UPD_IR : SH_IR;
      UPD_IR: st <= tms ? SEL_DR : RTI;
      default: st <= TLR;
    endcase
    if (st == TLR) ir <= IR_IDCODE;
    if (st == CAP_IR) ir_sr <= 6'b000001;
    if (st == SH_IR)  ir_sr <= {tdi, ir_sr[5:1]};
    if (st == UPD_IR) ir <= ir_sr;
    if (st == CAP_DR) begin
      id_sr <= IDCODE;
      byp   <= 1'b0;
    end
    if (st == SH_DR) begin
      id_sr <= {tdi, id_sr[31:1]};
      byp   <= tdi;
    end
  end

  always_comb begin
    jtag_o.tdi     = tdi;
    jtag_o.treset  = st == TLR;
    jtag_o.capture = st == CAP_DR;
    jtag_o.shift   = st == SH_DR;
    jtag_o.update  = st == UPD_DR;
    jtag_o.sel     = {ir == IR_USER4, ir == IR_USER3};
    tdo = st == SH_IR      ? ir_sr[0] :
          ir == IR_USER3   ? user_tdo_i[0] :
          ir == IR_USER4   ? user_tdo_i[1] :
          ir == IR_IDCODE  ? id_sr[0] : byp;
  end
endmodule
