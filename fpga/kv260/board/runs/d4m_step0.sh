#!/bin/bash
# d4m_step0.sh: step 0 of D4's boot-time modes (docs/spec/soc-d4-modes.md, DR-172): the SoC track's read-only probes
# of the QSPI U-Boot, its environment, the SD card's free sectors, flash-kernel's bootscript and four PS registers.
# Nothing is written and nothing reboots; it runs alongside a stress run (the PS reads need a Tanager app holding
# the PL, as psrd checks our host bridge first). The A53's Ubuntu has no binutils, so `strings -n N` is replaced by
# `tr -c '[:print:]' '\n' | awk 'length >= N'`: the same printable runs (strings also counts a tab as printable).
H=$HOME/tanager/d2pkg/tanager-host
str() { sudo cat /dev/mtd$1 | tr -c '[:print:]' '\n' | awk -v n=$2 'length >= n'; }
words='fatwrite|fatload|fpga|zynqmp|mmc|itest|setexpr|go|bootcount|sleep|source|load|mw|md|cmp|crc32|echo|exit|reset'
echo "== 1. the QSPI U-Boot"
cat /proc/mtd
for img in A B; do
  n=$(grep -F "\"Image $img (FSBL, PMU, ATF, U-Boot)\"" /proc/mtd | cut -d: -f1 | tr -d mtd)
  echo "-- Image $img = mtd$n, the commands soc-2 listed (runs of 3 or more): $(str $n 3 | grep -x -E "$words" | sort -u | tr '\n' ' ')"
  echo "-- Image $img, the commands by their usage strings (a name can't show as its own run when it is under 3 characters"
  echo "   (go, md, mw) or when the linker stores it as the tail of a longer string, e.g. load in fatload):"
  str $n 3 > /tmp/d4m_str.txt
  while IFS='|' read -r c u; do
    if grep -q -F -x -- "$u" /tmp/d4m_str.txt; then echo "   $c: yes ($u)"; else echo "   $c: usage string not found ($u)"; fi
  done <<'U'
fatwrite|write file into a dos filesystem
fatload|load binary file from a dos filesystem
fpga|loadable FPGA image support
zynqmp|ZynqMP sub-system
mmc|MMC sub system
itest|return true/false on integer compare
setexpr|set environment variable as the result of eval expression
go|start application at address 'addr'
sleep|delay execution for some time
source|run script from memory
load|load binary file from a filesystem
mw|memory write (fill)
md|memory display
cmp|memory compare
crc32|checksum calculation
echo|echo args to console
exit|exit script
reset|Perform RESET of the CPU
U
  echo "   bootcount: runs containing \"bootcount\" or \"bootlimit\": $(grep -c -i -E 'bootcount|bootlimit' /tmp/d4m_str.txt)"
  grep -i -E 'bootcount|bootlimit|altbootcmd' /tmp/d4m_str.txt | sort -u | head -5 | sed 's/^/   /'
  [ $img = A ] && { echo "-- Image A, U-Boot's default environment (the variables soc-2 listed):"
    grep -E '^(bootcmd|boot_targets|distro_bootcmd|scriptaddr|kernel_addr_r|fdt_addr_r|loadaddr|bootdelay|baudrate)=' /tmp/d4m_str.txt | sort -u; }
  rm -f /tmp/d4m_str.txt
  echo "-- Image $img, runs of 8 or more:"
  str $n 8 | grep -E 'U-Boot 20[0-9][0-9]|mmio_write|mmio_read|fpga load|mmc write' | sort -u | head -20
done
echo "-- the image the board boots:"; sudo xmutil bootfw_status 2>&1 | head -20
echo "== 2. the U-Boot environment"
which fw_printenv; dpkg -S "$(readlink -f "$(which fw_printenv)")" 2>&1 | head -2
echo "-- /etc/fw_env.config:"; grep -v -E '^\s*(#|$)' /etc/fw_env.config 2>&1
sudo fw_printenv > /tmp/d4m_env.txt 2> /tmp/d4m_env.err; echo "fw_printenv exit $?, $(wc -l < /tmp/d4m_env.txt) lines; stderr:"; cat /tmp/d4m_env.err
grep -E '^(bootcmd|boot_targets|distro_bootcmd|scriptaddr|kernel_addr_r|fdt_addr_r|loadaddr|bootdelay|baudrate)=' /tmp/d4m_env.txt
rm -f /tmp/d4m_env.txt /tmp/d4m_env.err
for v in "U-Boot storage variables" "U-Boot storage variables backup"; do
  m=$(grep -F "\"$v\"" /proc/mtd | cut -d: -f1)
  echo "-- $m ($v): $(sudo cat /dev/$m | tr -d '\377' | wc -c) bytes that aren't 0xFF (0: never saved, U-Boot uses its default)"
  sudo cat /dev/$m | tail -c +5 | tr '\0' '\n' | grep -a -E '^.?(bootcmd|boot_targets|distro_bootcmd|scriptaddr|kernel_addr_r|fdt_addr_r|loadaddr|bootdelay|baudrate)=' | head -12
