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

| test | d2 ns/op | d4s2 (change) | d4r1 (change) | spread |
|---|---|---|---|---|
| forkexec | 27,705,735 | 20,696,595 (-25.3%) | 20,298,619 (-26.7%) | 1.0% |
| syscall | 5,021 | 4,261 (-15.1%) | 4,259 (-15.2%) | 0.8% |
| memcpy-64 | 811 | 648 (-20.1%) | 648 (-20.0%) | 0.2% |
| memset-64 | 618 | 345 (-44.2%) | 345 (-44.2%) | 0.3% |
| memcpy-4096 | 11,978 | 10,086 (-15.8%) | 10,089 (-15.8%) | 0.5% |
| memset-4096 | 7,216 | 6,867 (-4.8%) | 6,874 (-4.7%) | 1.0% |
| memcpy-1048576 | 14,063,838 | 12,356,091 (-12.1%) | 8,090,781 (-42.5%) | 1.6% |
| memset-1048576 | 7,589,109 | 8,063,166 (+6.2%) | 5,723,267 (-24.6%) | 20.6% |
| pipe | 1,813,145 | 1,265,819 (-30.2%) | 1,226,632 (-32.3%) | 23.5% |
| tmpfs-write | 1,546,779 | 1,186,352 (-23.3%) | 957,743 (-38.1%) | 3.1% |
| tmpfs-read | 1,283,851 | 715,595 (-44.3%) | 683,217 (-46.8%) | 0.7% |
| pagefault | 91,079 | 77,022 (-15.4%) | 55,377 (-39.2%) | 2.9% |
| tlbwalk | 1,146 | 1,133 (-1.1%) | 1,133 (-1.1%) | 0.8% |
| gzip | 15,911,466,000 | 12,502,706,900 (-21.4%) | 12,501,704,600 (-21.4%) | 0.5% |
| sha256sum | 2,170,908,100 | 1,819,464,400 (-16.2%) | 1,818,696,300 (-16.2%) | 0.2% |
| coremark-a | 3,611,622 | 2,169,376 (-39.9%) | 2,172,675 (-39.8%) | 0.5% |
| coremark-b | 4,365,271 | 2,291,590 (-47.5%) | 2,292,306 (-47.5%) | 0.4% |
| dhrystone | 4,050 | 2,020 (-50.1%) | 2,019 (-50.1%) | 0.4% |
