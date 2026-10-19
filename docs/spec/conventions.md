# RTL, build and collaboration conventions

These rules apply to every track. They extend plan §14 (repository layout) and §2.3 (clean-room policy). The cross-track contracts are in [interfaces.md](interfaces.md).

## 1. Environment

- **Where:**
  - On the build host (`ssh home-wsl`, §9), WSL Ubuntu 24.04, in `~/tanager`.
  - On the laptop, the WSL distro **`Ubuntu-24.04`**, always selected explicitly (`wsl -d Ubuntu-24.04 ...`). The laptop's default distro is a different Ubuntu.
- **Setup:** `source tools/env.sh` before anything else.
  - It puts the pinned tools first on `PATH`: Verilator 5.052, Spike, TestFloat and the xPack GCC 15.2 cross compiler.
  - Pins are in `tools/versions.sh`; `tools/setup_tools.sh` rebuilds them on a new machine.
- **Compilers:**
  - Host C/C++: `g++-15`.
  - RISC-V bare metal: `riscv-none-elf-gcc` 15.2 (xPack).
  - Linux-target toolchains come from Buildroot, later.
- **System packages beyond the base install:** `mmdebstrap`, `qemu-user-static`, `binfmt-support` and `debian-archive-keyring`, for the SoC track's Debian image (2026-10-17, the user's OK); the versions, the one registered binfmt handler (`qemu-riscv64`) and the undo are in [sw/README.md](../../sw/README.md).
- **Vivado:** 2025.2 at `~/Xilinx/2025.2/Vivado`, licensed. Never call `vivado` directly; use `tools/vivado_run.sh` (§9).
- **Build trees:** go under `$TANAGER_BUILD/<worktree-name>/` (default `~/tanager-build`, Linux filesystem). Never put them in the repository, and never under `/mnt/c`: builds there run several times slower.

## 2. Language

- **Subset:** SystemVerilog-2017, the part both Verilator 5.052 and Vivado 2025.2 synthesis accept. `make lint` (Verilator) and `tools/tcl/elab.tcl` (Vivado) check it.
- **Allowed:**
  - packages, `typedef struct packed`, `typedef enum logic`;
  - `always_ff` / `always_comb`, `unique` / `priority case`;
  - generate loops, type parameters, elaboration-time `$error` in generate blocks.
