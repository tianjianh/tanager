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

## 8. Lint

- **Command:** `verilator --lint-only -Wall` across all four configurations (`make lint-all`) must be clean.
- **Waivers:** go in `rtl/lint.vlt`, one justified line each. Inline `lint_off` is allowed only around a single construct, with a comment saying why.

## 9. Sharing the build host

**The hosts.**
- **Build host:** the 5950X, `ssh home-wsl`. WSL Ubuntu 24.04, 32 threads, about 39 GB of RAM, and **about 100 GB of disk in total**: its Windows drive's free space is the real limit, not the 1 TB WSL reports. The tracks work there in the Linux filesystem (`~/tanager` and its worktrees).
- **Laptop:** 8 threads, 32 GB. For the coordinator and light work only.

**Rules.**
- **Vivado:** only through `tools/vivado_run.sh <run-dir> <script.tcl> [args]`.
  - It takes a machine-wide slot lock. `TANAGER_VIVADO_SLOTS` is 3 on the build host and 1 on the laptop, set in `tools/env.sh`.
  - At most 2 full-device runs at a time, since each needs about 8–12 GB of RAM; out-of-context runs need 2–6 GB.
  - Use out-of-context runs per unit wherever possible. A full-device run takes hours, so say so in your status.
- **Builds:** up to `-j16` per track on the build host (`-j4` on the laptop).
- **Use the build host's spare capacity** (32 threads, about 39 GB); idle cores are wasted:
  - run independent configurations and seeds in parallel;
  - build long simulations (Linux boots, long benchmarks) with Verilator `--threads 4`–`8`;
  - run soak tests and sweeps at `nice 19`, so interactive work keeps priority.
- **Disk stays the tighter limit:** watch `tools/disk_report.sh`.
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

## 11. Clean room (plan §2.3)

- **Specs first:** all RTL is written by us from our own specs.
- **Other cores' RTL:** never read it (NaxRiscv, BOOM, XiangShan, CVA6, Rocket, OpenC910 and so on) for a unit you are designing. Published papers, public specifications and documentation are fine; cite them in the unit spec.
- **Tools:** third-party tools (Spike, Verilator, GCC, OpenSBI, Linux, TestFloat) are used as-is.
