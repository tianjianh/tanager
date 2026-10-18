#!/bin/bash
# d2_run.sh ref12|alone|bench|d1: stage D's D2 (soc.md §8.2: the fan's PL regulator) and DR-156's board check,
# with the SoC track's d2-smt2-c2-100 package (~/tanager/d2pkg, staged as the app tanager-d2); README steps:
#   ref12: step 0 on a fresh sc3 load (the reference; also d2-probes' reload check), then load d2: steps 1 and 2
#   alone: step 3, the regulator alone: fancontrol stopped and pwm1 PWM_A53 (default 1: 0 leaves the TTC output
#          idling low, which the regulator reads as the A53 asking 255, full speed) for at most 5 minutes, sampled
#          every 30 s; fancontrol restarted at once above 50 C, if the regulator's duty reads 0, or if the A53's
#          PWM reads 128 or more (the fan near full speed: not the curve alone)
#   bench: step 4, DR-141's set (3 boots) on d2 with a 30 s fan sampler beside it (fan_bench.txt)
#   d1:    step 5, d1's test on this bitstream
# Every tanager-host call checks first that the expected Tanager app holds the PL.
mode=${1:-ref12}
cd ~/tanager/tg || exit 1
P=$HOME/tanager/d2pkg; H=$P/tanager-host; R=$HOME/tanager/runs
FANS=$(echo /sys/devices/platform/pwm-fan/hwmon/hwmon*); T1=$(echo /sys/devices/platform/ams/hwmon/hwmon*/temp1_input)
holds() { sudo xmutil listapps | grep -q -E "^ *$1 .* 0->"; }
h() { local a=$1; shift; holds $a || { echo "STOP: $a does not hold the PL"; return 1; }; echo "\$ tanager-host $*"; sudo $H "$@"; }
st() { echo "$(date +%T) pwm1 $(cat $FANS/pwm1)/255, temp1 $(cat $T1), fancontrol $(systemctl is-active fancontrol)"; }
sysmon() { local a=$1; h $a psrd 0xFFA50800; h $a psrd 0xFFA50C00; h $a psrd 0xFFA50D00 5; h $a psrd 0xFFA50D18 4; }
num() { echo "$1" | sed -n "s/.*$2 \([0-9]*\)\/255.*/\1/p"; }
echo "tanager-host $(sha256sum $H | cut -c1-16); mode $mode"
case "$mode" in
ref12)
  echo "== step 0: the reference, on a fresh sc3 load"
  TG_APP=tanager-sc3 TG_DIR=$HOME/tanager/sc3 ./tg.sh load | grep -E "^loaded|^fan" || exit 1
  st; sysmon tanager-sc3
  echo "== step 1: load d2"
  n0=$(sudo dmesg | wc -l)
  TG_APP=tanager-d2 TG_DIR=$P ./tg.sh load | grep -E "^loaded|^fan" || { TG_APP=tanager-d2 TG_DIR=$P ./tg.sh restore; exit 1; }
  st; h tanager-d2 fan; h tanager-d2 info | grep -E "configuration|core clock|capabilities"
  echo "dmesg, new lines:"; sudo dmesg | tail -n +$((n0 + 1)) | grep -v "OF: overlay: WARNING"
  echo "== step 2: the regulator beside fancontrol, 6 readings 10 s apart"
  for i in 1 2 3 4 5 6; do st; h tanager-d2 fan; sleep 10; done
  sysmon tanager-d2; echo "hwmon channels: $(ls /sys/devices/platform/ams/hwmon/hwmon*/ | grep -c _input) inputs; temp: $(cat /sys/devices/platform/ams/hwmon/hwmon*/temp*_input | tr '\n' ' ')"
  st; TG_APP=tanager-d2 TG_DIR=$P ./tg.sh restore | tail -1; st;;
alone)
  echo "== step 3: the regulator alone (fancontrol stopped, at most 5 minutes)"
  TG_APP=tanager-d2 TG_DIR=$P ./tg.sh load | grep -E "^loaded|^fan" || exit 1
  st; h tanager-d2 fan || { TG_APP=tanager-d2 TG_DIR=$P ./tg.sh restore; exit 1; }
  w=${PWM_A53:-1}
  sudo systemctl stop fancontrol; echo $w | sudo tee $FANS/pwm1 > /dev/null; echo "fancontrol stopped, pwm1 written $w at $(date +%T)"
  abort=""
  for i in $(seq 10); do
    sleep 30; st; f=$(h tanager-d2 fan | tail -1); echo "$f"
    d=$(num "$f" duty); p=$(num "$f" "the A53's PWM"); t=$(cat $T1)
    [ "$t" -gt 50000 ] && { abort="temp1 $t above 50 C"; break; }
    { [ -z "$d" ] || [ "$d" = 0 ]; } && { abort="the regulator's duty reads '${d:-none}'"; break; }
    [ -n "$p" ] && [ "$p" -ge 128 ] && { abort="the A53's PWM reads $p/255 (the fan near full speed: not the curve alone)"; break; }
  done
  sudo systemctl start fancontrol; sleep 6; echo "fancontrol started again at $(date +%T)${abort:+ (ABORT: $abort)}"
  st; h tanager-d2 fan; TG_APP=tanager-d2 TG_DIR=$P ./tg.sh restore | tail -1; st;;
bench)
  echo "== step 4: DR-141's set on d2, 3 boots, the fan sampled every 30 s"
  ( while sleep 30; do pgrep -f "[b]ench.sh tanager-d2" > /dev/null || break; holds tanager-d2 && { date +%T; sudo $H fan; cat $T1; }; done ) > $P/fan_bench.txt 2>&1 &
  BOOTS=3 $R/bench.sh tanager-d2 $P d2
  wait; st;;
d1)
  echo "== step 5: d1's test on d2"
  TG_APP=tanager-d2 TG_DIR=$P ./tg.sh load | grep -E "^loaded|^fan" || exit 1
  h tanager-d2 load --fw $P/ps_d1.bin --kernel /dev/null --dtb /dev/null && h tanager-d2 run --timeout 10; echo "run exit $?"
  st; TG_APP=tanager-d2 TG_DIR=$P ./tg.sh restore | tail -1; st;;
esac
