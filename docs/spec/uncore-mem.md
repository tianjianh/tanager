# Memory path: latency injector and DRAM window (`tg_axi_lat_inj`, `tg_axi_window`)

Status: draft — soc track — 2026-10-13

Each L2 bank's AXI4 master reaches its PS port through two blocks, in this order:

```
tg_l2_bank ──AXI4──► tg_axi_lat_inj ──AXI4──► tg_axi_window ──AXI4──► S_AXI_HP1 / HP2 (kv260_top)
             PA_W address, RISC-V physical               remapped address, AXI_EXT_ADDR_W bits
```

A register slice (`tg_axi_slice`: a skid buffer on each channel) follows the window, so the window's adder and the route to the PS port end at flip-flops. It may present a W beat before its AW, which AXI4 allows. `tg_uncore` `MEM_SLICE` (on by default, as built for 200 MHz) can remove it (`tg_axi_slice` `ON`), for DR-145's study of the slices at 125 and 100 MHz: off, every DRAM access is a cycle shorter each way ([soc.md](soc.md) §Reserve levers).

Before the injector, a skid buffer on AR alone (`tg_uncore` `AR_SLICE`, on by default since 10-15, the user's decision, DR-135) cuts the L2's AR handshake: without it, the L2's pick, its MSHR LUTRAM read, this window's range check and the ready back into the pick made the uncore's second-longest path at 200 MHz (−0.70 to −0.98 ns). It costs one cycle on every L2 fill (+0.056% cycles at `st`, +0.134% at `smt2`, first 20M cycles of the 2-core Linux boot). `W_SLICE` (off by default; a DR-135 reserve item, [soc.md](soc.md) §Reserve levers) puts skid buffers on AW and W in the same place, for the write-back path from the banks to the memory path by the PS ports, at a cycle per write-back.

Both are board-independent and simulate with the rest of `tanager_soc`. The carve-out location and size are run-time values from the host ([host.md](host.md)), so the L2 sees a generic memory (plan §5.5).

---

## Latency injector (`tg_axi_lat_inj`)

### Purpose
Emulates longer DRAM latency on the board, so Linux-scale workloads run at the 90-, 120- and 250-cycle points at full FPGA speed (plan §2.5, §5.6). It also measures the native latency, which is spike S1's question, from inside the running SoC.

### Interface
- AXI4 slave (from the L2 bank) and AXI4 master (to the window), same widths: 128-bit data, `AXI_ID_W` IDs.
- Configuration:
  - `rd_delay[9:0]`, `wr_delay[9:0]`;
  - `mode` (0 = target latency from issue, 1 = added to the native latency);
  - `bw_rate[8:0]` (beats per cycle × 256; 0 = no cap).
- Statistics: read count, sum and maximum of native read latency (cycles, from AR issue to the last R beat at the injector's downstream side). Each latency is taken modulo 2^16, like the time stamps, so a read in flight across the time counter's wrap counts its true latency.

### Behaviour
- **Reads.** Each AR accepted from the L2:
  - gets a slot (`SLOTS` = 32 per port; AR stalls when none is free);
  - records the issue time `t0` in issue order;
  - is forwarded downstream at once.
- **R beats.** They are always accepted from downstream (`RREADY = 1`) and written into their slot's buffer (block RAM, `SLOTS` × 4 beats × 128 bits plus `RRESP`). A slot is found from its ID through a table written at AR time; the L2's IDs are unique among its outstanding reads.
- **Release.** The oldest slot is released when all its beats have arrived and the time has come:
  - mode 0: `now − t0 ≥ rd_delay`;
  - mode 1: `now − t_arrival ≥ rd_delay`.

  Its beats stream to the L2 contiguously, in issue order. The delivered latency is `max(native, rd_delay)` in mode 0, which is the plan's "delay from request issue" definition, and `native + rd_delay` in mode 1. Store-and-forward plus the output buffer adds about 5 cycles to either (measured: 255–279 cycles at a 250-cycle target).
- **Writes.** AW and W pass through unchanged. Each B response is held in a FIFO until `now − t0(BID) ≥ wr_delay`, with `t0` from a per-ID table written at AW time, then released in arrival order. Delaying B keeps the L2's write-back MSHRs (and any re-read of the same line) honest at long latency.
- **Bandwidth cap.** A token bucket gates released R beats:
  - it gains `bw_rate` tokens per cycle, up to 1024;
  - a beat costs 256 tokens.
- **Why buffer.** The PS port's limit of 16 outstanding transactions applies only to the time a request spends downstream. Responses wait in the injector's own buffer, so the emulated latency is not distorted (plan §5.6).
- **Defaults.** Reset values (`rd_delay` = `wr_delay` = 0, mode 0, no cap) make the injector a pass-through with a few cycles of buffering.

### Parameters
`SLOTS` = 32 (more than the L2 bank's 24 MSHRs), `AXI_ID_W` = 6, `BEATS` = 4.

### Timing and area
- About 600 LUTs and 1 BRAM36 per port (32 × 4 × 130 bits, plan §5.6: "1–2 BRAM36 per port"); measured 700–900 LUTs in the traffic-generator build.
- Storage: the beat buffer in block RAM. The fields written once per burst and read by index (issue and arrival times, IDs, the ID → slot table, the issue-order queue, the per-ID AW times and the 32-entry B queue) are in LUTRAM through `tg_ram_lut`. The flags and beat counters with several writers are flip-flops.
- The release decision is a 10-bit subtract-compare on the head slot only.
- **200 MHz** (DR-137): the release decision (`issue`) arrives late, after the head's time stamps (a LUTRAM read) and the compare.
  - **The token bucket's next value** is computed both ways from registers (with the rate added, with and without the 256 a beat costs, each saturated at 1024), and `issue` only selects one. This is the same arithmetic as before, cycle for cycle. Before the change, the bucket's adder and saturation came after `issue`, which was the uncore's worst path (−0.738 ns, 13 levels).
  - **The head slot is a register** (`head_q`), not a read of the issue-order queue. So the time stamps are read straight from a register, one LUTRAM read earlier than before. `head_q` is the queue entry at the read pointer whenever the queue is not empty. After a pop it takes the entry behind the head (the queue's read port looks one entry ahead). When the queue is empty, or holds one entry and pops, it takes the slot being allocated. It does so whether or not a write lands: without one, the queue is or becomes empty and the head is not used. So `head_q` does not wait for `ar_fire`, which ends the L2's AR handshake (the uncore's longest path; with that dependency, `head_q` failed at −0.60 to −0.90 ns, and without it it passed in three of four port samples over two runs).
  - An assertion checks `head_q` against a model of the queue whenever it is not empty.

### Verification
`tests/unit/lat_inj`:
- random AR/AW traffic from a stub master to an AXI memory model with random latency and out-of-order responses;
- delivered latency checked per transaction against `max(native, rd_delay)` (mode 0) and `native + rd_delay` (mode 1);
- data, IDs and `RLAST` intact; issue order of R bursts;
- B delay; bandwidth cap rate over 10⁴ beats;
- statistics against the model's own latency record;
- a sparse-read phase after the dense ones. The issue-order queue then holds stale slots, and a burst often finishes as the next arrives, which exercises the head after a pop with one entry. Without this phase, a head register that ignored the write behind it passed the test.

### Provenance
Plan §2.5 and §5.6. XiangShan's FPGA prototype used a latency injector for the same purpose; that idea comes from its published papers and documentation (literature review), not its RTL. AXI4 per the AMBA AXI protocol specification (ARM IHI 0022).

---

## DRAM window (`tg_axi_window`)

### Purpose
Maps the RISC-V DRAM window (`DRAM_BASE` = `0x8000_0000`, `tg_map_pkg`) onto the PS DDR carve-out. It also guarantees that nothing the RISC-V side does can touch A53 memory outside the carve-out (plan §5.5).

### Interface
- AXI4 slave (from the injector, `PA_W` address) and AXI4 master (to the PS port, `AXI_EXT_ADDR_W` = 40).
- Configuration: `base[39:0]` (carve-out start, PS address space) and `size[39:0]` (carve-out bytes), from the host.

### Behaviour
- **In-range transactions:** an AR or AW with offset `o = addr − DRAM_BASE` and `o + bytes ≤ size` leaves with address `base + o`. Everything else passes unchanged.
- **Out-of-range transactions** never leave:
  - a read is answered with its beats and `RRESP = SLVERR`;
  - a write's W beats are absorbed, then `BRESP = SLVERR`.
  - Each refused burst pulses `oob_rd_o` or `oob_wr_o` with its address, which the board debug counters count and capture ([uncore.md](uncore.md) §Board debug counters).

  The L2 turns these into `denied` responses ([l2.md](l2.md)).
- **Configuration changes:** `base` and `size` may change only while the uncore is held in reset ([host.md](host.md) loading sequence). Their reset value, size 0, denies everything until the host configures the window.
- **Error response order:** errors merge into the response streams between bursts. The L2's IDs are unique among its outstanding transactions, so AXI's same-ID ordering is not at stake. A master that reuses IDs would need an in-order merge here.

### Parameters
`AXI_EXT_ADDR_W` = 40, `AXI_ID_W` = 6.

### Timing and area
- One 40-bit adder and compare per address channel, registered. About 200 LUTs per port.
- **The range check feeds `s_ar_ready_o`**, so it ends the L2's AR handshake path: the L2's pick, then its MSHR LUTRAM for the address, then this check, then the injector, then back into the L2's AR pointer (−0.700 ns at 200 MHz, all fabric).
  - `DRAM_BASE` is 2³¹, so synthesis already reduces `a − DRAM_BASE` to a short decrement of the top bits.
  - Comparing against `size + DRAM_BASE` instead was tried together with a one-hot L2 pick. Neither gained anything measurable, and ca1aece reverts both.

### Verification
`tests/unit/axi_window`: random in- and out-of-range bursts against a memory model, checking remapped addresses, that out-of-range transactions never appear downstream, the error responses, and same-ID ordering.

### Provenance
Plan §5.5. AXI4 per ARM IHI 0022.

---

No other core's or SoC's RTL was read for these units.
