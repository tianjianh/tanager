#!/bin/bash
# sd1_probe_boots.sh COM5LOG TALLY FIRST LAST [STRESS_S]: from the laptop, boots FIRST..LAST of the hunt for SD1's lost
# interrupt in RISC-V mode (the coordinator, 10-20; the probe is soc-2's sw/d4mode/sd1-irq-probe). It starts with the
# board in RISC-V mode, Debian up, and COM5 logged into COM5LOG by the caller. Each boot:
#   - Debian's reboot (its confirm unit keeps RISC-V mode), and the login on COM5;
#   - over SSH: sd_read_stress.sh (both CPUs, STRESS_S seconds, default 90); the probe's watch runs all the time, from
#     sd1-irq-watch.service (from RAM, from the root's mount through shutdown: boot 7's shutdown lost the interrupt);
#   - one line in TALLY: the COM5 offset where the boot starts, the login's time, SD1's timeouts in the boot and in the
#     stress, the readers' rates, and whether the probe fired.
# It stops at a boot with no login within 8 minutes (stuck: the PMOD break is the caller's) and at the probe's first
# capture, which it copies into TALLY from the guest's log or, when SSH is gone, from COM5 (also before a login: a
# shutdown's or a boot's capture).
L=$1; T=$2; first=$3; last=$4; S=${5:-90}
K=$(dirname "$T")/riscv_known_hosts
O="-F /dev/null -i $HOME/.ssh/tanager_kv260_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=$K -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o ServerAliveInterval=15"
R=tanager@tanager.mshome.net
g() { timeout 300 ssh $O $R "$@" < /dev/null 2>&1; }
cap() {   # the probe's capture on COM5 since the boot's start: its dump header ("sd1-irq-probe N s") and what follows
  tail -c +$((off + 1)) "$L" | tr -d '\r' | grep -a -q -E 'sd1-irq-probe [0-9]+\.[0-9]+ s' || return 1
  { echo "== boot $n: the probe's capture on COM5"; tail -c +$((off + 1)) "$L" | tr -d '\r' | grep -a -E 'sd1-irq-probe|PLIC:|SD1:|mmc0$|SiFive PLIC' ; } >> "$T"
  return 0
}
for n in $(seq "$first" "$last"); do
  off=$(stat -c %s "$L"); t0=$(date +%s)
  g 'sudo nohup sh -c "sleep 2; reboot" > /dev/null 2>&1 &' > /dev/null || { echo "$(date -u +%T) boot $n: no SSH to send the reboot: stop" >> "$T"; exit 1; }
  sleep 30   # the old Debian is still up for a few seconds; the login must come from the new one
  ok=0
  for i in $(seq 1 90); do
    tail -c +$((off + 1)) "$L" | grep -a -q -E 'tanager login: tanager \(automatic login\)|tanager@tanager:~\$' && { ok=1; break; }   # the prompt too: a COM5 drop lost boot 12's login line
    cap && { echo "$(date -u +%T) boot $n: CAPTURE on COM5 before the login (in the shutdown or the boot): stop" >> "$T"; exit 4; }
    sleep 5
  done
  tl=$(( $(date +%s) - t0 ))
  if [ $ok = 0 ]; then
    echo "$(date -u +%T) boot $n: COM5 from $off, NO LOGIN after $tl s (stuck: $(tail -c +$((off + 1)) "$L" | grep -a -c 'Timeout waiting for hardware') SD1 timeouts on COM5, probe lines $(tail -c +$((off + 1)) "$L" | grep -a -c 'sd1-irq-probe')): stop" >> "$T"
    exit 2
  fi
  for i in $(seq 1 24); do g true > /dev/null && break; sleep 10; done   # DHCP and the name follow the login
  b=$(g 'sudo dmesg | grep -c "Timeout waiting for hardware"; grep -c iomem=relaxed /proc/cmdline; cut -d" " -f1 /proc/uptime; systemctl is-active sd1-irq-watch')
  set -- $b; bt=${1:-?}; io=${2:-?}; up=${3:-?}; wa=${4:-?}
  r=$(g "sudo sh /home/tanager/sd_read_stress.sh $S" | tr '\n' ';')
  a=$(g 'sudo dmesg | grep -c "Timeout waiting for hardware"; grep -m1 mmc0 /proc/interrupts | tr -s " " | cut -d" " -f2-4; test -s /run/sd1-irq-probe.log && echo FIRED || echo none')
  st=$(echo "$a" | sed -n 1p); irq=$(echo "$a" | sed -n 2p); pr=$(echo "$a" | tail -1)
  echo "$(date -u +%T) boot $n: COM5 from $off, login after $tl s (guest up $up s at SSH), iomem=relaxed $io, watch $wa; SD1 timeouts: boot $bt, after the stress $st; mmc0 irqs $irq; $r probe $pr" >> "$T"
  if [ "$pr" = FIRED ] || [ "$st" != 0 ] || [ "$bt" != 0 ] || cap; then
    { echo "== boot $n: the probe's log"; g 'cat /run/sd1-irq-probe.log; sudo dmesg | grep -m3 -E "Timeout waiting|recovery failed|I/O error"'; } >> "$T"
    exit 3
  fi
done
echo "$(date -u +%T) boots $first-$last done" >> "$T"
