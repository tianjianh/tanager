#!/usr/bin/env python3
"""Sizes the S6 dual-core dry run (fpga/spikes/rtl/tg_s6_top.sv) for a configuration and a
total LUT target, from plan §8.2/§4.15 budgets and the spike structures' measured sizes.

  python3 -I fpga/spikes/scripts/s6_size.py <cfg> <target> [adj]
     target: LUTs or a percentage; adj: LUTs per core to add to the filler (the S6 runner
     passes half the miss of a run that missed its target)
  -> prints the tg_s6_top generics (-g NAME=VALUE ...) and the budget split; smt2 and the
     3-wide builds get S2_MX=1

Budget split: the uncore takes UNCORE_LUTS (plan §8.2: 13.3K), the two cores the rest
equally. In each core the real spike structures (S2-S5) are SPIKE_LUTS[cfg], as measured
inside the S6 design (they match the out-of-context runs within 2%); the filler supplies the
rest as LUTRAM blocks (the FP register file, ROB, FTQ, free lists, LSQ data: FILL_LUTRAM
per core), its fixed glue (FILL_GLUE) and tiles (LUTS_PER_TILE each).
Block RAM and DSP per core follow §8.2: 42 BRAM36 (24 in S4/S5) and 54 DSP.

Calibration (s6_smt2_85 and s6_smt2_90, synthesis of the same design with 542 and 610 tiles
per core): a tile costs 36.3 LUTs; the filler's fixed part (side units' read folding) is
about 1.85K per core, and the uncore's 1.35K (its glue plus the L2 datapath).
"""
import sys

DEVICE_LUTS = 117_120
UNCORE_LUTS = 13_300
LUTS_PER_TILE = 36.3        # per tile, marginal (s6_smt2_85 vs s6_smt2_90)
FILL_GLUE = 1_850           # per core: the filler's fixed logic
UNC_FIXED = 1_350           # uncore: filler glue 835 + L2 datapath 512
LUTS_PER_RAM = 80           # tg_s6_fill LUTRAM block: 10 RAM64M8
FILL_LUTRAM = 2_400         # per core
CORE_BRAM_FILL = 18         # TAGE 8, BTB, L2 TLB, ... (S4 has 8, S5 16)
CORE_DSP = 54               # MUL 16, FMA 14, Goldschmidt 24
UNC_LUTRAM = 1_600          # L2 MSHR state and queues (lever R15 keeps them in LUTRAM)

# LUTs of S2 (whole scheduler, chosen options) + S3 + S4 + S5 per configuration, inside S6
# where measured (util_hier.rpt of the S6 runs), else out of context (fpga/spikes/results).
# S2: st DUP_SEL + EARLY_W = 24; smt2 and the 3-wide builds add MX, which they need.
SPIKE_LUTS = {
    "st":      5_307 + 5_277 + 2_840 + 2_485,     # out of context (pblock runs)
    "smt2":    8_744 + 5_252 + 2_840 + 2_613,     # s6_smt2_90
    "st_w3":   7_000 + 8_710 + 2_840 + 2_516,     # out of context; S2 st_w3 estimated
    "smt2_w3": 12_047 + 8_653 + 2_678 + 2_582,    # s6_smt2w3_88
}


def main():
    if len(sys.argv) not in (3, 4):
        print(__doc__)
        sys.exit(2)
    cfg, tgt = sys.argv[1], sys.argv[2]
    adj = float(sys.argv[3]) if len(sys.argv) == 4 else 0.0
    total = DEVICE_LUTS * float(tgt[:-1]) / 100 if tgt.endswith("%") else float(tgt)
    core = (total - UNCORE_LUTS) / 2
    fill = core - SPIKE_LUTS[cfg] - FILL_LUTRAM - FILL_GLUE + adj
    if fill <= 0:
        sys.exit(f"target {total:.0f} leaves no room for core filler")
    tiles = int(round(fill / LUTS_PER_TILE))
    nram = FILL_LUTRAM // LUTS_PER_RAM
    unc_nram = UNC_LUTRAM // LUTS_PER_RAM
    unc_tiles = int(round((UNCORE_LUTS - UNC_LUTRAM - UNC_FIXED) / LUTS_PER_TILE))
    mx = " -g S2_MX=1" if cfg != "st" else ""
    print(f"-g CORE_TILES={tiles} -g CORE_NRAM={nram} -g CORE_NBRAM={CORE_BRAM_FILL} "
          f"-g CORE_NDSP={CORE_DSP} -g UNC_TILES={unc_tiles} -g UNC_NRAM={unc_nram}{mx}")
    print(f"# {cfg}: target {total:.0f} LUTs ({100 * total / DEVICE_LUTS:.1f}%), "
          f"core {core:.0f} = spikes {SPIKE_LUTS[cfg]} + filler {tiles} tiles + "
          f"{nram} LUTRAM blocks; uncore {UNCORE_LUTS}", file=sys.stderr)


if __name__ == "__main__":
    main()
