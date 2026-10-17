/* tanager-host: the A53-side control program for the Tanager SoC on the KV260 (docs/spec/host.md).
 *
 * It maps the host bridge's register window and the RISC-V DRAM carve-out through /dev/mem, loads
 * images, releases the RISC-V reset, bridges the console (stdio or a pty), watches power and tohost
 * requests, sets the latency injector, and collects the commit trace from its DDR ring
 * (docs/spec/uncore-trace.md). Runs as root on the board's Linux.
 *
 * Build: make -C sw/host (static aarch64 binary; see sw/host/Makefile).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/if_tun.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include "virtio.h"

/* ---- Host register map (docs/spec/host.md) ---- */
enum {
  R_ID = 0x000, R_VERSION = 0x004, R_CLK_HZ = 0x008, R_CAPS = 0x00C,
  R_CTRL = 0x010, R_STATUS = 0x014, R_POWER = 0x018,
  R_DRAM_BASE = 0x020, R_DRAM_SIZE = 0x028, R_BOOT_ENTRY = 0x030, R_DTB_ADDR = 0x038,
  R_INJ_RD = 0x040, R_INJ_WR = 0x044, R_INJ_CTRL = 0x048,
  R_INJ_CNT = 0x050, R_INJ_SUM = 0x054, R_INJ_MAX = 0x058,
  R_TOHOST = 0x060, R_FROMHOST = 0x068, R_MBOX_IN = 0x070, R_MBOX_OUT = 0x074,
  R_IRQ_STATUS = 0x080, R_IRQ_ENABLE = 0x084, R_TOHOST_SEQ = 0x088,
  R_TG_CTRL = 0x0C0, R_TG_BASE = 0x0C4, R_TG_LINES = 0x0C8,
  R_TG_OPS = 0x0D0, R_TG_ERRS = 0x0D4, R_TG_ERR_LINE = 0x0D8, R_TG_PASS = 0x0DC,
  R_UART_TX = 0x100, R_UART_TX_LEVEL = 0x104, R_UART_RX = 0x108, R_UART_RX_SPACE = 0x10C,
  R_TRS_CTRL = 0x1000, R_TRS_TRIG_PC = 0x1008, R_TRS_POST = 0x1010, R_TRS_START_PC = 0x1018,
  R_TRS_BASE = 0x1020, R_TRS_SIZE = 0x1028, R_TRS_RP = 0x1030, R_TRS_WP = 0x1038,
  R_TRS_STATUS = 0x1040, R_TRS_STALLS = 0x1044, R_TRS_INFO = 0x1048,
  R_VQ_CTRL = 0x1100, R_VQ_STATUS = 0x1104, R_VQ_REQ0 = 0x1108, R_VQ_REQ1 = 0x110C,
  R_VQ_RSP = 0x1110, R_VQ_IRQ = 0x1114,
  R_HDMA_CTRL = 0x1300, R_HDMA_STATUS = 0x1304, R_HDMA_RD_LINES = 0x1308, R_HDMA_WR_LINES = 0x130C,
  R_HDMA_CPL0 = 0x1310, R_HDMA_CPL1 = 0x1314, R_HDMA_WR_DROPS = 0x1318,
  R_DBG_SEL = 0x1200, R_DBG_VAL = 0x1204,
};
#define TRS_EN         0x001u
#define TRS_WRAP       0x002u
#define TRS_STOP_ARM   0x100u
#define TRS_START_ARM  0x200u
#define TRS_ST_CAPTURING 0x1u
#define TRS_ST_STARTED   0x2u
#define TRS_ST_STOPPED   0x4u
#define TRS_ST_FULL      0x8u
#define TRS_ST_AXI_ERR   0x10u
#define TRS_REC_BYTES  64u
#define CAPS_VIRTIO    0x4u            /* CAPS[2]: the forwarded virtio window (stage C, soc.md §8.1) */
#define CAPS_TRACE     0x8u            /* CAPS[3]: the commit-trace stream is built (DR-146) */
#define CAPS_HDMA      0x100u          /* CAPS[8]: the coherent host DMA port (stage C, soc.md §8.1) */
#define TG_ID          0x54474E52u     /* "TNGR" */
#define CTRL_CORE_RST  0x1u
#define CTRL_UNC_RST   0x2u
#define CTRL_LOSSLESS  0x4u
#define ST_CORES_RST   0x1u
#define ST_UNC_RST     0x2u
#define ST_L2_INIT     0x4u
#define ST_POWER_REQ   0x8u
#define POWER_OFF      0x5555u
#define POWER_REBOOT   0x7777u
#define POWER_FAIL     0x3333u

#define DRAM_BASE_RV   0x80000000ull   /* tg_map_pkg::DRAM_BASE */
#define OFF_FW         0x0ull          /* docs/spec/soc.md §3 */
#define OFF_KERNEL     0x200000ull
#define OFF_DTB        0x2200000ull

static volatile uint32_t *regs;
static const char *prog = "tanager-host";
static int verbose;

static void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "%s: ", prog);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  exit(2);
}

static uint32_t rd(unsigned off) { return regs[off / 4]; }
static void wr(unsigned off, uint32_t v) { regs[off / 4] = v; }
static uint64_t rd64(unsigned off) { return rd(off) | ((uint64_t)rd(off + 4) << 32); }
static void wr64(unsigned off, uint64_t v) { wr(off, (uint32_t)v); wr(off + 4, (uint32_t)(v >> 32)); }

static void *map_phys(uint64_t pa, size_t len) {
  int fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (fd < 0) die("open /dev/mem: %s (run as root)", strerror(errno));
  long pg = sysconf(_SC_PAGESIZE);
  uint64_t base = pa & ~(uint64_t)(pg - 1);
  size_t off = (size_t)(pa - base);
  void *p = mmap(NULL, len + off, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)base);
  close(fd);
  if (p == MAP_FAILED) die("mmap 0x%" PRIx64 "+0x%zx: %s", pa, len, strerror(errno));
  return (uint8_t *)p + off;
}

/* Touch the PL only while our design is loaded: a read that nothing answers hangs the ARM until a
 * power cycle (the board session's hang, 2026-10-14). The overlay that loads the bitstream adds the
 * host bridge's node to the live device tree, and dfx-mgr removes it with the bitstream. */
static void check_overlay(uint64_t regs_pa) {
  static const char *const bus[] = { "axi", "amba" };
  char path[96];
  for (int i = 0; i < 2; i++) {
    snprintf(path, sizeof path, "/sys/firmware/devicetree/base/%s/tanager@%" PRIx64, bus[i], regs_pa);
    if (access(path, F_OK) == 0) return;
  }
  die("no Tanager design is loaded (no /sys/firmware/devicetree/base/axi/tanager@%" PRIx64 "). "
      "Load it first (sudo xmutil loadapp tanager): reading the PL without it hangs the board. "
      "--force skips this check", regs_pa);
}

