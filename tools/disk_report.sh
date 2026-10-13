#!/bin/bash
# Disk usage of the Tanager trees on this host, and the free space that really limits us: on WSL,
# the Windows drive that holds the virtual disk (conventions §9).
#   bash tools/disk_report.sh
build="${TANAGER_BUILD:-$HOME/tanager-build}"
echo "== build trees ($build)"
du -sh "$build"/* 2>/dev/null | sort -h
echo "== tools and repos"
du -sh "$HOME/Xilinx" "$HOME/opt" "$HOME/src" "$HOME/tanager" "$HOME"/xinstall-* 2>/dev/null
if [ -d /mnt/c ]; then
  free_gb=$(df -BG --output=avail /mnt/c | tail -1 | tr -dc '0-9')
  echo "== host drive C: free ${free_gb} GB"
  [ "$free_gb" -lt 25 ] && echo "WARNING: under 25 GB free: clean up before starting new jobs"
fi
exit 0
