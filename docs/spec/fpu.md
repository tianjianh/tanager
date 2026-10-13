# FPU execution units (`tg_fpu`, `tg_fpu_fma`, `tg_fpu_misc`, `tg_fpu_div`)

Status: draft — fpu track — 2026-10-13

## Purpose

The three floating-point execution units behind port P4 of the core (plan §4.12), with the port contract of [interfaces.md §4](interfaces.md) and `rtl/common/tg_fpu_pkg.sv`:

| Unit | Module | Operations | Timing |
|---|---|---|---|
| FMA | `tg_fpu_fma` | FADD, FSUB, FMUL, FMADD, FMSUB, FNMSUB, FNMADD | `FMA_LAT` = 5, fully pipelined |
| FMISC | `tg_fpu_misc` | FSGNJ/N/X, FMIN, FMAX, FEQ, FLT, FLE, FCLASS, FCVT (F↔F, F↔I), FMV | `FMISC_LAT` = 2, fully pipelined |
| Divide/sqrt | `tg_fpu_div` | FDIV, FSQRT | 18 / 22 cycles (divide S / D), 18 / 26 (square root S / D); up to 4 in flight |

`tg_fpu` instantiates the three units and nothing else. The core owns issue, the FP register file, bypass, writeback arbitration, `fcsr` and the accumulation of `fflags` (plan §4.5). The FPU holds no architectural state.

Both formats of RISC-V F and D (unprivileged ISA 20240411, chapters "F" and "D") are implemented exactly. `FMT_H` is not implemented (Zfhmin is not scheduled); an assertion flags it.

## Interface

Ports are those of the stub `rtl/core/fpu/tg_fpu.sv`; requests are `fpu_req_t`, responses `fpu_resp_t` (`tg_fpu_pkg`).

**Request timing.** A request is taken at the rising edge that ends the cycle in which `*_valid_i` is high (and `fdiv_ready_o`, for the divider). The first stage of every unit does little work, because the operands may arrive late in the cycle through the core's bypass multiplexer: at most a format multiplexer, the NaN-box check, exponent arithmetic of 13 bits and the DSP input registers.

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

All operations become (±A × B) ± C with one rounding:

| Op | A | B | C | Product sign flip | Addend sign flip |
|---|---|---|---|---|---|
| FMADD | a | b | c | – | – |
| FMSUB | a | b | c | – | yes |
| FNMSUB | a | b | c | yes | – |
| FNMADD | a | b | c | yes | yes |
| FADD | a | 1.0 | b | – | – |
| FSUB | a | 1.0 | b | – | yes |
| FMUL | a | b | none (exact zero, no sign contribution) | – | – |

The sign flips are exact negations (FNMADD = −(a×b) − c), applied to the product and addend signs before the effective operation is chosen, so rounding direction and zero signs follow the negated operands.

### Datapath (D precision, p = 53; S uses the same path)

The product P = ma × mb is a 106-bit integer, weight 2^(Ep−104) with Ep = Ea + Eb. The addend is aligned in a 161-bit window that holds the product in bits 105:0 and the addend anywhere from bits 160:108 downwards (the single-path FMA of Montoye et al., with the addend pre-placed to the left of the product so that only a right shift is needed). One extra bit below bit 0 carries the sticky of whatever was shifted out, so effective subtraction borrows correctly.

- Right shift of the addend: sh = Ep − Ec + 56, clamped to [0, 162].
  - sh = 0 after clamping (Ec > Ep + 56): the addend dominates. The product is at least three bits below the addend's LSB and is replaced by its sticky in the extra bit.
  - sh > 108: addend bits below bit 0 go to the sticky.
- Window exponent: bit 160 has weight 2^E_top, E_top = max(Ep + 56, Ec).

**Multiplier.** With ma = 2^52·ha + fa and mb = 2^52·hb + fb (fa, fb the 52-bit fractions):

  P = fa × fb[50:0] + 2^51·fb[51]·fa + 2^52·(ha·fb + hb·fa) + 2^104·ha·hb

