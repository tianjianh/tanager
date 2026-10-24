# Tanager on the KV260: user guide

Tanager is a 64-bit RISC-V processor for the AMD Kria KV260's FPGA: two cores with two threads each (four harts), at 100 MHz. Its ISA is rv64gc with Zba, Zbb, Zbs, Zicond and Sstc. This guide takes a KV260 from its stock Ubuntu to Debian 13 running on Tanager, and back. It is written for someone new to the project.

**Values marked TBD-v1** change with the v1 release image. Today's value, from the release candidate rc3 (10-24), is given beside each.

## 1. What you need

| Item | Notes |
|---|---|
| **KV260 Starter Kit** with its 12 V supply | Ours: SOM SMK-K26-XCL2G rev 2, carrier SCK-KV-G rev 2. The boot firmware in QSPI stays as shipped; ours is `K26-BootFW-01.02`. |
| **microSD card**, 16 GB or more | It holds Ubuntu (ARM mode) and Debian (RISC-V mode) side by side ([§4](#4-preparing-the-sd-card-once)). |
| **A 3.3 V USB-UART adapter on PMOD J2** | Tanager's console. Wire J2 pin 1 (the FPGA's TX, pin H12) to the adapter's RX, J2 pin 2 (the FPGA's RX, pin B10) to its TX, and ground to ground. 3.3 V only. J2 is numbered in two rows, 11 9 7 5 3 1 and 12 10 8 6 4 2, so pins 1 and 2 face each other ([fpga/kv260/README.md](../fpga/kv260/README.md), The board). |
| **The KV260's own micro-USB** | Its UART1 port is the A53's console (Ubuntu's `ttyPS1`, and the A53's U-Boot). In RISC-V mode it becomes Debian's second console. |
| **An Ethernet cable** to the KV260's PS Ethernet port | Debian uses it in RISC-V mode (GEM3, 1 Gb/s link only), and Ubuntu in ARM mode. |
| **A Linux host** | For the serial terminals (115200 8N1 on both ports), SSH, writing the card, and building Debian's image ([§4](#4-preparing-the-sd-card-once)). Building the bitstream needs Vivado and much more ([fpga/kv260/README.md](../fpga/kv260/README.md), [sw/README.md](../sw/README.md)). This guide uses the release package instead. |

## 2. How the board boots: two modes

The board runs one OS at a time, chosen at every power-up and reset (DR-172, [soc-d4-modes.md](spec/soc-d4-modes.md)).

- **ARM mode:** the KV260's own Ubuntu on its Arm cores (the A53s). Tanager isn't running. ARM mode is the default and the fallback for every failure.
- **RISC-V mode:**
  - The A53's U-Boot loads Tanager's bitstream and Tanager's firmware, then releases Tanager and parks the A53s.
  - Tanager runs Debian 13 from the card, with the board's SD card, UART1 and Ethernet.
  - No Arm OS runs alongside.

**The mode record** is one 512-byte sector of the card (sector 2047, before the first partition), written with `tanager-mode`:

| The record says | The next boot |
|---|---|
| nothing, or anything invalid | ARM mode |
| `arm` | ARM mode |
| `riscv`, trial 0 | RISC-V mode. The A53's U-Boot first sets trial 1, so the record reads `riscv, trial 1` while Debian runs. |
| `riscv`, trial 1 | ARM mode: the last RISC-V boot never ended cleanly. |

Debian's confirm unit sets trial back to 0 on each clean shutdown or reboot. So:
- a clean reboot in RISC-V mode stays in RISC-V mode;
- any unclean end (a hang and the reset break, a crash, a power loss) comes back in ARM mode.

## 3. The release files

RISC-V mode needs one package. It is the files for the card's boot partition, plus the installers for both OSes (`sw/d4mode/`, packaged by [`sw/d4mode/riscv_package.sh`](../sw/d4mode/riscv_package.sh)):

