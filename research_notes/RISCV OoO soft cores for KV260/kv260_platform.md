# KV260 / K26 SOM (XCK26 Zynq UltraScale+) as the platform for a soft dual-core RV64 Linux-capable OoO CPU in the PL

## Q1. What are the exact XCK26 PL resources, speed grade and VCCINT, and how does "-2LV" (0.72 V) affect achievable PL Fmax compared with standard -1/-2 grades?

### Takeaway
The XCK26 has ZU5EV-class PL: 117,120 LUTs, 234,240 FFs, 3.5 Mb distributed RAM, 144 BRAM36 (5.1 Mb), 64 UltraRAM (288 Kb each, 18 Mb total) and 1,248 DSP slices. It ships only as XCK26-SFVC784-**2LV**-C/I, a -2 speed-grade "LV" die that runs the PL at **VCCINT = 0.72 V**; the PS rails stay at 0.85 V. At 0.72 V the -2 hard-block Fmax ceilings fall to roughly the level of a standard -1 at 0.85 V, or slightly below it for BRAM/URAM. Those ceilings (BRAM ≥510 MHz, URAM 404–500 MHz, DSP 644 MHz, BUFG 725 MHz) are far above what an OoO CPU will reach. In practice a CPU's Fmax will be set by LUT and routing depth at a "-1-class" timing corner.

