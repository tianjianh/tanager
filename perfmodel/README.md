# tgsim: Tanager performance model (milestone M1)

`tgsim` is a cycle-level timing model of the Tanager out-of-order RV64 core, and of a NaxRiscv-like configuration used as the control.
- **Execution driven:** a functional RV64/RV32 instruction-set simulator produces the correct-path instruction stream. It covers IMAFDC, Zicsr, Zba, Zbb, Zbs and Zicond, with real F and D arithmetic.
- **Timing:** the model charges each instruction its front-end, rename, scheduling, execution, memory and commit costs.
- **No wrong path:** wrong-path instructions are not simulated. A mispredicted branch stalls fetch until it resolves, which charges the full redirect penalty.
- **SMT2:** with `threads=2` the core runs two programs at once, one per hardware thread (plan §6). See [SMT2](#smt2-two-hardware-threads).
- **Provenance:** everything here was written from scratch for this project.

Results and decisions are in [`docs/perf/dse_report.md`](../docs/perf/dse_report.md) and
[`docs/perf/feature_ledger.md`](../docs/perf/feature_ledger.md); the SMT2 study is in
[`docs/perf/smt2_report.md`](../docs/perf/smt2_report.md).

## Requirements

Everything runs inside WSL **Ubuntu 24.04**. From Windows, either prefix commands with `wsl.exe -d Ubuntu-24.04 -- bash -c '...'`, or open an Ubuntu shell and `cd` to this directory.

| Tool | Version | Installed by |
|---|---|---|
| Host compiler for tgsim | GCC 15.2 (`g++-15`, `ppa:ubuntu-toolchain-r/test`) | `scripts/setup_host_gcc15.sh` (root) |
| RISC-V cross compiler | xPack `riscv-none-elf-gcc` 15.2.0-1 (newlib), SHA-256 verified | `scripts/fetch_deps.sh` (user, into `~/opt`) |
| CoreMark | eembc/coremark `1f483d5b` | `scripts/fetch_deps.sh` (into `third_party/`) |
| Embench-IoT | tag `embench-1.0` (`0466a18e`) | `scripts/fetch_deps.sh` |
| Dhrystone 2.1 | netlib `dhry-c`, SHA-256 `038a7e91…` | `scripts/fetch_deps.sh` |
| Python | 3.12 (Ubuntu 24.04 default), standard library only | |

Pinned versions are recorded in `third_party/VERSIONS.txt`. The Makefile forces `g++-15`: make's built-in `CXX` default is `g++`, which is GCC 13 on Ubuntu 24.04.

## Build and check

```bash
sudo bash scripts/setup_host_gcc15.sh      # once: host g++-15
bash scripts/fetch_deps.sh                 # once: cross GCC 15 + benchmark sources
make -j"$(nproc)"                          # builds build/tgsim with g++-15 -std=c++23 -O2
bash tests/run_sanity.sh                   # hello.c on 4 ISAs vs a native g++-15 build
bash bench/build_all.sh                    # the DSE suite, 33 workloads per ISA -> build/bench/<isa>/manifest.jsonl
bash bench/build_extra.sh                  # targeted kernels and coremark_N -> build/bench/<isa>/extra.jsonl
bash bench/build_ws.sh                     # working-set kernels, 0.5-4 MiB -> build/bench/<isa>/ws.jsonl
bash bench/build_m7.sh                     # M7's FP-restore tests -> build/bench/<isa>/m7.jsonl
bash scripts/verify_all.sh                 # functional check of every workload (CRCs, outputs, exit codes)
```

Files with Windows line endings will not run under bash; if a script fails with `$'\r': command not found`,
run `sed -i 's/\r$//' <script>`.

### Workloads

**The DSE suite** (`bench/build_all.sh`, suite revision 2):

| Group | Workloads | Notes |
|---|---|---|
| kernels | `coremark_A`, `coremark_B`, `dhrystone` | CoreMark, 20 iterations:<br>flag set A `-O2 -funroll-loops -fpeel-loops -fgcse-sm -fgcse-las`<br>flag set B `-O3 -funroll-loops`<br>Dhrystone, 20,000 runs: `-O3 -fno-inline` |
| embench | the 19 Embench-IoT 1.0 programs | `-O2`, `CPU_MHZ=1`, `WARMUP_HEAT=1` |
| memsuite | pointer chases: `ms_chase1`, `ms_chase8`, `ms_chase8f16`, `ms_chase16`<br>streaming: `ms_stream`, `ms_copy`<br>others: `ms_hashprobe`, `ms_spmv`, `ms_bsearch`, `ms_stride`, `ms_gather` | our own memory-latency kernels (8–32 MiB); fast-forwarded to the timed loop |

- **What revision 2 added:** `ms_stride` and `ms_gather`. These are independent misses whose consumers wait in the window; without them, no kernel stressed the issue queues and ROB under misses.
- **FP content:** the rv64gc builds are hard-float (lp64d). FP is 30–50% of dynamic instructions in `ms_stream`, `ms_spmv`, `embench_minver`, `embench_st` and `embench_nbody`.

**Extra workloads** (`bench/build_extra.sh`; not in the suite geomean):

| Workload | What it is | Used for |
|---|---|---|
| `tk_bigcode` | about 200 KiB of code | I-side prefetch, L1I |
| `tk_bsearch_l2` | an L2-resident binary search, 47 branch MPKI | branch recovery, checkpoints |
| `tk_histo` | a store-to-load aliasing histogram | memory-dependence prediction |
| `tk_dgemm` | an L1-resident, 4×4-blocked double matrix multiply | FP issue width, FP queue |
| `coremark_N` | CoreMark built the way NaxRiscv's published RV64 score was (`ee_u32` signed) | the CoreMark cross-check only; never a valid score |

**Working-set kernels** (`bench/build_ws.sh`; not in the suite geomean). DR-141's Linux-like working sets of 0.5–4 MiB, which the suite lacks: its kernels fit the L1s, and its memsuite needs 8–32 MiB. Each runs without fast-forward and touches its data before the region, so the region starts with as much of the working set cached as fits.

| Workload (`<k>` = 512, 1024, 2048, 4096 KiB) | What it is |
|---|---|
| `ws_chase1_<k>` | one random pointer chain over `<k>` KiB of 64-byte nodes (latency) |
| `ws_chase8_<k>` | eight chains over `<k>` KiB (memory-level parallelism) |
| `ws_hash_<k>` | lookups in a half-full `<k>` KiB open-addressing hash table (random reads, branches) |
| `ws_copy_<k>` | memcpy within `<k>` KiB (source and destination half each), about 2 MiB copied per region |

**How workloads are measured.** Each workload brackets its timed region with MMIO marker stores (`bsp/tgsim.h`), and only the region is measured.

ISA builds:
- `rv64gc`;
- `rv64gcb` (`rv64gc_zba_zbb_zbs_zicond`);
- `rv32im` (for the NaxRiscv calibration);
- `rv64imac` (soft float, for the Embench cross-check).

## Running

```bash
build/tgsim --params                                   # every parameter with its default (Tanager v1)
build/tgsim --preset nax --set dram_lat=120 build/bench/rv64gc/coremark_A.elf
build/tgsim --iss-only build/bench/rv64gc/coremark_A.elf # functional only
```

**Presets:**
- `tanager_v1` (the default): plan draft 0.3.
- `v1_freeze`: the approved M1 freeze (plan draft 0.4, `docs/perf/feature_ledger.md`).
- `nax`: the NaxRiscv-like control, with NaxRiscv's core structures on the same uncore.
- `nax_cal`: `nax` with NaxRiscv's own memory system, meaning no L2 and 30-cycle DRAM. Used only for calibration.
- `rtl_m2`: **the core as built**, calibrated against the RTL (`docs/perf/area_recovery.md` §6.3–§6.9; revision 7):
  - M2's front end: the micro-BTB is the only predictor, trained in the way that predicted the instruction (else a pseudo-random way), and a 32-bit instruction straddling two blocks is decoded with the second, never predicted or trained;
  - recovery at commit; speculative load wakeup, as main has it since DR-154 (an integer load's dependants issue three cycles after it, a forward completing at M2 counts as a hit, and a load that does not complete in M2, a D$ row clash included, cancels the next three cycles' issues);
  - four L1D misses in flight (main's default since DR-156) and one I$ refill, no prefetchers;
  - the RTL's issue queues (rows in banks by dispatch slot, each held until two cycles after its select; an ALU op's queue picked at rename from the banks' flags counting the group in the dispatch stage, STEER_LA) and its store address, which issues on its base alone (STA_BASE; DR-169); a load that finds its store's address before the data cancels the speculative-wakeup shadow, and a committed store writes the D$ a cycle after its commit at the earliest;
  - the RTL's latencies;
  - the memory of `tg_vsim`: no L2, a flat 30 cycles.

  With `--set l2_kb=1024 ...` it runs on the SoC's uncore.

**The RTL platform's ELFs.** tgsim also runs ELFs built with `tests/bench/bsp`, as tg_vsim does. Their 16550's status register reads as ready, and stores to the ELF's `tohost` and `tg_marker` symbols exit and mark the region. `bench/build_rtl.sh` builds some of the suite that way, so both simulators run the same binaries (`scripts/rtlcal.py`).

`--set name=value` overrides any parameter after the preset is applied; `--json FILE` writes all statistics.

**Design-space options.** These parameters are off by default; `--params` lists them all.

| Parameter | What it models |
|---|---|
| `fuse_alubr`, `fuse_1slot` | ALU+branch fusion; fused pairs taking one decode slot (pair decode) |
| `ld_ports` | a second load pipe |
| `fp_ports` | a second FMA pipe |
| `alu3`, `iq_a2` | a third ALU port, with its own queue and register bank |
| `fdiv_ii` with `lat_fdiv_*` / `lat_fsqrt_*` | a pipelined divide/sqrt unit, for example Goldschmidt |
| `decode_width` / `commit_width` | wider machines |
| `threads` with `smt_*` | SMT2: two programs on two hardware threads (below) |

| Script | Purpose |
|---|---|
| `scripts/tgrun.py --isa rv64gc --preset tanager_v1 [--set k=v] [--bench REGEX] [--manifest extra]` | runs workloads in parallel, checks them, prints per-workload IPC and suite scores |
| `scripts/calib.py` | calibrates the `nax_cal` preset against NaxRiscv's published RV32 IPC; writes `results/calibration.json` |
| `scripts/dse.py <isa>` | the main exploration:<br>baselines at 30/60/90/120/250 cycles;<br>21 ablations, the early-retirement study and 15 sweeps at 30/120/250;<br>writes `results/dse_summary_<isa>.json` |
| `scripts/dse.py <isa> --baseline` | baselines only (used for rv64gcb) |
| `scripts/dse.py rv64gc --targeted` | the extra workloads under feature on/off configurations → `results/targeted_rv64gc.json` |
| `scripts/dse.py rv64gc --greedy` | **the v1 freeze**, the acceptance rule applied to the combined design:<br>from a lean configuration, add the size increment with the best IPC gain per LUT at 120 cycles while gain ≥ LUT cost and the 30/250-cycle guards hold;<br>writes `results/greedy_rv64gc.json` |
| `scripts/dse.py <isa> --freeze` | the greedy result and its exception variants at every latency point, each against a control with the same uncore → `results/freeze_<isa>.json` |
| `scripts/dse.py rv64gc --width [--alu3]` | front-end width study: 3-wide decode/rename/commit, a third ALU, and a µop-cache upper bound → `results/width_rv64gc.json` |
| `scripts/report.py <isa>` | generated tables and charts in `docs/perf/` (`dse_tables*.md`, `ledger_table.md`, `*.svg`) |
| `scripts/recheck.py [isa] [N]` | re-simulates cached configurations and reports any change (use after rebuilding tgsim) |
| `scripts/recheck.py --freeze` | runs `--preset v1_freeze` on the whole suite at 30/120/250 cycles and compares every region statistic with the cached M1 freeze runs |
| `scripts/smt.py` | the SMT2 study (42 thread pairs; policies, partitions, sizes, the M1 options, a greedy sizing pass) → `results/smt2_rv64gc.json`. Other modes:<br>`--bundles`: the sizing pass with whole-window steps (the proposed SMT2 core);<br>`--width3`: the same pass on a 3-wide, 3-ALU SMT2 core (plan §6.2 rule 12);<br>`--supplementary`: window sharing × issue-queue caps, and window bundles;<br>`--explore`: the policy and cap exploration;<br>`--validate`: the SMT consistency checks (needs `bash tests/build_idle.sh` first) |
| `scripts/smt_tables.py` (or `smt.py --tables`) | generated SMT2 tables → `docs/perf/smt2_tables.md` |
| `scripts/area.py` | the area-recovery study (plan §8.5, D18): each IPC-costing lever alone on v1 (`smt2`) and v2 (`smt2_w3`), at 30/120/250 cycles, on the 42 pairs and the single-thread suite → `results/area_recovery.json`. Other modes:<br>`--combos`: the levers that pass the reverse rule, added greedily (each saving recomputed on top of the levers taken), the v2 re-plan options, window growth with wakeup tags, and the single-thread variants;<br>`--census`: the dependency census on v1 and v2 (pairs and single-thread suite);<br>`--tables`: generated tables → `results/area_tables.md` (used by `docs/perf/area_recovery.md`).<br>About 3 hours on 8 threads from an empty cache. |
| `scripts/area_fit.py --core <run>/latest.json --uncore <run>/latest.json [--cfg smt2]` | the device fit from per-unit budget runs (`docs/perf/area_recovery.md` §7). It reads the budget flow's `latest.json` for a core configuration and for the uncore, and adds hart 1's state (estimated) until M7 builds it. It prints each unit against `fpga/budget/budgets.tsv`, and the dual-core total against the 200 MHz and 180 MHz fill limits. It keeps §7.7's gap table current. |
| `scripts/rtlcal.py --vsim <tg_vsim> ELF...` | the calibration (`docs/perf/area_recovery.md` §6.3): the same ELFs in tg_vsim and in tgsim with `rtl_m2`, at native and 120-cycle latency, with region cycles per program. RTL results are cached in `results/rtlcal_rtl.json`. At most 8 runs at a time. `TGSIM_MPDUMP=file` makes tgsim write its mispredicts by PC, and `scripts/rtl_mpcmp.py` sets them against the RTL's commit-trace refills |
| `scripts/m6_rtlcheck.py` | the first M6 stack against the RTL (`docs/perf/area_recovery.md` §6.4): core-2's stack on make perf's ELFs, with each correction to the model added in turn, against the RTL's scores; `--levers` measures two RTL questions (the store address on its base alone, rows freed at select). `scripts/rtlprof/` holds the measurement-only profile binds used to find the corrections (`make -C sim CFG=st COV_EVENTS=<file>` on a scratch tree; not for commit to `sim/`) |
| `scripts/m6_swfit.py [--prof=DIR]` | speculative wakeup's cancels, the model against fpu-2's RTL profile (`docs/perf/area_recovery.md` §6.6): the RAS head and TAGE-lite builds, with the D$ row clash and fast forwards added in turn, make perf's regions at both lengths and CoreMark's steady state → `results/m6_swfit_rv64.json` |
| `scripts/m6_area.py` | what M6's remaining pieces buy per 1K LUTs from main with the RAS (`docs/perf/area_recovery.md` §6.5): `rtl_m2` with the RAS, on the suite (the SoC's uncore at 100 MHz) and make perf's bench; each piece alone and after TAGE-lite 4 × 1K, then stacked by marginal gain per chip LUT, with measured LUTs where core-2 has them and ledger estimates elsewhere → `results/m6_area_rv64.json` |
| `scripts/m6_fe.py --prof=DIR` | the front end of core-2's TAGE-lite build, the RTL's profile against the model (`docs/perf/area_recovery.md` §6.7): every F2 refetch and redirect by cause, with its rate and the decode slots it costs, on make perf's regions (`rtl_m2` revisions 4 and 5 beside the RTL) and the Linux boot's first 20M cycles (RTL only); DIR holds the logs of `scripts/rtlprof/prof_f2cut.sv` → `results/m6_fe_rv64.json` |
| `scripts/m6_rs.py --prof=DIR` | rename's stalls on core-2's TAGE-lite build, the RTL's profile against the model (`docs/perf/area_recovery.md` §6.8): every cycle decode is held, by cause (each issue queue's bank, ROB, LQ, SQ, free lists, tags, serializing uops), with the blocking bank's rows by state, on make perf's regions and the RTL suite (`rtl_m2` revisions 5 and 6), and the model's prediction for the store address issuing on its base alone; DIR holds the logs of `scripts/rtlprof/prof_rs.sv` → `results/m6_rs_rv64.json` |
| `scripts/m6_rank.py [--boot NAME=LOG]...` | M6's remaining pieces re-ranked on main's M6 set (`docs/perf/area_recovery.md` §6.11): `rtl_m2` revision 7 with the RAS, TAGE-lite 2 × 2K and F2's returns, each piece alone on make perf's bench, the suite (the SoC's uncore at 100 MHz) and the Linux-like workloads (`tk_bigcode`, `tk_bsearch_l2`, the `ws_*` working sets; `bench/build_extra.sh`, `bench/build_ws.sh`), with LUTs per chip; each `--boot` log of `scripts/rtlprof/prof_m6.sv` (with `prof_f2cut.sv`) adds the boot's cycles without a commit by cause and each piece's estimated share of the boot (with two cores, the boot core's counters) → `results/m6_rank_rv64.json` |
| `scripts/rtlprof/prof_window.py LOG FROM TO` | a window of the boot profile: run `tb_boot` with `scripts/rtlprof/prof_m6.sv` bound and `+prof_snap=N`, and each core prints its counters every N cycles (`smt2_prof_m6@CYCLE [INSTANCE] ...`); this differences the snapshots at cycles FROM and TO per core and prints each stall class as a share of the window's cycles (`docs/perf/area_recovery.md` §6.14) |
| `scripts/m6_board.py [--bench DIR --rtl CFG=LOG... --predict] [--layout DIR] [--init NAME=LOG...] [--copy]` | the model and the RTL against the board's M6 Linux runs (`docs/perf/area_recovery.md` §6.12–§6.14): with `--bench`, `rtl_m2` as d2's core and as M6's, in make perf's configuration (st) and the board's (smt2: ROB 80, LQ 24, SQ 20, 24 LLTs), on make perf's ELFs, beside the RTL's make perf on both trees (`tools/ci/perf.py`'s logs) and the board's IPC (MR18), and `--predict` d4r1's prediction; `--layout` the code-placement check (`scripts/rtlprof/layout.sh`); `--init` the boot to /init in `tb_boot` (`scripts/rtlprof/brd_init.sh`, d2, d4s2 and d4r1) phase by phase against the board's kernel logs, less the console time on each milestone's path (a console line holds only the thread that prints it; the async initramfs unpack runs through the init thread's lines), with d4r1's prediction against the board (MR23) and the unpack's own window; `--copy` the ownership prefetch on `ws_copy` against the board's memcpy of 1 MiB. Sections not rerun keep their earlier results → `results/m6_board_rv64.json` |
| `scripts/m7_smt.py [--exit2] [--policy] [--deadlock] [--fp] [--lone] [--prediction] [--groups] [--d3rev] [--pair] [--homes]` | M7's questions on `rtl_m2` revision 7 as the smt2 core (`docs/perf/smt2_report.md` §13): exit 2's weighted throughput over §2.3's 42 pairs at 30, 120 and 250 cycles against one program on the merged window; ICOUNT against round robin and the issue-queue caps, with the dispatch-slot bank rules (`smt_iq_cap_bank`); D8's deadlock search on the 10-16 setup and M7's core (`drain_guard`, `smt_drain_rr`); D3's per-hart free lists on a lone thread and FP-heavy pairs (`prf_split`, `prf_steer`, `bench/build_m7.sh`'s FP restores); D2's lone thread with its sibling asleep (`lone_*`); one thread a decode/rename/commit group (`smt_mix`); D3 as revised (`prf_xfer`, `prf_fp_bank`, `flush_walk`); `--pair`: exit 2 on verif-2's pair runner (`tests/bench/pair`, its ELFs in `TG_PAIRDIR`), with its barrier at the first marker (`smt_align`) and its programs at their own slot addresses (`smt_pa_flat`); `--homes`: D4's alternatives for hart 1's register homes (`prf_homes`); runs that may deadlock are cached with their errors in `results/m7/` → `results/m7_smt_rv64gc.json` |
| `scripts/m6_lev.py --meas=FILE --prof=DIR` | DR-169's levers measured in RTL against the model (`docs/perf/area_recovery.md` §6.9): fpu-2's region cycles for each lever alone and both (FILE, its stl_17.tsv) beside the model's predictions under revisions 6 and 7, and revision 7 against the levers tree's load profile (DIR, from `scripts/rtlprof/prof_sta.sv`) → `results/m6_lev_rv64.json` |
| `scripts/m6_steps.py` | the M6 features from the core as built (§6.3), at 100 MHz's latencies with the SoC's L2 and 115 MHz's alongside: each feature alone; stacked greedily by suite gain per LUT with the running LUT total; and in the plan's order. Then one core at 100 MHz against NaxRiscv at 135 and 150 MHz → `results/m6_steps_rv64gc.json` |
| `scripts/clock_low.py` | the DR-145 clocks (`docs/perf/area_recovery.md` §6.2): v1 calibrated to the RTL as built (one L1D miss in flight, one I-cache refill, no prefetchers) at 94, 100, 125 and 150 MHz with L2 `DATA_LAT` 2, in the default profile with 1, 2 or 4 L1D misses in flight and in the fallback, against the NaxRiscv-like control at 135 and 150 MHz. One thread (the suite and the working-set kernels, one core alone) and four threads (two busy cores × SMT2 on smt.py's 42 pairs and 16 working-set pairs; each core with half the L2 and one HP port). At most 8 runs at a time → `results/clock_low_rv64gc.json` |
| `scripts/clock.py` | the clock sweep (`docs/perf/area_recovery.md` §6.1): v1's single-thread suite at 150–200 MHz and the NaxRiscv-like control at 137 and 150 MHz, each with its clock's cycle latencies (DRAM 184 ns and 3.2 GB/s from spike S1, the L2's `DATA_LAT`), and one extra pipeline stage at each unit boundary at 200 and 150 MHz → `results/clock_rv64gc.json` |
| `scripts/stats.py <isa> <workload> <preset> [k=v ...]` | every statistic of one run, per cycle and per 1,000 instructions |
| `scripts/quick.sh`, `scripts/sweep1.sh`, `scripts/pairs.sh`, `scripts/dbg.sh` | quick comparisons, one-parameter sweeps, opcode mix and dependent pairs, functional runs (`TGSIM_TRACE=N`) |

**Caching.** Every configuration is cached in `results/dse/`, keyed by model version and suite revision (`MODEL_VERSION` and `SUITE_VERSION` in `dse.py`); reruns simulate only what is missing. SMT2 pair runs are cached the same way in `results/smt/`, with `SMT_VERSION` (in `smt.py`) added to the key.
- **Run times:** a full `dse.py rv64gc` is about 256 configurations × 33 workloads, roughly 20 minutes on 8 threads; the greedy freeze takes 10–20 minutes.
- **Reproducing the M1 results:**
  1. Run `make` and the build scripts.
  2. Run `dse.py rv64gc`, then its `--targeted`, `--greedy`, `--freeze` and `--width --alu3` modes.
  3. Run `dse.py rv64gcb --baseline`, then `--freeze`.
  4. Run `calib.py`, then `report.py` for both ISAs. The exact sequence is in `docs/perf/dse_report.md` §12.

## SMT2: two hardware threads

```bash
build/tgsim --preset v1_freeze --set threads=2 --set dram_lat=120 \
    --bench ms_gather --set ff=1 --bench2 coremark_A --ff2 0 \
    build/bench/rv64gc/ms_gather.elf build/bench/rv64gc/coremark_A.elf
```

The second program, and its options, belong to hardware thread 1:
- `--bench2` names it;
- `--stdin2` gives its input;
- `--ff2 1` fast-forwards it, as `ff` does for thread 0.

The JSON output has a `threads` array, with one result per program, and an `overlap` record.

**What each thread has, and what the threads share.**

| Per thread | Shared |
|---|---|
| program and functional simulator; instruction stream | fetch: one thread per cycle (16 B, one I$ access) |
| fetch state, instruction queue (`fetchq` entries), FTQ prefetch | decode, rename/dispatch and commit slots (`decode_width`, `commit_width`) |
| global history, RAS | issue queues, with a per-thread cap (`smt_iq_cap`) |
| rename map; `ckpt` checkpoints | physical register banks, which hold both threads' committed registers |
| ROB, LQ, SQ and completion-buffer share (`smt_part`) | long-latency tags (`smt_llt_cap`); divide, FMA and every other unit |
| commit order; store drain (one D$ store port, alternating) | L1I, L1D, L2, MSHRs (`smt_mshr_cap`), prefetchers, DRAM bandwidth |
| flushes and redirects; early-retired operations | predictor tables, hashed with the thread ID (`smt_bp_hash`) |

**Address spaces.** Thread 1's physical addresses are its own addresses plus 64 GiB and 21 pages.
- The threads never share a line.
- Two copies of one program do not alias set for set in the L2.
- L1 set mapping is unchanged, because the L1s are indexed within the page.

**Policies.**

| Parameter | Values | Default |
|---|---|---|
| `smt_fetch` | 0 ICOUNT (the thread with fewer uops in the instruction queue, rename stages and issue queues fetches); 1 round robin | 0 |
| `smt_part` | 1 static halves of the ROB, LQ, SQ and completion buffer (plan §6.4); 0 shared, with each thread capped at `smt_win_cap` % | 1 |
| `smt_iq_cap`, `smt_mshr_cap`, `smt_llt_cap` | percent of each issue queue, of the L1D MSHRs, and of the long-latency tags that one thread may hold | 75, 100, 100 |
| `smt_mix` | 1: slots one thread leaves unused in decode, rename or commit go to the other thread in the same cycle; 0: one thread per stage per cycle | 1 |

Decode, rename and commit alternate their first thread every cycle. ICOUNT applies only to fetch: at rename it would starve the thread whose uops are waiting.

**How a run is measured.**
- Each thread's IPC is taken over the marked region of its program's **first run**.
- A program that ends while the other thread's first run is still going is restarted, with a new functional simulator. Its caches, predictors and IDs carry on.
- Both threads are therefore loaded throughout both measured regions. The run ends when both first runs are complete.
- `laps` counts the restarts.
- `overlap` records the window in which both first-run regions were open, with each thread's instructions in it.

**Unchanged single-thread behaviour.** With `threads=1` (the default), results are identical to the M1 model:
- `scripts/recheck.py` and `scripts/recheck.py --freeze` re-simulate cached runs;
- `MODEL_VERSION` stays 3.

## Area-recovery levers (plan §8.5)

Options for the IPC-costing levers. All are off by default; with them off, results are identical to the SMT2 model (threads=1 and threads=2), so `MODEL_VERSION` stays 3.

| Parameter | Lever | Model |
|---|---|---|
| `smt_ckpt_shared` | R10 | the `ckpt` checkpoints are one pool for both threads (default: `ckpt` per thread) |
| `fwd_strict` | R9 | (existing) a load forwards only from a store of the same address and size; others wait for the store to drain |
| `rf_share_a2` | R11 (`alu3`) | ALU2 has no read ports of its own. Operand 0 uses the STA port and operand 1 the shared port (store data, FP integer sources). At select, an STA pick with an integer source or an FP pick with an integer source wins, and ALU2's pick waits a cycle (`rf_port_conflicts`) |
| `dec_full` | R12 | decode slots from this index on take only ALU, branch, jump, multiply/divide and integer load/store; anything else waits for the next cycle (`dec_slot_stops`). `dec_full=2` at 3-wide is the asymmetric third decoder |
| `alu3_simple` | R13 (`alu3`) | ALU2 executes only add/sub, logic, compare, LUI/AUIPC and the Zba shift-adds; the rest steer to ALU0/1 (`alu3_steer_stalls` counts uops that waited although ALU2 had room) |
| `iq_bank` | banked readiness | every issue queue is two banks of rows, and a row's readiness covers only its bank's half of the ROB (plus every LLT, and its bank's MX rows). With two threads, a thread uses its own bank. With one thread, a uop goes to the bank that sees all of its waiting producers; if they are in both halves, dispatch waits (`disp_stall_bank`). No dependency is ever dropped |
| `iq_bank_llt` | with `iq_bank` | each bank also sees only half of the long-latency tags; a tag comes from its producer's half |
| `wake_tags` | wakeup tags | rows wake on a pool of this many tags instead of one column per ROB entry. A uop that writes a register and is neither a 1-cycle ALU-queue op (MX) nor an LLT producer takes a tag at dispatch, and dispatch waits if none is free (`disp_stall_wtag`). A tag is free again 2 cycles after its result wakes |
| `census` | (measurement) | counts every dispatched uop's sources by what its row would wait on (value ready, MX row, ROB column, LLT column, other thread) and adds a `census` record to the JSON |

**Pipeline-stage ablations** (`docs/perf/area_recovery.md` §6.1). All are 0 by default; at 0 every result is identical, so `MODEL_VERSION` stays 3.

| Parameter | One extra stage at |
|---|---|
| `abl_ld_use` | load-to-use: every load result (hit, forward or miss) reaches its dependents this many cycles later; the speculative-wakeup shadow moves with it |
| `abl_alu` | the integer bypass and wakeup loop: a 1-cycle result wakes its dependents this many cycles later (completion unchanged) |
| `abl_done` | execute completion to the ROB: every uop is marked complete this many cycles later, so commit slips |

The mispredict penalty and the L2 hit have their own parameters (`redirect_lat`, `commit_redirect`, `l2_lat`).

**The DR-145 study's points** (`docs/perf/area_recovery.md` §6.2). Both are 0 by default (for `abl_st_done`, the fallback profile); at 0 every result is identical, so `MODEL_VERSION` stays 3.

| Parameter | Model point |
|---|---|
| `abl_st_done` | a store's address completes in the ROB this many cycles later: cut #4 (the LSU address-stage split) is 1, and #2 would add another. #5 and B3 have no model point (no atomics in the workloads, no TLBs) |
| `fe_m2`, `ubtb_ways`, `m2_ctr` | M2's front end: the micro-BTB (`ubtb` entries, 2 ways, keyed by the 16-byte block with the taken parcel's slot) is the only predictor. A table of 2-bit counters (`m2_ctr`, PC[10:2]) only decides whether a resolved branch writes or clears its entry. Decode repairs JAL targets, wrong targets of predicted-taken branches and bogus predictions, and fetch waits for that instruction's decode. Everything else is a mispredict |
| `m2_wp_train` | with `fe_m2`: extra not-taken trainings of a loop branch mispredicted at its exit. They stand for the RTL training on the wrong path, which runs the loop again until the commit flush |
| `m2_dir`; `ras` with `fe_m2` | M6 steps on M2's front end. The direction predictor (`dirpred`) decides branches, and decode supplies missing targets. A return the micro-BTB got wrong is repaired at decode from the RAS |
| `l1_fill_extra` | cycles added to every L1 refill: the RTL's miss overhead beyond the memory's latency (13 in `rtl_m2`) |
| `ld_fwd_lat`, `ld_fwd_wait` | store-to-load forwarding: the load-to-use of a forward whose data is ready (3; 5 in `rtl_m2`, which forwards at M2), and the cycles from the store's data to a waiting load's result (3; 8 in `rtl_m2`, which replays) |
| `drain_guard` | a committed store that has waited this many cycles for an L1D MSHR gets the next one: loads and prefetches leave it free. Without it, a model with one L1D MSHR and SMT2 can starve a thread's store drain for good, because loads book the MSHR at issue + 3 while the drain asks at the current cycle. §6.2 uses 16 |

**The M6 front end and the RTL's backend, as built** (`docs/perf/area_recovery.md` §6.3, §6.4). All are off by default except as noted, and at their defaults every earlier result is identical, so `MODEL_VERSION` stays 3. `rtl_m2` sets `iq_slot_bank`, `iq_hold` and `sta_split` as the RTL has them; the M6 stack's knobs join it as each step lands on main.

| Parameter | Model point |
|---|---|
| `m2_f2`, `m2_f2_bubble` | with `fe_m2` and `m2_dir`: core-2's front end. F2's pre-decode supplies direct targets and TAGE's overrides, which refetch after `m2_f2_bubble` cycles (the RTL: 2, as F2's action is registered) instead of redirecting at decode |
| `m2_ras_f2` | with `m2_f2` and `ras`: returns are repaired from the RAS at F2, not at decode (593ddcd) |
| `ret_btb` | without a RAS, returns are predicted by the BTB's stored target |
| `m2_btage`, `btage_li`, `btage_bi`, `btage_tw` | with `m2_dir`: TAGE-lite as built (`tg_tage.sv`) instead of the model's per-branch TAGE. One read per 16-byte block on the block address and a history of conditional branches only (newest first); a base of 2^`btage_bi` blocks with a 2-bit counter per slot; `btage_nt` tables (four in the RTL as built) of 2^`btage_li` entries, each two slot-tagged sub-entries with `btage_tw`-bit tags. Training reads the entries again with the fetch-time indices; a wrong fetch-time direction allocates one sub-entry above the provider |
| `btage_lag` | (1) a block read right behind another lacks that block's history bits (F1 reads as F2 delivers); a read after a redirect, a flush or an I$ miss has them all |
| `btage_tq` | (4) commit's requests reach TAGE through a queue of this many entries, one every two cycles; a full queue drops them. 0 trains at commit at once |
| `btage_nt` | (4) tagged tables, 1–4, with core-2's size-study histories: 12; 8/32; 5/14/40; 4/9/18/40 |
| `m2_cut` | with `m2_f2`: a block ends before its third conditional branch and is refetched there after `m2_f2_bubble` cycles, so a block adds at most two history bits |
| `m2_ftq` | with `fe_m2`: FTQ entries. A block holds one from fetch until an instruction of a later block commits; fetch waits while none is free, and a flush empties it |
| `m2_strad` | with `fe_m2`: a 32-bit instruction that straddles into the next block, reached in sequence, is decoded with that block, as F2 holds its first half: no block of its own, the next block's TAGE-lite read at slot 0, and one of that block's branches for `m2_cut`. The micro-BTB never predicts or trains a straddler (`rtl_m2`: 1; area_recovery.md §6.7) |
| `m2_ub_way` | with `fe_m2`: training writes the micro-BTB way that predicted this instruction, else a pseudo-random way, as `tg_exec`'s `upd_way` does; 0 writes the way that hit the block, so a block's second exit evicts its first (`rtl_m2`: 1) |
| `iq_slot_bank` | the issue queues' rows are banks by dispatch slot (plan §4.15, `tg_iq.sv`): decode slot k's uop takes a row of bank k, a decode group dispatches as one, and an ALU op goes to queue k mod 2 unless that queue's bank for slot k is full (`rtl_m2`: 1) |
| `iq_steer_rn` | with `iq_slot_bank`: an ALU op's queue is picked a cycle before dispatch, as rename does in the RTL, from the banks' free flags of the cycle before that, which miss the group dispatch writes meanwhile; the op keeps it. 2 reads flags that count the group in the dispatch stage (STEER_LA, DR-169). 0 picks at dispatch with the current rows (`rtl_m2`: 2; area_recovery.md §6.8, §6.9) |
| `iq_hold` | cycles from a uop's issue until dispatch can reuse its row. The RTL frees a row two cycles after its select (the speculative-wakeup shadow, there with or without speculative wakeup), so `rtl_m2` sets 3; a flush frees rows at once |
| `sta_split` | 1: a store's address issues on its base alone, with its data captured later. 0: it issues with its data as well, as the RTL did before STA_BASE (DR-169), when rename made the store's IQ-STA row wait on its data register. A younger load to the same address can then run first and is replayed at commit (`rtl_m2`: 1) |
| `whole_run` | the region's counters cover the whole run, as an RTL profile from reset does |
| `spec_int_only` | with `spec_wakeup`: only integer loads wake their dependants early; FP loads wake on the confirmed result, as IQ-FP sees only confirmed results in the RTL (`rtl_m2`: 1) |
| `spec_fwd` | with `spec_wakeup`: a store-to-load forward that completes at M2 wakes its dependants as a hit does (load-to-use 3, not `ld_fwd_lat`) (`rtl_m2`: 1) |
| `dc_row_clash`, `clash_delay` | the RTL's D$ row clash (`tg_lsu.sv` `m1_clash`): a load that reads the D$ while a store to its 16-byte block is acked in its AG cycle or the one before, or whose forwarding store drains before its M1, retries `clash_delay` (4) cycles later, and with speculative wakeup its shadow is cancelled (`rtl_m2`: 1; area_recovery.md §6.6) |
| `clash_rearm` | with `dc_row_clash`: the retry reads the row again at its own AG, so a store draining then makes it retry again (as the RTL does; it moved nothing measurable, so `rtl_m2` leaves it off; area_recovery.md §6.9) |
| `fwd_wait_cancel` | with `spec_wakeup`: a load that finds an older store's address without its data, or not covering it, cancels the speculative-wakeup shadow as a miss does (the RTL's STQ verdict at M2; `rtl_m2`: 1; area_recovery.md §6.9) |
| `drain_delay` | cycles from a store's commit to its D$ write at the earliest. The RTL's SQ committed pointer is registered, so its drain starts a cycle after commit (`rtl_m2`: 1; area_recovery.md §6.9) |

Counters for comparing with an RTL profile (`--json`): F2 overrides by kind (`f2o_miss`, split as `f2o_miss_br`, `f2o_miss_jal`, `f2o_miss_ret` and `f2o_miss_strad`; `f2o_slot`, `f2o_nt`, `f2o_ret`, `f2o_bogus`), `f2_cuts`, `bt_drops`, `fetch_blocks`, `ftq_full`, decode's take per cycle, its starved cycles and the cycles rename holds it (`dec_take0/1/2`, `dec_starved`, `dec_blocked`), `rob_empty`, and `disp_stall_slot` (a group waiting for a slot's bank). Decode's starved slots are charged to the front end's last event, as `scripts/rtlprof/prof_f2cut.sv` does in RTL (`lost_flush`, `lost_replay`, `lost_dred`, `lost_miss_br`, `lost_miss_jal`, `lost_miss_ret`, `lost_miss_strad`, `lost_slot`, `lost_rastgt`, `lost_nt`, `lost_bogus`, `lost_cut`, `lost_icmiss`, `lost_ftq`, or `lost_steady` with none in the last 32 cycles); not while fetch waits on a mispredict, nor after a flush at commit until fetch restarts, as the RTL decodes the wrong path meanwhile. Decode's cycles held by rename (`dec_blocked`) are charged to what stopped dispatch that cycle, as `scripts/rtlprof/prof_rs.sv` does in RTL (`held_iq_a0`, `held_iq_a1`, `held_iq_ld`, `held_iq_sta`, `held_iq_fp`, `held_rob`, `held_lq`, `held_sq`, `held_reg`, `held_llt`, `held_wtag`, `held_other`); when a queue's bank stopped it, that bank's rows are counted by state (`a0_rows_*`, `a1_rows_*`, `ld_rows_*`: waiting, ready, held; `sta_rows_*`: waiting on the base, only on the data, ready, held; `sta_held_data`, the cycles with a data-only row), and `held_alu_other` counts an ALU op stopped while the other ALU queue's bank had a row. `stq_cancels` counts the shadows cancelled by loads waiting for a store (`fwd_wait_cancel`). `mp_wait_cycles` sums, over the mispredicts recovered at commit, the cycles from the branch's resolution to its commit: the wait that checkpoints remove (`scripts/rtlprof/prof_m6.sv` measures it in RTL as `misp_wait`).

## Scoring

- **IPC** = instructions retired in the region ÷ cycles in the region.
- **CoreMark/MHz** = iterations × 10⁶ ÷ cycles.
- **DMIPS/MHz** = runs × 10⁶ ÷ cycles ÷ 1757.
- **Embench score:**
  - **Formula:** the geometric mean over programs of baseline ms × 1000 ÷ cycles, from Embench 1.0's `baseline-data/speed.json` (`CPU_MHZ=1`).
  - **`embench18`:** GCC 15 hoists `nbody`'s timed work out of its loop, so the report also gives `embench18`, which leaves `nbody` out.
  - **Which build to compare:** the baseline core used software floating point, so rv64gc scores are inflated by hardware FP. Use the rv64imac (soft-float) build to compare with published numbers.
- **Suite IPC**, the DSE's figure of merit, is the geometric mean of three equally weighted group geometric means: kernels, embench and memsuite.
- **MLP** = the average number of outstanding demand L1D misses, over cycles with at least one outstanding.

## Source map

| File | Contents |
|---|---|
| `src/isa.h`, `src/decode.cpp` | instruction set, RVC expansion, decoder |
| `src/iss.h`, `src/iss.cpp` | functional simulator (including F/D with NaN-boxing and rounding modes), ELF loader, MMIO console and markers |
| `src/config.h`, `src/config.cpp` | all parameters (X-macro), presets, JSON |
| `src/bpred.h`, `src/bpred.cpp` | bimodal, gshare, TAGE-lite, block BTB, micro-BTB, RAS |
| `src/cache.h`, `src/cache.cpp` | L1I, L1D, L2, MSHRs, DRAM, stride and stream prefetchers |
| `src/core.h`, `src/core.cpp` | fetch, decode (fusion, SFB, folding), rename, issue (including the FP queue and FMA/divide/sqrt units), load/store, commit, recovery; per-thread state and SMT2 arbitration |
| `bsp/` | bare-metal runtime: `crt0.S` (enables the FPU), linker script, newlib stubs, region markers |
| `bench/` | toolchain flags, workload builds, CoreMark port, Dhrystone and Embench board support, memsuite, bigcode generator |

## Known limitations

- **Correct path only:**
  - wrong-path cache pollution and prefetching are not modelled;
  - branch-heavy code with many mispredictions is therefore slightly optimistic for both configurations.
- **No virtual memory:**
  - TLBs, page walks and supervisor-mode code are not modelled;
  - Linux-level behaviour is out of scope for M1.
- **Single core:** coherence traffic and the second core's share of L2 and DRAM bandwidth are not modelled. SMT2 runs two programs on the one core.
- **SMT2 without an operating system:**
  - the two programs are bare-metal and run in separate address spaces;
  - there are no context switches, no TLB misses, and no shared memory between the threads;
  - a thread waiting on a mispredicted branch fetches nothing (correct path only). A real thread would fetch down the wrong path and take some fetch and decode slots from its sibling until the branch resolves. This favours SMT slightly.
- **Simple DRAM:** DRAM is a fixed latency plus a per-line occupancy, not a DDR4 timing model.
- **Estimated costs:** LUT costs in the feature ledger are estimates until the RTL synthesis spikes (S2–S6) replace them.
- **Little FP:** FP-heavy code is a small part of the suite (5 of 33 workloads).
- **Control FPU latency is assumed:**
  - the control's FMA latency (7 cycles) is our assumption, because NaxRiscv documents none;
  - `--freeze` reports the sensitivity to it.
