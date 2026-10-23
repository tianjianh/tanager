/* sbi_mask: fw_jump's next stage, at 0x8020_0000 (the generic platform's default) */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x80200000;
  .text : { *(.text.start) *(.text*) }
  .rodata : { *(.rodata*) *(.srodata*) }
  .data : { *(.data*) *(.sdata*) }
  .bss : { *(.bss*) *(.sbss*) *(COMMON) }
  . = ALIGN(16);
  . = . + 0x4000;
  __stack_top = .;
}