done
echo "== 3. the SD card"
sudo sfdisk -d /dev/mmcblk1
echo "-- sector 2047:"; sudo dd if=/dev/mmcblk1 bs=512 skip=2047 count=1 2>/dev/null | od -A d -t x1 | head -5
echo "-- sectors 1-2047, non-zero bytes: $(sudo dd if=/dev/mmcblk1 bs=512 skip=1 count=2047 2>/dev/null | tr -d '\000' | wc -c)"
df -h /boot/firmware; ls -la /boot/firmware
echo "== 4. flash-kernel"
echo "model: $(tr -d '\000' < /proc/device-tree/model)"
cat /etc/flash-kernel/machine 2>/dev/null || echo "(no /etc/flash-kernel/machine)"
ls -la /etc/flash-kernel/bootscript/ /usr/share/flash-kernel/bootscript/ 2>&1 | head -30
grep -A12 -i 'kv260\|zynqmp' /usr/share/flash-kernel/db/all.db | grep -E 'Machine|Boot-Script-Path|U-Boot-Script-Name|Required-Packages' | head
model=$(cat /etc/flash-kernel/machine 2>/dev/null || tr -d '\000' < /proc/device-tree/model)
if [ -f /etc/flash-kernel/db ]; then n=$(grep -c -v -E '^\s*(#|$)' /etc/flash-kernel/db); else n=absent; fi
echo "-- local db /etc/flash-kernel/db: $n non-comment lines"
echo "-- the first all.db entry whose Machine pattern matches \"$model\" (flash-kernel matches globs):"
ent=$(awk 'BEGIN {RS = ""; FS = "\n"} {for (i = 1; i <= NF; i++) if ($i ~ /^Machine:/) {m = $i; sub(/^Machine: */, "", m); print NR "\t" m}}' \
  /usr/share/flash-kernel/db/all.db | while IFS=$'\t' read -r k pat; do [[ "$model" == $pat ]] && { echo "$k"; break; }; done)
[ -n "$ent" ] || ent=0   # no entry: the lines below print nothing and diff reports the missing file
awk -v k=$ent 'BEGIN {RS = ""} NR == k' /usr/share/flash-kernel/db/all.db
scr=$(awk -v k=$ent 'BEGIN {RS = ""; FS = "\n"} NR == k {for (i = 1; i <= NF; i++) if ($i ~ /^U-Boot-Script-Name:/) {sub(/^U-Boot-Script-Name: */, "", $i); print $i}}' /usr/share/flash-kernel/db/all.db)
f=/etc/flash-kernel/bootscript/$scr
echo "-- $f: $(dpkg -S $f 2>&1 | head -1); listed as a conffile: $(dpkg-query -W -f='${Conffiles}\n' flash-kernel | grep -c " $f ")"
echo "-- the script inside /boot/firmware/boot.scr.uimg (after its 64-byte header and 8-byte length table), head -60:"
tail -c +73 /boot/firmware/boot.scr.uimg | head -60
echo "-- diff of that script against $f (flash-kernel's substitutions show here):"
diff <(tail -c +73 /boot/firmware/boot.scr.uimg | tr -d '\000') $f | head -20
echo "== 5. PS registers"
app=$(sudo xmutil listapps | awk '$NF ~ /^0->/ {print $1}')
case "$app" in tanager*) ;; *) echo "STOP: no Tanager app holds the PL (active: ${app:-none})"; exit 1;; esac
echo "tanager-host $(sha256sum $H | cut -c1-16); the PL holds $app"
sudo $H psrd 0xFF5E0218 3
sudo $H psrd 0xFF5E00C0
echo "-- the A53's uptime (a reboot since the last power-on would show in RESET_REASON): $(uptime -s) local, $(cut -d' ' -f1 /proc/uptime) s"
echo "== extras (not in soc-2's list; read-only)"
echo "-- flash-kernel's hook directories (README: users add stubs here; they replace @@UBOOT_ENV_EXTRA@@ and @@UBOOT_PREBOOT_EXTRA@@):"
for d in /etc/flash-kernel/ubootenv.d /etc/flash-kernel/preboot.d /usr/share/flash-kernel/ubootenv.d /usr/share/flash-kernel/preboot.d; do
  [ -d $d ] && echo "   $d: $(ls -A $d | wc -l) files" || echo "   $d: absent"; done
zcat /usr/share/doc/flash-kernel/README.gz | sed -n 192,205p
echo "-- where the hooks sit in $f:"; grep -n -E "@@|^for boot_target|^done|system.bit|fpga load" $f
echo "-- /etc/default/flash-kernel:"; grep -v -E '^\s*(#|$)' /etc/default/flash-kernel
echo "-- Image A: the fpga command's subcommands (its help lists them indented) and the driver's bitstream messages:"
str 5 3 | grep -E '^ +(dump|info|load|loadb|loadbp|loadp|loads|loadmk|lock)$' | sort -u | tr -s ' \n' ' '; echo
str 5 3 | grep -E '^ *(%s: )?Bitstream|bitstream\.\.\.' | sort -u | head -12
echo "-- Image A: the default environment's boot chain (each value cut to 300 characters):"
str 5 3 | grep -E '^(som_cc_boot|som_mmc_boot|k26_starter|k24_starter|bootcmd_mmc0|bootcmd_mmc1|boot_prefixes|boot_scripts|boot_a_script|scan_dev_for_scripts|scan_dev_for_boot|scan_dev_for_boot_part|boot_targets|loadaddr|board_name)=' | sort -u | cut -c1-300
