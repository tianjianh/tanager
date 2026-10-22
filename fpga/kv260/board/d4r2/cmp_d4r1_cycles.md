- **d4r1-stageC** (`d4r1_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1-stageC** (`d4r1_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1-stageC** (`d4r1_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_1.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_2.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_3.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4r1-stageC 0.831 s (3 boots, spread 0.4%); d4r2-pmpfix 18.648 s (3 boots, spread 0.5%, +2143.07%)

| test | d4r1-stageC cycles/op | d4r2-pmpfix (change) | spread |
|---|---|---|---|
| forkexec | 2,029,862 | 2,199,575 (+8.4%) | 1.3% |
| syscall | 426 | 620 (+45.5%) | 1.8% |
| memcpy-64 | 64.84 | 65.77 (+1.4%) | 0.2% |
| memset-64 | 34.45 | 34.92 (+1.4%) | 0.3% |
| memcpy-4096 | 1,009 | 1,027 (+1.8%) | 0.9% |
| memset-4096 | 687 | 699 (+1.7%) | 1.1% |
| memcpy-1048576 | 809,078 | 821,482 (+1.5%) | 0.7% |
| memset-1048576 | 572,324 | 552,413 (-3.5%) | 4.7% |
| pipe | 122,663 | 201,360 (+64.2%) | 5.4% |
| tmpfs-write | 95,774 | 200,055 (+108.9%) | 2.6% |
| tmpfs-read | 68,322 | 67,394 (-1.4%) | 0.7% |
| pagefault | 5,538 | 4,563 (-17.6%) | 2.9% |
| tlbwalk | 113 | 64.57 (-43.0%) | 0.8% |
| gzip | 1,250,170,461 | 1,447,350,891 (+15.8%) | 0.5% |
| sha256sum | 181,869,633 | 167,731,698 (-7.8%) | 0.7% |
| coremark-a | 217,268 | 220,006 (+1.3%) | 0.4% |
| coremark-b | 229,231 | 233,169 (+1.7%) | 0.4% |
| dhrystone | 202 | 206 (+1.8%) | 0.5% |
| coremark-a-imafd | - | 219,649 | 0.9% |
| coremark-b-imafd | - | 230,379 | 0.3% |
| dhrystone-imafd | - | 205 | 0.2% |
