#!/bin/bash
# d2_probe.sh: the SoC track's read-only probes for D2's sensor question (soc.md §8.2, the fan; package
# d2-probes-20261017 in ~/tanager/d2): which sensor the A53's fancontrol reads, and the PS and PL SYSMONs read
# through the AMS block with `tanager-host psrd` (always on, side-effect-free reads). Any Tanager app must hold
# the PL (the PL SYSMON is reachable only with the PL configured; psrd checks our host bridge first). It runs
# alongside a stress run, as the monitor's register reads do. No PS writes.
H=$HOME/tanager/d2/tanager-host
app=$(sudo xmutil listapps | awk '$NF ~ /^0->/ {print $1}')
case "$app" in tanager*) ;; *) echo "STOP: no Tanager app holds the PL (active: ${app:-none})"; exit 1;; esac
echo "tanager-host $(sha256sum $H | cut -c1-16); the PL holds $app"
echo "== 1. fancontrol's sensor"
cat /etc/fancontrol
for h in /sys/class/hwmon/hwmon*; do echo "$h $(cat $h/name) $(readlink -f $h/device)"; done
grep -H . /sys/bus/iio/devices/iio:device*/name
ls /sys/bus/iio/devices/iio:device*/ | grep -i temp; grep -H . /sys/bus/iio/devices/iio:device*/in_temp*_label 2>/dev/null
find /sys/firmware/devicetree/base -name io-channels | while read f; do echo "$f"; xxd "$f"; done
temps() { for h in /sys/class/hwmon/hwmon*; do for t in $h/temp*_input; do [ -e "$t" ] && printf '%s(%s) %s  ' "${t#/sys/class/hwmon/}" "$(cat $h/name)" "$(cat $t)"; done; done; echo; }
echo "== 2. the SYSMONs through the AMS"
sudo $H psrd 0xFFA50040 2
echo "hwmon before: $(temps)"
sudo $H psrd 0xFFA50800
sudo $H psrd 0xFFA50C00
echo "hwmon after:  $(temps)"
sudo $H psrd 0xFFA50900 5
sudo $H psrd 0xFFA50D00 5
sudo $H psrd 0xFFA50D18 4
echo "fancontrol $(systemctl is-active fancontrol), pwm1 $(cat /sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1)/255"
