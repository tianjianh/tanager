- **d2-4miss** (`d2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2-m6** (`d4s2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2-m6** (`d4s2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2-m6** (`d4s2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d2-4miss 1.181 s (3 boots, spread 0.9%); d4s2-m6 0.929 s (3 boots, spread 0.3%, -21.32%)

| test | d2-4miss cycles/op | d4s2-m6 (change) | spread |
|---|---|---|---|
| forkexec | 2,770,574 | 2,069,659 (-25.3%) | 1.0% |
| syscall | 502 | 426 (-15.1%) | 0.8% |
| memcpy-64 | 81.09 | 64.83 (-20.1%) | 0.1% |
| memset-64 | 61.76 | 34.46 (-44.2%) | 0.3% |
| memcpy-4096 | 1,198 | 1,009 (-15.8%) | 0.5% |
| memset-4096 | 722 | 687 (-4.8%) | 1.0% |
| memcpy-1048576 | 1,406,383 | 1,235,609 (-12.1%) | 1.6% |
| memset-1048576 | 758,908 | 806,316 (+6.2%) | 20.6% |
| pipe | 181,315 | 126,582 (-30.2%) | 23.5% |
| tmpfs-write | 154,678 | 118,635 (-23.3%) | 3.1% |
| tmpfs-read | 128,385 | 71,559 (-44.3%) | 0.7% |
| pagefault | 9,108 | 7,702 (-15.4%) | 2.1% |
| tlbwalk | 115 | 113 (-1.1%) | 0.7% |
| gzip | 1,591,146,548 | 1,250,270,695 (-21.4%) | 0.3% |
| sha256sum | 217,090,578 | 181,946,287 (-16.2%) | 0.2% |
| coremark-a | 361,162 | 216,938 (-39.9%) | 0.5% |
| coremark-b | 436,527 | 229,159 (-47.5%) | 0.3% |
| dhrystone | 405 | 202 (-50.1%) | 0.4% |
