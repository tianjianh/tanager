- **d4r2-100MHz** (`baseline_boot_1.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-100MHz** (`baseline_boot_2.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-100MHz** (`baseline_boot_3.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **u100-100MHz** (`u100_set.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=4 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=8 perf_errno=0; TGLB-END status=0
- **rc2-100MHz** (`rc2_set.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=4 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=8 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4r2-100MHz 18.648 s (3 boots, spread 0.5%); u100-100MHz 18.522 s (1 boot, spread 0.0%, -0.68%); rc2-100MHz 19.172 s (1 boot, spread 0.0%, +2.81%)

| test | d4r2-100MHz instret/op | u100-100MHz (change) | rc2-100MHz (change) | spread |
|---|---|---|---|---|
| forkexec | 1,204,384 | 1,191,431 (-1.1%) | 1,195,845 (-0.7%) | 0.8% |
| syscall | 452 | 451 (-0.3%) | 451 (-0.3%) | 1.3% |
| memcpy-64 | 90.25 | 90.25 (+0.0%) | 90.17 (-0.1%) | 0.1% |
| memset-64 | 45.69 | 45.69 (-0.0%) | 45.67 (-0.0%) | 0.1% |
| memcpy-4096 | 1,938 | 1,935 (-0.2%) | 1,935 (-0.1%) | 0.2% |
| memset-4096 | 691 | 688 (-0.3%) | 688 (-0.4%) | 0.5% |
| memcpy-1048576 | 490,245 | 489,020 (-0.2%) | 489,051 (-0.2%) | 0.1% |
| memset-1048576 | 174,667 | 173,923 (-0.4%) | 175,020 (+0.2%) | 0.3% |
| pipe | 82,972 | 76,608 (-7.7%) | 77,163 (-7.0%) | 1.9% |
| tmpfs-write | 110,983 | 109,621 (-1.2%) | 109,838 (-1.0%) | 1.6% |
| tmpfs-read | 31,876 | 31,643 (-0.7%) | 31,529 (-1.1%) | 0.3% |
| pagefault | 1,353 | 1,356 (+0.2%) | 1,361 (+0.5%) | 0.4% |
| tlbwalk | 4.16 | 4.01 (-3.5%) | 4.06 (-2.4%) | 2.0% |
| gzip | 1,041,481,351 | 1,038,578,295 (-0.3%) | 1,038,977,378 (-0.2%) | 0.3% |
| sha256sum | 302,761,511 | 302,691,550 (-0.0%) | 302,704,450 (-0.0%) | 0.1% |
| coremark-a | 340,900 | 340,980 (+0.0%) | 340,851 (-0.0%) | 0.0% |
| coremark-b | 345,503 | 345,135 (-0.1%) | 345,205 (-0.1%) | 0.1% |
| dhrystone | 325 | 325 (-0.1%) | 325 (-0.0%) | 0.0% |
| coremark-a-imafd | 341,005 | 340,968 (-0.0%) | 340,942 (-0.0%) | 0.1% |
| coremark-b-imafd | 345,241 | 345,125 (-0.0%) | 345,159 (-0.0%) | 0.0% |
| dhrystone-imafd | 325 | 325 (+0.0%) | 325 (-0.0%) | 0.0% |
