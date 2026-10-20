/* Litmus programs (litmus_gen.py): loaded at 0x8000_0000 by tb_boot's +fw, and as ELFs by tg_vsim and tg_replay. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text*) }
  . = ALIGN(64);
  .data : { *(.data*) *(.rodata*) *(.sdata*) *(.srodata*) }
  .bss : { *(.bss*) *(.sbss*) }
  .tohost : { *(.tohost) }
}