static void sleep_us(long us) {
  struct timespec ts = { us / 1000000, (us % 1000000) * 1000 };
  nanosleep(&ts, NULL);
}

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* ---- Options ---- */
struct opts {
  uint64_t regs_pa, base, size;
  uint64_t dma_pa;        /* the host DMA port's window (M_AXI_HPM1_FPD): the RISC-V's RAM from offset 0 */
  const char *blk;        /* virtio-blk image (slot 1), served through the window and the DMA port */
  int blk_ro, rng;        /* the image read-only; virtio-rng (slot 3) */
  const char *net;        /* virtio-net (slot 2) on this TAP device, made if missing */
  const char *net_bridge; /* and the bridge it joins (the A53's br0, docs/spec/soc.md §8.1), or NULL */
  uint8_t net_mac[6];     /* the RISC-V's MAC address */
  const char *fw, *kernel, *dtb;
  int console;            /* 0 stdio, 1 pty, -1 none */
  double timeout;
  long inj_rd, inj_wr, inj_mode, inj_bw;
  int lossless;
  /* commit trace (docs/spec/uncore-trace.md): a ring at the top of the carve-out */
  const char *trace;      /* output file ("-" = stdout); NULL = no tracing */
  int trace_log2;         /* ring of 2^n records */
  int trace_wrap;         /* post-mortem: the ring wraps, dumped at exit */
  int trace_start, trace_stop;
  int zero;               /* load: zero the RISC-V window first (also with --trace) */
  uint64_t trace_start_pc, trace_stop_pc;
  uint32_t trace_post;
};

/* The trace ring takes the top of the carve-out; the RISC-V DRAM window is what is left. */
static uint64_t trace_bytes(const struct opts *o) { return o->trace ? (uint64_t)TRS_REC_BYTES << o->trace_log2 : 0; }
static uint64_t dram_bytes(const struct opts *o)  { return o->size - trace_bytes(o); }

static void usage(void) {
  fprintf(stderr,
    "usage: %s [global options] <command> [args]\n"
    "global options:\n"
    "  --regs PA        host bridge window (default 0xA0000000)\n"
    "  --base PA        carve-out start in PS address space (default 0x840000000)\n"
    "  --size BYTES     carve-out size (default 0x40000000)\n"
    "  --force          touch the register window without the overlay check (see check_overlay)\n"
    "  -v               verbose\n"
    "Options may come before or after the command.\n"
    "commands:\n"
    "  info                                   identity and status\n"
    "  reset                                  hold cores and uncore in reset\n"
    "  load --fw F --kernel K --dtb D [--zero] reset, set the window, copy images (soc.md §3); --zero\n"
    "                                         (implied by --trace) zeroes the window first\n"
    "  run [--pty|--no-console] [--timeout S] [--lossless] [--inj-rd N] [--inj-wr N] [--inj-mode M] [--inj-bw R]\n"
    "      [--trace FILE [--trace-log2 N] [--trace-wrap] [--trace-start PC] [--trace-stop PC [--trace-post N]]]\n"
    "                                         release reset (a running system keeps running), bridge the\n"
    "                                         console, exit on power-off/tohost and hold everything;\n"
    "                                         --trace writes every commit record (64 B each) to FILE, stalling\n"
    "                                         the cores while it falls behind (with --trace-wrap: the last\n"
    "                                         2^N records, at exit). The ring takes the top 64 B << N of the\n"
    "                                         carve-out (default N 22: 256 MiB); the device tree's memory must\n"
    "                                         fit in the rest. --trace - writes the records to stdout and\n"
    "                                         everything else to stderr; if the reader stops, run exits 4\n"
    "  trace status                           commit-trace stream state\n"
    "  boot ...                               load, then run\n"
    "      [--blk IMAGE [--blk-ro]] [--rng]    with load/run/boot: serve virtio-blk on IMAGE (slot 1) and virtio-rng\n"
    "                                         (slot 3) through the virtio window and the host DMA port (a bitstream\n"
    "                                         built with TG_VIRTIO_WINDOW=1 TG_HOST_DMA=1, a device tree with VIRTIO=1)\n"
    "      [--net TAP [--net-bridge BR] [--net-mac MAC]]\n"
    "                                         and virtio-net (slot 2) on the TAP device TAP, made and brought up if\n"
    "                                         missing and added to the bridge BR (MAC default 02:74:6e:67:72:01)\n"
    "  inj [--inj-rd N] [--inj-wr N] [--inj-mode M] [--inj-bw R] [--stats]\n"
    "  tg start [LINES] | stop | status       traffic generators (bring-up bitstreams); start sets the\n"
    "                                         DRAM window from --base/--size, as load does\n"
    "  dbg                                    the board debug counters (a bitstream built with TG_DEBUG_CNT=1)\n"
    "  vq                                     the virtio window's state (a bitstream built with TG_VIRTIO_WINDOW=1)\n"
    "  dma status | read OFF [N] | write OFF VAL | check [OFF [BYTES]]\n"
    "                                         the coherent host DMA port (TG_HOST_DMA=1; --dma PA, default\n"
    "                                         0x500000000): offsets into the RISC-V's RAM; check writes and\n"
    "                                         reads back BYTES (64 KiB) at OFF (the RAM's last 64 KiB), which\n"
    "                                         it overwrites: hold the cores (load, or tg start) first\n"
  "  peek OFF | poke OFF VAL                raw register access\n", prog);
  exit(2);
}

static uint64_t num(const char *s) {
  char *e;
  errno = 0;
  uint64_t v = strtoull(s, &e, 0);
  if (errno || *e) die("bad number '%s'", s);
  return v;
}

/* ---- Commands ---- */
/* The board debug counters (tg_uncore DEBUG_CNT): each L2 bank's coherence messages, misses, AXI reads and
 * fills, each core's data-cache messages, the L2 error events, then the channels' valid/ready levels. The
 * index crosses into the core clock and the value back, so each read waits a millisecond. */
