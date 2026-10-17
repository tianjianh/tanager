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
  /* gen_coh's dma mode: the lines the host writes through the hdma port, at a fixed address its model is
     told (DMA_BASE), not loaded (zero, as +mem_zero leaves the RAM and lockstep's Spike starts) */
  .dma 0x80100000 (NOLOAD) : { *(.dma*) }
}
