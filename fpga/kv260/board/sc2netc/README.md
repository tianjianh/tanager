# DR-147 stage C: virtio-net speed, an A/B of tanager-host's idle wait (2026-10-17)

**Package:** `debian-trixie-20261015c` from the SoC track ([`package_README.txt`](package_README.txt), [`SHA256SUMS`](SHA256SUMS)).
- **The image:** `20261015b`'s, with systemd's default start and stop timeouts raised to 10 and 5 min for 70 MHz.
- **The host software:** `tanager-host` `a88547b` (`52329089…`). It waits in `ppoll` on the console and the TAP when idle; the old one slept 200 µs.
- **The bitstream:** sc2's, unchanged.

**The A/B** ([`ab_run.txt`](ab_run.txt); `runs/sc2_ab_both.sh` runs `runs/sc2_ab.sh` twice).
- **The setup:** each run starts from a clean copy of the image, bridged through `br0` (`net_bridge_ensure.sh` first).
- **In the RISC-V** ([`../runs/ab_cmds.txt`](../runs/ab_cmds.txt)):
  - `systemd-networkd-wait-online -i eth0 -4`;
  - `ping -c 10 -s 1400` to the A53;
  - `time sudo apt-get update`;
  - `time apt-get download` of the kernel package (112 MB) into `/tmp`, with `top -b -d 15 -n 4`.
- **On the A53:** `tanager-host`'s CPU time every 15 s ([`hostcpu_A.txt`](hostcpu_A.txt), [`hostcpu_B.txt`](hostcpu_B.txt): epoch seconds and utime+stime ticks).

| | A: `1e5fca51` (sleeps 200 µs) | B: `52329089` (`ppoll`) |
|---|---|---|
| Lease | 192.168.137.120 | 192.168.137.146 |
| `ping -s 1400`, 10 packets | 0% loss, avg 1.378 ms (1.036–2.893) | 0% loss, avg 1.314 ms (0.956–2.738) |
| `apt-get update` | "Fetched 16.5 MB in 3min 15s (84.6 kB/s)", real 5 min 41 s | "Fetched 16.5 MB in 3min 15s (85.0 kB/s)", real 5 min 38 s |
| `apt-get download linux-image-6.12.111+deb13-riscv64` | "Fetched 112 MB in 1min 29s (**1256 kB/s**)", real 1 min 59 s | "Fetched 112 MB in 1min 22s (**1370 kB/s**)", real 1 min 48 s |
| `top` during the download | `http` 88.8%, apt-get up to 87–94%; %Cpu 60–86 us, 9–39 sy | `http` 99.7%, apt-get up to 97%; %Cpu 44–48 us, 6–44 sy, 8–43 idle |
| virtio-net at the exit | 90,149 received, 3,353 sent, 10 dropped | 90,171 received, 3,053 sent, 10 dropped |
| `tanager-host` CPU on the A53 | 7–9% idle, 8–29% busy | 9% idle, 15–20% during the download (one 98% sample) |

**Reading:**
- **The link is not the limit.** A bulk download runs at 1.26–1.37 MB/s, 15× `apt-get update`'s 85 kB/s.
- **The guest's CPU at 70 MHz is.**
  - `apt-get update`'s rate is the index decompression and parsing.
  - The download is apt's single-threaded `http` method (receive and hash) at about one full core.
- **`ppoll` helps a little:** +9% on the download, −5% on the ping round trip. `tanager-host` is not the bottleneck.
- **10 frames dropped in both runs:** probably frames that arrive before the guest sets up its receive ring.
- **Correcting stage C's earlier note:** "virtio-net at 84 kB/s" was apt's index processing, not the network.
