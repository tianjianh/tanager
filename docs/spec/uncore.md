# Uncore overview and interconnect (`tg_xbar`, `tg_tl_dev`)

Status: draft — soc track — 2026-10-13

The uncore is everything between the cores' TileLink ports and the PS: the interconnect, the shared L2, the MMIO devices, the latency injector, the memory window and the host bridge (plan §3.1, §5). This document covers the block list, the identifiers and maps every block shares, and the interconnect. Each block has its own spec:

| Spec | Blocks |
|---|---|
| this file | `tg_xbar` (interconnect), `tg_tl_dev` (device bus), `tg_uncore_pkg`, helpers in `rtl/uncore/lib` |
| [l2.md](l2.md) | `tg_l2`, `tg_l2_bank` |
| [uncore-periph.md](uncore-periph.md) | `tg_aclint`, `tg_plic`, `tg_uart`, `tg_bootrom` |
| [uncore-mem.md](uncore-mem.md) | `tg_axi_lat_inj` (latency injector), `tg_axi_window` (DRAM window onto the PS carve-out) |
| [host.md](host.md) | `tg_host_bridge`, `tg_hostctl`; `tanager-host` (A53 software) |
| [soc.md](soc.md) | `tanager_soc`, `kv260_top`, clocks, resets, Vivado flow, boot flow, device tree, software images |

## Purpose

`tg_xbar` connects the three TileLink ports of each core (`l1i`, `l1d`, `mmio`, interfaces.md §2) and an optional host DMA port to four kinds of targets: the two L2 banks, the boot ROM, the device bus and an internal error responder. It routes requests by address (`tg_map_pkg`) and responses by source, and it owns `source[9:6]` (interfaces.md §2.1).

## Shared identifiers (`tg_uncore_pkg`)

**Initiators and `source[9:6]`.** The core drives `source[5:0]` and zero above. The interconnect replaces `source[9:6]` on channels A and C with the initiator's index:

| `source[9:6]` | Initiator | TileLink level |
|---|---|---|
| 0 … 3 | `l1d` of core 0 … 3 | TL-C: these are the coherence **agents**; agent index = `source[7:6]` |
| 4 … 7 | `l1i` of core 0 … 3 | TL-UL `Get` |
| 8 … 11 | `mmio` of core 0 … 3 | TL-UL `Get`, `PutFullData`, `PutPartialData` |
| 12 | host DMA (plan §5.4: coherent A53 access, M5) | TL-UL |
| 13 … 15 | reserved | |

- Up to 4 cores; `NUM_CORES` (2) of them exist today. The L2 directory has one presence bit per agent (plan §6.1: "room for 2 more agents").
- Responses on D and probes on B are routed back by `source[9:6]`; the target echoes the request's full source.

**Sinks.** An L2 bank names its transaction by `sink = {bank, mshr}` (1 + 5 bits; `TL_SINK_W` = 6). `GrantAck` on E is routed by `sink[5]`. Sink `6'h3F` belongs to the error responder; an L2 bank therefore has at most 31 MSHRs.

**Beats.** A message carries data on A (`PutFullData`, `PutPartialData`), C (`ProbeAckData`, `ReleaseData`) and D (`AccessAckData`, `GrantData`); it has `max(1, 2^size / 16)` beats, otherwise one. The package provides `tl_a_beats`, `tl_c_beats` and `tl_d_beats`.

**PLIC sources** (also in the device tree, [soc.md](soc.md) §4):

| Source | Device |
|---|---|
| 1 … 4 | virtio-mmio slots 0 … 3 (M5; tied 0 until then) |
| 10 | UART (the number QEMU `virt` uses, so both device trees agree) |
| 11 | host-control mailbox doorbell ([host.md](host.md)) |
| 16 + h | `merr_o` of hart h (edge-triggered; plan §4.5) |

## Interface

