#!/bin/bash
# After sc3's lockstep: soc-2's TCP look (70 and 100 MHz), DR-141's workload set on sc3 (3 boots), the dual-core
# CoreMark pair on sc3. Each step returns the board to k26-starter-kits.
R=$HOME/tanager/runs
while pgrep -f "[l]ockstep.sh tanager-sc3" > /dev/null; do sleep 30; done
echo "== sc3 lockstep ended at $(date +%T)"
echo "== tcp at $(date +%T)"; $R/tcp_both.sh
echo "== DR-141 set on sc3 at $(date +%T)"; BOOTS=3 $R/bench.sh tanager-sc3 $HOME/tanager/sc3 sc3
echo "== coremark pair at $(date +%T)"; $R/coremark_pair.sh tanager-sc3 sc3
echo "chain done at $(date +%T)"
