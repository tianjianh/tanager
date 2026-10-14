// tg_s1: PL -> PS DDR latency and bandwidth on the KV260 (Tanager spike S1).
//
// Runs on the A53 (Kria Ubuntu) with the S1 PL design loaded (xmutil loadapp tg-s1).
// Needs root: /dev/mem for the engines' registers, /proc/self/pagemap for physical
// addresses of the hugepage buffers.
//   build:  gcc -O2 -Wall -o tg_s1 tg_s1.c -lpthread
//   run:    sudo ./tg_s1 [--mb 256] [--quick] [--base 0xA0000000] | tee s1_results.txt
//           (--base: the engines' address if address_map.txt from the build differs)
//
// The PL has two engines (tg_s1_engine) on S_AXI_HP1_FPD and S_AXI_HP2_FPD, 128-bit at the
// 200 MHz core clock. Latency is counted in core clock cycles from the read-address
// handshake to the first data beat at the PL port: what the L2 would see.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define ENG_PHYS   0xA0000000UL
#define ENG_SPAN   0x1000
#define ENG_STRIDE 0x800
#define HUGE_SZ    (2UL << 20)
#define LINE       64

enum {
  R_ID = 0, R_CTRL, R_STATUS, R_BEATS, R_OUTST, R_COUNT, R_BASE_LO, R_BASE_HI, R_SIZE,
  R_STRIDE, R_SEED, R_HSHIFT, R_CYC_LO, R_CYC_HI, R_LMIN, R_LMAX, R_LSUM_LO, R_LSUM_HI,
  R_DONE, R_BYTES_LO, R_BYTES_HI, R_ERR, R_LAST_LO, R_LAST_HI, R_FERR, R_HIST = 256
};
enum { MODE_READ = 0, MODE_WRITE = 1 };

static volatile uint32_t *eng[2];
static double core_hz = 200e6;

static void wr(int e, int r, uint32_t v) { eng[e][r] = v; __sync_synchronize(); }
static uint32_t rd(int e, int r) { __sync_synchronize(); return eng[e][r]; }

typedef struct {
  uint64_t cycles, bytes, lat_sum, done;
  uint32_t lat_min, lat_max, errors, first_err;
  uint32_t hist[256];
  int hshift;
} result_t;

typedef struct {
  int mode, chase, random, beats, outst, hshift;
  uint32_t count, size, stride, seed;
  uint64_t base;
} job_t;

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void start(int e, const job_t *j) {
  while (rd(e, R_STATUS) & 1) usleep(100);
  wr(e, R_CTRL, (j->chase << 2) | (j->random << 3) | (j->mode << 4));
  wr(e, R_BEATS, j->beats - 1);
  wr(e, R_OUTST, j->outst);
  wr(e, R_COUNT, j->count);
  wr(e, R_BASE_LO, (uint32_t)j->base);
  wr(e, R_BASE_HI, (uint32_t)(j->base >> 32));
  wr(e, R_SIZE, j->size);
  wr(e, R_STRIDE, j->stride);
  wr(e, R_SEED, j->seed);
  wr(e, R_HSHIFT, j->hshift);
  wr(e, R_CTRL, (j->chase << 2) | (j->random << 3) | (j->mode << 4) | 1);
}

static int wait_done(int e, double timeout_s) {
  double t0 = now_s();
  while (rd(e, R_STATUS) & 1) {
    if (now_s() - t0 > timeout_s) {
      fprintf(stderr, "engine %d: timeout, aborting (issued up to 0x%08x%08x)\n", e,
              rd(e, R_LAST_HI), rd(e, R_LAST_LO));
      wr(e, R_CTRL, 2);
      return -1;
    }
    usleep(200);
  }
  return 0;
}

static void collect(int e, result_t *r, int hshift) {
  r->cycles = rd(e, R_CYC_LO) | (uint64_t)rd(e, R_CYC_HI) << 32;
  r->bytes = rd(e, R_BYTES_LO) | (uint64_t)rd(e, R_BYTES_HI) << 32;
  r->lat_sum = rd(e, R_LSUM_LO) | (uint64_t)rd(e, R_LSUM_HI) << 32;
  r->done = rd(e, R_DONE);
  r->lat_min = rd(e, R_LMIN);
  r->lat_max = rd(e, R_LMAX);
  r->errors = rd(e, R_ERR);
  r->first_err = rd(e, R_FERR);
  r->hshift = hshift;
  for (int i = 0; i < 256; i++) r->hist[i] = rd(e, R_HIST + i);
}

