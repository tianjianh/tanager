/* The forwarded virtio window's back-ends (docs/spec/soc.md §8.1; virtio.h). Written from the OASIS
 * virtio 1.2 specification: virtio-mmio version 2 registers (§4.2.2), split virtqueues (§2.7),
 * virtio-blk (§5.2) and virtio-rng (§5.4). The A53 reaches the virtqueues and buffers through the host
 * DMA port, an uncached device mapping, so every access is aligned: 8-byte reads, and 8-, 4- or 1-byte
 * writes. */
#define _GNU_SOURCE
#include "virtio.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <unistd.h>

#define NSLOTS      4
#define QMAX        256u                         /* QueueNumMax */
#define RAM_BASE    0x80000000ull                /* the RISC-V's RAM, physical */
#define SLOT_BLK    1
#define SLOT_RNG    3

/* status bits (§2.1) */
#define ST_FEATURES_OK  8u
/* features */
#define F_VERSION_1     (1ull << 32)
#define BLK_F_RO        (1ull << 5)
#define BLK_F_BLK_SIZE  (1ull << 6)
#define BLK_F_FLUSH     (1ull << 9)
/* descriptor flags (§2.7.5) */
#define D_NEXT  1u
#define D_WRITE 2u
#define D_INDIRECT 4u
/* virtio-blk request types and status (§5.2.6) */
#define BLK_T_IN     0u
#define BLK_T_OUT    1u
#define BLK_T_FLUSH  4u
#define BLK_T_GET_ID 8u
#define BLK_S_OK     0u
#define BLK_S_IOERR  1u
#define BLK_S_UNSUPP 2u

struct vq {
  uint32_t num, ready;
  uint64_t desc, avail, used;                    /* physical addresses */
  uint16_t last_avail, used_idx;
};

struct vdev {
  uint32_t id;                                   /* DeviceID: 0 none, 2 block, 4 rng */
  uint64_t features, drv_features;
  uint32_t dev_sel, drv_sel, qsel, status, cfg_gen;
  struct vq q;                                   /* one queue each */
  uint8_t  config[32];
  unsigned cfg_len;
};

static struct vio_hooks H;
static struct vdev dev[NSLOTS];
static int blk_fd = -1, blk_ro;
static uint64_t blk_sectors;
static uint64_t n_reqs, n_rd, n_wr;

/* ---- the RISC-V's RAM through the DMA port ---- */
static int ram_ok(uint64_t pa, uint64_t len) {
  return pa >= RAM_BASE && len <= H.ram_size && pa - RAM_BASE <= H.ram_size - len;
}
static uint8_t ram_rd8(uint64_t off) { return (uint8_t)(H.ram_rd64(off & ~7ull) >> (8 * (off & 7))); }
static uint64_t ram_rd(uint64_t off, unsigned n) {          /* n <= 8 bytes, not crossing 8 */
  uint64_t q = H.ram_rd64(off & ~7ull) >> (8 * (off & 7));
  return n == 8 ? q : q & ((1ull << (8 * n)) - 1);
}
static void ram_wr(uint64_t off, uint64_t v, unsigned n) {   /* the largest aligned stores */
  while (n) {
    if (n >= 8 && !(off & 7))      { H.ram_wr64(off, v); off += 8; n -= 8; v = 0; }
    else if (n >= 4 && !(off & 3)) { H.ram_wr32(off, (uint32_t)v); off += 4; n -= 4; v >>= 32; }
    else                           { H.ram_wr8(off, (uint8_t)v); off++; n--; v >>= 8; }
  }
}
static void ram_read(uint64_t off, uint8_t *buf, uint64_t len) {
  while (len && (off & 7)) { *buf++ = ram_rd8(off++); len--; }
  for (; len >= 8; len -= 8, off += 8, buf += 8) { uint64_t q = H.ram_rd64(off); memcpy(buf, &q, 8); }
  while (len) { *buf++ = ram_rd8(off++); len--; }
}
static void ram_write(uint64_t off, const uint8_t *buf, uint64_t len) {
  while (len && (off & 7)) { H.ram_wr8(off++, *buf++); len--; }
  for (; len >= 8; len -= 8, off += 8, buf += 8) { uint64_t q; memcpy(&q, buf, 8); H.ram_wr64(off, q); }
  while (len) { H.ram_wr8(off++, *buf++); len--; }
}