| Port group | Per | Channels |
|---|---|---|
| `l1i_*` | core | A in, D out |
| `l1d_*` | core | A in, B out, C in, D out, E in |
| `mmio_*` | core | A in, D out |
| `hdma_*` | 1, when `HOST_DMA = 1` | A in, D out |
| `l2_*` | L2 bank (2) | A out, B in, C out, D in, E out |
| `rom_*` | 1 | A out, D in |
| `dev_*` | 1 | A out, D in |

All channels are the `tg_tl_pkg` structs with `valid`/`ready` (conventions §3).

## Behaviour

**Routing of requests** (PMA from `tg_map_pkg::pma_of`; bank = `address[6]`):

| Initiator | `PMA_MEM` | `PMA_ROM` | `PMA_DEVICE` | `PMA_NONE` |
|---|---|---|---|---|
| `l1d` (A, C) | L2 bank | error | error | error |
| `l1i` | L2 bank | boot ROM | error | error |
| `mmio` | L2 bank (uncached access: Svpbmt NC/IO, M9) | boot ROM | device bus | error |
| host DMA | L2 bank | error | error | error |

- `l1d` C messages go to the bank of their address; E messages go to the bank in `sink[5]`, or to the error responder for sink `6'h3F`.
- The core faults the "error" cases before issuing them (interfaces.md §3), so the error responder exists for robustness: it answers `Get`/`Put` with `AccessAck[Data]` and `denied = 1` (`corrupt = 1` on data), and an `Acquire` with `Grant`, `denied = 1`, sink `6'h3F`, then swallows the `GrantAck`.

**Arbitration.**
- Each target's A, C and E inputs have a round-robin arbiter over the initiators that can reach it. Each initiator's D input, and each `l1d`'s B input, has a round-robin arbiter over the targets.
- Arbiters lock onto a multi-beat message from its first beat to its last: beats of one message stay contiguous on a channel (interfaces.md §2.1).
- Grants depend only on `valid` and the arbiter's registered state, never on `ready`, so no `valid` depends on a `ready` (conventions §3).

**Deadlock freedom.** TileLink's channel priority A < B < C < D < E (TileLink 1.8.1 §2.2) holds because every channel has its own arbiters and buffers: no channel's progress waits on a lower-priority channel at any point in the interconnect.

**Register slices.** A two-entry skid buffer (`tg_skid`) sits on every target-side A, C and E output and every initiator-side D and B output. Each adds one cycle and registers both `valid` and `ready`, so the arbiters' paths end at flip-flops. The skid entry loads whenever it is empty: its clock enable is a register, not the late incoming `valid` fanned out to every data bit (its contents matter only once it is marked valid, which happens exactly when it loads). `SLICE = 0` removes them for unit tests that want zero latency. `tg_uncore` `XBAR_SLICE` (on by default, as built for 200 MHz) passes that switch to the uncore's crossbar, and `MEM_SLICE` (on) the like one to the memory ports' AXI slices ([uncore-mem.md](uncore-mem.md)): both are for DR-145's study of which slices 125 and 100 MHz still need, with their costs in [soc.md](soc.md) §Reserve levers. `B_SLICE` (default off; a DR-135 reserve item, [soc.md](soc.md) §Reserve levers) adds one more on each L2 bank's B before the crossbar: it cuts the probe handshake (the bank's probe pick and agent, then the per-core B arbiter, which weighs both banks' probes, then `b_ready` back into the bank) at a cycle per probe. `D_SLICE` does the same on each bank's D before the crossbar (the D channel's handshake through the per-initiator D arbiters, which weigh both banks), at a cycle per L2 response. `XBAR_IN_SLICE` puts slices on the cores' request channels between the core ports and the crossbar: bit 0 the caches' A, bit 1 the MMIO A, bit 2 the l1d C, bit 3 the l1d E (the caches' A data, mask and corrupt are constants inside the crossbar, so their slice bits have no loads), at a cycle per message of each channel. All three are off by default, DR-135 reserve items ([soc.md](soc.md) §Reserve levers).