static double pct(const result_t *r, double p) {
  uint64_t tot = 0, acc = 0;
  for (int i = 0; i < 256; i++) tot += r->hist[i];
  if (!tot) return 0;
  for (int i = 0; i < 256; i++) {
    acc += r->hist[i];
    if (acc >= p * tot) return (double)((i << r->hshift) + ((1 << r->hshift) >> 1));
  }
  return (double)(255 << r->hshift);
}

static int run(int e, const job_t *j, result_t *r) {
  start(e, j);
  if (wait_done(e, 60.0)) return -1;
  collect(e, r, j->hshift);
  if (r->errors)
    fprintf(stderr, "engine %d: %u response errors, first %s (%u)\n", e, r->errors,
            r->first_err == 3 ? "DECERR" : r->first_err == 2 ? "SLVERR" : "?", r->first_err);
  return r->errors ? -1 : 0;
}

static void print_lat(const char *name, const result_t *r) {
  double avg = r->done ? (double)r->lat_sum / r->done : 0;
  double ns = 1e9 / core_hz;
  printf("  %-34s n=%-8" PRIu64 " min %4u  avg %6.1f  p50 %5.0f  p90 %5.0f  p99 %5.0f  max %5u cycles"
         "  (avg %.1f ns)\n", name, r->done, r->lat_min, avg, pct(r, .5), pct(r, .9), pct(r, .99),
         r->lat_max, avg * ns);
}

static void print_bw(const char *name, const result_t *r) {
  double secs = r->cycles / core_hz;
  double avg = r->done ? (double)r->lat_sum / r->done : 0;
  printf("  %-34s %8.1f MB/s  (%.2f bytes/cycle, avg latency %.1f cycles)\n", name,
         secs > 0 ? r->bytes / secs / 1e6 : 0, r->cycles ? (double)r->bytes / r->cycles : 0, avg);
}

// ---- Memory: hugepages with physical addresses ----
typedef struct { uint8_t *va; uint64_t pa; } page_t;
static page_t *pages;
static int npages;

static uint64_t virt_to_phys(void *va) {
  int fd = open("/proc/self/pagemap", O_RDONLY);
  if (fd < 0) { perror("pagemap"); exit(1); }
  uint64_t ent;
  off_t off = ((uintptr_t)va / 4096) * 8;
  if (pread(fd, &ent, 8, off) != 8) { perror("pagemap read"); exit(1); }
  close(fd);
  if (!(ent >> 63)) { fprintf(stderr, "page not present\n"); exit(1); }
  uint64_t pfn = ent & ((1ULL << 55) - 1);
  if (!pfn) { fprintf(stderr, "pagemap gives PFN 0: run as root\n"); exit(1); }
  return pfn * 4096 + ((uintptr_t)va & 4095);
}

static void alloc_huge(int n) {
  FILE *f = fopen("/proc/sys/vm/nr_hugepages", "r+");
  int have = 0;
  if (f) { if (fscanf(f, "%d", &have) != 1) have = 0; fclose(f); }
  if (have < n) {
    f = fopen("/proc/sys/vm/nr_hugepages", "w");
    if (f) { fprintf(f, "%d\n", n + 2); fclose(f); }
  }
  pages = calloc(n, sizeof(page_t));
  npages = n;
  for (int i = 0; i < n; i++) {
    void *p = mmap(NULL, HUGE_SZ, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_POPULATE, -1, 0);
    if (p == MAP_FAILED) {
      fprintf(stderr, "hugepage %d of %d failed (%s); try: echo %d | sudo tee "
              "/proc/sys/vm/nr_hugepages\n", i, n, strerror(errno), n + 2);
      exit(1);
    }
    memset(p, 0, HUGE_SZ);
    pages[i].va = p;
    pages[i].pa = virt_to_phys(p);
  }
}

// Clean the data cache to the point of coherency so the PL sees what the A53 wrote
static void clean_dcache(void *va, size_t len) {
#if defined(__aarch64__)
  for (uintptr_t a = (uintptr_t)va & ~63UL; a < (uintptr_t)va + len; a += 64)
    __asm__ volatile("dc cvac, %0" :: "r"(a) : "memory");
  __asm__ volatile("dsb sy" ::: "memory");
#else
  (void)va; (void)len;   // host syntax check only
#endif
}

