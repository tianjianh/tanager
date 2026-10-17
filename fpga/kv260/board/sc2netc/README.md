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

## Real work under Debian: gcc builds and runs a program on the RISC-V, and sysbench

`runs/sc2_work.sh` with [`../runs/debian_work_cmds.txt`](../runs/debian_work_cmds.txt), on B's image with `tanager-host` `52329089`, bridged.

**Try 2** ([`work_run2.txt`](work_run2.txt)):
- **The setup:** waited for the IPv4 lease (192.168.137.104), then `apt-get install gcc libc6-dev sysbench` with `Acquire::ForceIPv4`.
- **The failure:** most packages downloaded, but two failed with `Unable to connect to deb.debian.org:http:`, so nothing was installed. These were probably connection timeouts while apt's `http` method holds a full core at 70 MHz.

**Try 3** ([`work_run3.txt`](work_run3.txt), console [`linux_shell_work3.txt`](linux_shell_work3.txt)): the same, with `Acquire::Retries=5` and `Acquire::http::Timeout=120`, and `gcc libc6-dev` installed before `sysbench`.
- **The installs:**
  - `gcc libc6-dev` finished in 57 min 37 s ("Setting up gcc (4:14.2.0-1) …"), mostly dpkg's unpacking and configuring at 70 MHz: 813 MiB were written to the disk over the run.
  - `sysbench` took 2 min 45 s.
  - Versions: `gcc (Debian 14.2.0-19) 14.2.0`, `sysbench 1.0.20`.
- **A program built and run on the RISC-V:** a 100 M-iteration loop (`s += i ^ (i >> 3)`).
  - `gcc -O2` compiled it in 9.3 s (7.2 s user).
  - It ran in 5.4 s (5.3 s user) and printed `5007905533300608`, the same as on the 5950X (x86, gcc -O2).
- **sysbench:**

  | Test | Result |
  |---|---|
  | `cpu --threads=1` (20 s) | 26.96 events/s |
  | `cpu --threads=2` (20 s) | **54.65 events/s (2.03×)** |
  | `memory` (20 s, defaults) | 834.80 MiB, 41.48 MiB/s |
  | `threads --threads=2` (10 s) | 364 events |

- **Disk:** `/` went from 694 MB to 1.3 GB used of 7.8 GB.
- **Run time:** login at 277 s, commands done at 4,008 s, power-off at 4,036 s (`boot exit 0`).
- **Counters:**
  - L2 error events 144 (DR-151's refused fills).
  - `virtio: 89093 requests, 342 MiB read, 813 MiB written`; `virtio-net: 45657 frames received, 2181 sent, 10 dropped`.
