#!/bin/bash
# Undo the bridge: delete the in-memory connections and bring eth0's own connection back, under a checkpoint
# again (rolls back to the bridge if the laptop cannot reach the board within ROLLBACK_S). Run detached.
set -u
L=$HOME/tanager/sc2net/bridge.log
exec >> "$L" 2>&1
NM="org.freedesktop.NetworkManager"
echo "=== $(date +%T) bridge down: before"
ip -br addr; nmcli -t -f NAME,DEVICE,ACTIVE con show
R=${ROLLBACK_S:-180}
cp=$(sudo busctl call $NM /org/freedesktop/NetworkManager $NM CheckpointCreate aouu 0 "$R" 6 | awk '{print $2}' | tr -d '"')
echo "$cp" > "$HOME/tanager/sc2net/bridge.checkpoint"
echo "checkpoint $cp (rolls back at $(date -d "+$R seconds" +%T) unless confirmed)"
sudo nmcli connection delete tg-br0-eth0 tg-br0
sudo nmcli connection up "Wired connection 1"
for i in $(seq 1 90); do ip -4 -br addr show eth0 | grep -q "192\.168\." && break; sleep 1; done
echo "=== $(date +%T) after ($i s)"
ip -br addr; ip route; nmcli -t -f NAME,DEVICE,ACTIVE con show
