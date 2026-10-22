#!/bin/bash
# FP back-end regression (docs/spec/fpu.md, "Core integration"): tg_fp_exec with tg_fprf and
# tg_fpu, and tg_fcsr. Exits non-zero if any job fails.
#   run_be_tests.sh short|long <tb_fpx> <tb_fcsr> [seed]
#   short: random P4 streams (three stress settings: no flushes; flushes, early retirement and
#          B1 back-pressure; heavy flushing with 4 wakeup tags), each also with renaming across both
#          FP banks and the LSU's blocked selects (-cross 40 -fpblk 5, DR-179), TestFloat level 1 for
#          every function in RNE
#          (capped), fcsr streams
#   long:  more and longer random streams, TestFloat level 1 for every function in all five
#          modes (mulAdd capped), longer fcsr streams
# JOBS (default 16) jobs run in parallel; logs go next to the testbench.
set -u
mode=${1:?short|long}
tbx=${2:?path to tb_fpx}
tbc=${3:?path to tb_fcsr}
seed=${4:-$(date +%s)}
jobs=${JOBS:-16}
logdir=${LOGDIR:-$(dirname "$tbx")/logs_be_$mode}
mkdir -p "$logdir"
rm -f "$logdir"/*.log
command -v testfloat_gen >/dev/null || { echo "testfloat_gen not on PATH: source tools/env.sh"; exit 2; }

rms=(-rnear_even -rminMag -rmin -rmax -rnear_maxMag)
funcs="f32_add f64_add f32_sub f64_sub f32_mul f64_mul f32_mulAdd f64_mulAdd f32_div f64_div f32_sqrt
       f64_sqrt f32_eq f64_eq f32_lt f64_lt f32_le f64_le f32_to_i32 f32_to_ui32 f32_to_i64
       f32_to_ui64 f64_to_i32 f64_to_ui32 f64_to_i64 f64_to_ui64 i32_to_f32 ui32_to_f32 i64_to_f32
       ui64_to_f32 i32_to_f64 ui32_to_f64 i64_to_f64 ui64_to_f64 f32_to_f64 f64_to_f32"
stress=("-flush 0 -ret 0 -ready 100" "-flush 150 -ret 20 -ready 60" "-flush 40 -ret 40 -ready 30 -tags 4")

list=$(mktemp)
trap 'rm -f "$list"' EXIT
tf() {  # tf <function> <rm index> [max vectors]
  local f=$1 r=$2 n=${3:-}
  local ex=""
  case $f in *_to_i*|*_to_ui*) ex=-exact ;; esac
  local head=""
  [ -n "$n" ] && head="| head -n $n"
  echo "tfx_${f}_rm${r} testfloat_gen -level 1 $ex ${rms[$r]} $f $head | $tbx tf $f -rm $r" >> "$list"
}

if [ "$mode" = short ]; then
  for f in $funcs; do tf $f 0 30000; done
  for s in 0 1 2; do
    for k in 0 1 2 3; do
      echo "randx_s${s}_$k $tbx rand -seed $((seed + 10 * s + k)) -n 30000 ${stress[$s]}" >> "$list"
    done
    for k in 0 1; do
      echo "randc_s${s}_$k $tbx rand -seed $((seed + 10 * s + k + 5)) -n 30000 ${stress[$s]} -cross 40 -fpblk 5" >> "$list"
    done
  done
  for k in 0 1 2 3; do echo "fcsr_$k $tbc -seed $((seed + k)) -n 300000" >> "$list"; done
elif [ "$mode" = long ]; then
  for r in 0 1 2 3 4; do
    for f in $funcs; do
      case $f in *mulAdd) tf $f $r 1500000 ;; *) tf $f $r ;; esac
    done
  done
  for s in 0 1 2; do
    for k in 0 1 2 3 4 5 6 7; do
      echo "randx_s${s}_$k $tbx rand -seed $((seed + 10 * s + k)) -n 300000 ${stress[$s]}" >> "$list"
    done
    for k in 0 1 2 3; do
      echo "randc_s${s}_$k $tbx rand -seed $((seed + 10 * s + k + 5)) -n 300000 ${stress[$s]} -cross 40 -fpblk 5" >> "$list"
    done
  done
  for k in 0 1 2 3; do echo "fcsr_$k $tbc -seed $((seed + k)) -n 3000000" >> "$list"; done
else
  echo "unknown mode $mode"; exit 2
fi

echo "fp back-end $mode regression: $(wc -l < "$list") jobs, $jobs in parallel, seed $seed, logs in $logdir"
export logdir
start=$(date +%s)
xargs -P "$jobs" -L 1 -I{} bash -c '
  line="{}"; name=${line%% *}; cmd=${line#* }
  if bash -c "$cmd" > "$logdir/$name.log" 2>&1; then echo "PASS $name: $(tail -n 1 "$logdir/$name.log")";
  else echo "FAIL $name (log $logdir/$name.log)"; tail -n 5 "$logdir/$name.log"; exit 1; fi' < "$list"
rc=$?
echo "fp back-end $mode regression: $( [ $rc -eq 0 ] && echo PASSED || echo FAILED ) in $(( $(date +%s) - start )) s"
exit $rc
