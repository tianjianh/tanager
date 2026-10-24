#!/bin/bash
# rc3_bare.sh: at rc3's install (10-24), in ARM mode: memcal-big.bin twice, then soc-2's wsd.bin twice, on rc3's
# bitstream through memcal_release.sh (the dfx-mgr app tanager-rc3). Started with systemd-run, so the A53's network
# gaps (NetworkManager without a DHCP lease) can't end it with the SSH session.
BIT=$HOME/tanager/rc3u095r-riscv-pkg/rc3u095r-riscv/tanager/tanager.bit.bin; O=$HOME/tanager/rc3-bare.txt
{ date -u +"== memcal at %T (the A53's clock)"; bash "$HOME/tanager/runs/memcal_release.sh" rc3 "$BIT" 2
  date -u +"== wsd at %T"; bash "$HOME/tanager/runs/memcal_release.sh" rc3 "$BIT" 2 "$HOME/tanager/wsd/wsd.bin" ae231676
  echo "== done"; } > "$O" 2>&1