/* ---- a descriptor chain as two byte streams: what the device reads, then what it writes ---- */
#define MAXSEG 64
struct seg { uint64_t pa; uint32_t len; };
struct chain { struct seg r[MAXSEG], w[MAXSEG]; unsigned nr, nw; uint64_t rlen, wlen; int bad; };

static void walk(const struct vq *q, uint16_t head, struct chain *c) {
  memset(c, 0, sizeof *c);
  uint16_t i = head;
  for (unsigned n = 0; ; n++) {
    if (i >= q->num || n >= q->num) { c->bad = 1; return; }
    uint64_t d = q->desc + 16ull * i - RAM_BASE;
    uint64_t pa = H.ram_rd64(d), w1 = H.ram_rd64(d + 8);
    uint32_t len = (uint32_t)w1;
    uint16_t flags = (uint16_t)(w1 >> 32), next = (uint16_t)(w1 >> 48);
    if ((flags & D_INDIRECT) || !ram_ok(pa, len)) { c->bad = 1; return; }   /* indirect is not offered */
    if (flags & D_WRITE) {
      if (c->nw == MAXSEG) { c->bad = 1; return; }
      c->w[c->nw++] = (struct seg){ pa, len }; c->wlen += len;
    } else {
      if (c->nw || c->nr == MAXSEG) { c->bad = 1; return; }                /* readable first (§2.7.4.2) */
      c->r[c->nr++] = (struct seg){ pa, len }; c->rlen += len;
    }
    if (!(flags & D_NEXT)) return;
    i = next;
  }
}
/* copy bytes [pos, pos + len) of a stream */
static void stream_read(const struct seg *s, unsigned n, uint64_t pos, uint8_t *buf, uint64_t len) {
  for (unsigned k = 0; k < n && len; k++) {
    if (pos >= s[k].len) { pos -= s[k].len; continue; }
    uint64_t m = s[k].len - pos < len ? s[k].len - pos : len;
    ram_read(s[k].pa - RAM_BASE + pos, buf, m);
    buf += m; len -= m; pos = 0;
  }
}
static void stream_write(const struct seg *s, unsigned n, uint64_t pos, const uint8_t *buf, uint64_t len) {
  for (unsigned k = 0; k < n && len; k++) {
    if (pos >= s[k].len) { pos -= s[k].len; continue; }
    uint64_t m = s[k].len - pos < len ? s[k].len - pos : len;
    ram_write(s[k].pa - RAM_BASE + pos, buf, m);
    buf += m; len -= m; pos = 0;
  }
}

/* ---- the used ring: the element, then flags and idx together in one aligned 32-bit store, so the
 * driver never sees half an index ---- */
static void used_push(struct vq *q, uint16_t head, uint32_t written) {
  uint64_t u = q->used - RAM_BASE;
  ram_wr(u + 4 + 8ull * (q->used_idx % q->num), (uint64_t)head | ((uint64_t)written << 32), 8);
  H.barrier();
  q->used_idx++;
  ram_wr(u, (uint64_t)q->used_idx << 16, 4);
}
static void irq(unsigned slot, unsigned bit) {
  H.barrier();                                   /* the used ring before the interrupt */
  H.wr(VQ_IRQ, 1u << (2 * slot + bit));
}

/* ---- virtio-blk ---- */
static uint8_t blk_one(const struct chain *c, uint32_t *written) {
  uint8_t hdr[16], buf[65536];
  *written = 0;
  if (c->bad || c->rlen < 16 || c->wlen < 1) return BLK_S_IOERR;
  stream_read(c->r, c->nr, 0, hdr, 16);
  uint32_t type; uint64_t sector;
  memcpy(&type, hdr, 4); memcpy(&sector, hdr + 8, 8);
  uint64_t dlen = type == BLK_T_OUT ? c->rlen - 16 : c->wlen - 1;   /* the data between header and status */
  switch (type) {
  case BLK_T_IN:
  case BLK_T_OUT:
    if (dlen % 512 || sector > blk_sectors || dlen / 512 > blk_sectors - sector) return BLK_S_IOERR;
    if (type == BLK_T_OUT && blk_ro) return BLK_S_IOERR;
    for (uint64_t pos = 0; pos < dlen; ) {
      uint64_t m = dlen - pos < sizeof buf ? dlen - pos : sizeof buf;
      if (type == BLK_T_IN) {
        if (pread(blk_fd, buf, m, (off_t)(sector * 512 + pos)) != (ssize_t)m) return BLK_S_IOERR;
        stream_write(c->w, c->nw, pos, buf, m);
        n_rd += m;
      } else {
        stream_read(c->r, c->nr, 16 + pos, buf, m);
        if (pwrite(blk_fd, buf, m, (off_t)(sector * 512 + pos)) != (ssize_t)m) return BLK_S_IOERR;
        n_wr += m;
      }
      pos += m;
    }
    if (type == BLK_T_IN) *written = (uint32_t)dlen;
    return BLK_S_OK;
  case BLK_T_FLUSH:
    return fsync(blk_fd) ? BLK_S_IOERR : BLK_S_OK;
  case BLK_T_GET_ID: {
    static const char id[20] = "tanager-virtio-blk";
    uint64_t m = dlen < 20 ? dlen : 20;
    stream_write(c->w, c->nw, 0, (const uint8_t *)id, m);
    *written = (uint32_t)m;
    return BLK_S_OK;
  }
  default:
    return BLK_S_UNSUPP;
  }
}

