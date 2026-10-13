#!/bin/bash
# Disk usage of the Tanager trees on this host, against the limits in conventions §9.
# On WSL, space freed inside the distro is reused by WSL but never returned to Windows,
# so the limits are on total WSL usage and on the Windows drive's free space.
#   bash tools/disk_report.sh
build="${TANAGER_BUILD:-$HOME/tanager-build}"
echo "== build trees ($build)"
du -sh "$build"/* 2>/dev/null | sort -h
echo "== tools and repos"
du -sh "$HOME/Xilinx" "$HOME/opt" "$HOME/src" "$HOME/tanager" 2>/dev/null
used_gb=$(df -BG --output=used / | tail -1 | tr -dc '0-9')
echo "== WSL used ${used_gb} GB (limit 95)"
[ "$used_gb" -gt 95 ] && echo "WARNING: over 95 GB used: clean up before starting new jobs"
if [ -d /mnt/c ]; then
  free_gb=$(df -BG --output=avail /mnt/c | tail -1 | tr -dc '0-9')
  echo "== host drive C: free ${free_gb} GB (limit 15)"
  [ "$free_gb" -lt 15 ] && echo "WARNING: under 15 GB free on the host: clean up before starting new jobs"
fi
exit 0
