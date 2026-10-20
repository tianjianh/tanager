/* memgap: RISC-V mode's sysbench memory gap (soc-2, 10-20; docs/spec/soc-d4-modes.md, "RISC-V mode's memory gap").
   The measurements that tell a costlier clock read from a slower memory path or from time taken by something
   else, run the same way under Debian in stage C and in RISC-V mode on one bitstream. Our own code (DR-138).
   Build on the board's Debian:   gcc -O2 -pthread -o memgap memgap.c
     memgap [-i SECONDS] [-t SECONDS]
   First an idle window of -i seconds (default 10): what else runs, from /proc/stat and /proc/interrupts (MEMGAP-IDLE-*
   lines). Then each test for about -t seconds (default 1), one line each: MEMGAP <test> <value> <unit>.
   Tests, in the order they run:
     clock      clock_gettime(CLOCK_MONOTONIC), the vDSO's path: sysbench reads the clock 3 times an event
     rdtime     the time CSR alone (RISC-V only)
     wr1k       a 1 KiB buffer written with 8-byte stores, sysbench memory's event (L1)
     wr1m       1 MiB, twice the L2 (the L2 and DDR)
     wr16m      16 MiB, DDR write streaming
     rd16m      16 MiB read and summed, DDR read streaming
     chase16k   dependent loads through a random cycle of 64-byte lines over 16 KiB: L1 latency
     chase256k  over 256 KiB: L2 latency
     chase64m   over 64 MiB: DDR latency, TLB misses included (the same kernel in both modes)
     pingpong   two threads on CPUs 0 and 1 pass one cache line back and forth: a coherence round trip
     ev1        sysbench memory's event in one thread: 3 clock reads, a 1 KiB block written, one shared atomic add
     ev2local   the same in two threads, each with its own block (the shared atomic add stays)
     ev2shared  two threads writing one shared block, sysbench memory's default (--memory-scope=global)
   For the idle window and again for the tests: each CPU's time by kind, interrupts and context switches per second,
   and every interrupt line that counted, per second (in the tests' window, another program's time shows as user or
   system time beyond this one's: they keep one or two CPUs busy, as said above).
*/
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#define LINE 64

static double secs = 1.0, idle_secs = 10.0;
static volatile uint64_t sink;  // keeps every result live

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void *buf_alloc(size_t bytes) {
  void *p = aligned_alloc(4096, bytes);
  if (!p) {
    fprintf(stderr, "memgap: %zu bytes: %s\n", bytes, strerror(errno));
    exit(2);
  }
  memset(p, 1, bytes);  // fault every page in before any timing
  return p;
}

/* Runs f with a growing count until one run lasts at least `secs`; returns ns per unit of that run. */
static double timed(uint64_t (*f)(uint64_t), uint64_t start) {
  uint64_t n = start;
  for (;;) {
    double t0 = now();
    sink ^= f(n);
    double dt = now() - t0;
    if (dt >= secs) return dt * 1e9 / (double)n;
    n = dt < secs / 16 ? n * 8 : (uint64_t)((double)n * secs / dt * 1.1) + 1;
  }
}

static uint64_t t_clock(uint64_t n) {
  uint64_t s = 0;
  struct timespec ts;
  for (uint64_t i = 0; i < n; i++) {
    clock_gettime(CLOCK_MONOTONIC, &ts);
    s += (uint64_t)ts.tv_nsec;
  }
  return s;
}

#if defined(__riscv)
static inline uint64_t rdtime(void) {
  uint64_t t;
  __asm__ volatile("rdtime %0" : "=r"(t));
  return t;
}
static uint64_t t_rdtime(uint64_t n) {
  uint64_t s = 0;
  for (uint64_t i = 0; i < n; i++) s += rdtime();
  return s;
}
#endif

static uint64_t *wbuf;
static size_t wwords;

static void block_write(uint64_t *b, size_t words, uint64_t v) {
  for (size_t i = 0; i < words; i++) b[i] = v;
}

static uint64_t t_write(uint64_t n) {  // n passes over wbuf
  for (uint64_t i = 0; i < n; i++) block_write(wbuf, wwords, i);
  return wbuf[wwords - 1];
}

static uint64_t t_read(uint64_t n) {
  uint64_t s = 0;
  for (uint64_t i = 0; i < n; i++)
    for (size_t k = 0; k < wwords; k++) s += wbuf[k];
  return s;
}

