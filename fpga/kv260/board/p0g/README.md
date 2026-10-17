# DR-150: p0g on the board, the L2 error capture and the timer freeze (2026-10-17)

**Package:** `p0g-smt2-c2-70` from the SoC track; bitstream sha256 `10689e4b…`; `tanager-host` `1e5fca51…` (soc-2 `c2cc421`: `--freeze-time`, `--dbg`, the capture decode, the dma fix, `--net`). Hashes in [`SHA256SUMS`](SHA256SUMS), build facts in [`summary.txt`](summary.txt), the SoC track's notes in [`package_README.txt`](package_README.txt).
- **Tree:** `a39b13f826f2` (main `82463e2` with core-2's `73e88bd`, soc-2's branch, verif-2's `c665894`).
- **Design:** p0f's configuration: two `smt2` cores (harts 0 and 2), 70 MHz, trace and counters on; WNS +1.760 ns; 112,168 LUTs (95.8%).
- **New:**
  - The L2's first error and the first refused DRAM burst are captured whole.
  - `run --freeze-time` holds `mtime` while the trace stalls the cores.
  - core-2's debug words.
- **How it ran:** the app `tanager-p0g`, with Linux's fan control throughout (15/255, 32–33 °C).

## a. The traced boot that makes the L2 errors: confirmed as refused fills beyond RAM

[`a_run1.txt`](a_run1.txt), [`../runs/p0g_a.sh`](../runs/p0g_a.sh): the 768m tree, the trace into a wrapped 2^16 ring (`--trace /dev/null --trace-wrap`, no `--lossless`), 20 s. `dbg` was read from a second session at about +6 s, and `run --dbg` at the exit.

| When | L2 error events | DRAM window refusals | First L2 error | First refused burst |
|---|---|---|---|---|
| +6 s | 5,984 | 1,496 reads, 0 writes | bank 0, a fill read error, AXI resp 2 (SLVERR) | a read at `0xf273a280` |
| exit (20 s) | 6,072 | 1,518 reads, 0 writes | the same | the same |

- **Refusals × 4 fill beats = the error events, exactly.** The first refused read is the same address the SoC track's simulation of this tree found.
- **The SoC track's reading:**
  - These are line fetches beyond the 1 GiB DRAM window but inside the core's 2 GiB memory PMA, made by instructions that never commit.
  - Lockstep found no mismatch through such boots, and a committed one would fault.
  - The window keeps them off the A53's DDR, and the L2 answers with a denied Grant.
- **One oddity, sent back:** the capture's line and address read `0x0` for this kind (a fill read error). The refused burst carries the address.
- **core-2's debug words at the exit** (the full dump in the log):
  - core 0: `rename v1 … blk1 res1 …; rob 1; atomic IDLE; … trace stall0`;
  - core 1: `… atomic DONE (in window); sq head v1 … nonempty1; … trace stall0`.

## b. The plain boot (control): no L2 error

[`b_run1.txt`](b_run1.txt), console [`linux_shell_b.txt`](linux_shell_b.txt): `tg.sh shell` with the SMP test, 1 GiB tree, no trace.
- **The capture:** `L2 error events 0`, `DRAM window refusals 0 reads, 0 writes`, `no L2 error since the uncore reset`.
- **Linux:** "smp: Brought up 1 node, 2 CPUs"; login at 6 s. The SMP test is as on p0f: one busy loop 48 s, two in parallel 48 s. Power-off at 113 s.

## c. Two-core lockstep with `--freeze-time` on the plain 10 MHz tree

Run: `runs/lockstep.sh` with `LS_HOST_ARGS=--freeze-time` (`tg.sh ls-linux` passes it to `tanager-host`), checker `694aff2`, `--harts=4`.

**Result: pass** ([`ls_run1.txt`](ls_run1.txt), [`ls_p0g-ft.log`](ls_p0g-ft.log), [`ls_console_p0g-ft.txt`](ls_console_p0g-ft.txt)).
- **Verdict:** `PASS after 395612106 records (395596818 retired, 13052 traps, 2236 interrupts, 0 writebacks) in 4165.8 s, 94966 records/s`, with `126 loads read bytes another hart's recent write had replaced; 2 atomics read past a store, which then followed them`.
- **The path:** `TANAGER-BOOT-OK` at 2,042 s, the login prompt at 2,132 s, the root shell at 2,214 s, then `poweroff`. Boot exit 0, checker exit 0.
- **The kernel's clock behaves as in an unchecked boot:** `/init` at 0.368 s, against 9.8 s with p0f's 1 GHz-timebase workaround and 731 s on M4's real-time clock.
- **Shorter than the workaround:** 395.6 M records against 408.4 M, and interrupts at the pace of execution (2,236 against 19,840).
- **So the workaround tree is retired:** lockstep runs use `--freeze-time` with the normal tree.
