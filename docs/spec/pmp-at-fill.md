# PMP checks at TLB fill: correctness (design note)

**Status:** approved as DR-183 (the user, 10-21 22:45), with DR-182's per-page check first:
- DR-182, core-2's, is on main (6bed4f90);
- DR-183 is built behind the switch `PMP_FILL` (§7), merged off (main 90925ece) and on by default since its measured boot cost came in under 1% (+0.17% st, +0.19% smt2). soc-2 built it (the coordinator, 10-22, with the area pass on the critical path) in core-2's files, with core-2's agreement on them and its review of the plan.

The note is soc-2's (10-21), corrected and extended by core-2's review as the MMU's owner (`reports/pmp-at-fill-review.md` in core-2's build folder).

**The saving** (DR-183):
- Today's three checkers, with their per-thread selects and the CSR file's precompute, come to about 3.1K LUTs a core (spikes §8.18).
- Stubbing the fetch and load checkers measured −3,443 LUTs a chip after `opt_design` (spikes ex2, an upper bound).
- With the shared checker kept: about 2.5–3K a chip.

## The idea

- **Fast path:** a translated access (S or U with Sv39) uses the PMP result cached in its TLB entry. The walker computes it once per page, at the fill, and caches it only if the whole page is PMP-homogeneous.
- **Slow path:** everything else goes through one shared checker per core. It replaces today's three (fetch, the load port, the store-address port) and their per-thread descriptor selects.

Today ([core-mmu.md](core-mmu.md) §PMP) the walker already caches the result (`ph`, `pr`, `pw`, `px` in `tlb_pte_t`). It checks 2M leaves page by page (`pmp_p2m`), and 4K and 1G leaves take one flag for every page of the size (`pmp_al`). Uncached accesses use the three full checkers.
- **DR-182** applies the per-page check at every leaf size (§2).
- **DR-183** then makes the cache the only path for translated accesses, and the slow path rare.

## 1. Which accesses take the slow path

| Access | Path | Why |
|---|---|---|
| S or U, Sv39, TLB hit with `ph` = 1 | fast | the cached S/U result holds for every access inside the page (§2) |
| S or U, Sv39, `ph` = 0 (a page a PMP boundary splits) | slow, every access | no single result holds for the page |
| M-mode fetch and data, and data with `MPRV` = 1 and `MPP` = M | slow | no translation, so no TLB entry. M's rules differ from S/U's: only locked entries bind, and no match allows |
| Bare mode (`satp.MODE` = Bare) in S or U | slow | no TLB entry. U-Boot runs here in RISC-V mode, as does Linux before it enables paging |
| `MPRV` = 1 with `MPP` = S or U, Sv39 | fast | the effective privilege is S or U. PMP treats S and U alike, so the cached result is the right one; SUM and MXR act on the page, not on PMP. The RTL already does this (below) |
| The walker's PTE reads | slow, one per read | PMP checks page-table accesses as S-mode accesses (Privileged Architecture 1.13, §3.7). The leaf page's own check and homogeneity at the fill also use the slow checker, as `W_PMP` uses the STA port's checker today |

- **MPRV, as built:** the LSU already translates, and uses the cached result, by the effective data privilege (core-2). `xl_t` is `satp_sv39 && priv_d != M`, where `priv_d` is MPP while MPRV is set in M-mode. So those accesses already take the TLB's `ph`, `pr` and `pw`; DR-183 adds nothing there.
- **`big` is not a page size** (core-2): `tlb_pte_t.big` means the PPN has bits above `PA_W`. Every access through such a leaf faults before PMP, so it is never cached, and it is no slow-path case.
- **The fill's own checks contend with M-mode and bare accesses only when another hart is in M-mode or bare at that moment.** The walking hart itself is in S or U. So the shared checker needs arbitration, but it is rarely contended (§4).
- **Locked entries** change only M-mode results, and M-mode is always on the slow path. For S and U a locked entry is an ordinary entry in the cached result, and it can't change until reset, so it needs no flush. OpenSBI 1.9 on our core never sets L:
  - it has no Smepmp, so it takes the old PMP path;
  - there L comes only from `ENF_PERMISSIONS`, which only domain nodes in the device tree request, and our trees have none.

  Locked entries come only from tests.
