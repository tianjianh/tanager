#!/bin/bash
# Stage D's D4 handover on the A53 (docs/spec/soc.md §8.2; approved by the coordinator under DR-147): from the
# running Ubuntu, kexec once into Ubuntu's own kernel with the handover tree and initramfs. Nothing in the boot
# path changes (QSPI, U-Boot's environment, p1), so any reset or power cycle boots normal Ubuntu. The
# coordinator's conditions are checked or applied here: the fan passes to D2's regulator (pwm1 = 1) before
# Ubuntu stops, and systemctl kexec stops the services and remounts p2 read-only before the jump.
#   sudo bash handover.sh --dry [--dry-s N]
#       the handover without the RISC-V: the board reaches the A53 over SSH (root@kria) and it goes back to
#       Ubuntu after N seconds (900), or at once with reboot -f
#   sudo bash handover.sh --fw F --kernel K --initrd I --dtb D
#       loads the RISC-V's images into the carve-out first (cores held), then the handover runs it
# Run from a directory holding handover.dtb (handover_dtb.sh), handover.cpio.gz (mk_initramfs.sh) and
# tanager-host, with the bitstream loaded (xmutil).
set -euo pipefail
dry=0 dry_s=900 fw= kernel= initrd= dtb=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry) dry=1 ;;
    --dry-s) dry_s=$2; shift ;;
    --fw) fw=$2; shift ;;
    --kernel) kernel=$2; shift ;;
    --initrd) initrd=$2; shift ;;
    --dtb) dtb=$2; shift ;;
    *) echo "$0: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
die() { echo "handover.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
for f in handover.dtb handover.cpio.gz tanager-host; do [ -f "$f" ] || die "no $f here"; done
[ $dry = 1 ] || { [ -n "$fw" ] && [ -n "$kernel" ] && [ -n "$initrd" ] && [ -n "$dtb" ]; } \
  || die "--fw, --kernel, --initrd and --dtb, or --dry"

# Checks: kexec-tools present and leaving reboots alone; the bitstream and D2's regulator there
command -v kexec >/dev/null || die "kexec-tools is not installed"
grep -q '^LOAD_KEXEC=false' /etc/default/kexec 2>/dev/null || die "/etc/default/kexec must say LOAD_KEXEC=false"
[ "$(cat /sys/kernel/kexec_loaded)" = 0 ] || die "a kexec kernel is already loaded (kexec -u to drop it)"
./tanager-host info
fan=$(./tanager-host fan)
echo "$fan"
case "$fan" in *"PL die"*) ;; *) die "no reading from D2's fan regulator: this bitstream can't hold the fan" ;; esac

# The handover kernel's command line: the running one without its root, console and earlycon, plus
# pd_ignore_unused (SD1's and UART1's domains stay on), panic=10 (back to Ubuntu if /init dies) and the mode
cmdline=
for a in $(cat /proc/cmdline); do
  case "$a" in root=*|rootwait|console=ttyPS*|earlycon*) ;; *) cmdline="$cmdline $a" ;; esac
done
cmdline="${cmdline# } pd_ignore_unused panic=10 tg.handover=$([ $dry = 1 ] && echo dry || echo run) tg.dry_s=$dry_s"
case "$cmdline" in *mem=3G*) ;; *) die "the command line has no mem=3G: the carve-out would not survive" ;; esac
echo "handover command line: $cmdline"

# The RISC-V's images into the carve-out, cores held (it survives the kexec: mem=3G keeps it out of Linux RAM)
[ $dry = 1 ] || ./tanager-host load --fw "$fw" --kernel "$kernel" --initrd "$initrd" --dtb "$dtb"

# The fan passes to D2's regulator before Ubuntu stops (the handover kernel doesn't run fancontrol)
systemctl stop fancontrol
for h in /sys/class/hwmon/hwmon*; do [ "$(cat "$h/name")" = pwmfan ] && echo 1 > "$h/pwm1"; done
sleep 3
./tanager-host fan

kexec -l "/boot/vmlinuz-$(uname -r)" --initrd=handover.cpio.gz --dtb=handover.dtb --command-line="$cmdline"
echo "handover: kexec loaded; systemctl kexec in 10 s (Ctrl-C, then kexec -u and systemctl start fancontrol, to stop)"
sleep 10
systemctl kexec
