// tgsim: cycle-level out-of-order core timing model, driven by the functional simulator (correct
// path only: wrong-path instructions are not simulated; a mispredicted branch stalls fetch until it
// resolves, which charges the full redirect penalty).
//
// Multithreading (threads = 2, plan section 6): each hardware thread runs its own program on its own
// functional simulator. Per thread: instruction stream, fetch state and instruction queue, global history,
// RAS, rename map, checkpoints, ROB/LQ/SQ/completion-buffer share, commit order, store drain, flushes and
// statistics. Shared: fetch (one thread per cycle), decode/rename/commit slots, issue queues (optional
// per-thread caps), physical register banks, long-latency tags, execution units, caches, MSHRs, prefetchers
// and predictor tables (optionally hashed with the thread ID).
#pragma once
#include <array>
#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "bpred.h"
#include "cache.h"
#include "config.h"
#include "iss.h"

namespace tg {

enum Queue : uint8_t { Q_A0, Q_A1, Q_LD, Q_STA, Q_FP, Q_UNI, Q_SERIAL, Q_ALU_ANY, Q_A2, NQ };
// The front end's events that decode's starved slots are charged to (lost_* counters, area_recovery.md §6.7)
enum FeEv : int { FE_STEADY, FE_FLUSH, FE_REPLAY, FE_DRED, FE_MISS_BR, FE_MISS_JAL, FE_MISS_RET, FE_SLOT, FE_RASTGT,
                  FE_NT, FE_BOGUS, FE_CUT, FE_ICMISS, FE_FTQ, FE_MISS_STRAD };
// What stopped dispatch this cycle: decode's cycles held by rename are charged to it (held_*), as the RTL's rename
// profile does (area_recovery.md §6.8)
enum DispWhy : int { DW_NONE, DW_EMPTY, DW_ROB, DW_LQ, DW_SQ, DW_IQ, DW_REG, DW_LLT, DW_WTAG, DW_BANK };
constexpr uint64_t NEVER = ~0ull;
// Micro-op ids carry the hardware thread in their top bits: unique across threads, and thread 0's ids are
// exactly the single-thread ones.
constexpr int TID_SHIFT = 48;

struct RasUndo { bool op = false; int sp = 0; int slot = -1; uint64_t val = 0; };

// m2_btage: a conditional branch's block-TAGE read (its block's indices and tags, its slot and the fetch-time
// direction), for training at commit; and the block history before each instruction, for a flush's repair.
struct BtRec {
  BlockTage::Ix ix;
  uint64_t gh = 0;
  uint8_t slot = 0;
  bool v = false, pred = false;
};

struct FetchRec {
  uint64_t seq = 0;              // dynamic instruction number (synthetic shadow: branch seq)
  const DynInst* di = nullptr;
  uint64_t avail = 0;            // first cycle it can be decoded
  bool mispred = false;
  bool sfb = false;              // predicated short forward branch
  bool synthetic = false;        // shadow instruction of a taken predicated branch (not executed)
  uint8_t mp_kind = 0;           // 1 direction, 2 target, 3 return, 4 cold (no BTB entry)
  bool de_redirect = false;      // fe_m2: decode redirects fetch after this instruction (fetch waits for it)
  Hist hist;                     // global history before this instruction
  RasUndo ras;
  BtRec bt;
  uint64_t blk = 0;              // fe_m2: its fetch block's number (m2_ftq)
};

struct Uop {
  uint64_t id = 0;
  uint64_t age = 0;                   // dispatch order across threads (issue-queue age)
  uint8_t tid = 0;
  uint64_t seq = 0, seq_next = 0;
  const DynInst* di = nullptr;   // instruction that defines the timing class / memory / control
  Cls cls = Cls::ALU;
  uint8_t q = Q_SERIAL;
  uint8_t n_instr = 1;
  bool serial = false, mmio = false;
  uint8_t nsrc = 0;
  std::array<int, 3> src_arch{};      // 0..63 (FP = 32 + reg), -2 = SFB temp
  std::array<uint64_t, 3> src_prod{};
  int dst_arch = -1;                  // -1 none, -2 SFB temp
  int dst_bank = -1;
  int data_arch = -1;                 // store data source (split store)
  uint64_t data_prod = 0;
  uint64_t sfb_temp_of = 0;           // select uop: id of its compare uop (temp register owner)
  int sfb_temp_bank = -1;
  uint8_t state = 0;                  // 0 decoded, 1 dispatched (waiting), 2 issued
  uint64_t t_disp_ok = 0, t_eligible = 0, t_issue = NEVER, t_ready = NEVER, t_done = NEVER, t_ag = NEVER;
  bool is_ctrl = false, mispred = false, resolved = false, has_ckpt = false, sfb_cmp = false, sfb_sel = false;
  bool fused_br = false;
  uint8_t mp_kind = 0;
  Hist hist;
  RasUndo ras;
  BtRec bt;
  uint64_t blk = 0;
  uint64_t dgrp = 0;                  // iq_slot_bank: its decode group (decode cycle) and slot in it
  uint8_t dslot = 0;
  uint8_t steer_q = 0xff;             // iq_steer_rn: the ALU queue rename picked (0xff: not yet)
  bool is_load = false, is_store = false, violated = false, has_llt = false, in_lq = false;
  bool retired_early = false;
  int row = -1;
  uint8_t iq_bank = 0;                // iq_bank: the bank of its queue's rows that holds it
  bool has_wtag = false;              // wake_tags: holds a wakeup tag until its result wakes
  uint64_t addr = 0;
  uint8_t size = 0;
};

struct SqEntry {
  uint64_t id = 0, addr = 0;
  uint8_t size = 0;
  bool mmio = false, committed = false, rfo = false;
  uint64_t t_addr = NEVER;
  uint64_t t_commit = NEVER;  // drain_delay: when it committed
  uint64_t data_prod = 0;
  bool data_now = false;  // data captured at issue (non-split stores)
};

#define TG_STATS(X)                                                                                \
  X(cycles) X(instr) X(uops)                                                                       \
  X(br_cond) X(br_jal) X(br_jalr) X(br_ret)                                                        \
  X(mp_dir) X(mp_target) X(mp_ret) X(mp_cold) X(mp_resolved_exec) X(mp_resolved_commit)            \
  X(mp_refills) X(mp_refill_cycles)                                                                \
  X(taken_bubbles) X(predecode_redirects) X(ubtb_wrong) X(f2_overrides) X(f2_cuts) X(bt_drops)       \
  X(fetch_blocks) X(ftq_full)                                                                      \
  X(f2o_miss) X(f2o_slot) X(f2o_nt) X(f2o_ret) X(f2o_bogus)                                       \
  X(dec_take0) X(dec_take1) X(dec_take2) X(dec_blocked) X(dec_starved) X(rob_empty) X(disp_stall_slot) \
  X(dc_clashes)                                                                                    \
  X(f2o_miss_br) X(f2o_miss_jal) X(f2o_miss_ret) X(f2o_miss_strad)                                 \
  X(lost_steady) X(lost_flush) X(lost_replay) X(lost_dred) X(lost_miss_br) X(lost_miss_jal)        \
  X(lost_miss_ret) X(lost_slot) X(lost_rastgt) X(lost_nt) X(lost_bogus) X(lost_cut) X(lost_icmiss) \
  X(lost_ftq) X(lost_miss_strad)                                                                   \
  X(held_rob) X(held_lq) X(held_sq) X(held_iq_a0) X(held_iq_a1) X(held_iq_ld) X(held_iq_sta)      \
  X(held_iq_fp) X(held_reg) X(held_llt) X(held_wtag) X(held_other)                                 \
  X(sta_rows_base) X(sta_rows_data) X(sta_rows_ready) X(sta_rows_held) X(sta_held_data)            \
  X(a0_rows_wait) X(a0_rows_ready) X(a0_rows_held) X(a1_rows_wait) X(a1_rows_ready) X(a1_rows_held) \
  X(ld_rows_wait) X(ld_rows_ready) X(ld_rows_held) X(held_alu_other) X(stq_cancels)                \
  X(fused) X(folded) X(sfb_pairs) X(sfb_shadow_skipped)                                            \
  X(fetch_stall_icache) X(fetch_stall_blocked) X(fetch_stall_bubble) X(fetch_stall_queue)          \
  X(disp_stall_rob) X(disp_stall_iq) X(disp_stall_lq) X(disp_stall_sq) X(disp_stall_reg)           \
  X(disp_stall_llt) X(disp_stall_empty) X(ckpt_none)                                               \
  X(loads) X(stores) X(ld_fwd) X(ld_fwd_wait) X(ld_partial) X(ld_l1_hit) X(ld_l1_miss) X(ld_no_mshr) \
  X(hitpred_wrong) X(shadow_cancels) X(cancelled_issues) X(hitmiss_flushes)                        \
  X(violations) X(violation_flushes) X(mdp_waits) X(early_retired) X(commit_stall_cycles)          \
  X(mlp_sum) X(mlp_cycles_nz) X(mlp_max)

// Multithreading only (reported per thread when threads > 1).
#define TG_SMT_STATS(X) X(fetch_cycles) X(fetch_lost_smt) X(decode_slots) X(dispatch_slots)
// Area-recovery levers (reported when one of them is on): R11 port conflicts, R12 decode stops, R13 dispatch
// stalls of an op ALU2 could not take, iq_bank dispatch stalls of a uop whose producers lie in both banks,
// wake_tags dispatch stalls for want of a tag.
#define TG_LEVER_STATS(X)   X(rf_port_conflicts) X(dec_slot_stops) X(alu3_steer_stalls) X(disp_stall_bank) X(disp_stall_wtag)

struct Stats {
#define TG_SDECL(n) uint64_t n = 0;
  TG_STATS(TG_SDECL)
  TG_SMT_STATS(TG_SDECL)
  TG_LEVER_STATS(TG_SDECL)
#undef TG_SDECL
};

// One hardware thread's program. The core restarts a program that ends before the other thread's first
// run is complete, so both threads stay active while every first run is measured.
struct ThreadSpec {
  Iss* iss = nullptr;            // initial functional simulator, with the program loaded (owned by the caller)
  std::string elf, stdin_text, bench;
  bool ff = false;               // fast-forward to the region start marker
  uint64_t ram_base = 0, ram_size = 0;
};

class Core {
 public:
  Core(const Config& c, const std::vector<ThreadSpec>& specs);
  // Runs to completion. Returns false on simulation error (deadlock, ISS fault).
  bool run();
  std::string result_json(const std::string& bench) const;

