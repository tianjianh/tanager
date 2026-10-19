- **d2-4miss** (`d2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2-m6** (`d4s2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2-m6** (`d4s2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2-m6** (`d4s2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d2-4miss 1.181 s (3 boots, spread 0.9%); d4s2-m6 0.929 s (3 boots, spread 0.3%, -21.32%)

| test | d2-4miss instret/op | d4s2-m6 (change) | spread |
|---|---|---|---|
| forkexec | 1,337,864 | 1,327,393 (-0.8%) | 0.4% |
| syscall | 242 | 241 (-0.4%) | 0.1% |
| memcpy-64 | 89.85 | 89.68 (-0.2%) | 0.0% |
| memset-64 | 45.65 | 45.37 (-0.6%) | 0.1% |
| memcpy-4096 | 1,930 | 1,927 (-0.1%) | 0.1% |
| memset-4096 | 684 | 683 (-0.1%) | 0.3% |
| memcpy-1048576 | 489,858 | 487,947 (-0.4%) | 0.2% |
| memset-1048576 | 171,866 | 172,446 (+0.3%) | 1.1% |
| pipe | 65,729 | 64,965 (-1.2%) | 24.2% |
| tmpfs-write | 57,579 | 56,963 (-1.1%) | 6.7% |
| tmpfs-read | 36,129 | 35,481 (-1.8%) | 0.5% |
| pagefault | 2,540 | 2,505 (-1.4%) | 4.2% |
| tlbwalk | 4.18 | 4.15 (-0.8%) | 1.1% |
| gzip | 895,530,911 | 892,033,741 (-0.4%) | 0.2% |
| sha256sum | 340,386,307 | 340,013,489 (-0.1%) | 0.0% |
| coremark-a | 340,564 | 339,051 (-0.4%) | 0.0% |
| coremark-b | 345,469 | 343,303 (-0.6%) | 0.0% |
| dhrystone | 325 | 323 (-0.7%) | 0.0% |
