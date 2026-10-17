# DR-147/DR-150: p0d2 on the board, the two-core boot with debug counters (2026-10-16)

**Package:** `p0d2-smt2-c2-70-dbg` from the SoC track; bitstream sha256 `cfab9edd…`; `tanager-host` `9774b126…`.
- **Tree:** `05b45ce` = main `7f14964`, plus soc-2's `d515f6b` debug counters, plus core-2's `a0631fb` probe hold-off (the livelock fix).
- **Design:** two v1 `smt2` cores, one thread each (harts 0 and 2), at 70 MHz; no commit trace, so it fits; WNS +2.887 ns.
- **Images:** p0's.
- **How it ran:** loaded as the app `tanager-p0d2`, with Linux's fan control throughout.
- **The run** ([`shell_run1.txt`](shell_run1.txt)): `tg.sh shell` with `LOGIN_S=120 DBG=1`.

**Result: the same hang as p0.**
- **Console:** no output on either console, so no OpenSBI banner.
- **Counters:** `tanager-host dbg` read twice, 5 s apart, during the hang. Both reads were identical, so it's frozen, not a livelock:

  | Counter | bank 0 | bank 1 | core 0 L1D | core 1 L1D |
  |---|---|---|---|---|
  | A (requests) | 6 in | 4 in | 0 out | 0 out |
  | B (probes) | 0 | 0 | 0 | 0 |
  | C (probe acks) | 0 | 0 | 0 | 0 |
  | D (grants or data, beats) | 24 out | 16 out | 0 in | 0 in |
  | E (GrantAck) | 0 | 0 | 0 | 0 |
  | misses / AXI reads / fills | 3 / 3 / 3 | 2 / 2 / 2 | | |

- **The rest of the readout:** L2 error events 0. Levels `0x00044555`: every handshake ready, nothing valid without ready. Injector: 5 reads, native latency average 20.8, maximum 23 cycles.

**Reading.**
- **Only instruction fetches happened:** neither core's data cache sent a request. The L2's 10 requests are the two cores' instruction-cache fetches (5 lines each, the second core hitting), which are the 5 DRAM reads.
- **The stall is before any coherence traffic:** p0's trace shows the first data access of the boot is the lottery's `amoswap.w` at `0x80000034`. Here it never becomes a data-cache request, on either core. The stall is between the load/store unit and the data cache, so it is not the probe ping-pong that `a0631fb` fixes.
- **Reported** to soc-2, core-2 and verif-2, with the logs (`~/tanager-build/board/p0d2-board/` on the 5950X).