// A random cyclic pointer chase over all lines of the first np hugepages (Sattolo's
// algorithm); each node's first 8 bytes hold the next node's physical address.
static uint64_t build_chase(int np) {
  uint64_t lines_per = HUGE_SZ / LINE, n = lines_per * np;
  uint32_t *perm = malloc(n * sizeof(uint32_t));
  for (uint64_t i = 0; i < n; i++) perm[i] = i;
  uint64_t s = 0x9e3779b97f4a7c15ULL;
  for (uint64_t i = n - 1; i > 0; i--) {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    uint64_t k = s % i;
    uint32_t t = perm[i]; perm[i] = perm[k]; perm[k] = t;
  }
  for (uint64_t i = 0; i < n; i++) {
    uint64_t a = perm[i], b = perm[(i + 1) % n];
    uint64_t *node = (uint64_t *)(pages[a / lines_per].va + (a % lines_per) * LINE);
    *node = pages[b / lines_per].pa + (b % lines_per) * LINE;
  }
  for (int p = 0; p < np; p++) clean_dcache(pages[p].va, HUGE_SZ);
  uint64_t first = pages[perm[0] / lines_per].pa + (perm[0] % lines_per) * LINE;
  free(perm);
  return first;
}

// ---- A53 memory load for the contention test ----
static volatile int hog_stop;
static void *hog(void *arg) {
  size_t sz = 64UL << 20;
  uint8_t *a = malloc(sz), *b = malloc(sz);
  memset(a, 1, sz); memset(b, 2, sz);
  while (!hog_stop) memcpy(b, a, sz);
  free(a); free(b);
  return arg;
}

static void measure_clock(void) {
  job_t j = { .mode = MODE_READ, .beats = 4, .outst = 4, .count = 2000000, .size = HUGE_SZ,
              .stride = LINE, .seed = 1, .base = pages[0].pa };
  result_t r;
  double t0 = now_s();
  if (run(0, &j, &r)) return;
  double t = now_s() - t0;
  if (t > 0.05 && r.cycles)
    printf("core clock: %.1f MHz by wall time (includes polling; nominal 200, used below)\n",
           r.cycles / t / 1e6);
}

