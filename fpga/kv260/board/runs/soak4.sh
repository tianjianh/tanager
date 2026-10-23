#!/bin/bash
# soak4.sh: the four-hart soak (the coordinator, 10-22): dr187b's four harts under load for hours, built only from the
# scripts already in use. It runs on the RISC-V's Debian as root, started with
#   sudo systemd-run --unit=soak4 --collect /bin/bash /home/tanager/soak4.sh
# so it outlives the SSH session (--setenv=SOAK_DIR=DIR for another folder than ~/soak4). Stop it with
# `sudo touch DIR/stop`: it ends before its next step.
# Each round writes one line per step to ~/soak4/soak.log, each ending in PASS or FAIL:
#   A. one pass of d4r2's stress (~/stress/stress.sh, fed "q" so that it stops after one pass), run as tanager and
#      pinned to core 0 (CPUs 0 and 1), while the DR-141 set (tg-lbench.sh 1) runs pinned to core 1 (CPUs 2 and 3);
#   B. the same with the cores swapped;
#   C. the same, both unpinned;
#   D. hart_check.sh: every hart alone, every pair, then all four at once;
#   E. hsm_rounds.sh 1: CPUs 1-3 off and on again.
# After each step the kernel's new lines are checked for trouble. A DR-141 set passes with TGLB-END status=0, no
# TGLB-FAIL, no CoreMark CRC error, and each of its 4 CoreMark runs validated or only under CoreMark's 10 s rule (a
# note, not a failure: beside the stress its sizing can pick too few iterations); a stress pass with ok=1.
H=/home/tanager; S=${SOAK_DIR:-$H/soak4}; B=$H/baseline/bin
mkdir -p "$S" && cd "$S" || exit 1
L=$S/soak.log
BAD='Oops|BUG:|Kernel panic|rcu_.*stall|rcu: INFO|watchdog: BUG|soft lockup|hard LOCKUP|segfault|Unable to handle|blocked for more than'
log() { echo "$(date -u +%FT%TZ) up=$(cut -d' ' -f1 /proc/uptime) $*" >> "$L"; }
mark=$(dmesg | wc -l)
kcheck() {
  local now new; now=$(dmesg | wc -l); new=$(dmesg | tail -n +$((mark + 1)) | grep -E "$BAD"); mark=$now
  [ -z "$new" ] && log "$1 kernel PASS" || { log "$1 kernel FAIL"; echo "$new" | head -8 >> "$L"; }
}
pair() {  # pair NAME STRESS_CPUS DR141_CPUS (empty: unpinned)
  local n=$1 so=$S/r${r}_$1.stress dout=$S/r${r}_$1.tglb sp v e f
  local st=() dt=()
  [ -n "$2" ] && st=(taskset -c "$2"); [ -n "$3" ] && dt=(taskset -c "$3")
  echo q | sudo -u tanager -H "${st[@]}" bash "$H/stress/stress.sh" > "$so" 2>&1 &
  sp=$!
  (cd /tmp && PATH=$B:$PATH "${dt[@]}" sh "$B/tg-lbench.sh" 1) > "$dout" 2>&1
  wait "$sp"
  if grep -q "^STRESS pass 1 ok=1" "$so"; then log "r$r $n stress PASS $(grep -o '^STRESS pass 1 .*' "$so" | cut -d' ' -f6-9)"
  else log "r$r $n stress FAIL"; grep STRESS "$so" | head -5 >> "$L"; fi
  v=$(grep -c "Correct operation validated" "$dout"); e=$(grep -c "^TGLB-END status=0" "$dout"); f=$(grep -c "^TGLB-FAIL" "$dout")
  # CoreMark's own checks: a CRC error is a wrong result; "Must execute for at least 10 secs" is its timing rule,
  # which its sizing trips when its calibration ran slowly beside the stress (the CRCs are still checked).
  c=$(grep -c -E "ERROR! (seed|list|matrix|state)" "$dout"); short=$(grep -c "Must execute for at least 10 secs" "$dout")
  note=""; [ "$short" != 0 ] && note=" (note: $short CoreMark run(s) under 10 s, CoreMark's timing rule; CRCs right)"
  if [ "$e" = 1 ] && [ "$f" = 0 ] && [ "$c" = 0 ] && [ $((v + short)) = 4 ]; then
    log "r$r $n DR-141 PASS $(awk '/^TGLB coremark-a / { for (i = 1; i <= NF; i++) if ($i ~ /^cycles=/) print "coremark-a", $i }' "$dout")$note"
  else log "r$r $n DR-141 FAIL validated=$v short=$short crc-errors=$c end=$e fails=$f"; grep -E "TGLB-FAIL|ERROR|rror" "$dout" | head -5 >> "$L"; fi
  kcheck "r$r $n"
}
log "SOAK4-BEGIN nproc=$(nproc) online=$(cat /sys/devices/system/cpu/online)"
r=0
while [ ! -e "$S/stop" ]; do
  r=$((r + 1))
  pair A 0,1 2,3; [ -e "$S/stop" ] && break
  pair B 2,3 0,1; [ -e "$S/stop" ] && break
  pair C "" ""; [ -e "$S/stop" ] && break
  bash "$H/hart_check.sh" "soak-r$r" > "$S/r${r}_D.hartcheck" 2>&1
  f=$(grep -o "fails=[0-9]*" "$S/r${r}_D.hartcheck" | tail -1)
  if [ "$f" = fails=0 ]; then log "r$r D hart_check PASS"; else log "r$r D hart_check FAIL ($f)"; grep FAIL "$S/r${r}_D.hartcheck" | head -5 >> "$L"; fi
  bash "$H/hsm_rounds.sh" 1 > "$S/r${r}_E.hsm" 2>&1
  if grep -q "HSM-END fails=0 trouble-lines=0 online=0-3" "$S/r${r}_E.hsm"; then log "r$r E hsm PASS"; else log "r$r E hsm FAIL"; tail -3 "$S/r${r}_E.hsm" >> "$L"; fi
  kcheck "r$r D+E"
  log "ROUND $r done"
done
echo 1 > /proc/sys/kernel/perf_user_access   # tg-lbench.sh sets 2
log "SOAK4-END after round $r"
chown -R tanager:tanager "$S"
