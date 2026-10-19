- **d2** (`d2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2** (`d2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2** (`d2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2** (`d4s2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2** (`d4s2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2** (`d4s2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d2 1.181 s (3 boots, spread 0.9%); d4s2 0.929 s (3 boots, spread 0.3%, -21.32%); d4r1 0.831 s (3 boots, spread 0.4%, -29.58%)

| test | d2 cycles/op | d4s2 (change) | d4r1 (change) | spread |
|---|---|---|---|---|
| forkexec | 2,770,574 | 2,069,659 (-25.3%) | 2,029,862 (-26.7%) | 1.0% |
| syscall | 502 | 426 (-15.1%) | 426 (-15.2%) | 0.8% |
| memcpy-64 | 81.09 | 64.83 (-20.1%) | 64.84 (-20.0%) | 0.2% |
| memset-64 | 61.76 | 34.46 (-44.2%) | 34.45 (-44.2%) | 0.3% |
| memcpy-4096 | 1,198 | 1,009 (-15.8%) | 1,009 (-15.8%) | 0.5% |
| memset-4096 | 722 | 687 (-4.8%) | 687 (-4.7%) | 1.0% |
| memcpy-1048576 | 1,406,383 | 1,235,609 (-12.1%) | 809,078 (-42.5%) | 1.6% |
| memset-1048576 | 758,908 | 806,316 (+6.2%) | 572,324 (-24.6%) | 20.6% |
| pipe | 181,315 | 126,582 (-30.2%) | 122,663 (-32.3%) | 23.5% |
| tmpfs-write | 154,678 | 118,635 (-23.3%) | 95,774 (-38.1%) | 3.1% |
| tmpfs-read | 128,385 | 71,559 (-44.3%) | 68,322 (-46.8%) | 0.7% |
| pagefault | 9,108 | 7,702 (-15.4%) | 5,538 (-39.2%) | 2.9% |
| tlbwalk | 115 | 113 (-1.1%) | 113 (-1.1%) | 0.8% |
| gzip | 1,591,146,548 | 1,250,270,695 (-21.4%) | 1,250,170,461 (-21.4%) | 0.5% |
| sha256sum | 217,090,578 | 181,946,287 (-16.2%) | 181,869,633 (-16.2%) | 0.2% |
| coremark-a | 361,162 | 216,938 (-39.9%) | 217,268 (-39.8%) | 0.5% |
| coremark-b | 436,527 | 229,159 (-47.5%) | 229,231 (-47.5%) | 0.4% |
| dhrystone | 405 | 202 (-50.1%) | 202 (-50.1%) | 0.4% |
