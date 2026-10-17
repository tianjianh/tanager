d0-probes-20261017: stage D's D0 probes on sc3 (docs/spec/soc.md §8.2, "Order of work"; soc-2, branch
claude/track-soc-160053). Approved by the coordinator with these conditions:
- only with sc3 (our app) loaded (the PL read-hang rule);
- read-only on PS state, except the ADMA probe;
- the ADMA writes only inside the RISC-V's carve-out, never the A53's memory;
- fan control stays with the A53's fancontrol throughout.
Results go to the coordinator before D1's RTL is final (D-c may fall).
tanager-host here = sc3's plus `dma adma` and `psrd` (and the external-write records, MR5). Everything else is
unchanged.

PART 1: read-only facts (as root; mount debugfs if needed: mount -t debugfs none /sys/kernel/debug)
1. Clocks: grep -E 'uart|sdio|gem|usb|ttc|adma_ref|lpd_lsbus' /sys/kernel/debug/clk/clk_summary
   (enable count and rate of each; D1 targets only clocked blocks)
2. Power domains: cat /sys/kernel/debug/pm_genpd/pm_genpd_summary
3. SMMU: dmesg | grep -iE 'smmu|iommu'; ls /sys/class/iommu/; cat /sys/module/arm_smmu/parameters/disable_bypass;
   ls -l /sys/kernel/iommu_groups/*/devices/; cat /proc/cmdline
4. The live device tree, status and compatible of: serial@ff000000 (UART0), serial@ff010000 (UART1),
   timer@ff110000 (TTC0, the fan), timer@ff120000 (TTC1), mmc@ff160000 (SD0: eMMC; upstream's smk-k26 disables
   it, so we expect no eMMC), mmc@ff170000 (SD1, the card), ethernet@ff0e0000 (GEM3) with its PHY node (reg =
   the MDIO address) and any reset-gpios, usb@ff9d0000 and its dwc3 child (fe200000), the USB hub node (USB5744)
   and its reset-gpios, dma-controller@ffaf0000. For example:
     find /sys/firmware/devicetree/base -name '*@ff0[01]0000' -o -name '*@ff1[1-7]0000' -o -name '*@ff0e0000' \
       -o -name '*@ff9d0000' -o -name '*@fe200000' -o -name '*@ffaf0000' | while read n; do
       printf '%s %s\n' "$n" "$(tr -d '\0' < $n/status 2>/dev/null)"; done
   or dtc -I fs -O dts /sys/firmware/devicetree/base > live.dts, if dtc is installed.
5. Interrupts in use: cat /proc/interrupts. D1's test wants a block the A53 provably doesn't use: TTC1 is the
   candidate (disabled in the SOM tree, clocked by lpd_lsbus); confirm it's absent here and its status isn't okay.
6. Storage: ls -l /dev/mmcblk*; cat /sys/class/mmc_host/mmc*/mmc*:*/type
7. PS registers, read-only (`tanager-host psrd`, limited to always-on LPD blocks; a refused read prints "bus
   error"). Decode with UG1087:
     ./tanager-host psrd 0xFF980000        LPD XPPU CTRL ([0] enable)
     ./tanager-host psrd 0xFF9B0000        AFI FM6 RDCTRL (S_AXI_LPD's read width, [1:0])
     ./tanager-host psrd 0xFF9B0014        AFI FM6 WRCTRL (write width, [1:0])
     ./tanager-host psrd 0xFF5E023C        CRL_APB RST_LPD_TOP (AFI FM6's reset bit: D1 needs it released)

PART 2: the ADMA probe, D-c's premise: can an LPD master (like the SD, GEM and USB controllers) reach the host
DMA port (HPM1)?
- Keep ADMA channel 8 powered by its driver (it gates clocks and power while idle, and reading an unpowered
  block can hang the board):
    echo on > /sys/bus/platform/devices/ffaf0000.dma-controller/power/control
  (the device may be named ffaf0000.dma; check it reads `active` in power/runtime_status). tanager-host refuses
  unless it does.
- Load sc3 and release nothing: `sudo ./tanager-host load ...` as usual, cores held. Then:
    sudo ./tanager-host dma adma
  (defaults: channel 0xFFAF0000, 4096 bytes at the RISC-V RAM's last MiB). Two simple-mode copies, both inside
  the carve-out:
  - DDR -> HPM1 (into the RISC-V's RAM through the L2);
  - then HPM1 -> DDR.
  Each prints ok/FAIL, the channel's ISR (bit 10 done; 9 AXI write error, 8 AXI read error), the time, the
  words wrong, and the host DMA port's line counters (writes for the first copy, reads for the second: they
  show the traffic really went through the port).
- Afterwards: echo auto > /sys/bus/platform/devices/ffaf0000.dma-controller/power/control
- Reading the result:
  - both ok, with the port's counters moving: D-c holds;
  - an AXI error on the HPM1 side (copy 1: bit 9, copy 2: bit 8), or a timeout: say which; the SMMU state from
    part 1 tells whether it blocked the stream.
