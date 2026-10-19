#!/bin/bash
# riscv_net_check.sh LOG [EVERY_S] [COUNT]: from the laptop, during a soak in RISC-V mode, every EVERY_S seconds (default
# 3600) for COUNT checks (default 30): the RISC-V's network over its own Ethernet. It reaches the board by name
# (tanager.mshome.net follows the DHCP lease), copies a fresh 10 MiB random file each way with scp and compares the
# checksums, and runs apt-get update. One summary line per check goes into LOG, and the check stops at its first
# failure. The board key is the board session's; the RISC-V's host key goes into its own known-hosts file, never
# ~/.ssh's.
L=$1; every=${2:-3600}; count=${3:-30}
W=$(dirname "$L")/netcheck.tmp; mkdir -p "$W"
O="-F /dev/null -i $HOME/.ssh/tanager_kv260_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=$(dirname "$L")/riscv_known_hosts -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o ServerAliveInterval=15"
R=tanager@tanager.mshome.net
for k in $(seq 1 "$count"); do
  t=$(date -u +%FT%TZ)
  dd if=/dev/urandom of="$W/up.bin" bs=1M count=10 2>/dev/null; s0=$(sha256sum "$W/up.bin" | cut -c1-64)
  ip=$(ssh $O $R 'ip -4 -br addr show eth0 | awk "{print \$3}"' </dev/null 2>/dev/null) || { echo "$t check $k FAIL: no ssh to $R" >> "$L"; exit 1; }
  a=$(date +%s.%N); scp -q $O "$W/up.bin" $R:/tmp/netcheck.bin || { echo "$t check $k FAIL: scp up" >> "$L"; exit 1; }; b=$(date +%s.%N)
  s1=$(ssh $O $R 'sha256sum /tmp/netcheck.bin' </dev/null | cut -c1-64)
  scp -q $O $R:/tmp/netcheck.bin "$W/down.bin" || { echo "$t check $k FAIL: scp down" >> "$L"; exit 1; }; c=$(date +%s.%N)
  s2=$(sha256sum "$W/down.bin" | cut -c1-64)
  apt=$(ssh $O $R 'rm -f /tmp/netcheck.bin; o=$(sudo apt-get update 2>&1); r=$?; echo "exit $r, $(echo "$o" | grep -c -E "^(Hit|Get):") sources $(echo "$o" | grep -E "^Fetched" | cut -c1-40) $(echo "$o" | grep -E "^(Err|E:|W:)" | head -2 | tr "\n" " ")"' </dev/null 2>&1)
  ok=OK; [ "$s0" = "$s1" ] && [ "$s0" = "$s2" ] || ok="FAIL: checksums differ"
  printf '%s check %d %s: %s; up %.2f MB/s, down %.2f MB/s; apt: %s\n' "$t" "$k" "$ok" "$ip" \
    "$(awk -v a=$a -v b=$b 'BEGIN {print 10.48576/(b-a)}')" "$(awk -v b=$b -v c=$c 'BEGIN {print 10.48576/(c-b)}')" "${apt:-(no Fetched line)}" >> "$L"
  rm -f "$W/up.bin" "$W/down.bin"
  [ "$ok" = OK ] || exit 1
  [ "$k" -lt "$count" ] && sleep "$every"
done
