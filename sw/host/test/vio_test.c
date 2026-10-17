/* The virtio back-ends (sw/host/virtio.c) without the board: a fake host bridge whose window queue this
 * test fills the way a virtio-mmio driver's accesses would, and 1 MiB of fake RISC-V RAM. Checks the
 * register sets of every slot, feature negotiation, a queue's setup, virtio-blk reads, writes, flush,
 * GET_ID, a request out of range, an unknown type and a request whose header and data share a
 * descriptor, virtio-rng, the used ring and the interrupt bits, and a device reset. virtio-net runs on
 * a SOCK_SEQPACKET socket pair in place of the TAP device (one frame per read and write): its two
 * queues, frames sent in one or two descriptors, a runt, frames received into buffers, a frame that
 * waits for a buffer, a buffer too small, NO_INTERRUPT, and frames before the driver is ready.
 *   make -C sw/host test        (native build; sw/host/Makefile) */
#define _GNU_SOURCE
#include "../virtio.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define RAM_BYTES (1u << 20)
#define PA(off)   (0x80000000ull + (off))
static uint8_t ram[RAM_BYTES];
static uint32_t req0, req1, rsp, irq_set, irq_clr;
static int req_v, rsp_v, errors, narrow_idx;

#define CHECK(c, ...) do { if (!(c)) { errors++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
                           fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

/* ---- the fake host bridge and RAM ---- */
static uint32_t f_rd(unsigned off) {
  if (off == VQ_REQ0) return req_v ? req0 | 0x80000000u : 0;
  if (off == VQ_REQ1) { req_v = 0; return req1; }
  return 0;
}
static void f_wr(unsigned off, uint32_t v) {
  if (off == VQ_RSP) { rsp = v; rsp_v = 1; }
  else if (off == VQ_IRQ) { irq_set |= v & 0xff; irq_clr |= (v >> 8) & 0xff; }
}
static uint64_t f_rd64(uint64_t off) {
  CHECK(!(off & 7) && off + 8 <= RAM_BYTES, "rd64 at %llx", (unsigned long long)off);
  uint64_t v = 0;
  if (off + 8 <= RAM_BYTES) memcpy(&v, ram + off, 8);
  return v;
}
static void f_wr64(uint64_t off, uint64_t v) {
  CHECK(!(off & 7) && off + 8 <= RAM_BYTES, "wr64 at %llx", (unsigned long long)off);
  if (off + 8 <= RAM_BYTES) memcpy(ram + off, &v, 8);
}
static void f_wr32(uint64_t off, uint32_t v) {
  CHECK(!(off & 3) && off + 4 <= RAM_BYTES, "wr32 at %llx", (unsigned long long)off);
  if (off + 4 <= RAM_BYTES) memcpy(ram + off, &v, 4);
}
static void f_wr8(uint64_t off, uint8_t v) {
  CHECK(off < RAM_BYTES, "wr8 at %llx", (unsigned long long)off);
  if (off < RAM_BYTES) ram[off] = v;
  if ((off >= 0x3000 && off < 0x3004) || (off >= 0x7000 && off < 0x7004))
    narrow_idx = 1;                                     /* used.flags/idx must go in one store */
}
static void f_bar(void) {}

/* ---- the driver's accesses through the window ---- */
static unsigned lg(unsigned size) { return size == 4 ? 2 : size == 2 ? 1 : 0; }
static uint32_t mr(unsigned slot, unsigned off, unsigned size) {
  req0 = (slot << 12) | off | (lg(size) << 16); req1 = 0; req_v = 1; rsp_v = 0;
  int n = vio_poll();
  CHECK(n == 1 && rsp_v && !req_v, "read slot %u off %x: %d served", slot, off, n);
  return rsp;
}
static void mw(unsigned slot, unsigned off, uint32_t v) {
  req0 = (slot << 12) | off | (2u << 16) | (1u << 18); req1 = v; req_v = 1; rsp_v = 0;
  int n = vio_poll();
  CHECK(n == 1 && !rsp_v, "write slot %u off %x", slot, off);
}

/* ---- split virtqueues in fake RAM: queue 0 desc 0x1000, avail 0x2000, used 0x3000; queue 1 (virtio-net's
 * transmitq) at 0x5000, 0x6000, 0x7000 ---- */
