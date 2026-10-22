#!/bin/bash
# baseline_boots.sh COM5LOG OUTDIR FIRST LAST: from the laptop, boots FIRST..LAST of the "d4r2 + PMP fix" Linux baseline
# in RISC-V mode (the coordinator, 10-21). Each boot:
#   - Debian's reboot (its confirm unit keeps RISC-V mode) and the login on COM5 (logged by the caller into COM5LOG, with
#     serial_log_ts.ps1's UTC line stamps, which give the boot's timeline);
#   - SSH over the RISC-V's IPv6 link-local address (the laptop's ICS serves no DHCP), then systemd's "running";
#   - the wait for systemd-tmpfiles-clean.timer, which fires 15 min after boot, so that nothing else runs in the set;
#   - sudo bash ~/baseline/baseline_set.sh N, with its output in OUTDIR/baseline_boot_N.txt.
# It stops at a boot with no login within 8 minutes, which is the PMOD break's to recover.
L=$1; O=$2; first=$3; last=$4
K=$(dirname "$O")/riscv_known_hosts
R=(-F /dev/null -i "$HOME/.ssh/tanager_kv260_ed25519" -o IdentitiesOnly=yes -o UserKnownHostsFile="$K" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=30)
H="tanager@fe80::20a:35ff:fe2a:dfd8%8"
g() { timeout 2400 ssh "${R[@]}" "$H" "$@" < /dev/null 2>&1; }
mkdir -p "$O"
for n in $(seq "$first" "$last"); do
  off=$(stat -c %s "$L"); t0=$(date +%s)
  echo "$(date -u +%T) boot $n: the reboot command"
  g 'sudo systemd-run --on-active=2 --quiet /usr/sbin/reboot' > /dev/null || { echo "$(date -u +%T) boot $n: no SSH for the reboot: stop"; exit 1; }
  sleep 30
  ok=0
  for i in $(seq 1 90); do
    tail -c +$((off + 1)) "$L" | grep -a -q -E 'tanager login: tanager \(automatic login\)|tanager@tanager:~\$' && { ok=1; break; }
    sleep 5
  done
  tl=$(( $(date +%s) - t0 ))
  [ $ok = 1 ] || { echo "$(date -u +%T) boot $n: no login after $tl s: stop"; exit 2; }
  echo "$(date -u +%T) boot $n: login seen on COM5 $tl s after the reboot command"
  for i in $(seq 1 24); do g true > /dev/null && break; sleep 10; done
  for i in $(seq 1 30); do case "$(g 'systemctl is-system-running')" in running|degraded) break;; esac; sleep 10; done
  # The timer's AccuracySec is 1 min: it fires 15 to 16 min after boot.
  echo "$(date -u +%T) boot $n: $(g 'echo "systemd $(systemctl is-system-running) at $(cut -d" " -f1 /proc/uptime) s"; up=$(cut -d. -f1 /proc/uptime); [ $up -lt 960 ] && sleep $((960 - up)); sleep 30; echo "tmpfiles-clean exited at $(systemctl show systemd-tmpfiles-clean.service -p ExecMainExitTimestampMonotonic --value) us; the set starts at $(cut -d" " -f1 /proc/uptime) s"')"
  g "sudo bash /home/tanager/baseline/baseline_set.sh $n" > "$O/baseline_boot_$n.txt"
  echo "$(date -u +%T) boot $n: $(grep -c '^TGLB ' "$O/baseline_boot_$n.txt") TGLB lines, $(grep -c '^MEMGAP ' "$O/baseline_boot_$n.txt") MEMGAP lines, $(grep -c '^BASELINE-END' "$O/baseline_boot_$n.txt") end"
done