static void cmd_dbg(void) {
  static const char *bk[] = { "A in", "B out (probes)", "C in", "D out", "E in (GrantAck)", "misses", "AXI reads", "fills" };
  static const char *ck[] = { "A out", "B in (probes)", "C out", "D in", "E out (GrantAck)" };
  unsigned ncores = (rd(R_VERSION) >> 12) & 0xf, nbanks = (rd(R_CAPS) >> 4) & 0xf;
  wr(R_DBG_SEL, 5);
  if (rd(R_DBG_SEL) != 5) die("dbg: this bitstream has no debug counters (build with TG_DEBUG_CNT=1)");
  unsigned n = 8 * nbanks + 5 * ncores + 1;
  for (unsigned i = 0; i <= n; i++) {
    wr(R_DBG_SEL, i);
    sleep_us(1000);
    uint32_t v = rd(R_DBG_VAL);
    if (i < 8 * nbanks)       printf("  L2 bank %u %-18s %10u\n", i / 8, bk[i % 8], v);
    else if (i < n - 1)       printf("  core %u l1d %-16s %10u\n", (i - 8 * nbanks) / 5, ck[(i - 8 * nbanks) % 5], v);
    else if (i == n - 1)      printf("  L2 error events          %10u\n", v);
    else {
      printf("  levels 0x%08x:", v);
      static const char *lv[] = { "e_r", "e_v", "d_r", "d_v", "c_r", "c_v", "b_r", "b_v", "a_r", "a_v" };
      for (unsigned b = 0; b < nbanks && b < 2; b++) {
        printf(" bank%u[", b);
        for (int k = 9; k >= 0; k--) if (v >> (10 * b + k) & 1) printf(" %s", lv[k]);
        printf(" ]");
      }
      static const char *st[] = { "E", "D", "C", "B", "A" };
      for (unsigned c = 0; c < ncores && c < 2; c++) {
        printf(" core%u stalled[", c);
        for (int k = 4; k >= 0; k--) if (v >> (20 + 5 * c + k) & 1) printf(" %s", st[k]);
        printf(" ]");
      }
      printf("%s\n", v >> 30 & 1 ? " L2_ERR" : "");
    }
  }
  /* The cores' board-debug words (tg_core dbg_o, DR-150), index 128 + 32c + w: word 0 the status, words 1-15
   * the first dispatch groups after reset, 16-31 the first commit cycles that retire. 0xDEB00000: none.
   * A bitstream without them has a 6-bit DBG_SEL, which would wrap 128 + 32c + w onto the counters: it
   * reads back 0 for 128. */
  wr(R_DBG_SEL, 128);
  if (rd(R_DBG_SEL) != 128) { printf("  (no core debug words in this bitstream)\n"); return; }
  for (unsigned c = 0; c < ncores; c++) {
    uint32_t w[32];
    for (unsigned k = 0; k < 32; k++) { wr(R_DBG_SEL, 128 + 32 * c + k); sleep_us(1000); w[k] = rd(R_DBG_VAL); }
    if (w[0] == 0xDEB00000u) { if (c == 0) printf("  (no core debug words in this bitstream)\n"); break; }
    uint32_t s = w[0];
    static const char *am[] = { "IDLE", "REQ", "RES", "DONE" };
    printf("  core %u status 0x%08x: rename v%u ser%u empty%u blk%u res%u fire%u dsbusy%u rdy%u; rob %u; atomic %s%s;"
           " sq head v%u addr%u data%u dreg%u nonempty%u; d$ probe %u mshr %u ready%u; trace stall%u flush%u\n",
           c, s, s & 1, s >> 1 & 1, s >> 2 & 1, s >> 3 & 1, s >> 4 & 1, s >> 5 & 1, s >> 6 & 1, s >> 7 & 1,
           s >> 8 & 0x3f, am[s >> 14 & 3], s >> 16 & 1 ? " (in window)" : "", s >> 17 & 1, s >> 18 & 1, s >> 19 & 1,
           s >> 20 & 1, s >> 21 & 1, s >> 22 & 7, s >> 25 & 15, s >> 29 & 1, s >> 30 & 1, s >> 31 & 1);
    for (unsigned k = 1; k < 32; k++) {
      if (!w[k]) continue;
      printf("  core %u %s %2u:", c, k < 16 ? "dispatch" : "commit  ", k < 16 ? k : k - 16);
      for (unsigned sl = 0; sl < 2; sl++) {
        uint32_t e = w[k] >> (16 * sl) & 0x7fff;          /* {writes rd, fp, rd[4:0], preg[7:0]} */
        if (e >> 14 & 1) printf("  slot%u %c%-2u -> p%-3u", sl, e >> 13 & 1 ? 'f' : 'x', e >> 8 & 31, e & 0xff);
        else             printf("  slot%u -           ", sl);
      }
      printf("\n");
    }
  }
}

/* The forwarded virtio window (CAPS[2]): whether the host serves it, its queues, the slots' status bits,
 * and the oldest request, which stays queued (reading VQ_REQ1 would pop it) */
static void print_vq(void) {
  uint32_t vs = rd(R_VQ_STATUS), h = rd(R_VQ_REQ0);
  printf("  virtio window   %s; %u request(s) and %u event(s) queued%s; status bits 0x%02x\n",
         rd(R_VQ_CTRL) & 1 ? "served" : "not served (reads 0)", vs & 0x1f, (vs >> 8) & 0x1f,
         vs >> 16 & 1 ? ", a RISC-V read waits" : "", vs >> 24);
  if (h >> 31)
    printf("  oldest request  slot %u offset 0x%03x: %s of %u byte(s)\n", (h >> 12) & 3, h & 0xfff,
           h >> 18 & 1 ? "write" : "read", 1u << ((h >> 16) & 3));
}

static void cmd_vq(void) {
  if (!(rd(R_CAPS) & CAPS_VIRTIO)) die("vq: this bitstream has no virtio window (build with TG_VIRTIO_WINDOW=1)");
  print_vq();
}

/* The coherent host DMA port (CAPS[8]): the A53 reads and writes the RISC-V's RAM through HPM1, coherent
 * with the L2. The mapping is uncached (O_SYNC: Device-nGnRnE), so each access is one AXI beat and a store's
 * write response comes from the PL after the L2's AccessAck. Nothing touches HPM1 unless CAPS[8] says the
 * port is there. */
static volatile uint64_t *dma_map(const struct opts *o, uint64_t off, uint64_t len) {
  if (!(rd(R_CAPS) & CAPS_HDMA)) die("dma: this bitstream has no host DMA port (build with TG_HOST_DMA=1)");
  uint64_t ram = rd64(R_DRAM_SIZE);
  if ((off | len) & 7) die("dma: offsets and lengths are multiples of 8");
  if (off + len > ram) die("dma: 0x%" PRIx64 " + 0x%" PRIx64 " is beyond the RISC-V's RAM (DRAM_SIZE 0x%" PRIx64 ")",
                           off, len, ram);
  return map_phys(o->dma_pa + off, (size_t)len);
}

/* The DMA port goes through the L2, so its accesses need the uncore out of reset with the L2 ready. After
 * a load both are held: release the uncore, the cores stay held (a running system is left alone). */
static void uncore_up(void) {
  uint32_t st = rd(R_STATUS);
  if (!(st & ST_UNC_RST) && (st & ST_L2_INIT)) return;
  wr(R_CTRL, CTRL_CORE_RST);
  for (int i = 0; !(rd(R_STATUS) & ST_L2_INIT); i++) {
    if (i > 10000) die("L2 never finished its initialisation");
    sleep_us(100);
  }
  fprintf(stderr, "released the uncore (the cores stay held)\n");
}