static void rng_one(const struct chain *c, uint32_t *written) {
  uint8_t buf[4096];
  uint64_t len = c->bad ? 0 : (c->wlen < sizeof buf ? c->wlen : sizeof buf);
  if (len && getrandom(buf, len, 0) != (ssize_t)len) len = 0;
  stream_write(c->w, c->nw, 0, buf, len);
  *written = (uint32_t)len;
}

/* QueueNotify: every new available buffer, then one interrupt unless the driver asked for none */
static void notify(unsigned slot) {
  struct vdev *v = &dev[slot];
  struct vq *q = &v->q;
  if (!q->ready || !q->num || !(v->status & ST_FEATURES_OK)) return;
  uint64_t a = q->avail - RAM_BASE;
  int did = 0;
  for (;;) {
    uint16_t idx = (uint16_t)ram_rd(a + 2, 2);
    if (q->last_avail == idx) break;
    uint16_t head = (uint16_t)ram_rd(a + 4 + 2ull * (q->last_avail % q->num), 2);
    struct chain c;
    uint32_t written = 0;
    walk(q, head, &c);
    if (v->id == 2) {
      uint8_t st = blk_one(&c, &written);
      if (!c.bad && c.wlen) {                    /* the status: the last byte the device writes */
        stream_write(c.w, c.nw, c.wlen - 1, &st, 1);
        written++;
      }
    } else {
      rng_one(&c, &written);
    }
    used_push(q, head, written);
    q->last_avail++;
    did = 1;
    n_reqs++;
  }
  if (did && !(ram_rd(a, 2) & 1)) irq(slot, 0);   /* avail.flags NO_INTERRUPT */
}

static void dev_reset(unsigned slot) {
  struct vdev *v = &dev[slot];
  v->drv_features = 0; v->dev_sel = v->drv_sel = v->qsel = v->status = 0;
  memset(&v->q, 0, sizeof v->q);
  H.wr(VQ_IRQ, 3u << (8 + 2 * slot));           /* clear the slot's status bits */
}

/* ---- the registers (§4.2.2) ---- */
static uint32_t reg_read(unsigned slot, unsigned off, unsigned size) {
  struct vdev *v = &dev[slot];
  if (off >= 0x100) {                            /* configuration space, 8-, 16- or 32-bit */
    unsigned o = off - 0x100;
    uint32_t r = 0;
    for (unsigned b = 0; b < size; b++) if (o + b < v->cfg_len) r |= (uint32_t)v->config[o + b] << (8 * b);
    return r;
  }
  if (!v->id && off != 0x000 && off != 0x004) return 0;
  switch (off) {
  case 0x000: return 0x74726976;                 /* "virt" */
  case 0x004: return 2;
  case 0x008: return v->id;
  case 0x00c: return 0x52474E54;                 /* "TNGR" */
  case 0x010: return v->dev_sel < 2 ? (uint32_t)(v->features >> (32 * v->dev_sel)) : 0;
  case 0x034: return v->qsel == 0 ? QMAX : 0;
  case 0x044: return v->qsel == 0 ? v->q.ready : 0;
  case 0x070: return v->status;
  case 0x0b0: case 0x0b4: case 0x0b8: case 0x0bc: return 0xffffffffu;   /* no shared memory */
  case 0x0fc: return v->cfg_gen;
  default:    return 0;
  }
}

static void set_lo(uint64_t *x, uint32_t v) { *x = (*x & ~0xffffffffull) | v; }
static void set_hi(uint64_t *x, uint32_t v) { *x = (*x & 0xffffffffull) | ((uint64_t)v << 32); }

