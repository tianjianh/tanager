- **st1-60MHz-3eed95f** (`default_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=1 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=2 perf_errno=0; TGLB-END status=0
- **st1-60MHz-3eed95f** (`default_boot2.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=1 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=2 perf_errno=0; TGLB-END status=0
- **st1-60MHz-3eed95f** (`default_boot3.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=1 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=2 perf_errno=0; TGLB-END status=0
- **smt2x2-70MHz-p0f** (`p0f_boot1.txt`): TGLB-BEGIN version=1 kernel=6.18.56-tanager harts=2 runs=3; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): st1-60MHz-3eed95f 2.466 s (3 boots, spread 0.0%); smt2x2-70MHz-p0f 1.728 s (1 boot, spread 0.0%, -29.92%)

| test | st1-60MHz-3eed95f ns/op | smt2x2-70MHz-p0f (change) | spread |
|---|---|---|---|
| forkexec | 53,916,256 | 42,753,687 (-20.7%) | 0.3% |
| syscall | 9,162 | 7,251 (-20.9%) | 0.1% |
| memcpy-64 | 1,355 | 1,170 (-13.6%) | 0.5% |
| memset-64 | 1,044 | 890 (-14.8%) | 0.3% |
| memcpy-4096 | 20,236 | 17,250 (-14.8%) | 0.4% |
| memset-4096 | 12,171 | 10,402 (-14.5%) | 0.4% |
| memcpy-1048576 | 38,273,555 | 30,576,717 (-20.1%) | 0.1% |
| memset-1048576 | 15,369,620 | 13,802,581 (-10.2%) | 2.9% |
| pipe | 3,827,069 | 3,216,082 (-16.0%) | 7.1% |
| tmpfs-write | 3,507,778 | 2,930,235 (-16.5%) | 2.0% |
| tmpfs-read | 2,449,020 | 2,112,760 (-13.7%) | 0.7% |
| pagefault | 160,687 | 135,208 (-15.9%) | 1.6% |
| tlbwalk | 2,036 | 1,771 (-13.0%) | 0.3% |
| gzip | 31,548,076,400 | 26,571,856,700 (-15.8%) | 0.2% |
| sha256sum | 3,696,382,700 | 3,145,359,000 (-14.9%) | 0.1% |
| coremark-a | 6,112,134 | 5,203,798 (-14.9%) | 0.1% |
| coremark-b | 7,369,178 | 6,295,352 (-14.6%) | 0.1% |
| dhrystone | 6,899 | 5,842 (-15.3%) | 0.1% |
