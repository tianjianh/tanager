- **smt2x2-70MHz-p0f** (`p0f_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **smt2x2-100MHz-sc3** (`sc3_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **smt2x2-100MHz-sc3** (`sc3_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **smt2x2-100MHz-sc3** (`sc3_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): smt2x2-70MHz-p0f 1.728 s (1 boot, spread 0.0%); smt2x2-100MHz-sc3 1.289 s (3 boots, spread 0.4%, -25.43%)

| test | smt2x2-70MHz-p0f ns/op | smt2x2-100MHz-sc3 (change) | spread |
|---|---|---|---|
| forkexec | 42,753,687 | 29,270,934 (-31.5%) | 1.0% |
| syscall | 7,251 | 5,011 (-30.9%) | 0.3% |
| memcpy-64 | 1,170 | 811 (-30.7%) | 0.2% |
| memset-64 | 890 | 617 (-30.7%) | 0.4% |
| memcpy-4096 | 17,250 | 11,970 (-30.6%) | 0.5% |
| memset-4096 | 10,402 | 7,213 (-30.7%) | 0.7% |
| memcpy-1048576 | 30,576,717 | 22,646,153 (-25.9%) | 1.7% |
| memset-1048576 | 13,802,581 | 8,670,925 (-37.2%) | 4.2% |
| pipe | 3,216,082 | 2,204,262 (-31.5%) | 14.4% |
| tmpfs-write | 2,930,235 | 2,052,813 (-29.9%) | 2.7% |
| tmpfs-read | 2,112,760 | 1,488,200 (-29.6%) | 0.8% |
| pagefault | 135,208 | 96,094 (-28.9%) | 1.7% |
| tlbwalk | 1,771 | 1,272 (-28.2%) | 0.7% |
| gzip | 26,571,856,700 | 18,273,575,900 (-31.2%) | 0.2% |
| sha256sum | 3,145,359,000 | 2,180,978,600 (-30.7%) | 0.1% |
| coremark-a | 5,203,798 | 3,611,308 (-30.6%) | 0.2% |
| coremark-b | 6,295,352 | 4,363,476 (-30.7%) | 0.1% |
| dhrystone | 5,842 | 4,049 (-30.7%) | 0.1% |
