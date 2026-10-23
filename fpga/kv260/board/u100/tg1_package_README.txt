osbi-tg1: OpenSBI 1.9 with Tanager's patch set tg1 (soc-2, 10-23; commit fad99ab8, soc.md §5), for the board's
hotplug soak round on the installed u100 image. Only p1:/tanager/fw_jump.bin changes; the bitstream, U-Boot d4, the
trees and the kernel stay.

What it fixes: the u100 soak's "__sbi_rfence_v02_call: hbase = [1] hmask = [0x5] failed (error [-22])". Linux keeps a
CPU it has taken offline in an address space's CPU mask, so a remote fence soon after a hart stops can still name it;
upstream 1.9 refused the whole call (SBI_ERR_INVALID_PARAM) before any IPI, so the online harts in that mask missed
their fence too. tg1 sends the fence (or IPI) to the started harts and skips stopped ones; a hart that doesn't exist
is still an error. Checked on QEMU (sw/qemu/sbi_mask_test.sh) and in simulation (tb_boot's banner, the four-hart
Linux boot under lockstep).

Install (in ARM mode, logged with its undo, as before):
- keep the current file: cp p1:/tanager/fw_jump.bin p1:/tanager/fw_jump.bin.b0094d23 (sha256 b0094d23...);
- put this fw_jump.bin in its place (check SHA256SUMS first);
- undo: copy fw_jump.bin.b0094d23 back.

The round:
1. Boot the four-hart tree. OpenSBI's banner is the same apart from the image (v1.9).
2. hsm_rounds.sh and the soak's hotplug rounds (soak4 as on u100), at least as many rounds as the soak ran to its
   round 5, with the stress running.
3. Expect no "__sbi_rfence_v02_call ... failed" line in dmesg; any data error or oops in the window is a failure to
   report. hart_check.sh after the rounds.
