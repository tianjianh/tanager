# Privilege modes, CSRs, traps and interrupts (`tg_csr`, M3)

Status: implemented for M3 (`EXT_SU`, on) — core track — 2026-10-14

## Purpose
Extends the M2 machine-mode CSR file ([core-pipeline.md](core-pipeline.md) §9) to the privilege architecture Linux needs (plan §2.2, §4.1, §4.13): M, S and U modes; trap delegation; supervisor interrupts with Sstc; counters and their enables; the status fields that change memory access (MPRV, SUM, MXR, TVM, TW, TSR). The MMU and PMP are in [core-mmu.md](core-mmu.md); atomics in [core-lsu.md](core-lsu.md) §Atomics.

Target ISA string (M3, with verification.md §3.2; F and D join at M5): `rv64imac_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs`, privilege `MSU`, 8 PMP entries (`PMP_ENTRIES`, DR-167; 16 with `TG_PMP_ENTRIES=16`), Sv39. Every field below follows Spike for that configuration, so lockstep compares every read.

## Interface
`tg_csr` keeps its M2 ports and adds:
- **To decode:** `priv` (the current mode), `tvm`, `tsr`, `tw`, the misa bits (M, B, C).
- **To the MMU and the LSU:** `satp` (mode, ASID, PPN), the data access mode `priv_d` (MPRV), `sum`, `mxr`, and the PMP configuration (core-mmu.md §PMP).
- **To fetch:** `priv` (the fetch mode; MPRV never applies to fetch).
- **From commit:** the SRET event and the trap target selection (M or S).
- **Interrupts:** `irq_sei_i` (PLIC S context), `irq_ssi_i` (tied 0 today), and `mtime_i` for Sstc.

Mode changes happen only at commit: a trap, MRET or SRET retires, the CSR file switches mode, and the flush that follows refetches everything under the new mode. CSR writes are serialised and also end in a flush, so no younger instruction ever runs with stale status.

## Behaviour