enum { NUM = 8 };
static const uint32_t QD[2] = { 0x1000, 0x5000 }, QA[2] = { 0x2000, 0x6000 }, QU[2] = { 0x3000, 0x7000 };
static uint16_t avail_idx[2], used_seen[2];
static void descq(unsigned qi, unsigned i, uint64_t off, uint32_t len, uint16_t flags, uint16_t next) {
  uint64_t pa = PA(off);
  memcpy(ram + QD[qi] + 16 * i, &pa, 8);
  memcpy(ram + QD[qi] + 16 * i + 8, &len, 4);
  memcpy(ram + QD[qi] + 16 * i + 12, &flags, 2);
  memcpy(ram + QD[qi] + 16 * i + 14, &next, 2);
}
static void submitq(unsigned slot, unsigned qi, uint16_t head) {
  memcpy(ram + QA[qi] + 4 + 2 * (avail_idx[qi] % NUM), &head, 2);
  avail_idx[qi]++;
  memcpy(ram + QA[qi] + 2, &avail_idx[qi], 2);
  irq_set = 0;
  mw(slot, 0x050, qi);                           /* QueueNotify */
}
/* the next used element is {head, len}, with the slot's interrupt bit set or (irq 0) not */
static void usedq(unsigned qi, uint16_t head, uint32_t len, unsigned slot, int irq) {
  uint16_t idx;
  uint32_t id, l;
  memcpy(&idx, ram + QU[qi] + 2, 2);
  CHECK(idx == (uint16_t)(used_seen[qi] + 1), "queue %u used.idx %u, want %u", qi, idx, used_seen[qi] + 1);
  memcpy(&id, ram + QU[qi] + 4 + 8 * (used_seen[qi] % NUM), 4);
  memcpy(&l, ram + QU[qi] + 8 + 8 * (used_seen[qi] % NUM), 4);
  CHECK(id == head && l == len, "queue %u used element %u: id %u len %u, want %u %u", qi, used_seen[qi], id, l,
        head, len);
  CHECK(irq_set == (irq ? 1u << (2 * slot) : 0), "VQ_IRQ set 0x%x, want 0x%x", irq_set, irq ? 1u << (2 * slot) : 0);
  used_seen[qi] = idx;
}
static uint16_t used_idx(unsigned qi) { uint16_t i; memcpy(&i, ram + QU[qi] + 2, 2); return i; }
static void desc(unsigned i, uint64_t off, uint32_t len, uint16_t flags, uint16_t next) {
  descq(0, i, off, len, flags, next);
}
static void submit(unsigned slot, uint16_t head) { submitq(slot, 0, head); }
static void used(uint16_t head, uint32_t len, unsigned slot) { usedq(0, head, len, slot, 1); }
static void queue(unsigned slot, unsigned qi) {
  mw(slot, 0x030, qi);
  CHECK(mr(slot, 0x034, 4) == 256, "QueueNumMax");
  mw(slot, 0x038, NUM);
  mw(slot, 0x080, (uint32_t)PA(QD[qi])); mw(slot, 0x084, 0);
  mw(slot, 0x090, (uint32_t)PA(QA[qi])); mw(slot, 0x094, 0);
  mw(slot, 0x0a0, (uint32_t)PA(QU[qi])); mw(slot, 0x0a4, 0);
  mw(slot, 0x044, 1);
  CHECK(mr(slot, 0x044, 4) == 1, "QueueReady");
}
static void setup(unsigned slot, uint64_t features) {
  memset(ram, 0, 0x8000);
  avail_idx[0] = avail_idx[1] = used_seen[0] = used_seen[1] = 0;
  mw(slot, 0x070, 0);                            /* reset */
  mw(slot, 0x070, 1 | 2);                        /* ACKNOWLEDGE, DRIVER */
  mw(slot, 0x024, 0); mw(slot, 0x020, (uint32_t)features);
  mw(slot, 0x024, 1); mw(slot, 0x020, (uint32_t)(features >> 32));
  mw(slot, 0x070, 1 | 2 | 8);                    /* FEATURES_OK */
  CHECK(mr(slot, 0x070, 4) == (1 | 2 | 8), "FEATURES_OK refused");
  queue(slot, 0);
  if (slot == 2) queue(slot, 1);                 /* virtio-net's transmitq */
  mw(slot, 0x030, slot == 2 ? 2 : 1);
  CHECK(mr(slot, 0x034, 4) == 0, "a queue past the device's last");
  mw(slot, 0x070, 1 | 2 | 8 | 4);                /* DRIVER_OK */
}

static void blk_hdr(uint64_t off, uint32_t type, uint64_t sector) {
  uint32_t z = 0;
  memcpy(ram + off, &type, 4); memcpy(ram + off + 4, &z, 4); memcpy(ram + off + 8, &sector, 8);
}

