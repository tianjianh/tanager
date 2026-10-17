# Control for DR-150: the M4 bitstream traced on 2026-10-17

The question: does a tree that booted on this board still boot today, with the same images, today's `tanager-host` and today's A53 kernel? If yes, the hang of p0, p0d2, c1s and st2 is in their RTL.

- **Bitstream:** the app `tanager-m4`: tree `20435b1`, one `st` core at 60 MHz, sha256 `2f71d6ce…`. It booted Linux in FPGA lockstep on 2026-10-15.
- **Images:** the lockstep set's `fw_jump.bin` and `Image` (sha256 `b0094d23…` and `cea2bf66…`, the same files as p0, c1s and st2), with `tanager-kv260-768m.dtb`.
- **Host:** `tanager-host` `9774b126` (st2's) on kernel `6.8.0-1036-xilinx`.
- **Run** ([`run_ctl.sh`](run_ctl.sh), [`ctl_run1.txt`](ctl_run1.txt)): `tg.sh tracefile` with `TRACE_S=2`, unwrapped. The window was zeroed (768 MiB in 1.0 s).
  - **Console:** OpenSBI's banner ([`trace_console.txt`](trace_console.txt)).
  - **Trace:** 5,050,605 records (323 MB) in 2 s, deleted after the check; the first 20 kept as [`first20.trace`](first20.trace).
- **First 20 records** ([`trace_dump_first20.txt`](trace_dump_first20.txt)): right where st2's are wrong:
  - `mv s1, a1` = `0x82200000`;
  - `mv a0, s0` = 0;
  - `mv a2, s2` = 0.
- **The checker** ([`lockstep_ctl.txt`](lockstep_ctl.txt)): `PASS after 5050605 records (5050599 retired, 6 traps, …) in 38.8 s, 130283 records/s`.
- **The PMOD console** ([`uart_COM5.txt`](uart_COM5.txt), logged on the laptop's COM5 from st2's first run on). st2's runs printed nothing. The control's core kept running after `tanager-host` stopped at 2 s, through Linux to `TANAGER-BOOT-OK 6.18.56-tanager harts=1` and the login prompt, until the restore unloaded it about 70 s later.

**So:** the board, the host and the images are fine. See [`../st2/README.md`](../st2/README.md) for the cause.