 private:
  struct PendingFlush { bool v = false; uint64_t at = 0, from_id = 0, resume = 0; };
  struct Thread {
    explicit Thread(int ras_entries) : ras(ras_entries) {}
    int tid = 0;
    ThreadSpec spec;
    Iss* iss = nullptr;
    std::unique_ptr<Iss> owned;    // functional simulator of a restarted run
    uint64_t salt = 0;             // XORed into PCs that index shared predictor tables (TID hashing)
    uint64_t pa_off = 0;           // physical-address offset: each thread has its own address space
    // stream
    std::deque<DynInst> stream;
    uint64_t stream_base = 0;
    bool iss_done = false;
    std::vector<DynInst> synth;    // ring of synthetic shadow instructions
    size_t synth_pos = 0;
    // front end
    uint64_t fetch_seq = 0, fe_resume = 0;
    bool fe_blocked = false;
    std::deque<FetchRec> fetchq;
    Ras ras;
    Hist ghr;
    // m2_btage: the block history (a bit per conditional branch, newest in bit 0), the history before the last
    // block read, whether the next read has the whole history (after a redirect, a flush or an I$ miss), and a
    // block the fetch queue cut short (its rest reads nothing new)
    uint64_t bgh = 0, bt_h0 = 0;
    bool bt_exact = true, bt_partial = false;
    BlockTage::Ix bt_ix;
    uint64_t bt_blk = 0;
    int bt_nbr = 0;
    // fe_m2: blocks fetched (numbered from 1), and blocks the youngest retired instruction's block follows: the
    // FTQ (m2_ftq) holds blk_seq - blk_head of them
    uint64_t blk_seq = 0, blk_head = 0;
    // the front end's last event (decode's starved slots are charged to it, as the RTL profile does), and whether
    // fetch waits on a mispredict (the RTL decodes the wrong path meanwhile, so that wait is not starvation)
    int fe_ev = 0;
    uint64_t fe_ev_t = 0;
    bool fe_wait_mp = false;
    // ... and from when, after a flush at commit: fetch restarts commit_redirect cycles later, and the RTL decodes
    // the wrong path until its flush acts
    uint64_t fe_count_from = 0;
    // m2_strad: the last block ended in sequence (at a straddler, or cut short by a full fetch queue), so a
    // straddler that starts the next fetch is decoded with its second block
    bool fe_seq = false;
    // what stopped dispatch this cycle (DispWhy), and for a full issue queue, which queue and slot bank
    int disp_why = DW_NONE;
    uint8_t disp_why_q = 0, disp_why_k = 0;
    bool disp_why_alu = false;  // ... and whether the op stopped there is an ALU op rename steers between A0 and A1
    // window (program order): decoded but not yet committed uops
    std::deque<Uop> win;
    uint64_t win_base = 1, next_id = 1, disp_next = 1;
    uint64_t rob_count = 0;
    // rename
    std::array<uint64_t, 64> rat{};
    std::array<int, 64> arch_bank{};
    std::array<uint64_t, 64> arch_prod{};
    int ckpt_used = 0;
    // memory
    uint64_t lq_count = 0;
    std::deque<SqEntry> sq;
    std::deque<uint64_t> lqcb_done;  // completion times of retired loads in the completion buffer
    PendingFlush pflush;
    // region of interest (markers) of the first run
    bool in_region = false, region_seen = false;
    uint64_t r_start_cycle = 0, r_end_cycle = 0;
    Stats st, st_start, st_end;
    MemStats ms_start, ms_end;
    uint64_t last_commit_t = 0;
    uint64_t refill_from = ~0ull;  // commit cycle of a mispredict recovered at commit, until the next retire
    uint64_t drain_wait = ~0ull;   // cycle the committed SQ head first found no L1D MSHR (`drain_guard`)
    // multithreaded runs
    int lap = 0;                   // completed runs of the program
    bool first_done = false;
    int first_exit = 0;
    std::string first_stdout;
    uint64_t first_cycles = 0, first_instr = 0;
  };