- **Split pages** should not occur on our trees. Every MMIO range covers whole pages (`check_pages.py`, [soc.md](soc.md) §4), and OpenSBI's regions are naturally aligned NAPOT regions of at least 4 KiB. With DR-182, a sub-page region costs only its own page, not every page of its size as `pmp_al` does today (the memory gap of 10-21, [soc-d4-modes.md](soc-d4-modes.md)).
- **1G pages: cached, with the same per-page check.** A gigapage on the slow path would send all its traffic through one checker, and with DR-182 caching it costs nothing more. Linux maps no 1G page on the board today: its 1 GiB of RAM starts at `0x8000_0000` with OpenSBI's no-map region at the base, so the linear map can't take the first gigapage whole.

## 2. Access size and page crossings

- **The rule:** the lowest-numbered entry that matches any byte of an access decides, and it must match every byte, or the access fails. With no match, M is allowed and S/U are denied.
- **Homogeneous:** every entry covers either the whole page or none of it.
  - Then every byte of the page matches the same set of entries, so the same lowest-numbered entry decides for any access inside the page.
  - It covers the whole page, so it matches every byte of the access. The page's result is every access's result.
  - A page that no entry matches caches "deny" (`rwx` = 000): an access fault with the access type's cause.
- **No access crosses a page:**
  - misaligned loads, stores and AMOs trap before PMP, so a data access is one naturally aligned unit of at most 8 bytes;
  - a fetch block is 16 bytes, aligned. A 32-bit instruction that straddles a page is two fetches, each checked with its own page's entry;
  - PTE reads are 8 bytes, aligned.
- **The per-page check (DR-182)** applies the walker's 2M test (`tg_ptw`, `leaf_nh`) to the leaf's own page at every size. An entry breaks a page of size P only if:
  - it is NAPOT or NA4, smaller than P, and inside the page. Being naturally aligned, it is either inside or disjoint;
  - or one of its addresses that bounds a TOR range (`top(i−1)` or `top(i)`) lies inside the page, unaligned to P.

  OFF entries and regions above the physical address space never break one.
- **What each entry needs:** the page compare, or a flag `tg_csr` already keeps.
  - the page compare: `((a ^ page) & ~mask_P) == 0`, over 22 granule bits for 4K, 13 for 2M and 4 for 1G, with `PA_W` = 34;
  - "smaller than P": `nap && !above && mask[P−1]`;
  - "aligned to P": `pal_top_q`, which `tg_csr` already computes per entry for 4K, 2M and 1G.
- **The walker** picks the mask, the bit and the flag by the leaf's level (`lvl_q`) in `W_PMP`, as today, and sets `ph = !leaf_nh && !big` at every size.
- **`tg_csr`** exports the three alignment bits per entry (`pmp_pal`) in place of `pmp_p2m`, and drops `pmp_al`. It keeps its cycle of fetch hold, so PMP writes take the same cycles as today.
- **Measured** (core-2, out of context, smt2 with hart 1, main 5332b771): +26 LUTs and −5 flip-flops a core. The walker grows by 86 LUTs, and `tg_csr` loses 60 with the flags. The fill stays one cycle.
- **Exact per entry, conservative as a whole:** any entry that breaks the page makes it split, even behind a lower-numbered entry that covers the whole page and so decides every access there.
  - The exact rule, "the lowest-numbered entry touching the page covers all of it", costs a priority chain of a few tens of LUTs.
  - It would help only a layout with a sub-page region numbered above a page-covering one. OpenSBI orders the other way: its catch-all S/U region is last.
  - Conservative is safe: such a page just takes the slow path.

## 3. PMP writes

- **The spec** (Privileged Architecture 1.13, §3.7, "Physical Memory Protection and Paging"): translations, and the PMP results for them, may be cached. After writing `pmpcfg` or `pmpaddr`, M-mode software must execute `SFENCE.VMA` with `rs1` = `rs2` = x0.
- **OpenSBI 1.9** writes PMP:
  - at cold boot;
  - at each hart's warm start, so every HSM `hart_start` (Linux bringing a hart up, hotplug) reprograms it;
  - at resume from non-retentive suspend;
  - at domain switches, which our trees don't use.

  Each sequence ends in `sbi_hart_pmp_fence()`, an `sfence.vma`. Nothing writes PMP in steady state; the Smepmp map and unmap paths don't apply to our core.
