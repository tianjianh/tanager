d3-uart1: stage D's D3 (docs/spec/soc.md §8.2, DR-163): the RISC-V's console on the PS's UART1, the board's
USB serial port (COM7), with the A53's Ubuntu still running. soc-2, branch claude/track-soc-160053, commit d146c112c1f8.
No bitstream: d2's (already on the board) has the PS window, which passes UART1 and brings its interrupt to
PLIC source 20.

The coordinator's conditions (DR-163):
  - run-time changes only on the A53: the getty masked with --runtime and the console log level lowered,
    nothing persistent; SSH over GEM3 and fancontrol stay up throughout;
  - D1's "never reconfigure UART1" is lifted for D3 only, while the RISC-V owns the port;
  - NO A53 shutdown or reboot while the getty is masked and the RISC-V owns UART1. Unmask first; giving
    UART1 back (step 5) is the last step.
Work over SSH throughout: the A53's serial console goes to the RISC-V from step 1 to step 5.

Files: Image (Buildroot with the Cadence UART driver built in), fw_jump.bin (OpenSBI 1.9, generic: its Cadence
UART driver), tanager-kv260-uart1.dtb (UART1 as the stdout path, PLIC 20, the clocks at 99,999,999 Hz as D0's
clock tree; boot arguments console=ttyPS0,115200 console=ttyS0,115200 earlycon), tanager-kv260.dtb (the same
configuration without UART1, for a comparison boot), tanager-host (d2's).
Both trees: smt2, two cores (harts 0 and 2), 1 GiB, no virtio.

0. With d2 loaded (`sudo ./tanager-host info`: caps 0x12f, smt2 2x2, 100 MHz), record for step 5:
     cat /proc/sys/kernel/printk                     (the first number is the console level; Ubuntu's is 4)
     systemctl is-active serial-getty@ttyPS1.service (active)
   Optional, the same Image without UART1 first (the PL console only, as before):
     sudo ./tanager-host boot --fw fw_jump.bin --kernel Image --dtb tanager-kv260.dtb
   expect the usual boot, TANAGER-BOOT-OK, a login; `poweroff` ends it.
1. Release UART1 (A53, over SSH):
     sudo systemctl mask --runtime --now serial-getty@ttyPS1.service
     sudo dmesg -n 1
     systemctl is-active serial-getty@ttyPS1.service      (inactive)
     sudo ls -l /proc/[0-9]*/fd 2>/dev/null | grep -c ttyPS1    (0: nothing holds the port)
   From here until step 5: no shutdown or reboot of the A53.
2. On the laptop, keep COM7 open (115200 8N1). It now shows the RISC-V.
3. Boot (A53, over SSH; tanager-host bridges the PL console to its stdio, the second view):
     sudo ./tanager-host boot --fw fw_jump.bin --kernel Image --dtb tanager-kv260-uart1.dtb
   Expected on COM7: OpenSBI's banner (its console is UART1), Linux's log (earlycon, then ttyPS0), then
   "Tanager Linux" and "tanager login:". Log in as root (no password).
   Expected on the PL console (tanager-host's stdio): the kernel's log once the 8250 driver probes, TANAGER-BOOT-OK
   and the PL UART's own login, as always (/dev/console stays the PL UART).
4. On COM7, logged in:
     cat /proc/consoles ; grep -i -e ttyPS -e 20: /proc/interrupts ; uname -a ; ls /
   then type a few more commands and see the interrupt count rise. On the A53 (SSH):
     systemctl is-active fancontrol ; cat /sys/class/hwmon/hwmon*/pwm1 ; dmesg | tail -5
   (fancontrol active, pwm1 as before, no new kernel lines).
   End the RISC-V with `poweroff` on COM7; tanager-host exits.
5. Give UART1 back (A53, over SSH; the last step):
     sudo systemctl unmask --runtime serial-getty@ttyPS1.service
     sudo systemctl start serial-getty@ttyPS1.service
     sudo dmesg -n 4                                  (step 0's first number)
   Press Enter on COM7: the A53's login prompt answers.

If COM7 stays silent in step 3 for 20 s:
  - if the PL console shows Linux booting, UART1's path failed after OpenSBI (or OpenSBI printed nowhere). Log
    in on the PL console: dmesg | grep -i -e ttyPS -e ff010000 ; cat /proc/interrupts. Then poweroff;
  - if nothing shows anywhere, OpenSBI stopped at UART1: `sudo ./tanager-host dbg` (the cores' state), then stop
    tanager-host (Ctrl-C) and `sudo ./tanager-host reset`.
  In both cases do step 5, then send everything to soc-2.
Send the raw outputs: COM7's capture from step 2 to 5, tanager-host's stdio, and the A53 commands.