| File | What | Value |
|---|---|---|
| the package | `<name>-riscv.tar.gz` with `SHA256SUMS` and `H1-README.txt` | **TBD-v1** (rc3: `rc3u095r-riscv.tar.gz`, `8e53c0b8…`) |
| `tanager/tanager.bit.bin` | Tanager's bitstream: a release build, two `smt2` cores, 100 MHz | **TBD-v1** (rc3: `2a47608a…`) |
| `tanager/fw_jump.bin` | OpenSBI 1.9 with Tanager's patch set tg1 | rc3: `62349a65…` |
| `tanager/payload.bin` | U-Boot 2026.07 in S-mode, reading the card (`sw/build_uboot.sh d4`) | rc3: `459992b8…` |
| `tanager/tanager.dtb`, `tanager-h01.dtb` | the device trees: four harts, and a one-core fallback | rc3: `18afd230…`, `15cd197c…` |
| `tanager/riscv.scr`, `riscv.cmd` | the A53's script that loads and releases Tanager | rc3's `riscv.scr`: `2635d6bf…` |
| `install.sh`, `tanager-mode`, `ubootenv.d-tanager-mode` | Ubuntu's side: the mode tool and U-Boot's mode check | |
| `debian_install.sh`, `tanager-mode-confirm.service` | Debian's side: the tool and the confirm unit | |

Every firmware setting in these files is listed, with how to change it, in [firmware_switches.md](spec/firmware_switches.md). The hardware's build switches are in [area_switches.md](spec/area_switches.md).

**The board's MAC is in the device tree.** The release trees carry our board's address, `00:0a:35:2a:df:d8`. Another KV260 needs a package built with its own: `ETH_MAC=xx:xx:xx:xx:xx:xx` for `riscv_package.sh` or `sw/dts/board-trees.sh`. Use the address Ubuntu shows for `eth0`. **TBD-v1:** how v1 sets the MAC per board.

## 4. Preparing the SD card (once)

The card ends up with three partitions, plus the mode record before them:

| Part | Size (ours, 16 GB card) | What |
|---|---|---|
| sector 2047 | 512 bytes | the mode record |
| p1 | 1 GiB, FAT | the boot partition: Ubuntu's boot files, and RISC-V mode's `tanager/` |
| p2 | 6 GiB, ext4 | Ubuntu's root |
| p3 | the rest (7,741 MiB), ext4, `LABEL=tanager-root` | Debian's root: a file system with no partition table of its own |

### 4.1 Ubuntu

1. **Write the card:** the standard Ubuntu 24.04 for Kria image. Ours is Ubuntu 24.04.2 LTS for Kria, the image of 2025-04-23.
2. **Boot it** with the micro-USB console open. Then:
   - put it on the network;
   - give the `ubuntu` user an SSH key and sudo.
3. **The kernel's command line:** add `cma=800M mem=3G arm-smmu.disable_bypass=0`.
   - Set it as `LINUX_KERNEL_CMDLINE` in `/etc/default/flash-kernel`, then run `sudo flash-kernel` and reboot.
   - Why: `mem=3G` keeps Ubuntu out of the top 1 GiB of the high DDR bank, which is Tanager's memory ([fpga/kv260/README.md](../fpga/kv260/README.md), Board setup).

### 4.2 Room for Debian: shrink p2, add p3

Ubuntu's image fills the card, so p2 shrinks to 6 GiB and p3 takes the rest.

1. **First, in Ubuntu, stop cloud-init growing the root back:**
   - write `growpart: {mode: 'off'}` and `resize_rootfs: false` to `/etc/cloud/cloud.cfg.d/99-tanager-root-size.cfg`;
   - check with `sudo cloud-init single --name growpart`.

   On our board cloud-init regrew a shrunk root at the next boot ([board/sdcard/README.md](../fpga/kv260/board/sdcard/README.md)).
