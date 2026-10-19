- **d4s2** (`d4s2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2** (`d4s2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2** (`d4s2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4s2 0.929 s (3 boots, spread 0.3%); d4r1 0.831 s (3 boots, spread 0.4%, -10.50%)

| test | d4s2 cycles/op | d4r1 (change) | spread |
|---|---|---|---|
| forkexec | 2,069,659 | 2,029,862 (-1.9%) | 0.9% |
| syscall | 426 | 426 (-0.1%) | 0.3% |
| memcpy-64 | 64.83 | 64.84 (+0.0%) | 0.2% |
| memset-64 | 34.46 | 34.45 (-0.0%) | 0.3% |
| memcpy-4096 | 1,009 | 1,009 (+0.0%) | 0.5% |
| memset-4096 | 687 | 687 (+0.1%) | 0.8% |
| memcpy-1048576 | 1,235,609 | 809,078 (-34.5%) | 1.3% |
| memset-1048576 | 806,316 | 572,324 (-29.0%) | 20.6% |
| pipe | 126,582 | 122,663 (-3.1%) | 23.5% |
| tmpfs-write | 118,635 | 95,774 (-19.3%) | 3.1% |
| tmpfs-read | 71,559 | 68,322 (-4.5%) | 0.7% |
| pagefault | 7,702 | 5,538 (-28.1%) | 2.9% |
| tlbwalk | 113 | 113 (+0.1%) | 0.8% |
| gzip | 1,250,270,695 | 1,250,170,461 (-0.0%) | 0.5% |
| sha256sum | 181,946,287 | 181,869,633 (-0.0%) | 0.1% |
| coremark-a | 216,938 | 217,268 (+0.2%) | 0.5% |
| coremark-b | 229,159 | 229,231 (+0.0%) | 0.4% |
| dhrystone | 202 | 202 (-0.1%) | 0.4% |