**Slices in DSPs** (DR-136). A slice's main data register can sit in DSP48E2 slices (`tg_skid` `DSP`, through `tg_dsp_reg2`): per 48 bits one DSP, whose OPMODE picks the incoming data or the skid entry and whose clock enable is the slice's load. It is the same register transfer, cycle for cycle, without the fabric's 2:1 select, which costs about a LUT per two bits. `DSP_SKID` sets it per site; `tg_uncore`'s `UNCORE_DSP` carries this mask with the memory paths' slices and the L2 banks' R slices, so a placement check can return any site to fabric without new RTL. `tests/unit/dsp_reg` checks the mapping on the vendor's DSP48E2 model.
- **The default** (`64'h84_0308_0000`) keeps in DSPs only the sites whose DSP form met 200 MHz in every out-of-context placement of the whole uncore that had them in DSPs ([budgets.md](../perf/budgets.md) §4): the device bus's A slice, the L2 banks' C slices, and the memory ports' W slices.
- **At DR-145's 125 MHz** the other sites may be worth their DSPs for area: every site in DSPs saves 1,010 LUTs and 2,062 FFs against the default for 64 more DSPs (budget flow, `st`; per site in [budgets.md](../perf/budgets.md) §4). The worst DSP site missed 200 MHz out of context by 1.55 ns (028a480, the B slices), so at first order 125 MHz's 3 ns more leaves each at least about 1.4 ns out of context; the full chip needs a fit.
- A DSP's input passes through its ALU, which needs more setup than a flip-flop, and its clock-to-out is slower. So the slices fed by arbiters stay in fabric: D, B, the L2 banks' A slices and memory AR. Memory AW, memory R and the L2 banks' R slices each failed in one placement, and stay in fabric too.

### Device bus (`tg_tl_dev`)

It converts the device-bus target's TL-UL traffic (single beat, size ≤ 3, naturally aligned) into one register access at a time:
- request: address, write, 64-bit write data and byte strobes in their address lanes;
- response: 64-bit read data, error.

It decodes the device from the address: ACLINT, PLIC, UART and host control are present. The virtio and debug windows answer `denied` until those devices exist (M5, M9), as do sizes above 3 and misaligned accesses. Devices answer in the cycle after the request. The read data is replicated into both 64-bit halves of the 128-bit beat, so it sits in the lanes TileLink expects for the address (TileLink 1.8.1 §4.6).

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `N_CORES` | `NUM_CORES` | cores attached (1 … 4); M4 builds one |
| `HOST_DMA` | 0 | host DMA initiator present (M5) |
| `SLICE` | 1 | register slices on |
| `DSP_SKID` | all ones | per slice, its main data register in DSPs: bit i the D slice of initiator i, bit 16 + t the A slice of target t, bit 24 + b the C slice of bank b, bit 28 + c the B slice of core c (the E slices stay in fabric) |

Nothing here depends on `TID_W` or the decode width: harts of one core share its ports.

## Timing and area

- **Paths:** at 200 MHz each arbiter is one level of 4–7-input round-robin logic between slices, so the address decode for PMA routing is the longest path. It compares 8 ranges and runs on the request as it leaves the initiator's slice.
- **Area estimate:** about 1.5K LUTs and 3K FFs for 2 cores, most of it slice registers on the wide A, C and D channels. This is part of the plan §8.2 uncore budget (13.3K).
- **Fallback:** if slices on the wide data channels cost too much area, remove the initiator-side D slices and keep the target-side ones.

## Verification

- `tests/unit/xbar`: random TL-UL and TL-C message streams from every initiator type to stub targets that answer in random order with random back-pressure.
  - **Checks:** each message reaches the target its address or sink selects; responses return to the initiator named by `source[9:6]` with `source[5:0]` intact; multi-beat messages are never interleaved; no message is lost or duplicated.
- The full memory path is covered by the L2 random test ([l2.md](l2.md)) and the SoC test ([soc.md](soc.md)).

## Provenance

- TileLink 1.8.1 (SiFive, public specification): message formats, beats, channel priorities, source and sink routing. Implemented as written, with the subset in interfaces.md §2.
- Round-robin arbitration and skid buffers are textbook techniques.
- No other core's or SoC's RTL was read for this unit.