static void cmd_dma(const struct opts *o, int argc, char **argv) {
  if (argc < 1) usage();
  if (!(rd(R_CAPS) & CAPS_HDMA)) die("dma: this bitstream has no host DMA port (build with TG_HOST_DMA=1)");
  if (strcmp(argv[0], "status")) uncore_up();
  if (!strcmp(argv[0], "status")) {
    printf("host DMA port: completions %s, %u waiting; %u lines read, %u written; %u write bursts dropped in part\n",
           rd(R_HDMA_CTRL) & 1 ? "recorded" : "not recorded", rd(R_HDMA_STATUS) & 0x1f, rd(R_HDMA_RD_LINES),
           rd(R_HDMA_WR_LINES), rd(R_HDMA_WR_DROPS));
  } else if (!strcmp(argv[0], "read") && argc >= 2) {
    uint64_t off = num(argv[1]), n = argc > 2 ? num(argv[2]) : 1;
    volatile uint64_t *p = dma_map(o, off, 8 * n);
    for (uint64_t i = 0; i < n; i++) printf("0x%09" PRIx64 ": 0x%016" PRIx64 "\n", off + 8 * i, p[i]);
  } else if (!strcmp(argv[0], "write") && argc >= 3) {
    volatile uint64_t *p = dma_map(o, num(argv[1]), 8);
    p[0] = num(argv[2]);
    __asm__ volatile("dsb sy" ::: "memory");
  } else if (!strcmp(argv[0], "check")) {
    uint64_t ram = rd64(R_DRAM_SIZE);
    uint64_t len = argc > 2 ? num(argv[2]) : 0x10000, off = argc > 1 ? num(argv[1]) : ram - len;
    uint32_t st = rd(R_STATUS);
    if (!(st & ST_CORES_RST)) fprintf(stderr, "dma check: the cores are running; 0x%" PRIx64 "+0x%" PRIx64 " gets overwritten\n", off, len);
    volatile uint64_t *p = dma_map(o, off, len);
    uint64_t n = len / 8, bad = 0, drops0 = rd(R_HDMA_WR_DROPS);
    uint32_t rd0 = rd(R_HDMA_RD_LINES), wr0 = rd(R_HDMA_WR_LINES);
    double t0 = now_s();
    for (uint64_t i = 0; i < n; i++) p[i] = (off + 8 * i) * 0x9E3779B97F4A7C15ull;
    __asm__ volatile("dsb sy" ::: "memory");
    double t1 = now_s();
    for (uint64_t i = 0; i < n; i++)
      if (p[i] != (off + 8 * i) * 0x9E3779B97F4A7C15ull && bad++ < 4)
        fprintf(stderr, "dma check: 0x%" PRIx64 " reads 0x%016" PRIx64 "\n", off + 8 * i, p[i]);
    double t2 = now_s();
    /* narrow stores: every other 32-bit half, then the whole words again */
    volatile uint32_t *q = (volatile uint32_t *)p;
    for (uint64_t i = 0; i < 2 * n; i += 2) q[i] = (uint32_t)i;
    __asm__ volatile("dsb sy" ::: "memory");
    for (uint64_t i = 0; i < n; i++) {
      uint64_t want = (((off + 8 * i) * 0x9E3779B97F4A7C15ull) & ~0xffffffffull) | (uint32_t)(2 * i);
      if (p[i] != want && bad++ < 8) fprintf(stderr, "dma check: 0x%" PRIx64 " reads 0x%016" PRIx64 " after a 32-bit store\n", off + 8 * i, p[i]);
    }
    uint32_t drops = rd(R_HDMA_WR_DROPS) - (uint32_t)drops0;
    printf("dma check 0x%" PRIx64 "+0x%" PRIx64 ": %s; writes %.1f MB/s, reads %.1f MB/s; %u lines read, %u written, %u drops\n",
           off, len, bad || drops ? "FAIL" : "ok", len / (t1 - t0) / 1e6, len / (t2 - t1) / 1e6,
           rd(R_HDMA_RD_LINES) - rd0, rd(R_HDMA_WR_LINES) - wr0, drops);
    if (bad || drops) exit(1);
  } else usage();
}

static void check_id(void) {
  uint32_t id = rd(R_ID);
  if (id != TG_ID) die("no Tanager host bridge at the register window (ID 0x%08x); is the bitstream loaded?", id);
}

static void cmd_info(void) {
  uint32_t ver = rd(R_VERSION), st = rd(R_STATUS);
  static const char *cfgs[] = { "st", "smt2", "st_w3", "smt2_w3" };
  printf("Tanager host bridge v%u.%u\n", ver >> 24, (ver >> 16) & 0xff);
  printf("  configuration   %s, %u core(s) x %u thread(s)\n", cfgs[ver & 3], (ver >> 12) & 0xf, (ver >> 8) & 0xf);
  printf("  core clock      %.1f MHz\n", rd(R_CLK_HZ) / 1e6);
  printf("  capabilities    0x%08x%s%s\n", rd(R_CAPS),
         rd(R_CAPS) & CAPS_TRACE ? "" : " (no commit-trace stream: built with TG_COMMIT_TRACE=0)",
         rd(R_CAPS) & CAPS_VIRTIO ? " (virtio window)" : "");
  printf("  status          cores %s, uncore %s, L2 %s%s\n",
         st & ST_CORES_RST ? "in reset" : "running", st & ST_UNC_RST ? "in reset" : "running",
         st & ST_L2_INIT ? "ready" : "not ready", st & ST_POWER_REQ ? ", power request pending" : "");
  printf("  window          base 0x%" PRIx64 " size 0x%" PRIx64 "\n", rd64(R_DRAM_BASE), rd64(R_DRAM_SIZE));
  printf("  boot            entry 0x%" PRIx64 " dtb 0x%" PRIx64 "\n", rd64(R_BOOT_ENTRY), rd64(R_DTB_ADDR));
  printf("  injector        rd %u wr %u ctrl 0x%08x; %u reads, native latency avg %.1f max %u cycles\n",
         rd(R_INJ_RD), rd(R_INJ_WR), rd(R_INJ_CTRL), rd(R_INJ_CNT),
         rd(R_INJ_CNT) ? (double)rd(R_INJ_SUM) / rd(R_INJ_CNT) : 0.0, rd(R_INJ_MAX));
  printf("  tohost          0x%016" PRIx64 " (%u writes)\n", rd64(R_TOHOST), rd(R_TOHOST_SEQ));
  if (rd(R_CAPS) & CAPS_VIRTIO) print_vq();
}

static void cmd_reset(void) {
  wr(R_CTRL, CTRL_CORE_RST | CTRL_UNC_RST);
  for (int i = 0; i < 1000 && (rd(R_STATUS) & (ST_CORES_RST | ST_UNC_RST)) != (ST_CORES_RST | ST_UNC_RST); i++)
    sleep_us(100);
}

static size_t load_file(const char *path, uint8_t *dst, uint64_t room) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) die("open %s: %s", path, strerror(errno));
  struct stat sb;
  if (fstat(fd, &sb) < 0) die("stat %s: %s", path, strerror(errno));
  if ((uint64_t)sb.st_size > room) die("%s (%lld bytes) does not fit its slot (%" PRIu64 " bytes)", path, (long long)sb.st_size, room);
  /* Read through a buffer and store 8 bytes at a time: the mapping is uncached (O_SYNC). */
  static uint8_t buf[1 << 20];
  size_t done = 0;
  for (;;) {
    ssize_t n = read(fd, buf, sizeof buf);
    if (n < 0) die("read %s: %s", path, strerror(errno));
    if (n == 0) break;
    size_t k = 0;
    for (; k + 8 <= (size_t)n; k += 8) {
      uint64_t v;
      memcpy(&v, buf + k, 8);
      *(volatile uint64_t *)(dst + done + k) = v;
    }
    for (; k < (size_t)n; k++) *(volatile uint8_t *)(dst + done + k) = buf[k];
    done += (size_t)n;
  }
  close(fd);
  return done;
}