- fa[51:0] × fb[50:0] uses six DSP48E2 tiles of 26 × 17 bits (fa in two 26-bit chunks on the 27-bit port, fb in three 17-bit chunks on the 18-bit port; UG579).
- The three "row" terms and the 2^104 bit are summed in fabric (one ternary adder) and enter two of the tiles through their C ports, so they cost no extra compressor input.
- Each tile computes A×B + C into its P register in one cycle (no M register; the DSP48E2 meets 200 MHz without it).

**Pipeline** (stage E*k* is the cycle after the request plus *k*; E0 is the request cycle; registers at the end of each stage):

| Stage | Work |
|---|---|
| E0 | Unpack the three operands (format, NaN box, classes, hidden bits); special-case detection; exponents: Ep, sh, E_top; trailing-zero count of mc (addend sticky); load the DSP A/B registers. |
| E1 | DSP tiles (A×B + rows); addend alignment: 53 → 161-bit right shift by sh (four levels of 4:1 multiplexers) with sticky; one's complement of the aligned addend for effective subtraction. |
| E2 | Add: the six tile outputs and the aligned addend (column height ≤ 5) are reduced to three rows by one level of LUT counters over the columns that need it, then summed by two ternary adders in parallel, X = P − C and Z = C − P; X's sign selects \|S\|. The subnormal-limit marker (below) is ORed into \|S\|. |
| E3 | Leading-zero count of the 161-bit \|S\| and a left shift that keeps only the top 55 bits (significand, guard, round) plus a sticky. |
| E4 | Round (T, G, S and one round bit below G for the tininess test), pack with the exponent, special-case results, NaN boxing, flags. The response register. |

**Subnormal results** need no right shift: the normalising left shift is limited so that the exponent never goes below emin. The limit L = E_top − emin is known in E1; a one-hot marker bit at position 160 − L is ORed into \|S\| before the leading-zero count, so the count can never exceed L (the "virtual leading one"). If L < 0 (E_top < emin: product and addend both far below the smallest subnormal) the significand is cleared and only the sticky survives, which rounds to zero or the smallest subnormal.

**Rounding position.** For D, T = bits 54:2 of the normalised 55-bit window, G = bit 1, round bit = bit 0; for S, T = bits 54:31, G = bit 30, round bit = bit 29, and bits 28:0 join the sticky. The S exponent range check uses S limits (emin = −126, emax = 127).

