/* Two-hart coherence programs (gen_coh.py): loaded by tb_boot's +fw and tanager-lockstep's --fw at 0x8000_0000. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text*) }
  . = ALIGN(64);
  .data : { *(.data*) *(.rodata*) *(.sdata*) *(.srodata*) }
  .bss : { *(.bss*) *(.sbss*) }
}
