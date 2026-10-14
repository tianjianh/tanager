#!/bin/bash
# FPU regression (docs/spec/fpu.md, "Verification"). Exits non-zero if any job fails.
#   run_tests.sh short|long <tb_fpu> [seed]
#   short: TestFloat level 1 for every function, format and rounding mode (mulAdd capped),
#          directed divide/sqrt cases and random traffic on all units; about 5 minutes with JOBS=8
#   long:  level 2 for every function (mulAdd: a prefix of FMA_L2_N vectors per mode and format,
#          full level 2 is 1.5e10 (S) / 1.8e11 (D) cases), plus long random and directed runs
# JOBS (default 8) jobs run in parallel; logs go to $LOGDIR (default: next to the testbench).
set -u
mode=${1:?short|long}
tb=${2:?path to tb_fpu}
seed=${3:-$(date +%s)}
jobs=${JOBS:-8}
logdir=${LOGDIR:-$(dirname "$tb")/logs_$mode}
fma_l2_n=${FMA_L2_N:-20000000}
mkdir -p "$logdir"
rm -f "$logdir"/*.log
command -v testfloat_gen >/dev/null || { echo "testfloat_gen not on PATH: source tools/env.sh"; exit 2; }

rms=(-rnear_even -rminMag -rmin -rmax -rnear_maxMag)
list=$(mktemp)
trap 'rm -f "$list"' EXIT

# One job per line: <log name> <shell command>
tf() {  # tf <level> <function> <rm index> [max vectors]
  local lvl=$1 f=$2 r=$3 n=${4:-}
  local ex=""
  case $f in *_to_i*|*_to_ui*) ex=-exact ;; esac
  local head=""
  [ -n "$n" ] && head="| head -n $n"
  echo "tf_${f}_l${lvl}_rm${r} testfloat_gen -level $lvl $ex ${rms[$r]} $f $head | $tb tf $f -rm $r" >> "$list"
}

fp_funcs="add sub mul div sqrt"
cvt_funcs="f32_to_i32 f32_to_ui32 f32_to_i64 f32_to_ui64 f64_to_i32 f64_to_ui32 f64_to_i64 f64_to_ui64
           i32_to_f32 ui32_to_f32 i64_to_f32 ui64_to_f32 i32_to_f64 ui32_to_f64 i64_to_f64 ui64_to_f64
           f32_to_f64 f64_to_f32"
cmp_funcs="eq lt le"

if [ "$mode" = short ]; then
  for r in 0 1 2 3 4; do
    for x in f32 f64; do
      for f in $fp_funcs; do tf 1 ${x}_$f $r; done
      tf 1 ${x}_mulAdd $r 1500000
    done
    for f in $cvt_funcs; do tf 1 $f $r; done
  done
  for x in f32 f64; do for f in $cmp_funcs; do tf 1 ${x}_$f 0; done; done
  echo "hard_div_sqrt $tb hard -seed $seed -n 3000" >> "$list"
  for k in 0 1 2; do
    echo "rand_all_$k $tb rand -seed $((seed + k)) -n 600000 -issue 80 -ready 85" >> "$list"
  done
  echo "rand_full_rate $tb rand -seed $((seed + 9)) -n 600000" >> "$list"
elif [ "$mode" = long ]; then
  for r in 0 1 2 3 4; do
    for x in f32 f64; do
      for f in $fp_funcs; do tf 2 ${x}_$f $r; done
      tf 1 ${x}_mulAdd $r
      echo "tf_${x}_mulAdd_l2prefix_rm${r} testfloat_gen -level 2 -seed $((seed + r)) ${rms[$r]} ${x}_mulAdd | head -n $fma_l2_n | $tb tf ${x}_mulAdd -rm $r" >> "$list"
    done
    for f in $cvt_funcs; do tf 2 $f $r; done
  done
  for x in f32 f64; do for f in $cmp_funcs; do tf 2 ${x}_$f 0; done; done
  for k in 0 1 2 3; do echo "hard_div_sqrt_$k $tb hard -seed $((seed + k)) -n 50000" >> "$list"; done
  for k in 0 1 2 3 4 5; do
    echo "rand_all_$k $tb rand -seed $((seed + k)) -n 5000000 -issue 80 -ready 85" >> "$list"
  done
  echo "rand_full_rate $tb rand -seed $((seed + 9)) -n 5000000" >> "$list"
else
  echo "unknown mode $mode"; exit 2
fi

echo "fpu $mode regression: $(wc -l < "$list") jobs, $jobs in parallel, seed $seed, logs in $logdir"
export logdir
start=$(date +%s)
# Each job's log ends with its summary line. A job's status is the testbench's (the last command
# of each pipeline); the testbench fails when it reads no vectors, so a broken generator is caught.
xargs -P "$jobs" -L 1 -I{} bash -c '
  line="{}"; name=${line%% *}; cmd=${line#* }
  if bash -c "$cmd" > "$logdir/$name.log" 2>&1; then echo "PASS $name: $(tail -n 1 "$logdir/$name.log")";
  else echo "FAIL $name (log $logdir/$name.log)"; tail -n 5 "$logdir/$name.log"; exit 1; fi' < "$list"
rc=$?
echo "fpu $mode regression: $( [ $rc -eq 0 ] && echo PASSED || echo FAILED ) in $(( $(date +%s) - start )) s"
exit $rc
