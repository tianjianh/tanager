// Simulation model of the UltraScale+ CARRY8 primitive for unit tests of tg_iq's carry chains (TG_SIM_PRIMS,
// tg_iq_cand), written from the documented behaviour (UG974): with CARRY_TYPE "SINGLE_CY8" one 8-bit chain,
// CO[i] = S[i] ? (i == 0 ? CI : CO[i-1]) : DI[i], O[i] = S[i] ^ (i == 0 ? CI : CO[i-1]). "DUAL_CY4" (two 4-bit
// chains, the upper from CI_TOP) is not modelled.
/* verilator lint_off DECLFILENAME */
module CARRY8 #(
  parameter string CARRY_TYPE = "SINGLE_CY8"
) (
  output logic [7:0] CO,
  output logic [7:0] O,
  input  logic       CI,
  input  logic       CI_TOP,
  input  logic [7:0] DI,
  input  logic [7:0] S
);
  initial if (CARRY_TYPE != "SINGLE_CY8") $fatal(1, "CARRY8 model: only SINGLE_CY8");
  always_comb begin
    logic c;
    c = CI;
    for (int i = 0; i < 8; i++) begin
      O[i]  = S[i] ^ c;
      CO[i] = S[i] ? c : DI[i];
      c     = CO[i];
    end
  end
  wire unused = CI_TOP;
endmodule
/* verilator lint_on DECLFILENAME */
