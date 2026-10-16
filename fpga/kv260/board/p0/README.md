# DR-147 Phase 1: the first two-core boot on the KV260 (2026-10-16)

**Package:** `p0-smt2-c2-70` from the SoC track, built from main `379aebb`.
- **Design:** two v1 `smt2` cores, one thread each (harts 0 and 2), at 70 MHz; the default profile, with the commit trace.
- **Timing:** WNS +1.419 ns.
- **Images:** `fw_jump.bin` and `Image` are the M4 ones. `tanager-kv260.dtb` has harts 0 and 2 and 1 GiB.
- **How it ran:** loaded as the dfx-mgr app `tanager-p0` with `board/tg.sh`, with Linux's fan control throughout (15/255).

## Result: the two harts deadlock on OpenSBI's first atomic

- **Plain boot** (`tg.sh shell`, [`shell_run1.txt`](shell_run1.txt)): no console output in 800 s, on neither the host copy nor the PMOD UART.
  - `tanager-host info`: "cores running, uncore running, L2 ready".
  - Injector: "5 reads, native latency avg 21.8 max 24 cycles", flat over time.
  - `UART_TX_LEVEL` 0, `tohost` 0.
- **Traced boot** (`tg.sh tracefile`, 60 s, window zeroed, `tanager-kv260-768m.dtb`; [`tracefile_run1.txt`](tracefile_run1.txt), [`boot.trace`](boot.trace)): 40 records, 20 per hart, then nothing.
  - **Both harts run in step from reset:** their records alternate, hart 0 then hart 2.
  - **What they run:** `fw_boot_hart` (returns −1), then the boot lottery's set-up, up to `c.li a7,1` at `0x80000032`.
  - **Where they stop:** neither retires the next instruction, `0x80000034`: `amoswap.w a6, a7, (a6)` (`0x0918282f`), with `a6` = `0x80040000` (`_boot_lottery`, zeroed).
  - **So:** two AMOs to the same line, one from each core and issued together, never complete. That points to a coherence race in the L1D/L2 between the two cores' requests for one line.
  - **Not seen in simulation:** the SoC track's model passed this design through "2 CPUs", probably because its harts reach the lottery at different times, or with a different memory latency.
- **Reported** to the SoC track with the trace (`~/tanager-build/board/p0-board/` on the 5950X).

**Files:**
- `smp_cmds.txt`: the SMP sanity test meant for the console once Linux is up (both CPUs in `/proc/cpuinfo`, one busy loop alone against two in parallel, `/proc/stat` per CPU, the IPI counters).
- `trace_console.txt`: the traced run's console.
