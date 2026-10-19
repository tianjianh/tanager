d4s2-smt2-c2-100: D4's bitstream with core-2's M6 fix (soc-2, 10-19). Built from 03171ea+c261c1f: soc-2's D4 branch at
03171ea (main ea52c7f: M6 and PMP-8, plus step 1's BOARD_CTRL, RESET_CTRL in the PS window and the PMOD reset hook)
with core-2's micro-BTB target check (c261c1f's tg_fetch.sv; MR to the coordinator), in d4s1's configuration (trace
off, ExploreArea). Timing: WNS=0.529 WHS=0.010; pr_unc=1.0 ns; 106281 LUTs placed (90.75%). PMP has 8 entries now (any lockstep would need --pmp=8; there is no trace).
d4s1 panicked Linux at about 2.2 s (F2's micro-BTB aliasing); with the fix it shouldn't.
Files as d4s1's: tanager.bit.bin, tanager.dtbo, shell.json, tanager-host, ps_reset.bin, sc3's boot files (fw_jump.bin,
Image, the virtio trees, u-boot.bin) and the bench tree.
First: one stage C boot (Debian from p3 over virtio, as the stress runs) with about 30 minutes of load. Clean: step 6
in RISC-V mode on this bitstream (its own package).
cfg=smt2 kind=core core_mhz=100 n_cores=2
WNS=0.529 WHS=0.010
runtime_s=3306
commit=03171ea+c261c1f
profile=m6-smt2-notrace-pswin-fan defines=TG_COMMIT_TRACE=0 synth=AreaOptimized_high
pr_unc=1.0 (ns of setup uncertainty on clk_core for placement and routing, taken back before the reports)
opt=ExploreArea (opt_design's directive, DR-166)
uncore=VIRTIO_WINDOW=1 HOST_DMA=1 PS_WINDOW=1
pmod_uart=1 txd=H12 rxd=B10
fan=ttc0.wave2 invert=0 pl=1 pin=A12
