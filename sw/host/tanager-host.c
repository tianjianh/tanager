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
#include <sys/mman.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

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
    "  -v               verbose\n"
    "commands:\n"
    "  info                                   identity and status\n"
    "  reset                                  hold cores and uncore in reset\n"
    "  load --fw F --kernel K --dtb D         reset, set the window, copy images (soc.md §3)\n"
    "  run [--pty|--no-console] [--timeout S] [--lossless] [--inj-rd N] [--inj-wr N] [--inj-mode M] [--inj-bw R]\n"
    "      [--trace FILE [--trace-log2 N] [--trace-wrap] [--trace-start PC] [--trace-stop PC [--trace-post N]]]\n"
    "                                         release reset, bridge the console, exit on power-off/tohost;\n"
    "                                         --trace writes every commit record (64 B each) to FILE, stalling\n"
    "                                         the cores while it falls behind (with --trace-wrap: the last\n"
    "                                         2^N records, at exit). The ring takes the top 64 B << N of the\n"
    "                                         carve-out (default N 22: 256 MiB); the device tree's memory must\n"
    "                                         fit in the rest\n"
    "  trace status                           commit-trace stream state\n"
    "  boot ...                               load, then run\n"
    "  inj [--inj-rd N] [--inj-wr N] [--inj-mode M] [--inj-bw R] [--stats]\n"
    "  tg start [LINES] | stop | status       traffic generators (bring-up bitstreams); start sets the\n"
    "                                         DRAM window from --base/--size, as load does\n"
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
  printf("  capabilities    0x%08x\n", rd(R_CAPS));
  printf("  status          cores %s, uncore %s, L2 %s%s\n",
         st & ST_CORES_RST ? "in reset" : "running", st & ST_UNC_RST ? "in reset" : "running",
         st & ST_L2_INIT ? "ready" : "not ready", st & ST_POWER_REQ ? ", power request pending" : "");
  printf("  window          base 0x%" PRIx64 " size 0x%" PRIx64 "\n", rd64(R_DRAM_BASE), rd64(R_DRAM_SIZE));
  printf("  boot            entry 0x%" PRIx64 " dtb 0x%" PRIx64 "\n", rd64(R_BOOT_ENTRY), rd64(R_DTB_ADDR));
  printf("  injector        rd %u wr %u ctrl 0x%08x; %u reads, native latency avg %.1f max %u cycles\n",
         rd(R_INJ_RD), rd(R_INJ_WR), rd(R_INJ_CTRL), rd(R_INJ_CNT),
         rd(R_INJ_CNT) ? (double)rd(R_INJ_SUM) / rd(R_INJ_CNT) : 0.0, rd(R_INJ_MAX));
  printf("  tohost          0x%016" PRIx64 " (%u writes)\n", rd64(R_TOHOST), rd(R_TOHOST_SEQ));
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
  uint8_t *mem = map_phys(o->base, OFF_DTB + 0x10000);
  size_t n1 = load_file(o->fw, mem + OFF_FW, OFF_KERNEL - OFF_FW);
  size_t n2 = load_file(o->kernel, mem + OFF_KERNEL, OFF_DTB - OFF_KERNEL);
  size_t n3 = load_file(o->dtb, mem + OFF_DTB, 0x10000);
  /* read back a few words of each image */
  if (verbose) fprintf(stderr, "loaded fw %zu, kernel %zu, dtb %zu bytes\n", n1, n2, n3);
  wr64(R_BOOT_ENTRY, DRAM_BASE_RV + OFF_FW);
  wr64(R_DTB_ADDR, DRAM_BASE_RV + OFF_DTB);
  printf("loaded: fw %zu B, kernel %zu B, dtb %zu B into 0x%" PRIx64 " (RISC-V 0x%llx)\n", n1, n2, n3, o->base,
         (unsigned long long)DRAM_BASE_RV);
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
    if (fwrite(rec, TRS_REC_BYTES, 1, trace_out) != 1) die("trace write: %s", strerror(errno));
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

/* While running (no wrap): hand everything written to the output and free it. */
static int trace_poll(const struct opts *o) {
  if (o->trace_wrap) return 0;
  uint64_t wp = rd64(R_TRS_WP);
  if (wp == trace_rp) return 0;
  trace_copy(o, trace_rp, wp);
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
    trace_poll(o);
  }
  if (trace_out != stdout) fclose(trace_out);
  fprintf(stderr, "[%s] trace: %" PRIu64 " records written%s\n", prog, wp,
          rd(R_TRS_STATUS) & TRS_ST_AXI_ERR ? " (AXI ERROR)" : "");
}

static struct termios saved_tio;
static int tio_saved;
static void restore_tty(void) { if (tio_saved) tcsetattr(0, TCSANOW, &saved_tio); }
static volatile sig_atomic_t stop_req;
static void on_sig(int s) { (void)s; stop_req = 1; }

