| | boot 1 | boot 2 | boot 3 | mean | spread |
|---|---|---|---|---|---|
| kernel stamp at /init (s) | 18.681775 | 18.648307 | 18.580155 | 18.64 | 0.5% |
| systemd-analyze: kernel (s) | 52.047 | 51.687 | 52.163 | 51.97 | 0.9% |
| systemd-analyze: userspace (s) | 73.382 | 72.763 | 72.477 | 72.87 | 1.2% |
| systemd-analyze: total (s) | 125.43 | 124.45 | 124.641 | 124.8 | 0.8% |
| ttyS0 getty active (s after boot) | 124.334 | 122.735 | 122.852 | 123.3 | 1.3% |
| multi-user.target (s after boot) | 125.366 | 124.396 | 124.584 | 124.8 | 0.8% |
| gcc -O2 t.c, real (s) | 7.132 | 7.118 | 7.137 | 7.13 | 0.3% |
| gcc -O2 t.c, user + sys (s) | 4.778 | 4.742 | 4.79 | 4.77 | 1.0% |
| ./t, 100 M iterations, real (s) | 2.872 | 2.855 | 2.859 | 2.86 | 0.6% |
| 9-file project, 2 at a time, real (s) | 11.818 | 11.832 | 11.814 | 11.82 | 0.2% |
| 9-file project, user + sys (s) | 19.199 | 19.224 | 19.183 | 19.20 | 0.2% |
| sysbench cpu, 1 thread (events/s) | 46.93 | 47.04 | 47.08 | 47.02 | 0.3% |
| sysbench cpu, 2 threads (events/s) | 94.43 | 94.39 | 94.40 | 94.41 | 0.0% |
| sysbench memory 1 KiB, 1 thread (MiB/s) | 83.99 | 84.18 | 84.47 | 84.21 | 0.6% |
| sysbench memory 1 KiB, 2 threads (MiB/s) | 145.54 | 146.1 | 145.76 | 145.8 | 0.4% |
| sysbench threads, 2 threads, 10 s (events) | 780 | 782 | 780 | 780.7 | 0.3% |
| memgap clock (ns/call) | 985.9 | 984.8 | 984.7 | 985.1 | 0.1% |
| memgap rdtime (ns/read) | 204.7 | 204.8 | 204.6 | 204.7 | 0.1% |
| memgap wr1k (MiB/s) | 460.7 | 460.0 | 460.7 | 460.5 | 0.2% |
| memgap wr1m (MiB/s) | 180.5 | 181.0 | 181.0 | 180.8 | 0.3% |
| memgap wr16m (MiB/s) | 182.2 | 182.6 | 182.3 | 182.4 | 0.2% |
| memgap rd16m (MiB/s) | 140.7 | 140.5 | 139.2 | 140.1 | 1.1% |
| memgap chase16k (ns/load) | 31.0 | 31.6 | 31.7 | 31.43 | 2.2% |
| memgap chase256k (ns/load) | 469.3 | 432.1 | 432.4 | 444.6 | 8.4% |
| memgap chase64m (ns/load) | 695.6 | 695.7 | 696.5 | 695.9 | 0.1% |
| memgap pingpong (ns/round-trip) | 2220.8 | 2221.4 | 2187.5 | 2210 | 1.5% |
| memgap ev1 (ns/event) | 5407.1 | 5410.6 | 5409.1 | 5409 | 0.1% |
| memgap ev2local (ns/event) | 5829.2 | 5836.3 | 5832.0 | 5832 | 0.1% |
| memgap ev2shared (ns/event) | 11078.5 | 11071.3 | 11140.0 | 11097 | 0.6% |