/* A random cycle through every line of the buffer (Sattolo's shuffle, a fixed seed): each line holds the next. */
static void **chase_start;

static uint64_t xs = 0x9e3779b97f4a7c15u;
static uint64_t xorshift(void) {
  xs ^= xs << 13;
  xs ^= xs >> 7;
  xs ^= xs << 17;
  return xs;
}

static void chase_build(size_t bytes) {
  size_t lines = bytes / LINE;
  char *b = buf_alloc(bytes);
  size_t *perm = malloc(lines * sizeof *perm);
  if (!perm) exit(2);
  for (size_t i = 0; i < lines; i++) perm[i] = i;
  for (size_t i = lines - 1; i > 0; i--) {
    size_t j = (size_t)(xorshift() % i);
    size_t t = perm[i];
    perm[i] = perm[j];
    perm[j] = t;
  }
  for (size_t i = 0; i < lines; i++) *(void **)(b + perm[i] * LINE) = b + perm[(i + 1) % lines] * LINE;
  free(perm);
  chase_start = (void **)b;
}

static uint64_t t_chase(uint64_t n) {
  void **p = chase_start;
  for (uint64_t i = 0; i < n; i++) p = (void **)*p;
  chase_start = p;
  return (uint64_t)(uintptr_t)p;
}

/* Two threads pinned to CPUs 0 and 1. */
static int pin_ok = 1;

static void run2(void *(*fn)(void *), void *a0, void *a1) {
  pthread_t t[2];
  void *arg[2] = {a0, a1};
  for (int c = 0; c < 2; c++) {
    pthread_attr_t at;
    cpu_set_t set;
    pthread_attr_init(&at);
    CPU_ZERO(&set);
    CPU_SET(c, &set);
    if (pthread_attr_setaffinity_np(&at, sizeof set, &set)) pin_ok = 0;
    if (pthread_create(&t[c], &at, fn, arg[c])) {
      fprintf(stderr, "memgap: pthread_create: %s\n", strerror(errno));
      exit(2);
    }
    pthread_attr_destroy(&at);
  }
  pthread_join(t[0], NULL);
  pthread_join(t[1], NULL);
}

static _Alignas(LINE) _Atomic uint64_t pp_line[LINE / 8];  // [0], alone in its line
static uint64_t pp_n;

static void *pp_thread(void *arg) {
  uint64_t me = (uint64_t)(uintptr_t)arg, n = pp_n;  // me: 0 or 1
  for (uint64_t i = 0; i < n; i++) {
    uint64_t want = 2 * i + me;
    while (atomic_load_explicit(&pp_line[0], memory_order_acquire) != want) {
    }
    atomic_store_explicit(&pp_line[0], want + 1, memory_order_release);
  }
  return NULL;
}

static uint64_t t_pingpong(uint64_t n) {  // n round trips
  atomic_store(&pp_line[0], 0);
  pp_n = n;
  run2(pp_thread, (void *)0, (void *)1);
  return atomic_load(&pp_line[0]);
}

/* sysbench memory's event: the time-limit check's clock read, the start's, the block, the stop's, and the
   shared total's atomic add (its next_event). */
static _Alignas(LINE) _Atomic uint64_t ev_total[LINE / 8];  // [0], alone in its line
static uint64_t ev_n;

struct ev_arg {
  uint64_t *block;
};

static uint64_t ev_loop(uint64_t *block, uint64_t n) {
  struct timespec a, b, c;
  uint64_t s = 0;
  for (uint64_t i = 0; i < n; i++) {
    clock_gettime(CLOCK_MONOTONIC, &a);
    atomic_fetch_add_explicit(&ev_total[0], 1024, memory_order_relaxed);
    clock_gettime(CLOCK_MONOTONIC, &b);
    block_write(block, 1024 / 8, i);
    clock_gettime(CLOCK_MONOTONIC, &c);
    s += (uint64_t)(c.tv_nsec - b.tv_nsec) + (uint64_t)a.tv_nsec;
  }
  return s;
}

static void *ev_thread(void *arg) {
  struct ev_arg *e = arg;
  sink ^= ev_loop(e->block, ev_n);
  return NULL;
}

