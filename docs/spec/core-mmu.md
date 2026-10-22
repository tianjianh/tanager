# MMU and PMP (`tg_tlb`, `tg_ptw`, `tg_pmp`, M3)

Status: implemented for M3 (`EXT_SU`, on); per hart for M7's step 4 — core track — 2026-10-20

## Purpose
Sv39 address translation and physical memory protection for fetch, loads, stores, atomics and the page-table walker (plan §4.10, §2.2). M3 builds the functional version: an L1 TLB per side, one walker through the L1D, PMP on every access. The plan's 512-entry L2 TLB, the page-walk cache and a second concurrent walk are M6 options.

## Interface
- **`tg_tlb`** (`rtl/core/mmu`; ITLB: `ITLB_ENTRIES` = 16 in `tg_fetch`, one lookup; DTLB: `DTLB_ENTRIES` = 32 in `tg_lsu`, three lookups: the LD port, the STA port, and the ROB head's check, which still counts only when STA is idle (it had shared STA's port; a port of its own takes the paths between the head VA and the store's checks out of the netlist)): fully associative, combinational lookup of the VPN. No ASID tags: every satp change and SFENCE.VMA flushes the hart's entries (as Spike), so every entry belongs to its hart's current address space. Each entry carries its thread (M7's step 4: the walk's, set at the fill): a lookup matches only its thread's entries (the DTLB's load and store ports by their queue entry's half, the head's check and the ITLB the running thread's), and a fill's overlap check takes only its thread's entries. A hit returns the leaf (`tlb_pte_t`: 22-bit PPN with the superpage bits taken from the VA, `big`, G, D, A, U, X, W, R, and the cached PMP result). A fill first invalidates every entry whose page overlaps the new one, so at most one entry matches (asserted); then it takes an invalid entry, else a round-robin victim. The match is a CAM in LUTRAM (below, Timing and area); the valid bits and levels are flip-flops, and the leaf and its level are in LUTRAM (`tg_ram_lut`), read at the matching entry's index, which is the OR of the match bits. Without a match the leaf is undefined, and users gate it with `hit`. Flush: the flushed hart's entries (commit slot 0's thread; with one thread, all). A fill in the cycle of its own thread's flush writes nothing (its victim may be the other thread's entry, which the flush keeps); the other thread's fill stays. After spike S4's `tg_dtlb`.
- **`tg_ptw`** (instantiated in `tg_lsu`): one walk at a time. Requesters in priority order: the ROB head's deciding walk, an ITLB miss (fetch), a DTLB prefetch (a one-entry buffer, cleared by flushes). PTE reads take the load pipe's AG slot ahead of LQ replays (IQ-LD's select is blocked while one waits), read the L1D like a load and come back at M2; a missing line takes the MSHR and the read retries when it is idle; a denied line is an access fault. Results: a leaf for the requester's TLB, or a fault cause. A flush of the walk's thread ends it. Each walk is a hart's (M7's step 4): the requester's thread (the head's, fetch's, the prefetch's access's), taken as the walk starts, selects that hart's satp, SUM, MXR and PMP state, and goes with the fill (the entry's thread) and with the walk's PMP checks.
- **`tg_pmp`**: combinational check of {physical address, 4 or 8 bytes (or a 16-byte fetch block, one result per word), access type, M or not} against the region descriptors `tg_csr` precomputes for each hart; each checker takes its access's hart's (M7's step 4). Four instances: fetch (one per block), the LD and STA ports, the walker.

## Behaviour

### When translation applies
- **Fetch:** in S and U when `satp.MODE` = Sv39.
- **Data:** in the data mode `priv_d`, which is MPP when `mstatus.MPRV` = 1 and `priv` = M, else `priv`.
- **Untranslated (M, or Bare):** the physical address is the address itself. Bits above `PA_W` raise an access fault (as M2).
- **Translated addresses** must be canonical (bits 63:39 equal to bit 38), else a page fault, raised at AG (fetch: a fault block) without a walk.

### TLB hits
A cached leaf is used only if it allows the access now (`pte_ok`, Spike's walk rules):
- **Fetch:** X. U pages only in U mode; S never fetches from a U page.
- **Load:** R, or X with MXR. U pages in U; in S only with SUM.
- **Store and AMO (and SC):** W and D. U pages as for loads. LR checks as a load.
- **Any failed check is a miss:** the walk decides, so page faults come only from walks (as in Spike, whose TLBs hold only translations that passed for their access type). This also re-reads a PTE that software changed (for example D set) since the fill.
- **Entries are installed only from walks that succeeded** for their requester. Invalid or reserved PTEs are never cached (plan §2.2).

### Walk (Sv39, as Spike's `walk()`)
For level 2 to 0, the PTE address is (level 2: `satp.PPN`, else the previous PTE's PPN) × 4096 + VPN[level] × 8. The PTE address must be below `PA_W`, `PMA_MEM` and allowed by PMP in S; otherwise an access fault (1, 5 or 7, by the requester's type). Then (each failure is a page fault: 12, 13 or 15):
1. Bits 63:54 set (reserved, PBMT, N: no Svpbmt or Svnapot) → fault.
2. Non-leaf (V = 1, R = W = X = 0): D, A or U set, or level 0 → fault; else the next level.
3. Leaf: the U-bit rule for the mode; V = 0, or W = 1 with R = 0; a superpage with nonzero low PPN bits; the access permission; Svade (A = 0, or a store with D = 0) → fault.

A success fills the requester's TLB with the leaf and its level.

### Miss handling (M3: correct and simple)
- **Fetch:** F1 looks the ITLB up with `fpc_q`; the I$ is indexed with page-offset bits and tagged with the PA. A miss parks fetch in F2 and requests a walk; its end restarts fetch at the parked PC. A walk fault makes every block of that page a fault block (cause 12, or 1 for a PTE access fault) until a redirect.
- **Fault blocks and tval:** a fault block is one pseudo-instruction at the entry PC (tval = PC). When a 32-bit instruction began in the previous block (or, for PMP, at the entry) and only its second half faults, tval = PC + 2, as Spike reports the faulting parcel's address.
- **Load / store address:** new loads and STA look the DTLB up at AG (LQ replays reuse the PA in the LQ). The LQ and SQ keep the VA (trace, tval, walks) and the PA (D$, forwarding, ordering checks, drain). A miss marks the ROB entry `replay` + `tlb`, puts the load in `L_TLB` (or the store's SQ entry in `tlb`), does not access memory, and offers the VA to the prefetch buffer.
- **Commit, head with `replay` + `tlb`:**
  1. If the DTLB now translates the head's VA (it looks it up with the third port), flush and refetch at its PC (`hd_retry`).
  2. Otherwise, once the walker is free and the committed stores have drained (so the PTE reads see them), the deciding walk starts.
  3. A fill → the head finds it and refetches. A fault → the head traps with its cause and tval = VA (`hd_fault`), precisely.

  Speculative walks (fetch, prefetch) never raise exceptions in the data path; a fetch walk's fault reaches the trap only through a fault block that commits.
- **SFENCE.VMA** (and SINVAL.VMA, SFENCE.W.INVAL, SFENCE.INVAL.IR, serialised) commits once the store queue has drained and flushes the hart's entries in both TLBs together with the pipeline flush. Over-flushing is always legal; the address and ASID forms come with the L2 TLB (M6).
- **satp writes** commit once the store queue has drained; a write that changes satp flushes the hart's entries in both TLBs with the flush that follows (Spike does not flush on a rewrite of the same value).

### PMP (`tg_pmp`)
- **Entries:** `PMP_ENTRIES` (`tg_core_pkg`): 8 by default (DR-167, the user's area reserve: each checker scales with the count, about 2.7K LUTs a chip of two cores), or 16 with `TG_PMP_ENTRIES=16`, cycle for cycle as before. `pmpcfg` / `pmpaddr` in `tg_csr` (WARL rules in core-pipeline.md §9.1); with 8 entries, entries 8–15 read zero and ignore writes, which every PMP field's WARL rule allows (software probes the count; OpenSBI's Domain0 uses 6). Modes OFF, TOR, NA4, NAPOT; granularity 4 bytes.
- **Region descriptors** (flip-flops in `tg_csr`, read by every checker): per entry the mode, R/W/X/L, `pmpaddr`'s low `PA_W` − 2 granule bits, whether its high bits put a TOR top above every physical address, and for NAPOT/NA4 the compare mask and whether the region lies above the physical address space. Only `PA_W` − 2 bits are compared; a TOR top is compared once and serves as the next entry's base.
- **Descriptor updates:** `pmpaddr` is a LUTRAM. A PMP write marks the entries it changes (a `pmpaddr` write one, a `pmpcfg` write eight), and one descriptor unit recomputes a marked entry per cycle, with the entry's alignment to 4K, 2M and 1G pages (`pmp_pal`, for the walker's page check below). Meanwhile, and for a cycle after, `pmp_busy` holds fetch (F1): the write is serialised and followed by a flush, so nothing else checks PMP until fetch resumes. After reset a 16-cycle sweep writes the reset values into the LUTRAM (entry 0: NAPOT over everything), then all 16 descriptors are computed.
- **Cached in the TLB** (plan §4.10, lever for area and the AG/F1 paths): a fill checks the leaf page's base once more (one cycle in the walker) and stores the S/U permissions with the entry. They hold for the whole page when no active region boundary lies strictly inside that page, which the walker checks against every entry in the same cycle, for a leaf of any size (DR-182): no NAPOT or NA4 region smaller than the page within it, and no TOR bound (an entry's address that tops its TOR range or bottoms the next entry's) within it and unaligned to the page (`pmp_pal`). Then fetch, loads and stores use the cached bits. Bare-mode accesses, M-mode accesses, and pages with a boundary inside use the checker. PMP writes flush the hart's entries in both TLBs (as Spike).
  - **Per page at every size (DR-182).** Until fn7 the condition was per page size, for all pages at once. OpenSBI's firmware region is not 2M-aligned, so every 2M and 1G page lost the cached result, and with DR-140 #6 every kernel fetch block waited a cycle: the Linux boot was 2.2% slower (core-pipeline §13). fn7 checked 2M pages one by one; 4K and 1G pages kept a flag for every page of their size (`pmp_al`), so one region smaller than a page anywhere stopped the caching for every 4K page (soc-2's d4r2 firmware: a store loop −23.6%, sysbench memory −12.7%). DR-182 checks every leaf's own page: such a region costs that page alone. +26 LUTs a core (the walker +86, `tg_csr` −60 without the flags). On our layouts the cycles are the same: OpenSBI's regions are 4K-aligned NAPOT, Linux maps no 1G page, and the suites' default PMP is one region over everything.
  - **Conservative:** the test is per entry, so a boundary behind a lower-numbered region that covers the whole page still stops the caching. The exact rule (the lowest-numbered entry touching the page covers all of it) would take a priority chain over the entries; not taken.
  - **Shadow checker** (simulation only): every access that decides with a cached result is checked in full on its physical address too, and the two must agree (an assertion): loads and store addresses in `tg_lsu`, each fetch block's words in `tg_fetch`. The walker counts its fills by size, and how many cache their result, on stderr at the end (`TG-PMPH`).
- **Match:** the lowest-numbered entry matching any 4-byte granule of the access decides, and every granule must match it; otherwise the access fails (an 8-byte access that only half matches fails). Misaligned accesses trap before PMP, so an access is one naturally aligned unit.
- **Permission:** R (load, LR, PTE read), W (store, AMO, SC), X (fetch).
  - Locked entries (L) apply to M too; unlocked entries do not.
  - No matching entry: M is allowed; S and U are denied.
- **Where it is checked:**
  - fetch, per 4-byte word of the block, with `priv`: the first instruction from the entry that touches a denied word makes the block a fault block if it is the entry instruction (cause 1), else the block ends before it and fetch resumes there;
  - loads, stores and atomics at AG, after translation, with `priv_d` (causes 5, 7);
  - PTE reads, in S.
- **tval** is the original virtual address.

### Known differences from Spike (none reached by the tests)
- A PTE in a device region: the RTL raises an access fault; Spike would read the device.
- Spike also flushes its TLB on privilege changes and on writes to mstatus (MPRV, SUM, MXR, MPP) and PMP CSRs. Our hits re-check the current mode and bits, so only PTE changes made without SFENCE.VMA can differ, which the ISA leaves unspecified.
- Speculative walks read PTEs from the D$ without searching the store queue: a PTE store that has not drained can be missed by a fetch walk or a prefetch. Without SFENCE.VMA both outcomes are legal; deciding walks wait for the drain.

## Parameters
`ITLB_ENTRIES`, `DTLB_ENTRIES`, `PMP_ENTRIES` (8 or 16), `PA_W`, `TID_W` (each TLB entry carries its thread, and a
satp write, SFENCE.VMA or a PMP write flushes its hart's entries: M7's step 4, threading.md). `L2TLB_ENTRIES` and `PWC_ENTRIES` are unused until M6.

## Timing and area
- **Lookups:** fully associative 16/32-entry lookups as in spike S4 (the DTLB in M1 of the load pipe). Entries keep a 22-bit PPN (`PA_W` − 12) and a flag for a PTE whose PPN reaches above `PA_W` (every access then faults).
- **M3 moves the DTLB lookup into AG** (address add + CAM + PMP in one stage). This is a simulation-first choice: M6 puts it back in M1 with the D$ index from the untranslated page offset (VIPT).
- **TLB leaves in LUTRAM:** the leaf is read from a `tg_ram_lut` at the encoded match. This replaces an AND-OR over the entries; the DTLB keeps 6 RAM32M16 for its two lookups, and the ITLB 3.
- **The DTLB's match is a CAM in LUTRAM (FPGA-friendly T5, `CAM = 1`). The ITLB compares flip-flop VPNs (`CAM = 0`).**
  - **Tables:** the VPN is cut into six slices, each 9-bit level into 5 + 4 bits. Slice table s holds one bit per entry at each slice value: set when the entry's VPN has that value there.
  - **Lookup:** it reads every table at its VPN's slices. Entry e matches when its valid bit and its tables' bits agree; a level's slices don't count above the entry's page size (`lvl_q`, flip-flops).
  - **Fill:** it behaves as before, in one cycle:
    - The overlap check reads the tables at the new VPN through a maintenance read port.
    - The valid bits, the level and the leaf change in the fill cycle.
    - The next two cycles clear the victim's bits at its old VPN (from a key store, LUTRAM) and set them at the new one. Each is a read-modify-write through the maintenance port. Meanwhile the entry is left out of the table match, and a comparator on the new VPN stands in for it.
  - **Spacing:** fills come at least six cycles apart, since there is one walk at a time (asserted).
  - **Lookups a cycle ahead** (`EARLY`, timing, DR-145): with the address-stage split, the LD and STA ports read the tables and match at AG, on the address that M1 registers, and the match vector is registered. In M1 it is corrected for the clock edge between: ANDed with a register of the valid bits less a just-filled entry (a flush, a fill's overlap and its victim leave it), and the filled entry matched by the fill's VPN, compared a cycle ahead too. When the filled entry matches no other entry can, so the index is the OR-encoded registered match ORed with the filled entry's index: the leaf's read starts about 3 LUT levels from flip-flops (from 7 before the leaf's read on the forwarding family's path, then 7 from the valid bits through the per-entry override). The answer is the lookup M1 would make; simulation checks every lookup against each entry's VPN, the flip-flop form, and the index and hit against the match.
  - **Reset:** a 32-cycle sweep zeroes the tables. The key store needs no reset, because clearing a never-filled entry's bits is a no-op.
  - **Why:** the flip-flop CAM compares every entry's 27-bit VPN at each lookup port and again for the overlap check. The slice tables' cost doesn't grow with the compares in the same way.
  - **Measured** (budget flow, st, per instance, main 41bc3f6 → the CAM in both TLBs at f18704e):
    - **DTLB** (32 entries, two lookups and the overlap check): 1,470 → 1,104 LUTs, 965 → 146 flip-flops. The CAM wins.
    - **ITLB** (16 entries, one lookup and the overlap check): 486 → 480 LUTs, 484 → 92 flip-flops, for 160 more LUTs as LUTRAM. LUT-neutral: T5 is rejected for it.
  - **The verdict, with pros and cons (DR-124):**
    - **DTLB on the CAM:**
      - Pros: −366 LUTs and −819 flip-flops.
      - Cons: the three-cycle table update and its bypass comparator; a fill spacing to keep (asserted); a 32-cycle reset sweep.
    - **ITLB on flip-flops:**
      - Pros: one comparator per entry and no update state machine, for the same LUTs; the 160 LUTRAM LUTs stay free.
      - Cons: 392 more flip-flops; two TLB forms to maintain, one parameter apart.
  - **Source:** the spikes track's `tg_cam_lut` (slice tables, key store), extended for superpage levels, two lookups and the overlap check.
- **The walker's checks use the STA port's checker** (DR-139, the user's decision, superseding DR-122).
  - The walker checks the PTE address (W_CHK) and the leaf's page base (W_PMP) in a cycle without a store address at the decision (`chk_gnt`: AG without the split, M1 with it), so a walk step waits a cycle whenever a store address decides.
  - The request (`chk_req`) and the address come from flip-flops, each loaded with the value the walk's state gives it in the next cycle (timing, DR-145: the walker's VA, its canonical check and the address multiplexer left the checker's paths into the store's decision; asserted equal to the combinational form).
  - A translated store without the DTLB's cached result checks a cycle after its decision (S2, core-lsu), on the same checker. When the walker takes it (`chk_req` and the grant), the S2 check waits a cycle. The walker never checks two cycles running, and no store reaches S2 in the cycle after the walker's grant, so the wait is one cycle and walks keep their timing. A bare-mode store checks at its decision; no walk of its thread runs then (another thread's walk step waits for it, as for any store address at the decision, and so does another thread's S2 check: M7).
  - −0.83K LUTs per core. Cost by `make cycle-identical`, st / smt2: isa +0.05% / +0.23%, bench 0.
- The plan's lever R6 (set-associative LUTRAM TLBs) is an M6 decision.

## Verification
- Lockstep, with `EXT_SU` and `EXT_A` on: `rv64si-p` (7/7, including `dirty` and `icache-alias`), `rv64ui-v`, `rv64um-v`, `rv64ua-v` (the riscv-tests kernel environment with demand paging), `rv64mi-p-pmpaddr`; under `--lat`, `--bp`, `--d-gap`, `--probe-rate` and `--grant-b` stress.
- Directed: `tests/isa/directed/vm.S` (superpages, every PTE fault rule, SUM/MXR, MPRV, SFENCE.VMA and satp changes, atomics under translation, fetch faults in S and U), `pmp.S` (NAPOT/NA4/TOR, a half-matching 8-byte access, no-match, a locked entry binding M, a fetch block executable for two words only) and `pmp_page.S` (DR-182: a region boundary inside one 4K page, one 2M page and one 1G leaf, beside a page of each size without one; S loads and stores on both sides of each boundary).
- `tests/unit/tlb` (M7's step 4): two threads' lookups, fills and per-hart flushes against a model of each thread's pages, in the DTLB's CAM shapes (with and without `EARLY` ports) and the ITLB's flip-flop shape; its negatives (every lookup, or every fill, given thread 0) fail.
- To come: ACT4's privilege and PMP tests, random programs with virtual memory when the generator offers them, Linux boot.

## Provenance
- RISC-V Privileged Architecture 1.13 (Sv39, PMP, SFENCE.VMA, Svinval, Svade).
- Spike's `walk()` and PMP matching were read as the reference model's behaviour, so faults and tval compare in lockstep (plan §2.3).
- Spike S4 (our RTL) for the DTLB.
- No other core's RTL was read.