- **Keep today's hardware flush:** a PMP write is serialised and flushes the writing hart's entries in both TLBs, as Spike does. With PMP results in the TLB as the only path, this flush is what keeps them right:
  - **Lockstep:** Spike flushes its TLB on PMP writes. A program that omits the fence would otherwise diverge from the reference.
  - **Tests and other firmware:** bare-metal tests, and possibly riscv-arch-test's PMP set, don't always fence.
  - **Walks in flight:** the flush also ends the hart's walk in progress, and clears the DTLB prefetch buffer (core-2), so no fill computed from the old PMP lands after the write. Walks after the write start only once its descriptors are recomputed: fetch is held (`pmp_busy`), and the window is empty, since the write retires alone. The walker must keep honouring that.
  - **Cost:** about nothing; the flush exists. Clearing only the PMP bits instead of whole entries would save refills on an event that happens a few times per boot: not worth the logic.

## 4. The second hart

- **Per-hart PMP:** each hart has its own PMP CSRs, and TLB entries carry their thread. The walker computes the cached result with the walking hart's descriptors, as it does today (`wt`, and `chk_tid` for the shared port).
- **Flushes:** a PMP write flushes only its hart's entries. The other hart's walks read its own descriptors, which the write doesn't touch, so its cached results stay right.
- **The shared checker** takes the requester's descriptors per request: one thread select in place of three. The harts contend for it only when both are in M-mode, bare or walking at once. At boot that is rare: OpenSBI's cold boot runs on one hart while the others wait in its HSM loop, and a warm start is one hart's.
- **One hart fast, one slow:** a hart running Linux in S-mode and another in M-mode at the same moment share only the checker's arbitration, for the first hart's walks.

## 5. How often the slow path fires

- **The timer:** with Sstc (implemented, `stimecmp`), Linux sets its own compare, and STIP is taken in S-mode. No timer interrupt enters M-mode. On the board, 25–70 timer interrupts a second idle and about 310 under load reached S-mode alone.
- **IPIs:** they go through SBI on our platform. The sender's `ecall` enters M-mode, and each target takes MSIP in M-mode, which then raises SSIP. Measured on the board (RISC-V mode, two harts, d4r2; memgap's idle and loaded windows, `fpga/kv260/board/memgap`):
  - idle: 0.8–59 function-call IPIs and 0.1–0.4 reschedules a second;
  - under load: 12–23 and about 1.5.

  So about 2–120 M-mode entries a second.
