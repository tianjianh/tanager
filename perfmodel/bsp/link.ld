/* tgsim bare-metal memory map: 1 GiB of RAM at 0x80000000 (tgsim --ram-mb 1024). */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 1024M }

SECTIONS
{
  .text : {
    *(.text.init)
    *(.text .text.*)
  } > RAM
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } > RAM
  .init_array : {
    PROVIDE_HIDDEN(__init_array_start = .);
    KEEP(*(.init_array .init_array.*))
    PROVIDE_HIDDEN(__init_array_end = .);
  } > RAM
  .fini_array : {
    PROVIDE_HIDDEN(__fini_array_start = .);
    KEEP(*(.fini_array .fini_array.*))
    PROVIDE_HIDDEN(__fini_array_end = .);
  } > RAM
  .data : { *(.data .data.*) } > RAM
  .sdata : {
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*)
  } > RAM
  .sbss : { __bss_start = .; *(.sbss .sbss.*) *(.scommon) } > RAM
  .bss : { *(.bss .bss.*) *(COMMON) . = ALIGN(16); __bss_end = .; } > RAM
  . = ALIGN(4096);
  _end = .;
  PROVIDE(end = .);
  __stack_top = ORIGIN(RAM) + LENGTH(RAM) - 64;
}