static void cmd_load(const struct opts *o) {
  if (!o->fw || !o->kernel || !o->dtb) die("load needs --fw, --kernel and --dtb");
  if (dram_bytes(o) < OFF_DTB + 0x10000 || trace_bytes(o) >= o->size) die("carve-out too small");
  cmd_reset();
  wr64(R_DRAM_BASE, o->base);
  wr64(R_DRAM_SIZE, dram_bytes(o));
  /* the virtio window: served (EN) only by a run with back-ends; set while the uncore is held */
  if (rd(R_CAPS) & CAPS_VIRTIO) wr(R_VQ_CTRL, (o->blk || o->rng || o->net) ? 1 : 0);
  /* A lockstep checker's memory starts at zero, but the DDR outside the images holds old data, and
   * Linux can copy uninitialised bytes into registers (padding in a memcpy): with --trace, or
   * --zero, the window (not the trace ring above it) is zeroed first. 8-byte stores: the mapping
   * is uncached device memory, which takes no DC ZVA. */
  int zero = o->zero || o->trace;
  uint8_t *mem = map_phys(o->base, zero ? dram_bytes(o) : OFF_DTB + 0x10000);
  if (zero) {
    double t0 = now_s();
    volatile uint64_t *z = (volatile uint64_t *)mem;
    for (uint64_t i = 0; i < dram_bytes(o) / 8; i++) z[i] = 0;
    fprintf(stderr, "zeroed the RISC-V window: %" PRIu64 " MiB in %.1f s\n", dram_bytes(o) >> 20, now_s() - t0);
  }
  size_t n1 = load_file(o->fw, mem + OFF_FW, OFF_KERNEL - OFF_FW);
  size_t n2 = load_file(o->kernel, mem + OFF_KERNEL, OFF_DTB - OFF_KERNEL);
  size_t n3 = load_file(o->dtb, mem + OFF_DTB, 0x10000);
  /* read back a few words of each image */
  if (verbose) fprintf(stderr, "loaded fw %zu, kernel %zu, dtb %zu bytes\n", n1, n2, n3);
  wr64(R_BOOT_ENTRY, DRAM_BASE_RV + OFF_FW);
  wr64(R_DTB_ADDR, DRAM_BASE_RV + OFF_DTB);
  /* stderr: with --trace -, stdout carries only trace records */
  fprintf(stderr, "loaded: fw %zu B, kernel %zu B, dtb %zu B into 0x%" PRIx64 " (RISC-V 0x%llx)\n", n1, n2, n3,
          o->base, (unsigned long long)DRAM_BASE_RV);
}

static void set_inj(const struct opts *o) {
  if (o->inj_rd >= 0) wr(R_INJ_RD, (uint32_t)o->inj_rd);
  if (o->inj_wr >= 0) wr(R_INJ_WR, (uint32_t)o->inj_wr);
  if (o->inj_mode >= 0 || o->inj_bw >= 0) {
    uint32_t c = rd(R_INJ_CTRL);
    if (o->inj_mode >= 0) c = (c & ~1u) | (uint32_t)(o->inj_mode & 1);
    if (o->inj_bw >= 0) c = (c & ~(0x1ffu << 16)) | ((uint32_t)(o->inj_bw & 0x1ff) << 16);
    wr(R_INJ_CTRL, c);
  }
}

/* ---- Commit trace (docs/spec/uncore-trace.md) ---- */
static uint8_t *trace_ring;
static FILE *trace_out;
static uint64_t trace_rp;
static int      trace_broken;           /* a trace write failed: the consumer has gone (run exits 4) */

/* A bitstream built without the commit trace (TG_COMMIT_TRACE=0, DR-146) has no trace stream and reads
 * CAPS[3] = 0: --trace stops at once, before anything is loaded or released, instead of waiting on a
 * ring that never fills. */
static int trace_built(void) { return (rd(R_CAPS) & CAPS_TRACE) != 0; }
static void check_trace(const struct opts *o) {
  if (o->trace && !trace_built())
    die("--trace: this bitstream has no commit-trace stream (CAPS[3] = 0: built with TG_COMMIT_TRACE=0, "
        "DR-146); lockstep needs a bitstream built with the trace");
}

static void trace_status(void) {
  uint32_t st = rd(R_TRS_STATUS), info = rd(R_TRS_INFO);
  printf("trace: ctrl 0x%03x, ring 0x%" PRIx64 " of 2^%u records (%u B each, %u core(s))\n", rd(R_TRS_CTRL),
         rd64(R_TRS_BASE), rd(R_TRS_SIZE), info & 0xff, (info >> 8) & 0xff);
  printf("       written %" PRIu64 ", consumed %" PRIu64 ", in the lanes %u, stalled %u cycles%s%s%s%s%s\n",
         rd64(R_TRS_WP), rd64(R_TRS_RP), st >> 16, rd(R_TRS_STALLS),
         st & TRS_ST_CAPTURING ? ", capturing" : "", st & TRS_ST_STARTED ? ", started" : "",
         st & TRS_ST_STOPPED ? ", stopped by the trigger" : "", st & TRS_ST_FULL ? ", waiting for the reader" : "",
         st & TRS_ST_AXI_ERR ? ", AXI ERROR" : "");
}

/* Copies records [from, to) of the ring (record n at index n mod 2^log2) to the output. */
static void trace_copy(const struct opts *o, uint64_t from, uint64_t to) {
  uint64_t mask = ((uint64_t)1 << o->trace_log2) - 1;
  uint64_t rec[TRS_REC_BYTES / 8];
  for (uint64_t n = from; n < to; n++) {
    volatile uint64_t *src = (volatile uint64_t *)(trace_ring + (n & mask) * TRS_REC_BYTES);
    for (unsigned k = 0; k < TRS_REC_BYTES / 8; k++) rec[k] = src[k];   /* uncached: 8-byte loads */
    if (trace_broken) return;
    if (fwrite(rec, TRS_REC_BYTES, 1, trace_out) != 1) {
      fprintf(stderr, "\r\n[%s] trace write: %s\r\n", prog, strerror(errno));
      trace_broken = 1;
      return;
    }
  }
}

/* Before the cores start: program the ring and the triggers, enable, wait for the core domain. */
static void trace_begin(const struct opts *o) {
  uint64_t pa = o->base + dram_bytes(o);
  trace_ring = map_phys(pa, trace_bytes(o));
  trace_out = strcmp(o->trace, "-") ? fopen(o->trace, "wb") : stdout;
  if (!trace_out) die("open %s: %s", o->trace, strerror(errno));
  wr(R_TRS_CTRL, 0);
  wr64(R_TRS_BASE, pa);
  wr(R_TRS_SIZE, (uint32_t)o->trace_log2);
  wr64(R_TRS_RP, 0);
  if (o->trace_stop)  { wr64(R_TRS_TRIG_PC, o->trace_stop_pc); wr(R_TRS_POST, o->trace_post); }
  if (o->trace_start) wr64(R_TRS_START_PC, o->trace_start_pc);
  wr(R_TRS_CTRL, TRS_EN | (o->trace_wrap ? TRS_WRAP : 0) | (o->trace_stop ? TRS_STOP_ARM : 0) |
                 (o->trace_start ? TRS_START_ARM : 0));
  for (int i = 0; !(rd(R_TRS_STATUS) & TRS_ST_CAPTURING) && !o->trace_start; i++) {
    if (i > 10000) die("the trace stream did not start");
    sleep_us(10);
  }
  trace_rp = 0;
  if (verbose) fprintf(stderr, "trace ring at 0x%" PRIx64 ", 2^%d records\n", pa, o->trace_log2);
}

/* While running (no wrap): hand what has been written to the output and free it, at most 4,096
 * records per call, so the console, POWER and TOHOST stay serviced while the consumer lags. */
