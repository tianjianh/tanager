# PMP checks at TLB fill: correctness (design note, for review)

**Status:** a proposal (soc-2, 10-21), for core-2's review as the owner of the MMU. Not merged, no RTL, the plan unchanged. spikes-2 measures the area bound (about 2.3K LUTs a core: today's three checkers and their per-thread descriptor selects).

## The idea

- **Fast path:** a translated access (S or U with Sv39) uses the PMP result cached in its TLB entry. The walker computes it once per page, at the fill, and caches it only if the whole page is PMP-homogeneous.
- **Slow path:** everything else goes through one shared checker per core. It replaces today's three (fetch, the load port, the store-address port) and their per-thread descriptor selects.

Today ([core-mmu.md](core-mmu.md) §PMP) the walker already caches the result (`ph`, `pr`, `pw`, `px` in `tlb_pte_t`), checking 2M leaves page by page (`pmp_p2m`). 4K and 1G leaves take one flag for every page of the size (`pmp_al`). Uncached accesses use the three full checkers. The change is to make the cache the only path for translated accesses, and the slow path rare.

## 1. Which accesses take the slow path

| Access | Path | Why |
|---|---|---|
| S or U, Sv39, TLB hit with `ph` = 1 | fast | the cached S/U result holds for every access inside the page (§2) |
| S or U, Sv39, `ph` = 0 (a non-homogeneous page, or a `big` leaf) | slow, every access | no single result holds for the page |
| M-mode fetch and data, and data with `MPRV` = 1 and `MPP` = M | slow | no translation, so no TLB entry; M's rules differ from S/U's (only locked entries bind, no match allows) |
| Bare mode (`satp.MODE` = Bare) in S or U | slow | no TLB entry. U-Boot runs here in RISC-V mode, as does Linux before it enables paging |
| `MPRV` = 1 with `MPP` = S or U, Sv39 | fast | the effective privilege is S or U. PMP treats S and U alike, so the cached result is the right one; SUM and MXR act on the page, not on PMP |
| The walker's PTE reads | slow, one per read | PMP checks page-table accesses as S-mode accesses (Privileged Architecture 1.13, §3.7). The leaf page's own check and homogeneity at the fill also use the slow checker, as `W_PMP` uses the STA port's checker today |

- **Locked entries** change only M-mode results, and M-mode is always on the slow path. For S and U a locked entry is an ordinary entry in the cached result, and it can't change until reset, so it needs no flush. OpenSBI 1.9 on our core never sets L: it has no Smepmp, so it takes the old PMP path, where L comes only from `ENF_PERMISSIONS`, which only domain nodes in the device tree request, and our trees have none. Locked entries come only from tests.
- **Non-homogeneous pages** should not occur on our trees. Every MMIO range covers whole pages (`check_pages.py`, [soc.md](soc.md) §4), and OpenSBI's regions are naturally aligned NAPOT regions of at least 4 KiB. With a per-page check (§2), a sub-page region costs only its own page, not every page as `pmp_al` does today (the memory gap of 10-21, [soc-d4-modes.md](soc-d4-modes.md)).
- **1G pages: cache them, with the same per-page check.** A gigapage on the slow path would send all its traffic through one checker. The check is the 2M one at another index width. Linux maps no 1G page on the board today: its 1 GiB of RAM starts at `0x8000_0000` with OpenSBI's no-map region at the base, so the linear map can't take the first gigapage whole. So the choice costs nothing now and covers a larger memory later.

## 2. Access size and page crossings

- **The rule:** the lowest-numbered entry that matches any byte of an access decides, and it must match every byte, or the access fails. With no match, M is allowed and S/U are denied.
- **Homogeneous:** every entry covers either the whole page or none of it. Then every byte of the page matches the same set of entries, so the same lowest-numbered entry decides for any access inside the page. It covers the whole page, so it matches every byte of the access. The page's result is every access's result. A page that no entry matches caches "deny" (`rwx` = 000): an access fault with the access type's cause.
- **No access crosses a page:**
  - misaligned loads, stores and AMOs trap before PMP, so a data access is one naturally aligned unit of at most 8 bytes;
  - a fetch block is 16 bytes, aligned. A 32-bit instruction that straddles a page is two fetches, each checked with its own page's entry;
  - PTE reads are 8 bytes, aligned.
