#!/bin/bash
# hsm_rounds.sh N: OpenSBI's hart stop and start (SBI HSM) driven from Linux, on the RISC-V's Debian as root: soc-2's
# step 3 of DR-187's four-hart bring-up. N rounds (3) of CPUs 1-3 offline, then online again, each round checked in
# /sys/devices/system/cpu/online (0 with them off, 0-3 with them back); then t.c's loop on each CPU, which must print
# 5007905533300608, and the kernel's lines from the rounds, counted for trouble.
N=${1:-3}; T=${2:-/home/tanager/hartcheck/dr187b-h0123/t}; fails=0
k0=$(dmesg | wc -l)
echo "HSM-BEGIN rounds=$N online=$(cat /sys/devices/system/cpu/online) $(date -u +%T)"
for r in $(seq 1 "$N"); do
  for c in 1 2 3; do echo 0 > /sys/devices/system/cpu/cpu$c/online || { echo "round $r: cpu$c offline FAILED"; fails=$((fails + 1)); }; done
  off=$(cat /sys/devices/system/cpu/online)
  for c in 1 2 3; do echo 1 > /sys/devices/system/cpu/cpu$c/online || { echo "round $r: cpu$c online FAILED"; fails=$((fails + 1)); }; done
  on=$(cat /sys/devices/system/cpu/online)
  echo "round $r: CPUs 1-3 off -> online $off; back on -> online $on"
  [ "$off" = 0 ] && [ "$on" = 0-3 ] || { echo "round $r: FAIL"; fails=$((fails + 1)); }
done
for c in 0 1 2 3; do
  r=$(taskset -c $c "$T"); [ "$r" = 5007905533300608 ] && echo "t on cpu$c after the rounds: PASS" || { echo "t on cpu$c after the rounds: FAIL ($r)"; fails=$((fails + 1)); }
done
echo "== the kernel's lines during the rounds:"; dmesg | tail -n +$((k0 + 1))
# Known (u100, 10-23; fpga/kv260/README.md's known issues): OpenSBI 1.9 refuses a remote fence that names a hart just
# stopped. Expected in a hotplug round until our OpenSBI patch, so counted apart; every other such line is trouble.
KNOWN='__sbi_rfence_v02_call: hbase = \[[0-9]+\] hmask = \[0x[0-9a-f]+\] failed \(error \[-22\]\)'
known=$(dmesg | tail -n +$((k0 + 1)) | grep -c -E "$KNOWN")
t=$(dmesg | tail -n +$((k0 + 1)) | grep -v -E "$KNOWN" | grep -c -i -E "fail|error|timeout|unable|oops|bug|stall|warn")
echo "HSM-END fails=$fails trouble-lines=$t known=$known online=$(cat /sys/devices/system/cpu/online) $(date -u +%T)"