#define TRACE_POLL_MAX 4096u
static int trace_poll(const struct opts *o) {
  if (o->trace_wrap || trace_broken) return 0;
  uint64_t wp = rd64(R_TRS_WP);
  if (wp == trace_rp) return 0;
  if (wp - trace_rp > TRACE_POLL_MAX) wp = trace_rp + TRACE_POLL_MAX;
  trace_copy(o, trace_rp, wp);
  if (trace_broken) return 0;
  trace_rp = wp;
  wr64(R_TRS_RP, trace_rp);
  return 1;
}

/* At exit: stop taking records, let the lanes drain, collect the rest (or the ring's tail). */
static void trace_end(const struct opts *o) {
  uint32_t c = rd(R_TRS_CTRL);
  wr(R_TRS_CTRL, c & ~TRS_EN);
  uint64_t wp = rd64(R_TRS_WP);
  for (int i = 0; i < 1000; i++) {
    if (o->trace_wrap) wr64(R_TRS_RP, rd64(R_TRS_WP));
    else trace_poll(o);
    sleep_us(100);
    uint64_t w2 = rd64(R_TRS_WP);
    if (w2 == wp && (rd(R_TRS_STATUS) >> 16) == 0) break;
    wp = w2;
  }
  if (o->trace_wrap) {
    uint64_t n = (uint64_t)1 << o->trace_log2;
    trace_copy(o, wp > n ? wp - n : 0, wp);
  } else {
    while (trace_poll(o)) { }
  }
  if (!trace_broken) fflush(trace_out);
  if (trace_out != stdout) fclose(trace_out);
  fprintf(stderr, "[%s] trace: %" PRIu64 " records written%s\n", prog, wp,
          rd(R_TRS_STATUS) & TRS_ST_AXI_ERR ? " (AXI ERROR)" : "");
}

static struct termios saved_tio;
static int tio_saved;
static void restore_tty(void) { if (tio_saved) tcsetattr(0, TCSANOW, &saved_tio); }
static volatile sig_atomic_t stop_req;
static void on_sig(int s) { (void)s; stop_req = 1; }

/* Copy what the RISC-V's UART has sent to out_fd (if any); returns the number of bytes. */
static int console_out(int out_fd) {
  int n = 0;
  for (; n < 256; n++) {
    uint32_t v = rd(R_UART_TX);
    if (!(v & 0x100)) break;
    if (out_fd >= 0) {
      char c = (char)(v & 0xff);
      if (write(out_fd, &c, 1) < 0 && errno != EAGAIN) die("console write: %s", strerror(errno));
    }
  }
  return n;
}

/* The virtio back-ends' hooks (virtio.h): the host bridge's registers, and the RISC-V's RAM through
 * the host DMA port's uncached mapping, with aligned accesses only */
static volatile uint8_t *vio_ram;
static uint64_t h_ram_rd64(uint64_t off)             { return *(volatile uint64_t *)(vio_ram + off); }
static void     h_ram_wr64(uint64_t off, uint64_t v) { *(volatile uint64_t *)(vio_ram + off) = v; }
static void     h_ram_wr32(uint64_t off, uint32_t v) { *(volatile uint32_t *)(vio_ram + off) = v; }
static void     h_ram_wr8(uint64_t off, uint8_t v)   { vio_ram[off] = v; }
static void     h_barrier(void)                      { __asm__ volatile("dsb sy" ::: "memory"); }

/* --blk/--rng/--net need the window (CAPS[2]) and the DMA port (CAPS[8]) */
static void check_virtio(const struct opts *o) {
  if (!o->blk && !o->rng && !o->net) return;
  uint32_t caps = rd(R_CAPS);
  if (!(caps & CAPS_VIRTIO) || !(caps & CAPS_HDMA))
    die("--blk/--rng/--net: this bitstream lacks the virtio window or the host DMA port (CAPS 0x%x; build with "
        "TG_VIRTIO_WINDOW=1 TG_HOST_DMA=1)", caps);
}

/* The TAP device for --net (made if missing; it goes when the run ends unless it was made persistent),
 * brought up, and added to --net-bridge's bridge if given. Returns a non-blocking descriptor. */
static int tap_open(const char *name, const char *bridge) {
  int fd = open("/dev/net/tun", O_RDWR | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) die("--net: /dev/net/tun: %s", strerror(errno));
  struct ifreq ifr;
  memset(&ifr, 0, sizeof ifr);
  ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
  snprintf(ifr.ifr_name, IFNAMSIZ, "%s", name);
  if (ioctl(fd, TUNSETIFF, &ifr)) die("--net %s: %s", name, strerror(errno));
  int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (s < 0) die("--net: socket: %s", strerror(errno));
  if (bridge) {
    struct ifreq br;
    memset(&br, 0, sizeof br);
    snprintf(br.ifr_name, IFNAMSIZ, "%s", bridge);
    br.ifr_ifindex = (int)if_nametoindex(ifr.ifr_name);
    if (ioctl(s, SIOCBRADDIF, &br) && errno != EBUSY)   /* EBUSY: already a port of it */
      die("--net-bridge %s: adding %s: %s", bridge, ifr.ifr_name, strerror(errno));
  }
  if (ioctl(s, SIOCGIFFLAGS, &ifr)) die("--net %s: %s", ifr.ifr_name, strerror(errno));
  ifr.ifr_flags |= IFF_UP;
  if (ioctl(s, SIOCSIFFLAGS, &ifr)) die("--net %s: bringing it up: %s", ifr.ifr_name, strerror(errno));
  close(s);
  return fd;
}

