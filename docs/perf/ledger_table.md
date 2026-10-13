| Feature | Contribution @30 | @120 | @250 | Est. LUTs | LUT share | Gain / cost @120 | Rule verdict |
|---|---|---|---|---|---|---|---|
| TAGE-lite -> 4 KB gshare | +5.91% | +5.82% | +5.79% | 800 (core) | 1.95% | 3.0x | pass |
| micro-BTB off | +7.60% | +7.54% | +7.50% | 700 (core) | 1.71% | 4.4x | pass |
| checkpoints off (recover at commit) | +0.98% | +0.90% | +0.86% | 1000 (core) | 2.44% | 0.4x | below the line |
| SFB predication off | +0.17% | +0.17% | +0.17% | 500 (core) | 1.22% | 0.1x | below the line |
| jump folding off | +0.01% | +0.01% | +0.01% | 100 (core) | 0.24% | 0.0x | below the line |
| fusion off | +0.31% | +0.14% | +0.09% | 400 (core) | 0.98% | 0.1x | below the line |
| speculative load wakeup off | +3.04% | +2.99% | +2.97% | 500 (core) | 1.22% | 2.5x | pass |
| early retirement off | +1.64% | +2.39% | +2.33% | 900 (core) | 2.20% | 1.1x | pass |
| memory-dependence wait table off | +0.02% | +0.02% | +0.02% | 100 (core) | 0.24% | 0.1x | below the line |
| branch-first select off | -0.02% | -0.03% | -0.03% | 50 (core) | 0.12% | -0.2x | below the line |
| ownership prefetch off | +1.89% | +1.59% | +0.34% | 100 (core) | 0.24% | 6.5x | pass |
| L1D stride prefetcher off | +0.99% | +0.96% | +0.92% | 300 (core) | 0.73% | 1.3x | pass |
| L2 stream prefetcher off | +2.33% | +6.59% | +8.55% | 400 (SoC) | 0.43% | 15.5x | pass |
| I-side prefetch off (FDIP + next line) | +0.01% | +0.03% | +0.05% | 200 (core) | 0.49% | 0.1x | below the line |
| L1D MSHRs 12 -> 8 | +1.12% | +2.04% | +2.15% | 300 (core) | 0.73% | 2.8x | pass |
| L1s 32 KiB -> 16 KiB | +0.90% | +0.85% | +0.79% | 200 (core) | 0.49% | 1.7x | pass |
| L2 1 MiB -> 512 KiB | +0.03% | +0.10% | +0.12% | 200 (SoC) | 0.21% | 0.5x | below the line |
| +ALU+branch fusion | +0.03% | +0.04% | +0.04% | 300 (core) | 0.73% | 0.0x | reject |
| +micro-BTB 64 entries | +1.99% | +1.99% | +1.99% | 100 (core) | 0.24% | 8.2x | adopt |
| +second load pipe | +0.53% | +0.40% | +0.38% | 1500 (core) | 3.66% | 0.1x | reject |
| +radix-16 FP divide/sqrt | +1.67% | +1.67% | +1.67% | 1200 (core) | 2.93% | 0.6x | reject |
| +Goldschmidt divide/sqrt, 10-bit seed | +2.23% | +2.23% | +2.23% | 200 (core) | 0.49% | 4.6x | adopt |
| +Goldschmidt divide/sqrt, 14-bit seed | +2.35% | +2.35% | +2.35% | 300 (core) | 0.73% | 3.2x | adopt |
| +second FMA pipe | +0.08% | +0.08% | +0.08% | 4400 (core) | 10.73% | 0.0x | reject |

