- **d4r2-pmpfix** (`baseline_boot_1.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_2.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_3.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4r2-pmpfix 18.648 s (3 boots, spread 0.5%)

| test | d4r2-pmpfix ns/op | spread |
|---|---|---|
| forkexec | 21,995,752 | 1.3% |
| syscall | 6,197 | 1.8% |
| memcpy-64 | 658 | 0.2% |
| memset-64 | 349 | 0.2% |
| memcpy-4096 | 10,274 | 0.9% |
| memset-4096 | 6,994 | 1.1% |
| memcpy-1048576 | 8,214,836 | 0.1% |
| memset-1048576 | 5,524,148 | 0.3% |
| pipe | 2,013,605 | 2.0% |
| tmpfs-write | 2,000,551 | 0.7% |
| tmpfs-read | 673,944 | 0.7% |
| pagefault | 45,629 | 0.5% |
| tlbwalk | 646 | 0.1% |
| gzip | 14,473,509,500 | 0.4% |
| sha256sum | 1,677,317,900 | 0.7% |
| coremark-a | 2,200,058 | 0.2% |
| coremark-b | 2,331,691 | 0.4% |
| dhrystone | 2,055 | 0.5% |
| coremark-a-imafd | 2,196,495 | 0.9% |
| coremark-b-imafd | 2,303,788 | 0.3% |
| dhrystone-imafd | 2,046 | 0.2% |