  Thread& th(const Uop& u) { return *th_[u.tid]; }
  void fe_event(Thread& T, int ev) { T.fe_ev = ev; T.fe_ev_t = t_; }
  // stream of correct-path instructions from the ISS
  const DynInst* get(Thread& T, uint64_t seq);
  bool stream_has(Thread& T, uint64_t seq);
  void prune_stream(Thread& T);
  // pipeline stages
  void fetch();
  void fetch_thread(Thread& T);
  void decode();
  int decode_thread(Thread& T, int slots);
  int decode_take(Thread& T, int slots);
  void dispatch();
  void dispatch_thread(Thread& T, int& n, int& row);
  void issue();
  void commit();
  int commit_thread(Thread& T, int width);
  void drain_stores();
  bool drain_thread(Thread& T);
  int drain_reserve() const;  // 1 while a committed store has waited `drain_guard` cycles for an L1D MSHR
  // helpers
  bool predict_ctrl(Thread& T, const DynInst& di, FetchRec& r, uint64_t block_start, bool ubtb_hit,
                    uint64_t ubtb_tgt, int& bubble);
  void fetch_block_m2(Thread& T, uint64_t start, uint64_t blk_end);
  bool sfb_shape(Thread& T, const DynInst& di, const Decoded** shadow);
  Uop& new_uop(Thread& T, const FetchRec& r);
  void add_srcs(Uop& u, const Decoded& d, bool skip_store_data);
  bool src_ready(uint64_t prod, uint64_t t) const;
  uint64_t prod_ready_time(uint64_t prod) const;
  bool fusible(const FetchRec& a, const FetchRec& b) const;
  int bank_for(const Uop& u, uint8_t q) const;
  int free_regs(int bank);
  bool can_issue(Uop& u);
  void do_issue(Uop& u, int port);
  void exec_load(Uop& u);
  void exec_store(Uop& u);
  void resolve_branch(Uop& u, uint64_t when);
  bool early_retire_ok(Uop& u);
  void retire(Uop& u, bool early);
  void flush_from(Thread& T, uint64_t from_id, uint64_t resume_seq);
  void iq_remove(Uop& u);
  void iq_reinsert(Uop& u);
  Uop* find(uint64_t id);
  const Uop* find(uint64_t id) const;
  void train_predictors(const Uop& u);
  void sample_mlp();
  // multithreading
  void order(int* o, bool fetch_stage) const;  // thread priority this cycle (ICOUNT or round robin)
  uint64_t icount(const Thread& T) const;
  int64_t iq_cap(uint8_t q) const;
  int64_t iq_free(uint8_t q, int tid) const;  // entries thread tid may still take in queue q
  int iq_occ(uint8_t q, int tid) const;     // entries of queue q held by thread tid
  int64_t share(int64_t size, int tid) const;  // per-thread limit of a ROB/LQ/SQ/CB-like structure
  // iq_bank: the ROB half of a uop, free rows of a bank, and the bank a uop's producers need (-1 any, -2 none)
  int rob_half(uint64_t id) const;
  int64_t bank_free(uint8_t q, int b) const;
  // iq_hold: rows of issued uops not yet free (cycle free, slot bank, uop); iq_slot_bank: free rows of slot k's bank
  struct Held { uint64_t t_free; uint8_t bank; uint64_t id; };
  std::array<std::vector<Held>, NQ> held_;
  int64_t held(uint8_t q, int bank) const;
  int64_t slot_free(uint8_t q, int k) const;
  int dec_n_ = 0;                     // uops decoded so far this cycle (the next one's slot)
  // iq_steer_rn: the ALU queues' bank flags (a row free, by slot) rename read for this cycle's dispatch, and this
  // cycle's, which the next cycle's rename reads
  std::array<std::array<bool, 2>, 2> steer_flags_{{{true, true}, {true, true}}}, bf_prev_{{{true, true}, {true, true}}};
  void steer(Uop& u) const;
  // dc_row_clash: loads at their AG cycle (the D$ row they read), checked against the store drain's row writes
  struct AgRec { uint64_t ag, issue, id, blk; bool spec; bool done = false; };
  std::vector<AgRec> ag_recs_;
  void row_clash(Thread& T, uint64_t addr);
  void clash_hit(Thread& T, Uop& u, uint64_t issue, bool spec);
  int bank_need(const Thread& T, const Uop& u) const;
  bool mx_named(const Uop& p) const;  // a 1-cycle producer its consumers name by ALU-queue row (MX)
  void sta_census(Thread& T);         // IQ-STA's rows in the bank that stopped dispatch, by what they wait on
  void iq_census(Thread& T);          // the same for an ALU queue or IQ-LD: waiting, ready, issued and held
  int wtags_used() const;             // wake_tags: tags held by producers whose results have not woken
  bool window_full(int64_t size, uint64_t own, uint64_t total, int tid) const;
  bool fast_forward(Thread& T);
  bool finished(Thread& T);
  void restart(Thread& T);
  void end_first_region(Thread& T);
  void region_event(Thread& T, bool start);
  void overlap_check_start();
  std::string region_json(const Thread& T) const;
  std::string census_json() const;
  uint64_t pa(const Thread& T, uint64_t a) const { return a + T.pa_off; }