static void reg_write(unsigned slot, unsigned off, uint32_t val) {
  struct vdev *v = &dev[slot];
  if (!v->id || off >= 0x100) return;            /* no device; the configuration space is read-only */
  struct vq *q = &v->q;
  int qok = v->qsel == 0;
  switch (off) {
  case 0x014: v->dev_sel = val; break;
  case 0x020:
    if (v->drv_sel < 2) v->drv_features = (v->drv_features & ~(0xffffffffull << (32 * v->drv_sel))) |
                                          ((uint64_t)val << (32 * v->drv_sel));
    break;
  case 0x024: v->drv_sel = val; break;
  case 0x030: v->qsel = val; break;
  case 0x038: if (qok && val && val <= QMAX) q->num = val; break;
  case 0x044:
    if (qok) {
      q->ready = val & 1;
      if (q->ready) { q->last_avail = 0; q->used_idx = 0; }
    }
    break;
  case 0x050: if (val == 0) notify(slot); break;
  case 0x070:
    if (val == 0) { dev_reset(slot); break; }
    /* FEATURES_OK holds only for a subset of what is offered that includes VERSION_1 */
    if ((val & ST_FEATURES_OK) && !(v->status & ST_FEATURES_OK) &&
        ((v->drv_features & ~v->features) || !(v->drv_features & F_VERSION_1)))
      val &= ~ST_FEATURES_OK;
    v->status = val;
    break;
  case 0x080: if (qok) set_lo(&q->desc, val); break;
  case 0x084: if (qok) set_hi(&q->desc, val); break;
  case 0x090: if (qok) set_lo(&q->avail, val); break;
  case 0x094: if (qok) set_hi(&q->avail, val); break;
  case 0x0a0: if (qok) set_lo(&q->used, val); break;
  case 0x0a4: if (qok) set_hi(&q->used, val); break;
  default: break;
  }
  /* a queue the driver makes ready must lie in RAM */
  if (q->ready && (!ram_ok(q->desc, 16ull * q->num) || !ram_ok(q->avail, 6 + 2ull * q->num) ||
                   !ram_ok(q->used, 6 + 8ull * q->num))) {
    q->ready = 0;
    v->status |= 0x40;                           /* DEVICE_NEEDS_RESET */
    irq(slot, 1);
  }
}

/* ---- the service loop ---- */
int vio_poll(void) {
  int n = 0;
  for (;;) {
    uint32_t r0 = H.rd(VQ_REQ0);
    if (!(r0 >> 31)) break;
    uint32_t r1 = H.rd(VQ_REQ1);                 /* pops the request */
    unsigned slot = (r0 >> 12) & 3, off = r0 & 0xfff, size = 1u << ((r0 >> 16) & 3);
    if ((r0 >> 18) & 1) reg_write(slot, off, r1);
    else                H.wr(VQ_RSP, reg_read(slot, off, size));
    n++;
  }
  return n;
}

int vio_open(const struct vio_hooks *h, const char *blk_image, int readonly, int rng) {
  H = *h;
  memset(dev, 0, sizeof dev);
  n_reqs = n_rd = n_wr = 0;
  if (blk_image) {
    blk_fd = open(blk_image, readonly ? O_RDONLY : O_RDWR);
    struct stat sb;
    if (blk_fd < 0 || fstat(blk_fd, &sb)) { fprintf(stderr, "virtio-blk: %s: %s\n", blk_image, strerror(errno)); return -1; }
    blk_ro = readonly;
    blk_sectors = (uint64_t)sb.st_size / 512;
    struct vdev *v = &dev[SLOT_BLK];
    v->id = 2;
    v->features = F_VERSION_1 | BLK_F_BLK_SIZE | BLK_F_FLUSH | (readonly ? BLK_F_RO : 0);
    memcpy(v->config, &blk_sectors, 8);          /* capacity, 512-byte sectors */
    uint32_t bs = 512;
    memcpy(v->config + 20, &bs, 4);              /* blk_size */
    v->cfg_len = 24;
  }
  if (rng) {
    dev[SLOT_RNG].id = 4;
    dev[SLOT_RNG].features = F_VERSION_1;
  }
  return 0;
}

void vio_close(void) {
  if (blk_fd >= 0) { fsync(blk_fd); close(blk_fd); blk_fd = -1; }
}

void vio_stats(uint64_t *reqs, uint64_t *rd_bytes, uint64_t *wr_bytes) {
  *reqs = n_reqs; *rd_bytes = n_rd; *wr_bytes = n_wr;
}