### Privilege and serialisation
- `priv` resets to M. Traps go to M, or to S when delegated and `priv` ≤ S.
- **Serialising** (dispatched into an empty window, flush after commit, as in M2): CSR instructions, MRET, SRET, WFI, FENCE, FENCE.I, SFENCE.VMA, SINVAL.VMA, SFENCE.W.INVAL, SFENCE.INVAL.IR. A serialising instruction executes with every older instruction retired, so it sees the final mode and status.
- **Illegal at decode** (the CSR file's `priv` is stable while a serialising instruction runs, and any status change is followed by a flush):
  - MRET outside M;
  - SRET in U, or in S with TSR;
  - SFENCE.VMA and SINVAL.VMA in U, or in S with TVM;
  - WFI in U, or in S with TW.

### CSR set (adds to M2's)

| CSR | Behaviour (Spike, M+S+U, Sv39, no F yet) |
|---|---|
| `mstatus` | Writable: SIE, MIE, SPIE, MPIE, SPP, MPP (the reserved value 2 becomes U, as Spike legalises it), FS, MPRV, SUM, MXR, TVM, TW, TSR. UXL = SXL = 2 (read-only). SD = (FS == 3). FS is writable although F is absent (Spike keeps FS whenever S exists). |
| `sstatus` | View of SIE, SPIE, SPP, FS, SUM, MXR, UXL, SD |
| `misa` | `0x8000_0000_0014_1107` with C, B, M, A, I, S, U as configured; writable M, A, B, C bits as in Spike |
| `medeleg` | Writable: causes 0 (only while misa.C is clear), 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 15, and 19 (hardware error: Spike makes it writable with Zicntr; never raised) |
| `mideleg` | Writable: SSIP, STIP, SEIP |
| `mie` / `sie` | `mie`: SSIE, MSIE, STIE, MTIE, SEIE, MEIE. `sie`: the S bits, masked by `mideleg` |
| `mip` / `sip` | MSIP, MTIP, MEIP from the inputs. SSIP writable by M. STIP is writable by M only while `menvcfg.STCE` = 0; with STCE it is `time >= stimecmp`. SEIP reads as the input OR a software bit (writable by M). `sip` shows the bits `mideleg` delegates, and only SSIP is writable through it. Reads of `mip`/`sip` are `nondet`. |
| `mcounteren`, `scounteren` | 32 bits (Zicntr + Zihpm). Gate `cycle`, `time`, `instret`, `hpmcounter3–31` reads from S (mcounteren) and U (mcounteren and scounteren) |
| `menvcfg` | FIOM and STCE writable (no Zicbo*, Svpbmt or Svadu yet) |
| `senvcfg` | FIOM writable |
| `stvec`, `sscratch`, `sepc`, `scause`, `stval` | As their M counterparts; `sepc` masks like `mepc` |
| `satp` | MODE (Bare or Sv39), ASID (16 bits), PPN (44 bits). A write with any other MODE has no effect at all (privileged spec; Spike). Access in S with TVM is illegal. A write commits once the store queue has drained; one that changes the value flushes the TLBs (core-mmu.md). |
| `stimecmp` | Sstc. Access below M needs `menvcfg.STCE` and the `time` permission (`mcounteren.TM`), else illegal |
| `hpmcounter3–31` | Read 0 (Zihpm), `nondet`; gated by the enables |
| `mhpmevent3–31` | Read 0 (no Sscofpmf yet) |
| `dcsr`, `dpc`, `dscratch0`, `dscratch1` | With `TG_DEBUG` only, in debug mode only (Debug mode, below); otherwise illegal |

Everything M2 listed is unchanged. Existence and privilege follow the CSR address (bits 9:8 give the lowest privilege allowed; read-only when bits 11:10 are 3), as in M2.

### Traps
- **Target:** M, unless `priv` ≤ S and the cause's bit is set in `medeleg` (exceptions) or `mideleg` (interrupts); then S.
- **M target:** as M2, plus MPP ← `priv`.
- **S target:**
  - `sepc` ← PC; `scause`; `stval` ← tval (0 for interrupts);
  - SPIE ← SIE, SIE ← 0, SPP ← `priv` (0 for U, 1 for S);
  - `priv` ← S; PC ← `stvec` (vectored for interrupts).
- **tval by cause** (Spike):
  - illegal instruction: the instruction bits (16-bit for compressed);
  - breakpoint (EBREAK): the PC;
  - misaligned, access fault and page fault: the virtual address (for fetch, the address of the faulting halfword);
  - ECALL and interrupts: 0.
- **ECALL** cause by mode: 8 (U), 9 (S), 11 (M).
- **MRET:**
  - MIE ← MPIE, MPIE ← 1;
  - `priv` ← MPP, then MPP ← U;
  - MPRV ← 0 if the new mode is not M;
  - PC ← `mepc`.
- **SRET:**
  - SIE ← SPIE, SPIE ← 1;
  - `priv` ← SPP, then SPP ← U;
  - MPRV ← 0;
  - PC ← `sepc`.
- **Reservation:** every trap and xRET clears the LR reservation (Spike may keep it; the checker adopts our SC failures, interfaces.md §5).

### Interrupts
- **Pending:** `mip & mie`.
- **To M:** the bits not in `mideleg`, enabled when `priv` < M, or `priv` = M with MIE.
- **To S:** if none goes to M, the delegated bits, enabled when `priv` < S, or `priv` = S with SIE.
- **Priority** (default, as Spike): MEI, MSI, MTI, SEI, SSI, STI.
- Taken at commit before the head instruction, with the M2 exceptions (WFI at the head, MMIO load in flight).
- **WFI** retires when `mip & mie` is nonzero, whatever the enables and delegation, or after its 4096-cycle limit.

### Counters
- `cycle` counts every cycle and `instret` retired instructions (CY and IR inhibit, as M2).
- `time` reads `mtime_i`.
- From S or U, each counter read needs its enable bit; otherwise the read is illegal.

## Debug mode (Sdext; `TG_DEBUG`, M9's item 4, development builds only)

Status: spec for review (core-2), 2026-10-24. soc-2's Debug Module, DTM and debug window are [soc.md](soc.md) §9, agreed with this section.
- **Sources (DR-138):** the RISC-V Debug Specification 1.0 only: its Sdext chapter (Debug Mode, Single Step, Resume), its core debug registers (`dcsr`, `dpc`, `dscratch0`/`1`) and its execution-based abstract commands. No implementation was read.
- **The switch:** `TG_DEBUG` (`tg_core_pkg::DEBUG_ON`), off by default. A release build never sets it (as the virtio window, DR-180). Off, nothing below exists: the four CSRs and `dret` stay illegal, `debug_req_i` is unused, and the core is cycle for cycle the one without the switch.
- **The design is execution-based.** A halted hart runs the DM's ROM from the debug window, and the DM implements Access Register by writing instructions for the hart to run (soc.md §9.5). Nothing reaches rename or the register files.

### Interface (soc.md §9.4)
- **`debug_req_i[t]`** (from the DM's `dbg_haltreq[h]`): a level halt request per hart. It is the core's only debug signal, and `tg_core` already has it, so its port list doesn't change.
- **The DM derives the rest without new core ports.**
  - `havereset[h]`: the core's one reset, `core_rst`, so all its harts leave reset together.
  - `hart_unavail[h]`: that reset, plus hart 1's absence in a build without it (`tg_core_pkg::HART1_ON`).
  - **A limit:** a hart held off at run time by `mtgsmt.HART1_OFF`, which the firmware leaves at 0, isn't reported unavailable. A halt request to it waits until the debugger times out.
- **The crossbar** routes the I$'s line Gets to the debug window with `TG_DEBUG`. Without it they go only to memory and the boot ROM (soc.md §9.5).

### The CSRs, per hart (debug mode only; elsewhere an illegal instruction)
| CSR | Address | Contents |
|---|---|---|
| `dcsr` | 0x7B0 | `debugver` 4 and `cause` (read-only); `ebreakm`, `ebreaks`, `ebreaku`, `step` and `prv` writable (`prv` 2 writes as U, as MPP); hardwired: `stepie` 0 (no interrupt during a step), `stopcount` 1 (hart-local counters stop in debug mode and for an `ebreak` that enters it), `stoptime` 0 (`time` is the shared ACLINT's), `mprven` 0 (MPRV is ignored in debug mode, so the ROM's window accesses never translate; OpenOCD translates virtual addresses itself); `extcause`, `cetrig`, `pelp`, `ebreakvs`, `ebreakvu`, `v` and `nmip` 0. Reset: `prv` 3, the writable rest 0 |
| `dpc` | 0x7B1 | the pc to resume at, with `mepc`'s legal values |
| `dscratch0`, `dscratch1` | 0x7B2, 0x7B3 | 64 bits each. The DM's ROM keeps the hart's `s0` and `s1` there, so `hartinfo.nscratch` is 0 |

### Entry
- **Causes, highest first** (the spec's priority table: reset-halt, halt group, halt request, trigger, `ebreak`, step): the halt request (3), `ebreak` (1), a step (4). There are no triggers, reset-halt or halt groups. A halt request pending while an `ebreak` commits wins, with `dpc` at the `ebreak`.
- **The halt request** is taken at commit as the thread's highest-priority interrupt, by `do_irq`'s path: the thread's window flushes, `dpc` is the pc of the next instruction to commit, and the cause is 3. It works the same in split and merged mode. A thread asleep in WFI (core-pipeline.md §8.5) wakes for it (`wk_i`) and its halves split as for an interrupt. The WFI completes and its successor's pc is `dpc` (the spec: "leave the stalled state, completing this instruction's execution, and then enter Debug Mode").
- **`ebreak`** in a mode whose `dcsr.ebreakm`/`s`/`u` is set enters at commit in place of the breakpoint exception. `dpc` is the `ebreak`'s pc and the cause is 1. No trap CSR changes, and `minstret` doesn't count it.
- **On entry:** `dcsr.prv` takes the current privilege, along with `dcsr.cause` and `dpc`. The hart enters debug mode at M privilege, and fetch goes to 0x1100_0800. Pending interrupts stay pending.

### In debug mode (the spec's list, as built)
- M privilege, with the four debug CSRs accessible.
- **Interrupts:** all masked.
- **Exceptions:** traps don't take place. An exception (illegal instruction, access or page fault, misaligned access, `ecall`, and `mret` or `sret`, which the spec leaves unspecified there) flushes and jumps to 0x1100_0808. It changes no CSR: `mepc`, `mcause`, `mtval` and `mstatus` keep their values.
- **`ebreak`** re-enters at 0x1100_0800 without changing `dpc` or `dcsr`.
- **`wfi`** is a nop.
- **Translation:** MPRV is ignored, so loads and stores are M-mode physical and fetches untranslated. PMP applies as in M-mode, through locked entries only (`abstractcs.relaxedpriv` 0).
- **Counters:** `mcycle`, `minstret` and the HPM counters don't count; `time` does.
- **Control transfers and `auipc`** behave as usual, since the ROM jumps between its loop, the abstract area and the program buffer.
- **The debug window** (`DEBUG_BASE` 0x1100_0000, 64 KiB):
  - in debug mode it is fetchable through the I$, as the boot ROM is (line refills), with loads and stores uncached on the device path. PMP checks it as any M-mode access, through locked entries only (the spec leaves the DM's memory to the implementation), and the firmware locks none over it;
  - outside debug mode, every fetch, load and store to it is an access fault. The PMA check comes before the I$, so a line left in the I$ can't be fetched;
  - the ROM executes `fence.i` before jumping into the abstract area or the program buffer, which the DM has just written (soc.md §9.5).
- **The commit trace:** no records in debug mode, and one marker record at entry, where verif-2's checker stops, since a debugger can change state that Spike can't follow.

### `dret` (0x7B200073)
- Legal in debug mode only; elsewhere it is an illegal instruction.
- It is serialising, like `mret`. At commit it flushes and then:
  - sets the pc from `dpc` and the privilege from `dcsr.prv`;
  - clears `mstatus.MPRV` if the new privilege is below M (the spec's Resume section);
  - leaves debug mode. From the next fetch on, the window faults again.
- With `dcsr.step` set, it arms one step.

### Single step (`dcsr.step`)
- After `dret`, the hart commits one instruction. The next commit is then replaced by entry with cause 4, and `dpc` is the next pc (the pc + 4 or 2, or a taken jump's or branch's target).
- **A stepped instruction that traps:** the trap is taken (`mepc` and the rest as usual), and debug mode is entered at the handler's first pc before any of the handler runs.
- **An exception at the new pc** (an instruction access fault at a jump's target, say) is deferred. Entry happens with `dpc` at that pc, and the fault comes when the hart resumes.
- **A stepped `wfi`** is a nop.
- **Interrupts:** none is taken during a step (`stepie` 0).
- **Other causes win:** a stepped `ebreak` with its mode's `dcsr.ebreak` bit set enters with cause 1, and a halt request during a step enters with cause 3.

### The units
- **`tg_csr`:** the four CSRs per hart, the debug-mode bit per hart, entry's and `dret`'s writes, and the counters' stop.
- **`tg_rob`:**
  - entry at commit: the halt request as an interrupt, `ebreak`'s redirect, and the step's one commit;
  - `dret`'s serialisation;
  - debug-mode exceptions to 0x808 and `ebreak` to 0x800;
  - the trace's suppression and its marker.
- **`tg_fetch`:** the window's fetch permission, by the thread's debug mode.
- **`tg_lsu`:** the window's loads and stores in debug mode only. MPRV is ignored in debug mode (tg_csr's data mode).
- **`tg_core`:** `debug_req_i` connected, and the halt request among the sleepers' wake events.

### Cost and checks
- **Cost:** m9-plan §8 estimates about 50 LUTs and 100 FFs a hart for the CSRs, and 150–300 LUTs a core for entry and exit. Measured when built, in a development build.
- **With the switch off:** cycle-identical, with no new logic.
- **Tests:**
  - a directed test against a simulation model of the window in `tg_vsim` (a small ROM image), covering halt, a canned register read, a step, `ebreak` entry, an exception to 0x808, and `dret`;
  - soc-2's run with the real DM in `tb_boot` (soc.md §9.6).

## Parameters
`NUM_THREADS` (per-hart state since M7's step 2, core-pipeline.md §9.6; one thread runs until step 5), PMP entries (`PMP_ENTRIES`, 8 or 16), `PA_W`. The extensions follow the `tg_core_pkg` switches (core-pipeline.md §4), which turn on together with the M3 ISA string.

## Timing and area
CSR accesses are serialised, so the CSR file is off the critical paths. The cold CSRs are in LUTRAM indexed by {tid, CSR} (R2, core-pipeline.md §9.5); the hot state is flip-flops, one copy per hart (§9.6).

## Verification
- Done (lockstep, every M3 switch on, Spike `--priv=MSU`): `rv64mi-p` 17/17, `rv64si-p` 7/7, the `-v` suites; directed `vm.S` (S and U through Sv39, MPRV, SUM, MXR), `pmp.S`, and `irq_s.S` (SSI/STI/SEI delegated to S, Sstc, STI in U and waking WFI in S, an M timer interrupt taken from S).
- To come: ACT4 (privilege tests) when the flow targets the core; OpenSBI + Linux in simulation (M3 exit).

## Provenance
- RISC-V Privileged Architecture 1.13 (status fields, delegation, xRET, Sstc, counters).
- RISC-V Debug Specification 1.0 (debug mode: the Sdext chapter and the core debug registers).
- Spike's CSR implementation was read as the reference model's behaviour (plan §2.3 allows reference models and tools), to make every WARL field compare in lockstep.
- No other core's RTL was read.