int main(int argc, char **argv) {
  int mb = 256, quick = 0;
  unsigned long base = ENG_PHYS;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--mb") && i + 1 < argc) mb = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--base") && i + 1 < argc) base = strtoul(argv[++i], NULL, 0);
    else if (!strcmp(argv[i], "--quick")) quick = 1;
    else { fprintf(stderr, "usage: %s [--mb N] [--quick] [--base ADDR]\n", argv[0]); return 2; }
  }
  int fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (fd < 0) { perror("/dev/mem (run as root)"); return 1; }
  volatile uint32_t *regs = mmap(NULL, ENG_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)base);
  if (regs == MAP_FAILED) { perror("mmap engines"); return 1; }
  eng[0] = regs;
  eng[1] = regs + ENG_STRIDE / 4;
  for (int e = 0; e < 2; e++) {
    uint32_t id = rd(e, R_ID);
    if (id != 0x71530001) {
      fprintf(stderr, "engine %d: ID 0x%08x, expected 0x71530001. Is the S1 design loaded "
              "(xmutil listapps)? Are the AXI widths set (the overlay's afi0 node)?\n", e, id);
      return 1;
    }
  }
  int np = mb / 2;
  if (np < 2) np = 2;
  printf("tg_s1: allocating %d x 2 MiB hugepages\n", np);
  alloc_huge(np);
  printf("hugepage 0 at PA 0x%" PRIx64 ", last at 0x%" PRIx64 "\n", pages[0].pa, pages[np - 1].pa);
  measure_clock();
  uint32_t cnt = quick ? 20000 : 200000;
  result_t r, r1;

  printf("\n== Idle latency: dependent 64 B reads (pointer chase), one in flight, HP1\n");
  {
    uint64_t first = build_chase(1);
    job_t j = { .mode = MODE_READ, .chase = 1, .beats = 4, .outst = 1, .count = cnt,
                .size = HUGE_SZ, .stride = LINE, .base = first, .hshift = 1 };
    if (!run(0, &j, &r)) print_lat("chase within 2 MiB", &r);
    first = build_chase(np);
    j.base = first;
    if (!run(0, &j, &r)) print_lat("chase over the whole buffer", &r);
    j.beats = 1;
    if (!run(0, &j, &r)) print_lat("chase, 16 B reads", &r);
    j.beats = 4;
    if (!run(1, &j, &r)) print_lat("chase, HP2", &r);
  }

  printf("\n== Read bandwidth, one port (HP1), sequential, within 2 MiB\n");
  int outs[] = {1, 2, 4, 8, 16, 32};
  for (int b = 4; b <= 16; b *= 4) {
    for (unsigned k = 0; k < sizeof outs / sizeof outs[0]; k++) {
      job_t j = { .mode = MODE_READ, .beats = b, .outst = outs[k], .count = cnt * 2,
                  .size = HUGE_SZ, .stride = b * 16, .base = pages[0].pa, .hshift = 2 };
      char name[64];
      snprintf(name, sizeof name, "%3d B bursts, %2d outstanding", b * 16, outs[k]);
      if (!run(0, &j, &r)) print_bw(name, &r);
    }
  }
  printf("\n== Read bandwidth, random 64 B within 2 MiB\n");
  for (int o = 8; o <= 32; o *= 2) {
    job_t j = { .mode = MODE_READ, .random = 1, .beats = 4, .outst = o, .count = cnt * 2,
                .size = HUGE_SZ, .stride = LINE, .seed = 7, .base = pages[0].pa, .hshift = 2 };
    char name[64];
    snprintf(name, sizeof name, "random 64 B, %2d outstanding", o);
    if (!run(0, &j, &r)) print_bw(name, &r);
  }

  printf("\n== Write bandwidth, HP1, sequential, within 2 MiB (into hugepage 1)\n");
  for (int b = 4; b <= 16; b *= 4) {
    job_t j = { .mode = MODE_WRITE, .beats = b, .outst = 16, .count = cnt * 2,
                .size = HUGE_SZ, .stride = b * 16, .base = pages[1].pa, .hshift = 2 };
    char name[64];
    snprintf(name, sizeof name, "%3d B bursts, 16 outstanding", b * 16);
    if (!run(0, &j, &r)) print_bw(name, &r);
  }

  printf("\n== Both ports reading at once (HP1 + HP2), 256 B bursts, 32 outstanding\n");
  {
    job_t j = { .mode = MODE_READ, .beats = 16, .outst = 32, .count = cnt * 4,
                .size = HUGE_SZ, .stride = 256, .base = pages[0].pa, .hshift = 2 };
    job_t j1 = j;
    j1.base = pages[np > 2 ? 2 : 1].pa;
    start(0, &j); start(1, &j1);
    if (!wait_done(0, 60) && !wait_done(1, 60)) {
      collect(0, &r, 2); collect(1, &r1, 2);
      print_bw("HP1", &r); print_bw("HP2", &r1);
      printf("  aggregate %.1f MB/s\n", (r.bytes / (r.cycles / core_hz) + r1.bytes / (r1.cycles / core_hz)) / 1e6);
    }
  }

  printf("\n== Loaded latency: chase on HP1 while HP2 streams\n");
  {
    uint64_t first = build_chase(np);
    for (int wmode = 0; wmode < 2; wmode++) {
      job_t load = { .mode = wmode ? MODE_WRITE : MODE_READ, .beats = 16, .outst = 32,
                     .count = 0xffffffffu, .size = HUGE_SZ, .stride = 256,
                     .base = pages[1].pa, .hshift = 2 };
      job_t j = { .mode = MODE_READ, .chase = 1, .beats = 4, .outst = 1, .count = cnt,
                  .size = HUGE_SZ, .stride = LINE, .base = first, .hshift = 1 };
      start(1, &load);
      usleep(1000);
      int bad = run(0, &j, &r);
      wr(1, R_CTRL, 2);
      wait_done(1, 5);
      collect(1, &r1, 2);
      if (!bad) print_lat(wmode ? "chase, HP2 writing" : "chase, HP2 reading", &r);
      print_bw(wmode ? "  (HP2 write stream)" : "  (HP2 read stream)", &r1);
    }
    printf("\n== Loaded latency: chase on HP1 while 4 A53 threads copy memory\n");
    pthread_t th[4];
    hog_stop = 0;
    for (int i = 0; i < 4; i++) pthread_create(&th[i], NULL, hog, NULL);
    usleep(200000);
    job_t j = { .mode = MODE_READ, .chase = 1, .beats = 4, .outst = 1, .count = cnt,
                .size = HUGE_SZ, .stride = LINE, .base = first, .hshift = 1 };
    if (!run(0, &j, &r)) print_lat("chase, A53 memcpy x4", &r);
    hog_stop = 1;
    for (int i = 0; i < 4; i++) pthread_join(th[i], NULL);
  }
  printf("\ncore cycle = %.3f ns. Paste this output into the S1 section of docs/perf/spikes.md.\n",
         1e9 / core_hz);
  return 0;
}
