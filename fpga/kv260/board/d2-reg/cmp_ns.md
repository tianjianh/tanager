- **sc3-1miss** (`sc3_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **sc3-1miss** (`sc3_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **sc3-1miss** (`sc3_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d2-4miss** (`d2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): sc3-1miss 1.289 s (3 boots, spread 0.4%); d2-4miss 1.181 s (3 boots, spread 0.9%, -8.37%)

| test | sc3-1miss ns/op | d2-4miss (change) | spread |
|---|---|---|---|
| forkexec | 29,270,934 | 27,705,735 (-5.3%) | 1.0% |
| syscall | 5,011 | 5,021 (+0.2%) | 0.8% |
| memcpy-64 | 811 | 811 (+0.0%) | 0.2% |
| memset-64 | 617 | 618 (+0.1%) | 0.4% |
| memcpy-4096 | 11,970 | 11,978 (+0.1%) | 0.5% |
| memset-4096 | 7,213 | 7,216 (+0.0%) | 1.0% |
| memcpy-1048576 | 22,646,153 | 14,063,838 (-37.9%) | 1.7% |
| memset-1048576 | 8,670,925 | 7,589,109 (-12.5%) | 20.5% |
| pipe | 2,204,262 | 1,813,145 (-17.7%) | 14.4% |
| tmpfs-write | 2,052,813 | 1,546,779 (-24.7%) | 3.1% |
| tmpfs-read | 1,488,200 | 1,283,851 (-13.7%) | 0.8% |
| pagefault | 96,094 | 91,079 (-5.2%) | 2.0% |
| tlbwalk | 1,272 | 1,146 (-9.9%) | 0.7% |
| gzip | 18,273,575,900 | 15,911,466,000 (-12.9%) | 0.3% |
| sha256sum | 2,180,978,600 | 2,170,908,100 (-0.5%) | 0.2% |
| coremark-a | 3,611,308 | 3,611,622 (+0.0%) | 0.2% |
| coremark-b | 4,363,476 | 4,365,271 (+0.0%) | 0.1% |
| dhrystone | 4,049 | 4,050 (+0.0%) | 0.1% |