- **Remote fences:** with SBI IPIs, Linux sends TLB shootdowns and remote `fence.i` as SBI RFENCE calls. These enter M-mode on the caller and on each target, and don't show in `/proc/interrupts`.
- **All M-mode entries, counted on QEMU** (virt, four harts, the board's OpenSBI and the reference kernel, the release tree; busybox user space; every trap logged with `-d int`, 10-21):

  | Window | SBI calls (S-mode `ecall`) | M software interrupts | Illegal-instruction traps |
  |---|---|---|---|
  | Boot to the login prompt | 780 | 769 | 76 |
  | 30 s idle | 26 | 26 | 0 |
  | 200 fork/exec loops (`ls`) | 1,446 | 1,431 | 0 |

  - Every window has no M-mode timer interrupt (Sstc).
  - The illegal-instruction traps are boot-time; OpenSBI hands them back to Linux.
  - An idle system enters M-mode about twice a second; a process's creation and exit cost about 14 entries (its fences and IPIs).
  - QEMU doesn't trap misaligned accesses, so those aren't in the counts.
- **Other M-mode entries:**
  - illegal-instruction emulation: none, since `time` is a hardware CSR;
  - misaligned accesses: OpenSBI emulates them with MPRV loads unless Linux has them delegated through SBI FWFT. Compilers avoid them;
  - HSM and SRST: rare.
- **The boot, measured** (verif-2, DR-183: an st Linux boot to `TANAGER-BOOT-OK` on c0030303, 196.3M cycles, under lockstep):
  - 1.84% of the cycles run untranslated, almost all of them in OpenSBI's cold boot (3.32M cycles);
  - after Linux turns its MMU on there are only 17 M-mode entries, all SBI calls, about 14K cycles in all (about 800 cycles each);
  - a fetch and a data access want the checker in the same cycle in about 15% of the untranslated cycles. At one extra cycle each, that is about 0.28% of the boot.
- **Steady state,** at the boot's 800 cycles an entry:
  - an idle or lightly loaded system spends at most about 0.1% of a hart in M-mode (2–120 entries a second);
  - a load that creates hundreds of processes a second (a build, a shell script) adds about 14 entries each: a few thousand a second, about 2% of a hart in M-mode, and about 0.3% lost if the slow path costs M-mode code 15%.
- **PTE reads** take one slow check each (1–3 per walk). Steady-state S/U traffic leaves the checker free, so walks rarely wait for it.
- **Warm starts** of the other harts are short. **U-Boot** on the board runs in bare S-mode on the slow path; its time goes mostly to SD and network DMA.
- **If boot time matters:** one "last page" entry per hart for M-mode and bare accesses would keep the common case off the shared checker, for about 100 LUTs a core (core-2).
  - It takes the page's homogeneity from the same per-page logic, time-shared with the walker or a second copy.
  - It refills through the shared checker.
  - It flushes with the TLB on PMP writes.

## 6. Verification plan

- **Directed tests,** bare-metal, on the core in lockstep with Spike:
  1. **Sub-page regions:** an NA4 region and a TOR range inside one 4K page. S-mode accesses on both sides are right, that page doesn't cache, and a neighbouring page does.
  2. **The per-page check at each size** (DR-182, core-2): a boundary inside one 4K page, one 2M page and one 1G leaf, with neighbouring pages of each size caching. In today's design, the 4K and 1G cases are what `pmp_al` gets wrong, for performance, not correctness.
  3. **Locked entries:** an L region that denies M. M-mode fetch, load and store fault. S-mode follows the region's RWX. Writes to the entry are ignored after the lock.
  4. **MPRV:** M-mode with `MPRV` = 1:
     - `MPP` = S and Sv39: loads and stores on allowed and denied pages through the cached result;
     - `MPP` = M: physical, with M's rules.
  5. **PMP writes with and without `SFENCE.VMA`:** S-mode caches a page as allowed, then M-mode denies it, with the fence and without. The next S-mode access faults either way, as in Spike.
  6. **Two harts:** hart 1 changes its PMP. Hart 1's entries are flushed, and hart 0's stay and stay right.
  7. **Page-table reads:** page tables in a region PMP denies to S give an access fault with the requester's cause.
  8. **No match:** S/U are denied by default when entries are implemented. The cached deny faults with the right cause per access type.
  9. **Bare S-mode accesses** on the slow path.
- **A simulation-only shadow checker:** every translated access through a cached result is also checked in full, and the two must agree (an assertion). This covers every program and the Linux boot at no area cost. It runs in today's design too, so DR-182's per-page check lands under it before the shared checker (core-2).
- **riscv-arch-test's** PMP and privilege suites, in lockstep.
- **Random programs** with PMP configurations and Sv39 in lockstep, once the generator has a PMP option.
- **The Linux boot** under lockstep (st and smt2, four harts), with the cycle cost on the boot by profile, as DR-141 has it.
- **Measured already:** QEMU's M-mode entries (§5) and verif-2's boot profile (DR-183). Still to count:
  - the cycles of an M software interrupt, an IPI's target side (the st boot has none);
  - the M-mode entries under Debian on the board's four harts (RISC-V mode), where systemd's services add their own fences.
- **On the board:** memgap again, with `wr1k`, `rdtime`, `clock` and `ev1` at least at d4r2's figures with the page-sized reset syscon ([soc-d4-modes.md](soc-d4-modes.md), `fpga/kv260/board/d4r2`), and a RISC-V-mode Debian boot.

## 7. As built (DR-183, soc-2, 10-22)

- **The switch:** `PMP_FILL` (`sim/profile.mk`, `+define+TG_PMP_FILL`, `tg_core_pkg::PMP_FILL`; `TG_DEFINES="TG_PMP_FILL=0"` for the Vivado scripts), on by default. `PMP_FILL=0` builds the three checkers, cycle for cycle the core before DR-183 (below).
- **Which check decides:**

  | Access | Check |
  |---|---|
  | Translated S/U (fetch, loads, stores, AMOs) on a page with `ph` = 1 | the TLB's cached `px`, `pr`, `pw` alone |
  | M-mode, and MPRV with MPP = M, while the hart has no active locked entry | none: only locked entries bind M, and with no match M is allowed |
  | Bare S/U fetch | the hart's last-page entry (§5's lever), filled through the shared checker |
  | Any other fetch: a split page, M-mode with a locked entry | word checks on the shared checker |
  | Any other load, store or AMO: bare S/U, a split page, M-mode with a locked entry | the shared checker, at the access's check |
  | PTE reads, and the leaf's page check at the fill | the shared checker, as before (DR-139) |

