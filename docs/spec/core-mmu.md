# MMU and PMP (`tg_tlb`, `tg_ptw`, `tg_pmp`, M3)

Status: draft for M3 — core track — 2026-10-13

## Purpose
Sv39 address translation and physical memory protection for fetch, loads, stores, atomics and the page-table walker (plan §4.10, §2.2). M3 builds the functional version: an L1 TLB per side, one walker through the L1D, PMP on every access. The plan's 512-entry L2 TLB, the page-walk cache and a second concurrent walk are M6 options.

## Interface
- **`tg_tlb`** (ITLB: `ITLB_ENTRIES` = 16; DTLB: `DTLB_ENTRIES` = 32; fully associative): combinational lookup of {VPN, ASID}. A hit returns the PPN, the level (4K, 2M, 1G), R/W/X/U, D and G. Filled by the walker; flushed by SFENCE.VMA. Spike S4's `tg_dtlb` is the starting point (entries tagged {TID, ASID}).
- **`tg_ptw`**: one walk at a time. Requests come from fetch (ITLB miss), the load pipe and store-address port (DTLB miss), and commit (the walk that decides a fault, below). PTE reads go into the load pipe's AG slot, ahead of LQ replays, and read the L1D like a load; a PTE line that misses takes the MSHR. Results: a fill for the requesting TLB, or a fault.
- **`tg_pmp`**: combinational check of {physical address, size, access type, mode} against the 16 entries in `tg_csr`.

## Behaviour

### When translation applies
- **Fetch:** in S and U when `satp.MODE` = Sv39.
- **Data:** in the data mode `priv_d`, which is MPP when `mstatus.MPRV` = 1 and `priv` = M, else `priv`.
- **Untranslated (M, or Bare):** the physical address is the address itself. Bits above `PA_W` raise an access fault (as M2).
- **Translated addresses** must be canonical (bits 63:39 equal to bit 38), else a page fault.

### TLB hit checks (Spike's walk rules, applied to the cached leaf)
- **Fetch:** X. U pages only in U mode; S never fetches from a U page.
- **Load:** R, or X with MXR. U pages in U; in S only with SUM.
- **Store and AMO:** W. U pages as for loads.
  - A hit with D = 0 is treated as a **miss** and re-walked: the PTE may have been updated since the fill, and Spike reads it.
- **A failed permission is a page fault:** 12 (fetch), 13 (load), 15 (store/AMO), with tval = the virtual address.
- **Entries are installed only from walks that succeeded** for their requester. Invalid or reserved PTEs are never cached (plan §2.2).

### Walk (Sv39, as Spike's `walk()`)
For level 2 to 0, the PTE address is (level 2: `satp.PPN`, else the previous PTE's PPN) × 4096 + VPN[level] × 8. The PTE read must be `PMA_MEM` and pass PMP in S mode; otherwise an access fault (1, 5 or 7, by the requester's type). Then, in this order (each failure is a page fault):
1. Reserved bits (63:54 without Svpbmt/Svnapot) set → fault.
2. V = 0, or W = 1 with R = 0 → fault.
3. Non-leaf (R = X = 0): D, A or U set → fault; else next level (level 0 → fault).
4. Leaf: the U-bit rule for the mode (as for hits).
5. Superpage with nonzero low PPN bits → fault.
6. Permission for the access type (as for hits).
7. Svade: A = 0, or a store with D = 0 → fault (no hardware A/D update).

A success installs the leaf, with the level, in the requester's TLB.

### Miss handling (M3: correct and simple)
- **Fetch:** an ITLB miss parks fetch (like an I$ miss) and requests a walk; the fill restarts fetch. A walk fault becomes a fault block (cause 12). For a 32-bit instruction whose second half lies in the faulting page, tval is the faulting halfword's address.
- **Load / store address:** a DTLB miss marks the instruction's ROB entry `replay` with a `tlb` flag, and asks the walker for its VA (dropped if the walker is busy; this walk only prefetches the translation). The load or store does not access memory. The LQ/SQ entry keeps the VA.
- **Commit, head with `replay`+`tlb`:**
  1. If the DTLB now translates the head's VA, flush and refetch at its PC.
  2. Otherwise, when the walker is free, start a walk for it (non-speculative) and wait.
  3. A fill → flush and refetch. A fault → the head takes the page or access fault (precise).

  Speculative walks never raise exceptions.
- **SFENCE.VMA** (and SINVAL.VMA, SFENCE.W.INVAL, SFENCE.INVAL.IR, serialised) flushes both TLBs entirely. Over-flushing is always legal; the address and ASID forms come with the L2 TLB (M6).
- **satp writes** take effect after the flush that follows every CSR write.

### PMP (`tg_pmp`)
- **Entries:** 16, `pmpcfg` / `pmpaddr` in `tg_csr` (WARL rules in core-pipeline.md §9.1). Modes OFF, TOR, NA4, NAPOT; granularity 4 bytes.
- **Match:** the lowest-numbered entry matching any byte of the access decides, and every byte of the access must match it; otherwise the access fails. Misaligned accesses trap before PMP, so an access is one naturally aligned unit.
- **Permission:** R (load, PTE read), W (store, AMO), X (fetch).
  - Locked entries (L) apply to M too; unlocked entries do not.
  - No matching entry: M is allowed; S and U are denied.
- **Where it is checked:**
  - fetch, per 4-byte word of the block, with `priv` — the first denied word ends the block with an access fault (cause 1);
  - loads, stores and atomics at AG, after translation, with `priv_d` (causes 5, 7);
  - PTE reads in S.
- **tval** is the original virtual address.

## Parameters
`ITLB_ENTRIES`, `DTLB_ENTRIES`, `PA_W`, `TID_W` (entries are tagged with the thread). `L2TLB_ENTRIES` and `PWC_ENTRIES` are unused until M6.

## Timing and area
- **Lookups:** fully associative 16/32-entry lookups as in spike S4 (the DTLB in M1 of the load pipe), plus the PMP compare.
- **M3 moves the DTLB lookup into AG** (address add + CAM + PMP in one stage). This is a simulation-first choice: M6 puts it back in M1 with the D$ index from the untranslated page offset (VIPT).
- The plan's lever R6 (set-associative LUTRAM TLBs) is an M6 decision.

## Verification
- Lockstep on `rv64si-p`, every `-v` suite (virtual memory under the riscv-tests kernel environment) and ACT4's privilege and PMP tests.
- `rv64mi-p-pmpaddr` already passes.
- Random programs with virtual memory, when the generator offers them.
- Linux boot.

## Provenance
- RISC-V Privileged Architecture 1.13 (Sv39, PMP, SFENCE.VMA, Svinval, Svade).
- Spike's `walk()` and PMP matching were read as the reference model's behaviour, so faults and tval compare in lockstep (plan §2.3).
- Spike S4 (our RTL) for the DTLB.
- No other core's RTL was read.
