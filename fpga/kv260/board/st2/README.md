# DR-150: st2 on the board, two st cores, and the cause of the hang (2026-10-17)

**Package:** `st2-st-c2-70` from the SoC track; bitstream sha256 `9ecc8ee5…`; `tanager-host` `9774b126…`. Hashes in [`SHA256SUMS`](SHA256SUMS), build facts in [`summary.txt`](summary.txt).
- **Tree:** `be84cb83c375`, c1s's: main `537f23b` plus soc-2's branch (debug counters, `AreaOptimized_high`).
- **Design:** two v1 `st` cores (harts 0 and 1) at 70 MHz; commit trace and debug counters on; WNS +2.434 ns.
- **Images:** p0's `fw_jump.bin` and `Image` (the M4 ones); device trees with harts 0 and 1.
- **Why:** every core build that ran here before p0 was `st`. If st2 boots, the hang is `smt2`'s; if not, it is in the tree.
- **How it ran:** the app `tanager-st2`, with Linux's fan control throughout (15/255, 32–33 °C), back on `k26-starter-kits` after each run ([`run_shell.sh`](run_shell.sh), [`run_trace.sh`](run_trace.sh)).

## Result: st2 hangs the same way

- **Plain boot with the SMP test** ([`shell_run1.txt`](shell_run1.txt)): no login prompt in 120 s, nothing on the console.
  - **Counters:** two reads 5 s apart, identical. Bank 0: A 6 in, D 24 out; bank 1: A 4, D 16; 5 misses, 5 AXI reads. Both cores' L1D: A out 0, D in 0. No probes; L2 errors 0; levels `0x00044555`.
  - **Injector:** 5 reads, native latency average 20.4, maximum 22 cycles.
  - These are p0d2's numbers exactly: only the instruction fetches.
- **Traced boot** ([`tracefile_run1.txt`](tracefile_run1.txt); every record in [`trace_dump.txt`](trace_dump.txt), from [`boot_st2.trace`](boot_st2.trace)): 40 records, 20 per hart, then nothing.
  - **Both harts:** `mv s1, a1` gives `0x80000000` (t1's value) instead of `0x82200000`. `mv a0, s0` and `mv a2, s2` give −1, instead of the hart ID and 0.
  - **The stop:** neither hart retires the `amoswap.w` at `0x80000034`.
- **The checker** ([`lockstep_st2.txt`](lockstep_st2.txt), `--harts=2`): `MISMATCH at record 11 (cycle 130779): x9 value: RTL 0000000080000000, Spike 0000000082200000`.

## The control: the M4 bitstream on the same board, minutes later

[`../ctl-m4/`](../ctl-m4/README.md): `tanager-m4` (tree `20435b1`, one `st` core at 60 MHz), with the same `fw_jump.bin` and `Image`, the M4 768 MiB tree, today's `tanager-host` (`9774b126`) and today's A53 kernel. It was traced for 2 s, unwrapped.
- **The same first instructions are right:** `mv s1, a1` = `0x82200000`, `mv a0, s0` = 0, `mv a2, s2` = 0.
- **The OpenSBI banner prints.**
- **The checker passes all 5,050,605 records** (38.9 s on the A53).
- **The board's timing is the same** for both builds: the two MMIO loads 10 cycles apart, the first line fill about 60 cycles. So the board, the host and the images are fine. The fault is in the RTL between `3eed95f` (DR-141's builds, which booted Linux 9 times on 10-15) and `379aebb` (p0).

## The cause: `rn_fire` is undriven in hardware at rename's free lists

Vivado's synthesis logs ([`synth_rn_fire.txt`](synth_rn_fire.txt)) have this in every build that hangs, and in no build that booted:

```
WARNING: [Synth 8-3848] Net g_fl[0].rn_fire in module/entity tg_rename does not have driver. [rtl/core/rename/tg_rename.sv:154]
```

There are five per build: `g_fl[0..2]` (`:154`) and `g_ffl.g_b[0..1]` (`:172`).

| Build | Tree | Undriven `rn_fire` | On the board |
|---|---|---|---|
| dr141 fallback, default | `3eed95f` | 0 | Linux, 6 boots |
| dr141 default-no2 | `c129d19` | 0 | Linux, 3 boots |
| p0 | `379aebb` | 5 | hangs |
| p0d2 | `05b45ce` | 5 | hangs |
| c1s | `be84cb8` | 5 | hangs |
| st2 | `be84cb8` | 5 | hangs |
| sc1st | (building) | 5 | not run |

- **The code:** `tg_rename.sv` connects `.pop(rn_fire)` at lines 154 and 172, inside the generate blocks `g_fl[b]` and `g_ffl.g_b[b]`, but declares `logic rn_fire;` only at line 199.
- **What Vivado makes of it:** an undeclared identifier in a port connection becomes an implicit scalar net in the scope of the instantiation (IEEE 1800 §6.10), here each generate block. So it builds five separate nets that nothing drives. In hardware the free lists never take rename's pops.
- **What Verilator makes of it:** it resolves the name to the later module-level declaration, so simulation, the soak and the lockstep runs were right.
- **When it came in:** with `0c4b011` (core track, fn6, 2026-10-15 04:31: "the free lists take rename's fire separately from the pops"), inside the regression window.
- **It fits what the board shows:** registers still mapped are handed out again. a1 and t1 end up in one register; s0, s2 and a later −1 writer in another.
- **The fix:** declare `rn_fire` above line 150. Then `default_nettype none`, or a build gate on Synth 8-3848 / 8-6901 / 8-8895 in `rtl/`, keeps it from coming back.
- **Two more forward references in `be84cb8`:** `tg_dcache.sv:146-149` (an `always_comb` reads eight names declared at 211–246) and `tg_uncore.sv:693` (`dbg_sel`/`dbg_val`, Synth 8-8895). They are not implicit nets, but should be declared first too.
- **Sent** to core-2, soc-2, verif-2 and the coordinator (2026-10-17 00:40). The board runs the fixed build as soon as it is packaged.
