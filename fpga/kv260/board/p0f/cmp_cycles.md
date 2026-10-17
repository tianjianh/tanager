- **st1-60MHz-3eed95f** (`default_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=1 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=2 perf_errno=0; TGLB-END status=0
- **st1-60MHz-3eed95f** (`default_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=1 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=2 perf_errno=0; TGLB-END status=0
- **st1-60MHz-3eed95f** (`default_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=1 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=2 perf_errno=0; TGLB-END status=0
- **smt2x2-70MHz-p0f** (`p0f_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): st1-60MHz-3eed95f 2.466 s (3 boots, spread 0.0%); smt2x2-70MHz-p0f 1.728 s (1 boot, spread 0.0%, -29.92%)

| test | st1-60MHz-3eed95f cycles/op | smt2x2-70MHz-p0f (change) | spread |
|---|---|---|---|
| forkexec | 3,234,975 | 2,992,758 (-7.5%) | 0.3% |
| syscall | 550 | 508 (-7.7%) | 0.1% |
| memcpy-64 | 81.27 | 81.90 (+0.8%) | 0.5% |
| memset-64 | 62.65 | 62.31 (-0.5%) | 0.3% |
| memcpy-4096 | 1,214 | 1,208 (-0.5%) | 0.4% |
| memset-4096 | 730 | 728 (-0.3%) | 0.4% |
| memcpy-1048576 | 2,296,413 | 2,140,370 (-6.8%) | 0.1% |
| memset-1048576 | 922,173 | 966,181 (+4.8%) | 2.9% |
| pipe | 229,624 | 225,126 (-2.0%) | 7.1% |
| tmpfs-write | 210,467 | 205,116 (-2.5%) | 2.0% |
| tmpfs-read | 146,941 | 147,893 (+0.6%) | 0.7% |
| pagefault | 9,641 | 9,465 (-1.8%) | 1.6% |
| tlbwalk | 122 | 124 (+1.5%) | 0.3% |
| gzip | 1,892,884,495 | 1,860,029,874 (-1.7%) | 0.2% |
| sha256sum | 221,782,893 | 220,175,070 (-0.7%) | 0.1% |
| coremark-a | 366,728 | 364,266 (-0.7%) | 0.1% |
| coremark-b | 442,151 | 440,675 (-0.3%) | 0.1% |
| dhrystone | 414 | 409 (-1.2%) | 0.1% |