  const Config& c_;
  const int nthr_;
  std::vector<std::unique_ptr<Thread>> th_;
  MemSys mem_;
  std::unique_ptr<DirPred> dir_;
  Btb btb_;
  MicroBtb ubtb_;
  M2Ubtb m2_;  // fe_m2: the RTL's micro-BTB and its training counters
  // m2_btage: core-2's TAGE, its training queue (btage_tq), the request in T2 (written at the cycle's end) and
  // this cycle's requests from commit
  std::unique_ptr<BlockTage> btage_;
  struct BtReq { BlockTage::Ix ix; uint8_t slot = 0; bool taken = false, pred = false; };
  std::deque<BtReq> btq_;
  std::vector<BtReq> bt_new_;
  BtReq bt_t2_;
  bool bt_t2v_ = false;
  void bt_edge();
  PcCounters sfb_tab_;
  PcTable hitpred_, waittab_;

  uint64_t t_ = 0;
  uint64_t age_next_ = 1;
  // rename (shared register banks)
  std::vector<int64_t> bank_size_, bank_committed_, bank_inflight_;
  std::deque<std::pair<uint64_t, int>> deferred_free_;  // (cycle, bank)
  // issue
  std::array<std::vector<uint64_t>, NQ> iq_;
  int rows_used_ = 0;
  std::unordered_map<int, int> row_left_;
  int next_row_ = 0;
  uint64_t cancel_from_ = NEVER, cancel_to_ = 0;
  int cancel_tid_ = 0;
  uint64_t div_busy_ = 0, fdiv_busy_ = 0;
  std::array<uint64_t, 128> wb_b1_{};
  // early-retired uop id -> t_ready
  std::unordered_map<uint64_t, uint64_t> pending_;
  std::unordered_map<uint64_t, uint32_t> mp_pc_;  // mispredicts by PC in the region (TGSIM_MPDUMP=file writes them)
  // Dependency census (census = 1): each dispatched uop's sources, by what its row would wait on.
  // READY: the value exists; MX: a 1-cycle producer still in an ALU-queue row; ROB: a ROB-indexed wakeup
  // (multi-cycle or not yet woken); LLT: a long-latency tag; XTHREAD: a producer of the other thread.
  enum CensusKind { CK_READY, CK_MX, CK_ROB, CK_LLT, CK_XTHREAD, CK_N };
  std::array<std::array<uint64_t, CK_N>, NQ> census_{};
  std::array<std::array<uint64_t, NQ>, NQ> census_rob_from_{};  // ROB-column waits by producer queue
  // ROB-column waits on a 1-cycle ALU-queue producer (none can occur while MX covers them: these are the waits
  // that wakeup tags would lose), and waits (MX or ROB column) on a producer in the other half of the ROB
  std::array<uint64_t, NQ> census_rob_1c_{}, census_xhalf_{};
  void census_source(const Thread& T, uint8_t q, uint64_t prod, uint64_t cons);
  // overlap window of the threads' first regions (threads > 1)
  bool ov_started_ = false, ov_ended_ = false;
  uint64_t ov_start_ = 0, ov_end_ = 0;
  std::array<uint64_t, MAX_THREADS> ov_i0_{}, ov_i1_{}, ov_r0_{};
  std::string err_;
};

}  // namespace tg