**Tininess after rounding.** When the normalised value has its MSB one place below the emin position (the value is in [2^(emin−1), 2^emin)), the result is not tiny if rounding to *p* bits at the normal position (T' = the *p* bits below the MSB, G' = the next bit, S' = the rest) rounds up to 2^emin. The round bit makes this test exact.

**Special results** (computed in E0, carried to E4): canonical NaN for NaN inputs, ∞ × 0, ∞ − ∞; ∞ with the right sign; exact zeros with the IEEE sign rules above.

**Four-cycle option.** Plan §4.12 adopts a 4-cycle FMA only if it costs no Fmax. The RTL keeps each stage a separate block so a 4-stage variant (E3 and E4 merged) can be synthesised for comparison; the result of that experiment is reported under "Timing and area".

## FMISC unit (`tg_fpu_misc`)

Two stages, M0 (request cycle) and M1, each ending in a register; the response comes from the M1 register.

| Operation | M0 | M1 |
|---|---|---|
| FSGNJ, FSGNJN, FSGNJX | unpack (NaN box); sign of b (or its inverse, or XOR); result | pass |
| FMIN, FMAX | unpack; 63-bit magnitude compare; select per F 2.2: a NaN operand loses to a number; both NaN → canonical NaN; −0 < +0; NV if any sNaN | pass |
| FEQ, FLT, FLE | unpack; compare (±0 equal); FEQ quiet (NV only for sNaN), FLT/FLE signalling (NV for any NaN), NaN compares false | pass |
| FCLASS | unpack; 10-bit one-hot class mask | pass |
| FMV.X.W / FMV.X.D | sign-extend a[31:0] / pass a | pass |
| FMV.W.X / FMV.D.X | {0xFFFFFFFF, a[31:0]} / a | pass |
| FCVT.D.S | unpack S; leading-zero count of a subnormal fraction | normalise, rebias; canonical NaN (NV for sNaN) |
| FCVT.S.D | unpack D; S exponent; for S-subnormal results a right shift of up to 26 places with sticky | round to 24 bits; S overflow/underflow; tininess after rounding as in the FMA |
| FCVT.{W,WU,L,LU}.{S,D} | unpack; right shift of the significand to an integer with G and S (shift = 63 − E, saturated) | round; negate by one adder (result = negative ? ~m + ¬inc : m + inc); range check against the format's limits; saturate (NaN and +overflow → max, −overflow → min, i.e. 0 for unsigned); NV, or NX if inexact |
| FCVT.{S,D}.{W,WU,L,LU} | select and sign-handle the integer source; \|x\| by negation; leading-zero count of x XOR sign (the count of \|x\| except when x = −2^k, corrected in M1); trailing-zero count (the same for x and −x) | left shift; one-place correction; G from the shifted value, S from the trailing-zero count; round; pack |

Integer sources for FCVT.F.I and FMV.F.X arrive in `a`. FCVT.D.W and FCVT.D.WU are exact.

**Unsigned conversion of negative values.** A negative input that rounds to zero converts to 0 with NX only; one that rounds to −1 or below is invalid (result 0, NV).

**Plan lever R5** (conversions sharing the FMA's normaliser and rounder) is not used: it would raise the conversion latency from 2 to 5 cycles or add a second entry point into the FMA pipe with its own writeback-slot rules for the core. The FMISC area is reported separately so the trade can be judged later.

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
- Generated by `tests/unit/fpu/gen_seed.py` into `rtl/core/fpu/tg_fpu_seed_tab.svh` (checked in); the generator prints the worst-case errors, which the error budget below depends on.

### Small multipliers (approximate terms)

While round 1 runs, small DSPs compute an approximation ẽ0 of the round-1 error e0 from truncated operands, and ẽ0², ẽ0³:

| Stage | Divide | Square root |
|---|---|---|
| SM0 (1 DSP) | D̃0 = mb[52:29] × s → ẽ0 = 1 − D̃0 | Y2 = y0² (exact; feeds M2 in round 1) |
| SMa (2 DSPs) | (pass) | ũ0 = x[top 26 bits] × Y2 → ẽ0 = 1 − ũ0 |
| SMb (1 DSP) | ẽ0² | ẽ0² |
| SMc (1 DSP) | ẽ0³ = ẽ0² × ẽ0 (top bits) | same |

|ẽ0 − e0| ≤ 2^−23, so ẽ0² and ẽ0³ are good to about 2^−32. These terms only steer the iteration; the remainder step makes the result exact regardless.

### Division schedule

| Round | M1 | M2 | Notes |
|---|---|---|---|
| R1 | N0 = A · s | D0 = mb · s | e0 = 1 − D0, \|e0\| ≲ 2^−9.7 |
| R2 | N1 = N0 · R | D1 = D0 · R | R = 2 − D0 + ẽ0² + ẽ0³ ≈ 1 + e0 + e0² + e0³ (cubic step); e1 = 1 − D1 ≈ 2^−31 |
| R3 (D only) | N2 = N1 · (2 − D1) | – | error ≈ e1² + truncation |
| last | remainder: mb · c | – | c = quotient rounded to the guard grid |

Single precision uses R1, R2 and the remainder round (3 rounds); double precision R1–R3 and the remainder round (4 rounds).

### Square-root schedule (Goldschmidt with a second-order first step)

| Round | M1 | M2 | Notes |
|---|---|---|---|
| R1 | q0 = x · y0 | u0 = x · Y2 | e0 = 1 − u0 ≈ 2·(seed error), \|e0\| ≲ 2^−8.5 |
| R2 | q1 = q0 · P | y1 = y0 · P | P = 1 + e0/2 + ⅜ẽ0² + 5⁄16 ẽ0³, the series of (1 − e0)^−½; q1 error ≲ 2^−32 |
| R3 (D only) | w1 = q1 · y1 | – | e1 = 1 − w1, computed from the actual q1, y1 (self-correcting) |
| R4 (D only) | q2 = q1 · (1 + e1/2) | – | error ≈ ⅜·e1² + truncation |
| last | remainder: c · c | – | |

Single precision: 3 rounds; double: 5 rounds. Markstein (RNC 2004) gives the error behaviour of these coupled iterations.

### Error budget

The rounding step needs |q_approx − q| < u_g/2, where u_g is the guard-bit weight (2^−53 for D and 2^−24 for S, q ∈ [1, 2)). The budget, checked by the bit-accurate model (`tests/unit/fpu/gs_model.cpp`) over random and directed operands:
- each truncated product adds at most 2^−58;
- divide D: |error| < 2^−55.5; divide S: < 2^−29;
- square root D: < 2^−55.5; square root S: < 2^−30.

Q2.58 (rather than the plan's 56-bit multiplier) is what makes the double-precision budget hold with a one-step correction; it costs no extra DSPs (60 = 26 + 26 + 8 on the 27-bit port, 17 + 17 + 17 + 9 on the 18-bit port).

### Final rounding (remainder round, F0, F1)

1. **c0 of the last round:** c = q_approx rounded to the nearest multiple of u_g. Then q ∈ (c − u_g, c + u_g), and c may equal 2.0.
2. **Remainder:** R = A − mb·c (divide) or R = x − c² (square root), exact. Only its sign and whether it is zero are needed. |R| < 2^−51 (D), so only the low 57 bits of the product and two bits of A or x take part; S uses a window 29 bits higher.
3. **F0:** (T, G, S) at normal precision:
   - R = 0: from c, S = 0;
   - R > 0: from c, S = 1;
   - R < 0: from c − u_g (precomputed in the remainder round), S = 1.

   Exact midpoints cannot occur for division or square root, so the sticky case never hides a tie.
4. **F1:** for a divide result below 2^emin, shift (T, G, S) right by k = emin − Eq (k ≤ 55, larger values clamp) with sticky; round; pack; overflow; special results; NaN boxing; into the output queue.
   - Tininess after rounding uses the normal-precision (T, G, S) from F0: a result with Eq = emin − 1 is not tiny if it rounds up to 2^emin at *p* bits.
   - Square roots are never subnormal and never overflow.

### Pipeline and latency

| Cycle (accept = t) | Work |
|---|---|
| t | request registered |
| t+1 | unpack, classify, normalise both significands (LZC + shift), exponent, ma < mb compare, seed address |
| t+2 | BRAM18 read; seed into the DSP input registers |
| t+3 | SM0 |
| t+4 | c0 of R1 (slot entry) |
| t+4·n | c0 of round n |
| t+4·n_last+4 | F0 |
| t+4·n_last+5 | F1; written to the output queue |
| t+4·n_last+6 | `fdiv_valid_o` |

| Operation | Rounds n_last | Latency | Slot held (cycles) | Steady-state rate |
|---|---|---|---|---|
| FDIV.S | 3 | 18 | 12 | 1 per 3 cycles |
| FDIV.D | 4 | 22 | 16 | 1 per 4 cycles |
| FSQRT.S | 3 | 18 | 12 | 1 per 3 cycles |
| FSQRT.D | 5 | 26 | 20 | 1 per 5 cycles |

Against the plan (18/23, 20/26, one every 4 cycles) these are equal or better except FSQRT.D's rate. The constants `FDIV_LAT_S/D` and `FSQRT_LAT_S/D` in `tg_fpu_pkg` are set to the latencies above.

### Flow control

- **Slots.** Slot *k* passes the entry point (c0) in cycles ≡ *k* (mod 4). A request accepted in cycle *t* enters slot *t* mod 4 four cycles later, so `fdiv_ready_o` = slot (*t* mod 4) is free, or its operation is in its last round now and holds an output credit.
- **Output queue and credits.** The output queue holds 4 results. An operation reserves a credit when its last round starts (c0); credits count queue entries plus results in the remainder round, F0 and F1. Without a credit the operation repeats its last round (4 cycles later; the remainder round is idempotent) and keeps its slot. With `fdiv_ready_i` mostly high this never happens.
- **Special operands** (NaN, ∞, zero, divide by zero, negative square root) still pass through the ring, so every operation has the same latency and one exit path; F1 substitutes the special result.

### Area

- 24 DSP48E2 for M1 and M2: each is 12 tiles; pairs along the 18-bit port are summed in the DSP cascade (PCIN >> 17), the six pair sums by two ternary adders and one binary adder in c3.
- 5 DSP48E2 for the small multipliers.
- 1 BRAM18.

## Parameters

No configuration parameter changes the FPU: the four configurations (`st`, `smt2`, `st_w3`, `smt2_w3`) build the same units. `FPU_TAG_W` comes from `tg_pkg`. SMT is invisible to the FPU (the tag carries everything; the divider's slots are shared by both harts).

## Timing and area

Target: 200 MHz on xck26-sfvc784-2LV-c (≈ −1 speed at 0.72 V), out-of-context per unit.

| Unit | LUT estimate | DSP | BRAM | Budget (plan §8.2) | Critical stage |
|---|---|---|---|---|---|
| FMA | ≈ 2.2K | 6 | – | ≈ 2.5K, 10–14 DSP | E2 (ternary add 161 bits) and E3 (LZC + shift) |
| FMISC | ≈ 1.0K | – | – | | M1 of FCVT.F.I |
| Divide/sqrt | ≈ 1.8K | 29 | 1 BRAM18 | ≈ 1.2K LUTs (radix-4 + 0.2K), 24 DSP, 1 BRAM18 | c3 of the multiplier, c0 operand formation |
| Total | ≈ 5.0K | 35 | 0.5 BRAM36 | ≈ 4.7K | |

The divider's LUTs exceed the plan's estimate, mainly two input normalisers, the multipliers' final adders and the remainder logic. Levers if the total misses: share one normaliser between dividend and divisor; replace F1's denormalising shifter by candidates precomputed in the remainder round; FMISC lever R5.

**Fallbacks.**
- FMA misses 200 MHz at 5 stages: an LZA in E2 to take the leading-zero count off E3, or `FMA_LAT` = 6 (the plan prices 5 → 4 at +0.22% suite IPC, so 5 → 6 costs about as much).
- Divider misses: radix-4 digit recurrence at 17/31 cycles (plan §4.12).

## Verification

Tests live in `tests/unit/fpu/` (Verilator, C++ testbench on `tg_fpu`), exit non-zero on failure, print and accept their seed, and have `short` and `long` modes.

- **Reference model:** Berkeley SoftFloat 3 built with the RISC-V specialization (canonical NaN, RISC-V conversion limits, tininess after rounding), linked into the testbench; RISC-V-specific behaviour on top of it written from the ISA manual: NaN boxing, FMIN/FMAX 2.2, FCLASS, sign injection, moves, int_dest and sign extension.
- **TestFloat:** `testfloat_gen` vectors piped into the testbench for every function, both formats and all five rounding modes:
  - level 1 for every operation;
  - level 2 for add, sub, mul, div and sqrt (complete), and for mulAdd as a long prefix: complete level 2 is 1.5·10^10 (S) and 1.8·10^11 (D) cases, beyond simulation; the prefix length is reported with the results;
  - FMSUB, FNMSUB, FNMADD and FSUB reuse the mulAdd/add vectors with the operand signs flipped (exact identities: FMSUB(a, b, −c) = fma(a, b, c) and so on).
- **Directed divide/sqrt cases** for the remainder correction: quotients and roots constructed to lie within 2^−2p of a midpoint or of a representable value, exact quotients and roots, results at the subnormal boundary (Eq = emin − 1), overflow edges, every seed-ROM interval endpoint.
- **Pipelining:** back-to-back FMA and FMISC operations every cycle with random precision, op and rounding mode; the divider fed at full rate with mixed S/D divide and sqrt, random `fdiv_ready_i` backpressure, checking tags, order independence and that every accepted request produces exactly one response.
- **Interleaving:** all three units driven at once with random traffic.
- **Assertions** (Verilator `--assert`): FMT_H never requested; requests routed to the right unit; `fdiv_valid_i` held while not ready; credit and slot invariants.
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
