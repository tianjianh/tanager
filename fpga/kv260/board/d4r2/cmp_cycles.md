- **d4r2-pmpfix** (`baseline_boot_1.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_2.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_3.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4r2-pmpfix 18.648 s (3 boots, spread 0.5%)

| test | d4r2-pmpfix cycles/op | spread |
|---|---|---|
| forkexec | 2,199,575 | 1.3% |
| syscall | 620 | 1.8% |
| memcpy-64 | 65.77 | 0.2% |
| memset-64 | 34.92 | 0.2% |
| memcpy-4096 | 1,027 | 0.9% |
| memset-4096 | 699 | 1.1% |
| memcpy-1048576 | 821,482 | 0.1% |
| memset-1048576 | 552,413 | 0.3% |
| pipe | 201,360 | 2.0% |
| tmpfs-write | 200,055 | 0.7% |
| tmpfs-read | 67,394 | 0.7% |
| pagefault | 4,563 | 0.5% |
| tlbwalk | 64.57 | 0.1% |
| gzip | 1,447,350,891 | 0.4% |
| sha256sum | 167,731,698 | 0.7% |
| coremark-a | 220,006 | 0.2% |
| coremark-b | 233,169 | 0.4% |
| dhrystone | 206 | 0.5% |
| coremark-a-imafd | 219,649 | 0.9% |
| coremark-b-imafd | 230,379 | 0.3% |
| dhrystone-imafd | 205 | 0.2% |
