/* Bare-metal test program for tanager_soc, entered from the boot ROM (docs/spec/soc.md §3). */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.start) *(.text*) }
  .rodata : { *(.rodata*) *(.srodata*) }
  .data : { *(.data*) *(.sdata*) }
  .bss : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) __bss_end = .; }
  . = ALIGN(4096);
  __stack_top = . + 0x4000;           /* hart 0; hart h uses __stack_top + h * 0x4000 */
}
