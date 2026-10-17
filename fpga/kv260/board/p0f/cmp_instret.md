- **st1-60MHz-3eed95f** (`default_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=1 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=2 perf_errno=0; TGLB-END status=0
- **st1-60MHz-3eed95f** (`default_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=1 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=2 perf_errno=0; TGLB-END status=0
- **st1-60MHz-3eed95f** (`default_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=1 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=2 perf_errno=0; TGLB-END status=0
- **smt2x2-70MHz-p0f** (`p0f_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): st1-60MHz-3eed95f 2.466 s (3 boots, spread 0.0%); smt2x2-70MHz-p0f 1.728 s (1 boot, spread 0.0%, -29.92%)

| test | st1-60MHz-3eed95f instret/op | smt2x2-70MHz-p0f (change) | spread |
|---|---|---|---|
| forkexec | 1,408,769 | 1,362,887 (-3.3%) | 0.1% |
| syscall | 246 | 245 (-0.5%) | 0.0% |
| memcpy-64 | 90.29 | 90.21 (-0.1%) | 0.0% |
| memset-64 | 46.01 | 45.92 (-0.2%) | 0.1% |
| memcpy-4096 | 1,936 | 1,934 (-0.1%) | 0.1% |
| memset-4096 | 687 | 686 (-0.1%) | 0.1% |
| memcpy-1048576 | 511,774 | 506,285 (-1.1%) | 0.1% |
| memset-1048576 | 178,608 | 178,079 (-0.3%) | 0.3% |
| pipe | 67,517 | 67,483 (-0.1%) | 17.9% |
| tmpfs-write | 60,450 | 60,052 (-0.7%) | 5.1% |
| tmpfs-read | 37,221 | 36,962 (-0.7%) | 0.3% |
| pagefault | 2,600 | 2,563 (-1.4%) | 4.0% |
| tlbwalk | 4.94 | 4.80 (-2.8%) | 1.9% |
| gzip | 909,085,572 | 905,807,953 (-0.4%) | 0.1% |
| sha256sum | 341,684,546 | 341,313,908 (-0.1%) | 0.0% |
| coremark-a | 342,639 | 342,087 (-0.2%) | 0.0% |
| coremark-b | 347,951 | 347,313 (-0.2%) | 0.0% |
| dhrystone | 328 | 327 (-0.2%) | 0.0% |
