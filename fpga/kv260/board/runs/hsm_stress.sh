#!/bin/bash
# hsm_stress.sh ROUNDS GAP: ROUNDS rounds of hart stop and start (hsm_rounds.sh 1 each, GAP seconds apart) while d4r2's
# stress runs pass after pass beside them (as tanager, unpinned, so its work moves as harts go and come back). This is
# the board round for soc-2's OpenSBI fence fix (tg1, 10-23): remote fences issued while a hart has just stopped are
# what made OpenSBI 1.9 fail a whole call. On the RISC-V's Debian as root.
# Each round's HSM-END line is printed; at the end, the stress passes and the kernel's failed-fence lines are counted,
# and every other kernel line from the window is listed.
R=${1:-30}; G=${2:-8}; H=/home/tanager; D=$(mktemp -d /tmp/hsm_stress.XXXXXX)
k0=$(dmesg | wc -l)
echo "HSMSTRESS-BEGIN rounds=$R gap=${G}s online=$(cat /sys/devices/system/cpu/online) $(date -u +%T)"
(while [ ! -e "$D/done" ]; do echo q | sudo -u tanager -H bash "$H/stress/stress.sh"; done) > "$D/stress.txt" 2>&1 &
sp=$!
sleep 15
for i in $(seq 1 "$R"); do
  bash "$H/hsm_rounds.sh" 1 | grep "^HSM-END" | sed "s/^/round $i: /"
  sleep "$G"
done
touch "$D/done"; wait "$sp"
echo "stress passes beside the rounds: $(grep -c '^STRESS pass 1 ok=1' "$D/stress.txt") ok, $(grep -c -E '^STRESS (FAIL|DMESG)' "$D/stress.txt") failing"
grep -E '^STRESS (FAIL|DMESG)' "$D/stress.txt" | head -5
echo "failed remote fences in the window: $(dmesg | tail -n +$((k0 + 1)) | grep -c '__sbi_rfence_v02_call.*failed')"
echo "the window's other kernel lines (CPUn: off left out):"; dmesg | tail -n +$((k0 + 1)) | grep -v -E 'CPU[0-9]+: off' | head -20
echo "HSMSTRESS-END online=$(cat /sys/devices/system/cpu/online) $(date -u +%T)"
rm -f "$D"/*; rmdir "$D"
