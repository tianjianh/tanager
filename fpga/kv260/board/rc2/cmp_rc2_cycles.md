- **d4r2-100MHz** (`baseline_boot_1.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-100MHz** (`baseline_boot_2.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **d4r2-100MHz** (`baseline_boot_3.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=2 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=4 perf_errno=0; TGLB-END status=0
- **u100-100MHz** (`u100_set.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=4 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=8 perf_errno=0; TGLB-END status=0
- **rc2-100MHz** (`rc2_set.txt`): TGLB-BEGIN version=1 kernel=6.12.113+deb13-riscv64 harts=4 runs=1; TGLB-INFO counters=cycle,instret,time timebase=10000000 pagesize=4096 perf_events=8 perf_errno=0; TGLB-END status=0
- **Linux boot to /init** (kernel log timestamps, median): d4r2-100MHz 18.648 s (3 boots, spread 0.5%); u100-100MHz 18.522 s (1 boot, spread 0.0%, -0.68%); rc2-100MHz 19.172 s (1 boot, spread 0.0%, +2.81%)

| test | d4r2-100MHz cycles/op | u100-100MHz (change) | rc2-100MHz (change) | spread |
|---|---|---|---|---|
| forkexec | 2,199,575 | 2,121,615 (-3.5%) | 2,121,986 (-3.5%) | 1.3% |
| syscall | 620 | 617 (-0.4%) | 616 (-0.6%) | 1.8% |
| memcpy-64 | 65.77 | 65.82 (+0.1%) | 65.74 (-0.0%) | 0.2% |
| memset-64 | 34.92 | 35.02 (+0.3%) | 34.94 (+0.0%) | 0.2% |
| memcpy-4096 | 1,027 | 1,030 (+0.2%) | 1,027 (+0.0%) | 0.9% |
| memset-4096 | 699 | 699 (-0.0%) | 698 (-0.2%) | 1.1% |
| memcpy-1048576 | 821,482 | 735,258 (-10.5%) | 735,710 (-10.4%) | 0.1% |
| memset-1048576 | 552,413 | 534,552 (-3.2%) | 584,430 (+5.8%) | 0.3% |
| pipe | 201,360 | 205,481 (+2.0%) | 209,288 (+3.9%) | 2.0% |
| tmpfs-write | 200,055 | 189,781 (-5.1%) | 188,275 (-5.9%) | 0.7% |
| tmpfs-read | 67,394 | 63,882 (-5.2%) | 63,085 (-6.4%) | 0.7% |
| pagefault | 4,563 | 4,964 (+8.8%) | 5,197 (+13.9%) | 0.5% |
| tlbwalk | 64.57 | 53.70 (-16.8%) | 53.85 (-16.6%) | 0.1% |
| gzip | 1,447,350,891 | 1,408,876,075 (-2.7%) | 1,400,019,851 (-3.3%) | 0.4% |
| sha256sum | 167,731,698 | 166,881,656 (-0.5%) | 167,053,228 (-0.4%) | 0.7% |
| coremark-a | 220,006 | 220,629 (+0.3%) | 222,796 (+1.3%) | 0.2% |
| coremark-b | 233,169 | 231,979 (-0.5%) | 232,457 (-0.3%) | 0.4% |
| dhrystone | 206 | 204 (-0.7%) | 204 (-0.6%) | 0.5% |
| coremark-a-imafd | 219,649 | 220,235 (+0.3%) | 220,794 (+0.5%) | 0.9% |
| coremark-b-imafd | 230,379 | 229,258 (-0.5%) | 230,277 (-0.0%) | 0.3% |
| dhrystone-imafd | 205 | 204 (-0.4%) | 203 (-0.7%) | 0.2% |
