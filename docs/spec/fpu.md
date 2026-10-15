# FPU execution units (`tg_fpu`, `tg_fpu_fma`, `tg_fpu_misc`, `tg_fpu_div`)

Status: implemented — fpu track — 2026-10-13 (results under "Timing and area")

## Purpose

The three floating-point execution units behind port P4 of the core (plan §4.12), with the port contract of [interfaces.md §4](interfaces.md) and `rtl/common/tg_fpu_pkg.sv`:

| Unit | Module | Operations | Timing |
|---|---|---|---|
| FMA | `tg_fpu_fma` | FADD, FSUB, FMUL, FMADD, FMSUB, FNMSUB, FNMADD; FCVT FP→FP and integer→FP (lever R5) | `FMA_LAT` = 5, fully pipelined |
| FMISC | `tg_fpu_misc` | FSGNJ/N/X, FMIN, FMAX, FEQ, FLT, FLE, FCLASS, FCVT FP→integer, FMV | `FMISC_LAT` = 2, fully pipelined |
| Divide/sqrt | `tg_fpu_div` | FDIV, FSQRT | 19 / 23 cycles (divide S / D), 19 / 27 (square root S / D); up to 4 in flight |

`tg_fpu` instantiates the three units and nothing else. The core owns issue, the FP register file, bypass, writeback arbitration, `fcsr` and the accumulation of `fflags` (plan §4.5). The FPU holds no architectural state.

Both formats of RISC-V F and D (unprivileged ISA 20240411, chapters "F" and "D") are implemented exactly. `FMT_H` is not implemented (Zfhmin is not scheduled); an assertion flags it.

## Interface

Ports are those of the stub `rtl/core/fpu/tg_fpu.sv`; requests are `fpu_req_t`, responses `fpu_resp_t` (`tg_fpu_pkg`).

**Routing.** `tg_fpu_pkg::fpu_unit_of(op)` returns the port (`FU_FMA`, `FU_MISC`, `FU_DIV`) that executes an operation; the core routes with it and never hard-codes the unit. Each unit asserts that it only receives its own operations.

**Request timing.** A request is taken at the rising edge that ends the cycle in which `*_valid_i` is high (and `fdiv_ready_o`, for the divider). The first stage of every unit does little work, because the operands may arrive late in the cycle through the core's bypass multiplexer. The FMA's E0 stops at a format multiplexer, the NaN-box check, the integer extension of FCVT.F.I, exponent arithmetic of 13 bits and the DSP input registers; FMISC's M0 adds a magnitude compare. The timing runs model the late arrival (1.5 ns; "Timing and area").

**FMA and FMISC.** A request in cycle *t* produces `*_valid_o` and the response in cycle *t* + `FMA_LAT` (resp. *t* + `FMISC_LAT`), from a register. There is no backpressure: the core reserves the writeback slot at issue. A unit accepts one request per cycle.

**Divide/sqrt.** Valid/ready on both sides (conventions §3):
- `fdiv_ready_o` depends only on internal state, never on `fdiv_valid_i`.
- The response is held in an output queue until `fdiv_valid_o && fdiv_ready_i`. `fdiv_valid_o` does not depend on `fdiv_ready_i`.
- Latency is fixed per operation type (table above) unless the output queue is full; then a finished operation waits (see "Flow control").
- Results may leave in a different order from requests. The tag identifies them.

**Responses.**
- `result`: FP results NaN-boxed when `fmt = S`; integer results (`int_dest = 1`) sign-extended to 64 bits as RV64 requires (FCVT.W[U] sign-extend bit 31; FMV.X.W sign-extends bit 31; compares return 0 or 1; FCLASS returns the 10-bit mask).
- `fflags` = {NV, DZ, OF, UF, NX} of this operation only.
- `tag` is returned unchanged.
  - **Divider exception:** the divider keeps only `DIV_TAG_W` tag bits (a `tg_fpu` parameter, default `FPU_TAG_W`) in its output queue and returns the rest as zero. Requests must leave them zero, which an assertion checks. `tg_fp_exec` uses 2, its divide-table index.
  - A divide's `int_dest` is always 0.

**Reset** clears every valid bit (pipeline valids, the divider's slot and queue state). Datapath registers are not reset (plan §8.3).

## Behaviour common to all units

### Operand unpacking

| Item | Rule (RISC-V F/D) |
|---|---|
| NaN boxing | For `fmt = S`, an operand whose bits 63:32 are not all ones reads as the canonical single NaN `0x7FC00000`. FMV.X.W is a transfer and ignores bits 63:32. |
| Classes | zero, subnormal, normal, infinity, quiet NaN, signalling NaN (fraction MSB = 0, fraction ≠ 0) |
| Significand | 53-bit field `{h, f}` with the hidden bit `h` = (exponent ≠ 0). S significands occupy the top 24 bits of the field (bits 52:29), the rest zero. |
| Exponent | Subnormals use exponent field 1. Internal exponents are signed, in double bias (S fields are rebiased by +896), wide enough for products and quotients of extreme values (13 bits). |

Unpacking is one function in the FPU-local package `tg_fpu_util_pkg` (`rtl/core/fpu/`), shared by the three units.

### Results and flags

- **Canonical NaN.** Every NaN result is `0x7FF8000000000000` (D) or `0xFFFFFFFF_7FC00000` (S, boxed). No NaN payload propagates.
- **NV** for: any signalling-NaN input to an arithmetic operation, compare (FEQ only for sNaN; FLT/FLE for any NaN), FMIN/FMAX (sNaN only) or conversion; ∞ × 0 in the FMA even when the addend is a quiet NaN (F chapter, FMA); ∞ − ∞ (effective subtraction of infinities); 0/0, ∞/∞; square root of a value < 0 (not −0); FP→integer conversion of NaN, ∞ or an out-of-range value.
- **DZ** for a finite non-zero dividend divided by zero.
- **OF** when the rounded result with unbounded exponent exceeds the format's largest finite value. The result is ∞ or the largest finite value per the rounding mode (IEEE 754-2019 §7.4). OF implies NX.
- **UF** when the result is tiny *after rounding* and inexact (RISC-V detects tininess after rounding; IEEE 754-2019 §7.5). Tiny after rounding: the result rounded to *p* bits with unbounded exponent is below 2^emin in magnitude. Exact subnormal results raise no flag.
- **NX** when the delivered result differs from the exact result (including overflow), but never together with NV from the same conversion.
- **Signed zeros.** An exact zero sum of operands of opposite sign is +0, or −0 in RDN; x + x keeps the sign of x (IEEE 754-2019 §6.3). The FMA applies this to (a×b) + c with the product as one operand. FMUL has no addend: its zero results take the product's sign in every mode.

### Rounding

All five modes (`rm_e`; never DYN). Rounding uses the classic (T, G, S) decomposition: the truncated *p*-bit significand T, the guard bit G and the sticky bit S (OR of everything below G). Round up when:

| Mode | Round up when |
|---|---|
| RNE | G ∧ (S ∨ lsb(T)) |
| RTZ | never |
| RDN | (G ∨ S) ∧ negative |
| RUP | (G ∨ S) ∧ positive |
| RMM | G |

Overflow selects ∞ for RNE and RMM, for RUP when positive and for RDN when negative; otherwise the largest finite value.

Results are packed by adding the round increment to `{exponent − 1 + h, fraction}` so that a carry out of the fraction increments the exponent field, which also turns a subnormal that rounds up to 2^emin into the smallest normal.

## FMA unit (`tg_fpu_fma`)

### Operation mapping

All arithmetic operations become (±A × B) ± C with one rounding:

| Op | A | B | C | Product sign flip | Addend sign flip |
|---|---|---|---|---|---|
| FMADD | a | b | c | – | – |
| FMSUB | a | b | c | – | yes |
| FNMSUB | a | b | c | yes | – |
| FNMADD | a | b | c | yes | yes |
| FADD | a | 1.0 | c (rs2) | – | – |
| FSUB | a | 1.0 | c (rs2) | – | yes |
| FMUL | a | b | none (exact zero, no sign contribution) | – | – |
| FCVT.F.F | a, in `src_fmt` | 1.0 | none | – | – |

FADD and FSUB take their second operand in `c`, and `b` is ignored: P4 reads rs2 into `c` (AR-8, 2026-10-14). Before that, the FMA had a multiplexer moving `b` into the addend.

The sign flips are exact negations (FNMADD = −(a×b) − c), applied to the product and addend signs before the effective operation is chosen, so rounding direction and zero signs follow the negated operands.

**Conversions (lever R5, plan §8.5).** The FP→FP and integer→FP conversions reuse the FMA's normaliser and rounder and take `FMA_LAT` cycles:
- **FCVT.F.F** is a × 1.0 with no addend. The operand is unpacked (NaN box, classes, exponent constants) in `src_fmt`; the result is rounded, range-checked and packed in `fmt`. S → D is exact (a subnormal S is normalised like any unnormalised product); D → S rounds to 24 bits with S overflow, S subnormals and tininess after rounding. NaN, infinity and zero follow the multiply's special cases.
- **FCVT.F.I** takes the integer from `a` (sign- or zero-extended per `ifmt`). E0 registers it; E1 negates a negative value beside the alignment and places \|x\| as the adder's addend operand at V[164:101], so V[164] weighs 2^63 (E_top = 63 + 1023); E2 drops the product. E3 normalises and E4 rounds as for any sum; the sign is that of x, and x = 0 gives +0 through the special path.

### Datapath (D precision, p = 53; S uses the same path)

The product P = ma × mb is a 106-bit integer, weight 2^(Ep−104) with Ep = Ea + Eb. The addend is aligned in a window to the left of the product (the single-path FMA of Montoye et al., with the addend pre-placed to the left of the product so that only a right shift is needed). In window coordinates V[164:0]:
- the product occupies V[109:4] and the addend starts at V[164:112] (sh = 0);
- V[3:1] are three zero bits below the product. A multiplicand that is a subnormal with one or two significant bits puts the product up to 53 places below its nominal position, and these bits keep its round bit inside the window;
- V[0] collects the sticky of whatever falls below the window, so an effective subtraction borrows correctly;
- the adder works on 166 bits (bit 165 is the sign of the difference).

Placement:
- Right shift of the addend: sh = Ep − Ec + 56, clamped to [0, 165].
  - sh < 0 before clamping (Ec > Ep + 56): the addend dominates. The product is at least three bits below the addend's LSB and is replaced by a one in V[0].
  - sh > 112: addend bits below V[0] go to the sticky, computed from the addend's trailing-zero count.
  - A zero product anchors the window at the addend (sh = 0); a missing or zero addend anchors it at the product (sh = 165).
- Window exponent: V[164] has weight 2^E_top, E_top = Ep + 56, or Ec when the addend dominates.

**Multiplier.** With ma = 2^52·ha + fa and mb = 2^52·hb + fb (fa, fb the 52-bit fractions):

  P = fa × fb[50:0] + 2^51·fb[51]·fa + 2^52·(ha·fb + hb·fa) + 2^104·ha·hb

- fa[51:0] × fb[50:0] uses six DSP48E2 tiles of 26 × 17 bits (fa in two 26-bit chunks on the 27-bit port, fb in three 17-bit chunks on the 18-bit port; UG579).
- The three "row" terms and the 2^104 bit are summed in fabric in E1 by one ternary adder (the 2^104 bit sits above 2^52·ha·fb in the same operand) and enter two of the tiles through their C ports, so they cost no extra adder input in E2.
- Each tile computes A×B + C into its P register in one cycle (no M register; the DSP48E2 meets 200 MHz without it).
- When the product takes no part (FCVT.F.I, or an addend that dominates), the tiles' P registers are reset (the DSP48E2 P-register reset), so the adder needs no input gating.

**Pipeline** (stage E*k* is the cycle after the request plus *k*; E0 is the request cycle; registers at the end of each stage):

| Stage | Work |
|---|---|
| E0 | Unpack the three operands (format, NaN box, classes, hidden bits); special-case detection; the raw exponent sums ep = ea + eb − bias and shr = ep − ec + 56, straight from the encoding fields with the format's bias in a constant; load the DSP A/B registers. The operands may arrive late (the core's bypass), so E0 stops at the sums. |
| E1 | DSP tiles (A×B + rows). Window placement: clamp shr to sh, choose E_top, lim = E_top − emin. Addend alignment (`tg_fpu_fma_align`): 53 → 165-bit right shift by sh with the sticky from a trailing-zero count. FCVT.F.I's \|x\| is ORed into the addend operand (each is zero when the other is used). |
| E2 | Add (`tg_fpu_fma_add`): the six tile outputs and the aligned addend (complemented inside the column counters for an effective subtraction; column height ≤ 5) reduce column by column to three rows. Below bit 112 two ternary adders run in parallel, X = P − C (= P + ~C + 1) and Y = X − 1; above it only the addend contributes and the low part's carry is 0 or 1, so one incrementer serves both. That incrementer runs in two DSPs (`tg_fpu_dsp_add`, DR-123) on their own copy of E1's addend register, complemented there for an effective subtraction; the XOR shares its LUT with the addend's OR. \|S\| is X, or ~Y when X < 0. The emin marker (below) is decoded from lim, as the AND of one-hots of lim[7:4] and lim[3:0]. |
| E3 | Normalise (`tg_fpu_fma_norm`): leading-zero count of \|S\| \| marker, then the left shift in four radix-4 stages; each stage keeps only the bits that can still reach the top 55 (significand, guard, round) and ORs the rest into the sticky. |
| E4 | Round (T, G, S and one round bit below G for the tininess test), pack with the exponent (one adder for both formats: an S result occupies bits 59:29 of the D layout), exact zero (n = 0 with no sticky), special-case results, NaN boxing, flags. The response register. |

