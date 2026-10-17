sc2: stage C's first board build (DR-147): two smt2 cores (harts 0 and 2) with the forwarded virtio window and the
coherent host DMA port, on p0f's tree (the rn_fire fix).

Tree aae33dcaa7cc (main 537f23b + soc-2's branch + core-2's 24ada50), smt2, 2 cores, 70 MHz, TG_VIRTIO_WINDOW=1,
TG_HOST_DMA=1, the commit trace on, TG_DEBUG_CNT=1, AreaOptimized_high, PMOD console, fan per DR-129.
Timing at 70 MHz: WNS +1.057 ns, WHS +0.010 ns (routed; summary.txt); 112,905 synthesis LUTs (96.4%), TG_CHECK clean.
CAPS reads 0x12f: the window (bit 2) and the DMA port (bit 8) present.

Files: fw_jump.bin and Image as before; tanager-kv260-virtio.dtb (harts 0 and 2, 1 GiB, the four virtio slots
at 0x1001_0000, PLIC 1-4) and tanager-kv260-virtio-768m.dtb (for lockstep); tanager-host (--blk, --rng, dma, vq).

1. The DMA port alone, the cores held (load releases only the uncore):
     head -c 16M /dev/urandom > vblk-test.img && md5sum vblk-test.img
     sudo ./tanager-host load --fw fw_jump.bin --kernel Image --dtb tanager-kv260-virtio.dtb --blk vblk-test.img --rng
     sudo ./tanager-host dma check          # writes and reads back 64 KiB at the RAM's end: "ok", MB/s, 0 drops
     sudo ./tanager-host vq                 # "served", no requests yet
2. Linux with virtio-blk (slot 1) and virtio-rng (slot 3), served by tanager-host through the window and the port:
     sudo ./tanager-host run --blk vblk-test.img --rng
   In the RISC-V's shell:
     dmesg | grep -i virtio                 # virtio_mmio probes: slots 1 and 3 found, 0 and 2 no device
     cat /proc/partitions                   # vda, 16384 blocks
     md5sum /dev/vda                        # the md5sum printed in step 1
     head -c 64 /dev/hwrng | od -An -tx1    # random bytes
   From a second A53 shell during the run: sudo ./tanager-host vq; sudo ./tanager-host dma status
   At the end tanager-host prints the virtio request count and the MiB read and written.
3. When 1 and 2 pass: Debian 13 through U-Boot (stage C's goal), from the separate package
   debian-trixie-20261015 (u-boot.bin, the image as a sparse tarball; its README has the steps):
     tar -xSzf tanager-trixie.img.tar.gz
     sudo ./tanager-host boot --fw fw_jump.bin --kernel u-boot.bin --dtb tanager-kv260-virtio.dtb --blk tanager-trixie.img
If anything stalls: sudo ./tanager-host vq, sudo ./tanager-host dbg, and the console log. This tanager-host's dbg
also reads the cores' debug words where a bitstream has them; sc2 has none, and dbg says so.
