#!/bin/bash
# the A/B: A with 20261015b's tanager-host (1e5fca51), B with 20261015c's (52329089), each on a clean copy of
# the 20261015c image
D=$HOME/tanager/sc2netc
cp --sparse=always $D/tanager-trixie.img.orig $D/tanager-trixie.img && echo "== A: image reset"
$HOME/tanager/runs/sc2_ab.sh tanager-host-1e5fca51 A
cp --sparse=always $D/tanager-trixie.img.orig $D/tanager-trixie.img && echo "== B: image reset"
$HOME/tanager/runs/sc2_ab.sh tanager-host B
echo "A/B done at $(date +%T)"
