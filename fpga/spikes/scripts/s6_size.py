#!/usr/bin/env python3
"""Sizes the S6 dual-core dry run (fpga/spikes/rtl/tg_s6_top.sv) for a configuration and a
total LUT target, from plan §8.2/§4.15 budgets and the spike structures' measured sizes.

  python3 -I fpga/spikes/scripts/s6_size.py <cfg> <target>    target: LUTs or a percentage
  -> prints the tg_s6_top generics (-g NAME=VALUE ...) and the budget split

Budget split: the uncore takes UNCORE_LUTS (plan §8.2: 13.3K), the two cores the rest
equally. In each core the real spike structures (S2-S5) are SPIKE_LUTS[cfg] (measured, out
of context); the filler supplies the rest as tiles (LUTS_PER_TILE each, calibrated) and
LUTRAM blocks (the FP register file, ROB, FTQ, free lists, LSQ data: FILL_LUTRAM per core).
Block RAM and DSP per core follow §8.2: 42 BRAM36 (24 in S4/S5) and 54 DSP.
"""
import sys

DEVICE_LUTS = 117_120
UNCORE_LUTS = 13_300
LUTS_PER_TILE = 36.0        # calibrated from a filler-only synthesis (s6_fill_cal)
LUTS_PER_RAM = 80           # tg_s6_fill LUTRAM block: 10 RAM64M8
FILL_LUTRAM = 2_400         # per core
CORE_BRAM_FILL = 18         # TAGE 8, BTB, L2 TLB, ... (S4 has 8, S5 16)
CORE_DSP = 54               # MUL 16, FMA 14, Goldschmidt 24
UNC_LUTRAM = 1_600          # L2 MSHR state and queues (lever R15 keeps them in LUTRAM)

# Synthesised LUTs of S2 (whole scheduler, chosen options) + S3 + S4 + S5 per configuration,
# out of context (fpga/spikes/results); refreshed when the spikes change.
SPIKE_LUTS = {
    # S2 (whole scheduler, DUP_SEL + EARLY_W=24) + S3 + S4 + S5 (LUTRAM micro-BTB, WR=4)
    "st":      5_416 + 5_210 + 2_600 + 2_485,
    "smt2":    7_790 + 5_210 + 2_600 + 2_700,
    "st_w3":   6_100 + 8_713 + 2_600 + 2_700,
    "smt2_w3": 10_500 + 8_713 + 2_600 + 2_900,
}


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    cfg, tgt = sys.argv[1], sys.argv[2]
    total = DEVICE_LUTS * float(tgt[:-1]) / 100 if tgt.endswith("%") else float(tgt)
    core = (total - UNCORE_LUTS) / 2
    fill = core - SPIKE_LUTS[cfg] - FILL_LUTRAM
    if fill <= 0:
        sys.exit(f"target {total:.0f} leaves no room for core filler")
    tiles = int(round(fill / LUTS_PER_TILE))
    nram = FILL_LUTRAM // LUTS_PER_RAM
    unc_nram = UNC_LUTRAM // LUTS_PER_RAM
    unc_tiles = int(round((UNCORE_LUTS - UNC_LUTRAM - 600) / LUTS_PER_TILE))  # 600: L2 datapath
    print(f"-g CORE_TILES={tiles} -g CORE_NRAM={nram} -g CORE_NBRAM={CORE_BRAM_FILL} "
          f"-g CORE_NDSP={CORE_DSP} -g UNC_TILES={unc_tiles} -g UNC_NRAM={unc_nram}")
    print(f"# {cfg}: target {total:.0f} LUTs ({100 * total / DEVICE_LUTS:.1f}%), "
          f"core {core:.0f} = spikes {SPIKE_LUTS[cfg]} + filler {tiles} tiles + "
          f"{nram} LUTRAM blocks; uncore {UNCORE_LUTS}", file=sys.stderr)


if __name__ == "__main__":
    main()
