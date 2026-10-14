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

**Request timing.** A request is taken at the rising edge that ends the cycle in which `*_valid_i` is high (and `fdiv_ready_o`, for the divider). The first stage of every unit does little work, because the operands may arrive late in the cycle through the core's bypass multiplexer. The FMA's E0 stops at a format multiplexer, the NaN-box check, the integer extension of FCVT.F.I, exponent arithmetic of 13 bits and the DSP input registers; FMISC's M0 adds a magnitude compare and a trailing-zero count. The timing runs model the late arrival (1.5 ns; "Timing and area").

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
| FADD | a | 1.0 | b | – | – |
| FSUB | a | 1.0 | b | – | yes |
| FMUL | a | b | none (exact zero, no sign contribution) | – | – |
| FCVT.F.F | a, in `src_fmt` | 1.0 | none | – | – |

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
- The three "row" terms and the 2^104 bit are summed in fabric in E1 and enter two of the tiles through their C ports, so they cost no extra adder input in E2.
- Each tile computes A×B + C into its P register in one cycle (no M register; the DSP48E2 meets 200 MHz without it).

**Pipeline** (stage E*k* is the cycle after the request plus *k*; E0 is the request cycle; registers at the end of each stage):

| Stage | Work |
|---|---|
| E0 | Unpack the three operands (format, NaN box, classes, hidden bits); special-case detection; the raw exponent sums ep = ea + eb − bias and shr = ep − ec + 56, straight from the encoding fields with the format's bias in a constant; load the DSP A/B registers. The operands may arrive late (the core's bypass), so E0 stops at the sums. |
| E1 | DSP tiles (A×B + rows). Window placement: clamp shr to sh, choose E_top, lim = E_top − emin. Addend alignment (`tg_fpu_fma_align`): 53 → 165-bit right shift by sh with the sticky from a trailing-zero count; one's complement for an effective subtraction. |
| E2 | Add (`tg_fpu_fma_add`): the six tile outputs and the aligned addend (column height ≤ 5) reduce column by column to three rows, then two ternary adders run in parallel, X = P − C (= P + ~C + 1) and Y = X − 1; \|S\| is X, or ~Y when X < 0. The emin marker (below) is decoded from lim. |
| E3 | Normalise (`tg_fpu_fma_norm`): leading-zero count of \|S\| \| marker, then the left shift in four radix-4 stages; each stage keeps only the bits that can still reach the top 55 (significand, guard, round) and ORs the rest into the sticky. |
| E4 | Round (T, G, S and one round bit below G for the tininess test), pack with the exponent, special-case results, NaN boxing, flags. The response register. |

**Subnormal results** need no right shift: the normalising left shift is limited so that the exponent never goes below emin. The limit L = E_top − emin is known in E1; a one-hot marker bit at V[164 − L] (decoded and registered in E2) is ORed into \|S\| for the leading-zero count only, so the count can never exceed L (the "virtual leading one"). If L < 0 (E_top < emin: no addend and a product far below the smallest subnormal) the significand is cleared and only the sticky survives, which rounds to zero or the smallest subnormal.

**Rounding position.** For D, T = bits 54:2 of the normalised 55-bit window, G = bit 1, round bit = bit 0; for S, T = bits 54:31, G = bit 30, round bit = bit 29, and bits 28:0 join the sticky. The S exponent range check uses S limits (emin = −126, emax = 127).

