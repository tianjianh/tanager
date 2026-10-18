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
  X(btage_lag, 1, "m2_btage: a block read right behind another lacks that block's history bits (F1 reads as F2 delivers)") \
  X(btage_tq, 4, "m2_btage: training queue entries, one request every two cycles, a full queue drops; 0 = train at commit at once") \
  X(m2_cut, 0, "fe_m2 with m2_f2: a block ends before its third conditional branch, refetched at m2_f2_bubble") \
  X(m2_ftq, 0, "fe_m2: FTQ entries (core-2's TAGE front end): a block holds one from fetch until an instruction of a later block commits; fetch waits while none is free (0 = no FTQ)") \
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
  X(smt_fetch, 0, "front-end thread priority: 0 ICOUNT (fewest uops in IQ/rename/issue queues), 1 round robin") \
  X(smt_part, 1, "ROB/LQ/SQ/completion buffer: 1 static per-thread halves, 0 shared with smt_win_cap") \
  X(smt_win_cap, 75, "shared ROB/LQ/SQ/completion buffer (smt_part=0): percent one thread may hold") \
  X(smt_iq_cap, 75, "percent of each issue queue one thread may hold")                             \
  X(smt_mshr_cap, 100, "percent of the L1D MSHRs one thread may hold")                             \
  X(smt_llt_cap, 100, "percent of the long-latency tags one thread may hold")                      \
  X(smt_bp_hash, 1, "hash the thread ID into shared predictor tables (0 = threads share entries by PC)") \
  X(smt_mix, 1, "decode, rename and commit slots one thread leaves unused go to the other thread") \
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
  X(drain_guard, 0, "a committed store that has waited this many cycles for an L1D MSHR gets the next one; loads and prefetches wait (0 = no guard)")

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
