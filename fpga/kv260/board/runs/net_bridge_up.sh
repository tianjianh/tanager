#!/bin/bash
# Stage C network step 2 (DR-147, an approved A53 change): br0 over eth0, so the RISC-V's virtio-net TAP can
# join the laptop's link. In memory only (nmcli save no: gone on reboot or NetworkManager restart), and under
# a NetworkManager checkpoint that rolls everything back in ROLLBACK_S seconds unless it is destroyed from a
# fresh SSH session (net_bridge_confirm). br0 keeps eth0's MAC and DHCP client ID (01:00:0a:35:2a:df:d8), so
# the laptop's connection sharing hands back the same lease, 192.168.137.177. Run detached (setsid): the
# SSH session that starts it drops while eth0 moves into the bridge. Log: ~/tanager/sc2net/bridge.log
set -u
L=$HOME/tanager/sc2net/bridge.log
exec >> "$L" 2>&1
NM="org.freedesktop.NetworkManager"
echo "=== $(date +%T) bridge up: before"
ip -br addr; ip route; nmcli -t -f NAME,DEVICE,ACTIVE con show
R=${ROLLBACK_S:-180}
# devices: all (empty array); flags 6 = DELETE_NEW_CONNECTIONS | DISCONNECT_NEW_DEVICES
cp=$(sudo busctl call $NM /org/freedesktop/NetworkManager $NM CheckpointCreate aouu 0 "$R" 6 | awk '{print $2}' | tr -d '"')
[ -n "$cp" ] || { echo "no checkpoint, nothing changed"; exit 1; }
echo "$cp" > "$HOME/tanager/sc2net/bridge.checkpoint"
echo "checkpoint $cp: everything rolls back at $(date -d "+$R seconds" +%T) unless confirmed"
sudo nmcli connection add type bridge ifname br0 con-name tg-br0 save no \
  bridge.stp no bridge.forward-delay 0 bridge.mac-address 00:0a:35:2a:df:d8 \
  ipv4.method auto ipv4.dhcp-client-id mac ipv6.method auto
sudo nmcli connection add type ethernet ifname eth0 con-name tg-br0-eth0 save no master br0 slave-type bridge
sudo nmcli connection up tg-br0
sudo nmcli connection up tg-br0-eth0
for i in $(seq 1 90); do ip -4 -br addr show br0 2>/dev/null | grep -q "192\.168\." && break; sleep 1; done
echo "=== $(date +%T) after ($i s)"
ip -br addr; ip route; ip -br link show master br0; nmcli -t -f NAME,DEVICE,ACTIVE con show
