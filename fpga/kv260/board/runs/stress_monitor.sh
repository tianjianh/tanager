#!/bin/bash
# stress_monitor.sh LOG [CONSOLE]: while the boot runs, every 30 min (MON_S): the time, the guest's last stress line,
# the count of failures and kernel trouble on the console, the L2 error events and levels, the injector and
# the fan. Reads only (tanager-host dbg and inj through tg.sh's guard).
log=$1; con=${2:-$HOME/tanager/sc2netc/linux_shell.txt}; every=${MON_S:-1800}
cd ~/tanager/tg || exit 1
export TG_APP=${TG_APP:-tanager-sc2}
sleep 60
while pgrep -f "[t]anager-host boot" > /dev/null; do
  {
    echo "=== $(date +%T) A53 up $(cut -d' ' -f1 /proc/uptime) s"
    tr -d '\r' < $con | grep -a "STRESS pass" | tail -1
    echo "console: $(tr -d '\r' < $con | grep -a -c "STRESS pass") passes, $(tr -d '\r' < $con | grep -a -c -E "STRESS (FAIL|DMESG)") FAIL/DMESG lines, $(tr -d '\r' < $con | grep -a -c -E 'Oops|BUG:|Kernel panic|rcu_.*stall|rcu: INFO|soft lockup|hard LOCKUP|blocked for more than') kernel-trouble lines"
    ./tg.sh th dbg | grep -E "L2 error|levels"
    ./tg.sh th inj --stats | tail -1
    echo "fan: pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255, AMS temp1 $(( $(cat /sys/devices/platform/ams/hwmon/hwmon*/temp1_input) / 1000 )) C"
  } >> "$log" 2>&1
  for i in $(seq 1 $((every / 10))); do sleep 10; pgrep -f "[t]anager-host boot" > /dev/null || break; done
done
echo "=== $(date +%T) the boot has ended; monitor stops" >> "$log"
