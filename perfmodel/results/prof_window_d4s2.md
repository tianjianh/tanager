**d4s2 boot to /init (tb_boot as the board runs it, prof_m6.sv +prof_snap=1000000): cycles 61,000,000 to 83,000,000**

| Counter | core 0 | core 1 |
|---|---|---|
| instructions (IPC) | 15,307,434 (0.696) | 11,620,802 (0.528) |
| nothing commits, the ROB empty: fetch waits on an I$ miss | 3.5% | 3.2% |
| ... the refill after a mispredict | 3.4% | 4.2% |
| ... the refill after another flush | 4.9% | 7.3% |
| ... other (fetch, decode, rename) | 6.0% | 2.9% |
| ... the I$ sweep after FENCE.I | 0.0% | 0.0% |
| nothing commits: the head's DTLB retry | 0.1% | 0.0% |
| ... the head a load waiting on a D$ miss | 13.4% | 3.4% |
| ... the head a load waiting on a store | 0.4% | 0.7% |
| ... the head another incomplete load | 7.0% | 6.3% |
| ... the head a store | 3.6% | 5.3% |
| ... the head a serializing op (wfi when idle) | 11.9% | 27.2% |
| ... the head another incomplete op | 4.7% | 5.8% |
| ... the head complete, held | 0.4% | 0.5% |
| the store drain waits on the D$ | 22.0% | 5.3% |
| ... on a line (miss or ownership) | 20.2% | 5.0% |
| rename held by a full SQ | 11.9% | 2.2% |
| ... while the drain waits on a store's line | 10.6% | 1.9% |
| rename held by a full ROB | 2.9% | 0.1% |
| ... the head a load waiting on a miss | 2.2% | 0.1% |
| D$ miss entries busy: none | 70.5% | 90.8% |
| ... one | 20.6% | 8.7% |
| ... two | 8.7% | 0.4% |
| ... three | 0.3% | 0.0% |
| ... four | 0.0% | 0.0% |
| fetch parked on a refill: the line after the previous refill's | 4.4% | 3.8% |
| ... the line after the last block delivered | 3.2% | 2.3% |
| ... another line | 5.2% | 4.2% |
| mispredicts (count) | 91,952 | 120,171 |
| DTLB retries, loads (count) | 153 | 52 |
| DTLB retries, stores (count) | 251 | 27 |
| FENCE.Is (count) | 2 | 7 |
| D$ load requests (count) | 746,361 | 90,952 |

**d4s2 boot to /init (tb_boot as the board runs it, prof_m6.sv +prof_snap=1000000): cycles 84,000,000 to 106,000,000**

| Counter | core 0 | core 1 |
|---|---|---|
| instructions (IPC) | 15,610,723 (0.710) | 2,255,112 (0.103) |
| nothing commits, the ROB empty: fetch waits on an I$ miss | 3.5% | 0.7% |
| ... the refill after a mispredict | 2.7% | 0.4% |
| ... the refill after another flush | 5.2% | 2.1% |
| ... other (fetch, decode, rename) | 3.2% | 0.2% |
| ... the I$ sweep after FENCE.I | 0.0% | 0.0% |
| nothing commits: the head's DTLB retry | 0.0% | 0.0% |
| ... the head a load waiting on a D$ miss | 25.9% | 0.4% |
| ... the head a load waiting on a store | 0.1% | 0.0% |
| ... the head another incomplete load | 8.1% | 2.0% |
| ... the head a store | 3.2% | 0.7% |
| ... the head a serializing op (wfi when idle) | 1.2% | 86.4% |
| ... the head another incomplete op | 4.4% | 0.7% |
| ... the head complete, held | 0.3% | 0.1% |
| the store drain waits on the D$ | 31.7% | 0.3% |
| ... on a line (miss or ownership) | 29.6% | 0.2% |
| rename held by a full SQ | 23.9% | 0.1% |
| ... while the drain waits on a store's line | 22.0% | 0.1% |
| rename held by a full ROB | 1.6% | 0.1% |
| ... the head a load waiting on a miss | 1.2% | 0.1% |
| D$ miss entries busy: none | 60.5% | 99.3% |
| ... one | 19.1% | 0.6% |
| ... two | 19.6% | 0.1% |
| ... three | 0.9% | 0.0% |
| ... four | 0.0% | 0.0% |
| fetch parked on a refill: the line after the previous refill's | 4.4% | 0.4% |
| ... the line after the last block delivered | 3.3% | 0.4% |
| ... another line | 4.3% | 0.6% |
| mispredicts (count) | 77,220 | 10,488 |
| DTLB retries, loads (count) | 8 | 1 |
| DTLB retries, stores (count) | 8 | 0 |
| FENCE.Is (count) | 0 | 0 |
| D$ load requests (count) | 1,268,910 | 7,015 |

**d4s2 boot to /init (tb_boot as the board runs it, prof_m6.sv +prof_snap=1000000): cycles 107,000,000 to 121,000,000**

| Counter | core 0 | core 1 |
|---|---|---|
| instructions (IPC) | 1,257,372 (0.090) | 3,522,786 (0.252) |
| nothing commits, the ROB empty: fetch waits on an I$ miss | 0.6% | 0.0% |
| ... the refill after a mispredict | 0.3% | 0.4% |
| ... the refill after another flush | 1.9% | 1.2% |
| ... other (fetch, decode, rename) | 0.2% | 65.7% |
| ... the I$ sweep after FENCE.I | 0.0% | 0.0% |
| nothing commits: the head's DTLB retry | 0.0% | 0.0% |
| ... the head a load waiting on a D$ miss | 0.1% | 2.0% |
| ... the head a load waiting on a store | 0.0% | 0.0% |
| ... the head another incomplete load | 1.9% | 1.2% |
| ... the head a store | 0.5% | 10.1% |
| ... the head a serializing op (wfi when idle) | 88.2% | 0.0% |
| ... the head another incomplete op | 0.5% | 1.0% |
| ... the head complete, held | 0.1% | 0.1% |
| the store drain waits on the D$ | 0.1% | 75.0% |
| ... on a line (miss or ownership) | 0.1% | 73.6% |
| rename held by a full SQ | 0.0% | 75.1% |
| ... while the drain waits on a store's line | 0.0% | 70.2% |
| rename held by a full ROB | 0.0% | 0.3% |
| ... the head a load waiting on a miss | 0.0% | 0.2% |
| D$ miss entries busy: none | 99.9% | 22.8% |
| ... one | 0.1% | 77.0% |
| ... two | 0.0% | 0.2% |
| ... three | 0.0% | 0.0% |
| ... four | 0.0% | 0.0% |
| fetch parked on a refill: the line after the previous refill's | 0.4% | 0.0% |
| ... the line after the last block delivered | 0.4% | 0.0% |
| ... another line | 0.6% | 0.0% |
| mispredicts (count) | 5,567 | 7,400 |
| DTLB retries, loads (count) | 0 | 4 |
| DTLB retries, stores (count) | 2 | 28 |
| FENCE.Is (count) | 0 | 0 |
| D$ load requests (count) | 860 | 36,264 |

