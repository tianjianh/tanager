- **d4r1-stageC** (`d4r1_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1-stageC** (`d4r1_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1-stageC** (`d4r1_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_1.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_2.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-pmpfix** (`baseline_boot_3.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4r1-stageC 0.831 s (3 boots, spread 0.4%); d4r2-pmpfix 18.648 s (3 boots, spread 0.5%, +2143.07%)

| test | d4r1-stageC instret/op | d4r2-pmpfix (change) | spread |
|---|---|---|---|
| forkexec | 1,326,954 | 1,204,384 (-9.2%) | 0.8% |
| syscall | 241 | 452 (+87.2%) | 1.3% |
| memcpy-64 | 89.69 | 90.25 (+0.6%) | 0.1% |
| memset-64 | 45.37 | 45.69 (+0.7%) | 0.1% |
| memcpy-4096 | 1,927 | 1,938 (+0.5%) | 0.2% |
| memset-4096 | 683 | 691 (+1.1%) | 0.5% |
| memcpy-1048576 | 483,772 | 490,245 (+1.3%) | 0.1% |
| memset-1048576 | 170,065 | 174,667 (+2.7%) | 0.5% |
| pipe | 64,642 | 82,972 (+28.4%) | 27.9% |
| tmpfs-write | 56,703 | 110,983 (+95.7%) | 5.0% |
| tmpfs-read | 35,516 | 31,876 (-10.2%) | 0.4% |
| pagefault | 2,502 | 1,353 (-45.9%) | 4.2% |
| tlbwalk | 4.16 | 4.16 (-0.2%) | 2.0% |
| gzip | 892,119,575 | 1,041,481,351 (+16.7%) | 0.3% |
| sha256sum | 340,024,434 | 302,761,511 (-11.0%) | 0.1% |
| coremark-a | 339,094 | 340,900 (+0.5%) | 0.0% |
| coremark-b | 343,348 | 345,503 (+0.6%) | 0.1% |
| dhrystone | 323 | 325 (+0.5%) | 0.0% |
| coremark-a-imafd | - | 341,005 | 0.1% |
| coremark-b-imafd | - | 345,241 | 0.0% |
| dhrystone-imafd | - | 325 | 0.0% |
