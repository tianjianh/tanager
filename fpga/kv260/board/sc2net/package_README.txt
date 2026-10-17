debian-trixie-20261015b: the Debian 13 image of debian-trixie-20261015 with the network, and the newest
tanager-host. For sc2 as it is: tanager-host serves virtio-net in slot 2, so no new bitstream is needed.

What changed against 20261015:
- The image (soc-2 3da99b6): systemd-networkd takes an address by DHCP on any Ethernet interface, with
  systemd-resolved and systemd-timesyncd. IPv6 link-local addresses come up with or without DHCP. Checked on
  QEMU (sw/qemu/debian_test.sh, 17 checks, including a DHCP lease on eth0).
- tanager-host (soc-2 c2cc421):
  - --net TAP [--net-bridge BR] [--net-mac MAC]: virtio-net in slot 2 on a TAP device that run makes, and that
    goes when the run ends. MAC 02:74:6e:67:72:01.
  - dma read/write/check release the uncore themselves, so sc2's step 1 (dma check after load) runs now.
  - run --dbg prints the debug counters before the exit's hold, which clears them.
  - dma status says "line reads" and "line writes": an 8-byte store is one line write.
From sc2's package: fw_jump.bin, tanager-kv260-virtio.dtb.

1. A host-only link first. This changes nothing on the A53: the TAP device goes when the run ends.
     tar -xSzf tanager-trixie.img.tar.gz
     sudo ./tanager-host boot --fw fw_jump.bin --kernel u-boot.bin --dtb tanager-kv260-virtio.dtb \
       --blk tanager-trixie.img --rng --net tanager0 --dbg
   - The boot runs as before. dmesg shows virtio_net on slot 2, and `ip -br link` shows eth0 UP.
   - No DHCP server answers on this link, so networkd keeps asking, but IPv6 link-local works:
       on the A53, in a second shell:   ping -6 -c3 ff02::1%tanager0     # the RISC-V answers from its fe80::
       in the RISC-V's shell:           ping -6 -c3 ff02::1%eth0         # the A53's tanager0 answers
   - `sudo ./tanager-host vq` during the run. The exit lines count the virtio requests and the frames.
2. Then the bridge. It's an approved A53 change (DR-147), applied with an automatic rollback and logged with its
   undo in fpga/kv260/README.md. Put br0 over eth0 (the laptop's ICS link) and move the A53's address to br0.
   With netplan's networkd renderer, a file like this:
     network: {version: 2, ethernets: {eth0: {dhcp4: false}},
               bridges: {br0: {interfaces: [eth0], macaddress: <eth0's MAC>, dhcp4: true, dhcp-identifier: mac}}}
   applied with `sudo netplan try --timeout 120` keeps the same MAC and client ID, so ICS should hand back the
   same lease, and it reverts unless confirmed. If the renderer is NetworkManager, do it your way; the README's
   rule holds: the laptop's SSH path is never cut, and the change undoes itself if contact is lost. Then:
     sudo ./tanager-host boot ... --net tanager0 --net-bridge br0
   - The RISC-V takes a 192.168.137.x lease from the laptop: `networkctl status`, `ip -4 -br addr`.
   - `timedatectl` should show the clock synchronized (timesyncd through the laptop), then `sudo apt update`
     reaches Debian's mirrors.
L2 errors: with --dbg, the counters print at the exit. sc2 has no capture of the error itself; p0g has it.
