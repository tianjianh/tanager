- **d4s2** (`d4s2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2** (`d4s2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2** (`d4s2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4s2 0.929 s (3 boots, spread 0.3%); d4r1 0.831 s (3 boots, spread 0.4%, -10.50%)

| test | d4s2 instret/op | d4r1 (change) | spread |
|---|---|---|---|
| forkexec | 1,327,393 | 1,326,954 (-0.0%) | 0.3% |
| syscall | 241 | 241 (+0.0%) | 0.1% |
| memcpy-64 | 89.68 | 89.69 (+0.0%) | 0.1% |
| memset-64 | 45.37 | 45.37 (+0.0%) | 0.1% |
| memcpy-4096 | 1,927 | 1,927 (+0.0%) | 0.1% |
| memset-4096 | 683 | 683 (+0.0%) | 0.3% |
| memcpy-1048576 | 487,947 | 483,772 (-0.9%) | 0.2% |
| memset-1048576 | 172,446 | 170,065 (-1.4%) | 1.1% |
| pipe | 64,965 | 64,642 (-0.5%) | 27.9% |
| tmpfs-write | 56,963 | 56,703 (-0.5%) | 6.7% |
| tmpfs-read | 35,481 | 35,516 (+0.1%) | 0.5% |
| pagefault | 2,505 | 2,502 (-0.1%) | 4.2% |
| tlbwalk | 4.15 | 4.16 (+0.4%) | 1.2% |
| gzip | 892,033,741 | 892,119,575 (+0.0%) | 0.2% |
| sha256sum | 340,013,489 | 340,024,434 (+0.0%) | 0.0% |
| coremark-a | 339,051 | 339,094 (+0.0%) | 0.0% |
| coremark-b | 343,303 | 343,348 (+0.0%) | 0.0% |
| dhrystone | 323 | 323 (+0.0%) | 0.0% |
