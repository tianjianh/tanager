/* External-write records for board lockstep with the virtio back-ends (extwrite.h; docs/spec/verification.md
 * §3.10). Each store through the host DMA port is one AXI write, so it queues one completion, {line, cycle},
 * in the order of the stores (the mapping is Device-nGnRnE: no gathering, no reordering). */
#include "extwrite.h"
#include <stdio.h>
#include <string.h>

#define RAM_BASE 0x80000000ull                  /* the RISC-V's RAM, physical: the DMA port's offset 0 */

static struct vio_hooks V;                      /* the hooks wrapped */
static struct xw_hooks X;
static struct { uint64_t off, v; unsigned size; } pend[XW_OUTSTANDING];
static unsigned npend;
static uint64_t nrec;

static void put_le(uint8_t *p, uint64_t v, unsigned n) {
  for (unsigned k = 0; k < n; k++) p[k] = (uint8_t)(v >> (8 * k));
}

int xw_drain(void) {
  if (!npend) return 0;
  V.barrier();                                  /* the stores answered: their completions are queued or near */
  unsigned n = npend;
  npend = 0;
  for (unsigned i = 0; i < n; i++) {
    char msg[160];
    uint32_t c0 = 0;
    for (unsigned long k = 0; k < X.max_polls && !((c0 = V.rd(HDMA_CPL0)) >> 31); k++) { }
    if (!(c0 >> 31)) {
      snprintf(msg, sizeof msg, "no host DMA completion for the store to 0x%llx (%u of %u outstanding left)",
               (unsigned long long)(RAM_BASE + pend[i].off), n - i, n);
      X.fail(msg);
      return -1;
    }
    uint32_t line = c0 & 0x3ffffffu, want = (uint32_t)(pend[i].off >> 6) & 0x3ffffffu;
    uint32_t cyc = V.rd(HDMA_CPL1);
    if (line != want) {
      snprintf(msg, sizeof msg, "a host DMA completion for line 0x%x where the store to 0x%llx (line 0x%x) was due",
               line, (unsigned long long)(RAM_BASE + pend[i].off), want);
      X.fail(msg);
      return -1;
    }
    uint8_t rec[XW_REC_BYTES];
    memset(rec, 0, sizeof rec);
    put_le(rec, RAM_BASE + pend[i].off, 8);
    put_le(rec + 8, pend[i].v, pend[i].size);
    put_le(rec + 40, cyc, 4);
    put_le(rec + 44, (1u << pend[i].size) - 1, 4);
    rec[63] = XW_MARK;
    X.emit(rec);
    nrec++;
  }
  return (int)n;
}

static void note(uint64_t off, uint64_t v, unsigned size) {
  if (npend == XW_OUTSTANDING) xw_drain();
  pend[npend].off = off;
  pend[npend].v = v;
  pend[npend].size = size;
  npend++;
}
static void x_wr64(uint64_t off, uint64_t v) { note(off, v, 8); V.ram_wr64(off, v); }
static void x_wr32(uint64_t off, uint32_t v) { note(off, v, 4); V.ram_wr32(off, v); }
static void x_wr8(uint64_t off, uint8_t v)   { note(off, v, 1); V.ram_wr8(off, v); }
static void x_barrier(void) { if (npend) xw_drain(); else V.barrier(); }

void xw_wrap(struct vio_hooks *h, const struct xw_hooks *x) {
  V = *h;
  X = *x;
  if (!X.max_polls) X.max_polls = 1000000;
  npend = 0;
  nrec = 0;
  h->ram_wr64 = x_wr64;
  h->ram_wr32 = x_wr32;
  h->ram_wr8 = x_wr8;
  h->barrier = x_barrier;
}

uint64_t xw_records(void) { return nrec; }
