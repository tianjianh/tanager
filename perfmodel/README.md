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
