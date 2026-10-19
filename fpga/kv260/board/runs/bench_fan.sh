#!/bin/bash
# bench_fan.sh APP PKGDIR NAME: DR-141's set (BOOTS boots, default 3) on any app with bench.sh, and beside it the
# fan every 30 s (fan_bench_NAME.txt in PKGDIR): the PL regulator's status when PKGDIR's tanager-host has `fan`,
# and the A53's AMS temperature, as d2_run.sh's bench mode did for d2. Every tanager-host call is guarded on APP
# holding the PL. fancontrol keeps running and BOARD_CTRL stays 0 (as after every load).
app=$1; pk=$2; name=$3; R=$HOME/tanager/runs
H=$pk/tanager-host; T1=$(echo /sys/devices/platform/ams/hwmon/hwmon*/temp1_input)
holds() { sudo xmutil listapps | awk -v a="$app" '$1 == a && $NF ~ /^0->/ { f = 1 } END { exit !f }'; }
( sleep 5; while pgrep -f "[b]ench.sh $app" > /dev/null; do
    holds && { date +%T; sudo $H fan 2>&1; echo "temp1 $(cat $T1), pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)"; }
    sleep 30; done ) > $pk/fan_bench_$name.txt 2>&1 &
BOOTS=${BOOTS:-3} $R/bench.sh $app $pk $name
wait
echo "fan samples: $(grep -c "^[0-9][0-9]:" $pk/fan_bench_$name.txt)"