static int cmd_run(const struct opts *o) {
  check_id();
  set_inj(o);
  uint32_t ctrl = o->lossless ? CTRL_LOSSLESS : 0;
  /* uncore first, wait for the L2, then the cores (docs/spec/host.md, loading sequence). A system that
   * already runs (tg start) keeps running: holding the cores alone would cut their TileLink
   * transactions short and leave the L2 waiting for a GrantAck or the rest of a burst. */
  int running = !(rd(R_STATUS) & (ST_CORES_RST | ST_UNC_RST));
  wr(R_CTRL, ctrl | (running ? 0 : CTRL_CORE_RST));
  for (int i = 0; !(rd(R_STATUS) & ST_L2_INIT); i++) {
    if (i > 10000) die("L2 never finished its initialisation");
    sleep_us(100);
  }
  uint32_t seq0 = rd(R_TOHOST_SEQ);
  wr(R_POWER, 0x80000000u);                 /* clear a stale power request */

  int in_fd = -1, out_fd = -1;
  if (o->console == 1) {
    int m = posix_openpt(O_RDWR | O_NOCTTY);
    if (m < 0 || grantpt(m) || unlockpt(m)) die("pty: %s", strerror(errno));
    fprintf(stderr, "console on %s\n", ptsname(m));   /* stderr: stdout may carry trace records */
    in_fd = out_fd = m;
  } else if (o->console == 0) {
    in_fd = 0;
    out_fd = (o->trace && !strcmp(o->trace, "-")) ? 2 : 1;   /* --trace -: records alone on stdout */
    if (isatty(0) && tcgetattr(0, &saved_tio) == 0) {
      struct termios t = saved_tio;
      cfmakeraw(&t);
      t.c_oflag |= OPOST;
      tcsetattr(0, TCSANOW, &t);
      tio_saved = 1;
      atexit(restore_tty);
    }
  }
  signal(SIGPIPE, SIG_IGN);                 /* a trace consumer that exits ends the run (rc 4) */
  signal(SIGINT, on_sig);
  signal(SIGTERM, on_sig);

  if (o->trace) trace_begin(o);
  int vio = o->blk || o->rng || o->net, net_fd = -1;
  if (vio) {
    uint64_t ram = rd64(R_DRAM_SIZE);
    if (!(rd(R_VQ_CTRL) & 1)) die("--blk/--rng/--net: the window is not enabled; load with the same options first");
    vio_ram = (volatile uint8_t *)dma_map(o, 0, ram);
    if (o->net) net_fd = tap_open(o->net, o->net_bridge);
    struct vio_hooks hk = { rd, wr, h_ram_rd64, h_ram_wr64, h_ram_wr32, h_ram_wr8, h_barrier, ram };
    if (vio_open(&hk, o->blk, o->blk_ro, o->rng, net_fd, o->net_mac)) die("virtio back-ends failed to open");
    fprintf(stderr, "virtio:%s%s%s", o->blk ? " blk " : "", o->blk ? o->blk : "", o->rng ? " rng" : "");
    if (o->net)
      fprintf(stderr, " net %s%s%s %02x:%02x:%02x:%02x:%02x:%02x", o->net, o->net_bridge ? " in " : "",
              o->net_bridge ? o->net_bridge : "", o->net_mac[0], o->net_mac[1], o->net_mac[2], o->net_mac[3],
              o->net_mac[4], o->net_mac[5]);
    fputc('\n', stderr);
  } else if ((rd(R_CAPS) & CAPS_VIRTIO) && (rd(R_VQ_CTRL) & 1)) {
    fprintf(stderr, "warning: the virtio window is enabled but this run serves nothing; its reads will wait\n");
  }
  wr(R_CTRL, ctrl);                         /* release the cores */
  double t_end = o->timeout > 0 ? now_s() + o->timeout : 0;
  int rc = 0, ctrl_a = 0;
  char why[96] = "";                        /* the exit reason, printed after the console drains */
  for (;;) {
    int idle = 1;
    if (console_out(out_fd)) idle = 0;
    /* console in (stdio: ctrl-a x quits) */
    if (in_fd >= 0) {
      struct pollfd p = { in_fd, POLLIN, 0 };
      if (poll(&p, 1, 0) > 0 && (p.revents & POLLIN)) {
        char c;
        if (read(in_fd, &c, 1) == 1) {
          if (o->console == 0 && ctrl_a && c == 'x') { stop_req = 1; }
          else if (o->console == 0 && c == 1) { ctrl_a = 1; }
          else {
            ctrl_a = 0;
            while (rd(R_UART_RX_SPACE) == 0) sleep_us(50);
            wr(R_UART_RX, (uint8_t)c);
          }
        }
        idle = 0;
      }
    }
    /* power and tohost */
    uint32_t pw = rd(R_POWER);
    if (pw & 0x80000000u) {
      uint32_t v = pw & 0xffff;
      wr(R_POWER, 0x80000000u);
      if (v == POWER_OFF)         { snprintf(why, sizeof why, "RISC-V requested power-off"); rc = 0; break; }
      if (v == POWER_REBOOT)      { snprintf(why, sizeof why, "RISC-V requested reboot"); rc = 3; break; }
      if ((v & 0xffff) == POWER_FAIL) { snprintf(why, sizeof why, "RISC-V reported failure"); rc = 1; break; }
    }
    if (rd(R_TOHOST_SEQ) != seq0) {
      uint64_t th = rd64(R_TOHOST);
      if (th & 1) {                         /* riscv-tests convention: 1 = pass, else (code << 1) | 1 */
        snprintf(why, sizeof why, "tohost 0x%" PRIx64 ": %s", th, th == 1 ? "PASS" : "FAIL");
        rc = th == 1 ? 0 : 1;
        break;
      }
      seq0 = rd(R_TOHOST_SEQ);
    }
    if (o->trace && trace_poll(o)) idle = 0;
    if (vio && vio_poll()) idle = 0;
    if (trace_broken) { snprintf(why, sizeof why, "trace consumer stopped"); rc = 4; break; }
    if (stop_req) { rc = 130; break; }
    if (t_end && now_s() > t_end) { snprintf(why, sizeof why, "timeout"); rc = 124; break; }
    if (idle) sleep_us(200);
  }
  /* Drain the console before holding everything: the RISC-V's last line is often still in its UART
   * (the board's first light lost "S\n" of "PASS"), and on the PMOD line each byte takes 87 us at
   * 115200. Done once the UART has been quiet for 20 ms, or after 500 ms for a talkative program. */
  for (double t0 = now_s(), quiet = now_s(); now_s() - quiet < 0.02 && now_s() - t0 < 0.5; ) {
    if (console_out(out_fd)) quiet = now_s();
    else sleep_us(1000);
  }
  if (why[0]) fprintf(stderr, "\r\n[%s] %s\r\n", prog, why);
  if (o->trace) trace_end(o);
  if (vio) {
    uint64_t n, rb, wb;
    vio_stats(&n, &rb, &wb);
    vio_close();
    fprintf(stderr, "[%s] virtio: %" PRIu64 " requests, %" PRIu64 " MiB read, %" PRIu64 " MiB written\r\n", prog, n,
            rb >> 20, wb >> 20);
    if (net_fd >= 0) {
      uint64_t rx, tx, dr;
      vio_net_stats(&rx, &tx, &dr);
      close(net_fd);
      fprintf(stderr, "[%s] virtio-net: %" PRIu64 " frames received, %" PRIu64 " sent, %" PRIu64 " dropped\r\n", prog,
              rx, tx, dr);
    }
  }
  wr(R_CTRL, CTRL_CORE_RST | CTRL_UNC_RST);
  return rc;
}

static void cmd_tg(const struct opts *o, int argc, char **argv) {
  check_id();
  if (argc < 1) usage();
  if (!strcmp(argv[0], "start")) {
    uint32_t lines = argc > 1 ? (uint32_t)num(argv[1]) : 16384;
    /* The generators reach memory through the DRAM window like the cores do: set it while
     * everything is held, or a size of 0 denies every access. */
    wr(R_CTRL, CTRL_CORE_RST | CTRL_UNC_RST);
    wr64(R_DRAM_BASE, o->base);
    wr64(R_DRAM_SIZE, dram_bytes(o));
    wr(R_CTRL, CTRL_CORE_RST);              /* uncore running, generators held */
    for (int i = 0; !(rd(R_STATUS) & ST_L2_INIT); i++) { if (i > 10000) die("L2 not ready"); sleep_us(100); }
    wr(R_TG_LINES, lines);
    wr(R_TG_CTRL, 1);
    wr(R_CTRL, 0);
    printf("traffic generators running over %u lines each; window 0x%" PRIx64 " + 0x%" PRIx64 "\n",
           lines, o->base, dram_bytes(o));
  } else if (!strcmp(argv[0], "stop")) {
    wr(R_TG_CTRL, 0);
  } else if (!strcmp(argv[0], "status")) {
    printf("passes %u, lines checked %u, errors %u (last at line 0x%07x)\n",
           rd(R_TG_PASS), rd(R_TG_OPS), rd(R_TG_ERRS), rd(R_TG_ERR_LINE));
  } else usage();
}