- **No locked entry:** `tg_csr` gives each hart a registered OR of L over its entries that aren't OFF (`pmp_lk_h`). It settles the cycle after a PMP write's last descriptor changes. Fetch waits that out (`pchg_q`), and the write's flush has emptied the window.
- **One checker a core:** the store-address port's (`u_pmp_st`), which the walker already shares. Fetch's and the load port's checkers go, with their thread selects. The order:
  1. a store address at its decision;
  2. the walker's checks (`chk_gnt`);
  3. a translated store's S2 check, as before;
  4. the ROB head's parked MMIO load whose check is pending (`mh_req`);
  5. a load, new or replaying;
  6. fetch, which goes ahead of loads once it has waited `PFC_WAIT` (3) cycles, so load replays can't starve it.
- **Loads:** a load not granted in its check cycle doesn't complete. It replays with its check pending (`lq_pck_q`) and asks again. A parked MMIO load keeps the bit; the head then holds its issue (`mm_hold`) and asks with its thread's descriptors and privilege. A denial is its exception, on port 2.
- **DR-182's per-page test** moves beside the checker (`g_pg` in `tg_lsu`; `tg_ptw` keeps its own with the switch off). The walker's leaf in `W_PMP` (by `chk_lvl`) and fetch's 4 KiB page requests share it.
- **Fetch** has no checker. Its requests leave from flip-flops and stay up until the tagged response, the cycle after the grant. The work keeps the block it started for (`rq_id_q`: the hart, the PC's bits 38:2, M-mode or not, translation), all registers. Work for a block that isn't F1's is dropped the cycle after, with any response on its way and its last-page fill, and all work is dropped at a TLB flush (PMP, satp and SFENCE.VMA writes), so no result of the old descriptors outlives a PMP write. A block refetched with the same identity keeps its results. When F1's block changes is known late, from F3's redirects and the I$ refills: in spikes-2's previews that signal held the request registers' enables (−1.07 ns), then an epoch register (−1.24 ns), so nothing of DR-183's reads it.
  - **Last-page entry,** one per hart: the S/U execute result of the page F1 last fetched from in bare mode, and whether a region boundary lies inside it. A page request fills it; the hart's TLB flush empties it (PMP and satp writes, SFENCE.VMA). A split page goes to word checks.
  - **Word checks:** one 4-byte word at a time from the block's first, stopping at the first denied word. The block then ends before it, or is a fault block at its first instruction, as F2 takes `f1_pmpd` today.
- **Shadow checks** (simulation only) cover the new paths too: the last-page entry's result on every word, M-mode's skip (a full check under M's rules must allow), and the word checks up to the first denied word. A load or store that skips under M must pass a full check under M's rules.
- **Area** (out of context, the product's core: smt2 with hart 1, the URF, no trace, `flatten_hierarchy none`, at 5a885ab9): 56,976 → 55,640 LUTs, −1,336 a core and about −2,670 a chip, for +102 flip-flops a core.
  - fetch 8,562 → 7,994;
  - the LSU 14,891 → 14,208;
  - the walker 520 → 272;
  - `tg_csr` 2,093 → 2,015.
- **Switch off:** cycle-identical with main (a6ff993d), st and smt2, the suites and the boot's first 20M cycles.
- **Switch on:** the directed tests, 22 of 22 on st and smt2, with three new ones: `pmp_tlb` (§6's tests 5, 7 and 8: pages and a code stub cached, then denied with and without the fence; page tables S may not read; the default deny by access type), `pmp_mprv` (test 4) and `pmp_mlock` (M-mode's side of test 3: M passes unlocked entries and no match, and bare S is denied; once an entry is locked, M's fetch, loads and stores take the check, and a locked entry binds them). Regress on st, and on smt2 with hart 1.
- **To come:** ACT4's PMP set, the boots under lockstep (st, board, smp4) and the boot's cost.

## Order of work

1. **DR-182's per-page check** first, on its own (+26 LUTs a core), under today's three checkers. It is cycle-identical on our layouts and closes the `pmp_al` gap. On main (core-2).
2. **DR-183's shared checker** after step 7, behind its switch, replacing the three (§7, soc-2).
