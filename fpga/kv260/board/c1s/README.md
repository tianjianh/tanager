# DR-150: c1s on the board, one smt2 core with the commit trace (2026-10-17)

**Package:** `c1s-smt2-c1-70` from the SoC track; bitstream sha256 `c8d72f0c…`; `tanager-host` `9774b126…` (p0d2's). Hashes in [`SHA256SUMS`](SHA256SUMS), build facts in [`summary.txt`](summary.txt).
- **Tree:** `be84cb83c375` (soc-2's `089f8f1`) = main `537f23b`, which has core-2's `a0631fb`, plus soc-2's branch: debug counters, stage C RTL off by default, `AreaOptimized_high` synthesis.
- **Design:** one v1 `smt2` core, one thread (hart 0), at 70 MHz; commit trace on, debug counters on; WNS +2.852 ns, WHS +0.010 ns.
- **Images:** p0's `fw_jump.bin` and `Image`; device trees with hart 0 only (`tanager-kv260.dtb` for the plain boot, `tanager-kv260-768m.dtb` for the trace).
- **Why:** p0, p0d and p0d2 (two smt2 cores) hang before OpenSBI prints. If one smt2 core hangs the same way, the bug is in the core, not in two cores together.
- **How it ran:** loaded as the app `tanager-c1s`, with Linux's fan control throughout (`pwm1` 15/255, 31–33 °C); back on `k26-starter-kits` after each run.

**Result: the same hang as p0, with one core. The trace shows wrong register values from the 7th instruction.**

**1. Plain boot** ([`shell_run1.txt`](shell_run1.txt)): `tg.sh shell` with `LOGIN_S=120 DBG=1`.
- **Console:** nothing on the PMOD console; `tanager-host` printed only its load line ([`linux_shell.txt`](linux_shell.txt)).
- **Counters:** `tanager-host dbg` twice, 5 s apart, identical, so frozen:

  | Counter | bank 0 | bank 1 | core 0 L1D |
  |---|---|---|---|
  | A (requests) | 3 in | 2 in | 0 out |
  | B, C, E | 0 | 0 | 0 |
  | D (beats) | 12 out | 8 out | 0 in |
  | misses / AXI reads / fills | 3 / 3 / 3 | 2 / 2 / 2 | |

- **The rest:** L2 error events 0; levels `0x00044555` (every handshake ready, nothing stuck valid); injector 5 reads, native latency average 20.6, maximum 22 cycles.
- **So:** as on p0d2, only the instruction cache's 5 line fetches happened. The data cache never sent a request.

**2. Traced boot** ([`tracefile_run1.txt`](tracefile_run1.txt), [`trace_console.txt`](trace_console.txt)): `tg.sh tracefile` with `TRACE_S=30 TRACE_WRAP=16`, the 768m tree, the window zeroed (1020 MiB in 1.4 s).
- **20 records, then nothing** for 30 s. The same 20 instructions as p0's hart 0.
- **Every record** ([`trace_dump.txt`](trace_dump.txt), from [`../trace_dump.py`](../trace_dump.py) on [`boot_c1s.trace`](boot_c1s.trace)):

  | # | cycle | pc | instruction | RTL wrote | right value |
  |---|---|---|---|---|---|
  | 0 | 128128 | `1000` | `csrr a0, mhartid` | a0 = 0 | ✓ |
  | 1 | 128140 | `1004` | `lui t0, 0x10001` | t0 = `10001000` | ✓ |
  | 2 | 128150 | `1008` | `ld a1, 16(t0)` (MMIO) | a1 = `82200000` | ✓ (DTB address) |
  | 3 | 128160 | `100c` | `ld t1, 8(t0)` (MMIO) | t1 = `80000000` | ✓ (entry) |
  | 4 | 128163 | `1010` | `jr t1` | | ✓ |
  | 5 | 128223 | `80000000` | `mv s0, a0` | s0 = 0 | ✓ |
  | 6 | 128223 | `80000004` | `mv s1, a1` | s1 = **`80000000`** | **✗ `82200000`**: t1's value |
  | 7 | 128224 | `80000008` | `mv s2, a2` | s2 = 0 | ✓ |
  | 8 | 128225 | `8000000c` | `jal fw_boot_hart` | ra = `80000010` | ✓ |
  | 9 | 128276 | `800007a8` | `c.li a0, -1` | a0 = −1 | ✓ |
  | 10 | 128277 | `800007aa` | `ret` | | ✓ |
  | 11 | 128289 | `80000010` | `mv a6, a0` | a6 = −1 | ✓ |
  | 12 | 128289 | `80000014` | `mv a0, s0` | a0 = **−1** | **✗ 0**: s0 now reads −1 |
  | 13 | 128290 | `80000018` | `mv a1, s1` | a1 = `80000000` | (s1's wrong value) |
  | 14 | 128290 | `8000001c` | `mv a2, s2` | a2 = **−1** | **✗ 0**: s2 now reads −1 |
  | 15 | 128291 | `80000020` | `c.li a7, -1` | a7 = −1 | ✓ |
  | 16 | 128292 | `80000022` | `beq a6, a7, _try_lottery` | taken | ✓ (given a6 = −1) |
  | 17 | 128304 | `8000002a` | `auipc a6, 0x40` | a6 = `8004002a` | ✓ |
  | 18 | 128305 | `8000002e` | `addi a6, a6, -42` | a6 = `80040000` | ✓ |
  | 19 | 128305 | `80000032` | `c.li a7, 1` | a7 = 1 | ✓ |
  | — | | `80000034` | `amoswap.w a6, a7, (a6)` | never retires | |

**3. The checker** ([`lockstep_c1s.txt`](lockstep_c1s.txt)): the verification track's `tanager-lockstep` (`694aff2`) on the trace, offline on the A53, with the same images and the 768m tree:
`MISMATCH at record 6 (cycle 128223): x9 value: RTL 0000000080000000, Spike 0000000082200000`, at `add s1, a1, zero`.

**Reading.**
- **One smt2 core is enough.** c1s hangs like the two-core builds, at the same instruction, so it isn't two cores together.
- **The first wrong value comes right after the boot ROM's two back-to-back MMIO loads,** which retire 10 cycles apart. The second load's value is in a1 as well as t1.
- **Later, s0 and s2 read back a newer −1** (the value `c.li a0, -1` wrote) instead of the 0 they were given.
- **All three look like one physical register held by two live names:** a1 with t1, and s0 and s2 with a later −1 writer. That points at register renaming: a free list or allocation handing out a register that is still mapped, or a writeback tag going to the wrong register.
- **The hang may be the same fault.** The `amoswap.w` reads a6 and writes a6. If its new destination register were also its source's register, it would wait for itself and never issue, which matches a data cache that never sees a request. That's a guess; the trace can't show register numbers.
- **Not the synthesis strategy:** c1s used `AreaOptimized_high`; p0 and p0d2 used the default (their synthesis logs on the 5950X have no directive), and hang the same way. p0's trace shows the same wrong values on both harts.
- **Candidates since the last one-core tree that booted here** (DR-141's `3eed95f`/`c129d19`, an `st` core): the core track's fn6 change "rename's free lists take their pop last" (`0c4b011`, via `4c904a4`), and the atomic path (`41a4eb7`, `755fe6b`). The simulation of this tree gets the values right, so the difference to look for is in timing the board has (MMIO answers in 10 cycles, line fills in about 60) or in how the hardware realizes a memory (read during write).
- **Reported** to soc-2, core-2 and verif-2, with the logs (`~/tanager-build/board/c1s-board/` on the 5950X).