static int cmd_run(const struct opts *o) {
  check_id();
  set_inj(o);
  uint32_t ctrl = o->lossless ? CTRL_LOSSLESS : 0;
  /* uncore first, wait for the L2, then the cores (docs/spec/host.md, loading sequence) */
  wr(R_CTRL, ctrl | CTRL_CORE_RST);
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
    printf("console on %s\n", ptsname(m));
    fflush(stdout);
    in_fd = out_fd = m;
  } else if (o->console == 0) {
    in_fd = 0;
    out_fd = 1;
    if (isatty(0) && tcgetattr(0, &saved_tio) == 0) {
      struct termios t = saved_tio;
      cfmakeraw(&t);
      t.c_oflag |= OPOST;
      tcsetattr(0, TCSANOW, &t);
      tio_saved = 1;
      atexit(restore_tty);
    }
  }
  signal(SIGINT, on_sig);
  signal(SIGTERM, on_sig);

  if (o->trace) trace_begin(o);
  wr(R_CTRL, ctrl);                         /* release the cores */
  double t_end = o->timeout > 0 ? now_s() + o->timeout : 0;
  int rc = 0, ctrl_a = 0;
  for (;;) {
    int idle = 1;
    /* console out */
    for (int k = 0; k < 256; k++) {
      uint32_t v = rd(R_UART_TX);
      if (!(v & 0x100)) break;
      if (out_fd >= 0) {
        char c = (char)(v & 0xff);
        if (write(out_fd, &c, 1) < 0 && errno != EAGAIN) die("console write: %s", strerror(errno));
      }
      idle = 0;
    }
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
      if (v == POWER_OFF)         { fprintf(stderr, "\r\n[%s] RISC-V requested power-off\r\n", prog); rc = 0; break; }
      if (v == POWER_REBOOT)      { fprintf(stderr, "\r\n[%s] RISC-V requested reboot\r\n", prog); rc = 3; break; }
      if ((v & 0xffff) == POWER_FAIL) { fprintf(stderr, "\r\n[%s] RISC-V reported failure\r\n", prog); rc = 1; break; }
    }
    if (rd(R_TOHOST_SEQ) != seq0) {
      uint64_t th = rd64(R_TOHOST);
      if (th & 1) {                         /* riscv-tests convention: 1 = pass, else (code << 1) | 1 */
        fprintf(stderr, "\r\n[%s] tohost 0x%" PRIx64 ": %s\r\n", prog, th, th == 1 ? "PASS" : "FAIL");
        rc = th == 1 ? 0 : 1;
        break;
      }
      seq0 = rd(R_TOHOST_SEQ);
    }
    if (o->trace && trace_poll(o)) idle = 0;
    if (stop_req) { rc = 130; break; }
    if (t_end && now_s() > t_end) { fprintf(stderr, "\r\n[%s] timeout\r\n", prog); rc = 124; break; }
    if (idle) sleep_us(200);
  }
  if (o->trace) trace_end(o);
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
  struct opts o = { .regs_pa = 0xA0000000ull, .base = 0x840000000ull, .size = 0x40000000ull,
                    .console = 0, .inj_rd = -1, .inj_wr = -1, .inj_mode = -1, .inj_bw = -1,
                    .trace_log2 = 22 };
  int stats = 0;
  static const struct option lo[] = {
    { "regs", 1, 0, 'R' }, { "base", 1, 0, 'B' }, { "size", 1, 0, 'S' },
    { "fw", 1, 0, 'f' }, { "kernel", 1, 0, 'k' }, { "dtb", 1, 0, 'd' },
    { "pty", 0, 0, 'p' }, { "no-console", 0, 0, 'n' }, { "timeout", 1, 0, 't' }, { "lossless", 0, 0, 'l' },
    { "inj-rd", 1, 0, 1 }, { "inj-wr", 1, 0, 2 }, { "inj-mode", 1, 0, 3 }, { "inj-bw", 1, 0, 4 },
    { "stats", 0, 0, 5 }, { "trace", 1, 0, 6 }, { "trace-log2", 1, 0, 7 }, { "trace-wrap", 0, 0, 8 },
    { "trace-start", 1, 0, 9 }, { "trace-stop", 1, 0, 10 }, { "trace-post", 1, 0, 11 },
    { "help", 0, 0, 'h' }, { 0, 0, 0, 0 }
  };
  int c;
  while ((c = getopt_long(argc, argv, "+vh", lo, NULL)) != -1) {
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
      case 'v': verbose = 1; break;
      default: usage();
    }
  }
  if (optind >= argc) usage();
  const char *cmd = argv[optind++];
  regs = map_phys(o.regs_pa, 0x10000);

  if (!strcmp(cmd, "info"))       { check_id(); cmd_info(); return 0; }
  if (!strcmp(cmd, "reset"))      { check_id(); cmd_reset(); return 0; }
  if (!strcmp(cmd, "load"))       { check_id(); cmd_load(&o); return 0; }
  if (!strcmp(cmd, "run"))        return cmd_run(&o);
  if (!strcmp(cmd, "boot"))       { check_id(); cmd_load(&o); return cmd_run(&o); }
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
    trace_status();
    return 0;
  }
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
