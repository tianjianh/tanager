- **d4s2** (`d4s2_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2** (`d4s2_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4s2** (`d4s2_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r1** (`d4r1_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4s2 0.929 s (3 boots, spread 0.3%); d4r1 0.831 s (3 boots, spread 0.4%, -10.50%)

| test | d4s2 ns/op | d4r1 (change) | spread |
|---|---|---|---|
| forkexec | 20,696,595 | 20,298,619 (-1.9%) | 0.9% |
| syscall | 4,261 | 4,259 (-0.1%) | 0.3% |
| memcpy-64 | 648 | 648 (+0.0%) | 0.2% |
| memset-64 | 345 | 345 (-0.0%) | 0.3% |
| memcpy-4096 | 10,086 | 10,089 (+0.0%) | 0.5% |
| memset-4096 | 6,867 | 6,874 (+0.1%) | 0.8% |
| memcpy-1048576 | 12,356,091 | 8,090,781 (-34.5%) | 1.3% |
| memset-1048576 | 8,063,166 | 5,723,267 (-29.0%) | 20.6% |
| pipe | 1,265,819 | 1,226,632 (-3.1%) | 23.5% |
| tmpfs-write | 1,186,352 | 957,743 (-19.3%) | 3.1% |
| tmpfs-read | 715,595 | 683,217 (-4.5%) | 0.7% |
| pagefault | 77,022 | 55,377 (-28.1%) | 2.9% |
| tlbwalk | 1,133 | 1,133 (+0.1%) | 0.8% |
| gzip | 12,502,706,900 | 12,501,704,600 (-0.0%) | 0.5% |
| sha256sum | 1,819,464,400 | 1,818,696,300 (-0.0%) | 0.1% |
| coremark-a | 2,169,376 | 2,172,675 (+0.2%) | 0.5% |
| coremark-b | 2,291,590 | 2,292,306 (+0.0%) | 0.4% |
| dhrystone | 2,020 | 2,019 (-0.1%) | 0.4% |
