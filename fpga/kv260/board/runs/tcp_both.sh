#!/bin/bash
# the TCP look at the internet download, 70 then 100 MHz, back to back (the same image, host and commands)
R=$HOME/tanager/runs
$R/sc_tcp.sh tanager-sc2 $HOME/tanager/sc2 sc2-70
$R/sc_tcp.sh tanager-sc3 $HOME/tanager/sc3 sc3-100
echo "both tcp runs done at $(date +%T)"