### Cited Findings
- **PL resources (DS987 v1.2, 15-Mar-2022, Table 5 "PL Resources")**: 256,200 system logic cells; 234,240 CLB flip-flops; 117,120 CLB LUTs; 3.5 Mb distributed RAM; 144 × 36 Kb block RAMs (5.1 Mb); 64 UltraRAM blocks ("288 Kb dual-port, 72-bit-wide memory with error correction"); 1,248 DSP slices ("27 x 18 signed multiplier with 48-bit adder/accumulator"); 4 GTH (12.5 Gb/s); 1 VCU (H.264/H.265); HDIO 69; HPIO 58 (differential pairs) — [DS987 v1.2 (Mouser copy)](https://www.mouser.com/datasheet/2/903/ds987_k26_som-2329045.pdf)
- Search-indexed copies of later revisions (v1.3, July 2022; v1.5, 30-Jan-2024) show the same PL figures. I did not open v1.5 directly, so this rests on the search-result excerpt — [DS987 (Digi-Key copy)](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/7161/SM-K26-XCL2GI.pdf)
- DS987 v1.2 states: "The K26 SOM is built with the XCK26-SFVC784-2LV device; which has a -2 speed grade and is an LV device (operates at VCCINT = 0.72V)." The XCK26 is "a custom-built Zynq UltraScale+ MPSoC that runs optimally (and exclusively) on the SOM." Commercial (XCK26-C) and industrial (XCK26-I) grades exist, each with an "-ED" (encryption-disabled) ordering variant (SM-K26-XCL2GC, -XCL2GC-ED, -XCL2GI, -XCL2GI-ED) — [DS987 v1.2](https://www.mouser.com/datasheet/2/903/ds987_k26_som-2329045.pdf)
- A hobbyist bring-up repo says the XCK26 is "close to ZU5EV" but has pinout differences, e.g. bank 66 pin count (Vivado/PetaLinux 2021.1 era) — [tomverbeure/kv260_bringup](https://github.com/tomverbeure/kv260_bringup)
- **DS925 rev 1.30 (2026-07-09), Table 1 (speed grades and voltages)**: -2LE is listed at both VCCINT 0.85 V and VCCINT 0.72 V. In the 0.72 V row only VCCINT drops; VCC_PSINTLP, VCC_PSINTFP and VCC_PSINTFP_DDR stay at 0.85 V — [DS925 Available Speed Grades and Operating Voltages](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Available-Speed-Grades-and-Operating-Voltages)
- **Hard-block Fmax, DS925 rev 1.30 (2026-07-09).** Columns are -3 @0.90 V | -2 @0.85 V | -1 @0.85 V | **-2 @0.72 V (K26)** | -1 @0.72 V:
  - Block RAM WRITE_FIRST/NO_CHANGE: 825 | 738 | 645 | **585** | 516 MHz; READ_FIRST: 718 | 637 | 575 | **510** | 460 MHz; ECC without pipeline: 718 | 637 | 575 | **510** | 460 MHz; ECC with pipeline (WRITE_FIRST/NO_CHANGE): 825 | 738 | 645 | **585** | 516 MHz — [DS925 Block RAM and FIFO Switching Characteristics](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Block-RAM-and-FIFO-Switching-Characteristics)
  - UltraRAM with OREG_B=True: 650 | 600 | 575 | **500** | 481 MHz; no pipeline (OREG_B=False): 528 | 500 | 478 | **404** | 389 MHz; ECC read without pipeline: 435 | 400 | 386 | **312** | 303 MHz — [DS925 UltraRAM Switching Characteristics](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/UltraRAM-Switching-Characteristics)
  - DSP48 with all registers: 891 | 775 | 645 | **644** | 600 MHz; two-register multiply without MREG: 635 | 544 | 456 | **440** | 413; without pipeline registers: 483 | 410 | 338 | **323** | 304. A footnote says that at 0.72 V, DSP cascades crossing the clock-region center may run below the specified Fmax — [DS925 DSP48 Slice Switching Characteristics](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/DSP48-Slice-Switching-Characteristics)
  - Global clock buffers (BUFG/BUFGCTRL/BUFGCE/BUFGCE_DIV/BUFCE_LEAF): 891 | 775 | 667 | **725** | 667 MHz; BUFG_GT: 512 MHz. The fetch tool flagged the column layout as ambiguous, but a separate search excerpt independently gave 725 MHz (-2) and 667 MHz (-1) at 0.72 V — [DS925 Clock Buffers and Networks](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Clock-Buffers-and-Networks)
- **PS clocks**: DS925 rev 1.30 gives the -2 grade an APU maximum of 1333 MHz, RPU 533 MHz and GPU 600 MHz (-3: 1500/600/667; -1: 1200/500/600) — [DS925 PS Performance Characteristics](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Processor-System-PS-Performance-Characteristics). DS987 v1.2 agrees: A53 FMAX 1333 MHz, R5F 533 MHz, Mali-400 MP2 600 MHz — [DS987 v1.2](https://www.mouser.com/datasheet/2/903/ds987_k26_som-2329045.pdf). **Conflict:** the tomverbeure README lists 1.5 GHz / 600 MHz / 667 MHz, which are the -3 figures — [kv260_bringup](https://github.com/tomverbeure/kv260_bringup)

### Inferences
- CLB structure: 117,120 LUTs ÷ 8 = 14,640 CLBs, and 234,240 FFs ÷ 16 = 14,640, so the counts are consistent with UltraScale+ CLBs of 8 LUT6 + 16 FF.
- LUTRAM-capable LUTs (not stated in DS987): 3.5 Mb ÷ 64 bits per LUT6-as-RAM ≈ 57.3K–57.6K LUTs, i.e. roughly 7.2K SLICEMs, about half the slices. This is a derived estimate; confirm it with "LUT as Memory (available)" in a Vivado utilization report for xck26-sfvc784-2LV-c.
- Ratio of K26 (-2 @0.72 V) to a standard -2 @0.85 V: BRAM 79%, URAM 83%, DSP 83%, BUFG 94%. Ratio to -1 @0.85 V: BRAM 91%, URAM 87%, DSP ~100%, BUFG 109%. For planning, treat the K26 PL as a "-1-class" device and expect lower Fmax than published results on standard -2 ZU+ boards such as ZCU102/ZCU104.
- The hard-block ceilings do not constrain a CPU at 150–250 MHz. The limits will be LUT logic depth and routing: wakeup/select, rename, bypass muxing and LSU CAMs. A multi-port LUTRAM PRF needs many LUTs because extra read ports require replication.
- Memory budget: 64 URAM = 2.25 MB, enough for a shared L2 data array of up to ~1–2 MB (a 1 MB data array needs about 29 URAM blocks at 4K × 72 b). The 144 BRAM36 are the scarcer resource, needed for L1 I/D arrays, tags, branch predictors and possibly ROB/queue storage.
- LUTs are the binding resource for two OoO cores. 117K LUTs must hold both cores, FPUs, MMUs, L2, the AXI bridge to the PS and the debug/peripheral logic. A common rule of thumb (not from a cited source) is to stay below ~70–80% LUT utilization to close timing at high Fmax.

### Gaps
- Exact SLICEM/LUTRAM count not found in a primary document; DS987 lists only "3.5 Mb".
- DS925 CLB/LUTRAM (distributed RAM) timing at 0.72 V, BUFG_PS Fmax and the maximum PL_CLK frequency were not retrieved.
- DS987 v1.5 (latest) was not opened directly; values come from v1.2 plus search excerpts saying later revisions are unchanged.

## Q2. Does the free Vivado edition support the XCK26, and how did 2026.1 licensing change this?

### Takeaway
Up to Vivado 2025.2 the free Standard edition targets the K26 without a license. The part is hidden from the device catalog, so you pick the Kria board files or create the project with part xck26-sfvc784-2LV-c. Vivado 2026.1 moved to tiered licensing: the free BASIC tier is reported to be Windows-only and to have limited simulation/ILA, and every tier now checks the license at launch. AMD support says Kria SOM kits will include a one-year CORE voucher starting with 2026.1. Today (2026-10-12), a Linux-hosted RTL flow needs either Vivado 2025.2 or a CORE license.

### Cited Findings
- An AMD staff answer (2024) says no license is required for the K26, and that the K26 is not directly visible in the device catalog, so the project must be created via Tcl targeting xck26-sfvc784-2LV-c (search-result excerpt) — [AMD Adaptive Support: "Vivado and Kria board/ K26 SOM?"](https://adaptivesupport.amd.com/s/question/0D52E00007G0tIJSAZ/vivado-and-kria-board-k26-som?language=en_US)
- With 2021.1 tools, Vivado "does not support it directly", so a board is selected instead of a part — [tomverbeure/kv260_bringup](https://github.com/tomverbeure/kv260_bringup)
- AMD's page says Vivado moves to a tiered model starting with 2026.1. Tiers (search-result excerpt): BASIC (free, annual renewal), CORE ($1,200/$1,800 annual), PRO ($2,400/$3,000 annual), ENTERPRISE ($4,395/$5,495 perpetual), GOLD ($10K/$15K perpetual) — [AMD Vivado Licensing Options](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/vivado/vivado-licensing-options.html)
- AMD FAQ (search-result excerpt): Vivado "now checks for the license at the time of tool getting launched", and "if no valid license is found, then Vivado will not launch". From 2026.1 only PRO/ENTERPRISE/GOLD include access to pre-2026.1 versions; BASIC and CORE users must keep their existing license file to keep using older versions — [AMD Licensing FAQ](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/licensing-faq.html)
- TE Labs (20-May-2026) says AMD did not include Linux support in the BASIC/free tier, ILA is no longer fully included from 2026.1, and AMD had "not fully clarified" the details as of 19-May-2026 — [TE Labs](https://www.telabs.dev/articles/vivado-2026-1-licensing-changes). Similar reports: [Slashdot, 23-May-2026](https://hardware.slashdot.org/story/26/05/23/1917255/amd-xilinx-is-excluding-linux-from-the-free-tier-for-its-fpga-dev-tool), [It's FOSS](https://itsfoss.com/news/amd-vivado-bait-and-switch-on-linux-users/), [Tom's Hardware (headline: free versions restricted to Windows)](https://www.tomshardware.com/software/linux/amd-leaves-linux-fpga-users-in-the-lurch-with-controversial-vivado-licensing-update-new-tier-model-restricts-future-free-versions-to-windows)
- In a 2026 thread, a new KV260 buyer found no voucher. An AMD representative replied that "Kria SOM kits will get a CORE license voucher inside the kit, starting with 2026.1 release" and pointed missing vouchers to Customer Service (search-result excerpt) — [AMD Adaptive Support thread](https://adaptivesupport.amd.com/s/question/0D5Pd00001tiKr4KAE/kv260-purchased-new-but-no-vivado-core-license-voucher-included-is-this-expected-with-vivado-20261?language=en_US)
- For comparison, vivado-risc-v supports Vitis/Vivado 2021.2 through 2026.1 and says Nexys Video, Nexys A7 and Arty A7 work with free Vivado, while KC705/VC707/Genesys 2 need a license — [vivado-risc-v README](https://github.com/eugene-tarassov/vivado-risc-v)

### Inferences
- Practical options for a Linux-hosted team:
  - Freeze on Vivado 2025.2, the last free release that ran on Linux per the secondary reports.
  - Use the KV260 kit's 1-year CORE voucher for 2026.1 and later, and budget for CORE renewal (about $1.2–1.8K/year) over a multi-year CPU project.
- Reported BASIC limits on XSIM and ILA make an independent simulation flow (e.g., Verilator) and a CORE license for on-chip debug (ILA/System ILA) more important during CPU bring-up.

### Gaps
- AMD's licensing FAQ and options pages timed out twice, so the BASIC device list (does it include XCK26?), per-tier OS support and voucher terms were verified only through search excerpts and secondary press.

## Q3. Which KV260 carrier I/O can the PL reach, which peripherals are PS-only, and what are the JTAG, clocking and thermal/power limits?

### Takeaway
PL-reachable carrier I/O on the KV260 is minimal:
- one 12-pin Pmod (8 signals on HDIO bank 45, LVCMOS33, ≤250 Mb/s);
- the fan gate/PWM pin;
- three MIPI camera inputs on HPIO bank 66 (IAS0 through the AP1302 ISP, IAS1, and a 2-lane Raspberry Pi connector).

Everything else is PS-only:
- the USB-UART console (PS UART1 on MIO36/37 → /dev/ttyPS1);
- Gigabit Ethernet (GEM3 + TI DP83867, RGMII);
- microSD (SDHCI1, 4-bit, no UHS);
- the USB 3.0 hub (USB0 + USB5744);
- DisplayPort/HDMI (PS DP through an STDP4320 splitter).

There is no PL oscillator, so all PL clocks come from the PS (or an external clock on a Pmod CC pin). The fansink is sized for a 10 W MPSoC application power budget.

### Cited Findings
- The kit is a non-production version of the K26 SOM plus carrier card and thermal solution (fansink) — [UG1089 v1.3, 14-May-2024](https://docs.xibif.ch/_downloads/480ec1217d1ac2bd520e695148cfe86f/KV260_Userguide.pdf)
- **Carrier connectors (UG1089 v1.3)**:
  - J2: Digilent Pmod 2×6
  - J3: direct JTAG ("bypasses the FTDI device")
  - J4: FTDI USB2.0 UART and JTAG
  - J5: HDMI
  - J6: DisplayPort
  - J7: IAS0 (4 MIPI lanes to the OnSemi AP1302 ISP)
  - J8: IAS1 (4 MIPI lanes)
  - J9: Raspberry Pi camera (15-pin, 2 MIPI lanes "directly connected ... to the ... MPSoC HPA bank")
  - J10: RJ45 1 Gb/s
  - J11: microSD
  - J12: 12 V input
  - J13: fan power
  - SW1: firmware update button; SW2: reset (POR_B)
  - 4× USB3.0
  
  — [UG1089 v1.3](https://docs.xibif.ch/_downloads/480ec1217d1ac2bd520e695148cfe86f/KV260_Userguide.pdf)
- The UG1089 v1.3 block diagram shows HDMI 1.4 and DisplayPort 1.2a fed from a "Video Splitter". The KV260 Linux DT overlay comments a DP/HDMI splitter (STDP4320) on I2C and enables only the PS DisplayPort subsystem (zynqmp_dpsub on PS-GTR lanes 0/1) — [UG1089 v1.3](https://docs.xibif.ch/_downloads/480ec1217d1ac2bd520e695148cfe86f/KV260_Userguide.pdf); [Linux zynqmp-sck-kv-g-revB.dtso](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/xilinx/zynqmp-sck-kv-g-revB.dtso)
- **PS peripheral assignment (Linux DT overlay "ZynqMP KV260 revB", torvalds/linux master)**:
  - UART1 on MIO36/37 (1.8 V); UART0 not configured.
  - GEM3 in rgmii-id mode with a TI DP83867 PHY at MDIO address 1 (MIO64–75).
  - SDHCI1, 4-bit, with "no-1-8-v" (UHS needs a level shifter).
  - USB0 (DWC3 host) with USB3 on PS-GTR lane 2 and a Microchip USB5744 hub (I2C 0x2d) (MIO52–63).
  - DP on PS-GTR lanes 1/0.
  - INA260 power monitor at I2C 0x40.
  - GTR reference clocks 27/26/125 MHz.
  - No PL nodes.
  
  — [Linux DT overlay](https://github.com/torvalds/linux/blob/master/arch/arm64/boot/dts/xilinx/zynqmp-sck-kv-g-revB.dtso)
- The console is ttyPS1: "The AMD KV260 has a serial console on ttyPS1" (Yocto patch, 22-Apr-2025) — [Yocto patchwork](https://patchwork.yoctoproject.org/project/oe-core/patch/20250422190053.3244331-3-ross.burton@arm.com). DS987 v1.2 note: "MIO36 and MIO37 are the default Linux console interface pins". Other MIO notes: MIO12 is firmware-update enable; MIO31 is shutdown; MIO35 is the PMU watchdog; MIO31–33 are reserved for the PMU — [DS987 v1.2](https://www.mouser.com/datasheet/2/903/ds987_k26_som-2329045.pdf)
- The USB JTAG/UART is a quad FTDI FT4232H (0403:6011) wired to the FPGA JTAG, the SOM UART, the STDP4320 UART and an EEPROM write-control pin. When the FTDI LS_OE_B pin is asserted the FTDI drives JTAG; otherwise the JTAG connector can take over — [tomverbeure/kv260_bringup](https://github.com/tomverbeure/kv260_bringup)
- **PL pins (LiteX platform for KV260, 2022)**:
  - Part "xck26-sfvc784-2lv-c".
  - Fan on package pin A12 (LVCMOS33).
  - Pmod0 = H12, E10, D10, C11, B10, E12, D11, B11.
  - E12 is the clock-capable HDA16_CC.
  - File comment: "Seems like there are no on-board clock sources for PL when PS is not used so here a clock-capable PMOD connector pin is added as a possible clock input (not tested)."
  
  — [litex-boards platforms/xilinx_kv260.py](https://github.com/litex-hub/litex-boards/blob/master/litex_boards/platforms/xilinx_kv260.py)
- **SOM connector banks (DS987 v1.2)**:
  - HDA = HDIO bank 45 (HDA[20:0], clock-capable HDA00/08/16) on SOM240_1.
  - HPA = HPIO bank 66 (HPA[14:0] + HPA_CLK0, i.e. 16 differential pairs) on SOM240_1.
  - HDB/HDC (banks 43/44, 24 pins each), HPB/HPC (banks 65/64, 21 pairs each) and the GTH quad (bank 224) are on SOM240_2.
  - Max data rates: HDIO 250 Mb/s, HPIO 2.5 Gb/s, PS-GTR 6.0 Gb/s, GTH 12.5 Gb/s.
  - HPA can carry three 4-lane MIPI links.
  - Bank VCCO is supplied by the carrier.
  
  — [DS987 v1.2](https://www.mouser.com/datasheet/2/903/ds987_k26_som-2329045.pdf)
- **Power (UG1089 v1.3)**:
  - A 12 V, 3 A adapter is required.
  - The Pmod rail is 3.3 V with 100 mA capacity.
  - USB ports have 900 mA switches.
  - SOM power telemetry is readable over I2C.
  - "The integrated fansink allows you to exercise the full 10W ... MPSoC application power budget."
  - The fan runs at constant speed by default; variable speed needs an FPGA-based PWM fan controller on "a FPGA HD I/O bank pin".
  
  — [UG1089 v1.3](https://docs.xibif.ch/_downloads/480ec1217d1ac2bd520e695148cfe86f/KV260_Userguide.pdf)
- **Limits (DS987 v1.2)**: VCC_SOM is 5 V (4.75–5.25 V), 4 A maximum. Operating temperature at MPSoC junction: commercial 0–85 °C, industrial −40–100 °C — [DS987 v1.2](https://www.mouser.com/datasheet/2/903/ds987_k26_som-2329045.pdf)
- PS reference clocks: PSS_REF_CLK 33.33 MHz; DP 27 MHz; USB 26 MHz; 125 MHz. The author adds: "I can find no clock that can be used straight by the PL part." He also reports the PL was only usable after the board booted (PetaLinux from SD) in his 2021 setup — [tomverbeure/kv260_bringup](https://github.com/tomverbeure/kv260_bringup)

### Inferences
- The KV260 carrier appears to use only the SOM240_1 connector. All PL-wired carrier functions map to HDA (bank 45) and HPA (bank 66), the three MIPI interfaces match HPA's three-link capacity exactly, and the carrier has no GTH-based interface. If so, HDB/HDC/HPB/HPC and the GTHs are unusable on the KV260 (the KR260 differs). This is inferred, not stated in a fetched document.
- For the soft CPU's external I/O:
  - The only direct PL option is the Pmod (8 × 3.3 V LVCMOS, enough for a USB-UART Pmod, SPI/SD-SPI or JTAG).
  - Ethernet, SD, USB and display must be proxied by the A53s, e.g. via virtio (Q5).
  - The PL can neither drive the HDMI connector nor reach the RJ45 PHY.
- A full-chip CPU bitstream should keep driving the fan pin (A12), at least constant-on, and power should be watched via the INA260/SYSMON. A dense dual-OoO design plus the A53s running Linux could approach the 10 W budget the fansink is rated for.
- Use J3 (direct JTAG) or J4 (FTDI) for Vivado hw_server, ILA and BSCAN-based debug. The PS DAP and the PL TAP sit on the same chain.

### Gaps
- No fetched document explicitly states "KV260 uses only SOM240_1".
- The mapping of FT4232H channels (ttyUSB0–3) to functions (JTAG / SOM UART / STDP4320 UART) was not confirmed.
- Whether the KV260's non-production SOM has eMMC populated is not explicitly stated; UG1089 only says "Production SOMs provide both QSPI and eMMC devices".

## Q4. What PS–PL interfaces exist (widths, maximum clock, coherency), what PL-to-DDR4 latency and bandwidth can be expected, and how is the KV260's DDR4 configured?

### Takeaway
The KV260 has no PL-attached DRAM. The soft CPU must reach the PS's 4 GB DDR4-2400 x64 (19.2 GB/s theoretical) through PS slave ports:
- **HP0–3**: non-coherent; the direct path to DDR.
- **HPC0/1**: I/O-coherent through the CCI; AMD says these have "longer latency to DDR".
- **ACE**: 128-bit, full two-way coherency, 64-byte lines only.
- **ACP**: 128-bit, only 64-B/16-B transactions, ≤4 outstanding; AMD itself discourages it.
- **S_AXI_LPD**: "relatively long latency to DDR"; best for the 256 KB OCM.

All AXI interfaces are limited to **333 MHz** (DS925), so one 128-bit port moves at most 5.33 GB/s per direction. Published ZCU102 measurements (same DDR4-2400 x64 configuration) reach ~75% of theoretical peak, i.e. ~13.7 GB/s with three HP ports at 300 MHz. Loaded read latencies ran 250–10,000 PL cycles. I found no primary source giving the idle PL→DDR read latency in ns.

### Cited Findings
- **KV260/K26 DDR**: "4 GB 64-bit wide, 2400 Mb/s memory", built from four 1 GB DDR4 devices (block diagram); QSPI 512 Mb, eMMC 16 GB on production SOMs; 64 Kb EEPROM — [DS987 v1.2](https://www.mouser.com/datasheet/2/903/ds987_k26_som-2329045.pdf). The LiteX KV260 PS configuration uses DDR4-2400R, a 64-bit bus, 8 Gbit devices, ECC disabled, with DDR address ranges 0x0000_0000–0x7FFF_FFFF and 0x8_0000_0000–0x8_7FFF_FFFF — [litex-boards targets/xilinx_kv260.py](https://github.com/litex-hub/litex-boards/blob/master/litex_boards/targets/xilinx_kv260.py)
- **Interface summary (UG1085 v2.5, 21-Mar-2025, Tables 2-13 and 35-1)**:
  - S_AXI_HP0–3_FPD (AFI_2–5): "Non-coherent paths from PL to FPD main switch and DDR. No L2 cache allocation."
  - S_AXI_HPC0/1_FPD (AFI_0/1): I/O coherent through the CCI and SMMU, no L2 allocation.
  - S_AXI_ACE_FPD: "Two-way coherent path between memory in PL and CCI", 128-bit, 40-bit address.
  - S_AXI_ACP_FPD: I/O coherent with L2 allocation, 128-bit, 40-bit address, 5-bit ID.
  - S_AXI_LPD (AFI_6): non-coherent, into the LPD.
  - PS-to-PL masters: M_AXI_HPM0/1_FPD and M_AXI_HPM0_LPD.
  - HP/HPC/LPD carry 49-bit (virtual) addresses. The device has 40-bit physical and 49-bit virtual address space.
  
  — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)
- **AFI (FIFO-based PL→PS ports), UG1085 v2.5**:
  - PL-side width selectable 32/64/128; "the PS-side AXI interface is always 128 bits".
  - Independent read and write clocks: "Two PL clocks per interface".
  - AXI4→AXI3 conversion "restricted to a maximum of 16" beats per burst.
  - Command acceptance of 8; "maximum number of outstanding unique IDs ... eight per port, per channel".
  - Issuing capability "up to a maximum of 16" per port per channel.
  - "128 x 128-bit deep read and write data FIFOs".
  - FIFO fill levels (RCOUNT/WCOUNT/RACOUNT/WACOUNT) and AxQOS are exported to the PL.
  - "The PS AFI is not capable of generating early write responses itself."
  
  — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)
- **Port asymmetry**: "S_AXI_HP1_FPD and S_AXI_HP2_FPD interfaces share exclusive access to an AXI Port Interface (XPI 4). This facilitates high throughput and relatively low-latency access from the PL directly to the DDR memory." HP0 shares a DDR controller XPI port with the DisplayPort master; HP3 shares one with the FPD DMA — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)
- **HPC coherency**: snooping requires a non-zero AxCACHE[3:2] and enabling snoops in the CCI (Snoop_Control_Register_S3). "Because both the S_AXI_HPC0_FPD and S_AXI_HPC1_FPD interfaces are routed through the CCI before reaching the DDR memory controller, these two ports have a longer latency to DDR." All high-performance FPD interfaces pass through the SMMU — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)
- **ACE**:
  - Configurable as ACE-Lite (I/O coherency) or full ACE.
  - "For full coherency, transactions can only have a 64-byte cache line size."
  - "The PL-ACE master cannot allocate into the APU L2 cache however, it has coherent access to L2 cache."
  - When used as ACE-Lite or AXI4 the master must keep bursts ≤16 beats, because the ACE→DDR path cannot split longer bursts ("lockups ... starvation ... very high latencies" otherwise).
  - Unused snoop channels must be disabled.
  
  — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)
- **ACP**:
  - Accepts only 64-byte aligned 4-beat INCR or 16-byte single-beat transactions, with restricted AxCACHE values.
  - "Supports up to four outstanding transactions", with one per AXI ID.
  - Bypasses the MMU and SMMU (40-bit physical).
  - "Adversely affects CPU cluster performance."
  - "AMD recommends using either an S_AXI_HPCx_FPD port or the ACE port ... over ACP."
  - Security caution: the ACP has unrestricted L2 access.
  
  — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)
- **S_AXI_LPD**: the "Preferred interface for PL access to the OCM and TCMs with the lowest latency", but "this port has a relatively long latency to DDR". The OCM is 256 KB at 0xFF_FFFC_0000 — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)
- **QoS**: three traffic classes (high priority/low latency, isochronous, best effort). The low-latency class is "primarily intended for CPU (or CPU like) latency critical traffic, and is not recommended for use by transfers with an AXI interface that includes a FIFO". The HP ports "are designed to provide a latency guarantee for DDR memory controller accesses" — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)
- AMD on latency variability: "The access latency through the multi-ported DDR memory controller in the PS is expected to vary across a wide range and can vary under loaded conditions" — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)
- **Signalling resources (UG1085 v2.5)**: 16 PL→PS interrupts (GIC SPIs 121–128 and 136–143); 7 PL→PS IPI channels; 4 PS→PL IPI channels; 32-bit PMU GPI/GPO to and from the PL; per-core FIQ/IRQ inputs — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)
- **Maximum clocks (DS925 rev 1.30, Table 6 "PS-PL Interface Performance")**: FAXICLK ("Maximum AXI interface performance") 333 MHz; flow-control DMA 333 MHz; DisplayPort live video 300 MHz; EMIO GEM 125 MHz; EMIO SD 25 MHz — [DS925 PS Performance Characteristics](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Processor-System-PS-Performance-Characteristics)
- **Measured bandwidth/latency (Manev, Vaishnav, Koch, "Unexpected Diversity: Quantitative Memory Analysis for Zynq UltraScale+ Systems", FPT 2019, accepted manuscript)**. Setup: ZCU102 (XCZU9EG-2, 4 GB DDR4-2400 x64) and Ultra96 (LPDDR4-1066 x32); bare-metal; SMMU bypassed; 128-bit ports; 100/300 MHz. Results:
  - Effective throughput was "only 75% and 92.5% of theoretical maximum" (ZCU102 / Ultra96).
  - 128- and 192-byte bursts were often optimal.
  - Best ZCU102 result: 13,721 MB/s with HP0,1,3 or HP0,2,3 at 192-B bursts at 300 MHz.
  - Write-only throughput exceeds read-only by 11–13%.
  - "The average read latency in all single AXI configurations on both boards was found between 250 and 10,000 clock cycles and scales linearly with respect to burst size" (saturating traffic, not idle).
  - Average read latency rose about 2× in 3- and 4-port configurations on ZCU102.
  - HP1 and HP2 share a DDR port.
  - Maximal AXI read inactivity was ~200–300 cycles (refresh was hidden).
  - Single PS AXI port theoretical: 9.6 GB/s at 300 MHz and 3.2 GB/s at 100 MHz (read + write).
  - At 100 MHz with all 4 ports: 8,800 MB/s.
  
  — [FPT'19 paper](https://pure.manchester.ac.uk/ws/files/137731499/FPT19_paper_14.pdf)
- **AMD SPA tutorial (2021.1, ZCU102, DDR4-2400 x64 = 19,200 MB/s theoretical)**: 4Kp60 video traffic (1424 MB/s) over HP ports with the ATG at 250 MHz was achieved with no software slowdown. Eight channels at ~2,000 MB/s each (83.3% of peak) was not achievable and made the BEEBS benchmark 76% slower. Reads take priority over writes under congestion, and HP1/HP2 delivered less because they share one DDR input port — [Xilinx Embedded Design Tutorials: Evaluating High-Performance Ports](https://xilinx.github.io/Embedded-Design-Tutorials/docs/2021.1/build/html/docs/User_Guides/SPA-UG/docs/6-evaluating-high-performance-ports.html)
- J. Marjanovic's blog timed single transactions (cycles from address to full response) through an AXI proxy. Per a search-result excerpt, latency on the cached interfaces (ACP, HPC) was "very uniform", while HP to DDR4 was higher and more variable. The numbers are only in graphs; the page was unreachable (TLS/socket errors), so values were not extracted — [j-marjanovic.io](https://j-marjanovic.io/exploring-the-ps-pl-axi-interfaces-on-zynq-ultrascale-mpsoc.html)

### Inferences
- **Bandwidth is not the bottleneck; latency is.** One 128-bit port gives 16 B × 333 MHz = 5.33 GB/s per direction (4.0 GB/s at 250 MHz). Two cores at 150–200 MHz refilling 64-B lines (4 beats at 128-bit, well within the 16-beat cap) are far below that. The CPU's memory system needs latency tolerance: a non-blocking L2 with roughly 8–16 MSHRs per port (matching the AFI's 8-ID / 16-outstanding limits), plus a prefetcher.
- **Port choice for the main memory path.** HP1 or HP2 have the "exclusive" XPI with "relatively low-latency access", but avoid using both together since they share XPI 4. HP0 is fine if the PS DisplayPort is idle; HP3 competes with FPD DMA. Use HPC only where hardware I/O coherency is needed, because of the CCI latency.
- **Coherency with the A53 Linux side** (for virtio rings, console buffers, boot handoff):
  - HPC gives one-way coherence: soft-core reads snoop A53 caches, but the A53 cannot snoop the soft core's L2. Shared regions must therefore be uncached or write-through on the RISC-V side, or explicitly flushed.
  - ACE would make the soft L2 a full CCI participant: the PL cache becomes snoopable, 64-B lines only, ≤16-beat bursts. It is attractive but requires implementing ACE snoop channels.
  - ACP is unsuitable as a main memory port.
- **Addressing.** Soft-core masters must emit more than 32 address bits to reach the upper 2 GB at 0x8_0000_0000. A simple approach is to translate the soft core's physical map, e.g. RISC-V 0x8000_0000 onwards, onto a reserved PS-DDR window inside the AXI bridge.
- **Isolation.** The SMMU, which every HP/HPC path traverses, and the DDR XMPUs can sandbox the soft core inside its reserved window, protecting the A53 Linux from soft-core bugs. FPT'19 bypassed the SMMU to avoid overhead, so measure the cost.
- **QoS.** Raising AxQOS on the CPU refill port can cut queueing latency when the A53s are busy. UG1085, however, says the high-priority class is not recommended for FIFO-based ports, so evaluate it empirically.

### Gaps
- No primary source gave the **idle (unloaded) PL→PS-DDR read latency in ns** for HP, HPC, ACE or ACP. Marjanovic's graphs were unreachable, the FPT'19 latencies are for saturating traffic, and the shared web-search budget ran out before other papers could be found. Recommendation: measure on the KV260 with an AXI probe (AR valid to RLAST) at the target PL clock, with the A53s both idle and loaded.
- The bandwidth numbers come from ZCU102 (DDR4-2400 x64 SODIMM); no KV260-specific measurement was found.

## Q5. What boot and loading flows are available: KV260 firmware and A53 Linux, runtime PL loading, reserving DDR, loading soft-core images, releasing reset, console options, and virtio over shared memory?

### Takeaway
The KV260 boots A/B boot firmware from QSPI (FSBL, PMU FW, TF-A, U-Boot) and then Linux from the microSD card. Kria Ubuntu 24.04 is recommended for new users, Ubuntu 22.04 for the example apps, and PetaLinux is listed through 2026.1. PL designs load at runtime through xmutil → dfx-mgr, using a .bit.bin, a .dtbo and shell.json under /lib/firmware.

A soft-core system can follow an "A53 as host" pattern:
1. Carve out DDR with a reserved-memory (no-map) node in the boot device tree.
2. Load OpenSBI, the kernel, the DTB and the initramfs into that window from Linux, via UIO/mmap or a remoteproc driver.
3. Release the core's reset through an AXI GPIO.
4. Provide console, storage and network through one of:
   - an AXI UART bridged to the A53 (the NutShell pattern);
   - a Pmod USB-UART;
   - virtio-mmio devices whose back-ends run on the A53 (the OpenAMP "hypervisorless virtio" pattern).

### Cited Findings
- **Boot chain (UG1089 v1.3)**:
  - Primary boot device: QSPI on the SOM, holding BOOT.BIN (FSBL, PMU FW, ATF, U-Boot) in an A/B configuration with fallback to the last known good image.
  - Boot mode set to QSPI32.
  - U-Boot hands off to the SD card, which holds the Linux image, the DTBs (e.g., som.dtb), boot.scr and the root filesystem.
  - "You must burn the SD card image ... for the kit to successfully boot to Linux"; SDHC cards are recommended.
  
  — [UG1089 v1.3](https://docs.xibif.ch/_downloads/480ec1217d1ac2bd520e695148cfe86f/KV260_Userguide.pdf)
- **Linux options (Kria docs, page updated 12-Aug-2026)**:
  - Kria Ubuntu 24.04 is recommended for new evaluators; its only listed app is BIST.
  - Ubuntu 22.04 is recommended to run the example applications (Smart Camera, AI Box ReID, Defect Detect, NLP SmartVision, DFX and others).
  - Embedded Linux (PetaLinux) is listed for 2021.1, 2022.1–2025.2 and 2026.1.
  
  — [Kria KV260 Linux boot page](https://xilinx.github.io/kria-apps-docs/kv260/2022.1/build/html/docs/linux_boot.html)
- Legacy KV260 kits require the 2022.1 boot-firmware update before booting Ubuntu 22.04 (search-result excerpt) — [element14: Kria firmware update for booting Ubuntu 22.04](https://community.element14.com/technologies/fpga-group/b/blog/posts/kria-kv260-kr260-firmware-update-for-booting-ubuntu-22-04)
- **Runtime PL loading (Kria docs 2022.1, "On-target Utilities and Firmware")**:
  - xmutil is a wrapper; it calls dfx-mgr for loadapp/unloadapp/listapps.
  - dfx-mgrd is a daemon supporting flat and DFX designs.
  - Each app needs a .bit.bin, a .dtbo and shell.json; a .xclbin is needed only for XRT/Vitis designs.
  - Files live in /lib/firmware/<company>/<app> (non-"xilinx" folders from 2022.1 via daemon.config) and are detected through inotify.
  - A .bit becomes a .bit.bin with bootgen ("-process_bitstream bin").
  - Shell types: XRT_FLAT, XRT_DFX, PL_FLAT, PL_DFX, AIE (the page says only XRT_FLAT was usable at the time).
  - The KV260 rootfs (mmcblk1p2) is not auto-expanded; use resize-part.
  
  — [Kria on-target utilities](https://xilinx.github.io/kria-apps-docs/creating_applications/2022.1/build/html/docs/target.html)
- **DT overlay generation (Kria docs, updated 10-Apr-2025)**: XSCT with the Device Tree Generator turns the XSA into pl.dtsi (with the dt_overlay option), which DTC compiles to a .dtbo. "Generated .dtsi files usually need modification." The Yocto class fpgamanager_custom is deprecated in 2024.1, and dfx_user_dts is supported from 2024.1 — [Kria DTSI/DTBO generation](https://xilinx.github.io/kria-apps-docs/creating_applications/2022.1/build/html/docs/dtsi_dtbo_generation.html)
- **reserved-memory binding (devicetree-org dt-schema)**:
  - Regions under /reserved-memory are either static (reg) or dynamic (size/alignment/alloc-ranges).
  - no-map: the OS "must not create a virtual mapping of the region as part of its standard mapping of system memory" and must not allow speculative access except under the owning driver's control.
  - reusable regions may be borrowed by the OS; reusable cannot be combined with no-map.
  - Devices reference a region via memory-region.
  
  — [dt-schema reserved-memory.yaml](https://github.com/devicetree-org/dt-schema/blob/main/dtschema/schemas/reserved-memory/reserved-memory.yaml)
- **UIO (Linux kernel docs)**: user space mmap()s /dev/uioX, with each map index × page size as the offset and maps described in sysfs. A blocking read() waits for an interrupt and returns a 32-bit count; a write() re-enables the interrupt through irqcontrol. uio_pdrv_genirq binds to DT nodes when the module parameter of_id equals the node's compatible string — [Kernel UIO HOWTO](https://www.kernel.org/doc/html/latest/driver-api/uio-howto.html)
- **remoteproc (Linux kernel docs)**:
  - The core loads ELF32/ELF64 segments to the device addresses given in the firmware.
  - The platform driver supplies start/stop, plus kick for virtio/rpmsg.
  - The firmware's resource table can request carveouts, devmem mappings, a trace buffer and vdev entries (virtio IDs, features, vrings); the framework creates virtio devices from the vdev entries.
  - The boot address is the ELF entry point.
  
  — [Kernel remoteproc docs](https://www.kernel.org/doc/html/latest/staging/remoteproc.html)
- **NutShell (OSCPU RV64) on Zynq boards** (README lists zedboard, zcu102, sidewinder, ultraZ, axu3cg): the PS runs a "ddr-loader" that loads the RISC-V binary (which must start at 0x80000000) into NutShell memory. The NutShell UART is reached from PS Linux as /dev/ttyUL1 using minicom. The bitstream goes into BOOT.BIN on SD. Vivado 2019.1 — [NutShell README](https://github.com/OSCPU/NutShell)
- **Hypervisorless virtio (OpenAMP), ZCU102 under Xilinx QEMU with 2020.2 packages**:
  - A53 PetaLinux runs a physical-machine monitor built on kvmtool ("lkvm ... --transport mmio") that hosts the virtio back-ends.
  - Zephyr on the R5 runs virtio front-ends (virtio-rng, virtio-net) over virtio-mmio.
  - The two sides share a 16 MB region (--shmem-addr 0x37000000, --shmem-size 0x1000000).
  - A ZCU102 mailbox module (user-mbox.ko) and an rpu_0_ipi device appear, which suggests IPI-based notification.
  
  — [danmilea/hypervisorless_virtio_zcu102](https://github.com/danmilea/hypervisorless_virtio_zcu102)
- **vivado-risc-v boot/console (non-Zynq boards)**:
  - A bootrom SD bootloader loads boot.elf (OpenSBI + U-Boot) from the SD card's DOS partition.
  - UART console at 115200; SSH after boot.
  - JTAG RISC-V debug through a BSCAN block.
  - The SD controller runs SD High Speed (~25 MB/s); Ethernet uses verilog-ethernet.
  
  — [vivado-risc-v README](https://github.com/eugene-tarassov/vivado-risc-v). The maintainer notes Linux can boot with U-Boot loaded over JTAG and the rootfs on NFS, used on boards without SD such as VCU1525/Alveo (search-result excerpt) — [vivado-risc-v Discussion #186](https://github.com/eugene-tarassov/vivado-risc-v/discussions/186)
- LiteX's CPU JTAG-debug helper rejects Zynq/ZynqMP devices — [linux-on-litex-vexriscv README](https://github.com/litex-hub/linux-on-litex-vexriscv)
- UG1085 v2.5 lists the doorbell and interrupt resources (16 PL→PS IRQs, IPI channels in both directions, PMU GPI/GPO), and the PL clock-throttle "PLx_THR_STOP" can stop a PL clock for PL logic debug — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)

### Inferences
- **A workable KV260 flow** (synthesized from the sources above):
  1. Keep the stock QSPI firmware and A53 Ubuntu/PetaLinux.
  2. Add a /reserved-memory no-map carveout to the boot DT that U-Boot passes to Linux, e.g. part or all of the upper 2 GB at 0x8_0000_0000.
  3. Package the CPU bitstream as a dfx-mgr app (PL_FLAT/XRT_FLAT). Its .dtbo exposes an AXI GPIO for reset and clock-enable (as UIO), an AXI UART Lite or 16550, and a mailbox/doorbell.
  4. From user space or a small kernel driver, copy OpenSBI (fw_jump or fw_payload), the Linux Image, the RV64 DTB and an initramfs into the carveout, then deassert reset.
- **A custom remoteproc driver is the "productized" variant.** It brings ELF loading, carveouts and vdev/virtio plumbing (virtio-console, rpmsg) for free, but it expects the firmware to carry a resource table.
- **Reserved memory must exist at boot.** The kernel builds its memory map early, so runtime overlays loaded by dfx-mgr can add devices but should not be relied on to carve DRAM. This is an inference from the binding's purpose; it was not explicitly stated in a fetched Kria document.
- **Console options:**
  - **(a)** PL UART (AXI UART Lite/16550) mapped through M_AXI_HPM0/1_FPD. It appears on the A53 as /dev/ttyULx or /dev/ttySx, reachable over SSH; this is NutShell's /dev/ttyUL1 pattern.
  - **(b)** Pmod USB-UART on the HDA pins (3.3 V); independent of the A53, useful for very early bring-up.
  - **(c)** Shared-memory ring plus doorbell IRQ, exposed by an A53 daemon as a pty, or virtio-console over shared memory.
  - **(d)** A BSCANE2 JTAG UART. Note that LiteX's helper rejects ZynqMP and Vivado hw_server would contend for the FT4232H JTAG channel.
- **Storage and network:** because the PL has no SD or Ethernet pins on the KV260, use virtio-blk backed by an image file on the A53's SD card and virtio-net bridged to the A53's GEM3 (tap/bridge), or NFS root over that bridge. The hypervisorless-virtio work (kvmtool PMM + virtio-mmio + shared memory) is the closest published template.
- **Coherence for virtio rings:** either place them in a region the A53 maps non-cacheable, or have the soft core access them through HPC (it snoops A53 caches) with write-through/uncached RISC-V-side attributes for those pages (see Q4).
- **Debug hook:** the PS PL-clock throttle (counted pulses, PLx_THR_STOP) offers a hardware single-step or freeze of a clock domain, but only if the CPU is clocked directly from a PL_CLK rather than through an MMCM, which would lose lock.

### Gaps
- fpgautil / FPGA-manager CLI documentation was not retrieved; the Xilinx wiki page did not render.
- No KV260-specific worked example of reserved-memory plus soft-core loading, and no remoteproc driver for a soft RISC-V on ZynqMP, was found before the search budget ran out.
- The notification mechanism in hypervisorless virtio is only inferred (mailbox/IPI module names).

## Q6. What prior art exists for soft RISC-V Linux on Zynq UltraScale+ boards (KV260, KR260, Ultra96, ZCU102/104/106), with Fmax, utilization, boot and console/storage approaches?

### Takeaway
I found no verified public project booting Linux on a soft RISC-V on the KV260 itself.
- LiteX's KV260 target uses the A53 as the CPU.
- linux-on-litex-vexriscv lists ZCU104 as tested, but the LiteX ZCU104 target uses the PL-side DDR4 SODIMM at 125 MHz, which the KV260 lacks.
- NutShell (RV64) lists ZCU102 and uses the "PS as host" pattern (PS loader plus PS-bridged UART).
- vivado-risc-v (Rocket/BOOM) and CVA6 have no ZU+ board targets.

Their published clocks on other Xilinx parts calibrate expectations: Rocket 100–160 MHz, BOOM 31–50 MHz, NaxRiscv RV64 137 MHz on Artix-7 -3. MicroBlaze V reaches 504 MHz on the fastest ZU+ grade.

### Cited Findings
- **LiteX xilinx_kv260 target (2022, Ilia Sergachev)**: provides "enough support to run LiteX BIOS on Cortex-A53 core #0". The default CPU type is zynqmp, with sys_clk 100 MHz taken from the PS clock domain; PS UART1 on MIO36–37 at 115200; Pmod extensions supported — [litex-boards targets/xilinx_kv260.py](https://github.com/litex-hub/litex-boards/blob/master/litex_boards/targets/xilinx_kv260.py)
- **linux-on-litex-vexriscv**: the tested-board list includes zcu104, the only ZU+ board in the list. The CPU is VexRiscv-SMP (RV32). It needs ≥32 MB RAM (8 MB with an SD or NFS rootfs) and can load Linux by serial (litex_term), TFTP, SD or NFS; the kernel console is hvc0 — [linux-on-litex-vexriscv README](https://github.com/litex-hub/linux-on-litex-vexriscv)
- **LiteX xilinx_zcu104 target**: sys_clk 125 MHz; LiteDRAM through USPDDRPHY on DDR4 (MTA4ATF51264HZ, 1 GiB) in the PL; "Zynq PS: Not used" — [litex-boards targets/xilinx_zcu104.py](https://github.com/litex-hub/litex-boards/blob/master/litex_boards/targets/xilinx_zcu104.py)
- **vivado-risc-v (eugene-tarassov)**:
  - Boards: VC707, KC705, Genesys 2, Nexys Video, Nexys A7-100T, Arty A7-100T; releases add Alveo U200/U250, VCU1525, X3522PV and SITLINV XC7K325T. No ZU+ boards.
  - Configs: Rocket64 b1/b2/b2l2/b2gem/b4l2w/b4/b8; BOOM w1 (1-wide small), x1 (2-wide medium), y1 (3-wide large), z1 (4-wide mega).
  
  — [README](https://github.com/eugene-tarassov/vivado-risc-v); [releases](https://github.com/eugene-tarassov/vivado-risc-v/releases)
- **vivado-risc-v clocks per board/config (rocket-freq file)**:
  - VC707: Rocket 100 MHz (b4–b9: 80; l2 variants: 62.5); BOOM x1 50 MHz; other BOOM 31.25.
  - Genesys 2 / KC705: similar (BOOM w1 80 MHz).
  - VCU1525/U200/U250 (VU9P): Rocket 125 MHz; BOOM 31.25.
  - X3522PV: Rocket32s1 200 MHz, Rocket64b1 160 MHz, BOOM 40.
  - Default for other boards: Rocket 50 MHz, BOOM 20.
  
  — [vivado-risc-v board/rocket-freq](https://github.com/eugene-tarassov/vivado-risc-v/blob/master/board/rocket-freq)
- **CVA6** FPGA constraint files: ariane.xdc, genesys-2, kc705, nexys_video, vc707, vcu118. No ZU+ board in the listing — [cva6 corev_apu/fpga/constraints](https://github.com/openhwgroup/cva6/tree/master/corev_apu/fpga/constraints)
- **NutShell (OSCPU, RV64)**: boards zedboard, zcu102, sidewinder, ultraZ and axu3cg (the last two "not available to the public"); PS-side ddr-loader; /dev/ttyUL1 console on the PS; Vivado 2019.1. The README does not state the clock frequency or the DDR port — [NutShell README](https://github.com/OSCPU/NutShell)
- **ZynqParrot (BlackParrot / HammerBlade)**: "enables rapid design iteration of Accelerators on Zynq FPGAs" (co-simulation and co-emulation meta-repo). The README gives no board list or memory-path details — [zynq-parrot](https://github.com/black-parrot-hdk/zynq-parrot)
- **NaxRiscv** (performance page, 2022; all on Artix-7 speed grade 3):

  | Config | DMIPS/MHz | CoreMark/MHz | Embench | IPC | KLUT | KFF | BRAM | DSP | Fmax |
  |---|---|---|---|---|---|---|---|---|---|
  | RV32 dual-issue (config A) | 2.93 | 5.02 | 1.67 | 1.65 Dhrystone / 1.28 CoreMark / 1.42 Embench | 13.3 | 10.3 | 12 | 4 | 155 MHz |
  | RV64 | 2.94 | 4.94 | 1.84 | not reported | 17.9 | 12.5 | 12 | 16 | 137 MHz |

  — [NaxRiscv performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html). The README describes an OoO core ("2 decode, 3 execution units, 2 retire") with SV32/SV39, 3-cycle load-to-use, Linux/Buildroot on hardware via LiteX (e.g., Nexys Video), and Xilinx Series 7 as the reference target — [NaxRiscv README](https://github.com/SpinalHDL/NaxRiscv)
- **VexiiRiscv**: in-order single/dual issue, RV32/64; up to 5.24 CoreMark/MHz and 2.50 DMIPS/MHz; a quad-core Debian demo on FPGA. No Fmax or board data in the README — [VexiiRiscv README](https://github.com/SpinalHDL/VexiiRiscv)
- **MicroBlaze V maximum frequencies (UG1629, 2026.1, released 2026-07-31; fastest speed grade per family)**: Zynq UltraScale+ 504 MHz; Kintex UltraScale+ 558; Virtex UltraScale+ 540; Artix UltraScale+ 508; Artix-7 227; Zynq-7000 225 — [UG1629 Maximum Frequencies](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Maximum-Frequencies)
- Hypervisorless virtio on ZCU102 is prior art for the virtio-over-shared-memory I/O model (Q5) — [hypervisorless_virtio_zcu102](https://github.com/danmilea/hypervisorless_virtio_zcu102)

### Inferences
- **The KV260 forces the "PS DDR via HP/HPC/ACE" architecture** used by NutShell and other Zynq-hosted projects, not the LiteDRAM/MIG approach of LiteX ZCU104, vivado-risc-v or CVA6. Porting any of those requires replacing their DRAM controller with an AXI bridge into a PS port, plus a PS-side loader.
- **Fmax calibration for the clean-room core on XCK26:**
  - Mature OoO RTL generators run at 31–50 MHz (BOOM in vivado-risc-v, conservative settings) up to ~137–155 MHz (NaxRiscv, Artix-7 -3).
  - MicroBlaze V shows ZU+ ≈ 2.2× Artix-7 for a simple pipeline at the fastest grades.
  - K26 (-2 @0.72 V) is slower than ZU+ -3: about 0.7–0.8× on hard-block metrics (Q1).
  - A well-pipelined 2-wide OoO RV64 on XCK26 therefore plausibly targets roughly 150–200 MHz. This is an estimate to validate with early synthesis.
- **IPC benchmark context:** NaxRiscv's published IPCs (RV32 config: Dhrystone 1.65, CoreMark 1.28, Embench 1.42) are the bar. On the KV260 every core sees the same long PS-DDR path, so IPC gains on memory-bound code will depend heavily on L2 size (URAM) and prefetching.

### Gaps
- No verified data was found on CVA6, BOOM, XiangShan, NaxRiscv or VexiiRiscv running on KV260/KR260/Ultra96/ZCU102/104/106 (Fmax, utilization, boot method). The web-search budget was exhausted before targeted searches for those ports could run.
- NutShell's ZU+ clock frequency and memory port are not stated in its README.

## Q7. What timing-closure considerations apply to CPU designs on Zynq UltraScale+: typical soft-CPU Fmax, LUTRAM/BRAM/URAM timing, and clocking from the PS pl_clk versus an MMCM?

### Takeaway
On the K26, the hard blocks at -2 @0.72 V (BRAM 510–585 MHz, URAM 404–500 MHz, DSP 644 MHz, BUFG 725 MHz) leave ample margin at 150–250 MHz, so the CPU's critical paths will be LUT/route-dominated. The PL has no dedicated oscillator, so CPU clocks must be derived from the PS PL_CLK outputs, normally passed through an MMCM, or from an external clock on the Pmod's clock-capable pin. The PS–PL AXI side can run asynchronously up to 333 MHz, because the AFI already performs the PL↔PS clock-domain crossing with separate read and write PL clocks.

### Cited Findings
- **Fmax ceilings at -2 @0.72 V (DS925 rev 1.30)**: BRAM 585 MHz (WRITE_FIRST/NO_CHANGE) and 510 MHz (READ_FIRST); URAM 500 MHz with the output register and 404 MHz without (312 MHz with ECC and no pipeline); DSP 644 MHz fully pipelined and 323 MHz with no pipeline registers; global clock buffers 725 MHz. At 0.72 V, DSP cascades crossing the clock-region center may run below the specified Fmax — [DS925 BRAM](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Block-RAM-and-FIFO-Switching-Characteristics); [DS925 URAM](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/UltraRAM-Switching-Characteristics); [DS925 DSP](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/DSP48-Slice-Switching-Characteristics); [DS925 Clock Buffers](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Clock-Buffers-and-Networks)
- **PS→PL clocks (UG1085 v2.5)**: "There are four clock outputs to the PL from independent clock generators", each "with two clock dividers ... plus the clock throttle feature". They are "asynchronous to each other and all other clocks". Throttle registers (PLx_THR_CTRL/CNT) can emit a counted number of pulses, and PLx_THR_STOP from the PL "stops the PL clock during PL logic debug". The signal table lists PL_CLK{0:3} (×4, from the LPD) plus 2 F2P auxiliary reference clocks — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft)
- AFI ports provide "Asynchronous clock frequency domain crossing for all AXI interfaces between the PL and PS. Two PL clocks per interface, one for read and one for write" — [UG1085 v2.5](https://docs.amd.com/api/khub/documents/xzMsp_c5sG9J6A3u7NkJYQ/content?Ft-Calling-App=ft). The AXI interface maximum is 333 MHz — [DS925 rev 1.30 Table 6](https://docs.amd.com/r/en-US/ds925-zynq-ultrascale-plus/Processor-System-PS-Performance-Characteristics)
- **KV260 clock sources**: LiteX notes no on-board PL clock when the PS is unused and offers Pmod pin E12 (HDA16_CC) as an external clock input — [litex-boards platform](https://github.com/litex-hub/litex-boards/blob/master/litex_boards/platforms/xilinx_kv260.py). LiteX's KV260 target clocks its system from the PS clock domain at 100 MHz — [litex-boards target](https://github.com/litex-hub/litex-boards/blob/master/litex_boards/targets/xilinx_kv260.py). The tomverbeure bring-up set PL0/PL1 to 100 MHz and derived 50–600 MHz clocks with a Clocking Wizard — [kv260_bringup](https://github.com/tomverbeure/kv260_bringup)
- **Soft-CPU Fmax reference points**: MicroBlaze V 504 MHz on the fastest Zynq US+ grade ([UG1629 2026.1](https://docs.amd.com/r/en-US/ug1629-microblaze-v-user-guide/Maximum-Frequencies)); NaxRiscv RV64 137 MHz on Artix-7 -3 ([NaxRiscv performance](https://spinalhdl.github.io/NaxRiscv-Rtd/main/NaxRiscv/performance/index.html)); Rocket 125 MHz and BOOM 31.25 MHz on VU9P boards, Rocket64b1 160 MHz on X3522PV ([vivado-risc-v rocket-freq](https://github.com/eugene-tarassov/vivado-risc-v/blob/master/board/rocket-freq)).

### Inferences
- **Clocking plan:**
  - Feed PL_CLK0 (e.g., 100 MHz) into an MMCM to synthesize the CPU clock, and optionally a second, faster AXI/L2-bridge clock up to 333 MHz.
  - Rely on the AFI's built-in async CDC so the core clock can be tuned independently of the PS port clock.
  - Keep a direct PL_CLK-clocked "debug domain" if the throttle single-step feature is wanted.
  - PL_CLK frequencies are integer divisions of PS PLLs, so an MMCM gives finer frequency granularity and jitter filtering. This is general UltraScale+ practice, not a cited K26 statement.
- **Memory-structure choices at ~150–250 MHz:**
  - BRAM, including READ_FIRST at 510 MHz, supports single-cycle L1 arrays.
  - URAM without the output register (404 MHz) can serve single-cycle L2 banks; enable OREG for multi-cycle pipelined L2 access if more Fmax is needed.
  - Multi-ported structures (PRF, rename tables, issue queues) are best built in LUTRAM with replication, within an estimated ~57K LUTRAM-capable LUTs (Q1), or in FFs for small CAMs.
  - Avoid long DSP cascades across clock-region centers at 0.72 V.
- **Floorplanning:** PS–PL AXI ports enter the PL at fixed locations next to the PS. Placing the L2/AXI bridge near the PS and giving each core its own region with pblocks should help timing on a near-full XCK26. This is general practice and was not verified for K26 specifically.
- **Plan timing against a -1-class corner** (Q1). Fmax figures published for -2 @0.85 V ZU+ boards (ZCU102/ZCU104) will likely overstate what the K26 achieves.

### Gaps
- DS925 CLB/LUTRAM switching characteristics, the PL_CLK maximum frequency and jitter, and BUFG_PS Fmax were not retrieved.
- No published soft-CPU Fmax measured specifically on XCK26 (-2LV) was found.
- The web-search budget ran out before queries on ZU+ OoO-core timing closure (e.g., BOOM or XiangShan on ZCU102) could be made.
