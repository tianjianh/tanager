- **d4r2-100MHz** (`baseline_boot_1.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-100MHz** (`baseline_boot_2.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-100MHz** (`baseline_boot_3.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **dr187b-80MHz** (`dr187b_fh80.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=4 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=8 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4r2-100MHz 18.648 s (3 boots, spread 0.5%); dr187b-80MHz 22.893 s (1 boot, spread 0.0%, +22.76%)

| test | d4r2-100MHz instret/op | dr187b-80MHz (change) | spread |
|---|---|---|---|
| forkexec | 1,204,384 | 1,206,660 (+0.2%) | 0.8% |
| syscall | 452 | 454 (+0.4%) | 1.3% |
| memcpy-64 | 90.25 | 90.54 (+0.3%) | 0.1% |
| memset-64 | 45.69 | 45.81 (+0.3%) | 0.1% |
| memcpy-4096 | 1,938 | 1,942 (+0.2%) | 0.2% |
| memset-4096 | 691 | 692 (+0.2%) | 0.5% |
| memcpy-1048576 | 490,245 | 492,195 (+0.4%) | 0.1% |
| memset-1048576 | 174,667 | 176,709 (+1.2%) | 0.3% |
| pipe | 82,972 | 79,450 (-4.2%) | 1.9% |
| tmpfs-write | 110,983 | 110,647 (-0.3%) | 1.6% |
| tmpfs-read | 31,876 | 32,070 (+0.6%) | 0.3% |
| pagefault | 1,353 | 1,382 (+2.1%) | 0.4% |
| tlbwalk | 4.16 | 4.21 (+1.3%) | 2.0% |
| gzip | 1,041,481,351 | 1,044,646,267 (+0.3%) | 0.3% |
| sha256sum | 302,761,511 | 303,561,764 (+0.3%) | 0.1% |
| coremark-a | 340,900 | 341,762 (+0.3%) | 0.0% |
| coremark-b | 345,503 | 346,290 (+0.2%) | 0.1% |
| dhrystone | 325 | 326 (+0.3%) | 0.0% |
| coremark-a-imafd | 341,005 | 341,932 (+0.3%) | 0.1% |
| coremark-b-imafd | 345,241 | 346,187 (+0.3%) | 0.0% |
| dhrystone-imafd | 325 | 326 (+0.3%) | 0.0% |
