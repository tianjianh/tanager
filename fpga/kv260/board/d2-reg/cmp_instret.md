- **sc3-1miss** (`sc3_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **sc3-1miss** (`sc3_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **sc3-1miss** (`sc3_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): sc3-1miss 1.289 s (3 boots, spread 0.4%); d2-4miss 1.181 s (3 boots, spread 0.9%, -8.37%)

| test | sc3-1miss instret/op | d2-4miss (change) | spread |
|---|---|---|---|
| forkexec | 1,339,065 | 1,337,864 (-0.1%) | 0.4% |
| syscall | 242 | 242 (+0.0%) | 0.0% |
| memcpy-64 | 89.84 | 89.85 (+0.0%) | 0.0% |
| memset-64 | 45.65 | 45.65 (+0.0%) | 0.1% |
| memcpy-4096 | 1,929 | 1,930 (+0.0%) | 0.1% |
| memset-4096 | 684 | 684 (-0.0%) | 0.3% |
| memcpy-1048576 | 498,420 | 489,858 (-1.7%) | 0.2% |
| memset-1048576 | 172,974 | 171,866 (-0.6%) | 1.0% |
| pipe | 65,979 | 65,729 (-0.4%) | 14.8% |
| tmpfs-write | 59,109 | 57,579 (-2.6%) | 6.7% |
| tmpfs-read | 36,333 | 36,129 (-0.6%) | 0.4% |
| pagefault | 2,543 | 2,540 (-0.1%) | 4.8% |
| tlbwalk | 4.30 | 4.18 (-2.8%) | 0.9% |
| gzip | 897,693,504 | 895,530,911 (-0.2%) | 0.2% |
| sha256sum | 340,361,172 | 340,386,307 (+0.0%) | 0.0% |
| coremark-a | 340,525 | 340,564 (+0.0%) | 0.0% |
| coremark-b | 345,418 | 345,469 (+0.0%) | 0.0% |
| dhrystone | 325 | 325 (+0.0%) | 0.0% |
