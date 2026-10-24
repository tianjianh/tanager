# M6: the direction predictor (TAGE-lite at fetch), design note, 2026-10-17

*The core track's design note for M6's direction predictor, written while it was built (stage 1, 10-17), kept here as
the record core-pipeline.md §3 cites (it lived in the track's build tree until 10-24). What shipped differs in size:
DR-170 (10-18) took TAGE-lite with two tagged tables of 2K entries, not the four of 1K below, after DR-162's re-check;
core-pipeline.md §3 describes the predictor as built. The measurements are stage 1's, on the commits named.*

## Evidence (RTL, st, native latency, bench rv64im; private profiling bind on f34b08a, RAS on)

**Today:** a 64-entry micro-BTB is the only taken predictor, and every mispredict recovers at commit.

| | CoreMark A | CoreMark B | Dhrystone |
|---|---|---|---|
| cycles / instructions | 716.5K / 717K | 757K / 724K | 295K / 246K |
| conditional branches resolved (with wrong path) | 120.4K, 12.2% mispredicted | | 37.6K, 15.6% |
| ... taken, missed by the micro-BTB / micro-BTB hits not taken | 10.1K / 4.6K | | 5.3K / 0.57K |
| JALR mispredicted (with the RAS) | 419 of 7.2K | | 165 of 14.8K |
| commit-time mispredict flushes | 11.7K (16 per 1,000 instructions) | 12.1K | 4.6K (19 per 1,000) |
| resolved mispredicts waiting for commit | 48.8K cycles (6.8%) | 68.3K (9.0%) | 23.8K (8.1%) |
| ROB empty | 11.7% | 11.3% | 15.2% |

**Committed conditional branches through behavioural predictors** (mispredicts):

| predictor | CoreMark A (108.3K) | CoreMark B (113.3K) | Dhrystone (32.6K) |
|---|---|---|---|
| bimodal 4K | 10,204 | 8,903 | 2,316 |
| gshare 4K, 12-bit history | 7,228 | 7,951 | 1,087 |
| TAGE-lite, per branch (history per branch), 4 × 1K | 1,848 | 2,126 | 580 |
| TAGE-lite, per branch, 4 × 4K | 1,827 | 2,094 | 579 |
| block TAGE (a counter per slot, history one bit per block) | 4,032 | 4,191 | 666 |
| block TAGE (a counter per slot, history one bit per branch, shifted at the block's end) | 3,260 | 3,427 | 654 |
| block TAGE (two slot-tagged sub-entries per entry) | 3,062 | 3,290 | 609 |
| ... with the lookup one block behind in history | 3,424 | 3,240 | 621 |

- Tables of 4K entries gain nothing over 1K on these programs. Linux's code is far larger: start at 1K in BRAM, and size up later on the board's workloads.
- **Estimate:** about 13 cycles per mispredict (4 waiting for commit plus about 9 to refill). TAGE-lite takes out 8–9K mispredicts in CoreMark A, about 15% of its cycles, and Dhrystone similarly.

## Placement
- **At decode** (per-branch history, exact): best accuracy. But each disagreement with the micro-BTB is a decode redirect, which flushes the instruction queue: about 3–4 cycles, roughly 11K times in CoreMark A. BRAM tables also need the read a cycle ahead, before decode knows the group. LUTRAM tables avoid that, but cost about 1.5K LUTs per core at 4 × 1K.
- **At fetch (chosen):** the read in F1 on the block address, and the decision and override in F2. An override drops only the blocks behind F2, so the queue keeps feeding decode and the bubble is mostly hidden. The pipeline is clean: the F1 address is the block PC and the history register, with no path from F2's decision into it (the one-block lag measured above costs about 0.3K mispredicts). It is the plan's architecture (§4.2), and the FTQ it needs carries the block BTB and fetch-directed I$ prefetch later.

## Design (stage 1)
- **Tables.**
  - A base table: a 2-bit counter per slot, 2K blocks, 1 BRAM36.
  - T1..T4: 1K entries each, 1 BRAM36 each. An entry is two sub-entries {slot 3, tag 9, ctr 3, u 2}. A branch matches the sub-entry with its slot and the tag.
  - History lengths about 4/9/18/40 branch bits.
  - Total 5 BRAM36 per core. Port A predicts (read in F1); port B writes the training.
- **History.** One bit per conditional branch, in program order. At F2, each delivered block shifts in its conditional branches' predicted outcomes up to its exit.
  - A block holds at most two predicted conditional branches. F2 ends a block after its second, and the rest is fetched as the next block, so the shift is 0, 1 or 2 bits.
  - Folded copies per table (index and tags) are kept as registers.
  - **Exact recovery, as with the RAS:** commit keeps the same history by shifting in each committed conditional branch's outcome. A flush copies it, and the folded copies with it, into the speculative history.
- **F2 decision.**
  - For each conditional branch slot that pre-decode marks, from the entry's point: the provider (the longest matching table) or the base counter.
  - The block's exit is the first taken conditional branch, else the first unconditional jump (JAL from pre-decode; JALR from the micro-BTB). The target is PC + imm from the parcels; a JALR keeps the micro-BTB's target.
  - If this differs from what F1 followed (the micro-BTB's exit and target), F2 refetches: the existing override path, k_ovr_q generalized to a target.
- **FTQ.** 16 entries, LUTRAM, allocated per block delivered to F3. It holds:
  - each table's index and tag;
  - for each predicted slot, the provider and alternate, their read data and the prediction.
  
  Instructions carry their FTQ index through the queue, decode and rename into the ROB payload (+4 bits), plus a predicted-direction bit. Flushes reset the FTQ tail.
- **Training at commit**, per conditional branch from its FTQ entry:
  - update the provider's counter, and its useful bit when the provider and alternate disagree;
  - on a mispredict, allocate a sub-entry in a longer table with u = 0, else age;
  - reset u periodically;
  - port B writes back the entry from the FTQ's copy plus the update.
  - The micro-BTB keeps training at execute, as today.
- **Switch:** TG_TAGE (on). Off is today's front end, cycle for cycle.
- **Cost estimate:** 5 BRAM36 (the chip has about 29 spare); about 1–1.5K LUTs per core (FTQ, folds, compares, F2 logic, training).

## Later
- A block BTB (BRAM): the micro-BTB's capacity, and JALR targets.
- Checkpoint recovery: the 4-cycle commit wait, 7–9% of cycles today, smaller after TAGE.
- Fetch-directed I$ prefetch from the FTQ.

## Built: c48b1ce (branch claude/track-core-adb715-tage, on the RAS f34b08a), 10-17 15:10
- As designed above, with history at most two bits per block (a cut before the third conditional branch).
- **st, rv64im, native, timed regions:** CoreMark A 3.090 → 3.705 CM/MHz, B 2.900 → 3.503, Dhrystone 2.046 → 2.336 DMIPS/MHz (against the RAS). Against main: +22%, +22%, +40%.
- **Profile, CoreMark A:**
  - commit-time mispredict flushes 11.7K → 3.5K, as the behavioural model said;
  - the commit wait 48.8K → 16.2K cycles (2.7%);
  - decode redirects 4.1K → 1.4K;
  - F2 overrides 15.5K and cuts 3.8K, in 299K blocks; the FTQ never full.
- **Profile, Dhrystone:** flushes 4.6K → 0.8K; overrides 12.0K; cuts 2.0K; decode redirects 9.9K → 4.2K (mostly the RAS).
- **Bug found by regress (trace stall):** the branch cut was not gated by a hit. A block that missed in the I$ raised a cut from its stale parcels, and the refetch after the line arrived took it, skipping three instructions. Fixed before the commit: the cut is gated like the PMP cut.

## Tuning items, for the final pass (DR-155)
- **F2 overrides** (15.5K in CoreMark A). The micro-BTB is trained at execute with the old BHT's direction, so it often disagrees with TAGE. Lever: train it from F2's decision (write TAGE's taken exit, invalidate on not taken).
- **History bits per block:** four instead of two (cut before the fifth branch), measured on wt-tage2: CoreMark A +0.9% cycles, B −0.04%, Dhrystone 0%, CoreMark A rv64gcb −0.16%, Dhrystone rv64gcb −2.1%. A wash; kept at two.
- **Table sizes:** 1K tagged entries match 4K on the bench; Linux's code needs measuring on the board.
- **The useful bits are never reset periodically** (only aged on a failed allocation).
- **F2 overrides by kind** (c48b1ce, st, native):

  | | missed a taken exit | hit, TAGE not taken | hit at another slot |
  |---|---|---|---|
  | CoreMark A | 8,962 | 2,908 | 3,681 |
  | Dhrystone | 8,069 | 856 | 3,031 |

- **A larger micro-BTB** (scratch, UBTB_ENTRIES 64 → 128 / 256; timed-region cycles):
  - CoreMark A 539,748 → 538,678 / 537,598 (−0.2% / −0.4%);
  - CoreMark B 570,967 → 571,226 / 570,873 (0%);
  - Dhrystone 121,822 → 118,802 / 118,559 (−2.5% / −2.7%).
  
  Overrides fall only 8–30%, so on these programs zero-bubble capacity is a small lever. The queue hides most of an override's bubble.