int main(void) {
  char path[512];
  snprintf(path, sizeof path, "%s/vio_test_XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : ".");
  int fd = mkstemp(path);
  if (fd < 0) { perror("mkstemp"); return 2; }
  static uint8_t img[1 << 20];                   /* 2048 sectors */
  for (unsigned i = 0; i < sizeof img; i++) img[i] = (uint8_t)(i * 7 + (i >> 9));
  if (write(fd, img, sizeof img) != (ssize_t)sizeof img) { perror("write"); return 2; }
  struct vio_hooks h = { f_rd, f_wr, f_rd64, f_wr64, f_wr32, f_wr8, f_bar, RAM_BYTES };
  int sv[2];                                     /* sv[0] the back-end's "TAP device", sv[1] the network */
  if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK, 0, sv)) { perror("socketpair"); return 2; }
  static const uint8_t mac[6] = { 0x02, 0x74, 0x6e, 0x67, 0x72, 0x01 };
  CHECK(vio_open(&h, path, 0, 1, sv[0], mac) == 0, "vio_open");

  /* ---- every slot's identity ---- */
  for (unsigned s = 0; s < 4; s++) {
    CHECK(mr(s, 0x000, 4) == 0x74726976, "slot %u MagicValue", s);
    CHECK(mr(s, 0x004, 4) == 2, "slot %u Version", s);
  }
  CHECK(mr(0, 0x008, 4) == 0, "slot 0 is empty");
  CHECK(mr(1, 0x008, 4) == 2 && mr(2, 0x008, 4) == 1 && mr(3, 0x008, 4) == 4, "slot 1 block, 2 network, 3 rng");
  /* features: VERSION_1, BLK_SIZE, FLUSH */
  mw(1, 0x014, 0); uint32_t f0 = mr(1, 0x010, 4);
  mw(1, 0x014, 1); uint32_t f1 = mr(1, 0x010, 4);
  CHECK(f0 == ((1u << 6) | (1u << 9)) && f1 == 1, "block features 0x%x 0x%x", f0, f1);
  /* configuration: capacity 2048, blk_size 512, narrow reads */
  CHECK(mr(1, 0x100, 4) == 2048 && mr(1, 0x104, 4) == 0, "capacity");
  CHECK(mr(1, 0x114, 4) == 512 && mr(1, 0x114, 2) == 512 && mr(1, 0x115, 1) == 2, "blk_size");
  /* a driver without VERSION_1 cannot set FEATURES_OK */
  mw(1, 0x070, 0); mw(1, 0x070, 3); mw(1, 0x024, 1); mw(1, 0x020, 0); mw(1, 0x070, 3 | 8);
  CHECK(!(mr(1, 0x070, 4) & 8), "FEATURES_OK without VERSION_1");
  CHECK(irq_clr == 0x0c, "reset cleared slot 1's status bits (0x%x)", irq_clr);

  /* ---- virtio-blk ---- */
  setup(1, (1ull << 32) | (1u << 9));
  /* read sectors 5-6: header, data, status */
  blk_hdr(0x10000, 0, 5);
  desc(0, 0x10000, 16, 1, 1);
  desc(1, 0x11000, 1024, 1 | 2, 2);
  desc(2, 0x12000, 1, 2, 0);
  ram[0x12000] = 0xff;
  submit(1, 0);
  used(0, 1025, 1);
  CHECK(ram[0x12000] == 0 && !memcmp(ram + 0x11000, img + 5 * 512, 1024), "read sectors 5-6");
  /* write sector 7 from two buffers, then read it back */
  blk_hdr(0x10100, 1, 7);
  for (int i = 0; i < 512; i++) ram[0x13000 + i] = (uint8_t)(0xA5 ^ i);
  desc(3, 0x10100, 16, 1, 4);
  desc(4, 0x13000, 200, 1, 5);
  desc(5, 0x13000 + 200, 312, 1, 6);
  desc(6, 0x12001, 1, 2, 0);
  submit(1, 3);
  used(3, 1, 1);
  uint8_t back[512];
  pread(fd, back, 512, 7 * 512);
  CHECK(ram[0x12001] == 0 && !memcmp(back, ram + 0x13000, 512), "write sector 7");
  /* no framing assumed (§5.2.6.1): data and status in one descriptor; header and data in one */
  blk_hdr(0x14000, 0, 7);
  desc(0, 0x14000, 16, 1, 1);
  desc(1, 0x15000, 513, 2, 0);
  submit(1, 0);
  used(0, 513, 1);
  CHECK(!memcmp(ram + 0x15000, back, 512) && ram[0x15000 + 512] == 0, "read with the status in the data's descriptor");
  blk_hdr(0x17000, 1, 9);
  for (int i = 0; i < 512; i++) ram[0x17010 + i] = (uint8_t)(0x3C + 3 * i);
  desc(0, 0x17000, 16 + 512, 1, 1);
  desc(1, 0x12007, 1, 2, 0);
  submit(1, 0);
  used(0, 1, 1);
  pread(fd, back, 512, 9 * 512);
  CHECK(ram[0x12007] == 0 && !memcmp(back, ram + 0x17010, 512), "write with header and data in one descriptor");
  /* a chain that loops is refused without a status, and the device goes on */
  desc(0, 0x10000, 16, 1, 1);
  desc(1, 0x12008, 1, 1 | 2, 0);
  submit(1, 0);
  used(0, 0, 1);
  /* flush, GET_ID, beyond the end, an unknown type */
  blk_hdr(0x10200, 4, 0); desc(0, 0x10200, 16, 1, 1); desc(1, 0x12002, 1, 2, 0);
  submit(1, 0); used(0, 1, 1);
  CHECK(ram[0x12002] == 0, "flush");
  blk_hdr(0x10300, 8, 0); desc(0, 0x10300, 16, 1, 1); desc(1, 0x16000, 20, 1 | 2, 2); desc(2, 0x12003, 1, 2, 0);
  submit(1, 0); used(0, 21, 1);
  CHECK(ram[0x12003] == 0 && !memcmp(ram + 0x16000, "tanager-virtio-blk", 18), "GET_ID");
  blk_hdr(0x10400, 0, 2047); desc(0, 0x10400, 16, 1, 1); desc(1, 0x11000, 1024, 1 | 2, 2); desc(2, 0x12004, 1, 2, 0);
  submit(1, 0); used(0, 1, 1);
  CHECK(ram[0x12004] == 1, "beyond the end: IOERR");
  blk_hdr(0x10500, 99, 0); desc(0, 0x10500, 16, 1, 1); desc(1, 0x12005, 1, 2, 0);
  submit(1, 0); used(0, 1, 1);
  CHECK(ram[0x12005] == 2, "unknown type: UNSUPP");
  /* no interrupt while avail.flags says NO_INTERRUPT */
  ram[QA[0]] = 1;
  blk_hdr(0x10600, 4, 0); desc(0, 0x10600, 16, 1, 1); desc(1, 0x12006, 1, 2, 0);
  submit(1, 0);
  CHECK(irq_set == 0, "an interrupt despite NO_INTERRUPT");
  ram[QA[0]] = 0;

  /* ---- virtio-rng ---- */
  setup(3, 1ull << 32);
  memset(ram + 0x20000, 0, 64);
  desc(0, 0x20000, 64, 2, 0);
  submit(3, 0);
  used(0, 64, 3);
  int nz = 0;
  for (int i = 0; i < 64; i++) nz += ram[0x20000 + i] != 0;
  CHECK(nz > 32, "rng bytes look random (%d of 64 non-zero)", nz);

  /* ---- virtio-net ---- */
  mw(2, 0x014, 0); f0 = mr(2, 0x010, 4);
  mw(2, 0x014, 1); f1 = mr(2, 0x010, 4);
  CHECK(f0 == ((1u << 5) | (1u << 16)) && f1 == 1, "network features 0x%x 0x%x", f0, f1);
  CHECK(mr(2, 0x100, 4) == 0x676e7402 && mr(2, 0x104, 2) == 0x0172 && mr(2, 0x106, 2) == 1, "mac and link up");
  setup(2, (1ull << 32) | (1u << 5) | (1u << 16));
  uint8_t fr[1600], got[2048];
  for (unsigned i = 0; i < sizeof fr; i++) fr[i] = (uint8_t)(i * 3 + 1);
  /* transmitq: a frame after its header in a second descriptor, then both in one */
  memset(ram + 0x30000, 0, 12);
  memcpy(ram + 0x30100, fr, 60);
  descq(1, 0, 0x30000, 12, 1, 1);
  descq(1, 1, 0x30100, 60, 0, 0);
  submitq(2, 1, 0);
  usedq(1, 0, 0, 2, 1);
  ssize_t n = recv(sv[1], got, sizeof got, 0);
  CHECK(n == 60 && !memcmp(got, fr, 60), "sent a frame from two descriptors (%zd bytes)", n);
  memset(ram + 0x30200, 0, 12);
  memcpy(ram + 0x30200 + 12, fr + 7, 1514);
  descq(1, 2, 0x30200, 12 + 1514, 0, 0);
  submitq(2, 1, 2);
  usedq(1, 2, 0, 2, 1);
  n = recv(sv[1], got, sizeof got, 0);
  CHECK(n == 1514 && !memcmp(got, fr + 7, 1514), "sent a full-size frame from one descriptor (%zd bytes)", n);
  /* a runt (no Ethernet header) goes back unsent */
  descq(1, 3, 0x30800, 12 + 10, 0, 0);
  submitq(2, 1, 3);
  usedq(1, 3, 0, 2, 1);
  CHECK(recv(sv[1], got, sizeof got, 0) < 0, "a runt went out");
  /* receiveq: two buffers wait, then a frame comes */
  descq(0, 0, 0x40000, 12 + 1514, 2, 0);
  descq(0, 1, 0x41000, 12 + 1514, 2, 0);
  submitq(2, 0, 0);
  submitq(2, 0, 1);
  CHECK(used_idx(0) == 0 && irq_set == 0, "a buffer used with nothing received");
  memset(ram + 0x40000, 0xee, 12);
  send(sv[1], fr + 3, 100, 0);
  irq_set = 0;
  CHECK(vio_poll() == 1, "one frame received");
  usedq(0, 0, 112, 2, 1);
  static const uint8_t hdr[12] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 };   /* num_buffers 1 */
  CHECK(!memcmp(ram + 0x40000, hdr, 12) && !memcmp(ram + 0x40000 + 12, fr + 3, 100), "the received frame");
  /* two frames, one buffer: the second waits until the driver adds a buffer */
  send(sv[1], fr, 64, 0);
  send(sv[1], fr + 1, 1514, 0);
  irq_set = 0;
  CHECK(vio_poll() == 1, "one buffer, one frame");
  usedq(0, 1, 76, 2, 1);
  irq_set = 0;
  CHECK(vio_poll() == 0 && irq_set == 0, "a frame received without a buffer");
  descq(0, 2, 0x42000, 12 + 1514, 2, 0);
  submitq(2, 0, 2);
  usedq(0, 2, 12 + 1514, 2, 1);
  CHECK(!memcmp(ram + 0x42000 + 12, fr + 1, 1514), "the frame that waited");
  /* a buffer too small goes back empty, its frame dropped; a buffer the device would have to read too */
  descq(0, 3, 0x43000, 64, 2, 0);
  submitq(2, 0, 3);
  send(sv[1], fr, 200, 0);
  irq_set = 0;
  vio_poll();
  usedq(0, 3, 0, 2, 1);
  descq(0, 4, 0x44000, 16, 0, 5);
  descq(0, 5, 0x44100, 12 + 1514, 2, 0);
  submitq(2, 0, 4);
  send(sv[1], fr, 60, 0);
  irq_set = 0;
  vio_poll();
  usedq(0, 4, 0, 2, 1);
  /* no interrupt while the receiveq's avail.flags says NO_INTERRUPT */
  ram[QA[0]] = 1;
  descq(0, 6, 0x45000, 12 + 1514, 2, 0);
  submitq(2, 0, 6);
  send(sv[1], fr, 60, 0);
  irq_set = 0;
  vio_poll();
  usedq(0, 6, 72, 2, 0);
  ram[QA[0]] = 0;
  /* frames that come after a reset, before the driver is ready again, are dropped */
  mw(2, 0x070, 0);
  send(sv[1], fr, 60, 0);
  vio_poll();
  CHECK(recv(sv[0], got, sizeof got, 0) < 0, "a frame left waiting after the reset");
  uint64_t rx, tx, dr;
  vio_net_stats(&rx, &tx, &dr);
  CHECK(rx == 4 && tx == 2 && dr == 4, "network counters: %llu received, %llu sent, %llu dropped",
        (unsigned long long)rx, (unsigned long long)tx, (unsigned long long)dr);

  CHECK(!narrow_idx, "the used ring's index was written in pieces");
  vio_close();
  close(sv[0]);
  close(sv[1]);
  unlink(path);
  uint64_t r, rb, wb;
  vio_stats(&r, &rb, &wb);
  printf("vio_test: %llu requests, %llu bytes read, %llu written; %llu frames received, %llu sent: %s\n",
         (unsigned long long)r, (unsigned long long)rb, (unsigned long long)wb, (unsigned long long)rx,
         (unsigned long long)tx, errors ? "FAIL" : "PASS");
  return errors ? 1 : 0;
}