| Feature | What the LUT estimate covers | BRAM / URAM | Timing exposure | Verification surface |
|---|---|---|---|---|
| TAGE-lite -> 4 KB gshare | hashing and tag compare for 4 tables, update logic; storage in BRAM | +1 to 3 BRAM36 | none (overrides the micro-BTB a stage later) | low: prediction only |
| micro-BTB off | 32-entry fully associative flip-flop CAM and target mux | none | is the next-PC loop | low: prediction only |
| checkpoints off (recover at commit) | 8 LUTRAM rename snapshots, restore mux, free-list heads | none | rename restore select | high: recovery |
| SFB predication off | decode conversion, 3-operand select, candidate table | none | third operand on P0; select on the ALU0 bypass | medium: retire count, debug rules |
| jump folding off | decode skip and retire-count credit | none | none | medium: retire count |
| fusion off | pair detection and merged uop formation | none | decode only | medium: faulting second half re-executes unfused |
| speculative load wakeup off | hit predictor, shadow cancel, row hold | none | wakeup-select loop: shadow cancel | high: cancel and replay |
| early retirement off | long-latency tag columns, completion buffer, deferred free | none | LLT columns in the wakeup matrix | high: precise state, ordering, writeback records |
| memory-dependence wait table off | 1K-bit table (LUTRAM) and check | none | none | low |
| branch-first select off | priority term in IQ-A0 select | none | IQ-A0 select priority term | low |
| ownership prefetch off | request on store-address resolution | none | none | low-medium: coherence requests |
| L1D stride prefetcher off | 16-entry PC-stride table | none | none | low |
| L2 stream prefetcher off | 8-stream table in the L2 | none | none | low |
| I-side prefetch off (FDIP + next line) | FTQ-directed request and second I$ MSHR | none | none | low |
| L1D MSHRs 12 -> 8 | 4 MSHRs with fill buffers | none | MSHR CAM on the miss path | medium |
| L1s 32 KiB -> 16 KiB | tags/LRU; data is BRAM (+12 BRAM36) | +12 BRAM36 per core | 8-way way select on the load-to-use path | low |
| L2 1 MiB -> 512 KiB | tags; data is UltraRAM (+16 URAM) | +16 URAM | none | low |
| +ALU+branch fusion | extra pair patterns, branch uop with a destination | none | branch unit gains an ALU result write | medium |
| +micro-BTB 64 entries | 64 x 2-way LUTRAM instead of 32 flip-flop entries | none | next-PC loop through LUTRAM (the plan's fallback) | low |
| +second load pipe | second AGU/DTLB port, LQ search port, D$ read port (+8 BRAM36) | +8 BRAM36 per core | second AGU, DTLB port and LQ search port | high: two-load ordering |
| +radix-16 FP divide/sqrt | two overlapped radix-4 stages per cycle instead of one (divide and square root share the unit) | none | longer quotient-digit selection path in the iterative unit | medium: TestFloat |
| +Goldschmidt divide/sqrt, 10-bit seed | net of the radix-4 unit it replaces: operand muxes, 2 - D, partial-product sums, remainder correction, sequencing; the multipliers are DSPs | +1 BRAM18, +24 DSP48E2 | DSP cascades (registered, 4 stages) | medium-high: correct rounding needs the remainder step; TestFloat |
| +Goldschmidt divide/sqrt, 14-bit seed | as the 10-bit seed, plus bipartite seed-table logic | +2-4 BRAM36, +24 DSP48E2 | as 10-bit seed | medium-high: as 10-bit seed |
| +second FMA pipe | second FMA datapath (~2.5K), third FP bank and 7 read ports per bank (~1.3K), FP bypass and second issue port (~0.6K) | +12 DSP48E2 | FP bypass network grows; FP register read ports 4 -> 7 | medium: TestFloat per pipe, issue/writeback arbitration |

### Size steps (each step judged against the next smaller size)

| Parameter | Step | Gain @30 | Gain @120 | Gain @250 | Est. LUT change | LUT share | Rule verdict |
|---|---|---|---|---|---|---|---|
| rob | 48 -> 64 | +1.11% | +0.93% | +0.86% | +480 (core) | 1.17% | below the line |
| rob | 64 -> 80 | +0.14% | +0.31% | +0.12% | +480 (core) | 1.17% | below the line |
| rob | 80 -> 96 | +0.01% | +0.05% | +0.05% | +480 (core) | 1.17% | below the line |
| rob | 96 -> 128 | +0.00% | +0.01% | +0.02% | +960 (core) | 2.34% | below the line |
| iq | 6 -> 8 | +1.48% | +1.71% | +1.83% | +720 (core) | 1.76% | below the line |
| iq | 8 -> 10 | +1.16% | +1.35% | +1.36% | +720 (core) | 1.76% | below the line |
| iq | 10 -> 12 | +0.63% | +0.47% | +0.40% | +800 (core) | 1.95% | below the line |
| iq | 12 -> 16 | +1.00% | +1.19% | +1.25% | +1440 (core) | 3.51% | below the line |
| lq | 12 -> 16 | +1.14% | +0.92% | +0.86% | +160 (core) | 0.39% | pass |
| lq | 16 -> 24 | +0.82% | +0.94% | +0.99% | +320 (core) | 0.78% | pass |
| lq | 24 -> 32 | +0.01% | +0.01% | +0.01% | +320 (core) | 0.78% | below the line |
| sq | 12 -> 16 | +0.65% | +0.37% | +0.28% | +200 (core) | 0.49% | below the line |
| sq | 16 -> 24 | +0.03% | +0.03% | +0.12% | +400 (core) | 0.98% | below the line |
| lqcb | 0 -> 8 | +1.61% | +2.36% | +2.29% | +64 (core) | 0.16% | pass |
| lqcb | 8 -> 16 | -0.00% | +0.00% | +0.00% | +64 (core) | 0.16% | below the line |
| lqcb | 16 -> 24 | +0.00% | +0.00% | +0.00% | +64 (core) | 0.16% | below the line |
| l1d_mshr | 4 -> 8 | +8.51% | +10.77% | +10.98% | +300 (core) | 0.73% | pass |
| l1d_mshr | 8 -> 12 | +1.12% | +2.04% | +2.15% | +300 (core) | 0.73% | pass |
| l1d_mshr | 12 -> 16 | +0.54% | +1.23% | +1.38% | +300 (core) | 0.73% | pass |
| l1d_mshr | 16 -> 20 | -0.00% | +0.46% | +0.34% | +300 (core) | 0.73% | below the line |
| l1d_mshr | 20 -> 24 | +0.00% | +0.00% | +0.00% | +300 (core) | 0.73% | below the line |
| l2_mshr | 16 -> 32 | -0.00% | +2.73% | +4.28% | +800 (SoC) | 0.85% | pass |
| l2_mshr | 32 -> 48 | +0.00% | +0.00% | +0.00% | +800 (SoC) | 0.85% | below the line |
| l1i_mshr | 1 -> 2 | +0.01% | +0.03% | +0.05% | +60 (core) | 0.15% | below the line |
| l1i_mshr | 2 -> 4 | +0.00% | +0.01% | +0.02% | +120 (core) | 0.29% | below the line |
| ubtb | 0 -> 16 | +6.56% | +6.50% | +6.46% | +350 (core) | 0.85% | pass |
| ubtb | 16 -> 32 | +0.98% | +0.98% | +0.98% | +350 (core) | 0.85% | pass |
| ubtb | 32 -> 64 | +1.99% | +1.99% | +1.99% | +100 (core) | 0.24% | pass |
| ubtb | 64 -> 128 | +0.06% | +0.06% | +0.06% | +60 (core) | 0.15% | below the line |
| llt | 16 -> 24 | +0.03% | +0.00% | +0.02% | +200 (core) | 0.49% | below the line |
| llt | 24 -> 32 | +0.00% | +0.00% | +0.00% | +200 (core) | 0.49% | below the line |
| llt | 32 -> 48 | +0.00% | +0.00% | +0.00% | +400 (core) | 0.98% | below the line |
| tage_log | 9 -> 10 | +0.55% | +0.55% | +0.55% | +30 (core) | 0.07% | pass |
| tage_log | 10 -> 11 | +0.46% | +0.45% | +0.45% | +30 (core) | 0.07% | pass |
| tage_log | 11 -> 12 | +0.22% | +0.22% | +0.22% | +30 (core) | 0.07% | pass |
| ckpt | 0 -> 4 | +0.91% | +0.84% | +0.80% | +500 (core) | 1.22% | below the line |
| ckpt | 4 -> 8 | +0.07% | +0.06% | +0.05% | +500 (core) | 1.22% | below the line |
| ckpt | 8 -> 12 | +0.01% | +0.00% | +0.00% | +500 (core) | 1.22% | below the line |
| pf_stride_dist | 2 -> 4 | -0.09% | +0.02% | +0.03% | +0 (core) | 0.00% | free, no effect |
| pf_stride_dist | 4 -> 8 | -0.34% | -0.05% | -0.07% | +0 (core) | 0.00% | free, no effect |
| pf_stride_dist | 8 -> 16 | +0.29% | +0.01% | +0.02% | +0 (core) | 0.00% | free, no effect |
| pf_stride_dist | 16 -> 32 | -0.26% | -0.05% | -0.03% | +0 (core) | 0.00% | free: take the better |
| pf_stream_dist | 4 -> 8 | -0.00% | +1.28% | +1.33% | +0 (SoC) | 0.00% | free: take the better |
| pf_stream_dist | 8 -> 16 | -0.00% | +0.28% | -0.89% | +0 (SoC) | 0.00% | free: take the better |
| lat_fma | 4 -> 5 | -0.24% | -0.21% | -0.20% | +0 (core) | 0.00% | timing trade-off, not judged on LUTs |
| lat_fma | 5 -> 6 | -0.25% | -0.22% | -0.21% | +0 (core) | 0.00% | timing trade-off, not judged on LUTs |

Size cost bases:

- **rob** (core): about 30 LUTs/entry: ROB LUTRAM and completion bits, plus one dependency column in every issue-queue row (registers held at 3 x 64)
- **iq** (core): about 80 LUTs/entry (plan section 8.2: 4.6K for 56 entries); A0, A1, LD and FP change by v, STA by 2v/3
- **lq** (core): about 40 LUTs per CAM entry
- **sq** (core): about 50 LUTs per entry (CAM, forwarding select, data in LUTRAM)
- **lqcb** (core): about 8 LUTs per completion-buffer entry (LUTRAM, no CAM)
- **l1d_mshr** (core): about 75 LUTs per MSHR with its fill buffer in LUTRAM
- **l2_mshr** (SoC): about 50 LUTs per L2 MSHR
- **l1i_mshr** (core): about 60 LUTs per L1I MSHR with its line buffer
- **ubtb** (core): 16 and 32 entries: fully associative flip-flops (about 22 LUTs/entry); 64 and 128: 2-way LUTRAM
- **llt** (core): about 25 LUTs per tag: one dependency column in every issue-queue row
- **tage_log** (core): LUTs nearly flat; the four tagged tables are BRAM: about 2, 2, 4 and 8 BRAM36 at log2 sizes 9, 10, 11 and 12
- **ckpt** (core): about 125 LUTs per checkpoint (LUTRAM snapshot and restore select)
- **pf_stride_dist** (core): run-time register (plan section 4.11)
- **pf_stream_dist** (SoC): run-time register
- **lat_fma** (core): FMA pipeline depth: the cost is timing (DSP48E2 cascade at 200 MHz), not LUTs; the plan allows 4-5 cycles
