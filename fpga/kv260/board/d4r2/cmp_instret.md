- **d4r2-pmpfix** (`baseline_boot_1.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_2.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_3.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4r2-pmpfix 18.648 s (3 boots, spread 0.5%)

| test | d4r2-pmpfix instret/op | spread |
|---|---|---|
| forkexec | 1,204,384 | 0.8% |
| syscall | 452 | 1.3% |
| memcpy-64 | 90.25 | 0.1% |
| memset-64 | 45.69 | 0.1% |
| memcpy-4096 | 1,938 | 0.2% |
| memset-4096 | 691 | 0.5% |
| memcpy-1048576 | 490,245 | 0.1% |
| memset-1048576 | 174,667 | 0.3% |
| pipe | 82,972 | 1.9% |
| tmpfs-write | 110,983 | 1.6% |
| tmpfs-read | 31,876 | 0.3% |
| pagefault | 1,353 | 0.4% |
| tlbwalk | 4.16 | 2.0% |
| gzip | 1,041,481,351 | 0.3% |
| sha256sum | 302,761,511 | 0.1% |
| coremark-a | 340,900 | 0.0% |
| coremark-b | 345,503 | 0.1% |
| dhrystone | 325 | 0.0% |
| coremark-a-imafd | 341,005 | 0.1% |
| coremark-b-imafd | 345,241 | 0.0% |
| dhrystone-imafd | 325 | 0.0% |
