# spikes-2: where to resume

Written 2026-10-24 16:15 PDT for the pause until the weekly reset (10-28). In this note, `$B` is `~/tanager-build/track-spikes-72f833`.

## State

**The branch:** `claude/track-spikes-72f833`, last merged into main as 7e838ecc (55bc9ec1). Only this note is not on main.

**The build tree:** `$B`. Its keep list `$B/KEEP.txt` is current.

**Done on 10-24** (everything is in `docs/perf/spikes.md` §8.18 and in `fpga/spikes/results/`):
- **The pair of record** (`rec_u095` / `rec_u105`) closes both placements.
- **The write-pacing image** (`wbpm_u105`) closes at +1.068 ns. It went to soc-2; its sha256s are in `KEEP.txt` and §8.18.
- **The indirect-target table's heads** were checked out of context: at bf29152f (T6), mode 2 has the decision registers at the table-off depth.
- **M9's area package** (`TG_HPM=1`, `TG_LWT=1`, `TG_ITT=2`; `m9a`) doesn't place.
  - No placement form packs it (`m9t_*`).
  - The prices after `opt_design`: the counters +277 LUTs, the load-wait table +424, the table +922.
  - The packing cliff is about 116,500 LUTs after `opt_design`.
  - DR-195 (program counters at 40 bits, pc40) is the RTL answer.

## Armed

There is one watcher: `$B/tools/wait_main_m9b2.sh`.
- **How it runs:** it started at 16:14 on 10-24 as pid 3732581 and runs detached. It checks main every 5 minutes and gives up at 16:14 on 10-29.
- **What it waits for:** DR-195's pc40 step 1 on main, that is all of:
  - `pc40_t` in `rtl/core/tg_core_pkg.sv`;
  - `pc40_t` in `rtl/core/frontend/tg_fetch.sv`;
  - `bpc_q` in `rtl/core/rob/tg_rob.sv`.
- **What it does then:**
  1. Snapshots main into `$B/snap/product_wt`.
  2. Lints it with HPM=1, LWT=1 and ITT=2.
  3. Pins it as `claude/spikes-2-board-m9b`.
  4. Starts the pair `m9b` (the product flow, 0.95 and 1.05 ns) in `$B/vivado/product_wt_m9b_u095` and `_u105`, with the families queries (`$B/ooc/q_fam_m9b_u0*`).
- **Where its progress shows:** `$B/logs/track_runner.log`, in the lines starting `m9b:` and `product_wt m9b_`.

Nothing else is running, and no session waiter is left.

## Next step, after the reset

1. **Check the watcher:** `grep -E "m9b" ~/tanager-build/track-spikes-72f833/logs/track_runner.log | tail`.
   - If it only says waiting, step 1 hasn't landed.
   - Check that the watcher is still alive (`ps -eo pid,args | grep "[w]ait_main_m9b2"`). If it has expired, relaunch it with `bash $B/tools/launch_wait_main_m9b2.sh`.
2. **If the pair ran, report it to the coordinator:**
   - LUTs and fill (`reports/utilization.rpt`) against `rec_u105`'s 112,862 (96.4%);
   - both placements' WNS / TNS / WHS (`reports/summary.txt`);
   - the worst families (`fail_families.txt` in each families query's folder).
3. **Measure `fpc_q` and the I$-data family:**
   - Run `bash $B/tools/run_q_paths.sh <folder> <routed.dcp> fpga/spikes/tcl/paths_m9a.tcl` on each placement.
   - Compare with `fpga/spikes/results/m9a_area/rec_u0{95,105}_paths_m9a.txt`.
   - If it again fails to place, report the packer's CLB count (Place 30-487) and its LUTs after `opt_design` against the cliff.
4. **Write it up:** a dated entry in §8.18 and the results in `fpga/spikes/results/`, then an MR.
