d4s1-smt2-c2-100: D4 modes, step 1's bitstream, for step 2 (docs/spec/soc-d4-modes.md; DR-172). soc-2, built
from commit e8345f3. Timing: WNS=0.721 WHS=0.010; pr_unc=1.0 ns; 109269 LUTs placed (93.30%).
It is m6-smt2-c2-100's configuration (main with M6; smt2, two cores, 100 MHz, the virtio window and the host
DMA port, PMOD console, the PS window, D2's fan regulator; no commit trace, so no board lockstep) plus step 1's
PL changes:
  - BOARD_CTRL, host register 0x1404, reset 0: [0] the fan regulator ignores the A53's PWM; [1] the board's reset
    path: the PS window passes CRL_APB RESET_CTRL (0xFF5E0218, that word alone) and the PMOD reset hook is armed;
    [3:2] read-only, the hook's write: [2] it went out, [3] answered with an error or not at all (both clear
    with [1]).
  - The PMOD reset hook: while armed, a break on COM5 (the PMOD UART's RX) of 2.7 to 10.7 s makes the PS window
    write RESET_CTRL's SOFT_RESET when the break ends, once per arming. The uncore must be out of reset (the
    window is in it).
With BOARD_CTRL at 0 (as after every load) the design behaves as m6's: stage C runs as before.

Files: tanager.bit.bin, tanager.dtbo (as d2's), shell.json, tanager-host (unchanged), ps_reset.bin (step 2a),
tanager-kv260-bench.dtb (p0f's), and sc3's boot files (fw_jump.bin, Image, the virtio DTBs) with sdpart's
u-boot.bin, so stage C (Debian from p3) runs as on m6.

Step 2 (ARM mode under tanager-host; nothing in the boot path changes). Both tests reset the whole board, A53
included: run `sync` first, and expect SSH to drop and Ubuntu to boot again (an unclean shutdown of Ubuntu,
whose ext4 journal replays). Record CRL_APB RESET_REASON before and after each with
`sudo busybox devmem 0xFF5E0220 32` (informational).
0. Load it as its own app (xmutil). `sudo ./tanager-host info`, `fan`, and `peek 0x1404` (0).
1. Step 2(a), the RISC-V's write (Debian's reboot in RISC-V mode):
     sudo ./tanager-host poke 0x1404 2
     sudo ./tanager-host load --fw ps_reset.bin --kernel /dev/null --dtb /dev/null
     sync; sudo ./tanager-host run
   The console prints RESET_CTRL's value, then "writing SOFT_RESET in 1 s"; then the board resets: pass.
   Otherwise the program says why (access fault on the read or the write, with its time: under 5000 ticks
   the window denied it or the PS answered an error, the XPPU or TrustZone refusing a non-secure PL master;
   over, no answer) and stops: record the console, `sudo ./tanager-host poke 0x1404 0`, and report. An error
   from the PS means step 2's fallback (the PMU's reset service through a PL IPI channel), not step 2(b).
2. Step 2(b), the PMOD reset hook (after 2(a) passed and Ubuntu is back): load the app again, then
     sudo ./tanager-host poke 0x010 1        (the uncore out of reset, the cores held)
     sudo ./tanager-host poke 0x1404 2
     sync
   and on the laptop, with nothing else holding COM5:
     python -c "import serial; s = serial.Serial('COM5', 115200); s.send_break(3); s.close()"
   The board resets when the break ends: pass. If not, `sudo ./tanager-host peek 0x1404`: 0x2 nothing went out
   (the break never seen: 3 s inside 2.7-10.7 s? the right COM port?), 0x6 the write went out and was answered
   but nothing reset, 0xe an error or no answer (as 2(a)'s fault). Then poke 0x1404 0 and report.
3. Optional, the fan bit: with fancontrol stopped and pwm1 at 255 (the fan full from the A53), `fan` shows the
   duty at 255; after `poke 0x1404 1` the duty is the PL curve's (15 below 35 C); `poke 0x1404 0` and restart
   fancontrol.
4. Read-only probes for step 5, any time in ARM mode (record the output; nothing is written):
     for a in 0xfd4d0000 0xfd4d0004 0xff150000 0xff150004 0xfd615000 0xff180314 0xff180318; do
       printf '%s ' $a; sudo busybox devmem $a 32; done
   (the FPD and LPD SWDTs' ZMR and CCR: ZMR bit 0 set means a watchdog runs; AFI_FS; SD1's taps as Linux set them)
     grep . /sys/class/watchdog/watchdog*/identity /sys/class/watchdog/watchdog*/state 2>/dev/null
     sudo dd if=/dev/mtd5 bs=1M 2>/dev/null | tr -c '[:print:]' '\n' | grep -i -m8 'wdt\|watchdog'
   Why: in RISC-V mode the A53 parks in a WFI loop. If its U-Boot started a watchdog, nothing services it, and
   riscv.scr must stop it before the park.
cfg=smt2 kind=core core_mhz=100 n_cores=2
WNS=0.721 WHS=0.010
runtime_s=4631
commit=e8345f3
profile=m6-smt2-notrace-pswin-fan defines=TG_COMMIT_TRACE=0 synth=AreaOptimized_high
pr_unc=1.0 (ns of setup uncertainty on clk_core for placement and routing, taken back before the reports)
opt=ExploreArea (opt_design's directive, DR-166)
uncore=VIRTIO_WINDOW=1 HOST_DMA=1 PS_WINDOW=1
pmod_uart=1 txd=H12 rxd=B10
fan=ttc0.wave2 invert=0 pl=1 pin=A12