- **The per-page check** is exact. An entry breaks a page of size P only if:
  - it is NAPOT or NA4 and smaller than P, and lies inside the page. Being naturally aligned, it is either inside or disjoint;
  - or it is TOR, and one of its bounds, `top(i−1)` or `top(i)`, lies strictly inside the page.

  OFF entries and regions above the physical address space never do. Per entry this is a page-index compare and an alignment flag, which `tg_csr` already keeps per entry for 4K, 2M and 1G. It is today's 2M check (`pmp_p2m`), widened to 4K and 1G.

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
  - **Walks in flight:** the flush also ends the hart's walk in progress, so no fill computed from the old PMP lands after the write. Walks after the write start only once its descriptors are recomputed: fetch is held (`pmp_busy`) and the write retires alone. The walker must keep honouring that.
  - **Cost:** about nothing; the flush exists. Clearing only the PMP bits instead of whole entries would save refills on an event that happens a few times per boot: not worth the logic.

## 4. The second hart

- **Per-hart PMP:** each hart has its own PMP CSRs, and TLB entries carry their thread. The walker computes the cached result with the walking hart's descriptors, as it does today (`chk_tid`).
- **Flushes:** a PMP write flushes only its hart's entries. The other hart's cached results stay right, since its PMP didn't change.
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
- **Per entry:** a few hundred M-mode instructions, an estimate to be measured. So an idle or lightly loaded system runs at most about 40K M-mode instructions a second, well under 0.1% of a hart even if the slow path halved M-mode speed. A load that creates hundreds of processes a second (a build, a shell script) adds about 14 entries each, a few thousand a second: about 1% of a hart in M-mode, and a few tenths of a percent lost if the slow path costs M-mode code 10–30%.
- **PTE reads** take one slow check each (1–3 per walk). Steady-state S/U traffic leaves the checker free, so walks rarely wait for it.
- **Boot:**
  - **OpenSBI's cold boot** is about 4.5M cycles of M-mode. In `tb_boot` (2 × 1, the reference images) hart 0 leaves OpenSBI between 4M and 5M cycles, of about 335M to `TANAGER-BOOT-OK` (1 × 1). There every fetch block and data access goes through the one checker. If contention between fetch and the LSU costs M-mode code 10–30%, that is 0.1–0.4% of the boot.
  - **Warm starts** of the other harts are short.
  - **U-Boot** on the board runs in bare S-mode on the slow path. Its time goes mostly to SD and network DMA.
- **If boot time matters:** one "last page" entry per hart for M-mode and bare accesses would keep the common case off the shared checker. It would take the page's homogeneity from the same per-page logic, refill through the shared checker, and flush with the TLB on PMP writes.

## 6. Verification plan

- **Directed tests,** bare-metal, on the core in lockstep with Spike:
  1. **Sub-page regions:** an NA4 region and a TOR range inside one 4K page. S-mode accesses on both sides are right, that page doesn't cache, and a neighbouring page does.
  2. **Superpages:** a TOR bound strictly inside a 2M and inside a 1G leaf. No caching, and accesses on both sides are right.
  3. **Locked entries:** an L region that denies M. M-mode fetch, load and store fault. S-mode follows the region's RWX. Writes to the entry are ignored after the lock.
  4. **MPRV:** M-mode with `MPRV` = 1:
     - `MPP` = S and Sv39: loads and stores on allowed and denied pages through the cached result;
     - `MPP` = M: physical, with M's rules.
  5. **PMP writes with and without `SFENCE.VMA`:** S-mode caches a page as allowed, then M-mode denies it, with the fence and without. The next S-mode access faults either way, as in Spike.
  6. **Two harts:** hart 1 changes its PMP. Hart 1's entries are flushed, and hart 0's stay and stay right.
  7. **Page-table reads:** page tables in a region PMP denies to S give an access fault with the requester's cause.
  8. **No match:** S/U denied by default with entries implemented. The cached deny faults with the right cause per access type.
  9. **Bare S-mode accesses** on the slow path.
- **A simulation-only shadow checker:** every translated access through a cached result is also checked in full, and the two must agree (an assertion). This covers every program and the Linux boot at no area cost.
- **riscv-arch-test's** PMP and privilege suites, in lockstep.
- **Random programs** with PMP configurations and Sv39 in lockstep, once the generator has a PMP option.
- **The Linux boot** under lockstep (st and smt2, four harts), with the cycle cost on the boot by profile, as DR-141 has it.
- **Before the RTL:**
  - QEMU's counts (§5) are done. Still to do: instructions per SBI call and per M software interrupt, from a commit trace of the boot (`tb_boot +trace_out`; the records carry the privilege);
  - the same counts under Debian on the board's harts (RISC-V mode, four harts), where systemd's services add their own fences.
- **On the board:** memgap again (`wr1k`, `rdtime`, `clock`, `ev1` at least at d4r2 + PMP fix's figures, `fpga/kv260/board/d4r2`), and a RISC-V-mode Debian boot.
