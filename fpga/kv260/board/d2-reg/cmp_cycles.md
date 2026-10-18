- **sc3-1miss** (`sc3_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **sc3-1miss** (`sc3_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **sc3-1miss** (`sc3_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): sc3-1miss 1.289 s (3 boots, spread 0.4%); d2-4miss 1.181 s (3 boots, spread 0.9%, -8.37%)

| test | sc3-1miss cycles/op | d2-4miss (change) | spread |
|---|---|---|---|
| forkexec | 2,927,093 | 2,770,574 (-5.3%) | 1.0% |
| syscall | 501 | 502 (+0.2%) | 0.8% |
| memcpy-64 | 81.06 | 81.09 (+0.0%) | 0.2% |
| memset-64 | 61.69 | 61.76 (+0.1%) | 0.4% |
| memcpy-4096 | 1,197 | 1,198 (+0.1%) | 0.5% |
| memset-4096 | 721 | 722 (+0.0%) | 1.0% |
| memcpy-1048576 | 2,264,615 | 1,406,383 (-37.9%) | 1.7% |
| memset-1048576 | 867,092 | 758,908 (-12.5%) | 20.5% |
| pipe | 220,426 | 181,315 (-17.7%) | 14.4% |
| tmpfs-write | 205,281 | 154,678 (-24.7%) | 3.1% |
| tmpfs-read | 148,820 | 128,385 (-13.7%) | 0.8% |
| pagefault | 9,609 | 9,108 (-5.2%) | 2.0% |
| tlbwalk | 127 | 115 (-9.9%) | 0.7% |
| gzip | 1,827,357,496 | 1,591,146,548 (-12.9%) | 0.3% |
| sha256sum | 218,097,522 | 217,090,578 (-0.5%) | 0.2% |
| coremark-a | 361,131 | 361,162 (+0.0%) | 0.2% |
| coremark-b | 436,348 | 436,527 (+0.0%) | 0.1% |
| dhrystone | 405 | 405 (+0.0%) | 0.1% |
