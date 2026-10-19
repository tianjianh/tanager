# The double-pumped UltraRAM register file (DR-174, `docs/perf/spikes.md` §8.14)

Measurement harness from spikes-2's tier A. DR-174 builds the core's version from `tg_urf.sv`'s `WMODE "edge"`, behind the URF switch. This branch, `claude/spikes-2-uram-rf`, is not for merging.

## Files

| File | What it is |
|---|---|
| `tg_urf.sv` | The register file: NB banks × NC `URAM288_BASE` copies on `clk2x` (twice `clk`, from the same MMCM, phase-aligned). `WMODE "edge"` is DR-174's variant; `"mid"` is the plan as briefed, which misses in a routed chip. |
| `tb_urf.sv` | Against `tg_ram_lut` banks wired as `tg_irf`, with the early ports' addresses registered as today's issue → RF register. 200K cycles, reads biased to collide with writes. |
| `sim/URAM288_BASE.sv` | A behavioural model written from UG573, for Verilator. |
| `sim/vendor_uram_vl.sh`, `sim/vl_top.sv` | The vendor's model, made Verilator-compatible (its unconnected-pin `1'bz` defaults dropped), and a top that puts `glbl` beside the testbench. |
| `urf_top.sv`, `urf_fit.tcl`, `urf_fp_c0*.tcl` | Tier A's standalone harness: the RF stage as `tg_exec` has it, core 0's distances from `h100_m6m`. |
| `q_urf_ctx.tcl`, `q_urf_detail.tcl` | Context queries on a routed chip: URAM sites, where the register file and its sources sit, when each input arrives. |

## `WMODE "edge"`: what each copy does

| Edge | Port A | Port B |
|---|---|---|
| Core edge | Writes the bank's write port | Reads early port c (after A's write, so it sees it) |
| Mid-cycle | Reads late port c | Idles (`EN_B` low), so its output holds the early read to the next core edge |

- **One early and one late port per copy**, NC = max(NE, NL). Every copy of a bank takes every write of its bank.
- **Early port:** `e_bank_n`/`e_idx_n` are the *next* cycle's bank and index: the D side of today's issue → RF register. The UltraRAM's address register takes it at the core edge. The data is valid at the end of the next cycle.
- **Late port:** `l_bank`/`l_idx` are *this* cycle's bank and index, from a register (today's issue → RF register). The data is valid at the end of this cycle.
- **Write port:** `we`/`waddr`/`wdata` are held during the cycle, exactly what `tg_ram_lut` would write at the edge that ends it.
- **Semantics:** the same as `tg_irf` with the early addresses registered. Every read returns the writes of earlier cycles.
- **It depends on UltraRAM doing port A's operation before port B's at the core edge.** That's how an early read sees the last cycle's write. UG573 and the vendor model agree, and the testbench fails, with 154,877 mismatches, if the order is reversed.

## Ports in the core

- **Integer file:** three of the six issue-time read ports take port B at the core edge (the select's output, retimed), and three take port A at mid-cycle (registered addresses). That's 3 banks × 3 copies = 9 UltraRAMs a core.
- **Choosing ports:** put the ports with the most logic after the read on the core-edge slot, because port B's data holds for the whole cycle. The LD/STA bases, with their `rbs` select, are the candidates. A mid-cycle read leaves 1.7–1.9 ns after its data reaches the first LUT (tier A: +0.86 to +1.22 ns into the RF stage through two LUT levels).
- **The store-data port (`P_SH`) and the trace ports (`P_TR`) stay in LUTRAM.** `h100_m6m`'s LSU has the store-data tag ready 5.19 ns into the cycle, and a mid-cycle read needs it by about 3.95 ns. A `tg_ram_lut` per bank with NR = 1 + COMMIT_WIDTH and its bank select costs about 300 LUTs a core without the trace.

## Timing exceptions a chip needs

These are `urf_fit.tcl -edge 1`'s, written for a core. `$urams` is the URF's `URAM288_BASE` cells and `c0` the core clock.

```tcl
# Early (port B) reads: the address is captured at the core edge, a full core cycle after the issue stage's
# launch (port B idles at the mid-cycle edge between, so every path into ADDR_B is full-cycle; EN_B is not)
set_multicycle_path -setup 2 -end -from [get_clocks c0] -through [get_pins -of_objects $urams -filter {REF_PIN_NAME =~ ADDR_B*}]
set_multicycle_path -hold  1 -end -from [get_clocks c0] -through [get_pins -of_objects $urams -filter {REF_PIN_NAME =~ ADDR_B*}]
# The write lands at the core edge, a full cycle. Port A's address and enable also carry the mid-cycle late read
# (through the half-cycle multiplexer), so relax only the paths from the write port's sources, the startpoints
# behind tg_urf's we/waddr/wdata inputs, which must not also feed the late address (check with all_fanout)
set wsrc [all_fanin -flat -startpoints_only [get_pins <...>/u_urf/we* <...>/u_urf/waddr* <...>/u_urf/wdata*]]
set_multicycle_path -setup 2 -end -from $wsrc -to $urams
set_multicycle_path -hold  1 -end -from $wsrc -to $urams
# Port B's early data holds from the core edge to the next (EN_B low at mid-cycle): a full cycle into the RF stage
set held [get_pins -of_objects $urams -filter {REF_PIN_NAME =~ DOUT_B*}]
set_multicycle_path -setup 2 -start -through $held -to [get_clocks c0]
set_multicycle_path -hold  1 -start -through $held -to [get_clocks c0]
# No exception: port A's mid-cycle data (DOUT_A) into the RF stage, the late addresses into ADDR_A, and the
# half-cycle flag (t1_q, t2_q) into every multiplexer, EN and RDB_WR: all 5 ns from the edge that launches them
```

## UltraRAM numbers (XCK26 −2LV, tier A)

- **Clock-to-out without the output register:** port A 1.63–1.70 ns, port B 2.65 ns.
- **With the output register:** 0.81–0.96 ns.
- **Setup:** 0.68–0.75 ns on port A's address, 0.45 on port B's, 0.50 on port B's write data.
- **Clock uncertainty between `clk` and `clk2x`:** 0.187 ns.

## Sites

`h100_m6m` leaves `URAM288_X0Y48`–`X0Y63` free in clock region X2Y3 (core 0's side) and `X0Y0`–`X0Y15` in X2Y0 (core 1's side). The L2 uses `X0Y16`–`X0Y47`. A core needs 9 for the integer file, plus 4 if the FP file follows: 13 of its 16. Tier A put core 0's nine at `X0Y52`–`X0Y60`, level with its RF stage.

## Simulation

Verilator 5.052 (`source tools/env.sh`); this host's Vivado has no xsim libraries (`data/xsim` is missing).

```bash
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-PROCASSINIT --top-module tb_urf -GNE=3 -GNL=3 '-GWMODE="edge"' fpga/spikes/uram/sim/URAM288_BASE.sv rtl/common/prim/tg_ram_lut.sv fpga/spikes/uram/tg_urf.sv fpga/spikes/uram/tb_urf.sv
```

```bash
bash fpga/spikes/uram/sim/vendor_uram_vl.sh /tmp/URAM288_BASE_vl.v
```

The vendor model then builds with `--top-module vl_top`, adding `/tmp/URAM288_BASE_vl.v`, `$XILINX_VIVADO/data/verilog/src/glbl.v` and `fpga/spikes/uram/sim/vl_top.sv`. Both models pass both modes: 0 mismatches in 200K cycles.
