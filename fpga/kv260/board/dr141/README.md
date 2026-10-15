# DR-141 profile runs on the KV260 (2026-10-15)

The board track ran the verification track's Linux workload set on the three core profiles of DR-141.

## Setup

- **Profiles:** the SoC track's packages, one `st` core at 60 MHz each, all on the same uncore:

  | Profile | Timing cuts | WNS | Tree |
  |---|---|---|---|
  | `fallback` | #2 #4 #5 off | +2.595 ns | `3eed95f` |
  | `default` | #2 #4 #5 on | +3.651 ns | `3eed95f` |
  | `default-no2` | #4 #5 on, #2 off | +3.355 ns | `c129d19` |

  The trees are recorded in each `summary.txt`. `tanager-host` was `47552f27` throughout.
- **Image:** `dr141-linux` (Buildroot `tanager_lp64d_bench`, the workload set at `ceeace5`, `tanager-kv260-bench.dtb`), the same for all three profiles.
- **Method:**
  - Each profile was loaded as its own dfx-mgr app, with Linux's fan control throughout.
  - It booted the image 3 times at native latency (`board/tg.sh bench`, `--lossless`).
  - Each boot runs all 18 tests 3 times and powers off, so every test has 9 runs per profile.
- **Checks** (verification.md §4.6), all 9 boots:
  - `TGLB-INFO counters=cycle,instret,time … perf_events=2 perf_errno=0`;
  - 54 measurement lines, all with nonzero cycles;
  - 6 × "Correct operation validated";
  - `TGLB-END status=0`, then power-off.
- **Times:** `TANAGER-BOOT-OK` came 8–9 s after the load, and a whole boot took 504–507 s to power-off.

## Cycles per operation

The median of 9 runs per profile, from `tglb_compare.py` (verification track) on each profile's three logs joined (`fallback=… default=… no2=…`). Δ is against `fallback`. The spread is the widest (max − min) / median in any profile; a change inside it is not a finding.

| test | fallback cycles/op | default Δ | no2 Δ | spread |
|---|---|---|---|---|
| forkexec | 3,219,330 | 3,234,975 (+0.5%) | 3,239,207 (+0.6%) | 0.9% |
| syscall | 545 | 550 (+0.9%) | 532 (-2.4%) | 0.2% |
| memcpy-64 | 82.19 | 81.27 (-1.1%) | 82.20 (+0.0%) | 0.5% |
| memset-64 | 62.54 | 62.65 (+0.2%) | 62.63 (+0.1%) | 0.5% |
| memcpy-4096 | 1,213 | 1,214 (+0.1%) | 1,213 (+0.0%) | 0.6% |
| memset-4096 | 731 | 730 (-0.1%) | 731 (-0.0%) | 0.5% |
| memcpy-1048576 | 2,243,195 | 2,296,413 (+2.4%) | 2,285,952 (+1.9%) | 0.5% |
| memset-1048576 | 902,371 | 922,173 (+2.2%) | 911,719 (+1.0%) | 5.4% |
| pipe | 229,324 | 229,624 (+0.1%) | 229,389 (+0.0%) | 0.8% |
| tmpfs-write | 209,277 | 210,467 (+0.6%) | 209,988 (+0.3%) | 1.8% |
| tmpfs-read | 146,275 | 146,941 (+0.5%) | 146,764 (+0.3%) | 0.7% |
| pagefault | 9,602 | 9,641 (+0.4%) | 9,599 (-0.0%) | 1.7% |
| tlbwalk | 121 | 122 (+1.1%) | 122 (+1.1%) | 0.3% |
| gzip | 1,884,243,620 | 1,892,884,495 (+0.5%) | 1,886,026,513 (+0.1%) | 0.4% |
| sha256sum | 221,512,376 | 221,782,893 (+0.1%) | 221,560,264 (+0.0%) | 0.1% |
| coremark-a | 366,505 | 366,728 (+0.1%) | 366,187 (-0.1%) | 0.2% |
| coremark-b | 442,538 | 442,151 (-0.1%) | 442,821 (+0.1%) | 0.1% |
| dhrystone | 405 | 414 (+2.3%) | 411 (+1.5%) | 0.1% |

`cmp_instret.md` (instructions per operation) and `cmp_ns.md` (wall time) hold the same comparison by those metrics.

## Reading

- **Instructions per operation are identical across the profiles,** within 0.3%, with the largest difference in `forkexec`. So the cycle differences are the core's timing, not different work.
- **Changes larger than the spread:**
  - **`default` against `fallback`:** `memcpy-1048576` +2.4%, `dhrystone` +2.3%, `tlbwalk` +1.1%, `syscall` +0.9%, `gzip` +0.5%; `memcpy-64` −1.1%.
  - **`default-no2` against `fallback`:** `memcpy-1048576` +1.9%, `dhrystone` +1.5%, `tlbwalk` +1.1%; `syscall` −2.4%.
- **No change beyond the spread:** CoreMark (both flag sets, ±0.1%), `sha256sum`, `pipe`, the tmpfs tests, `pagefault`, `memset`, and `forkexec`.

## Files

- **Console logs:** `<profile>_boot<k>.txt`, one per boot.
- **The board script's output:** `fallback_run.txt`, and `default_no2_run.txt` for the two later profiles.
