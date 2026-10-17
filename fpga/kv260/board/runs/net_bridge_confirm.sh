#!/bin/bash
# Keep the bridge: destroy the checkpoint net_bridge_up.sh made (from a fresh SSH session, which proves the
# laptop's path works through br0). The connections stay in memory only.
NM="org.freedesktop.NetworkManager"
cp=$(cat "$HOME/tanager/sc2net/bridge.checkpoint") || exit 1
sudo busctl call $NM /org/freedesktop/NetworkManager $NM CheckpointDestroy o "$cp" && echo "checkpoint $cp destroyed: br0 kept (in memory)"
echo "=== $(date +%T) confirmed" >> "$HOME/tanager/sc2net/bridge.log"
