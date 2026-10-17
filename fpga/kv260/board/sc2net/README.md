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
