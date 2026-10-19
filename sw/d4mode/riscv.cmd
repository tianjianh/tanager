# Tanager riscv.scr (D4's RISC-V mode, docs/spec/soc-d4-modes.md): sourced by the boot script's tanager-mode hook,
# which has already written trial 1. It loads the Tanager bitstream and the RISC-V's firmware, sets the PS up,
# releases the RISC-V and parks this A53. Any failure before the release returns (exit), and Ubuntu boots.
# p1:/tanager/: tanager.bit.bin (a TG_PS_WINDOW=1 TG_PMOD_UART=1 build), fw_jump.bin (OpenSBI), payload.bin (U-Boot in
# S-mode, sw/build_uboot.sh d4; step 5: the test image), tanager.dtb (sw/dts UART1=1 SD1=1 BOARD_RESET=1).
# Registers: CRL_APB PL0_REF_CTRL 0xff5e00c0, FPD_SLCR AFI_FS 0xfd615000, GPIO bank 5 (EMIO, bit 31 = pl_resetn0)
# DIRM 0xff0a0344 OEN 0xff0a0348 MASK_DATA_MSW 0xff0a002c, IOU_SLCR SD_ITAPDLY 0xff180314 SD_OTAPDLYSEL 0xff180318;
# the host bridge at 0xa0000000 (docs/spec/host.md): ID 0x000, CTRL 0x010, STATUS 0x014, DRAM_BASE 0x020, DRAM_SIZE
# 0x028, BOARD_CTRL 0x1404; BOOT_ENTRY (0x8000_0000) and DTB_ADDR (0x8220_0000) keep their reset values.
# (U-Boot's hush takes an apostrophe inside double quotes as a syntax error and then crashes: none in strings.)
setenv tg_part "${devtype} ${devnum}:${distro_bootpart}"
echo "tanager: RISC-V mode from ${tg_part}"

# 8 first: the park loop in OCM (wfi; b .-4), checked, so that a fault here still comes before the release
mw.l 0xfffc0000 0xd503207f
mw.l 0xfffc0004 0x17ffffff
itest.l *0xfffc0000 == 0xd503207f || exit
itest.l *0xfffc0004 == 0x17ffffff || exit

# 2. the bitstream, the PL clock (IOPLL / 10: 100 MHz), the fabric widths (HPM0 32-bit, HPM1 128-bit; the slave
# ports reset to 128-bit), a pulse on pl_resetn0
load ${tg_part} 0x10000000 tanager/tanager.bit.bin || exit
fpga load 0 0x10000000 ${filesize} || exit
zynqmp mmio_write 0xff5e00c0 0x013f3f07 0x01010a00
zynqmp mmio_write 0xfd615000 0x00000f00 0x00000800
itest.l *0xff5e00c0 == 0x01010a00 || exit
setexpr tg_v *0xfd615000 \& 0xf00
test "${tg_v}" = "800" || exit
setexpr tg_v *0xff0a0344 \| 0x80000000
mw.l 0xff0a0344 ${tg_v}
setexpr tg_v *0xff0a0348 \| 0x80000000
mw.l 0xff0a0348 ${tg_v}
mw.l 0xff0a002c 0x7fff0000
sleep 1
mw.l 0xff0a002c 0x7fff8000
sleep 1

# 3. our design answers on HPM0
itest.l *0xa0000000 == 0x54474e52 || exit
echo "tanager: the host bridge answers"

# 4. SD1's tap delays, as the A53 Linux sets them for the card (input 0x2a enabled, output 5); SD1's and UART1's
# clocks, power and pins stay as the boot firmware left them. A refused write leaves the taps this U-Boot read
# the card with, which may do: the RISC-V goes on either way
zynqmp mmio_write 0xff180314 0x03ff0000 0x02000000
zynqmp mmio_write 0xff180314 0x03ff0000 0x032a0000
zynqmp mmio_write 0xff180314 0x03ff0000 0x012a0000
zynqmp mmio_write 0xff180318 0x003f0000 0x00050000
md.l 0xff180314 2

# 5. the RISC-V DRAM window (0x8_4000_0000, 1 GiB; each 64-bit register low half first), BOARD_CTRL (the fan
# ignores this A53, whose PWM dies with it; the board reset path on)
mw.l 0xa0000020 0x40000000
mw.l 0xa0000024 0x00000008
mw.l 0xa0000028 0x40000000
mw.l 0xa000002c 0x00000000
mw.l 0xa0001404 0x00000003
itest.l *0xa0000024 == 0x8 || exit
itest.l *0xa0001404 == 0x3 || exit

# 6. the images at tanager-host offsets in the carve-out: OpenSBI at 0x8000_0000, the payload at 0x8020_0000,
# the tree at 0x8220_0000 (PS 0x8_4000_0000 + offset). Each is loaded low and copied up: cp takes no part in the
# memory reservations load checks, and this U-Boot runs from the low 2 GiB (DRAM: 2 GiB, effective 4 GiB). The
# RISC-V reads DRAM past this A53 caches: flushed before the release
load ${tg_part} 0x30000000 tanager/fw_jump.bin || exit
cp.b 0x30000000 0x840000000 ${filesize}
load ${tg_part} 0x30000000 tanager/payload.bin || exit
cp.b 0x30000000 0x840200000 ${filesize}
load ${tg_part} 0x30000000 tanager/tanager.dtb || exit
cp.b 0x30000000 0x842200000 ${filesize}
dcache flush

# 7. the uncore, the L2 initialisation, the cores: the point of no return
mw.l 0xa0000010 0x1
sleep 1
setexpr tg_v *0xa0000014 \& 4
if test "${tg_v}" != "4"; then
  echo "tanager: the L2 did not initialise; booting Ubuntu"
  mw.l 0xa0000010 0x3
  mw.l 0xa0001404 0x0
  exit
fi
mw.l 0xa0000010 0x0
echo "tanager: the RISC-V runs, its console on COM5 and UART1; this A53 parks"

# 8. park
dcache flush
icache flush
go 0xfffc0000
