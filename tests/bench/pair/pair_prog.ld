/* A pair program at its slot (tests/bench/pair; pair.h): PAIR_BASE and PAIR_SIZE come from the link line
   (--defsym). Code, read-only data and the pristine image of .data load from PAIR_BASE; .data runs 8 MiB above,
   then .bss and the heap; the stack is at the slot's end. pair_crt0.S copies the image into .data at every start. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = PAIR_BASE;
  .text : {
    *(.text.init)
    *(.text .text.*)
  }
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) }
  .init_array : {
    PROVIDE_HIDDEN(__init_array_start = .);
    KEEP(*(.init_array .init_array.*))
    PROVIDE_HIDDEN(__init_array_end = .);
  }
  .fini_array : {
    PROVIDE_HIDDEN(__fini_array_start = .);
    KEEP(*(.fini_array .fini_array.*))
    PROVIDE_HIDDEN(__fini_array_end = .);
  }
  . = ALIGN(64);
  __data_lma = .;
  .data PAIR_BASE + 0x800000 : AT(__data_lma) {
    __data_start = .;
    *(.data .data.*)
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*)
    . = ALIGN(8);
    __data_end = .;
  }
  .bss (NOLOAD) : ALIGN(8) {
    __bss_start = .;
    *(.sbss .sbss.*) *(.scommon) *(.bss .bss.*) *(COMMON)
    . = ALIGN(8);
    __bss_end = .;
  }
  . = ALIGN(4096);
  _end = .;
  PROVIDE(end = .);
  __stack_top = PAIR_BASE + PAIR_SIZE - 64;
  ASSERT(__data_lma + (__data_end - __data_start) <= PAIR_BASE + 0x800000, "pair: code, read-only data and the data image pass 8 MiB")
  ASSERT(_end <= __stack_top - 0x400000, "pair: data and bss leave the heap and stack under 4 MiB")
}
