- **smt2x2-70MHz-p0f** (`p0f_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **smt2x2-100MHz-sc3** (`sc3_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **smt2x2-100MHz-sc3** (`sc3_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **smt2x2-100MHz-sc3** (`sc3_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): smt2x2-70MHz-p0f 1.728 s (1 boot, spread 0.0%); smt2x2-100MHz-sc3 1.289 s (3 boots, spread 0.4%, -25.43%)

| test | smt2x2-70MHz-p0f instret/op | smt2x2-100MHz-sc3 (change) | spread |
|---|---|---|---|
| forkexec | 1,362,887 | 1,339,065 (-1.7%) | 0.3% |
| syscall | 245 | 242 (-1.0%) | 0.0% |
| memcpy-64 | 90.21 | 89.84 (-0.4%) | 0.0% |
| memset-64 | 45.92 | 45.65 (-0.6%) | 0.1% |
| memcpy-4096 | 1,934 | 1,929 (-0.3%) | 0.1% |
| memset-4096 | 686 | 684 (-0.4%) | 0.1% |
| memcpy-1048576 | 506,285 | 498,420 (-1.6%) | 0.2% |
| memset-1048576 | 178,079 | 172,974 (-2.9%) | 0.3% |
| pipe | 67,483 | 65,979 (-2.2%) | 17.9% |
| tmpfs-write | 60,052 | 59,109 (-1.6%) | 5.4% |
| tmpfs-read | 36,962 | 36,333 (-1.7%) | 0.4% |
| pagefault | 2,563 | 2,543 (-0.8%) | 4.8% |
| tlbwalk | 4.80 | 4.30 (-10.4%) | 0.9% |
| gzip | 905,807,953 | 897,693,504 (-0.9%) | 0.1% |
| sha256sum | 341,313,908 | 340,361,172 (-0.3%) | 0.0% |
| coremark-a | 342,087 | 340,525 (-0.5%) | 0.0% |
| coremark-b | 347,313 | 345,418 (-0.5%) | 0.0% |
| dhrystone | 327 | 325 (-0.5%) | 0.0% |
