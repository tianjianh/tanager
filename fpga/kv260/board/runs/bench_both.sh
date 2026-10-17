#!/bin/bash
# 70 against 100 MHz, back to back: the same frozen image, tanager-host, commands and network
R=$HOME/tanager/runs
$R/sc_bench.sh tanager-sc2 $HOME/tanager/sc2 sc2-70b
$R/sc_bench.sh tanager-sc3 $HOME/tanager/sc3 sc3-100b
echo "both benches done at $(date +%T)"
