sc3: stage C at 100 MHz (the coordinator, after MR2 and MR3 landed): main's tree, two smt2 cores (harts 0 and 2),
the forwarded virtio window and the coherent host DMA port, now 43% faster than sc2's 70 MHz.

Tree 5172c6a (main: stage C merged, DR-151's 1 GiB memory region), smt2, 2 cores, 100 MHz (tg_clkgen: 1200 MHz VCO /
12), TG_VIRTIO_WINDOW=1, TG_HOST_DMA=1, the commit trace on, the debug counters off, AreaOptimized_high, PMOD console,
fan per DR-129. Timing at 100 MHz: WNS +0.347 ns, WHS +0.010 ns (routed; summary.txt); 113,014 synthesis LUTs (96.5%), TG_CHECK clean.
CAPS reads 0x12f, as sc2's.

Files: fw_jump.bin and Image (Buildroot) as before; tanager-kv260-virtio.dtb and tanager-kv260-virtio-768m.dtb (harts
0 and 2, sc2's: nothing in them depends on the core clock); tanager-host (soc-2 a88547b: --net, ppoll, the dma fix).
For Debian: debian-trixie-20261015c's u-boot.bin and image, unchanged.

1. Buildroot over virtio, as sc2's step 2 (--blk on a random image, --rng): md5 of /dev/vda, /dev/hwrng.
2. Debian 13, as before (U-Boot, --blk tanager-trixie.img, --net tanager0 --net-bridge br0 if the bridge is up):
   the times against sc2's (autologin 240 s, startup 1 min 41 s + 2 min 1 s), and the apt-get download rate
   (sc2: 1.3 MB/s, the guest's http at a whole core).
3. Lockstep: main has no CTRL.TFREEZE yet (it comes with soc-2's next MR, MR4), so use the 1 GHz-timebase 768m DTB
   that passed on p0f. The trace and lockstep are unchanged.
No debug counters in this build: dbg says so. DR-151 should leave no L2 error events at all; a counters build checks
that later.
