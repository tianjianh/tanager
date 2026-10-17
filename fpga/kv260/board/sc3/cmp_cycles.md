- **smt2x2-70MHz-p0f** (`p0f_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **smt2x2-100MHz-sc3** (`sc3_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **smt2x2-100MHz-sc3** (`sc3_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **smt2x2-100MHz-sc3** (`sc3_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): smt2x2-70MHz-p0f 1.728 s (1 boot, spread 0.0%); smt2x2-100MHz-sc3 1.289 s (3 boots, spread 0.4%, -25.43%)

| test | smt2x2-70MHz-p0f cycles/op | smt2x2-100MHz-sc3 (change) | spread |
|---|---|---|---|
| forkexec | 2,992,758 | 2,927,093 (-2.2%) | 1.0% |
| syscall | 508 | 501 (-1.3%) | 0.3% |
| memcpy-64 | 81.90 | 81.06 (-1.0%) | 0.2% |
| memset-64 | 62.31 | 61.69 (-1.0%) | 0.4% |
| memcpy-4096 | 1,208 | 1,197 (-0.9%) | 0.5% |
| memset-4096 | 728 | 721 (-0.9%) | 0.7% |
| memcpy-1048576 | 2,140,370 | 2,264,615 (+5.8%) | 1.7% |
| memset-1048576 | 966,181 | 867,092 (-10.3%) | 4.2% |
| pipe | 225,126 | 220,426 (-2.1%) | 14.4% |
| tmpfs-write | 205,116 | 205,281 (+0.1%) | 2.7% |
| tmpfs-read | 147,893 | 148,820 (+0.6%) | 0.8% |
| pagefault | 9,465 | 9,609 (+1.5%) | 1.7% |
| tlbwalk | 124 | 127 (+2.6%) | 0.7% |
| gzip | 1,860,029,874 | 1,827,357,496 (-1.8%) | 0.2% |
| sha256sum | 220,175,070 | 218,097,522 (-0.9%) | 0.1% |
| coremark-a | 364,266 | 361,131 (-0.9%) | 0.2% |
| coremark-b | 440,675 | 436,348 (-1.0%) | 0.1% |
| dhrystone | 409 | 405 (-1.0%) | 0.1% |