- **Not used in product RTL:** `interface`/`modport`, classes, `program`, latches, `initial` (except in testbenches), `#` delays, tri-states.
- **Assertions:** go inside `` `ifndef SYNTHESIS `` and are encouraged. Verilator runs them with `--assert`.

## 3. Naming and structure

- **Files and modules:** one module per file. The file is named after the module, with the `tg_` prefix (`tg_rob.sv`).
- **Packages:** `tg_*_pkg.sv`.
- **Types:** `_t` for structs and typedefs; `_e` for enums.
- **Signals:**
  - `snake_case`;
  - `_q` for registered values and `_d` for their next state;
  - `_i` / `_o` on ports where the direction is not obvious from a struct.
- **Parameters:** `UPPER_CASE`.
- **Interfaces:** every interface is a packed struct plus `valid`/`ready`.
  - `valid` must not depend combinationally on `ready`.
  - Data holds stable while `valid && !ready`.
- **Thread IDs:** a `tid` (type `tid_t`) goes on every structure and port where a thread ID applies (plan §6.2).
  - With `TID_W = 0` it is 1 bit tied to 0. Never declare a zero-width signal.
  - Size every index with `tg_pkg::idx_w(n)`, never a raw `$clog2(n)`.

## 4. Clocks, resets, memories

- **Clocks:** one core clock, `clk`. The only clock-domain crossing is in the host bridge, built with `xpm_cdc_*`.
- **Resets:** `rst` is active-high and synchronous, applied to control state only. Datapath and memory contents are not reset (plan §8.3). Replicate the reset register at unit boundaries; do not fan out one net.
- **Memories:** every memory goes through `rtl/common/prim`, never inferred ad hoc:
  - `tg_ram_lut`: multi-read LUTRAM;
  - `tg_ram_sdp` / `tg_ram_tdp`: block memory, URAM through `PRIM="ultra"`;
  - `tg_fifo`.
  - Synthesis is checked against expected primitive counts (plan §8.3).
- **Read-during-write:** behaviour is documented per wrapper. Never rely on anything a wrapper leaves undefined.

## 5. Parameters and configurations

- **Configuration files:** one of `rtl/common/cfg/tg_cfg_{st,smt2,st_w3,smt2_w3}.sv` is compiled per build (`CFG=...`). It defines `tg_cfg_pkg`.
- **`tg_pkg`:** re-declares every configuration value by name and derives the rest. RTL imports `tg_pkg` and never `tg_cfg_pkg`.
- **A new configuration parameter:** add it to all four `tg_cfg_*.sv` files and to `tg_pkg` in one commit. These files are shared, so ask the coordinator first (§7).
- **Width rules (plan §4.15):**
  - No literal widths.
  - Per-instruction structures are generate loops over `DECODE_WIDTH` / `COMMIT_WIDTH` / `N_ALU`.
  - Every change must build and lint in all four configurations.

## 6. Files, builds, tests

- **Filelists:**
  - Each RTL area keeps a filelist in compile order: `rtl/common/common.f`, `rtl/core/core.f`, `rtl/core/fpu/fpu.f`, `rtl/uncore/uncore.f` and so on.
  - Lists nest with `-F` (paths relative to the list).
  - `rtl/rtl.f` lists the areas.
  - Vivado reads the same lists through `tools/tcl/tg_files.tcl`.
- **Entry points:**
  - `make lint CFG=<cfg>` and `make lint-all` (repo root).
  - Each area adds its own targets (`make -C sim ...`, `make -C tests/unit/<unit> ...`).
- **Unit tests:** each unit has a test under `tests/unit/<unit>/` that exits non-zero on failure.
  - Random tests print their seed and accept it as an argument.
  - A test that is slow (more than about 2 minutes) gets a `short` and a `long` mode.
- **Regressions:** before asking for a merge, run lint for all four configurations and your area's tests. For the core, that includes the lockstep suite in `st` and `st_w3`.

## 7. Ownership and shared files

| Area | Owner (track) |
|---|---|
| `rtl/core/**` except `fpu/`; `docs/spec/core-*.md` | core |
| `rtl/core/fpu/**`, `tests/unit/fpu/**`, `docs/spec/fpu.md` | fpu |
| `rtl/uncore/**`, `rtl/soc/**`, `fpga/kv260/**`, `sw/**`, `docs/spec/{uncore,l2,soc,host}*.md` | soc |
| `sim/**`, `tests/{isa,bench,random,arch}/**`, `tools/ci/**`, `docs/spec/verification.md` | verif |
| `fpga/spikes/**`, `rtl/common/prim/**`, `docs/perf/spikes.md` | spikes |
| `rtl/common/*.sv`, `rtl/common/cfg/**`, `rtl/rtl.f`, `Makefile`, `tools/*.sh`, `tools/tcl/**`, `docs/spec/{interfaces,conventions}.md`, `docs/architecture_plan.md` | coordinator |

- **Outside your area:** you may add new files elsewhere when your work needs them, for example a unit test that instantiates another track's module. Do not edit another track's files; ask the owner.
- **Coordinator files:** to change a shared file or an interface, message the coordinator with the change and the reason. Small additions, such as a new package constant, can be committed on your branch and flagged for review in the merge request.
- **Unit specs:** every unit has a spec in `docs/spec/` before its RTL (plan §2.3), using [README.md](README.md)'s template. The spec records where each idea came from.
- **FPGA-friendly from the start (DR-125):** new RTL uses the forms in [fpga_friendly.md](../perf/fpga_friendly.md) §2 wherever they keep the cycle behaviour.
  - Tables read by index go in LUTRAM or block RAM.
  - Per-thread state is an extra RAM address bit, not a second copy in flip-flops.
  - Delay lines are shift-register LUTs.
  - Rarely written lookups are LUTRAM CAMs.
  - A unit's spec says which form each structure uses, and why when it stays in flip-flops.

## 8. Lint

- **Command:** `verilator --lint-only -Wall` across all four configurations (`make lint-all`) must be clean.
- **Waivers:** go in `rtl/lint.vlt`, one justified line each. Inline `lint_off` is allowed only around a single construct, with a comment saying why.

## 9. Sharing the build host

**The hosts.**
- **Build host (since 2026-10-19):** w-arrowlake, `ssh home-wsl`, on the home LAN; a reverse tunnel for access from outside comes later.
  - **The machine:** native Ubuntu 24.04.5 with kernel 7.0 on a Core Ultra 7 270K Plus: 8 P-cores (CPUs 0–7) and 16 E-cores (8–23), 24 threads, no SMT. It has 62 GB of RAM and a 457 GB NVMe.
  - **Speed:** a Vivado job keeps about 2.5 threads busy, so per-thread speed sets a full chip's time. Vivado runs belong on the P-cores. Lint plus regress st take 1:41 there, against 3:36 on w-x299.
  - **Same user `w` and paths as before:** `~/tanager`, its worktrees, the tools in `~/opt` and Vivado 2025.2 in `~/Xilinx` were copied as they were, over a direct 2.5 GbE cable in 11 minutes.
- **2026-10-18 to 10-19:** w-x299 (an i9-10980XE, 18 cores and 36 threads, 62 GB). It is retired; `ssh w-x299` is for its cleanup only.
- **Until 2026-10-18:** the 5950X's WSL (32 threads, 56 GB, about 100 GB of real disk behind the Windows drive). It was retired from Tanager for other work; it remains reachable as `old-5950x` (through gcvm) for its cleanup.
- **Moving hosts:** switching the alias does not move running remote sessions. The app keeps its SSH bridge and every session's process on the old host. Once the tracks are idle and the final sync is done, kill the old host's remote session processes; the app reconnects through the alias by itself.
- **Laptop:** 8 threads, 32 GB. For the coordinator and light work only.

**Rules.**
- **Memory is the binding limit (2026-10-14).**
  - **What happened:** WSL has 39 GB. With three Vivado slots, the build host ran out of memory: two full-device runs (about 9 GB each) plus a budget synthesis whose parent and six child Vivado processes took about 14.5 GB. SSH and the sessions stalled for about 10 minutes.
  - **The budget:** keep about 12 GB for the OS, sshd, the agent sessions and simulations; Vivado gets at most 50 GB declared on the 62 GB hosts (w-arrowlake, and w-x299 before it; 40 GB on the 5950X's 56 GB WSL; 24 GB before WSL went from 40 to 56 GB); builds, simulations and soak share the rest. Simulations can use `-j16` per track.
- **Vivado:** only through `tools/vivado_run.sh <run-dir> <script.tcl> [args]`.
  - **Slots:** `TANAGER_VIVADO_SLOTS` is 8 on the build host (6 on the 5950X) and 1 on the laptop, set in `tools/env.sh`. The memory budget is the main limit; the slot count caps CPU use. Only the coordinator changes capacity live, through `.locks/vivado.slots` and `.locks/vivado.budget` in the build tree; jobs read them as they wait.
  - **Fair queue:** each job takes a ticket. The next job admitted is the waiting one whose owner holds the fewest slots, then the oldest. The head of the queue holds the admission lock while it waits, so a fresh launch cannot take a freed slot first.
    - **Owner:** the `track-*` name in the script's path or the run directory. Set `TANAGER_TRACK` if neither has one.
    - **Status:** `tools/vivado_run.sh --status` shows the running jobs and the queue.
    - **Chained launches:** don't launch Vivado jobs back to back to hold slots. Queue them through the script; it orders them fairly against other tracks.
  - **Declared memory:** each job declares `TANAGER_VIVADO_MEM_GB`: about 10 for a full-device run (the default), about 4 for an out-of-context unit run. A job starts only when its declaration fits `TANAGER_VIVADO_MEM_BUDGET` (50 GB on the build host, 40 on the 5950X) next to the running jobs' declarations.
  - **Declare from measurements:** every job reports its measured peak (`done rc=0, peak 8.6 GB of 12 GB declared`) and appends it to `$TANAGER_BUILD/.locks/vivado_peaks.log`. Declare about 1.2 × the measured peak of the same kind of run, rounded up. Over-declaring holds slots others could use. On 2026-10-14 jobs measured about 60% of their declarations.
  - **Undeclared jobs:** a held slot with no declaration (a job started by an older `vivado_run.sh`) counts as 10 GB.
  - **Child processes count:** a declaration covers everything Vivado spawns. Flows that launch parallel runs (`launch_runs -jobs`, IP generation) must declare their total or run their children one at a time.
  - **Kill order:** Vivado runs with a raised `oom_score_adj`, so under memory pressure the kernel kills a Vivado job rather than sshd or the sessions.
- **Shared-tool changes:** when main changes `tools/vivado_run.sh`, `tools/env.sh` or `tools/memguard.sh`, merge main before your next heavy job. You run tools from your own branch, so a fix on main does not reach your jobs until you merge it.
- **Memory guard:** `tools/memguard.sh` runs on the build host, started at boot by an `@reboot` crontab entry.
  - **What it does:** when `MemAvailable` falls under 3 GB, it stops the newest expendable job holding at least 1 GB, then checks again. Expendable means Vivado, a compiler or linker, a Verilator model, Spike, QEMU, or anything with a raised `oom_score_adj`. It never touches agent sessions, sshd or shells.
  - **If your job dies with signal 15 or 9,** look in `$TANAGER_BUILD/memguard.log` first.
  - **Why:** the kernel's OOM killer acts only after minutes of thrashing, and every session stalls meanwhile (10 and then 31 minutes on 2026-10-14).
  - Use out-of-context runs per unit wherever possible. A full-device run takes hours, so say so in your status.
- **Builds:** at most `-j8` per track on the build host for Verilator model builds, since each compile can take 2–4 GB; `-j4` on the laptop.
- **Use the build host's spare capacity** (32 threads), within the memory budget:
  - run independent configurations and seeds in parallel;
  - build long simulations (Linux boots, long benchmarks) with Verilator `--threads 4`;
  - run soak tests and sweeps at `nice 19`, pausing them when `MemAvailable` falls under 12 GB.
- **Disk is a limit too:** watch `tools/disk_report.sh`.
- **Long jobs:** run in the background with a log in your build tree. Never poll in a tight loop.
- **Disk:** a hard budget. The WSL virtual disk never gives space back to Windows, so what counts is total WSL usage.
  - **Totals:** WSL usage (`df -h /`, Used) must stay at or under **95 GB**, and the host drive at or over **15 GB free**. On 2026-10-13, with Vivado (47 GB) and the tools installed, usage was 64 GB and the host had 34 GB free.
  - **Per-track build trees:**

    | Track | Budget |
    |---|---|
    | core | 4 GB |
    | fpu | 3 GB |
    | verif | 5 GB |
    | spikes | 8 GB |
    | soc | 15 GB |

    The SoC budget covers Buildroot and Linux: use an external toolchain and one shared download directory.
  - After a Vivado run, keep the reports you need and delete checkpoints (`.dcp`), run directories and logs.
  - Delete waveforms once a bug is understood.
  - `ccache` is capped at 1 GB on the build host (`ccache -M 1G`). Install pip and gem packages without keeping caches (`pip --no-cache-dir`, `bundle clean`).
  - `tools/disk_report.sh` shows usage per tree, WSL usage and the host's free space. When a total limit is near, clean up before starting anything new, and tell the coordinator.

## 10. Git and tracks

- **Branches:** each track works on its own branch in its own worktree.
  - `main` is the integration branch. Only the coordinator merges into it, after the track reports green lint and tests.
  - Bring `main` into your branch when you need others' work (the app's sync tool, or `git merge main`).
- **Commits:** small and often, with messages of the form `area: what (why)`. End each message with the `Co-Authored-By` line given in your session instructions.
- **Rules:**
  - Never rewrite history that others may have merged.
  - Never push to a remote; none is configured.
- **Merge requests:** when a piece is green, message the coordinator with the branch name, what it adds, and the test commands and results.
  - **End every merge request with a `Learned:` line:** what surprised you, what was measured against what was estimated, and what didn't work and why.
  - **Add a `Decisions:` line** for every design choice the merge makes or rejects: what was chosen, the alternatives considered, the **pros and cons** of each, and the evidence. The coordinator records each one in [docs/decisions.md](../decisions.md), pros and cons included (the user's rule, 2026-10-14).
  - **History and lessons:** every area document (spec or perf report) keeps a short "History and lessons" section, updated with each merge: the starting point, each change and what it bought (LUTs, slack, IPC, bugs found), and dead ends. The coordinator rolls these up into [docs/devlog.md](../devlog.md).
  - **No-IPC rewrites (DR-123):** quote the result of `make cycle-identical CFG="st smt2" BASE=<merge base>` on the merge request's commit, plus the boot suite once it exists for uncore changes. A change that isn't identical goes to the reserve list with its cycle cost, which the tool reports per suite. Before rewriting a structure, check that some program in the suites fills it; `tlb_stress` was added because none filled the TLBs.

## 11. Clean room (plan §2.3)

- **Specs first:** all RTL is written by us from our own specs.
- **Other cores' RTL:** never read it (NaxRiscv, BOOM, XiangShan, CVA6, Rocket, OpenC910 and so on) for a unit you are designing. Published papers, public specifications and documentation are fine; cite them in the unit spec.
- **Tools:** third-party tools (Spike, Verilator, GCC, OpenSBI, Linux, TestFloat) are used as-is.
- **Licences (DR-018, DR-130):** hardware files are under SHL-2.1 and software under Apache-2.0, by path through `REUSE.toml`; no header is needed.
  - **Third-party source:** never copy it into the repository; fetch it at build time, as now.
  - **A new kind of path** (a new top-level directory, a new file type in `fpga/`): tell the coordinator, so `REUSE.toml` stays right.
  - **Generated reports** go under a `results/` directory, which `REUSE.toml` marks as tool output.
