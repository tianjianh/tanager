d1-smt2-c2-100: stage D's first milestone D1 (docs/spec/soc.md §8.2): the RISC-V reaches the PS's peripheral
registers through the PS window (S_AXI_LPD), with their interrupts on PLIC 20-24. soc-2, branch
claude/track-soc-160053, commit a4bc643941f3. sc3's configuration (smt2, two cores, 100 MHz, the virtio window and
the host DMA port, the trace, PMOD console, fan per DR-129) plus TG_PS_WINDOW=1. Timing: WNS=0.650 WHS=0.010; pr_unc=1.0 ns; 110980 LUTs placed (94.76%).
The coordinator's conditions (DR-158): only blocks D0 found clocked; the interrupt test on a block the A53
provably doesn't use (TTC1); UART1 is the A53's console: only its status and FIFO are touched, never its mode
or baud; the fan stays with the A53's fancontrol.

Files: tanager.bit.bin, tanager.dtbo (adds S_AXI_LPD's AFI width, 128-bit = its reset value), shell.json,
tanager-host (as d0's), ps_d1.bin (D1's bare-metal test), and sc3's boot files (fw_jump.bin, Image, the
virtio DTBs) so stage C (Debian from p3 with sdpart's u-boot.bin) still runs on this bitstream; the window
stays idle unless the RISC-V touches it.

0. Load the app as usual (xmutil). Pre-checks, read-only:
     sudo ./tanager-host psrd 0xFF9B0000 ; sudo ./tanager-host psrd 0xFF9B0014    AFI FM6: [1:0] still 0 (128-bit)
     sudo ./tanager-host psrd 0xFF5E0238    CRL_APB RST_LPD_IOU2 (UG1087): TTC1's reset bit must be clear
       (UART1's, SD1's and TTC0's, in use, will be clear too; UART0's may be set). If TTC1 is held in reset,
       stop and tell soc-2: step 3 of ps_d1 needs it released, a PS change for the coordinator to approve.
1. Run the test (cores held until run; the RISC-V console is tanager-host's):
     sudo ./tanager-host load --fw ps_d1.bin --kernel /dev/null --dtb /dev/null && sudo ./tanager-host run --timeout 10
   Expected on the RISC-V console:
     tanager D1: the PS window
     UART1 SR xxxxxxxx
     UART1: line written
     IOU_SLCR MIO_PIN_36 xxxxxxxx, SD_ITAPDLY xxxxxxxx, SD_OTAPDLYSEL xxxxxxxx
     TTC1: interrupt after xxxxxxxx ticks of 10 MHz, ISR 00000001
     denied: TTC0 and UART0 fault
     D1 PASS
   and on the A53's own serial console (the micro-USB port, ttyPS1), among its output:
     [tanager RISC-V] hello from the RISC-V, through the PS window
2. Check the A53: dmesg shows nothing new (no SError, no UART errors), its console still answers, fancontrol
   still regulates (the pwm value as before).
3. If it fails, the code says where:
     FAIL 0011  the first UART1 read faulted: the PS refused the PL master (the XPPU, most likely). Nothing
                hangs: the window turns an error or a 2^16-cycle silence into a fault.
     FAIL 0010  UART1's transmit FIFO stayed full for 10 ms
     FAIL 0020  an IOU_SLCR read faulted
     FAIL 0031  no TTC1 interrupt within 10 ms (the PS-to-PL line or the PLIC)
     FAIL 0040/0041  a denied address did not fault (a window bug)
   If the board hangs at the first access (the PS interconnect stalled), power-cycle it and tell soc-2.
