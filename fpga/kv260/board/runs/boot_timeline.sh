#!/bin/bash
# boot_timeline.sh COM5LOG COM7LOG: each RISC-V-mode boot's timeline from the laptop's stamped serial logs
# (serial_log_ts.ps1: every line starts with the UTC time its first characters arrived, [HH:MM:SS.mmm]).
# A boot starts at the old kernel's "reboot: Restarting system" (Debian's on COM5, or Ubuntu's on COM7), and each
# milestone is its first line after that, in seconds from it:
#   COM7, the A53: the FSBL's banner, its U-Boot's banner, the mode hook, riscv.scr's park;
#   COM5, the RISC-V: OpenSBI's banner, U-Boot d4's banner, "Starting kernel", Linux's banner, "Run /init", the root's
#   mount, and the autologin on ttyS0 (with the kernel's own stamps for /init and the root).
# Debian's shutdown before it is timed from wall's "The system will reboot now!" on COM5 to the reset.
# A milestone printed mid-line has no stamp of its own and shows "-": COM7's FSBL banner after Debian's ttyPS0 prompt,
# with no newline between them. The A53's U-Boot banner, about 1.2 s later, has its own line.
# The logs' days are not stamped: the boots must not cross midnight UTC.
{ grep -a -E '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\] ' "$1" | sed 's/^/COM5 /'
  grep -a -E '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\] ' "$2" | sed 's/^/COM7 /'; } | sort -s -k2,2 | awk '
function sec(s) { split(substr(s, 2, 12), a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
function ks(l) { return match(l, /\[ *[0-9]+\.[0-9]+\]/) ? substr(l, RSTART + 1, RLENGTH - 2) + 0 : -1 }
function mark(k) { if (on && !(k in m)) m[k] = sec($2) - t0 }
function show(   i, k, s) {
  s = sprintf("boot %d: reset %s (%s)", ++n, substr(ts0, 2, 12), from == "COM5" ? "Debian'"'"'s reboot, COM5" : "Ubuntu'"'"'s reboot, COM7")
  for (i = 1; i <= nk; i++) { k = keys[i]; s = s sprintf(" | %s %s", k, (k in m) ? sprintf("%.1f", m[k]) : "-") }
  print s sprintf(" | kernel stamps: /init %.2f s, root %.2f s | shutdown before the reset %s", kinit, kroot, sd >= 0 ? sprintf("%.1f s", sd) : "-")
}
BEGIN { nk = split("fsbl uboot-a53 hook park opensbi uboot-rv kernel linux init root login", keys, " ") }
$1 == "COM5" && /The system will reboot now!/ { bc = sec($2) }
/reboot: Restarting system/ { if (on && !("login" in m)) show(); on = 1; delete m; t0 = sec($2); ts0 = $2; from = $1; kinit = kroot = -1
  sd = (bc != "" && t0 - bc < 300) ? t0 - bc : -1; bc = ""; next }
$1 == "COM7" && /Zynq MP First Stage Boot Loader/ { mark("fsbl") }
$1 == "COM7" && /U-Boot 2023\.01/ { mark("uboot-a53") }
$1 == "COM7" && /tanager-mode: / { mark("hook") }
$1 == "COM7" && /this A53 parks/ { mark("park") }
$1 == "COM5" && /OpenSBI v/ { mark("opensbi") }
$1 == "COM5" && /U-Boot 20[0-9][0-9]\.[0-9]/ { mark("uboot-rv") }
$1 == "COM5" && /Starting kernel \.\.\./ { mark("kernel") }
$1 == "COM5" && /Linux version / { mark("linux") }
$1 == "COM5" && /Run \/init as init process/ { if (on && !("init" in m)) kinit = ks($0); mark("init") }
$1 == "COM5" && /EXT4-fs \(mmcblk0p3\): mounted/ { if (on && !("root" in m)) kroot = ks($0); mark("root") }
$1 == "COM5" && /tanager login: tanager \(automatic login\)/ { if (on && !("login" in m)) { mark("login"); show(); on = 0 } }
'
