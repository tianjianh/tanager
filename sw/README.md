# Tanager software (SoC track)

Design: [docs/spec/soc.md](../docs/spec/soc.md) §3–§6, [docs/spec/host.md](../docs/spec/host.md).
Run everything after `source tools/env.sh && source sw/env.sh`. Build trees go to `$SOC_BUILD`
(`$TANAGER_BUILD/<worktree>`), downloads to `$SOC_DL`. The Bootlin toolchains are unpacked once: a worktree
uses its own `$SOC_BUILD/tc` if it has one, else the shared `$TANAGER_BUILD/tc` (`sw/env.sh` `SOC_AATC`,
`SOC_RVTC`), so other worktrees and CI build `tanager-host` and OpenSBI without a copy of their own;
`SOC_TC_DIR=$TANAGER_BUILD/tc bash sw/fetch.sh aatc` installs into the shared directory.

| Path | What | Command |
|---|---|---|
| `versions.sh`, `sha256sums` | pinned OpenSBI, Linux, Buildroot, Bootlin toolchains, with checksums | `bash sw/fetch.sh` |
| `buildroot/` | Buildroot external tree: `tanager_lp64d` (OpenSBI 1.9 fw_jump, Linux 6.18.56, busybox initramfs built in) | `bash sw/build_linux.sh` |
| `buildroot/configs/tanager_lp64d_bench_defconfig` | the bench image (DR-141): `tanager_lp64d` plus the SBI PMU driver (user-mode `rdcycle`, `board/tanager/linux-bench.fragment`) and the verification track's Linux workload set (package `tg-lbench`, from `tests/bench/linux`; it runs at boot with `tanager.bench=1` and powers off). `tanager_lp64d` stays the reference image for tb_boot, lockstep and the cycle-identical boot | `bash sw/build_linux.sh tanager_lp64d_bench` |
| `dts/` | device trees for the plan §5.4 map: `tanager-kv260.dts`, `tanager-qemu.dts` | `make -C sw/dts CORES=2 THREADS=1 MEM=0x40000000 FPU=1` |
| `qemu/boot_test.sh` | boots the images on QEMU virt with the Tanager tree; PASS/FAIL | `bash sw/qemu/boot_test.sh 2 1` |
| `bootrom/` | boot ROM source; regenerates `rtl/uncore/bootrom/tg_bootrom_img_pkg.sv` | `make -C sw/bootrom` / `make -C sw/bootrom check` |
| `host/` | `tanager-host`, the A53 control program | `make -C sw/host` (aarch64) / `make -C sw/host native` |

Image layout in the carve-out (soc.md §3): `fw_jump.bin` at +0, `Image` at +0x20_0000, DTB at
+0x220_0000. The kernel's effective size must stay below 32 MiB (`build_linux.sh` checks it).

QEMU results (2026-10-13): PASS for 1 core x 1 thread, 2 x 1 (`st`) and 2 x 2 (`smt2`).
