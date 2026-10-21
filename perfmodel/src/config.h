// tgsim: model parameters. Every knob is listed once in TG_PARAMS; presets set groups of them and
// --set name=value overrides any of them.
#pragma once
#include <cstdint>
#include <string>

namespace tg {

// X(name, default, description). Defaults are Tanager v1 (plan draft 0.3, section 4.14). With threads = 2,
// sizes are per core: the ROB, LQ, SQ and completion buffer are split between the threads (smt_part).
#define TG_PARAMS(X)                                                                               \
  /* front end */                                                                                  \
  X(fetch_bytes, 16, "fetch block size in bytes")                                                  \
  X(fetchq, 16, "instruction queue entries between fetch and decode")                              \
  X(if_stages, 3, "cycles from fetch (IF1) to decode")                                             \
  X(decode_width, 2, "instructions decoded per cycle (decode slots)")                              \
  X(dec_to_disp, 2, "cycles from decode to dispatch (rename + dispatch stages)")                   \
  X(ubtb, 32, "micro-BTB entries (0 = none)")                                                      \
  X(fe_m2, 0, "the M2 RTL's front end: the micro-BTB (ubtb entries, ubtb_ways) is the only predictor; no RAS; decode repairs JAL and predicted-taken targets (predecode_bubble)") \
  X(ubtb_ways, 2, "micro-BTB ways with fe_m2")                                                     \
  X(m2_ctr, 512, "2-bit counters (PC[10:2]) that gate the micro-BTB's training with fe_m2")       \
  X(m2_wp_train, 0, "fe_m2: extra not-taken trainings of a loop branch mispredicted at its exit (the RTL's wrong path)") \
  X(m2_dir, 0, "fe_m2: the direction predictor (dirpred) decides branches; decode supplies missing targets")   \
  X(m2_f2, 0, "fe_m2: direct targets and direction overrides come from F2's pre-decode (core-2's TAGE front end), not decode") \
  X(m2_f2_bubble, 1, "fe_m2 with m2_f2: fetch bubble of an F2 redirect (cycles)")                    \
  X(m2_ras_f2, 0, "fe_m2 with m2_f2 and ras: returns are repaired from the RAS at F2 (pre-decode), not at decode") \
  X(m2_btage, 0, "fe_m2 with m2_dir: core-2's TAGE as built (tg_tage.sv): one read per 16-byte block, slot-tagged sub-entries, conditional-branch history; 0 = the model's per-branch TAGE (dirpred)") \
  X(btage_li, 10, "m2_btage: tagged tables' index bits (two sub-entries per entry)")             \
  X(btage_bi, 11, "m2_btage: base table's index bits (blocks; a 2-bit counter per slot)")         \
  X(btage_tw, 9, "m2_btage: tag bits")                                                             \
  X(btage_nt, 4, "m2_btage: tagged tables, 1-4 (histories 12; 8/32; 5/14/40; 4/9/18/40, as core-2's size study)") \
  X(btage_lag, 1, "m2_btage: a block read right behind another lacks that block's history bits (F1 reads as F2 delivers)") \
  X(btage_tq, 4, "m2_btage: training queue entries, one request every two cycles, a full queue drops; 0 = train at commit at once") \
  X(btage_alloc, 0, "m2_btage: 0 = allocate the first way that is invalid or not useful, as tg_tage did before c1c21281; 1 = within a table, an invalid way before a not-useful one, as tg_tage does since (rtl_m2 from revision 9)") \
  X(m2_cut, 0, "fe_m2 with m2_f2: a block ends before its third conditional branch, refetched at m2_f2_bubble") \
  X(m2_ftq, 0, "fe_m2: FTQ entries (core-2's TAGE front end): a block holds one from fetch until an instruction of a later block commits; fetch waits while none is free (0 = no FTQ)") \
  X(m2_strad, 0, "fe_m2: a 32-bit instruction that straddles into the next block, reached in sequence, is decoded with that block (F2 holds its first half): no block of its own, the next block's TAGE read at slot 0, one of its branches; the micro-BTB never predicts or trains a straddler (the RTL as built)") \
  X(m2_ub_way, 0, "fe_m2: training writes the micro-BTB way that predicted this instruction, else a pseudo-random way (the RTL as built); 0 = the way that hit the block") \
  X(btb_block, 1, "1 = block BTB with slots, 0 = per-instruction BTB")                             \
  X(btb_sets, 256, "BTB sets")                                                                     \
  X(btb_ways, 4, "BTB ways")                                                                       \
  X(btb_slots, 2, "branch slots per block BTB entry")                                              \
  X(taken_bubble, 2, "bubble for a taken branch predicted by the main BTB (micro-BTB miss)")       \
  X(predecode_bubble, 3, "bubble for an early redirect at pre-decode (BTB miss on a jump)")         \
  X(dirpred, 2, "direction predictor: 0 bimodal, 1 gshare, 2 TAGE-lite")                          \
  X(gshare_log, 14, "gshare log2(entries)")                                                        \
  X(gshare_hist, 14, "gshare history bits")                                                        \
  X(tage_base_log, 12, "TAGE base bimodal log2(entries)")                                          \
  X(tage_tables, 4, "TAGE tagged tables")                                                          \
  X(tage_log, 10, "TAGE tagged table log2(entries)")                                               \
  X(tage_tag, 9, "TAGE tag bits")                                                                  \
  X(tage_hmin, 8, "TAGE shortest history")                                                         \
  X(tage_hmax, 64, "TAGE longest history (<= 128)")                                                \
  X(ras, 32, "return address stack entries")                                                       \
  X(ras_at_decode, 0, "returns use the BTB target at fetch; the RAS corrects at decode (NaxRiscv)") \
  X(ret_btb, 0, "with ras = 0: returns are predicted by the BTB's stored target (0 = every return mispredicts)") \
  X(fdip, 1, "fetch-directed I-cache prefetch")                                                    \
  X(ftq, 32, "fetch target queue blocks (FDIP lookahead)")                                         \
  X(fusion, 1, "macro-op fusion")                                                                  \
  X(fuse_alubr, 0, "also fuse addi/addiw/andi + a dependent conditional branch (resolves 1 cycle later)") \
  X(fuse_1slot, 0, "a fused pair takes one decode slot (pairs found in pre-decode; DSE option)")    \
  X(sfb, 1, "short-forward-branch predication")                                                    \
  X(sfb_entries, 64, "SFB candidate table entries")                                                \
  X(sfb_thresh, 2, "mispredicts before a short forward branch is predicated")                      \
  X(fold, 1, "jump folding")                                                                       \
  /* back end */                                                                                   \
  X(rob, 64, "reorder buffer entries")                                                             \
  X(commit_width, 2, "micro-ops retired per cycle")                                                \
  X(iq_unified, 0, "1 = one unified issue queue (NaxRiscv-like), 0 = distributed")                 \
  X(iq_a0, 12, "IQ-A0 entries (ALU, branches)")                                                    \
  X(iq_a1, 12, "IQ-A1 entries (ALU, MUL, DIV)")                                                    \
  X(iq_ld, 12, "IQ-LD entries")                                                                    \
  X(iq_sta, 8, "IQ-STA entries")                                                                   \
  X(iq_hold, 0, "cycles from a uop's issue until dispatch can reuse its IQ row (0 = at once; core-2's RTL: 3, the row is freed two cycles after its select)") \
  X(iq_slot_bank, 0, "IQ rows are banks by dispatch slot (plan §4.15; core-2's RTL): decode slot k's uop takes a row of bank k, and a group waits until each slot's bank has one") \
  X(iq_steer_rn, 0, "with iq_slot_bank: an ALU op's queue is picked a cycle before dispatch, as rename does in the RTL, from the banks' free flags of the cycle before that (which miss the group dispatch writes meanwhile): slot k's op takes queue k mod 2 if its bank had a row, else the other if it had one, else k mod 2, and keeps it; 0 = picked at dispatch with the current rows; 2 = picked at rename from flags that count the group the dispatch stage writes in the same cycle (a fix)") \
  X(iq_fp, 12, "IQ-FP entries")                                                                    \
  X(alu3, 0, "third simple-ALU port P5 with its own queue and register bank (DSE option)")         \
  X(iq_a2, 0, "IQ-A2 entries with alu3 (0 = same as IQ-A1)")                                       \
  X(fp_ports, 1, "FP issue ports / FMA pipes fed by IQ-FP (divide/sqrt stays one iterative unit)") \
  X(iq_size, 32, "unified IQ entries (iq_unified=1)")                                              \
  X(iq_rows, 0, "unified IQ allocates whole rows of decode_width and never compacts")             \
  X(prf_banked, 1, "1 = writer-sharded banks, 0 = one shared pool")                                \
  X(bank_size, 64, "registers per bank (prf_banked=1)")                                            \
  X(prf_int, 64, "integer registers in the shared pool (prf_banked=0)")                            \
  X(prf_fp, 64, "FP registers in the shared pool (prf_banked=0)")                                  \
  X(ckpt, 8, "rename checkpoints (0 = all branch recovery at commit)")                             \
  X(llt, 32, "long-latency tags")                                                                  \
  X(br_first, 1, "ready branches first in IQ-A0 select")                                           \
  X(spec_wakeup, 1, "speculative load wakeup (assume hit)")                                        \
  X(hit_pred, 1, "per-PC load hit predictor gates speculative wakeup")                             \
  X(shadow, 2, "load shadow cycles cancelled on a wrong hit guess")                                \
  X(hitmiss_flush, 0, "a wrong hit guess flushes the pipeline (NaxRiscv)")                         \
  X(spec_int_only, 0, "speculative wakeup for integer loads only; FP loads wake on the confirmed result (the RTL)") \
  X(spec_filter, 0, "with spec_wakeup: the RTL's filter C (tg_issue): rtl_m2 from revision 10. a 2-bit count per hash of an integer load's PC (32; PC bits 5:1 ^ 10:6 ^ 15:11), +1 when the load fails to complete in M2 (a miss, a store-data wait, a row clash, no miss entry), -1 when it completes there; from 2 its dependants wait for its result and it cancels nothing") \
  X(spec_fwd,0, "with spec_wakeup, a store-to-load forward completing at M2 wakes dependants as a hit does (load-to-use 3)") \
  X(fwd_wait_cancel, 0, "with spec_wakeup: a load that finds an older store's address without its data, or not covering it, cancels the shadow as a miss does (the RTL's STQ verdict at M2)") \
  X(dc_row_clash, 0, "a load whose AG (D$ row read) meets a store draining into the same row (VA[11:4]) retries (the RTL's D$)") \
  X(clash_delay, 4, "dc_row_clash: cycles a clashing load's result is delayed (its replay from the LQ)") \
  X(clash_rearm, 0, "dc_row_clash: the retry reads the row again at its own AG, so a store draining then makes it retry again") \
  X(redirect_lat, 1, "cycles from branch resolution (end of EX) to the redirected IF1")            \
  X(commit_redirect, 1, "cycles from commit of a mispredicted branch to IF1 (no checkpoint)")      \
  X(lat_mul, 3, "multiply latency")                                                                \
  X(div_base, 4, "divide latency = div_base + significant bits / div_bits_per_cycle")              \
  X(div_bits_per_cycle, 2, "divider radix bits per cycle")                                         \
  X(lat_fma, 5, "FP add/mul/FMA latency")                                                          \
  X(lat_fmisc, 2, "FP sign/min/max/convert latency")                                               \
  X(lat_fdiv_s, 17, "FDIV.S latency (unpipelined; plan 4.12 radix-4 digit recurrence: 14 steps + 3)") \
  X(lat_fdiv_d, 31, "FDIV.D latency (unpipelined; radix-4: 28 steps + 3)")                         \
  X(lat_fsqrt_s, 17, "FSQRT.S latency (unpipelined; radix-4)")                                     \
  X(lat_fsqrt_d, 31, "FSQRT.D latency (unpipelined; radix-4)")                                     \
  X(fdiv_ii, 0, "cycles between FP divide/sqrt starts; 0 = unpipelined (busy for the full latency)") \
  X(lat_serial, 3, "CSR / system op latency at the ROB head")                                      \
  X(lat_mmio, 12, "uncached MMIO access latency at the ROB head")                                  \
  /* load / store */                                                                               \
  X(lq, 16, "load queue (CAM) entries")                                                            \
  X(lqcb, 16, "retired-load completion buffer entries")                                            \
  X(sq, 16, "store queue entries")                                                                 \
  X(early_retire, 1, "early retirement of loads and long operations")                             \
  X(mdp, 1, "memory dependence prediction (wait table)")                                           \
  X(mdp_entries, 1024, "wait table entries")                                                       \
  X(mdp_clear, 65536, "wait table clear interval (cycles)")                                        \
  X(fwd_strict, 0, "forward only from a store of the same address and size")                      \
  X(ld_fwd_lat, 3, "load-to-use of a load forwarded from an older store whose data is ready")    \
  X(ld_fwd_wait, 3, "cycles from an older store's data to the result of a load waiting to forward it") \
  X(sta_split, 1, "store address issues alone; data captured in the SQ")                           \
  X(rfo_pf, 1, "request ownership when a store address resolves")                                 \
  X(rfo_pf_reserve, 2, "L1D miss entries an ownership prefetch must leave free (the RTL: 1, DR-171)") \
  X(rfo_pf_max, 0, "ownership prefetches in flight at most (0 = no cap; the RTL's STORE_PF_MAX is 3)") \
  X(ld_ports, 1, "load pipes")                                                                     \
  /* caches and memory */                                                                          \
  X(l1i_kb, 32, "L1I size KiB")                                                                    \
  X(l1i_ways, 8, "L1I ways")                                                                       \
  X(l1i_mshr, 2, "L1I MSHRs")                                                                      \
  X(l1d_kb, 32, "L1D size KiB")                                                                    \
  X(l1d_ways, 8, "L1D ways")                                                                       \
  X(l1d_mshr, 12, "L1D MSHRs")                                                                     \
  X(l2_kb, 1024, "L2 size KiB (0 = none)")                                                         \
  X(l2_ways, 8, "L2 ways")                                                                         \
  X(l2_lat, 12, "L1 miss to data, L2 hit (cycles)")                                                \
  X(l2_mshr, 32, "L2 MSHRs (both banks)")                                                          \
  X(dram_lat, 120, "DRAM round trip seen from the L2 (cycles)")                                    \
  X(dram_line_cyc, 4, "DRAM cycles per 64-byte line (bandwidth)")                                  \
  X(l1_fill_extra, 0, "cycles added to every L1 refill (the RTL's request, beats, install and replay)") \
  X(pf_stride, 1, "L1D PC-stride prefetcher")                                                      \
  X(pf_stride_entries, 16, "stride table entries")                                                 \
  X(pf_stride_dist, 4, "stride prefetch distance (strides ahead)")                                 \
  X(pf_stream, 1, "L2 stream prefetcher")                                                          \
  X(pf_stream_dist, 8, "stream prefetch distance (lines ahead)")                                   \
  X(pf_stream_deg, 2, "stream prefetch degree (lines per trigger)")                                \
  X(pf_i_nextline, 1, "L1I next-line prefetch")                                                    \
  X(max_cycles, 0, "stop after this many cycles (0 = no limit)")                                  \
  X(ff, 0, "fast-forward functionally to the region start marker (caches and predictors cold)")  \
  X(whole_run, 0, "ignore the region markers: the region's counters cover the whole run (as an RTL profile does)") \
  /* multithreading (plan section 6); ignored when threads = 1 */                                  \
  X(threads, 1, "hardware threads: 1, or 2 (SMT2: two programs share the core)")                   \
  X(smt_fetch, 0, "front-end thread priority: 0 ICOUNT (fewest uops in the fetch queue, decode, rename and the issue queues), 1 round robin, 2 ICOUNT on the issue-queue rows each thread holds, a cycle late (tg_issue's export), 3 as 0 a cycle late") \
  X(smt_fetch_hold, 0, "two threads: one fetch pipe as the RTL's (tg_fetch with hart 1): the threads take turns at fetch, and a block whose thread's instruction queue is full holds the pipe, and the other thread's fetch, until there is room (smt_fetch is then unused)") \
  X(smt_dec_rr, 0, "two threads, one thread a group: decode reads one thread a cycle, chosen the cycle before as the RTL's (tg_fetch_compact's rt_q): the other thread when its queue holds instructions and rename can take its group, after a take from this one or when this one has nothing to give or rename can't take its group (0: the first thread that can decode, the first alternating)") \
  X(smt_part, 1, "ROB/LQ/SQ/completion buffer: 1 static per-thread halves, 0 shared with smt_win_cap") \
  X(smt_win_cap, 75, "shared ROB/LQ/SQ/completion buffer (smt_part=0): percent one thread may hold") \
  X(smt_iq_cap, 75, "percent of each issue queue one thread may hold")                             \
  X(smt_mshr_cap, 100, "percent of the L1D MSHRs one thread may hold")                             \
  X(smt_llt_cap, 100, "percent of the long-latency tags one thread may hold")                      \
  X(smt_bp_hash, 1, "hash the thread ID into shared predictor tables (0 = threads share entries by PC)") \
  X(smt_mix, 1, "decode, rename and commit slots one thread leaves unused go to the other thread") \
  X(smt_rn_one, 0, "two threads, one thread a group: one rename register, as the RTL's RN stage. A thread whose group stalls there (its ROB, LQ or SQ half, registers, issue rows) keeps RN until the group moves, and the sibling's group waits in decode") \
  X(smt_rn_room, 0, "with smt_rn_one: decode hands RN a thread's group only when that thread's room flags of the cycle before say the group fits, otherwise it serves the other thread: 1 = its ROB, LQ and SQ halves and its free registers; 2 = also a row in each of its uops' issue queues (the slot's bank); 3 = as 2 with this cycle's flags (no lag)") \
  X(smt_commit_rr, 0, "two threads, one thread a group: the commit thread is chosen a cycle ahead and commits what it can, possibly nothing; 2 = as the RTL's ROB (tg_rob's ct_n): the other thread whenever its ROB holds entries; 3 = a thread whose head is complete, the other first, else as 2; 4 = core-2's fix: the turn stays while the other thread's head isn't actionable, and passes when it is, when this thread committed nothing, or after 4 turns in a row; 1 = as 2 with a thread's decoded uops not yet dispatched counted as entries (§13.14's form); 0: the first thread whose head can commit, the first alternating") \
  /* M7 (docs/spec/m7-smt2-plan.md); off by default */                                              \
  X(smt_drain_rr, 1, "two threads: the thread whose committed SQ head the D$ store port tries first alternates every cycle (D8; 0 = thread 0 always first)") \
  X(smt_iq_cap_bank, 0, "two threads, iq_slot_bank: the issue-queue cap holds in each dispatch-slot bank of rows too, a thread taking at most smt_iq_cap% of a bank's rows (rounded up) and never all of them, so its sibling finds a row in either bank; 2 = only never all of a bank's rows; 3 = not the bank's last row while the sibling waits on that bank; 4 = not a bank's last free row while the sibling's waiting group needs a row there, every bank that group needs (fpu-2's R2); 5 = not a bank's last free row while the sibling waits on that bank; 6 = as 3, every bank the sibling's waiting group needs") \
  X(prf_split, 0, "D3: 1 = a free list per thread in each register bank, each bank's free registers halved between the two harts, each hart's architectural registers homed as D4 (hart t's x1-x31 in integer bank t, f0-f31 in F<t>; bank 0 keeps the zero register); 2 = the same for the integer banks, the FP lists shared; with one thread, its own lists (the sibling's architectural registers still held); 3 = the FP banks only, the integer lists shared") \
  X(prf_homes, 0, "D4 with prf_split: 0 = hart t's x1-x31 at reset in integer bank t; 1 = both harts' in B0 (hart 0's at 1-31, hart 1's at 32-62); 2 = hart 0's in B0, hart 1's x1-x16 in B1 and x17-x31 in B2") \
  X(prf_steer, 0, "D3: rename steers an ALU op away from an ALU whose bank has no free register on the thread's list, to the other ALU when its bank has one") \
  X(prf_xfer, 0, "D3 revised (core-2): with prf_split, a hart that cannot rename for want of a bank's register takes one a cycle from the sibling's list (a sleeping sibling's with one thread); 1 = the donor keeps at least one free, 2 = the donor keeps its architectural registers of that kind plus one in the bank, 3 = as 1, but a hart that waits for a bank's register (starved) may take the sibling's last free one, and while it waits its sibling renames nothing into that bank") \
  X(prf_fp_bank, 0, "registers in each FP bank, F0 and F1 (0 = bank_size)") \
  X(prf_fp_xbank, 0, "D3 with FP banks of 64: an op that finds no register for its hart in its FP bank (its list, or a transfer) renames into the other FP bank: 1 = both ways (P4's results into F1, FP loads into F0, as if each bank's write port took either source); 2 = FP loads only, into F0 (a load-to-F0 path, or an fld cracked into an integer load and a move); 3 = P4's results only, into F1") \
  X(prf_fp_collide, 0, "prf_fp_xbank: each FP bank's one write port, as tg_lsu's hold (fpu-2, DR-179): an FP load whose write meets P4's in its bank waits in a one-entry hold, no wake or completion, and takes the result register in the first later cycle no load completes in M2 and P4 leaves its bank the next cycle (it wakes then and writes the cycle after); a second colliding FP load while the hold is full replays (prf_fp_replay cycles). 1 = no guards (a wait capped at 64 cycles); 2 = f5d9f294's guards: IQ-LD's select blocked from the hold's prf_fp_guard_ld-th failed take, IQ-FP's from its prf_fp_guard_fp-th, until it takes") \
  X(prf_fp_guard_ld, 1, "prf_fp_collide 2: the failed takes before IQ-LD's select is blocked") \
  X(prf_fp_guard_fp, 8, "prf_fp_collide 2: the failed takes before IQ-FP's select is blocked (0 = never)") \
  X(prf_fp_replay, 4, "prf_fp_collide: cycles before a replayed FP load reaches M2 again") \
  X(prf_fp_wait, 0, "prf_fp_collide: an FP load that collides while the hold is full waits, using neither AG nor M2, instead of replaying; the replay path picks one waiting load a cycle while the hold has a free entry (fpu-2's A); 2 = also IQ-FP's select paused from the cycle after a load waits until none waits and the hold is empty (A+B)") \
  X(prf_fp_fh, 1, "prf_fp_collide: the hold's entries, 1 or 2 (fpu-2's D); one takes the result register a cycle, the oldest first") \
  X(prf_fp_noxfer, 0, "prf_xfer: no transfers in the FP banks (the integer banks keep theirs)") \
  X(prf_fp_xbank_lat, 0, "prf_fp_xbank: cycles added to the result of an op renamed across (a cracked fld's move, for instance)") \
  X(prf_fp_homes, 0, "with prf_split: 1 = each hart's f0-f15 at reset in F0 and f16-f31 in F1, rather than all 32 in F<t>") \
  X(flush_walk, 0, "two threads, shared lists: a flush returns the flushed thread's registers by a walk of 2 ROB entries a cycle, its rename stalled meanwhile; 1 = the walk covers the thread's whole half, 2 = only the flushed entries (a mispredict's wrong path estimated as 2 a cycle from the branch's dispatch, up to the half)") \
  X(lone_sleep, 0, "D2, one thread: every lone_sleep cycles an unsimulated sibling wakes from WFI; the merged window splits after a drain, keeps halves while the sibling runs and sleeps until the merge, then merges (0 = always merged)") \
  X(lone_awake, 0, "D2: cycles the sibling runs after a split before it sleeps in WFI again") \
  X(lone_merge, 64, "D2: cycles the sibling spends in WFI with an empty half before the halves merge (-1 = never: static halves)") \
  X(lone_split, 0, "D2: 0 = the split waits until the thread's ROB, LQ and SQ are empty; 1 = until each fits its half") \
  X(wfi_sleep, 0, "a thread dispatches nothing past a WFI, and after it commits sleeps this many cycles (a timer's wake); parked while asleep with an empty window") \
  X(smt_cap_lift, 0, "two threads: the issue-queue caps and bank rules don't bind a thread while its sibling is parked in WFI (wfi_sleep)") \
  X(lone_caps, 1, "D2: 1 = the issue-queue caps (smt_iq_cap) bind a lone thread while its window is split; 2 = always") \
  X(smt_align, 0, "two threads (verif-2's pair runner): a thread's first-run region start (marker 1) waits at commit until every thread's has reached its commit head, so the two first regions start together") \
  X(smt_pa_flat, 0, "two threads share one physical address space: each program's addresses are its own (the pair runner's programs, linked at their slots' bases); 0 = thread 1's offset by 64 GiB + 21 pages") \
  X(stop_regions, 0, "the run ends once every thread's first region has ended, as the pair runner's finish does (its REPEAT builds never exit); 0 = once every thread's first run has") \
  X(smt_restart_ff, 0, "two threads, a mask of threads (bit t = thread t) whose program, once ended, runs again from its region start, fast-forwarded past its set-up (the pair runner's memory kernels built to repeat their region); others run again from the top") \
  /* area-recovery levers (plan section 8.5); off by default */                                   \
  X(smt_ckpt_shared, 0, "R10: the ckpt checkpoints are one pool shared by the threads (0 = ckpt per thread)") \
  X(rf_share_a2, 0, "R11 (alu3): ALU2 reads through the STA and shared ports; STA and FP int reads win") \
  X(dec_full, 0, "R12: decode slots from this index on take only ALU/branch/integer load-store (0 = all)") \
  X(alu3_simple, 0, "R13 (alu3): ALU2 executes add/sub, logic, compare, LUI/AUIPC and Zba shift-adds only") \
  X(iq_bank, 0, "each issue queue is two banks of rows that wake only on their half of the ROB; a uop takes the bank that sees its producers (two threads: its own)") \
  X(iq_bank_llt, 0, "with iq_bank: each bank also sees only half of the long-latency tags")      X(wake_tags, 0, "rows wake on a pool of this many tags for multi-cycle fixed-latency producers instead of ROB columns (0 = ROB columns)") \
  X(census, 0, "count every dispatched uop's source dependencies by wakeup kind (output only)")    \
  /* pipeline-stage ablations (area_recovery.md 6.1): 0 = the model as before */                    \
  X(abl_ld_use, 0, "extra cycles on every load result (hit, forward or miss) before its dependents issue") \
  X(abl_alu, 0, "extra cycles before a 1-cycle result wakes its dependents (completion unchanged)") \
  X(abl_done, 0, "extra cycles from execute completion to the ROB's complete mark (commit slips)") \
  /* DR-140's profiles (area_recovery.md 6.2): 0 = the fallback, the model as before */                 \
  X(abl_st_done, 0, "extra cycles before a store's address completes in the ROB (cut #4; #2 adds another)") \
  X(drain_guard, 0, "a committed store that has waited this many cycles for an L1D MSHR keeps the last free one from loads and prefetches until it allocates; they still use any beyond it (0 = no guard)") \
  X(drain_delay, 0, "cycles from a store's commit to its D$ write at the earliest (0: in its commit cycle)")

constexpr int MAX_THREADS = 2;

struct Config {
#define TG_DECL(n, d, s) int64_t n = d;
  TG_PARAMS(TG_DECL)
#undef TG_DECL
  std::string preset = "tanager_v1";

  bool set(const std::string& name, const std::string& value);  // false if unknown name
  bool apply_preset(const std::string& name);
  std::string to_json() const;
  static std::string help();
};

}  // namespace tg