2. **Then shrink p2 and add p3.** The simplest way is with the card in the Linux host's reader, unmounted.
   - The commands, with `/dev/sdX` the card. They follow our board's own tool, `tg-shrink-root.premount`:
     ```bash
     sudo e2fsck -f /dev/sdX2
     sudo resize2fs /dev/sdX2 6000M                 # the file system a little under 6 GiB first
     start=$(sudo sfdisk -d /dev/sdX | sed -n 's/^.*2 : start= *\([0-9]*\),.*$/\1/p')
     echo "$start,12582912" | sudo sfdisk -N 2 /dev/sdX   # p2: 6 GiB from its own start
     sudo e2fsck -f /dev/sdX2 && sudo resize2fs /dev/sdX2  # the file system grown to fill p2
     echo ",+,83" | sudo sfdisk --append /dev/sdX   # p3: the rest of the card
     ```
   - p1 must still start at sector 2048: `tanager-mode` checks it.
   - Our board, which we couldn't take the card out of, did the same from Ubuntu's initramfs at boot. [board/sdcard/README.md](../fpga/kv260/board/sdcard/README.md) has that record and its tool.

### 4.3 Debian on p3

1. **Build the image on the Linux host,** with your SSH public key for the `tanager` user:
   ```bash
   source tools/env.sh && source sw/env.sh
   bash sw/build_debian.sh debian.img 8 ~/.ssh/id_ed25519.pub
   ```
   It gives Debian 13 (trixie) riscv64 from a pinned snapshot, every download verified. The host needs a few packages first, listed in [sw/README.md](../sw/README.md).
2. **Write it to p3,** from the host (`/dev/sdX3`) or from the board's Ubuntu (`/dev/mmcblk1p3`):
   ```bash
   sudo sw/debian_to_partition.sh debian.img /dev/sdX3
   ```
   p3 then holds `LABEL=tanager-root` alone.

### 4.4 Debian's drivers and confirm unit (TBD-v1)

Debian's kernel lacks two drivers the board needs: the Arasan SD controller, for the root, and the Cadence UART, for UART1.
- `sw/debian/stage_d_prep.sh` builds them with DKMS from the running kernel's own sources, and puts the SD driver in the initrd.
- `debian_install.sh` (in the package) installs `tanager-mode` and the confirm unit.

Both must run inside p3's Debian, on Tanager, before RISC-V mode can boot from the card.
- **Today that means stage C:** Debian booted from p3 in ARM mode, under `tanager-host`, with a development bitstream that has the virtio window. That is how our board's p3 was prepared ([board/d4/README.md](../fpga/kv260/board/d4/README.md)):
  ```bash
  sudo tanager-host boot --inj-rd 0 --fw fw_jump.bin --kernel u-boot.bin --dtb tanager-kv260-virtio.dtb \
    --blk /dev/mmcblk1p3 --rng --net tanager0 --net-bridge br0 --timeout 14400
  ```
  - The network goes through a bridge on Ubuntu's eth0 (`fpga/kv260/board/runs/net_bridge_up.sh`), since `stage_d_prep.sh` downloads its build tools.
  - Then, in that Debian: `sudo bash stage_d_prep.sh`, `sudo bash debian_install.sh`, and a clean shutdown.
- **TBD-v1:** how v1 delivers p3 with this done, so that a user needs no stage C.

### 4.5 RISC-V mode's boot files on p1

On the board's Ubuntu, with the package unpacked:

```bash
sha256sum -c SHA256SUMS
sudo bash install.sh
```

`install.sh`:
- keeps `boot.scr.uimg` and `image.fit` as `*.tanager-pre`;
- installs `tanager-mode` and U-Boot's mode check;
- copies `tanager/` to p1, rebuilds the boot script, and checks the check reached it.

It never writes the mode record, so the board still boots Ubuntu. Undo: `sudo bash install.sh --undo`.

## 5. Booting RISC-V mode

1. **Open both consoles,** at 115200 8N1:
   - the PMOD adapter (Tanager's firmware and Debian's kernel console);
   - the micro-USB's UART1 (the A53's U-Boot, then Debian's second console).

   The PMOD adapter may drop out for a moment while the bitstream loads, so a terminal that reopens the port helps.
2. **In Ubuntu:** `sudo tanager-mode riscv`, `sync`, `sudo reboot`.
3. **On UART1,** the A53's U-Boot:
   - `tanager-mode: riscv, trial 0: writing trial 1`;
   - `tanager: RISC-V mode from mmc 1:1`, then the bitstream's load;
   - `tanager: the host bridge answers`;
   - `tanager: the RISC-V runs, its console on COM5 and UART1; this A53 parks`.
