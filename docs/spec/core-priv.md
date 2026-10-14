# Privilege modes, CSRs, traps and interrupts (`tg_csr`, M3)

Status: implemented for M3 behind `EXT_SU` — core track — 2026-10-13

## Purpose
Extends the M2 machine-mode CSR file ([core-pipeline.md](core-pipeline.md) §9) to the privilege architecture Linux needs (plan §2.2, §4.1, §4.13): M, S and U modes; trap delegation; supervisor interrupts with Sstc; counters and their enables; the status fields that change memory access (MPRV, SUM, MXR, TVM, TW, TSR). The MMU and PMP are in [core-mmu.md](core-mmu.md); atomics in [core-lsu.md](core-lsu.md) §Atomics.

Target ISA string (M3, with verification.md §3.2; F and D join at M5): `rv64imac_zicsr_zifencei_zicntr_zihpm_zba_zbb_zbs_zicond_zihintpause_sstc_svinval_zkt_za64rs`, privilege `MSU`, 16 PMP entries, Sv39. Every field below follows Spike for that configuration, so lockstep compares every read.

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
| `medeleg` | Writable: causes 0 (only without C), 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 15 |
| `mideleg` | Writable: SSIP, STIP, SEIP |
| `mie` / `sie` | `mie`: SSIE, MSIE, STIE, MTIE, SEIE, MEIE. `sie`: the S bits, masked by `mideleg` |
| `mip` / `sip` | MSIP, MTIP, MEIP from the inputs. SSIP writable by M. STIP is writable by M only while `menvcfg.STCE` = 0; with STCE it is `time >= stimecmp`. SEIP reads as the input OR a software bit (writable by M). `sip` shows the bits `mideleg` delegates, and only SSIP is writable through it. Reads of `mip`/`sip` are `nondet`. |
| `mcounteren`, `scounteren` | 32 bits (Zicntr + Zihpm). Gate `cycle`, `time`, `instret`, `hpmcounter3–31` reads from S (mcounteren) and U (mcounteren and scounteren) |
| `menvcfg` | FIOM and STCE writable (no Zicbo*, Svpbmt or Svadu yet) |
| `senvcfg` | FIOM writable |
| `stvec`, `sscratch`, `sepc`, `scause`, `stval` | As their M counterparts; `sepc` masks like `mepc` |
| `satp` | MODE (Bare or Sv39; other modes leave MODE unchanged), ASID (16 bits), PPN (44 bits). Access in S with TVM is illegal. A write commits once the store queue has drained; one that changes the value flushes the TLBs (core-mmu.md). |
| `stimecmp` | Sstc. Access below M needs `menvcfg.STCE` and the `time` permission (`mcounteren.TM`), else illegal |
| `hpmcounter3–31` | Read 0 (Zihpm), `nondet`; gated by the enables |
| `mhpmevent3–31` | Read 0 (no Sscofpmf yet) |

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

## Parameters
`NUM_THREADS` (per-hart arrays arrive with M7; M3 is hart 0), PMP entries (16), `PA_W`. The extensions follow the `tg_core_pkg` switches (core-pipeline.md §4), which turn on together with the M3 ISA string.

## Timing and area
CSR accesses are serialised, so the CSR file is off the critical paths. The plan's lever R2 (cold CSRs in LUTRAM indexed by {TID, CSR}) applies when SMT2 doubles the state; M3 keeps flip-flops.

## Verification
- Done (lockstep, every M3 switch on, Spike `--priv=MSU`): `rv64mi-p` 17/17, `rv64si-p` 7/7, the `-v` suites; directed `vm.S` (S and U through Sv39, MPRV, SUM, MXR), `pmp.S`, and `irq_s.S` (SSI/STI/SEI delegated to S, Sstc, STI in U and waking WFI in S, an M timer interrupt taken from S).
- To come: ACT4 (privilege tests) when the flow targets the core; OpenSBI + Linux in simulation (M3 exit).

## Provenance
- RISC-V Privileged Architecture 1.13 (status fields, delegation, xRET, Sstc, counters).
- Spike's CSR implementation was read as the reference model's behaviour (plan §2.3 allows reference models and tools), to make every WARL field compare in lockstep.
- No other core's RTL was read.
