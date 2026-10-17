/* The forwarded virtio window's back-ends (docs/spec/soc.md §8.1, host.md): virtio-mmio version 2
 * register sets for the RISC-V's four slots at 0x1001_0000, served from the window's request queue,
 * with the virtqueues worked through the coherent host DMA port. Slot 1 is virtio-blk on an image file,
 * slot 2 virtio-net on a TAP device (one frame per read and write) and slot 3 virtio-rng; slot 0
 * (console) reads DeviceID 0, no device.
 * The register and memory accesses go through hooks, so a test can run the devices without the board
 * (sw/host/test/vio_test.c). */
#ifndef TG_VIRTIO_H
#define TG_VIRTIO_H
#include <stdint.h>

struct vio_hooks {
  uint32_t (*rd)(unsigned off);                 /* host bridge registers */
  void     (*wr)(unsigned off, uint32_t v);
  /* the RISC-V's RAM through the DMA port: offset = physical address - 0x8000_0000; 8-byte units */
  uint64_t (*ram_rd64)(uint64_t off);
  void     (*ram_wr64)(uint64_t off, uint64_t v);
  void     (*ram_wr32)(uint64_t off, uint32_t v);    /* 4-byte aligned */
  void     (*ram_wr8)(uint64_t off, uint8_t v);
  void     (*barrier)(void);                    /* writes complete (DSB on the A53) */
  uint64_t ram_size;
};

/* Open the back-ends: blk_image may be NULL (no block device); rng 0/1; net_fd a non-blocking TAP
 * descriptor, or -1 for no network device, with its MAC address. Returns 0, or -1 with a message. */
int  vio_open(const struct vio_hooks *h, const char *blk_image, int blk_readonly, int rng, int net_fd,
              const uint8_t mac[6]);
/* Serve every request waiting in the window's queue, and move the frames waiting on the TAP device into
 * the driver's receive buffers; returns the requests served plus the frames received. */
int  vio_poll(void);
void vio_close(void);                           /* the TAP descriptor stays the caller's */
/* Counters for the exit summary: requests served, block reads and writes in bytes; frames received and
 * sent, and dropped (no room, malformed, or arriving before the driver was ready). */
void vio_stats(uint64_t *reqs, uint64_t *rd_bytes, uint64_t *wr_bytes);
void vio_net_stats(uint64_t *rx, uint64_t *tx, uint64_t *drops);

/* The window's host registers (host.md) */
#define VQ_CTRL   0x1100u
#define VQ_STATUS 0x1104u
#define VQ_REQ0   0x1108u
#define VQ_REQ1   0x110Cu
#define VQ_RSP    0x1110u
#define VQ_IRQ    0x1114u
#endif