4. **On the PMOD console:**
   - OpenSBI's banner, with `Platform HART Count : 4`;
   - U-Boot 2026.07 reading the card, and the extlinux menu;
   - Debian's kernel;
   - the automatic login: `tanager login: tanager (automatic login)`.
5. **Times from the reset: TBD-v1.** rc3: OpenSBI at 11.9 s, the kernel's `/init` at 51.9 s, the login at 154.2 s ([board/rc3/README.md](../fpga/kv260/board/rc3/README.md)).
6. **Checks in Debian:**
   - `nproc` gives 4, and `cat /proc/cpuinfo` shows each hart's ISA string;
   - `findmnt /` shows `/dev/mmcblk0p3`;
   - `sudo tanager-mode status` reads `riscv, trial 1`, which is normal while Debian runs.

**If it doesn't come up:**
- If `riscv.scr` fails before releasing Tanager, Ubuntu boots at once.
- Otherwise use the reset break ([§8](#8-when-something-hangs)), which gives ARM mode.

The table of every failure and its way out is in [soc-d4-modes.md](spec/soc-d4-modes.md), "Every failure ends in ARM mode".

## 6. Using Debian on Tanager

- **The user `tanager`:**
  - logs in automatically on both consoles: `ttyS0`, the PMOD, and `ttyPS0`, UART1;
  - has no password and passwordless sudo;
  - takes SSH by key only, the key given to `build_debian.sh`.
- **The SD card:**
  - The root is `/dev/mmcblk0p3`, through the PS's SD controller at 50 MHz, 3.3 V.
  - p1 and p2 are on the same card, so leave them alone in RISC-V mode.
  - `tanager-mode` refuses any disk but the card.
- **Ethernet (GEM3, `eth0`):**
  - systemd-networkd asks for an address by DHCP on any Ethernet, and the link must run at 1 Gb/s.
  - The IPv6 link-local address always works, even with no DHCP server. It is made from the MAC: ours is `fe80::20a:35ff:fe2a:dfd8`, so `ssh tanager@fe80::20a:35ff:fe2a:dfd8%<host interface>`.
- **Harts:** CPUs 1–3 can be stopped and started again: `echo 0 | sudo tee /sys/devices/system/cpu/cpu1/online`, then `echo 1` the same way.
- **USB:** not supported yet.
- **Updates:** `apt` works as on any Debian. DKMS rebuilds the board's two drivers on a kernel update.

## 7. Back to ARM mode

- **From Debian:** `sudo tanager-mode arm`, then `sudo reboot`. Ubuntu comes up.
- **Back again from Ubuntu:** `sudo tanager-mode riscv`, then `sudo reboot`.
- **A clean reboot in Debian** without `tanager-mode arm` stays in RISC-V mode.
- **To remove RISC-V mode:**
  - `sudo bash debian_install.sh --undo` in Debian;
  - `sudo bash install.sh --undo` in Ubuntu.

## 8. When something hangs

- **The reset break.** In RISC-V mode, a break on the PMOD console resets the whole board, even with Tanager hung.
  - The break is the adapter's TX held low for 2.7 to 10.7 s; use 4 s.
  - Then the record says trial 1, and Ubuntu boots.
  - From a Linux host, with pyserial and the adapter's device name:
    ```bash
    python3 -c "import serial,time; s=serial.Serial('/dev/ttyUSB0',115200); s.break_condition=True; time.sleep(4); s.break_condition=False"
    ```
- **A shutdown that hangs after the confirm.**
  - The first break comes back in RISC-V mode, because the confirm unit had already set trial 0.
  - If that boot hangs too, a second break gives ARM mode.
  - Seen on our board on 10-20 ([board/stress/README.md](../fpga/kv260/board/stress/README.md)).
- **A power cycle** in RISC-V mode comes back in ARM mode, since trial 1 is set while Debian runs. Power cycling is also the way out of anything else, ARM-mode hangs included ([§9](#9-the-host-tools-arm-mode)).
- **A broken boot script.** At the A53's U-Boot prompt on UART1:
  ```
  load mmc 1:1 0x20000000 boot.scr.uimg.tanager-pre; source 0x20000000
  ```
  That boots Ubuntu. Then run `sudo bash install.sh --undo`.

## 9. The host tools (ARM mode)

For development, Tanager can also run under Ubuntu in ARM mode. Its bitstream is loaded as a PL app, and Ubuntu drives it with `tanager-host` ([fpga/kv260/README.md](../fpga/kv260/README.md), Bring-up sequence; [host.md](spec/host.md)). RISC-V mode needs none of this, and in RISC-V mode the A53 is parked.

- **PL apps:**
  - Each app is a folder in `/lib/firmware/xilinx/<app>/`: `tanager.bit.bin`, `tanager.dtbo`, `shell.json`.
  - dfx-mgr's `xmutil` loads them: `sudo xmutil listapps`, `sudo xmutil unloadapp`, `sudo xmutil loadapp <app>`.
  - Ubuntu loads `k26-starter-kits` at boot. Load it back when you're done.
- **`tanager-host`** (`make -C sw/host`, a static aarch64 binary) controls a loaded Tanager design:
  - `info`, `reset`, `peek`/`poke`;
  - `load` and `run`, or `boot` for both: OpenSBI, a kernel and a tree into Tanager's memory, then the console;
  - the virtio disk, network and rng for development bitstreams (`--blk`, `--net`, `--rng`);
  - `fan`, `inj`, `trace`, `dma`, `psrd`.
- **[`fpga/kv260/board/tg.sh`](../fpga/kv260/board/tg.sh)** wraps it on the board:
  - `load` loads an app and arms a 10-minute timer that restores `k26-starter-kits`;
  - `th ARGS` runs `tanager-host`, refused unless the app is loaded;
  - `restore` puts `k26-starter-kits` back, and `status` shows the apps and the fan.

> **Warning: a PL read with no Tanager app loaded hangs the board until a power cycle.** The A53 waits forever for an answer nothing in the PL gives, and a reset break doesn't help in ARM mode.
> - Before any `tanager-host` command, check that `sudo xmutil listapps` shows the Tanager app active (`0->` in its slot). `tanager-host` also checks for its overlay first.
> - Never put a `tanager-host` call in a cleanup step that runs after `k26-starter-kits` is restored.

## 10. The fan

Linux owns the fan in ARM mode, and the bitstream keeps it on the same curve in RISC-V mode.

- **In ARM mode:** Ubuntu's `fancontrol.service` reads the temperature every 5 s and sets the fan's PWM: 15/255 at 35 °C, rising to 255 at 45 °C.
  - The PWM leaves the A53's side on EMIO. The loaded PL design must route it to the fan pin (A12, `fan_en_b`).
  - `k26-starter-kits` routes it, and so does every Tanager bitstream.
- **In RISC-V mode** the A53 is parked, so its PWM stops. The bitstream's fan regulator runs the same curve from the FPGA's own temperature sensor, and ignores the stopped PWM.
- **The rule:** no design may tie `fan_en_b` low, since that runs the fan at full speed. A design that doesn't route the PWM is not loaded.

## 11. More

- [firmware_switches.md](spec/firmware_switches.md): every firmware setting, including the A53's settings in ARM mode.
- [area_switches.md](spec/area_switches.md): the hardware's build switches.
- [soc-d4-modes.md](spec/soc-d4-modes.md): the two modes' design.
- [fpga/kv260/README.md](../fpga/kv260/README.md): building the bitstream, the board's facts and its change log.
- [sw/README.md](../sw/README.md): building the firmware, the kernel and Debian's image.
- [sw/d4mode/README.md](../sw/d4mode/README.md): the mode tools, and the steps that brought RISC-V mode up.
- **TBD-v1:** v1's release notes (the ISA string, the devices, the performance figures, and known gaps such as USB) and errata ([m9-plan.md](spec/m9-plan.md) §9).