static _Alignas(4096) uint64_t ev_blocks[2][4096 / 8];  // two 1 KiB blocks, a page apart

static uint64_t t_ev1(uint64_t n) { return ev_loop(ev_blocks[0], n); }

static uint64_t t_ev2local(uint64_t n) {  // n events in each thread
  struct ev_arg a = {ev_blocks[0]}, b = {ev_blocks[1]};
  ev_n = n;
  run2(ev_thread, &a, &b);
  return atomic_load(&ev_total[0]);
}

static uint64_t t_ev2shared(uint64_t n) {
  struct ev_arg a = {ev_blocks[0]}, b = {ev_blocks[0]};
  ev_n = n;
  run2(ev_thread, &a, &b);
  return atomic_load(&ev_total[0]);
}

/* ---- /proc/stat and /proc/interrupts over the run ---- */
#define MAXCPU 8
#define MAXIRQ 128

struct snap {
  int ncpu;
  unsigned long long cpu[MAXCPU][8];  // user nice system idle iowait irq softirq steal
  unsigned long long intr, ctxt;
  int nirq;
  char irq_name[MAXIRQ][16];
  char irq_desc[MAXIRQ][48];
  unsigned long long irq_cnt[MAXIRQ];
};

static void snap_take(struct snap *s) {
  memset(s, 0, sizeof *s);
  FILE *f = fopen("/proc/stat", "r");
  char ln[4096];
  if (f) {
    while (fgets(ln, sizeof ln, f)) {
      int c;
      unsigned long long v[8] = {0};
      if (sscanf(ln, "cpu%d %llu %llu %llu %llu %llu %llu %llu %llu", &c, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5],
                 &v[6], &v[7]) >= 5 && c >= 0 && c < MAXCPU) {
        memcpy(s->cpu[c], v, sizeof v);
        if (c + 1 > s->ncpu) s->ncpu = c + 1;
      } else if (!strncmp(ln, "intr ", 5)) {
        s->intr = strtoull(ln + 5, NULL, 10);
      } else if (!strncmp(ln, "ctxt ", 5)) {
        s->ctxt = strtoull(ln + 5, NULL, 10);
      }
    }
    fclose(f);
  }
  f = fopen("/proc/interrupts", "r");
  if (!f) return;
  if (!fgets(ln, sizeof ln, f)) {  // the CPU header: one count column per CPU it names
    fclose(f);
    return;
  }
  int cols = 0;
  for (char *h = ln; (h = strstr(h, "CPU")); h += 3) cols++;
  while (s->nirq < MAXIRQ && fgets(ln, sizeof ln, f)) {
    char *colon = strchr(ln, ':');
    if (!colon) continue;
    *colon = 0;
    char *name = ln;
    while (*name == ' ') name++;
    char *p = colon + 1, *end;
    unsigned long long sum = 0;
    for (int k = 0; k < cols; k++) {  // ERR and MIS have one
      unsigned long long v = strtoull(p, &end, 10);
      if (end == p) break;
      sum += v;
      p = end;
    }
    while (*p == ' ') p++;
    p[strcspn(p, "\n")] = 0;
    snprintf(s->irq_name[s->nirq], sizeof s->irq_name[0], "%.15s", name);
    snprintf(s->irq_desc[s->nirq], sizeof s->irq_desc[0], "%.47s", p);
    s->irq_cnt[s->nirq++] = sum;
  }
  fclose(f);
}

static void snap_report(const char *pre, const struct snap *a, const struct snap *b, double dt) {
  static const char *kind[8] = {"user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal"};
  long hz = sysconf(_SC_CLK_TCK);
  for (int c = 0; c < b->ncpu; c++) {
    printf("%s-CPU cpu%d", pre, c);
    for (int k = 0; k < 8; k++)
      printf(" %s=%.1f%%", kind[k], 100.0 * (double)(b->cpu[c][k] - a->cpu[c][k]) / ((double)hz * dt));
    printf("\n");
  }
  printf("%s-RATE interrupts=%.1f/s context-switches=%.1f/s over %.1f s\n", pre, (double)(b->intr - a->intr) / dt,
         (double)(b->ctxt - a->ctxt) / dt, dt);
  for (int i = 0; i < b->nirq; i++) {
    unsigned long long was = 0;
    for (int j = 0; j < a->nirq; j++)
      if (!strcmp(a->irq_name[j], b->irq_name[i])) was = a->irq_cnt[j];
    if (b->irq_cnt[i] != was)
      printf("%s-IRQ %s %.1f/s %s\n", pre, b->irq_name[i], (double)(b->irq_cnt[i] - was) / dt, b->irq_desc[i]);
  }
}