The control fields travel E0 → E4 in flip-flops (`shreg_extract = "no"`). As shift-register LUTs they would cost LUTs, and their longer setup time would lengthen E0's special-case path.

**Subnormal results** need no right shift: the normalising left shift is limited so that the exponent never goes below emin. The limit L = E_top − emin is known in E1; a one-hot marker bit at V[164 − L] (decoded and registered in E2) is ORed into \|S\| for the leading-zero count only, so the count can never exceed L (the "virtual leading one"). If L < 0 (E_top < emin: no addend and a product far below the smallest subnormal) the significand is cleared and the sticky is 1, which rounds to zero or the smallest subnormal. (Such a window always holds a non-zero product: a window anchored at an addend or at a zero product is never below emin.)

**Rounding position.** For D, T = bits 54:2 of the normalised 55-bit window, G = bit 1, round bit = bit 0; for S, T = bits 54:31, G = bit 30, round bit = bit 29, and bits 28:0 join the sticky. The S exponent range check uses S limits (emin = −126, emax = 127).

**Tininess after rounding.** When the normalised value has its MSB one place below the emin position (the value is in [2^(emin−1), 2^emin)), the result is not tiny if rounding to *p* bits at the normal position (T' = the *p* bits below the MSB, G' = the next bit, S' = the rest) rounds up to 2^emin. The round bit makes this test exact.

**Special results** (computed in E0, carried to E4 as a kind and a sign, `spec_e`): canonical NaN for NaN inputs, ∞ × 0, ∞ − ∞; ∞ with the right sign; exact zeros with the IEEE sign rules above.

**Four-cycle option.** Plan §4.12 adopts a 4-cycle FMA only if it costs no Fmax. The RTL keeps each stage a separate block so a 4-stage variant (E3 and E4 merged) can be synthesised for comparison; the result of that experiment is reported under "Timing and area".

## FMISC unit (`tg_fpu_misc`)

Two stages, M0 (request cycle) and M1, each ending in a register; the response comes from the M1 register. M0 classifies the operands, compares the magnitudes of the raw encodings and prepares FCVT.I.F; M1 computes every result from the raw operands. NaN boxing matters only where an S operand's bits reach the result (sign injection of an improperly boxed a), so one flag travels instead of unboxed copies; FMIN/FMAX return an operand that is not a NaN, which is properly boxed. The FP→FP and integer→FP conversions run on the FMA (lever R5, above).

FCVT.I.F shifts {significand, 12'b0} right by 63 − E in M1, in three radix-4 stages, to {integer part, guard}; each stage ORs the bits it drops into the sticky.

| Operation | M0 | M1 |
|---|---|---|
| FSGNJ, FSGNJN, FSGNJX | unpack (NaN box) | sign of b (or its inverse, or XOR) |
| FMIN, FMAX | unpack; 63-bit magnitude compare | select per F 2.2: a NaN operand loses to a number; both NaN → canonical NaN; −0 < +0; NV if any sNaN |
| FEQ, FLT, FLE | unpack; magnitude compare | ±0 equal; FEQ quiet (NV only for sNaN), FLT/FLE signalling (NV for any NaN), NaN compares false |
| FCLASS | unpack | 10-bit one-hot class mask |
| FMV.X.W / FMV.X.D | – | sign-extend a[31:0] / pass a |
| FMV.W.X / FMV.D.X | – | {0xFFFFFFFF, a[31:0]} / a |
| FCVT.{W,WU,L,LU}.{S,D} | unpack; shift = 1086 − exponent field, saturated | shift; round; negate by one adder (negative ? ~m + ¬inc : m + inc); range check on m and inc without another adder; saturate (NaN and +overflow → max, −overflow → min, i.e. 0 for unsigned); NV, or NX if inexact |

The integer source of FMV.F.X arrives in `a`.

**Unsigned conversion of negative values.** A negative input that rounds to zero converts to 0 with NX only; one that rounds to −1 or below is invalid (result 0, NV).

## Divide/sqrt unit (`tg_fpu_div`)

### Overview

Division and square root by Goldschmidt iteration (Goldschmidt 1964; Ercegovac & Lang, *Digital Arithmetic*, ch. 7) on two dedicated 60 × 60-bit multipliers, M1 and M2, with:
- a seed ROM in one BRAM18 (2 K × 9: 1 K reciprocal and 1 K reciprocal-square-root entries);
- a short chain of small DSP multipliers that computes approximate correction terms while the first iteration runs;
- correct rounding from a final back-multiplication (remainder) and a (T, G, S) selection, the method of the AMD-K7 FPU (Oberman, ARITH-14, 1999).

**Rounds and slots.** A *round* is one pass through a multiplier: operands formed and registered in cycle c0, three multiplier stages c1–c3, product registered at the end of c3; the next round's c0 is the following cycle. Rounds take exactly 4 cycles. The multipliers are fully pipelined, so four operations can use them at once, one per phase (cycle mod 4). The unit is therefore a ring of four *slots*; each operation owns one slot from its first round to its last and carries its state around the ring with the multiplier pipeline. The plan's "new operation every 4 cycles" becomes "a new operation whenever its slot is free".

### Fixed-point formats

All iteration values are unsigned Q2.58 (60 bits: two integer, 58 fraction bits). Products are 120 bits (Q4.116); iteration products are truncated to Q2.58 (bits 117:58), the remainder product is used in full.

Operands are normalised in the first cycle after acceptance (leading-zero count and left shift of subnormal significands), so ma, mb ∈ [1, 2).

- **Divide:** if ma < mb the dividend is doubled and the exponent decremented, so q = A/mb ∈ [1, 2) with A ∈ [1, 4).
- **Square root:** an odd exponent doubles the radicand, x ∈ [1, 4), so √x ∈ [1, 2).

### Seed ROM

- Reciprocal: index = mb fraction bits 51:42; entry s ≈ 1/mb, stored as 9 bits after an implicit "0.1" (10 significant bits). Each entry minimises the worst relative error |1 − mb·s| over its interval after quantisation (the optimal-interval-reciprocal construction of Das Sarma & Matula, IEEE TC 1994, with quantisation folded into the search).
- Reciprocal square root: index = {exponent parity, fraction bits 51:43}; entry y0 ≈ 1/√x, same encoding.
- Generated by `tests/unit/fpu/gen_seed.py` into the package `rtl/core/fpu/tg_fpu_seed_pkg.sv` (checked in); the generator prints the worst-case errors, which the error budget below depends on: max \|1 − mb·s\| = 2^−9.73 and max \|1 − x·y0²\| = 2^−8.69.
- The ROM is a `tg_rom` (`rtl/common/prim`; block RAM, `RD_LAT` = 2: address and output registers in the BRAM18), so the primitive check counts it.

### Small multipliers (approximate terms)

While round 1 runs, small DSPs compute an approximation ẽ0 of the round-1 error e0 from truncated operands, and ẽ0², ẽ0³:

| Stage (cycle) | Divide | Square root |
|---|---|---|
| SM0 (t+3, 1 DSP) | D̃0 = mb[52:29] × s → ẽ0 = 1 − D̃0 | Y2 = y0² (exact; feeds M2 in round 1) |
| SMa (t+4, 2 DSPs) | – | ũ0 = x[59:34] × Y2 → ẽ0 = 1 − ũ0 (t+5). The low tile subtracts its product from 2^44 in its own ALU, so only a 30-bit subtraction of the high tile is left in LUTs (DR-123). |
| SMb (t+6, 1 DSP) | e2 = ẽ0 × (ẽ0 >> 9) ≈ ẽ0² | same |
| SMc (t+7, 1 DSP) | e23 = (e2 >> 24) × (ẽ0 >> 9) + e2 ≈ ẽ0³ + ẽ0² | e23 = (5 (e2 >> 24)(ẽ0 >> 9) + 6 e2) / 16 ≈ 5/16 ẽ0³ + 3/8 ẽ0² |

All values are Q.33 or Q2.58 two's complement and fit the DSP48E2 ports (27-bit A, 18-bit B, 48-bit C). The chain runs in lockstep with the slot: the operation that entered in t+4 is in ring stage r4 in t+8, the c0 of its round 2, exactly when e23 leaves SMc, so e23 is never stored in the ring. \|ẽ0 − e0\| ≤ 2^−23, so the terms are good to about 2^−32. They only steer the iteration; the remainder step makes the result exact regardless.

### Division schedule

| Round | M1 | M2 | Notes |
|---|---|---|---|
| R1 | N0 = A · s | D0 = mb · s | e0 = 1 − D0, \|e0\| ≲ 2^−9.7 |
| R2 | N1 = N0 · R | D1 = D0 · R | R = 2 − D0 + e23 ≈ 1 + e0 + e0² + e0³ (cubic step); e1 = 1 − D1 ≈ 2^−31 |
| R3 (D only) | N2 = N1 · (2 − D1) | – | error ≈ e1² + truncation |
| last | remainder: mb · c | – | c = quotient rounded to the guard grid |

Single precision uses R1, R2 and the remainder round (3 rounds); double precision R1–R3 and the remainder round (4 rounds).

### Square-root schedule (Goldschmidt with a second-order first step)

| Round | M1 | M2 | Notes |
|---|---|---|---|
| R1 | q0 = x · y0 | u0 = x · Y2 | e0 = 1 − u0 ≈ 2·(seed error), \|e0\| ≲ 2^−8.5 |
| R2 | q1 = q0 · P | y1 = y0 · P | P = 3/2 − u0/2 + e23 = 1 + e0/2 + ⅜ẽ0² + 5⁄16 ẽ0³, the series of (1 − e0)^−½; q1 error ≲ 2^−32 |
| R3 (D only) | w1 = q1 · y1 | – | e1 = 1 − w1, computed from the actual q1, y1 (self-correcting) |
| R4 (D only) | q2 = q1 · (3/2 − w1/2) | – | error ≈ ⅜·e1² + truncation |
| last | remainder: c · c | – | |

Single precision: 3 rounds; double: 5 rounds. Markstein (RNC 2004) gives the error behaviour of these coupled iterations.

The four iteration factors share one adder in c0: K − (src >> h) + e, with K = 2 (division) or 3/2 (square root), src = D0, D1, u0 or w1, h = 1 for the square root (x/2 truncated) and e = e23 in round 2.

### Error budget

The rounding step needs |q_approx − q| < u_g/2, where u_g is the guard-bit weight (2^−53 for D and 2^−24 for S, q ∈ [1, 2)), i.e. 2^−54 (D) and 2^−25 (S). The bit-accurate model (`tests/unit/fpu/gs_model.h`, checked by `gs_check`) measures, over 161M random operands, 20K directed cases per kind and both ends of every seed interval:
- each truncated product adds at most 2^−58;
- divide D: worst 2^−56.1; divide S: 2^−32.8;
- square root D: worst 2^−56.1; square root S: 2^−32.9.

Q2.58 (rather than the plan's 56-bit multiplier) is what makes the double-precision budget hold with a one-step correction; it costs no extra DSPs (60 = 26 + 26 + 8 on the 27-bit port, 17 + 17 + 17 + 9 on the 18-bit port).

### Final rounding (remainder round, F0, F1, F2)

1. **c0 of the last round:** c = q_approx rounded to the nearest multiple of u_g. Then q ∈ (c − u_g, c + u_g), and c may equal 2.0.
2. **Remainder:** R = A − mb·c (divide) or R = x − c² (square root), exact. Only its sign and whether it is zero are needed. |R| < 2^−51 (D), so only the low 57 bits of the product and two bits of A or x take part; S uses a window 29 bits higher.
3. **F0:** (T, G, S) at normal precision:
   - R = 0: from c, S = 0;
   - R > 0: from c, S = 1;
   - R < 0: from c − u_g, S = 1.

   Exact midpoints cannot occur for division or square root, so the sticky case never hides a tie. F0 runs in the c0 cycle after the remainder product: the remainder's sign and zero test, and the choice of c or c − u_g. The remainder is the low 96 bits of A·2^58 − p, small, so it is exact modulo 2^96. Its low 58 bits are −p[57:0], which only lends a borrow when p[57:0] ≠ 0: a 38-bit subtraction of the upper bits with that borrow gives the sign, and with the 58-bit test the zero test (DR-123; it replaced a 96-bit subtraction).
4. **F1:** for a divide result below 2^emin, shift (T, G, S) right by k = emin − Eq (k ≤ 55, larger values clamp) in three radix-4 stages, each ORing the bits it drops into the sticky; the rounding decision; flags. The conditions that depend only on Eq (subnormal, k, the exponent field, Eq = emin − 1, Eq > emax, Eq = emax) are derived in S3 and travel with the operation.
   - Tininess after rounding uses the normal-precision (T, G, S) from F0: a result with Eq = emin − 1 is not tiny if it rounds up to 2^emin at *p* bits.
   - Overflow: Eq > emax, or Eq = emax and the significand rounds up from all ones.
   - Square roots are never subnormal and never overflow.
5. **F2:** pack {exponent − 1 + hidden, fraction} + increment, special results, NaN boxing; into the output queue.

### Pipeline and latency

| Cycle (accept = t) | Work |
|---|---|
| t | request registered |
| t+1 | S1: unpack, classify, specials, normalise both significands (LZC + shift), seed-ROM address |
| t+2 | S2: ma < mb, operand scaling, result exponent Eq (BRAM read) |
| t+3 | S3: SM0; conditions derived from Eq |
| t+4 | c0 of R1 (slot entry); SMa |
| t+4·n | c0 of round n |
| t+4·n_last+4 | F0 |
| t+4·n_last+5 | F1 |
| t+4·n_last+6 | F2; written to the output queue |
| t+4·n_last+7 | `fdiv_valid_o` |

| Operation | Rounds n_last | Latency | Slot held (cycles) | Steady-state rate |
|---|---|---|---|---|
| FDIV.S | 3 | 19 | 12 | 1 per 3 cycles |
| FDIV.D | 4 | 23 | 16 | 1 per 4 cycles |
| FSQRT.S | 3 | 19 | 12 | 1 per 3 cycles |
| FSQRT.D | 5 | 27 | 20 | 1 per 5 cycles |

Against the plan (18/23, 20/26, one every 4 cycles): FDIV.D and FSQRT.S meet it, FDIV.S and FSQRT.D are one cycle longer (F2 was added for timing), and FSQRT.D's rate is one per 5 cycles. The constants `FDIV_LAT_S/D` and `FSQRT_LAT_S/D` in `tg_fpu_pkg` are set to the latencies above.

### Flow control

- **Slots.** Slot *k* passes the entry point (c0) in cycles ≡ *k* (mod 4). A request accepted in cycle *t* enters, four cycles later, the slot that is in c0 in cycle *t*. So `fdiv_ready_o` is high when that slot will be empty after this cycle: no operation enters it now (accepted four cycles ago) and its operation, if any, leaves now. It depends only on registers.
- **Output queue and credits.** The output queue (`tg_fifo`, 4 entries) holds results until `fdiv_ready_i`. It stores only the result, the flags and `DIV_TAG_W` tag bits: 71 bits in P4, not 102. An operation whose remainder product is ready leaves its slot for F0 only if the queue has room for it counting the results in F1 and F2; otherwise it repeats the remainder round (4 cycles later; the round is idempotent) and keeps its slot. With `fdiv_ready_i` mostly high this never happens.
- **Special operands** (NaN, ∞, zero, divide by zero, negative square root) still pass through the ring, so every operation has the same latency and one exit path; F2 substitutes the special result.

### Area

- 24 DSP48E2 for M1 and M2 (`tg_fpu_div_mul`): each is 12 tiles; tiles of y chunks 1 and 3 add their neighbour shifted right by 17 in c2 (the DSP cascade pattern), and the six pair sums are added by two ternary adders and one binary adder in c3. `use_dsp` keeps the smallest tile (8 × 9 bits) in a DSP; Vivado otherwise builds it in LUTs.
- 5 DSP48E2 for the small multipliers (SMa's 26 × 3-bit half by `use_dsp` too); SMc forms 5·e2hi in its pre-adder.
- The pipeline and ring registers are flip-flops (`shreg_extract = "no"`): as shift-register LUTs they would spend LUTs, the scarce resource, to save flip-flops.
- 1 BRAM18.

## Fallback: radix-4 divide/sqrt (`tg_fpu_div_r4`)

The plan's fallback for the Goldschmidt unit (§4.12, trim ladder §8.4 #6). `tg_fpu_pkg::FDIV_RADIX4 = 1` selects it (`tg_fpu` parameter `DIV_RADIX4`) together with its latency constants; ports and handshake are those of `tg_fpu_div`. Bit-accurate model: `tests/unit/fpu/r4_model.h`.

**Algorithm.** Restoring digit recurrence in radix 4 (Ercegovac & Lang, *Digital Arithmetic*, ch. 5 and 6), on the operands scaled as for the Goldschmidt unit (q ∈ [1, 2)), so the integer digit is 1 and the residual starts at w0 = A − d (division) or x − 1 (square root). Each cycle chooses the next digit b ∈ {0, 1, 2, 3} as the largest b with X − S_b ≥ 0, X = 4w, and sets w to X − S_b:

| | S1 | S2 | S3 |
|---|---|---|---|
| Division | d | 2d | d + 2d |
| Square root (u = 4^−(j+1)) | 2Q \| u | 4Q \| 4u | (2Q \| u) + (4Q \| 8u) = 6Q + 9u |

- The partial root Q has no bits at or below u, so its terms are ORs, and S3 needs no 3Q register: T3 = X − S1 − (4Q \| 8u) is one ternary subtraction.
- The three trial subtractions run in parallel, one carry chain per cycle. There is no redundancy, no selection table and no on-the-fly conversion; the residual is never negative, so the digits are exact and S = (w ≠ 0).
- Widths: residual Q4.56 (the model shows 4w < 2^60), root and quotient Q1.56; 27 digits for D (52 fraction bits, guard and one spare), 12 for S.

**Pipeline.** One operation at a time: UNP (unpack, specials, normalise the divisor or the radicand), NRM (normalise the dividend with the same leading-zero counter and shifter), INI (scaling, exponent, w0), then one digit per cycle; the last digit hands (T, G, S) to `tg_fpu_div_round`. Latency 18 (S) and 33 (D) cycles for both operations; the result waits in an output register for `fdiv_ready_i`, and the next request is accepted once it has been taken.

## Lever R4: integer divide on the Goldschmidt unit (assessment, not built)

Plan §8.5 lever R4 runs DIV/REM on the Goldschmidt unit's multipliers so that the core's integer divider goes. Assessed 2026-10-13 at the coordinator's request; not built (the coordinator schedules it with the core track).

**What would go.** The core's integer divider `tg_div` (core track, branch `claude/track-core-adb715-m3`, commit 24595a1) uses radix-2 restoring division with early out:
- **Latency:** n + 4 cycles for an n-bit quotient, so at most 68 (36 for the W forms), and 4 when the quotient is 0. It runs one divide at a time behind a 4-entry input FIFO.
- **Size** (out of context at 200 MHz, the flow above): 1,447 LUTs (92 of them LUTRAM for the FIFO), 293 FFs, WNS +0.21 ns; its slowest path is the early-out normaliser (two 64-bit leading-zero counts and a 128-bit shift, 14 logic levels).

**What the divide/sqrt unit would need.**
- **Precision.** A 64-bit quotient needs the approximation within 2^−64 of A/B, so that one remainder round picks between two candidates. The FP unit reaches 2^−56.1, limited by truncation (about four products at 2^−58 each) and by the convergence after R3 (e1² ≈ 2^−62, "Division schedule").
  - The iteration values grow from 60 to about 70 bits (Q2.68): x splits as 26 + 26 + 18 bits and y into five 17-bit chunks, so 15 tiles per multiplier instead of 12 (+6 DSPs). The c3 adders, the operand multiplexers and the slot registers grow by about 10 bits each.
  - Integer division takes one more Newton round (R4: e ≈ e2² ≈ 2^−124) before the remainder round, +4 cycles.
- **A front-end stage before S1:** the W forms extend bit 31, and the signed forms take \|a\| and \|b\| (two 64-bit negations). This cannot join S1, which is already the unit's critical path (10 logic levels into the seed-ROM address). Integer operations therefore enter the ring one cycle later than FP ones, and the ready logic looks one slot further ahead for them.
- **S1:** the normalisers widen from 53 to 64 bits.
- **Remainder round:** the candidate's grid becomes variable. The integer quotient's LSB lies lzb − lza places below the binary point of the normalised quotient, not at the S or D position, so the half-grid and mask are decoded from that difference.
- **REM** needs the remainder's value, not just its sign. It is shifted back by the dividend's normalisation and corrected by +b when the lower candidate is taken, which takes an adder and the divisor carried in the slot.
- **F1:** the denormalisation shifter, widened to 64 bits, aligns the quotient (DIV) or the remainder (REM).
- **F2/F3:**
  - the sign fix-up, one ternary adder that also folds in the REM correction;
  - W sign extension;
  - division by zero (quotient all ones, remainder a);
  - overflow (−2^63 / −1) falls out of the magnitude path, as in `tg_div`.
- **Estimate:** +0.9 to 1.1K LUTs and +6 DSPs.

**What the core would change.**
- **Request port:**
  - DIV/REM stay in IQ-A1, which reads their two integer operands.
  - P1 (DIV/REM) and P4 (FDIV/FSQRT) share the divider's request port through an arbiter and a 2:1 multiplexer for the operands, operation and tag, about 0.15K LUTs.
  - P1's select sees `fdiv_ready_o` (a register) and the arbitration result.
- **No input FIFO:**
  - `tg_div`'s 4-entry FIFO goes, and a divide issues only when the divider is ready.
  - Divides retire early once issued (plan §4.5), so nothing in the divider is ever flushed.
- **Results:**
  - Integer results leave the divider's output queue for P1's write port (bank B1, the existing reservation arbitration, the LLT wakeup as today). FP results go to F0.
  - A result waiting for one port must not block the other: the queue needs per-destination heads, or a one-entry side register.
- **Interface (interfaces.md §4):**
  - `fop_e` gains the integer divide operations, and `fpu_unit_of` maps them to `FU_DIV`.
  - The response's `int_dest` marks integer results.
  - The tag, or a request bit, tells the destination file.

**Net per core:** −1.45K (`tg_div`) + 0.15–0.2K (core glue) + 0.9–1.1K (divider) ≈ −0.15 to −0.4K LUTs, below the plan's 0.4–0.6K. A cheaper early-out normaliser in `tg_div` (the core track's call) would capture much of that saving without R4.

**Latency:** about 29 cycles for any operand size: the FDIV.D schedule of 23, plus the extra round (4), the front-end stage and the integer fix-up. Up to four divides, integer and FP together, are in flight. `tg_div` takes n + 4 cycles, one divide at a time, so R4 is faster for quotients wider than about 25 bits and slower for narrower ones.

## Core integration (P4 back end)

Status: interface agreed with the core track on 2026-10-14. That includes its changes: AR-1's wakeup tags, the completion's `wid`, the B1 hand-off, the integer source, and the load write from a register. The modules are built and unit-tested (verification below), but not yet wired into `tg_core`.

F/D integration splits between the two tracks:
- **FPU track** (`rtl/core/fpu/`): `tg_fprf`, `tg_fp_exec`, `tg_fcsr` and the load/store helpers in `tg_fpcore_pkg`.
- **Core track:** decode, renaming of both register files, dispatch, IQ-FP inside the scheduler (sharing the woken vector W), ROB and commit, and the LSU and CSR-file hooks.

The core instantiates `tg_fp_exec`, which contains `tg_fprf` and `tg_fpu`. The CSR file instantiates `tg_fcsr`.

**Compile order.** The back end imports `tg_core_pkg`, so its files sit in `rtl/core/fpu/fpu_be.f`. `core.f` lists `fpu.f` (the units), then `tg_core_pkg.sv`, then `fpu_be.f`.

### Register file (`tg_fprf`)
- **Banks** (plan §4.7): F0 is written only by `tg_fp_exec`'s F0 stream, F1 only by the load path. Each bank is 64 × 64 bits (`FP_PREGS_PER_BANK`), one `tg_ram_lut` with explicit RAM64M8.
- **FP tags** are {bank, index} (`FPIDX_W` + 1 bits). They travel in the low bits of `preg_t` fields, next to the flag that names the file. `FPIDX_W`, `fpreg_bank()`, `fpreg_idx()` and `mk_fpreg()` are the core's, in `tg_core_pkg`; rename and the LSU use them too.
- **Read ports:**
  - three operand ports (P4's RF stage);
  - one store-data port, `fsd_tag` → `fsd_data`, combinational;
  - `NTR` trace ports (default `COMMIT_WIDTH`, as on the integer file).
  A read selects its bank after the LUTRAM. Read-during-write follows `tg_ram_lut`: the new value is visible after the write edge.
- **Init port** (on `tg_fp_exec`): `init_we`/`init_idx` writes zero into F0, for the reset sequence's initial FP map (Spike resets every f register to 0). The write takes the F0 port, whose stream is idle then, so the zero folds into the F0 stream's multiplexer and the banks need no zero multiplexer. `init_bank` must be 0 (asserted).

### P4 pipeline (`tg_fp_exec`)

Cycle s is IQ-FP's select. The payload `fp_iss_t` (`tg_fpcore_pkg`) is the core's `iq_pl_t` restricted to what P4 needs:
- `tid`, `rob`, `wid`, `llt`, `dst_en`, `dst`;
- `src1`, `src2`, `src3`, `src1_fp`;
- `fop`, `fmt`, `src_fmt`, `ifmt`, `rm` (resolved);
- `fp_int`, `fp_div`.

| Cycle | Stage | Work |
|---|---|---|
| s | IS (core) | IQ-FP selects one operation; `fmisc_block` masks some FMISC rows (below) |
| s+1 | RF | `iss_valid`/`iss_pl` arrive; the three operands are read from `tg_fprf`; bypass selects are computed; an integer source is read through the core's shared integer port (`isrc_tag` → `isrc_data`) |
| s+2 | EX0 | operand multiplexers (bypass); the request to the FMA or FMISC (routing by `fpu_unit_of`), or into the FDIV queue |
| s+4 | – | FMISC result (`FMISC_LAT` = 2): an FP result is written to F0 at the end of s+4; an integer result enters the B1 queue |
| s+7 | – | FMA result (`FMA_LAT` = 5), written to F0 at the end of s+7 |
| c, c+1 | – | an FDIV result claims a free F0 slot in cycle c and is written at the end of c+1 |

**F0 writeback.** F0 has one write port and one writer, the F0 stream. That stream is also the bypass source for every F0 result.
- **Fixed-latency writes:** FMA and FMISC FP results write at fixed cycles (s+7, s+4). They collide only when an FMISC op with an FP destination is selected three cycles after an FMA.
- **`fmisc_block`** is a register, high in cycle s when an FMA was selected in s−3. While it is high, IQ-FP must not select an FMISC op with an FP destination (FSGNJ, FSGNJN, FSGNJX, FMIN, FMAX, FMV.F.X). Other rows are unaffected, so FMA streams issue every cycle.
  - The core takes it: `tg_iq` gets a class bit per row (FMISC with an FP destination), set at dispatch, and an AND with `fmisc_block` in the ready vector.
  - The alternative, not taken: FMISC FP results write at s+7 like the FMA, with their wakeup at s+4. That makes them effectively 5 cycles, at most −0.09% suite IPC by R5's model.
- **FDIV results take free slots.** In cycle c the divider's result is accepted if slot c+1 is free, then it is written at the end of c+1. Otherwise it waits in the divider's output queue.

**Bypass** (inside `tg_fp_exec`). The selects are made in RF from the tags.
- **RF** takes an F1 load write of its own cycle into the operand register, in place of the register file's value.
- **EX0** then chooses among four sources, one LUT6 per bit:
  - the operand register;
  - the F0 stream of EX0's cycle (EX level) or of RF's (WB level);
  - the F1 load write of EX0's cycle.
- **History:** until AR-8 the F1 write of RF's cycle was a fifth EX0 source (two LUTs per bit).

The F0 write of the next cycle is always known one cycle ahead (FMA and FMISC from the select, FDIV from its claim), and the load path announces F1 writes one cycle ahead (`fld_m2_will`, as for integer loads).

**Wakeup** (`wake_reg`: W set at the end of the cycle). The columns follow the core's layout, with the wakeup tags of AR-1 (plan §4.6; area_recovery.md §5.2):
- columns 0 to NFX − 1 are the fixed-latency producers' tags (NFX = `NCOL − LLT_ENTRIES`: 16 tags; ROB indices before AR-1);
- column NFX + llt is an LLT;
- the payload's `wid` is the column an operation wakes.

`tg_fp_exec` takes NFX from `NCOL`, so it works with either layout.

| Producer | Wakeup column | Fires | Dependants |
|---|---|---|---|
| FMA (all, including the conversions) | tag | s+4 | select at s+5; EX0 at s+7 takes the F0 stream (back to back at `FMA_LAT`) |
| FMISC, FP destination | tag | s+1 (RF) | select at s+2; EX0 at s+4 takes the F0 stream (back to back at `FMISC_LAT`) |
| FDIV/FSQRT | LLT | claim cycle c | select at c+1; RF at c+2 reads F0 |
| FMISC, integer destination | LLT | the core, when it writes B1 | – |
| FP loads (F1) | LLT | the core's LSU | – |

`llt_done` names the FDIV LLTs written each cycle.

**Tags** are the core's:
- Rename allocates them and clears their W column on allocation.
- Rename frees a tag 2 cycles after its op's F0 write, which the completion's `cmp_wid` names. A flushed op writes nothing and never wakes, so the core frees its tag at the flush.
- P4 only carries the tag (`wid`) beside the operation and broadcasts it.

**Integer source** (FCVT.F.I and FMV.F.X):
- `isrc_valid` and `isrc_tag` are presented in RF (s+1), and `isrc_data` is sampled at the end of that cycle.
- The core gives P4 its shared integer read port in that cycle, ahead of the SQ's store-data capture, which it suppresses in that cycle.
- There is no bypass into `isrc_data`. IQ-FP's dependencies on 1-cycle ALU producers resolve only when the producer's row is freed, 2 cycles after its issue, so the FP op reaches RF after the ALU's register-file write.
- This costs 2 cycles on integer-to-FP moves of in-flight ALU results, about 0.4% of FP sources in the census. MUL (tag) and LLT producers wake late enough already.

**FP loads** (F1):
- `fld_valid`, `fld_idx` and `fld_data` write F1 at the end of the cycle. `fld_data` is the value F1 gets: the core's LSU NaN-boxes an FLW value as {0xFFFFFFFF, data[31:0]} before its load result register (3f9a227). `tg_fp_exec` used to do it itself, from a `fld_single` flag; DR-123 dropped the flag and the port.
- `fld_m2_will` and `fld_m2_idx` announce the write one cycle ahead, for the bypass select.
- The core wakes the load's LLT and completes it, as for integer loads.

**FP store data:** the SQ claims `fsd_tag`/`fsd_data` when the value is in the register file, as it does the integer shared port. FSW stores bits 31:0, which the ISA requires without any NaN-box check.

**Integer results (to bank B1).** FEQ, FLT, FLE, FCLASS, FCVT.W/WU/L/LU and FMV.X enter a queue of `FPI_Q` entries (default 4) at s+4, holding {`tid`, `rob`, `wid`/`llt`, `dst_en`, `dst`, `data`, `fflags`}.
- **The hand-off.** The core treats the head like a finished divide on bank 1:
  - it claims a write slot when `fpi_valid` is high, `fpi_kill` is low and the slot is free;
  - it wakes the LLT one cycle before the write;
  - in the write cycle it pulses `fpi_ready`, sampling `fpi_o`, writing B1 (unless `dst_en` is 0) and completing the ROB entry with `fpi_fflags`.
- **The head stays put until `fpi_ready`.** Only `fpi_ready` pops the queue, so the head cannot change between the claim and the write.
- **`fpi_kill`** marks a head whose thread was flushed, including by a flush in this very cycle. The core pops it with `fpi_ready` without a write, wakeup or completion: at any time, or in its claimed write cycle when the flush came after the claim.
- Rename keeps at most `FPI_INFLIGHT` such operations between rename and the hand-off. `fpi_pop` returns one credit per entry leaving the queue.

**Divide and square root:**
- **Queue:** an FDIV takes an entry of a table of `FDIV_Q` entries in RF, which tracks it until its result is written or dropped (so an early retirement can find it from RF on). From EX0 it enters a queue of the same size in front of the divider, which it skips when the queue is empty and the divider is ready.
- **Credits:** rename keeps at most `FDIV_INFLIGHT` divides between rename and their result. That differs from the F/D branch's comment ("rename and the unit"), and it bounds the table. `fdiv_done` returns one credit per divide, written or dropped.
- **Tag:** the divider's tag is the table index.

**Completion to the ROB** (F0 results): one port, `cmp_valid`, `cmp_tid`, `cmp_rob`, `cmp_wid` and `cmp_fflags`. `cmp_wid` (the op's wakeup column) is for rename's tag release.
- It fires in the F0 write cycle for FMA, FMISC FP results, and divides that did not retire early.
- FP operations raise no exceptions.
- The ROB keeps five fflag bits per FP entry and passes them to `tg_fcsr` when the entry retires.

**Flush** (`flush` and `flush_tid`, registered by the core as for `tg_exec`). Every operation of that thread is dropped: no write, no wakeup, no completion. Credits still return.
- **RF, EX0, FMA and FMISC:** shadow valid bits beside the units' fixed latencies; the FPU itself has no kill input (interfaces.md §4).
- **B1 queue:** the thread's entries are marked dead and presented with `fpi_kill` (above).
- **Divides:** the thread's divides that have not retired early are marked squashed and dropped when they leave the divider.

**Early retirement of divides** (plan §4.5; M6). The core reports `fdiv_ret_valid`, `fdiv_ret_tid` and `fdiv_ret_llt` when it retires a divide before its result. Its result still writes F0 and wakes, and flushes no longer squash it, including one in the cycle of its claim or write. Its fflags go to `tg_fcsr` (`er_valid`, `er_tid`, `er_fflags`) instead of the ROB completion, also when the retirement arrives in the write cycle itself. Tie these low until early retirement is on.

**The core's side of the contract**, checked by assertions:
- an FMISC op with an FP destination is not selected while `fmisc_block` is high;
- credits keep at most `FDIV_Q` divides and `FPI_Q` integer results in flight;
- each operation's wakeup column is in its range: a tag below NFX for FMA and FMISC FP results, NFX + llt for divides and integer results;
- a divide does not retire early in a cycle when its thread is flushed. The flush is registered from an older commit, so nothing it kills can retire with it.

Not checkable by an assertion: the F1 load write (`fld_valid`, `fld_idx`, `fld_data`) comes straight from the load result register, with no logic after it, and `fld_data` is already NaN-boxed for FLW. It feeds the F1 bypass into the units' first stage, and the timing below assumes it.
- The core agreed: `fld_data` and `fld_idx` come from the LSU's `r_data_q` and `r_dst_q`, which already drive the integer load bank at WB.
- `fld_valid` is a flip-flop of the same stage.

### `fcsr` (`tg_fcsr`)
- **State per hart:** `frm` and `fflags`.
- **Rounding mode:** `frm_o[tid]` goes to decode, which resolves DYN and flags reserved modes. That is legal at decode because every CSR write ends in a flush. `fp_rm_resolve()` in `tg_fpcore_pkg` does the same check.
- **CSR access:**
  - read is combinational, `csr_rtid` → `csr_fflags`, `csr_frm`;
  - write is `csr_wvalid`, `csr_wtid`, `csr_waddr` (fflags, frm or fcsr) and `csr_wdata`, applied at retirement;
  - the CSR file checks FS ≠ Off and does the csrrs/csrrc arithmetic.
- **Accumulation:**
  - `cm_valid`, `cm_tid` and `cm_fflags` per commit slot (the ROB's per-entry flags);
  - `er_valid`/`er_fflags`, early-retired divides at completion.
- **`er_busy[tid]`:** an early-retired divide of that hart is still pending. Per plan §4.5, a CSR access to fflags or fcsr waits until it clears.
- **`fs_dirty[tid]`** pulses (the CSR file sets mstatus.FS = Dirty) when any of these happens:
  - an FP register is written by a retiring instruction (`cm_fpr`, FP loads included);
  - nonzero flags are accumulated;
  - fflags, frm or fcsr is written.
  This matches Spike.

### Area and timing of the back end

Out of context at 200 MHz, as for the units ("Timing and area"; `TG_OOC_FILES=rtl/core/fpu/fpu_be.f`), v1 configuration (smt2), 2026-10-14. The complete `tg_fp_exec` rows measure the agreed RTL as merged (d8335ca), with the seed ROM on `tg_rom`.

| Module | LUTs | of which LUTRAM | FFs | WNS | Budget line (docs/perf/budgets.md) |
|---|---|---|---|---|---|
| `tg_fprf` (3 operand ports, store data, 2 trace ports) | 1,158 | 880 | 0 | +1.64 ns | register files and bypass (plan §4.7: about 1.3K for the FP file) |
| `tg_fcsr` (two harts) | 46 | 0 | 24 | +1.29 ns | ROB, commit, traps, CSRs |
| `tg_fp_exec` without `tg_fpu` and `tg_fprf` (bypass, F0 stream, wakeups, divide table and queue, B1 queue) | 1,085 | 144 | 626 | — | FP bypass: register files and bypass; the rest: the FPU line's headroom (911 LUTs) |
| `tg_fp_exec` complete (with `tg_fpu` and `tg_fprf`), smt2 | 8,275 | 1,080 | 4,526 | **−0.145 ns** (inside the FMA's E2) | |
| `tg_fp_exec` complete, st | 8,198 | 1,072 | 4,013 | +0.015 ns | |

The per-module split comes from a synthesis that keeps the hierarchy. The trace ports cost 2 × 64 bits of LUTRAM per bank; without them `tg_fprf` would be about 850 LUTs.

**Timing.** Inputs arrive 1.5 ns after the clock, as for the units, except the F1 load write (`fld_valid`, `fld_idx`, `fld_data`) at 1.0 ns (`TG_OOC_IO=tests/unit/fpu/vivado/fp_exec_io.tcl`).
- The core writes the load bank at WB from its load result register ([core-lsu.md](core-lsu.md)), so these ports leave a register. 1.0 ns leaves about 0.9 ns for routing across the core. The contract above requires it.
- **The complete module has no margin at 200 MHz.** The agreed RTL measures −0.145 ns (smt2) and +0.015 ns (st).
  - **smt2's worst path is inside the FMA's E2:** the tile outputs, the row sum and the roughly 120-bit adder, whose sign selects the magnitude (85 loads), into `mag_q`. It has 15 logic levels and 71% of its delay is routing. E3 follows at −0.062 ns.
  - **st's worst paths all lie within 0.1 ns of zero:** the load write into the FMA's E0 (+0.015), the divider's S1 into the seed ROM (+0.021), the FMA's E2 (+0.027) and E3 (+0.09).
  - **Alone, the FMA meets at +0.10 ns.** In this run, placement inside `tg_fp_exec` costs it about 0.25 ns. Across the six runs of the complete module, under either constraint, WNS lies between −0.15 and +0.10 ns.
  - **An earlier estimate overstated the margin.** It re-timed the routed designs of the 1.5 ns runs under the new constraint, which holds placement fixed, and gave +0.02 ns (smt2) and +0.14 ns (st).
  - **Implementation effort:** with the Explore directives (`TG_OOC_IMPL=explore`), the same RTL closes at **+0.020 ns (smt2) and +0.039 ns (st)**. Both are limited by the FMA's E2.
  - **Where E2's time goes** (Explore runs, about 4.93 ns):
    - 0.9 ns out of the DSP tile to the fabric;
    - 0.6 ns in the column counters;
    - 1.5 ns in two chained carry chains, with a 0.65 ns hop between them;
    - 0.8–0.9 ns on one sign net with 165 loads;
    - the magnitude select.
  - **A cheap fix and its limit:** replicating the sign's driver (`max_fanout`) should recover about 0.3 ns there. But E3, the divider's S1 into the seed ROM and the load bypass also sit within 0.1 ns in context, so it does not make margin alone.
- **Default effort, measured** (2026-10-14; main at cb8ff6c with AR-1's 16 tags; the load write at 1.0 ns).
  - **The E2 restructure** (branch `claude/track-fpu-395911-e2`, 6d32453; not merged):
    - X's +1 goes into `s2`'s always-zero bit 0, so both low sums are pure three-operand adds, one carry chain each instead of two in series;
    - the ~Y select is replicated (`max_fanout`).
  - **Standalone FMA:** +0.315 ns against +0.103 for the baseline in the same flow, for +118 LUTs (2,491 against 2,373). E2 leaves the 30 worst paths, which now all run from the request into E0. TestFloat long regression: 177/177.
  - **In context:**

    | `tg_fp_exec` | smt2 | st |
    |---|---|---|
    | main | +0.092 ns (divider S1 → ROM) | −0.008 ns (FMA E2) |
    | with the E2 restructure | −0.125 ns (divider S1 → ROM) | +0.035 ns (seed ROM → DSP) |

  - **The restructure fixes E2,** but the module still does not close reliably at default effort. In the failing run, five groups sit at or below +0.02 ns:
    - the divider's S1 → seed-ROM address (−0.125): 9 LUT levels, 75% routing, and 0.47 ns of block-RAM address setup;
    - FMISC's FCVT.I.F (−0.10);
    - the seed ROM → DSP routes (−0.02);
    - FMA E3 (−0.02);
    - EX0's bypass select into FMA E0 (+0.02).
  - **Placement decides which group fails.** Each has 0.16–0.40 ns in its unit's own run, and placement in the combined module costs 0.2–0.3 ns.
  - **Floorplan test** (`TG_OOC_IO` with `tests/unit/fpu/vivado/fp_exec_pblock.tcl`): main's RTL, confined to the smallest clock-region block that holds its DSPs, block RAM and slices at 60% fill. That is two stacked regions, X1Y0 and X1Y1; no single region holds it.
    - **It closes at default effort in both configurations:** +0.113 ns (smt2, limited by the load write into FMA E0) and +0.100 ns (st, limited by the divider's seed-ROM address).
    - **LUTs fall too:** 8,017 and 7,960, against about 8,200–8,275 unconstrained, because implementation replicates less.
  - **Options for default-effort closure:**
    - **Floorplan P4** (a pblock in the full-chip flow): measured above, with no RTL change and no IPC cost. This is the recommended route.
    - **Seed-ROM address register in the fabric:** this removes the block-RAM setup from S1, but costs one divider cycle (FDIV/FSQRT 20/24/20/28). Divides complete through LLTs, so the IPC effect should be negligible; it is still an IPC cost, a report item under D18.
    - **The E2 restructure:** only together with the above, since alone it moves the failure elsewhere.
- Under the uniform 1.5 ns, the worst path is the F1 load bypass into the FMA's E0: 11 LUT levels from `fld_data` through the bypass multiplexer and the FMA's classification of the addend. It moves with placement: smt2 +0.05 and −0.09 ns, st +0.01 and +0.10 ns. These are two runs each, before and after the last timing change and the ROM change, neither of which touches this path. Every failing path of the −0.09 ns run starts at `fld_*`; its worst internal path is +0.02 ns (the FMISC's FCVT.I.F).
- Two changes made it close:
  - the F0 stream's data is selected by the registered slot owners only (the first version failed by 0.56 ns on flush and early-retirement inputs feeding the bypass);
  - the divide claim and the F0 write enable use the registered retired bit only, which removed a path at +0.09 ns.
- The wakeup decoders cover only their own ID range (ROB or LLT columns): −116 LUTs.
- **Flip-flops:** synthesis gives 3,868 to 3,907 in every run. The routed counts above are higher by 70 to 620, from register replication during implementation, and vary from run to run.
- **Primitive check:** the seed ROM, both register-file banks (55 RAM64M8 each) and the queues pass.
  - **Until 5a31536,** the check after synthesis flagged the divider's output queue inside `tg_fp_exec`: 8 RAM32M16 found, 7 expected. 31 of its 102 bits were never read: `int_dest` and 30 tag bits, since P4 uses only 2. Synthesis kept one primitive whose read bits were all unloaded; `opt_design` removed it.
  - **Fixed at the source:** the queue now keeps only the bits P4 reads (`DIV_TAG_W`).
  - **Confirmed by synthesis** of the fd2 merge: the check after synthesis passes in smt2 and st. The queue is 71 bits in 6 RAM32M16, 2 fewer than before. Standalone `tg_fpu` stores 101 bits in 8 and passes too.

### Helpers (`tg_fpcore_pkg`)
- `fp_rm_resolve(rm_field, frm)`: the rounding mode and legality, Spike's RM rule.
- `FPTAG_W`, the width of an FP tag. The tag helpers themselves are in `tg_core_pkg` (above).

## Parameters

No configuration parameter changes the FPU: the four configurations (`st`, `smt2`, `st_w3`, `smt2_w3`) build the same units. `FPU_TAG_W` comes from `tg_pkg`. SMT is invisible to the FPU (the tag carries everything; the divider's slots are shared by both harts).

## Timing and area

Out-of-context synthesis and implementation per unit (`tests/unit/fpu/vivado/ooc.tcl` through `tools/vivado_run.sh`), Vivado 2025.2, xck26-sfvc784-2LV-c, 5.0 ns clock, request inputs arriving 1.5 ns after the clock (the core's operand bypass), outputs needed 1.0 ns before the next edge. Routed results, 2026-10-13, after R5 and the LUT pass:

| Unit | LUTs | FFs | DSP48E2 | RAMB18 | WNS at 200 MHz | Latency | Budget (plan §8.2) |
|---|---|---|---|---|---|---|---|
| FMA, 5 stages | 2,373 | 1,150 | 6 | 0 | +0.10 ns | 5 | ≈ 2.5K LUTs, 10–14 DSPs |
| FMISC | 863 | 347 | 0 | 0 | +0.40 ns | 2 | (part of the 4.7K FPU) |
| Divide/sqrt, Goldschmidt (v1, D17) | 2,653 | 2,262 | 29 | 1 | +0.15 ns | 19/23 div, 19/27 sqrt | ≈ 1.2K LUTs (radix-4 + 0.2K), 24 DSPs, 1 BRAM18 |
| Divide/sqrt, radix-4 fallback | 1,617 | 899 | 0 | 0 | +0.59 ns | 18/33 div and sqrt | (the plan's fallback) |
| **FPU with Goldschmidt** | **5,889** | 3,759 | 35 | 1 | met | | **≈ 4.7K LUTs**; nightly budget 6,800 |
| **FPU with radix-4** | **4,853** | 2,396 | 6 | 0 | met | | **≈ 4.7K LUTs** |

**All units meet 200 MHz.** The critical paths are: FMA E3 (normalisation: leading-zero count, then the shift) and E2 (the tile outputs into the adder), FMISC M1 (the FCVT.I.F shift and rounding), Goldschmidt S1 (normalise, then the seed-ROM address) and the seed into SMa, radix-4 UNP/NRM (normalise).

**LUT pass** (2026-10-13, plan §8.5 step 1: no latency or function change). Each run includes the changes above it, so a row's change also carries synthesis variation of a few tens of LUTs (the counter change alone measured +126, and the next change −302):

| Unit | Change | LUTs | WNS |
|---|---|---|---|
| FMA | after R5 | 2,883 | +0.08 ns |
| FMA | control pipeline in flip-flops, not shift-register LUTs | 2,809 | +0.29 ns |
| FMA | emin marker as the AND of two small one-hots | 2,797 | +0.27 ns |
| FMA | sticky-only window below emin; exact zero found in E4 | 2,710 | +0.15 ns |
| FMA | one packing adder for S and D | 2,730 | +0.15 ns |
| FMA | addend complement in the column counters; tiles dropped by the P-register reset | 2,856 | +0.28 ns |
| FMA | one incrementer above bit 112 | 2,554 | +0.02 ns |
| FMA | special results as a kind and a sign | 2,530 | +0.22 ns |
| FMA | rows sum as one ternary add | 2,530 | +0.22 ns |
| FMA | FCVT.F.I without a negation | **2,373** | +0.10 ns |
| FMISC | after R5 | 1,002 | +0.51 ns |
| FMISC | raw operands and a boxing flag; FCVT.I.F sticky from the shift stages | **863** | +0.40 ns |
| Divide/sqrt | after R5 | 3,125 | +0.39 ns |
| Divide/sqrt | ring and pipeline in flip-flops, not shift-register LUTs | 2,979 | +0.06 ns |
| Divide/sqrt | smallest tiles in DSPs (+3); rounding sticky from the shift stages | 2,670 | +0.17 ns |
| Divide/sqrt | 5·e2hi in the SMc pre-adder | **2,653** | +0.15 ns |
| Radix-4 | rounding sticky from the shift stages (shared `tg_fpu_div_round`) | 1,714 → **1,617** | +0.59 ns |

**Seed ROM on `tg_rom`** (DR-070, after the pass): the divider is 2,651 LUTs at +0.16 ns with one RAMB18. That is neutral, and the primitive check now counts the ROM instead of reporting a stray block RAM.

**Measured but not adopted:**
- **Area-optimised synthesis** (`AreaOptimized_high`, `TG_OOC_DIRECTIVE`): FMA 2,331 (−42, +0.25 ns), FMISC 738 (−125, +0.13 ns), divider 2,532 (−121, but −0.19 ns: fails). Worth applying to the FMA and FMISC as a per-module synthesis strategy in the full-chip flow (−167 LUTs), not to the divider.
- **FADD/FSUB's second operand in `c`:** the FMA drops its b/c operand multiplexer, −92 LUTs. Built in AR-8: P4 reads rs2 into `c` (−60 LUTs measured).
- **The single packing adder** measured −12 LUTs against two adders at the final state, within run-to-run variation; kept.
- **Not possible at 200 MHz without a latency change:** the alignment shift as a DSP multiply by 2^k (its one-hot would be decoded at the end of E0, which is near-critical, or the DSP output would feed two more LUT levels in E1); the adders into DSP ALUs (E2 and the divider's c3 need their full results in the same cycle); sharing the divider's two S1 normalisers (one normaliser can serve both operands only if requests are accepted every other cycle, a throughput change).

**Lever R5, measured** (same flow and constraints, routed):

| Unit | Before R5 | After R5 | Change |
|---|---|---|---|
| FMA | 2,670 LUTs, 982 FFs, WNS +0.34 ns | 2,883 LUTs, 1,040 FFs, WNS +0.08 ns | +213 LUTs, +58 FFs |
| FMISC | 1,827 LUTs, 515 FFs, WNS +0.25 ns | 1,002 LUTs, 416 FFs, WNS +0.51 ns | −825 LUTs, −99 FFs |
| FPU with Goldschmidt | 7,622 LUTs | 7,010 LUTs | −612 LUTs |
| FPU with radix-4 | 6,211 LUTs | 5,599 LUTs | −612 LUTs |

- The FMA grows by the source-format decode in E0, the 64-bit integer register, its negation and the addend-operand multiplexer in E1, and the product gate in E2. E3 and E4 are unchanged.
- The FMA's critical path is still E3, with the same 11 logic levels; its slack is smaller because that path routes longer (3.10 ns of route against 2.85 ns).
- FMISC loses 825 LUTs, more than the 584 estimated before the change. The estimate only zeroed the two results and so kept the shared shifter's operand selection and bit reversal; FCVT.I.F now has a right shifter of its own.
- FP→FP and integer→FP conversions now take `FMA_LAT` = 5 cycles instead of `FMISC_LAT` = 2.

**Four-cycle FMA.** Measured before R5: with the E3/E4 boundary removed (`STAGES = 4`) the FMA misses by 1.88 ns (≈ 145 MHz, 26 logic levels from the marker register through LZC, shift, rounding and packing to the response) and grows to 2,971 LUTs. It costs Fmax, so `FMA_LAT` stays 5 (plan §4.12). R5 adds nothing to E3 or E4, so the result stands.

**Area against the budget.** The FPU is 5,889 LUTs with the Goldschmidt unit: under the nightly budget of 6,800 (docs/perf/budgets.md), 1.2K over the plan's 4.7K estimate; 4,853 with radix-4.
- **Divider.** The Goldschmidt unit costs 1,036 LUTs (and 29 DSPs and a BRAM18) more than the radix-4 unit, not the plan's +0.2K. The user kept it for v1 (decision D17, plan §4.12): `FDIV_RADIX4` = 0, and the radix-4 unit stays built and in the regression as the fallback.
- **Levers:** R5 (−612 LUTs) and the LUT pass (−1,121 LUTs) are built; R4 is assessed and parked (section above).
- **FMA** is 127 LUTs under its own estimate after the pass.
- **Flip-flops and DSPs** went over their budget lines with the pass. The nightly synthesis at d04ae26 measures 3,733 FFs against 3,450, and 35 DSPs against 32. The pass moved the pipelines from shift-register LUTs into flip-flops, and the divider's smallest tiles into DSPs (+3).
  - DR-110 raised the lines to 4,100 FFs and 35 DSPs: LUTs are the binding resource, and D18 favours trading LUTs for flip-flops and DSPs.

**Fallbacks not needed:** an LZA in the FMA (E3 meets timing without it), `FMA_LAT` = 6, the radix-4 unit for timing.

## Verification

Tests live in `tests/unit/fpu/` (Verilator, C++ testbench `tb_fpu.cpp` on `tg_fpu`), exit non-zero on failure, print and accept their seed, and have `short` and `long` modes:

| Command (after `source tools/env.sh`, in `tests/unit/fpu`) | What runs |
|---|---|
| `make model` | the bit-accurate divider models against SoftFloat (`gs_check`, `r4_check`) |
| `make test` | short regression, about 30 s with 8 jobs: TestFloat level 1 for every function, mode and format (mulAdd: 1.5M vectors per mode), directed divide/sqrt cases, random traffic on all units |
| `make test-long` | level 2 for every function, mulAdd level 1 complete plus a level-2 prefix of 2·10^7 vectors per mode and format, longer directed and random runs (23 minutes with 6 jobs on 2026-10-13: 2.6·10^9 results) |
| `make tb DIV=r4`, `make test DIV=r4` | the same on the radix-4 fallback |
| `make test-be CFG=…` (`DIV=r4`), `run_be_tests.sh short\|long` | the FP back end (below), with `-j16` |

The testbench takes every latency from `tg_fpu_pkg` (FMA and FMISC exactly; the divider exactly when `fdiv_ready_i` is never low), so it checks the RTL against the constants the core uses.

- **Reference model:** Berkeley SoftFloat 3 built with the RISC-V specialization (canonical NaN, RISC-V conversion limits, tininess after rounding), linked into the testbench; RISC-V-specific behaviour on top of it written from the ISA manual: NaN boxing, FMIN/FMAX 2.2, FCLASS, sign injection, moves, int_dest and sign extension.
- **TestFloat:** `testfloat_gen` vectors piped into the testbench for every function, both formats and all five rounding modes:
  - level 1 for every operation;
  - level 2 for add, sub, mul, div and sqrt (complete), and for mulAdd as a long prefix: complete level 2 is 1.5·10^10 (S) and 1.8·10^11 (D) cases, beyond simulation; the prefix length is reported with the results;
  - FMSUB, FNMSUB, FNMADD and FSUB reuse the mulAdd/add vectors with the operand signs flipped (exact identities: FMSUB(a, b, −c) = fma(a, b, c) and so on).
  - The testbench routes every vector with the same rule as `fpu_unit_of`, so the FP→FP and integer→FP conversion vectors run on the FMA and are checked at `FMA_LAT`.
- **Directed divide/sqrt cases** for the remainder correction: quotients and roots constructed to lie within 2^−2p of a midpoint or of a representable value, exact quotients and roots, results at the subnormal boundary (Eq = emin − 1), overflow edges, every seed-ROM interval endpoint.
- **Pipelining:** back-to-back FMA and FMISC operations every cycle with random precision, op and rounding mode; the divider fed at full rate with mixed S/D divide and sqrt, random `fdiv_ready_i` backpressure, checking tags, order independence and that every accepted request produces exactly one response.
- **Interleaving:** all three units driven at once with random traffic.
- **Assertions** (Verilator `--assert`): FMT_H never requested; requests routed to the right unit; no divider slot collision; output-queue credits in step and never exceeded.
- **Models:** `gs_model.h` and `r4_model.h` are bit-accurate models of the two dividers; `gs_check` also measures the Goldschmidt approximation error against its budget, including both ends of every seed-ROM interval.
- **Lockstep** (core track, later) compares FP results through the commit trace; `fflags` are compared only where software reads them (interfaces §5).

**The FP back end** (`tb_fpx.cpp` on `tg_fp_exec` through the wrapper `tb_fpx_top.sv`; `tb_fcsr.cpp` on `tg_fcsr`; every configuration, and the radix-4 divider):

The bench models the core's side of P4:
- the woken vector, filled only from `wake_reg`, so a wakeup that fires early makes a consumer read a stale value;
- physical-register, ROB and LLT pools, the divide and integer-result credits, and `fmisc_block`;
- AR-1's wakeup tags: 16 (or fewer, `-tags`), taken at select, freed 2 cycles after the F0 write or at a flush, so tags are reused at once;
- F1 loads announced through `fld_m2_will`, and the integer source port;
- the bank-1 arbiter: it claims a live head, writes it 1 to 4 cycles later, and pops killed heads without effects.

It checks, against the SoftFloat-based reference:
- every F0 write, at its exact cycle (FMA s+7, FMISC s+4, divides one cycle after their wakeup), and its value through a trace port the next cycle;
- every completion with its flags and `cmp_wid`, every wakeup at its exact cycle, `llt_done`;
- every B1 record (value, flags, destination, IDs) in queue order; `fpi_kill` exactly on flushed entries; the head unchanged from claim to write; pops only on `fpi_ready`;
- random store-data reads.

| Run | What it covers |
|---|---|
| `rand` | random FP streams with dependencies through both bypass levels. Three stress settings: no flushes; a flush per ~150 cycles with 20% early retirement and 60% claims per cycle; a flush per ~40 cycles with 40% and 30%, and only 4 tags |
| `tf` | TestFloat level 1 for every function. Operands go through F1 loads (FP) or the integer source port, results through F0 or the B1 queue |
| `tb_fcsr` | CSR writes of the three views, commit and early-retired accumulation, `er_busy`, `fs_dirty`, every cycle |

Review and the bench found three errors in `tg_fp_exec`, all fixed:
- a B1-queue entry pushed in a flush cycle could inherit its slot's previous occupant's dead mark;
- a divide that retired early was still dropped when its thread was flushed in its claim or write cycle;
- a divide that retired in its own write cycle completed to the ROB entry it had just left, not through the early-retirement port.

## History and lessons

**Starting point** (M1, merged 2026-10-13 as 9e861b2). The spec and a bit-accurate Goldschmidt model came first: 161M cases matched SoftFloat, with a worst error of 2^−56.1 against a 2^−54 budget. The RTL followed: the FMA (5 stages), FMISC, the Goldschmidt divide/sqrt unit and the radix-4 fallback.
- **Verification:** SoftFloat and TestFloat, 2.6·10^9 results in the long run.
- **Timing:** all units at 200 MHz. Getting there took a staged normaliser in the FMA's E3, and a third rounding stage (F2) in the divider, which added one cycle to every divide and square-root latency.
- **Area:** 7,622 LUTs with the Goldschmidt unit (FMA 2,670, FMISC 1,827, divider 3,125), against the plan's 4.7K.

| Step | FPU LUTs (Goldschmidt) | What it bought |
|---|---|---|
| As built | 7,622 | The Goldschmidt unit is 1,411 LUTs more than radix-4, not the plan's +0.2K (below). The user kept it for its latency (D17). |
| R5: FP→FP and integer→FP conversions on the FMA | 7,010 | −612 (FMISC −825, FMA +213), at most −0.09% IPC |
| LUT pass, no latency or function change | **5,889** | −1,121 (FMA −510, FMISC −139, divider −472), under the nightly 6,800. WNS afterwards: +0.10 ns (FMA), +0.40 ns (FMISC), +0.15 ns (divider). |
| Back end for F/D (P4) | units unchanged | `tg_fprf` 1,158 LUTs, P4 logic 1,085, `tg_fcsr` 46. The complete `tg_fp_exec` sits at 200 MHz with no margin: the agreed RTL measures −0.145 ns (smt2, inside the FMA's E2) and +0.015 ns (st), and runs vary between −0.15 and +0.10 ns. With the Explore directives it closes at +0.020 and +0.039 ns. Floorplanned into two clock regions, it closes at default effort at +0.113 and +0.100 ns. |
| Seed ROM on `tg_rom` (DR-070) | 5,889 | Neutral: the divider is 2,651 LUTs at +0.16 ns. The primitive check counts the ROM. |
| AR-8 no-IPC pass on P4 (step 1) | FMA −55 | FADD/FSUB's rs2 into `c` (the FMA's b/c multiplexer goes) and a four-source EX0 bypass. Budget flow (`-flatten none`): P4 7,954 → 7,823 (st), 7,977 → 7,846 (smt2), −131. Out-of-context synthesis with `rebuilt` flattening had shown −281/−239: it optimises across module boundaries, so it overstates. FMA slack +0.103 → +0.159 ns. Floorplanned P4 still closes at default effort (+0.096 and +0.056 ns). |
| DR-123 FPGA-native pass on P4 (step 2) | P4 −113 | The FMA's hi + 1 in 2 DSPs (−54), the divider's e0 subtraction in its SMa tile (−38) and the remainder's sign from a 38-bit subtraction (−22). Budget flow, standalone: P4 7,386 → 7,273 (st), 35 → 37 DSPs. Floorplanned P4 closes at default effort (+0.130 and +0.089 ns). Details below ("DR-123, FPGA-native pass"). |
| DR-123, P4 step 3 | P4 −16 | The core's LSU NaN-boxes FLW before its load result register (core track, 3f9a227), so P4 drops its boxing multiplexer: `fld_data` goes straight into F1, the RF-stage capture and the EX0 bypass, one LUT level shorter. `fld_single` is ignored until the core drops the port. Budget flow: P4 7,273 → 7,257 (st), 7,294 → 7,278 (smt2). Floorplanned P4 closes at default effort (+0.089 ns smt2, +0.073 ns st); cycle-identical to main f46d871 (`make cycle-identical`, 798 of 798 programs in each configuration). |
| DR-123, P4 step 4 | P4 −59 | The FP register file's bank select folds into the RF-stage operand multiplexer (one encoded 4:1 per port: bank 0, bank 1, the F1 write, the integer source), −28; FMISC's result is one encoded select per bit over a, b, the FCVT.I.F sum, the two sign-extension bits and a constant word, in place of three multiplexers in a row, −31. Budget flow: P4 7,257 → 7,198 (st), 7,278 → 7,219 (smt2). Floorplanned 200 MHz: +0.097 ns (smt2), +0.067 ns (st). Measured and not taken (T1/T4): the divide table and the B1 queue have 4 entries (about 35 and 10 LUTs of flip-flop logic; the B1 payload is LUTRAM already), and an SRL FIFO counts more LUTs before placement than LUTRAM (spikes' table, fpga_friendly.md §3.1). |
| DR-123, execute step 2 | execute −17 | The divider's NM amount is `nz ? 64 : ~(lzd − lza)` on the original shifter (+58 against main's form, where the form that kept r and q at n = 0 was +75), and FX goes back to its original select. Execute 7,892 → 7,875 (st and smt2); it closes 200 MHz at +0.116 ns (st, the NM step now the worst path) and +0.033 ns (smt2). |
| DR-133, execute's UltraRAM operand ports (behind `IRF_URAM`, default 0) | execute −597 when on | The 4 ALU operand ports read URAM copies of the register file: one per bank and port (12 URAM per core at N_ALU = 2), written like the banks and addressed in IS from tg_iq's `payload_sel` (the new inputs `is_src1`/`is_src2`, tg_issue's export, 748a133 on the core track's branch), so the data arrives in RF as the LUTRAM's does. The URAM read is read-first, so the write of the cycle before RF comes from that write's registers, picked once per port; one 4:1 per bit then selects the source's bank or that write. `tg_irf` keeps the other 5 ports. Gates (DR-133): (1) cycle-identical with the switch on, 798/798 in st and smt2 (and a mutant without the bypass mismatches on 262 of 293 riscv-tests), `make regress` passes; first on a local prototype of the core's port, then again on the core track's export (`is_src1`/`is_src2`, fn2 2952dbd, with u_ex wired in tg_core): 798/798 in st and smt2, and with execute step 3's RTL on fn2 65dce2e (base main f0a1207): 798/798 in st and smt2; (2) out of context next to a URAM column (`exec_pblock.tcl`, `exec_uram_io.tcl` with the tags at 2.5 ns): +0.019 ns (st), +0.002 ns (smt2), floorplanned into X2Y0–X2Y1 (12 URAM sites); (3) the full-chip placement check: asked of spikes-2 on a test branch with the switch on (claude/track-fpu-395911-dr133-gate3, not for merging). Budget flow: 7,875 → 7,278 LUTs (st), 12 URAM; a first form of the bypass (a 6:1 per bit) gave 7,532. |
| DR-123, execute step 3 | execute −350 | Four changes, each cycle-identical (798/798 in st and smt2 against main f0a1207), measured in sequence: the integer divider aligns the divisor in NM, d = \|b\| << (n − 1), with one 64-bit shifter, where {r, q} = \|a\| << (64 − n) needed a 128-bit shift, and sets x / 0's all-ones quotient there, so FX has no override (−208); the Zbb unit's clz/ctz on `tg_fpu_lzc` and cpop as a tree of 6-bit group counts (−23); res_q[0] held at zero through the reset sequence, so bank 0's zero writes need no multiplexer (−31); the branch target's select in front of the JALR adder, which adds zero to the decoded target (−88). Execute 7,875 → 7,525 (st), 7,524 (smt2), 85 under its 7,610 with `IRF_URAM` off. 200 MHz: +0.163 ns (st), +0.204 ns (smt2), the worst paths now the shared read port's I/O. |
| DR-123, P4 step 5 | P4 −64 | The reset sequence's zero writes take the F0 write port: the zero and its index fold into the F0 stream's multiplexers, and `tg_fprf` loses its init port with both banks' zero multiplexers. `init_bank` must be 0 (asserted; the core ties it to 0), and the back-end bench zeroes F1 registers through the load port. Budget flow: 7,198 → 7,134 (st), 7,219 → 7,156 (smt2). Floorplanned 200 MHz: +0.069 ns (st), +0.117 ns (smt2). |

**What Goldschmidt really cost, and why.**
- **The estimate:** about the radix-4 unit's LUTs plus 0.2K, on the reasoning that its multipliers are DSPs.
- **As built:** 3,125 LUTs against radix-4's 1,714, and 26 DSPs against 24 planned.
- **Why:** the logic around the DSPs is LUTs. In the as-built breakdown, 2,066 LUTs sit outside the multipliers and the shared rounding:
  - the ring's operand multiplexers into two 60 × 60 multipliers;
  - the c3 adders and the correction terms;
  - a normaliser for each operand in S1;
  - the remainder round.
- On top of that, each multiplier spends 259 LUTs summing the tiles the DSP cascade does not cover.
- **The LUT pass** brought it to 2,653: pipelines in flip-flops, the smallest tiles in DSPs, and the pre-adder.

**Dead ends:**
- **A 4-cycle FMA:** misses 200 MHz by 1.88 ns (about 145 MHz). Without the E3/E4 boundary, one cycle must hold the leading-zero count, the normalising shift, rounding and packing: 26 logic levels from the marker register to the response.
- **Area-optimised synthesis:** −167 LUTs on the FMA and FMISC, but the divider then fails timing. Left as a per-module strategy for the full-chip flow.
- **Not possible at 200 MHz without a latency or throughput change:** the alignment shift as a DSP multiply, the adders in DSP ALUs, and one S1 normaliser shared by both operands.
- **R4** (integer divide on the Goldschmidt unit): only 0.15–0.4K saved per core, against the plan's 0.4–0.6K. Parked.
  - **Divider growth:** an integer quotient needs 2^−64 accuracy instead of 2^−56. That means wider iteration values, one more Newton round, a stage for signs and W forms, a variable-grid remainder round and the REM fix-up: about +1K LUTs and +6 DSPs.
  - **Core glue:** the core keeps an arbiter and the result routing.
  - **Alternative:** a cheaper early-out normaliser in `tg_div` would capture most of the saving without R4.

**Bugs found by the back-end bench:**
- three errors in `tg_fp_exec` before merge (list under "Verification");
- one wrong assertion: the `fmisc_block` check looked one cycle early;
- more errors in the bench's own model of the core than in the RTL.

**Interface agreement (2026-10-14).** The core track's review brought AR-1's wakeup tags (columns are tags, not ROB indices), the completion's `wid` for tag release, the B1 head held until `fpi_ready` with `fpi_kill`, and the load write from a register.
- The bench now recycles 16 tags (4 in one stress setting) and models the bank-1 arbiter's claim, hold and write.
- Three mutations are each caught at once: a wrong `cmp_wid`, the old B1 head that left on a flush, and a flushed FMA that still wakes its tag. The last woke a reused tag's new consumers two cycles early, which is the hazard tag reuse creates.

**AR-8, Execute** (`rtl/core/exec`, handed over by the core track on 2026-10-14). Measured with the budget flow (`unit_synth.tcl`, `-flatten none`) and checked cycle for cycle against the previous build (`cyc_cmp.py`):
- **The Zbb unit on P1** (clz, ctz, cpop, min/max, in the MUL slot):
  - clz and ctz share one leading-zero count: ctz is the clz of the bit-reversed value, and the W forms put ones beside the low word;
  - min/max use ALU1's compare flags, with its adder set to subtract for them in RF, instead of a comparator of their own.
  - `tg_exec`: 8,722 → 8,550 LUTs (st), 8,727 → 8,555 (smt2).
- **Cycle-identical:** st and smt2 each match the previous build on every passing ELF: 310 riscv-tests, CoreMark/Dhrystone and directed tests natively, 309 under memory stress, and 895 ACT4 tests.
- **A new directed test,** `tests/isa/directed/zbb.S`, covers the bit counts and min/max in lockstep. The random generator has no Zbb, so riscv-tests' `rv64uzbb` was the only coverage before.
- **The divider's leading-zero counts** use `tg_fpu_lzc`, the FPU's two-level tree, instead of a loop: 1,315 → 1,188 LUTs. In context the loop cost far more than the 71 against 57 of an isolated test.
- **Execute after both steps:** 8,722 → 8,423 LUTs (st), 8,727 → 8,428 (smt2), against 7,610.
- **Divider timing.** The divider's NM step is its critical path: two leading-zero counts, then the 128-bit shift, in one cycle.
  - Alone at 200 MHz it measures +0.088 ns with the loop counts and +0.117 ns with the tree.
  - In one out-of-context run of the whole `tg_exec` it fell to −0.365 ns; another run of the same RTL did not show it.
  - So it depends on placement whichever count it uses. It belongs on the timing list with the floorplan.
- **Dead ends, measured and reverted:**
  - one shift mask for both directions in `tg_alu`: −5 and −0 LUTs;
  - `bext` from the rotator: +1;
  - the tree count in the Zbb unit: +77, because with `-flatten none` synthesis can no longer fold the bit-reverse multiplexer into the count.
- **What is left is structural:** the register file (2,568: 9 read ports over 3 banks), two ALUs (≈1.17K each), the divider (1,315), and an 8-source bypass.
- **Options that cost IPC** (estimates, not proposed): each needs the core's issue logic to change, so neither has a measured cycle cost. Execute is under its budget since step 3, so neither goes on the reserve list (DR-135: only the user adopts a lever that moves a cycle, one at a time, on its measured cost per suite):
  - dropping the write-back level from the load/store base bypass: about −128 LUTs;
  - unary and single-bit Zbb/Zbs ops on one ALU only: about −200 to −300.
- **The trace read ports** move no cycle; dropping them is DR-121's reserve: −584.

**DR-123, FPGA-native pass** (P4 and Execute, 2026-10-14, zero IPC).
- **Method:**
  - Areas come from the budget flow (`unit_synth.tcl`, `-flatten none -directive AreaOptimized_high`, DR-113), each unit synthesised alone.
  - Timing is out of context at 200 MHz (`ooc.tcl`, default effort): P4 with its DR-119 floorplan, Execute with the load result arriving 1.0 ns after the clock (`exec_io.tcl`, the same assumption as P4's load write).
  - Every change is cycle-identical to HEAD bf914f1. `cyc_cmp.py` compares simulators built from both on 310 ELFs natively, 309 under memory stress and 895 ACT4 tests, in st and smt2. The stressed `tanager-p-amo` fails identically on both, from its LR/SC retry bound (fixed on fd2).

| Unit | Change (technique) | LUTs (st) | DSPs | Notes |
|---|---|---|---|---|
| FMA (P4) | E2's hi + 1 above bit 112 in 2 DSPs, fed by their own copy of E1's addend register (T6) | −54 | +2 | The XOR of an effective subtraction shares the addend's OR LUT in E1. |
| Divider (P4) | 2^44 − x·y0²[16:0] in the SMa low tile's own ALU, so only (that >> 17) − hi is left for LUTs (T6, on a DSP already there) | −38 | 0 | |
| Divider (P4) | F0: the remainder's sign and zero test from a 38-bit subtraction with the low 58 bits' borrow, not a 96-bit subtraction (T7) | −22 | 0 | A first version compared the truncated halves as plain numbers and lost the modular wrap; the back-end bench caught it (3,050 errors in f32_div). |
| ALUs (Execute) | the logic ops and lui go through the adder, and the result is an encoded 4:1 select (T7) | −61 | 0 | 1,017 and 995 → 983 and 968 |
| MUL (Execute) | M3's select folded into the bank-1 write multiplexer (T7) | −64 | 0 | +64 flip-flops: M3 now holds the whole product |
| Branch unit (Execute) | pc + 2 or 4 in 2 DSPs holding their own copy of the RF → EX register (T6) | −50 | +2 | |
| Zbb unit (Execute) | the bit counts and min/max computed a cycle later, since their result waits two cycles anyway | 0 | 0 | +64 flip-flops; takes the load bypass, the count and ALU1's flag out of one cycle |
| Divider (Execute) | NM: the shift amount ~(lzd − lza), with no adder in front of the shifter; with no quotient bits, r and q keep their values and FX picks the remainder | +75 | 0 | timing |
| Branch unit (Execute) | the misprediction test as taken ? target ≠ pred : seq ≠ pred, not after the next-PC multiplexer | +52 | 0 | timing |

- **P4:** 7,386 → 7,273 LUTs (st) and 7,407 → 7,294 (smt2), with 35 → 37 DSPs. Floorplanned, it closes at default effort at +0.130 ns (smt2) and +0.089 ns (st), against +0.113 and +0.100 before.
- **Execute:** 7,944 → 7,892 LUTs (st) and 7,925 → 7,892 (smt2), with 16 → 18 DSPs.
- **Execute timing:**
  - Before: HEAD fails 200 MHz in st by 0.286 ns over 159 endpoints. The failing paths were the Zbb unit from the bypass, ALU0 from the load result, the divider's NM step and the misprediction test.
  - After: +0.025 ns (st) and +0.006 ns (smt2), with no failing endpoint. The worst paths are now the shared store-data read port, combinational from `sd_tag` through the register file to `isrc_data` and `sd_data`, which the out-of-context I/O delays decide.
- **Measured and not adopted:**
  - The divider's F2 pack adders in DSPs saved 4 LUTs for 3 DSPs, and c − grid saved 14 for 2. Incrementers and constant adds already cost almost nothing beyond their carry chain.
  - ALU variants:
    - a hand-instantiated CARRY8 chain, with propagate and generate per bit from a 3-bit mode: +129 per ALU alone, 0 in context;
    - the logic ops in front of the adder alone: +212;
    - a funnel shifter instead of the rotator and mask: +43.
    - All passed the equivalence bench (3 million vectors against the old ALU, with Xilinx's CARRY8 model for the explicit chain).
  - The divider's NM as two 64-bit shifts: +185. One shifter with the amount `nz ? 64 : ~(lzd − lza)` measured +58 in context, 17 below the adopted form (+75, verified end to end first): taken in execute step 2, then replaced by the divisor alignment of step 3.
  - Step 3: the misprediction test back to next PC ≠ predicted saves 23 LUTs, but the slack falls from +0.16 to +0.03 ns; the ALU with the W extension as a fourth source above bit 31 (+3 alone), bit masks from the rotator (+99) or a funnel shifter (+58); x / 0 as q = 1 negated (+97 alone); P4's F0 source as an encoded select with the zero as a fourth state (−4, noise).
- **What is left:** after P4 step 5 and execute step 3 (the history table above), P4 is 334 (st) and 356 (smt2) over its 6,800, and Execute 85 (st) and 86 (smt2) under its 7,610. The big blocks are:
  - LUTRAM register files, sized by their read ports (2,568 and 1,143);
  - the FMA's adder tree and normaliser, which must finish within E2 and E3;
  - the divider's operand multiplexers into two 60 × 60 multipliers;
  - two 1-cycle ALUs.
  - The remaining levers cost IPC or are the coordinator's reserve: the options above, and DR-121's trace ports. For P4 these are its URAM operand ports (DR-133's reserve, about −240) and its two trace read ports per bank (an estimated −290 LUTRAM, from 55 to 37 RAM64M8 per bank, and −128 LUTs of bank select).
- **Lessons:**
  - **Adders are not equal in the budget's count.** An incrementer or a constant add costs almost nothing beyond its carry chain, so moving it into DSPs saves little (−4, −14). An adder whose operand bits come from LUT logic saves about a LUT per bit (hi + 1 of an XOR: −54; pc + 2 or 4: −50).
  - **DSP inference needs the attribute on a module, with the operand register inside it.**
    - `(* use_dsp = "yes" *)` on a signal inferred nothing.
    - On a module, a 64-bit add took 2 DSPs and 0–1 LUTs, with +2.0 to 2.7 ns of slack.
    - Under the kept hierarchy a parent's register cannot move into the DSP, so `tg_fpu_dsp_add` registers its own operands.
  - **Synthesis already packs LUT functions well.** A hand-mapped carry chain needed a LUT for each bit's generate, where synthesis had shared it.
  - **Under the kept hierarchy, put a select in the multiplexer downstream of it.** The MUL's M3 select cost 64 LUTs in its own module; folded into the write multiplexer, it costs none.
  - **A timing fix can cost area.** Prefer a form that changes only the arithmetic in front of the critical logic. Two shifters for the NM step cost 185 LUTs; taking the adders out of the one shifter's amount fixed the same path for 75 LUTs.
  - **A narrower form of a modular computation needs the same modular care.** The remainder is exact modulo 2^96. Comparing its truncated halves as plain numbers lost the wrap; a 38-bit subtraction with the low part's borrow keeps it.
  - **A stale build hides a broken change.** The FPU unit run that passed had been built before the edit; the back-end bench, built after it, failed. Check the binary's time against the edit.
  - **Change what the algorithm aligns before changing how it maps.** The integer divider's NM shifted the dividend into two registers (a 128-bit shift); aligning the divisor instead needs one 64-bit shifter, and saved 208 LUTs where every mapping of the old shift had cost LUTs.
  - **A zero needs no multiplexer if a register can hold it.** The reset sequence's zero writes now take data that is zero then anyway (res_q[0], and P4's F0 stream), so the banks lose their zero multiplexers.
  - **Judge small changes in context.** Equivalent forms of a module synthesised alone moved by up to ±100 LUTs (x / 0 as q = 1: +97); the budget flow with an A/B decides.

**Integration on the core's F/D branch (fd2, 2026-10-14).**
- **Results:** with F/D on, all four configurations pass `make regress` (riscv-tests 284/284 including rv64uf/ud, ACT4 rv64imafdc 895/895). P4 measures 7,861 LUTs in the st core (`tg_fpu` 5,832, `tg_fprf` 1,108).
- **Assertions:** the wakeup-column assertion caught a core-side bug, an FP→int op with rd = x0 that had no LLT column.
- **Core-owned helpers:** `FPIDX_W`, `fpreg_bank()` and `fpreg_idx()` moved to `tg_core_pkg`. Defined in both packages, which `tg_fp_exec` imports together, they made the build fail.
- **Divider queue:** the core's budget run flagged the output queue, which now keeps only the read bits (above).
- **After that fix** (fd2 at c898f1e): the st core's primitive check passes (92 instances, 0 failures). P4 is 7,853 LUTs of the core's 56,461, and `make regress` still passes in all four configurations.

**Lessons:**
- **Estimates made by deletion undercount.** R5's FMISC saving was estimated at 584 by zeroing the two results; it measured 825, because the shared shifter's operand selection and bit reversal also went.
- **Single-run deltas of a few tens of LUTs are noise.** One change measured +126 and the next −302. The single packing adder measured +20 in sequence and −12 in an A/B at the final state. Judge small changes by A/B.
- **LUT savings moved cost into flip-flops and DSPs.** Pipelines in flip-flops instead of shift-register LUTs, and the smallest divider tiles in DSPs, saved LUTs. The nightly synthesis at d04ae26 measures the FPU at 5,703 LUTs, but 3,733 FFs and 35 DSPs, against 3,450 and 32 on the budgets.tsv FPU line, which was set before the pass. DR-110 raised the lines to 4,100 and 35.
- **Late control signals should gate write enables, not select data.**
  - The first `tg_fp_exec` failed timing by 0.56 ns (smt2) and 0.80 ns (st), because flush and `fdiv_ret` chose the F0 data that feeds the bypass into the units' first stage.
  - Selecting the data by the registered slot owners alone fixed it.
  - `fdiv_ret` still reached the LUTRAM write enable at +0.09 ns, and was then removed from that path as well.
- **Constrain each input by where it comes from.** With every input at 1.5 ns, the only failing paths of `tg_fp_exec` started at the load write, which leaves a register in the core, and they moved by ±0.1 ns between runs. Constraining those ports from the core's design (1.0 ns) fixed the measurement, not the RTL. The contract now states the assumption.
- **Measure area the way the budget does.** P4's first pass measured −281 LUTs with out-of-context `rebuilt` flattening, but −131 in the budget flow (`-flatten none`), which counts each module's own LUTs.
- **When placement is the cost, floorplan before changing RTL.** The floorplan gave +0.10 ns in both configurations for no LUTs, where the E2 restructure spent 118 LUTs and moved the failure.
- **At the edge, fixing the worst path moves the failure.** The E2 restructure gained 0.21 ns on the FMA, and the next run failed on the divider instead. A design with five path groups within 0.1 ns of zero needs margin on all of them, or a floorplan, not one fix at a time.
- **Re-timing is not re-implementing.** Re-timing a routed design under a new constraint holds its placement fixed. It predicted +0.02 ns for smt2; implementing with the constraint measured −0.145 ns. On paths this close to zero, only a new run counts.
- **A model of the partner needs as much care as the RTL.** Most failures were in the bench's model of the core, not in `tg_fp_exec`: registers recycled too early, retirement before producers, sources from the other thread, retirement in the flush cycle. Writing the core's side down first (the contract above, asserted in the RTL) settled each one quickly.
- **Check every event at its exact cycle.** Each wakeup, F0 write and completion is checked in its own cycle, and each value through a trace port one cycle later. Errors were therefore reported where they happened, not when a later result went wrong.
- **Operations:** jobs waiting on `tools/vivado_run.sh` lose free slots to fresh launches. Batching the OOC runs through one slot, on snapshots of the tree, ran reliably.

## Provenance

- RISC-V Unprivileged ISA, version 20240411: F and D extensions (NaN boxing, canonical NaN, FMIN/FMAX semantics of F 2.2, FCVT saturation and flags, FMA invalid rule, tininess after rounding).
- IEEE 754-2019 (and 2008): rounding, exceptions, signed-zero rules, minimumNumber/maximumNumber.
- R. E. Goldschmidt, *Applications of Division by Convergence*, M.S. thesis, MIT, 1964: the division and square-root iterations.
- M. D. Ercegovac and T. Lang, *Digital Arithmetic*, Morgan Kaufmann, 2004: ch. 7 (division by convergence, square root), ch. 8 (floating-point addition, FMA structure, rounding, leading-zero handling).
- S. F. Oberman, "Floating point division and square root algorithms and implementation in the AMD-K7 microprocessor", ARITH-14, 1999: Goldschmidt on a pipelined multiplier with interleaved operations and remainder-based correct rounding.
- P. Markstein, "Software division and square root using Goldschmidt's algorithms", RNC 6, 2004: the coupled square-root iteration and its error terms.
- D. Das Sarma and D. W. Matula, "Measuring the accuracy of ROM reciprocal tables", IEEE Trans. Computers 43(8), 1994: optimal piecewise-constant reciprocal tables.
- R. K. Montoye, E. Hokenek and S. L. Runyon, "Design of the IBM RISC System/6000 floating-point execution unit", IBM J. Res. Dev. 34(1), 1990: single-path FMA with the addend placed left of the product.
- T. Lang and J. D. Bruguera, "Floating-point multiply-add-fused with reduced latency", IEEE Trans. Computers 53(8), 2004: FMA datapath organisation and sticky handling.
- AMD UG579 (UltraScale DSP slice): 27×18 multiplier, C port, 17-bit cascade shift, register options; UG573 (memory resources): BRAM18 2K × 9; DS925 switching characteristics.
- F. de Dinechin and B. Pasca, "Large multipliers with fewer DSP blocks", FPL 2009: tiling large multipliers with DSP rectangles.
- J. R. Hauser, Berkeley SoftFloat 3e and TestFloat 3e: reference results and test vectors (tools, used as-is).

No other FPU's or core's RTL was read for these units.
