# M9 §10: the ISA-string check, extension by extension

Status: draft, prepared for the check (soc track with core) — smt2-study — 2026-10-24. Built from our specs only: no
RTL was read for it. What each extension requires is the published specification's (Sources), summarised; where this
page summarises a chapter, the check reads the chapter.

## Purpose
- **The item:** M9 §10 ([m9-plan.md](m9-plan.md) lines 331–339) lists in the device tree the extensions of
  core-priv.md's target that the RTL meets.
- **Today's trees** list `rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicond_sstc` (sw/dts/tanager.dtsi:62–66).
- **The target** adds six: `zicntr`, `zihpm`, `zihintpause`, `svinval`, `zkt` and `za64rs` (core-priv.md:8; plan §4.1's
  day-one extensions).
- **For each of the six, this page gives:**
  - what the extension requires;
  - what our specs say the RTL does;
  - what already verifies it;
  - what is left for the check.

  The check then reads the RTL against a short list instead of the specs.
- **None of the six costs a LUT:** the change is the tree's two macros. Only `zihintpause` and `svinval` name
  instructions that cost cycles here.

## Summary
| Extension | It requires | Our specs say | Verified today | Left for the check | Recommendation |
|---|---|---|---|---|---|
| `zicntr` | `cycle`, `time`, `instret` readable below M where `mcounteren`/`scounteren` allow | all three per hart; `time` is the core's copy of the ACLINT's `mtime`, so nothing is emulated | ACT4's Zicntr plans in every configuration; lockstep (Spike's string has it) | read `tg_csr`'s aliases and enables against two spec rows | **list it** |
| `zihpm` | `hpmcounter3–31` readable where the enables allow; a counter and its event selector may be read-only zero | the 29 counters read 0, gated by the enables, whose HPM bits are writable | ACT4's Zihpm and Sscounterenw plans; Sail's WARL setting "HPM counters reading zero" equals Spike's | the same reading for `hpmcounter3–31` and `mhpmevent3–31` | **list it** |
| `za64rs` | reservation sets contiguous, naturally aligned, at most 64 bytes | an LR reserves its 64-byte line; one reservation per hart, ended by the sibling's stores | ACT4's Za64rs plan; Sail and Spike reserve the 64-byte block; lockstep's SC rule relies on it | confirm the reservation compares the line address and nothing coarser | **list it** |
| `zihintpause` | PAUSE (a FENCE with pred = W, succ = 0) is a hint: it never traps; any effect is bounded | no spec line names PAUSE. FENCE is serialising: it retires alone with the hart's window and store queue drained, then refetches | ACT4's Zihintpause plan | confirm decode takes every FENCE encoding as FENCE, never illegal | **list it** |
| `svinval` | SINVAL.VMA invalidates as SFENCE.VMA does; a simple implementation runs it as SFENCE.VMA and the two new fences as no-ops | all three serialising; each waits for the store queue and flushes the hart's whole ITLB and DTLB (no ASID tags) | ACT4's Svinval plan; lockstep (Spike's string has it) | a board measurement, with the name and without | **leave it out of v1** unless a board session measures no cost: here it buys only the name |
| `zkt` | the listed instructions' latency does not depend on their operands' values | ALU ops take one cycle; MUL three fixed stages (MUL-to-use 5); divides are iterative but not listed | the directed timing test `zkt.S` and the core track's reading of the ALU and the multiplier (10-24): no value-dependent path | nothing | **list it** |

**The order for the check:**
1. The four reading items in one sitting, minutes each.
2. `zkt`'s test and reading, about an hour. Done on 10-24 (below).
3. `svinval` on a board session, if one has an hour. Without one, v1 ships without it.

## Each extension

### `zicntr`
- **Requires** (Volume I's counters chapter; Volume II for the enables): `cycle`, `time` and `instret` (0xC00–0xC02)
  readable in M, in S where `mcounteren` allows (CY, TM, IR), and in U where `scounteren` also allows. Otherwise the
  read is illegal.
- **Our specs:**
  - The three are read-only aliases of the per-hart `mcycle` and `minstret` and of `time` (core-pipeline.md:456–458).
    `mcountinhibit` has CY and IR writable.
  - `time` is the core's snapshot of the ACLINT's `mtime`, a cycle behind it and monotonic (DR-146), and Sstc's
    compare uses the same input (core-priv.md:88; interfaces.md:116).
  - The enables are 32 bits (core-priv.md:42), per hart in SMT2 (core-pipeline.md:496–497).
  - Because `time` is a hardware CSR, OpenSBI emulates nothing (pmp-at-fill.md:118).
- **Verified:**
  - ACT4: Zicntr's plans in every configuration (verification.md:1072–1075).
  - Lockstep: Spike's string has `zicntr` (sim/Makefile:64), so every run checks the reads' legality. The values
    of `cycle` and `time` are `nondet`, which the checker takes from the RTL (core-pipeline.md:458, 477).
  - The board: OpenSBI and Debian's kernel already report `zicntr`, though the tree omits it
    (release_notes_v1.md:42–45).
- **The check:** read the three aliases and the TM/CY/IR gating in `tg_csr` against those rows. Nothing to run.

### `zihpm`
- **Requires** (the same chapters): `hpmcounter3–31` (0xC03–0xC1F) readable where the enables allow. Volume II
  allows a counter and its event selector to be read-only zero, so all-zero counters meet Zihpm (m9-plan.md:335).
- **Our specs:**
  - `hpmcounter3–31` read 0, `nondet`, gated by the enables; `mhpmevent3–31` read 0 (core-priv.md:48–49); the HPM
    counters read zero (core-pipeline.md:544).
  - The enables' HPM bits are writable (core-priv.md:42).
  - That is the default build. With `TG_HPM` = 1, counters 3–6 count, and Sscofpmf joins (area_switches.md:44;
    m9-plan.md §1).
- **Verified:**
  - ACT4: the Zihpm and Sscounterenw plans (verification.md:1074).
  - Sail's WARL settings equal Spike's: the HPM bits of `mcounteren` and `scounteren` writable, and the counters
    reading zero (verification.md:1084).
  - Under `TG_HPM` = 1, ACT4's `-hpm` configuration passed 895 of 895 on 10-24 (verif-2, checked on main d1a28b08,
    merged as d7c2d835).
- **The check:** the same reading for `hpmcounter3–31` and `mhpmevent3–31`. A v1 built with `TG_HPM` also lists
  `sscofpmf`, with a `riscv,pmu` node (release_notes_v1.md:48).

### `za64rs`
- **Requires** (the Profiles, which name it): reservation sets are contiguous, naturally aligned and at most 64 bytes.
- **Our specs:**
  - An LR reserves its 64-byte line, one reservation per hart (core-lsu.md:132).
  - The reservation is ended by:
    - an SC;
    - a trap or xRET;
    - the line leaving the D$ or losing T;
    - a store or an atomic's write to that line by the sibling hart, as a probe would (core-lsu.md:70–71;
      threading.md:15).