int main(int argc, char **argv) {
  struct opts o = { .regs_pa = 0xA0000000ull, .base = 0x840000000ull, .size = 0x40000000ull, .dma_pa = 0x500000000ull,
                    .console = 0, .inj_rd = -1, .inj_wr = -1, .inj_mode = -1, .inj_bw = -1,
                    .trace_log2 = 22, .net_mac = { 0x02, 0x74, 0x6e, 0x67, 0x72, 0x01 } };   /* "tngr", local */
  int stats = 0;
  static const struct option lo[] = {
    { "regs", 1, 0, 'R' }, { "base", 1, 0, 'B' }, { "size", 1, 0, 'S' },
    { "fw", 1, 0, 'f' }, { "kernel", 1, 0, 'k' }, { "dtb", 1, 0, 'd' },
    { "pty", 0, 0, 'p' }, { "no-console", 0, 0, 'n' }, { "timeout", 1, 0, 't' }, { "lossless", 0, 0, 'l' },
    { "inj-rd", 1, 0, 1 }, { "inj-wr", 1, 0, 2 }, { "inj-mode", 1, 0, 3 }, { "inj-bw", 1, 0, 4 },
    { "stats", 0, 0, 5 }, { "trace", 1, 0, 6 }, { "trace-log2", 1, 0, 7 }, { "trace-wrap", 0, 0, 8 },
    { "trace-start", 1, 0, 9 }, { "trace-stop", 1, 0, 10 }, { "trace-post", 1, 0, 11 },
    { "force", 0, 0, 12 }, { "zero", 0, 0, 13 }, { "dma", 1, 0, 14 }, { "blk", 1, 0, 15 }, { "blk-ro", 0, 0, 16 },
    { "rng", 0, 0, 17 }, { "net", 1, 0, 18 }, { "net-bridge", 1, 0, 19 }, { "net-mac", 1, 0, 20 },
    { "help", 0, 0, 'h' }, { 0, 0, 0, 0 }
  };
  int c, force = 0;
  /* Options anywhere (getopt_long's argument permutation): `run --timeout 5` as well as
   * `--timeout 5 run`; the command's own arguments keep their order. */
  while ((c = getopt_long(argc, argv, "vh", lo, NULL)) != -1) {
    switch (c) {
      case 'R': o.regs_pa = num(optarg); break;
      case 'B': o.base = num(optarg); break;
      case 'S': o.size = num(optarg); break;
      case 'f': o.fw = optarg; break;
      case 'k': o.kernel = optarg; break;
      case 'd': o.dtb = optarg; break;
      case 'p': o.console = 1; break;
      case 'n': o.console = -1; break;
      case 't': o.timeout = strtod(optarg, NULL); break;
      case 'l': o.lossless = 1; break;
      case 1: o.inj_rd = (long)num(optarg); break;
      case 2: o.inj_wr = (long)num(optarg); break;
      case 3: o.inj_mode = (long)num(optarg); break;
      case 4: o.inj_bw = (long)num(optarg); break;
      case 5: stats = 1; break;
      case 6: o.trace = optarg; break;
      case 7: o.trace_log2 = (int)num(optarg); if (o.trace_log2 < 4 || o.trace_log2 > 26) die("--trace-log2: 4 to 26"); break;
      case 8: o.trace_wrap = 1; break;
      case 9: o.trace_start = 1; o.trace_start_pc = num(optarg); break;
      case 10: o.trace_stop = 1; o.trace_stop_pc = num(optarg); break;
      case 11: o.trace_post = (uint32_t)num(optarg); break;
      case 12: force = 1; break;
      case 13: o.zero = 1; break;
      case 14: o.dma_pa = num(optarg); break;
      case 15: o.blk = optarg; break;
      case 16: o.blk_ro = 1; break;
      case 17: o.rng = 1; break;
      case 18: o.net = optarg; break;
      case 19: o.net_bridge = optarg; break;
      case 20: {
        unsigned m[6];
        if (sscanf(optarg, "%x:%x:%x:%x:%x:%x", &m[0], &m[1], &m[2], &m[3], &m[4], &m[5]) != 6 ||
            (m[0] & 1) || m[0] > 255 || m[1] > 255 || m[2] > 255 || m[3] > 255 || m[4] > 255 || m[5] > 255)
          die("--net-mac: six hex bytes a:b:c:d:e:f, unicast (the first byte even)");
        for (int i = 0; i < 6; i++) o.net_mac[i] = (uint8_t)m[i];
        break;
      }
      case 'v': verbose = 1; break;
      default: usage();
    }
  }
  if (optind >= argc) usage();
  const char *cmd = argv[optind++];
  if (!force) check_overlay(o.regs_pa);
  regs = map_phys(o.regs_pa, 0x10000);

  if (!strcmp(cmd, "info"))       { check_id(); cmd_info(); return 0; }
  if (!strcmp(cmd, "reset"))      { check_id(); cmd_reset(); return 0; }
  if (!strcmp(cmd, "load"))       { check_id(); check_trace(&o); check_virtio(&o); cmd_load(&o); return 0; }
  if (!strcmp(cmd, "run"))        { check_id(); check_trace(&o); check_virtio(&o); return cmd_run(&o); }
  if (!strcmp(cmd, "boot"))       { check_id(); check_trace(&o); check_virtio(&o); cmd_load(&o); return cmd_run(&o); }
  if (!strcmp(cmd, "inj"))        {
    check_id();
    set_inj(&o);
    if (stats || (o.inj_rd < 0 && o.inj_wr < 0 && o.inj_mode < 0 && o.inj_bw < 0))
      printf("injector: rd %u wr %u ctrl 0x%08x; %u reads, native latency avg %.1f max %u cycles\n",
             rd(R_INJ_RD), rd(R_INJ_WR), rd(R_INJ_CTRL), rd(R_INJ_CNT),
             rd(R_INJ_CNT) ? (double)rd(R_INJ_SUM) / rd(R_INJ_CNT) : 0.0, rd(R_INJ_MAX));
    return 0;
  }
  if (!strcmp(cmd, "tg"))         { cmd_tg(&o, argc - optind, argv + optind); return 0; }
  if (!strcmp(cmd, "trace"))      {
    check_id();
    if (optind >= argc || strcmp(argv[optind], "status")) usage();
    if (!trace_built()) {
      printf("trace: no commit-trace stream in this bitstream (CAPS[3] = 0: built with TG_COMMIT_TRACE=0, DR-146)\n");
      return 1;
    }
    trace_status();
    return 0;
  }
  if (!strcmp(cmd, "dbg"))        { check_id(); cmd_dbg(); return 0; }
  if (!strcmp(cmd, "vq"))         { check_id(); cmd_vq(); return 0; }
  if (!strcmp(cmd, "dma"))        { check_id(); cmd_dma(&o, argc - optind, argv + optind); return 0; }
  if (!strcmp(cmd, "peek"))       {
    if (optind >= argc) usage();
    unsigned off = (unsigned)num(argv[optind]);
    printf("0x%08x\n", rd(off));
    return 0;
  }
  if (!strcmp(cmd, "poke"))       {
    if (optind + 1 >= argc) usage();
    wr((unsigned)num(argv[optind]), (uint32_t)num(argv[optind + 1]));
    return 0;
  }
  usage();
  return 2;
}
