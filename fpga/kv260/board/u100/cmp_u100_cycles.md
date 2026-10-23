- **d4r2-100MHz** (`baseline_boot_1.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-100MHz** (`baseline_boot_2.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-100MHz** (`baseline_boot_3.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **dr187b-80MHz** (`dr187b_fh80.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=4 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=8 perf_errno=0; TGLB-END status=0
- **u100-100MHz** (`u100_set.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=4 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=8 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4r2-100MHz 18.648 s (3 boots, spread 0.5%); dr187b-80MHz 22.893 s (1 boot, spread 0.0%, +22.76%); u100-100MHz 18.522 s (1 boot, spread 0.0%, -0.68%)

| test | d4r2-100MHz cycles/op | dr187b-80MHz (change) | u100-100MHz (change) | spread |
|---|---|---|---|---|
| forkexec | 2,199,575 | 2,146,664 (-2.4%) | 2,121,615 (-3.5%) | 1.3% |
| syscall | 620 | 625 (+0.8%) | 617 (-0.4%) | 1.8% |
| memcpy-64 | 65.77 | 66.16 (+0.6%) | 65.82 (+0.1%) | 0.2% |
| memset-64 | 34.92 | 35.08 (+0.4%) | 35.02 (+0.3%) | 0.2% |
| memcpy-4096 | 1,027 | 1,042 (+1.4%) | 1,030 (+0.2%) | 0.9% |
| memset-4096 | 699 | 700 (+0.1%) | 699 (-0.0%) | 1.1% |
| memcpy-1048576 | 821,482 | 728,552 (-11.3%) | 735,258 (-10.5%) | 0.1% |
| memset-1048576 | 552,413 | 558,567 (+1.1%) | 534,552 (-3.2%) | 0.3% |
| pipe | 201,360 | 197,725 (-1.8%) | 205,481 (+2.0%) | 2.0% |
| tmpfs-write | 200,055 | 188,161 (-5.9%) | 189,781 (-5.1%) | 0.7% |
| tmpfs-read | 67,394 | 64,158 (-4.8%) | 63,882 (-5.2%) | 0.7% |
| pagefault | 4,563 | 4,748 (+4.1%) | 4,964 (+8.8%) | 0.5% |
| tlbwalk | 64.57 | 51.90 (-19.6%) | 53.70 (-16.8%) | 0.1% |
| gzip | 1,447,350,891 | 1,422,722,314 (-1.7%) | 1,408,876,075 (-2.7%) | 0.4% |
| sha256sum | 167,731,698 | 168,239,404 (+0.3%) | 166,881,656 (-0.5%) | 0.7% |
| coremark-a | 220,006 | 221,587 (+0.7%) | 220,629 (+0.3%) | 0.2% |
| coremark-b | 233,169 | 234,418 (+0.5%) | 231,979 (-0.5%) | 0.4% |
| dhrystone | 206 | 205 (-0.2%) | 204 (-0.7%) | 0.5% |
| coremark-a-imafd | 219,649 | 221,122 (+0.7%) | 220,235 (+0.3%) | 0.9% |
| coremark-b-imafd | 230,379 | 230,646 (+0.1%) | 229,258 (-0.5%) | 0.3% |
| dhrystone-imafd | 205 | 204 (-0.1%) | 204 (-0.4%) | 0.2% |