- **Verified:**
  - ACT4: the Za64rs plan (verification.md:1074).
  - Sail and Spike reserve the 64-byte block (verification.md:1085).
  - The RTL never succeeds where Spike fails because its reservation is never wider than Spike's, provided Spike's
    string has `za64rs` (core-lsu.md:135). So lockstep holds the RTL to it on every run.
- **The check:** confirm that the reservation compares the line address (PA bits 6 and up) and no coarser block.

### `zihintpause`
- **Requires** (Volume I's Zihintpause chapter):
  - PAUSE is encoded as a FENCE with pred = W, succ = 0, fm = 0, rd = rs1 = x0 (0x0100000F).
  - It is a hint that the hart may slow its retirement for a while. The effect must be bounded, and may be zero.
  - That FENCE orders nothing (succ = 0), so running it as a FENCE is legal.
  - Volume I also requires base implementations to treat FENCE's reserved fm and pred/succ settings as normal fences,
    so no FENCE encoding may trap.
- **Our specs:**
  - No line names PAUSE.
  - FENCE is serialising (core-priv.md:24; core-pipeline.md:374): it is taken alone in slot 0
    (core-pipeline.md:200), dispatched into the hart's empty window, and waits for the store queue
    (core-lsu.md:111). It then retires and the hart flushes and refetches at the next PC.
  - In SMT2 the serialisation is per thread (m7-smt2-plan.md:69, 106).
- **Its cost:** a PAUSE holds its hart for the drain and then a refill. A flush's refill, from one retirement to the
  next, is 13.5 cycles for mispredicts (area_recovery.md:750). The sibling has the core meanwhile, which is the
  hint's purpose.
- **Verified:** ACT4's Zihintpause plan (verification.md:1074).
- **The check:**
  - Confirm that decode takes every FENCE encoding (any fm, pred, succ, rs1, rd) as FENCE.
  - Optional: count retirements of 0x0100000F in an RTL boot's commit trace, with the name and without. This shows
    whether Debian's kernel runs PAUSE either way.

### `svinval`
- **Requires** (Volume II 1.13, the Svinval chapter):
  - SINVAL.VMA invalidates what SFENCE.VMA with the same rs1 and rs2 would. SFENCE.W.INVAL and SFENCE.INVAL.IR order
    it against earlier stores and later implicit page-table reads.
  - SINVAL.VMA takes SFENCE.VMA's permissions and exceptions: illegal in U, and in S with TVM = 1.
  - A simpler implementation may run SINVAL.VMA as SFENCE.VMA and the two fences as no-ops.
- **Our specs:**
  - All three are serialising (core-priv.md:24), and SINVAL.VMA traps as SFENCE.VMA does (core-priv.md:28).
  - Each waits for the store queue to drain and flushes the hart's entries in both TLBs with the pipeline flush
    (core-mmu.md:47).
  - The TLBs have no ASID tags (core-pipeline.md:555; area_switches.md:65), so every form flushes the hart's ITLB (16)
    and DTLB (32) whole (core-mmu.md:9).
  - That is the simpler implementation, made stronger: the two fences serialise instead of doing nothing.
- **Its cost, by our spec:**
  - A range flush of N pages written the Svinval way (SFENCE.W.INVAL, N × SINVAL.VMA, SFENCE.INVAL.IR) costs N + 2
    serialisations and N whole-TLB flushes.
  - N SFENCE.VMAs cost N and N.
  - So the name gains nothing on this RTL and can cost two drains a batch, or more if software picks a different
    batch size when it sees the name. Our specs don't say what Debian's kernel does with it; m9-plan.md:336–337
    raises the risk.
- **Verified:**
  - ACT4: the Svinval plan (verification.md:1074).
  - Lockstep: Spike's string has `svinval` (sim/Makefile:64; core-pipeline.md:198).
- **The check:**
  - **On the board:** one image, two trees, the name in or out (no bitstream or kernel rebuild). Time a loop that
    maps 1, 8 and 64 pages, writes a byte in each and unmaps them, 1,000 times, with `clock_gettime`. Take
    `systemd-analyze` too (today 1 min 59.0 s, release_notes_v1.md:87). Three runs each.
  - **Decision:** list `svinval` only if the loop is no slower beyond the runs' spread. Without a board session, v1
    leaves it out: it costs nothing to omit here, and v1 doesn't aim at the RVA profiles that require it
    (release_notes_v1.md:49).

### `zkt`
- **Requires** (Volume I, the scalar cryptography chapter's Zkt section): the latency of a listed set of instructions
  must not depend on their operands' values. The list covers:
  - the base integer ALU ops, shifts, LUI and AUIPC, with their W forms;
  - the multiplies (MUL, MULH, MULHSU, MULHU, MULW). The divides are not listed;
  - the compressed forms of those;
  - the bit-manipulation ops Zbkb shares with Zbb (ANDN, ORN, XNOR, the rotates, REV8).

  Loads, stores and branches are not listed. The manual's table is the reference.
- **Our specs:**
  - **ALU ops** take one cycle, with no wakeup column: a dependant selects the cycle after its producer
    (core-pipeline.md:223, 294). The ALUs are `tg_alu` on every port (core-pipeline.md:322).
  - **MUL, MULH, MULHSU, MULHU and MULW** run on P1: three stages, a 128-bit product (core-pipeline.md:323).
    Dependants wake through a fixed delay line (MUL-to-use 5 cycles, no bypass; core-pipeline.md:294), with a tag
    from a pool (core-pipeline.md:222). Rename waits when the pool runs short, which depends on the instruction mix,
    not on data.
  - **The compressed forms** are expanded before decode, so they run as their 32-bit forms (core-pipeline.md:197).
  - **Not listed, for completeness:**
    - CLZ, CTZ and CPOP share P1's tag path (core-pipeline.md:222);
    - DIV and REM are radix-2 iterative on long-latency tags (core-pipeline.md:23, 323).
- **Verified (10-24, the core track).** ACT4 and lockstep compare values, and `cycle-identical` compares builds, so
  none of them times one instruction against its operands; this check does:
  - **The reading:** `tg_alu` is combinational, and its result select takes only the decoded control bits: operand
    values choose data, never timing. `tg_mul` is a fixed three-stage pipeline whose valid bits never look at the
    operands. Neither has an early out, a zero skip or a stall on an operand pattern.
  - **The test,** `tests/isa/directed/zkt.S`: the 45 listed instructions (register, immediate and W forms, the
    multiplies, Zbkb's share of Zbb, LUI and AUIPC), each as a 64-long dependent chain timed with `mcycle` under every
    class. Every class gives the same count: 82 cycles a chain for the ALU ops, 336 for the multiplies (5 cycles each,
    the MUL-to-use delay). It passes in lockstep in `st`, `st_w3`, `smt2` with hart 1 off and idle, both `SOLO_TID=1`
    forms and `PMP_FILL=1`, with the directed run's `--irq-rand=5`. Without Zbb (the test core) its probe traps and the
    Zbkb part is skipped, as in `zbb.S`.
  - **Runs that change cycle counts by design leave it out** (`tests/isa/exclude/directed-timing.txt`): regress's trace
    back-pressure run (`--trace-stall=50`) and random-wake run (`+xwake=20`), and `cycle-identical`'s stress suite.
    Under either perturbation it fails at its first instruction, as it must.
  - **Outside Zkt's rule:** a divide (not listed; `n + 4` cycles, `n` from its operands' leading zeros, `tg_div.sv`)
    blocks one ALU1 select when it writes back (`a1_block`, `tg_exec.sv`), as an FP-to-integer result does. A listed
    instruction on ALU1 after a divide can therefore move by a cycle with the divide's operands, never with its own.
- **The check:**
  - **A directed test** in `tg_vsim`. For each listed instruction, a 64-long dependent chain under each operand class:
    0, 1, −1, the sign bit alone, small, large, mixed signs, and shift amounts 0, 1, 31, 32, 63. Each chain is timed
    with `mcycle`, with the code warm in the I$.
    - The simulation is cycle-exact, so the counts must match exactly within each instruction.
    - Run it in `st` and in `smt2` with hart 1 idle.
  - **The core track reads `tg_alu` and the multiplier** for any value-dependent path: an early out, a zero skip, or
    a stall on an operand pattern.
  - Then list `zkt`. Both done on 10-24 (above).

## The listed extensions
`i`, `m`, `a`, `f`, `d`, `c`, `zicsr`, `zifencei`, `zba`, `zbb`, `zbs`, `zicond` and `sstc` are in the trees today.
- **ACT4's F/D configuration passes 895 of 895:**
  - in `st` on 10-24 (main d1a28b08: default and `TG_HPM` = 1; d7c2d835);
  - with 8 PMP entries in `st`, in `smt2` with hart 1, and in `st` with `PMP_FILL=0` (soc.md:929; 8183c5a2).
- **Lockstep** runs Spike with every name in the target except `zihintpause` and `zkt` (sim/Makefile:64, as
  core-pipeline.md:198 gives it).
- **ACT4** runs Spike with the full target (tests/arch/config/core-m3-rv64imafdc/test_config.yaml:11).

The check has nothing to add for these.

**A stale line, for the verification track:** verification.md:264 gives the full target as the simulations' default
string. The default (sim/Makefile:64) lacks `zihintpause` and `zkt`. For this check that costs nothing: Zkt is about
time, which Spike doesn't model, and ACT4's Zihintpause plan runs with the full string.

## The string itself
- **Where it is set:**
  - Two macros set `riscv,isa` (`TG_ISA_STR`) and `riscv,isa-extensions` (`TG_ISA_EXT`). Each has an FPU and a
    no-FPU form (sw/dts/tanager.dtsi:62–66), so four lines change together.
  - Every tree built from tanager.dtsi takes them: the KV260's, the simulation boot's
    (tests/unit/boot/Makefile:81–84), and QEMU's (sw/dts/tanager-qemu.dts:18).
- **OpenSBI reads the names too:** on rc3 it reports `sstc,zicntr,sdtrig,f,d` (release_notes_v1.md:43). What it does
  with the new names is for the soc track to read, since DR-192 allows OpenSBI's source for configuring it. Its boot
  banner shows the result.
- **The QEMU tree:**
  - QEMU's runs use its default CPU (sw/qemu/boot_test.sh:22; sw/qemu/debian_test.sh:58), so a name that CPU lacks
    would be claimed falsely there.
  - So keep the QEMU tree on today's list (tanager.dtsi would need an `#ifndef` around the two macros), unless QEMU's
    documentation shows its default CPU has the names.
- **The order** (Volume I's naming chapter): multi-letter Z extensions by the category letter after the Z, in the
  manual's order (I, M, A, F, D, Q, L, C, B, K, …), then alphabetically; S extensions after them, alphabetically.
  - With all six: `rv64imafdc_zicntr_zicond_zicsr_zifencei_zihintpause_zihpm_za64rs_zba_zbb_zbs_zkt_sstc_svinval`.
  - Without `svinval` (the recommendation unless measured):
    `rv64imafdc_zicntr_zicond_zicsr_zifencei_zihintpause_zihpm_za64rs_zba_zbb_zbs_zkt_sstc`.
  - Today's string puts `zicond` after `zbs`. The board's kernel prints its own order anyway (d4r2's `/proc/cpuinfo`,
    release_notes_v1.md:45).

## The check's results (soc-2, 10-24; the RTL of main 16b6d5d1)
- **`zicntr`: met.** `tg_csr` reads `cycle`, `time` and `instret` (0xC00–0xC02) as the hart's `mcycle`, the core's `mtime` copy and the hart's `minstret`. Below M, `mcounteren` gates 0xC00–0xC1F by bit, and in U `scounteren` as well. Both enables keep all 32 bits writable.
- **`zihpm`: met.** `hpmcounter3–31` (0xC03–0xC1F) read the HPM file, zero without `TG_HPM` and counters 3–6 with it, under the same gating.
- **`za64rs`: met.** Each hart's reservation is a 64-byte line (`tg_lsu` `rsv_line_q`, PA[33:6]), set by an LR as it completes and ended by any SC, a lost line or the sibling's store to it.
- **`zihintpause`: met.** Decode takes every MISC-MEM encoding with funct3 0 as a FENCE, whatever its fm, pred, succ, rs1 and rd, so PAUSE never traps. As a FENCE it serialises (bounded).
- **`zkt`: met** (core-2's audit, its MR ab2b2436): `tg_alu` and `tg_mul` have no operand-dependent early-out, and a cycle-exact directed test over every operand class gives identical counts.
- **The trees** (DR-194, sw/dts/tanager.dtsi): `rv64imafdc_zicntr_zicond_zicsr_zifencei_zihintpause_zihpm_za64rs_zba_zbb_zbs_zkt_sstc`, with `sscofpmf` before `sstc` in `TG_HPM` builds. `svinval` stays out. QEMU's tree keeps today's list (`TG_ISA_PRE194`), byte for byte main's.

## Not in the target
Outside core-priv.md's target, for the notes. v1 doesn't aim at RVA22S64 or RVA23S64 (release_notes_v1.md:49; DR-190).
- **`sscofpmf`:** listed only by a v1 built with `TG_HPM` (above).
- **Six names ACT4 already passes:** Svade (core-mmu.md:33), Sstvala, Sstvecd, Ssu64xl, Ssccptr and Sscounterenw
  (verification.md:1074). These are the profiles' names. A later check could list them from the same ACT4 record.
- **`zicbop`:** the prefetch hints run as no-ops (m9-plan.md, Summary), which a hint allows. Nothing is built.

## Sources
Each is in provenance.md §3.1:
- *The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA*, 20240411: the counters chapter (Zicntr, Zihpm),
  Zihintpause, FENCE's reserved settings, the scalar cryptography chapter's Zkt section, and the naming chapter.
- *Volume II: Privileged Architecture*, 1.13: the counter enables, and the Svinval chapter.
- *The RISC-V Profiles*: Za64rs.
