# DR-147 stage C: the network on sc2, Debian 13 with virtio-net (2026-10-17)

**Package:** `debian-trixie-20261015b` from the SoC track ([`package_README.txt`](package_README.txt), [`SHA256SUMS`](SHA256SUMS)).
- **The image:** the Debian 13 image with systemd-networkd (DHCP on any Ethernet), resolved and timesyncd.
- **The host software:** `tanager-host` `c2cc421` (`1e5fca51…`, as in p0g): `--net TAP [--net-bridge BR]` serves virtio-net in slot 2, MAC `02:74:6e:67:72:01`.
- **The bitstream:** sc2's, unchanged (two `smt2` cores, the virtio window and the host DMA port).

## Step 1: a host-only link (nothing on the A53 changes): pass

[`net1_run1.txt`](net1_run1.txt), the RISC-V console [`linux_shell_net1.txt`](linux_shell_net1.txt), the A53 side [`net1_a53.txt`](net1_a53.txt); `runs/sc2_net1.sh`: `--blk` the image, `--rng`, `--net tanager0`, `--dbg`.
- **U-Boot:** `Net: eth0: virtio-net#2`. Debian booted as before.
- **systemd-networkd** took about 1 min 54 s to start at 70 MHz, then `multi-user.target` and the autologin.
- **On the RISC-V:**
  - `eth0` is UP on the `virtio_net` driver (`platform-10012000.virtio_mmio`), `02:74:6e:67:72:01`, with link-local `fe80::74:6eff:fe67:7201`.
  - `networkctl`: "degraded (configuring)": no DHCP server on a host-only link, as expected.
  - `ping -6 ff02::1%eth0`: answers from itself and from the A53's TAP (`fe80::dc64:69ff:fe64:da58`), 0% loss, 0.8–3.9 ms.
- **On the A53:**
  - `tanager0` is UP, and NetworkManager leaves it alone (`tun:unmanaged`).
  - `ping -6 fe80::74:6eff:fe67:7201%tanager0`: 3/3, 1.12–1.15 ms.
- **The exit:** `virtio: 42467 requests, 108 MiB read, 144 MiB written`; `virtio-net: 15 frames received, 51 sent, 10 dropped`; L2 error events 172 (the refused speculative fills of DR-151; sc2 predates the PMA fix). `tanager0` was gone after the run.
- **A board-script bug this run exposed, fixed:**
  - **The symptom:** `tg.sh shell` gave up one second after the load ("no login prompt"), so the commands were typed through the console FIFO by hand, and the poweroff with them.
  - **The cause:** its liveness check `kill -0` on the `sudo` process can fail with EPERM while `sudo` sets up.
  - **The fix:** `tg.sh` now checks `/proc/PID` (`alive`).

## Step 2: bridged onto the laptop's link: pass

**The bridge on the A53** (an approved A53 change; [the change log](../../README.md#a53-os-changes-change-log), [`bridge.log`](bridge.log)): `br0` over `eth0`, made in memory with NetworkManager, the A53's renderer.
- **The connections:** `tg-br0` with `eth0`'s MAC and DHCP client ID `mac`, and `tg-br0-eth0`, both `save no`.
- **How it was applied:** [`../runs/net_bridge_up.sh`](../runs/net_bridge_up.sh), run detached under a NetworkManager checkpoint that rolls everything back in 180 s. It was confirmed from a fresh SSH session ([`../runs/net_bridge_confirm.sh`](../runs/net_bridge_confirm.sh)).
- **The switch:** `br0` came up in 2 s with the same lease (192.168.137.177), and the laptop's SSH was back within about 7 s.
- **The undo:** [`../runs/net_bridge_down.sh`](../runs/net_bridge_down.sh), or any reboot.
- **Why not `netplan try`:** it does not revert bridges.

**The run** ([`net2_run1.txt`](net2_run1.txt), console [`linux_shell_net2.txt`](linux_shell_net2.txt); `runs/sc2_net2.sh`: `--net tanager0 --net-bridge br0`):
- **The lease:** `eth0 192.168.137.64/24`, "Address: 192.168.137.64 (DHCPv4 via 192.168.137.1)", networkd "routable (configured)".
- **Reaching the A53:** `ping 192.168.137.177` 3/3, 0.9–2.7 ms.
- **DNS:** `resolvectl query deb.debian.org` resolves `146.75.94.132` and `2a04:4e42:87::644`.
- **The clock:** `timedatectl`: "System clock synchronized: yes", NTP active, the right UTC time.
- **Debian's mirror:** `sudo apt-get update`: "Fetched 16.5 MB in 3min 16s (84.4 kB/s)", "Reading package lists...". Package lists only; nothing was installed.
- **From the A53:** `tanager0` was in `br0` with `eth0`. The RISC-V at 192.168.137.64 answered 3/3, about 1.1 ms.
- **The exit:** `virtio: 14367 requests, 115 MiB read, 209 MiB written`; `virtio-net: 11596 frames received, 486 sent, 11 dropped`. Login at 280 s, commands done at 653 s, power-off at 685 s (`boot exit 0`). L2 error events 188 (DR-151's refused fills).
- **For the SoC track:**
  - virtio-net's rate is low (84 kB/s for apt).
  - About 10 frames are dropped per boot.
  - `systemd-networkd` takes about 1 min 54 s to start at 70 MHz, close to its 2 min 30 s limit.
- **State after the run:** `br0` stays up in memory for further network runs; `tanager0` is gone.

## Real work under Debian, try 1: apt could not install (network not ready, or no IPv4 route yet)

[`work_run1.txt`](work_run1.txt), console [`linux_shell_work.txt`](linux_shell_work.txt); `runs/sc2_work.sh` with [`../runs/debian_work_cmds.txt`](../runs/debian_work_cmds.txt). It installs `gcc`, `libc6-dev` and `sysbench`, builds and times a small C program, and runs a short `sysbench` set.
- **The bridge:** `br0` was already up (`runs/net_bridge_ensure.sh`, now each network run's first step).
- **The failure:** `apt-get install` failed: `E: Failed to fetch … Cannot initiate the connection to deb.debian.org:80 (2a04:4e42:87::644). - connect (101: Network is unreachable)` for three packages, so nothing was installed. The rest found no `gcc` or `sysbench`.
- **Reading:**
  - The laptop's sharing gives IPv4 only. The RISC-V has just a link-local IPv6, so apt's IPv6 tries fail at once, and apt should fall back to IPv4.
  - The commands ran right at the login, and this script did not print the address first. So the IPv4 lease was most likely not up yet.
- **The fix for the next try:**
  - wait for `systemd-networkd-wait-online -i eth0 -4`;
  - print the address and the route;
  - give apt `-o Acquire::ForceIPv4=true`.
