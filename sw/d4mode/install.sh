#!/bin/bash
# D4 modes, the A53's side (docs/spec/soc-d4-modes.md, step 4): on the KV260's Ubuntu, as root, from the package
# directory sw/d4mode/build.sh makes:
#   sudo bash install.sh            the mode check in the boot script, p1's tanager/ files and the tanager-mode tool
#   sudo bash install.sh --undo     the hook removed and the boot script regenerated without it
# The install keeps today's boot.scr.uimg and image.fit as *.tanager-pre (once, before the first change), installs
# tanager-mode in /usr/local/sbin, copies tanager/ to p1 (/boot/firmware/tanager), puts the hook in
# /etc/flash-kernel/ubootenv.d/tanager-mode and runs flash-kernel, which regenerates boot.scr.uimg (and image.fit,
# from the same kernel). Then it checks that every line of the hook is in the new script, verbatim; if not, it
# puts the kept script back and says so. It never writes the mode record: with none, every boot is ARM mode.
# The undo leaves p1's tanager/, the *.tanager-pre copies and the tool, which do nothing without the hook.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fw=/boot/firmware
hook=/etc/flash-kernel/ubootenv.d/tanager-mode
[ "$(id -u)" = 0 ] || { echo "$0: run as root" >&2; exit 1; }
[ -f "$fw/boot.scr.uimg" ] || { echo "$0: no $fw/boot.scr.uimg" >&2; exit 1; }

# the script inside the uImage (after the 64-byte header and the 8-byte length table), in a file: grep -q on a
# pipe would end tail early, which pipefail counts as a failure
pl=$(mktemp)
trap 'rm -f "$pl"' EXIT
payload() { tail -c +73 "$fw/boot.scr.uimg" > "$pl"; }

if [ "${1:-}" = --undo ]; then
  rm -f "$hook"
  flash-kernel
  payload
  if grep -q "tanager-mode" "$pl"; then echo "$0: the hook is still in boot.scr.uimg" >&2; exit 1; fi
  sync
  echo "undone: no hook; boot.scr.uimg regenerated without it"
  exit 0
fi
[ $# -eq 0 ] || { echo "usage: $0 [--undo]" >&2; exit 2; }
for f in tanager-mode ubootenv.d-tanager-mode tanager/riscv.scr; do
  [ -f "$here/$f" ] || { echo "$0: missing $here/$f" >&2; exit 1; }
done

for f in boot.scr.uimg image.fit; do
  [ -f "$fw/$f.tanager-pre" ] || cp -p "$fw/$f" "$fw/$f.tanager-pre"
done
install -m 755 "$here/tanager-mode" /usr/local/sbin/tanager-mode
mkdir -p "$fw/tanager"
cp "$here"/tanager/* "$fw/tanager/"
mkdir -p "$(dirname "$hook")"
install -m 644 "$here/ubootenv.d-tanager-mode" "$hook"
flash-kernel
payload
missing=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  grep -qxF -- "$line" "$pl" || { echo "$0: not in the new boot.scr.uimg: $line" >&2; missing=1; }
done < "$hook"
if [ $missing = 1 ]; then
  rm -f "$hook"
  cp -p "$fw/boot.scr.uimg.tanager-pre" "$fw/boot.scr.uimg"
  cp -p "$fw/image.fit.tanager-pre" "$fw/image.fit"
  sync
  echo "$0: the hook did not reach the script verbatim; the hook is removed and the kept script and FIT are back" >&2
  exit 1
fi
sync
echo "installed: the hook is in boot.scr.uimg ($(grep -c "tanager-mode" "$pl") lines name it); p1's tanager/:"
ls -la "$fw/tanager"
/usr/local/sbin/tanager-mode status
