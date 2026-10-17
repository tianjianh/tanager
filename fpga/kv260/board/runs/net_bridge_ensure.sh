#!/bin/bash
# A stage C run's first step: make sure the A53's br0 is up. If it is (with an IPv4 lease), nothing changes.
# If not (after an A53 reboot), bring it up with net_bridge_up.sh under its NetworkManager checkpoint, then
# confirm it only if the path through the laptop works: a lease on br0 and a TCP connection out through the
# laptop's connection sharing (the laptop itself drops ping). Otherwise leave the checkpoint to roll back and
# fail, so the run stops. Run detached (setsid): the SSH session drops for a few seconds during the switch.
R=$HOME/tanager/runs
have_br0() { ip -4 -br addr show br0 2>/dev/null | grep -q "192\.168\."; }
path_ok() { have_br0 && timeout 8 bash -c "</dev/tcp/deb.debian.org/80" 2>/dev/null; }
if have_br0; then echo "br0 is up: $(ip -4 -br addr show br0)"; exit 0; fi
echo "br0 is not up: bringing it up under a checkpoint"
ROLLBACK_S=${ROLLBACK_S:-180} "$R/net_bridge_up.sh"
for i in $(seq 1 30); do path_ok && break; sleep 2; done
if path_ok; then
  "$R/net_bridge_confirm.sh" && echo "br0 up and confirmed: $(ip -4 -br addr show br0)"
else
  echo "br0 has no working path: not confirmed; the checkpoint rolls it back"
  exit 1
fi