**Tininess after rounding.** When the normalised value has its MSB one place below the emin position (the value is in [2^(emin−1), 2^emin)), the result is not tiny if rounding to *p* bits at the normal position (T' = the *p* bits below the MSB, G' = the next bit, S' = the rest) rounds up to 2^emin. The round bit makes this test exact.

**Special results** (computed in E0, carried to E4): canonical NaN for NaN inputs, ∞ × 0, ∞ − ∞; ∞ with the right sign; exact zeros with the IEEE sign rules above.

**Four-cycle option.** Plan §4.12 adopts a 4-cycle FMA only if it costs no Fmax. The RTL keeps each stage a separate block so a 4-stage variant (E3 and E4 merged) can be synthesised for comparison; the result of that experiment is reported under "Timing and area".

## FMISC unit (`tg_fpu_misc`)

Two stages, M0 (request cycle) and M1, each ending in a register; the response comes from the M1 register. M0 unpacks, compares magnitudes and prepares FCVT.I.F; M1 computes every result. The FP→FP and integer→FP conversions run on the FMA (lever R5, above).

FCVT.I.F shifts {significand, 11'b0} right by 63 − E in M1: the integer part, the guard from the shifter, and the sticky from the significand's trailing-zero count compared with the shift amount (no OR tree).

| Operation | M0 | M1 |
|---|---|---|
| FSGNJ, FSGNJN, FSGNJX | unpack (NaN box) | sign of b (or its inverse, or XOR) |
| FMIN, FMAX | unpack; 63-bit magnitude compare | select per F 2.2: a NaN operand loses to a number; both NaN → canonical NaN; −0 < +0; NV if any sNaN |
| FEQ, FLT, FLE | unpack; magnitude compare | ±0 equal; FEQ quiet (NV only for sNaN), FLT/FLE signalling (NV for any NaN), NaN compares false |
| FCLASS | unpack | 10-bit one-hot class mask |
| FMV.X.W / FMV.X.D | – | sign-extend a[31:0] / pass a |
| FMV.W.X / FMV.D.X | – | {0xFFFFFFFF, a[31:0]} / a |
| FCVT.{W,WU,L,LU}.{S,D} | unpack; shift = 1086 − exponent field, saturated; trailing zeros | shift; round; negate by one adder (negative ? ~m + ¬inc : m + inc); range check on m and inc without another adder; saturate (NaN and +overflow → max, −overflow → min, i.e. 0 for unsigned); NV, or NX if inexact |

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
- `tg_fpu_seed_rom` infers a block ROM (address and output registers in the BRAM18). `rtl/common/prim` has no ROM wrapper; one would replace it.

### Small multipliers (approximate terms)

While round 1 runs, small DSPs compute an approximation ẽ0 of the round-1 error e0 from truncated operands, and ẽ0², ẽ0³:

| Stage | Divide | Square root |
|---|---|---|
| Stage (cycle) | Divide | Square root |
|---|---|---|
| SM0 (t+3, 1 DSP) | D̃0 = mb[52:29] × s → ẽ0 = 1 − D̃0 | Y2 = y0² (exact; feeds M2 in round 1) |
| SMa (t+4, 2 DSPs) | – | ũ0 = x[59:34] × Y2 → ẽ0 = 1 − ũ0 (t+5) |
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

   Exact midpoints cannot occur for division or square root, so the sticky case never hides a tie. F0 runs in the c0 cycle after the remainder product: a 96-bit subtraction (the low bits of A·2^58 − p), its sign and zero test, and the choice of c or c − u_g.
4. **F1:** for a divide result below 2^emin, shift (T, G, S) right by k = emin − Eq (k ≤ 55, larger values clamp) with sticky; the rounding decision; flags. The conditions that depend only on Eq (subnormal, k, the exponent field, Eq = emin − 1, Eq > emax, Eq = emax) are derived in S3 and travel with the operation.
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
- **Output queue and credits.** The output queue (`tg_fifo`, 4 entries) holds results until `fdiv_ready_i`. An operation whose remainder product is ready leaves its slot for F0 only if the queue has room for it counting the results in F1 and F2; otherwise it repeats the remainder round (4 cycles later; the round is idempotent) and keeps its slot. With `fdiv_ready_i` mostly high this never happens.
- **Special operands** (NaN, ∞, zero, divide by zero, negative square root) still pass through the ring, so every operation has the same latency and one exit path; F2 substitutes the special result.

### Area

- 24 DSP48E2 for M1 and M2 (`tg_fpu_div_mul`): each is 12 tiles; tiles of y chunks 1 and 3 add their neighbour shifted right by 17 in c2 (the DSP cascade pattern), and the six pair sums are added by two ternary adders and one binary adder in c3.
- 5 DSP48E2 for the small multipliers.
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

## Parameters

No configuration parameter changes the FPU: the four configurations (`st`, `smt2`, `st_w3`, `smt2_w3`) build the same units. `FPU_TAG_W` comes from `tg_pkg`. SMT is invisible to the FPU (the tag carries everything; the divider's slots are shared by both harts).

## Timing and area

Out-of-context synthesis and implementation per unit (`tests/unit/fpu/vivado/ooc.tcl` through `tools/vivado_run.sh`), Vivado 2025.2, xck26-sfvc784-2LV-c, 5.0 ns clock, request inputs arriving 1.5 ns after the clock (the core's operand bypass), outputs needed 1.0 ns before the next edge. Routed results, 2026-10-13, with lever R5 (the FP→FP and integer→FP conversions on the FMA):

| Unit | LUTs | FFs | DSP48E2 | RAMB18 | WNS at 200 MHz | Latency | Budget (plan §8.2) |
|---|---|---|---|---|---|---|---|
| FMA, 5 stages | 2,883 | 1,040 | 6 | 0 | +0.08 ns | 5 | ≈ 2.5K LUTs, 10–14 DSPs |
| FMISC | 1,002 | 416 | 0 | 0 | +0.51 ns | 2 | (part of the 4.7K FPU) |
| Divide/sqrt, Goldschmidt (v1, D17) | 3,125 | 1,642 | 26 | 1 | +0.39 ns | 19/23 div, 19/27 sqrt | ≈ 1.2K LUTs (radix-4 + 0.2K), 24 DSPs, 1 BRAM18 |
| Divide/sqrt, radix-4 fallback | 1,714 | 899 | 0 | 0 | +0.20 ns | 18/33 div and sqrt | (the plan's fallback) |
| **FPU with Goldschmidt** | **7,010** | 3,098 | 32 | 1 | met | | **≈ 4.7K LUTs** |
| **FPU with radix-4** | **5,599** | 2,355 | 6 | 0 | met | | **≈ 4.7K LUTs** |

The divider rows did not change with R5 (the units only switched their routing assertion to `fpu_unit_of`), so they are the runs of the first build.

**All units meet 200 MHz.** The critical paths are: FMA E3 (normalisation: leading-zero count from the marker register, then the shift), FMISC M0 (the late operand through unpacking to the significand's trailing-zero count; M1, the FCVT.I.F shift and rounding, has +0.62 ns), Goldschmidt S1 (normalise, then the seed-ROM address), radix-4 UNP/NRM (normalise).

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

**Area against the budget.** The FPU is over its 4.7K-LUT budget: by 2.3K with the Goldschmidt unit, by 0.9K with radix-4.
- **Divider.** The Goldschmidt unit costs 1,411 LUTs (and 26 DSPs and a BRAM18) more than the radix-4 unit, not the plan's +0.2K. At that cost it fails the plan's acceptance rule (§2.5: +2.4% suite IPC against 3.7% of the 37.7K-LUT core). The user kept it for v1 (decision D17, plan §4.12): `FDIV_RADIX4` = 0, and the radix-4 unit stays built and in the regression as the fallback.
- **Lever R5** (plan §8.5) is adopted and built: −612 LUTs net (table above).
- **FMA** is 383 LUTs over its own estimate: 170 before R5 and 213 for the conversions. The largest blocks are the 166-bit adder pair (P − C and its complement, needed because the sign of an effective subtraction is unknown in the near case), the 165-bit alignment and the normaliser.

**Fallbacks not needed:** an LZA in the FMA (E3 meets timing without it), `FMA_LAT` = 6, the radix-4 unit for timing.

## Verification

Tests live in `tests/unit/fpu/` (Verilator, C++ testbench `tb_fpu.cpp` on `tg_fpu`), exit non-zero on failure, print and accept their seed, and have `short` and `long` modes:

| Command (after `source tools/env.sh`, in `tests/unit/fpu`) | What runs |
|---|---|
| `make model` | the bit-accurate divider models against SoftFloat (`gs_check`, `r4_check`) |
| `make test` | short regression, about 30 s with 8 jobs: TestFloat level 1 for every function, mode and format (mulAdd: 1.5M vectors per mode), directed divide/sqrt cases, random traffic on all units |
| `make test-long` | level 2 for every function, mulAdd level 1 complete plus a level-2 prefix of 2·10^7 vectors per mode and format, longer directed and random runs (about an hour with 6 jobs) |
| `make tb DIV=r4`, `make test DIV=r4` | the same on the radix-4 fallback |

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
