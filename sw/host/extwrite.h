/* Board lockstep with the virtio back-ends (docs/spec/verification.md §3.10, host.md): every store the
 * back-ends make into the RISC-V's RAM through the host DMA port becomes an external-write record in the
 * trace stream that tanager-lockstep reads. Byte 63 is 0xE1; bytes 0-7 hold the physical address, 8-39 the
 * data, 40-43 the L2's AccessAck cycle from the port's completion queue (HDMA_CPL0/1), 44-47 the byte mask.
 * A record must reach the checker ahead of every trace record captured from its store's issue on, a load
 * the L2 served up to 256 cycles before the AccessAck included. So the caller forwards no trace records
 * while stores are outstanding: after vio_poll(), xw_drain() emits the records of every store made so far,
 * and only then does the trace go on. Trace records captured before a store and forwarded after its record
 * do no harm: each record carries its own visibility.
 * The completion queue holds 16 and a write waits while it is full, its B response with it, so a barrier
 * (DSB) behind a waiting write would never end. A store that would exceed XW_OUTSTANDING drains first:
 * half the queue, so neither the FIFO's exact usable depth nor its full flag's lag behind the reads can
 * hold a write that the A53 waits on. */
#ifndef TG_EXTWRITE_H
#define TG_EXTWRITE_H
#include <stdint.h>
#include "virtio.h"

#define XW_REC_BYTES 64u
#define XW_MARK      0xE1u                      /* byte 63; hardware records keep bytes 44-63 zero */
#define XW_OUTSTANDING 8u                       /* stores without their completion read: half the queue (16) */
#define HDMA_STATUS  0x1304u
#define HDMA_CPL0    0x1310u                    /* [31] valid, [25:0] the line (window offset / 64) */
#define HDMA_CPL1    0x1314u                    /* the AccessAck cycle; reading it pops the completion */

struct xw_hooks {
  void (*emit)(const uint8_t rec[XW_REC_BYTES]);   /* append a record to the trace output */
  void (*fail)(const char *msg);                /* a completion missing or for another line (the board dies) */
  unsigned long max_polls;                      /* HDMA_CPL0 reads before a completion counts as missing (0: 1M) */
};
/* From now on h's stores are recorded and its barrier drains; the wrappers call h's own hooks. Call it
 * before vio_open(), which copies the hooks. */
void xw_wrap(struct vio_hooks *h, const struct xw_hooks *x);
/* Waits for every outstanding store's completion and emits its record. Returns the records emitted, or -1
 * after x->fail. */
int  xw_drain(void);
uint64_t xw_records(void);                      /* records emitted so far */
#endif
