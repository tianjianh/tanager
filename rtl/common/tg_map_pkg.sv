// Tanager platform memory map and physical-memory attributes (plan §5.4).
// Board-independent: the KV260 carve-out offset lives in the SoC layer, never here.
package tg_map_pkg;
  import tg_pkg::*;

  localparam paddr_t BOOTROM_BASE = paddr_t'(64'h0000_1000);  localparam paddr_t BOOTROM_SIZE = paddr_t'(64'h1000);
  localparam paddr_t ACLINT_BASE = paddr_t'(64'h0200_0000);  localparam paddr_t ACLINT_SIZE = paddr_t'(64'h1_0000);
  localparam paddr_t PLIC_BASE = paddr_t'(64'h0C00_0000);  localparam paddr_t PLIC_SIZE = paddr_t'(64'h400_0000);
  localparam paddr_t UART_BASE = paddr_t'(64'h1000_0000);  localparam paddr_t UART_SIZE = paddr_t'(64'h1000);
  localparam paddr_t HOSTCTL_BASE = paddr_t'(64'h1000_1000);  localparam paddr_t HOSTCTL_SIZE = paddr_t'(64'h1000);
  localparam paddr_t VIRTIO_BASE = paddr_t'(64'h1001_0000);  localparam paddr_t VIRTIO_SIZE = paddr_t'(64'h4000);
  localparam paddr_t DEBUG_BASE = paddr_t'(64'h1100_0000);  localparam paddr_t DEBUG_SIZE = paddr_t'(64'h1_0000);
  localparam paddr_t DRAM_BASE = paddr_t'(64'h8000_0000);  localparam paddr_t DRAM_SIZE_MAX = paddr_t'(64'h8000_0000);

  localparam logic [63:0] TIMEBASE_HZ = 64'd10_000_000;  // ACLINT mtime rate (plan §7.1)

  // PMA classes
  typedef enum logic [1:0] {
    PMA_NONE   = 2'd0,  // no device: access fault
    PMA_MEM    = 2'd1,  // main memory: cacheable, idempotent, AMO and LR/SC
    PMA_ROM    = 2'd2,  // boot ROM: fetch cached through l1i; data loads uncached (mmio); no stores
    PMA_DEVICE = 2'd3   // I/O: uncached, non-idempotent, no speculation, no AMO/LR/SC
  } pma_e;

  // a in [base, base + size). For a naturally aligned power-of-two region, which every region
  // above is, that is a match of the address bits above the size (DR-120: 10 LUTs per pma_of
  // instead of 136 and 17 CARRY8 for the subtract-and-compare). Any other region keeps the
  // range test. The choice folds at elaboration, since base and size are constants.
  function automatic logic in_rg(input paddr_t a, input paddr_t base, input paddr_t size);
    if ((size & (size - paddr_t'(1))) == '0 && (base & (size - paddr_t'(1))) == '0)
      return ((a ^ base) & ~(size - paddr_t'(1))) == '0;
    return a >= base && a - base < size;
  endfunction

  function automatic pma_e pma_of(input paddr_t a);
    if (in_rg(a, DRAM_BASE, DRAM_SIZE_MAX))     return PMA_MEM;
    if (in_rg(a, BOOTROM_BASE, BOOTROM_SIZE))   return PMA_ROM;
    if (in_rg(a, ACLINT_BASE, ACLINT_SIZE)   || in_rg(a, PLIC_BASE, PLIC_SIZE)       ||
        in_rg(a, UART_BASE, UART_SIZE)       || in_rg(a, HOSTCTL_BASE, HOSTCTL_SIZE) ||
        in_rg(a, VIRTIO_BASE, VIRTIO_SIZE)   || in_rg(a, DEBUG_BASE, DEBUG_SIZE))  return PMA_DEVICE;
    return PMA_NONE;
  endfunction
endpackage
