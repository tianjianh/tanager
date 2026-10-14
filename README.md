# Tanager (working name)

Tanager is a clean-room, 2-wide-decode, out-of-order RV64GC dual-core with two hardware threads per core (SMT2) that runs Linux on the AMD Kria KV260 (XCK26). Its IPC must beat NaxRiscv's, and it is built so 3-wide decode can be added next.

| Document | Contents |
|---|---|
| [docs/architecture_plan.md](docs/architecture_plan.md) | Architecture and project plan (draft 0.4): targets, microarchitecture (M1 freeze), dual-core memory system, SMT/CMT hooks, KV260 integration, verification, milestones, risks, open decisions |
| [docs/perf/dse_report.md](docs/perf/dse_report.md) | M1 performance model results: calibration, IPC vs DRAM latency, ablations, early retirement, FPU and decode-width studies, the v1 freeze |
| [docs/perf/feature_ledger.md](docs/perf/feature_ledger.md) | Every v1 feature and size, with its evidence and decision |
| [docs/devlog.md](docs/devlog.md) | Development log and lessons: timeline, the area story (estimates, overruns, what shrank them), timing, verification, operations |
| [docs/decisions.md](docs/decisions.md) | Decision register: every decision, approved or rejected, with date, who decided and the evidence |
| [perfmodel/](perfmodel/README.md) | `tgsim`, the performance model, with workloads and scripts (WSL Ubuntu 24.04, GCC 15) |
| [reports/RISCV OoO soft cores for KV260.md](reports/RISCV%20OoO%20soft%20cores%20for%20KV260.md) | Literature review: pros, cons and numbers for about 30 cores and techniques |
| `research_notes/RISCV OoO soft cores for KV260/` | Sourced research notes behind the review |

**Status.**
- **M1 (model and design-space exploration):** done. The parameter freeze was approved on 2026-10-13.
- **SMT2 model study:** done ([docs/perf/smt2_report.md](docs/perf/smt2_report.md)).
- **Roadmap:** single-thread bring-up (ST) → **v1, the first release: SMT2, 2-wide, 2 cores × 2 harts** (plan §6.5) → v2: 3-wide on the SMT2 core. All on the KV260 (plan §8.5).
- **Schedule (plan §11):** agent-built. Linux on the board about 4–6 weeks after M0 starts; v1 in about 3 months.
- **M0 (repository, CI, FPGA spikes):** done, except spike S1, which waits for the board. The spikes are reported in [docs/perf/spikes.md](docs/perf/spikes.md).
- **M2 (out-of-order core in simulation):** done on 2026-10-14. Lockstep passes in all four configurations; CoreMark 3.04 CM/MHz on the conservative M2 core.
- **M3 (Linux-capable core):** in progress. RV64GC, with F and D, runs in lockstep with Spike in all four configurations (ACT4 rv64imafdc 895/895). **Next:** OpenSBI and Buildroot to a shell in Verilator, and redoing the area fit with the measured RTL.