static void info(void) {
  struct utsname u;
  char cs[64] = "?";
  FILE *f = fopen("/sys/devices/system/clocksource/clocksource0/current_clocksource", "r");
  if (f) {
    if (fgets(cs, sizeof cs, f)) cs[strcspn(cs, "\n")] = 0;
    fclose(f);
  }
  uname(&u);
  printf("MEMGAP-INFO kernel=%s machine=%s cpus=%ld clocksource=%s idle=%.1f s, each test %.2f s\n", u.release,
         u.machine, sysconf(_SC_NPROCESSORS_ONLN), cs, idle_secs, secs);
}

int main(int argc, char **argv) {
  int opt;
  while ((opt = getopt(argc, argv, "i:t:")) != -1) {
    if (opt == 't' && atof(optarg) > 0) secs = atof(optarg);
    else if (opt == 'i' && atof(optarg) >= 0) idle_secs = atof(optarg);
    else {
      fprintf(stderr, "usage: memgap [-i SECONDS] [-t SECONDS]\n");
      return 2;
    }
  }
  setvbuf(stdout, NULL, _IOLBF, 0);
  info();
  static struct snap s0, s1;
  if (idle_secs > 0) {
    snap_take(&s0);
    double i0 = now();
    struct timespec ts = {(time_t)idle_secs, (long)((idle_secs - (double)(time_t)idle_secs) * 1e9)};
    while (nanosleep(&ts, &ts) && errno == EINTR) {
    }
    double di = now() - i0;
    snap_take(&s1);
    snap_report("MEMGAP-IDLE", &s0, &s1, di);
  }
  snap_take(&s0);
  double t0 = now();

  printf("MEMGAP clock %.1f ns/call\n", timed(t_clock, 1000));
#if defined(__riscv)
  printf("MEMGAP rdtime %.1f ns/read\n", timed(t_rdtime, 1000));
#endif
  static const struct { const char *name; size_t bytes; } wr[] = {
    {"wr1k", 1024}, {"wr1m", 1u << 20}, {"wr16m", 16u << 20}};
  for (size_t k = 0; k < sizeof wr / sizeof wr[0]; k++) {
    wbuf = buf_alloc(wr[k].bytes);
    wwords = wr[k].bytes / 8;
    double ns = timed(t_write, 1);
    printf("MEMGAP %s %.1f MiB/s\n", wr[k].name, (double)wr[k].bytes / (1 << 20) / (ns * 1e-9));
    if (k == 2) {
      ns = timed(t_read, 1);
      printf("MEMGAP rd16m %.1f MiB/s\n", (double)wr[k].bytes / (1 << 20) / (ns * 1e-9));
    }
    free(wbuf);
  }
  static const struct { const char *name; size_t bytes; } ch[] = {
    {"chase16k", 16u << 10}, {"chase256k", 256u << 10}, {"chase64m", 64u << 20}};
  for (size_t k = 0; k < sizeof ch / sizeof ch[0]; k++) {
    chase_build(ch[k].bytes);
    void *b = chase_start;
    printf("MEMGAP %s %.1f ns/load\n", ch[k].name, timed(t_chase, 1000));
    free(b);
  }
  printf("MEMGAP pingpong %.1f ns/round-trip\n", timed(t_pingpong, 100));
  printf("MEMGAP ev1 %.1f ns/event\n", timed(t_ev1, 100));
  double l = timed(t_ev2local, 100), sh = timed(t_ev2shared, 100);
  printf("MEMGAP ev2local %.1f ns/event (per thread; %.0f events/s in all)\n", l, 2e9 / l);
  printf("MEMGAP ev2shared %.1f ns/event (per thread; %.0f events/s in all)\n", sh, 2e9 / sh);
  if (!pin_ok) printf("MEMGAP-NOTE the two-thread tests could not pin to CPUs 0 and 1\n");

  double dt = now() - t0;
  snap_take(&s1);
  snap_report("MEMGAP", &s0, &s1, dt);
  return 0;
}
