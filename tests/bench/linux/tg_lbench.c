/* tg-lbench: the Linux workload set's micro-benchmarks (DR-141; docs/spec/verification.md §4.6).
   One static binary, one subcommand per measurement, each run -n times with one TGLB line per run
   (tglb.h). Our own code (the clean-room rule, DR-138).

     tg-lbench info                              counters, timebase, page size
     tg-lbench forkexec [-n R] [COUNT] [PROG]    COUNT fork + exec PROG + wait (1000, /bin/true)
     tg-lbench syscall  [-n R] [COUNT]           COUNT getpid system calls (1,000,000)
     tg-lbench memcpy   [-n R] SIZE [TOTAL]      memcpy of SIZE bytes until TOTAL bytes moved (64 MiB)
     tg-lbench memset   [-n R] SIZE [TOTAL]      memset, the same way
     tg-lbench pipe     [-n R] [SIZE] [TOTAL]    a child writes TOTAL bytes into a pipe in SIZE writes;
                                                 the parent reads them (64 KiB, 16 MiB)
     tg-lbench tmpfs    [-n R] [SIZE] [TOTAL] [PATH]  write TOTAL bytes to a file in SIZE writes, read
                                                 them back (64 KiB, 16 MiB, /tmp/tglb.dat)
     tg-lbench pagefault [-n R] [MIB]            mmap MIB MiB and write one byte per page (64)
     tg-lbench tlbwalk  [-n R] [MIB] [STEPS]     a dependent pointer chase through a random cycle of
                                                 the MIB MiB's pages (64, 1,000,000 steps)
     tg-lbench gen FILE MIB                      write MIB MiB of deterministic, compressible text
     tg-lbench exec [-n R] [-l LABEL] -- CMD...  run CMD with stdout to /dev/null, R times
*/
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#include "tglb.h"

static int runs = 1;

static void die(const char *what) {
  fprintf(stderr, "tg-lbench: %s: %s\n", what, strerror(errno));
  exit(2);
}

static uint64_t num(const char *s, const char *what) {  // a count, with an optional K or M suffix
  char *end;
  errno = 0;
  unsigned long long v = strtoull(s, &end, 0);
  int ok = end != s && !errno;
  if (ok && (*end == 'K' || *end == 'k')) v <<= 10, end++;
  else if (ok && (*end == 'M' || *end == 'm')) v <<= 20, end++;
  if (!ok || *end) {
    fprintf(stderr, "tg-lbench: bad %s: %s\n", what, s);
    exit(2);
  }
  return v;
}

static uint64_t timebase(void) {
  unsigned char b[4];
  int fd = open("/proc/device-tree/cpus/timebase-frequency", O_RDONLY);
  if (fd < 0) return 0;
  ssize_t n = read(fd, b, 4);
  close(fd);
  return n == 4 ? ((uint64_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]) : 0;
}

static void *map(size_t bytes) {
  void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED) die("mmap");
  return p;
}

static void touch(void *p, size_t bytes) {
  for (size_t i = 0; i < bytes; i += 4096) ((volatile char *)p)[i] = 1;
}

static int t_info(void) {
  int c = tglb_has_cycle();
  printf("TGLB-INFO counters=%s timebase=%" PRIu64 " pagesize=%ld perf_events=%d perf_errno=%d\n",
         c ? "cycle,instret,time" : "time", timebase(), sysconf(_SC_PAGESIZE), tglb_perf_opened, tglb_perf_errno);
  return 0;
}

static int t_forkexec(int argc, char **argv) {
  uint64_t count = argc > 0 ? num(argv[0], "COUNT") : 1000;
  const char *prog = argc > 1 ? argv[1] : "/bin/true";
  char extra[160];
  snprintf(extra, sizeof extra, " prog=%s", prog);
  for (int r = 1; r <= runs; r++) {
    struct tglb_mark a, b;
    tglb_take(&a);
    for (uint64_t i = 0; i < count; i++) {
      pid_t pid = fork();
      if (pid < 0) die("fork");
      if (pid == 0) {
        execl(prog, prog, (char *)NULL);
        _exit(127);
      }
      int st;
      if (waitpid(pid, &st, 0) < 0) die("waitpid");
      if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        fprintf(stderr, "tg-lbench: %s failed (status %d)\n", prog, st);
        return 1;
      }
    }
    tglb_take(&b);
    tglb_report("forkexec", r, &a, &b, count, extra);
  }
  return 0;
}

static int t_syscall(int argc, char **argv) {
  uint64_t count = argc > 0 ? num(argv[0], "COUNT") : 1000000;
  for (int r = 1; r <= runs; r++) {
    struct tglb_mark a, b;
    tglb_take(&a);
    for (uint64_t i = 0; i < count; i++) syscall(SYS_getpid);  // always enters the kernel
    tglb_take(&b);
    tglb_report("syscall", r, &a, &b, count, " call=getpid");
  }
  return 0;
}

static int t_mem(int argc, char **argv, int copy) {
  if (argc < 1) {
    fprintf(stderr, "tg-lbench: %s needs SIZE\n", copy ? "memcpy" : "memset");
    return 2;
  }
  uint64_t size = num(argv[0], "SIZE"), total = argc > 1 ? num(argv[1], "TOTAL") : 64 << 20;
  if (size == 0 || size > total) {
    fprintf(stderr, "tg-lbench: SIZE must be from 1 to TOTAL\n");
    return 2;
  }
  uint64_t iters = total / size;
  char *src = map(size), *dst = map(size);
  touch(src, size);
  touch(dst, size);
  memset(src, 0x5a, size);
  char test[32], extra[64];
  snprintf(test, sizeof test, "%s-%" PRIu64, copy ? "memcpy" : "memset", size);
  snprintf(extra, sizeof extra, " bytes=%" PRIu64, iters * size);
  for (int r = 1; r <= runs; r++) {
    struct tglb_mark a, b;
    tglb_take(&a);
    for (uint64_t i = 0; i < iters; i++) {
      if (copy) memcpy(dst, src, size);
      else memset(dst, (int)i, size);
      __asm__ volatile("" : : "r"(dst) : "memory");  // keep every call
    }
    tglb_take(&b);
    tglb_report(test, r, &a, &b, iters, extra);
  }
  return 0;
}

static int t_pipe(int argc, char **argv) {
  uint64_t size = argc > 0 ? num(argv[0], "SIZE") : 64 << 10, total = argc > 1 ? num(argv[1], "TOTAL") : 16 << 20;
  char *buf = map(size);
  touch(buf, size);
  char extra[64];
  snprintf(extra, sizeof extra, " size=%" PRIu64 " bytes=%" PRIu64, size, total);
  for (int r = 1; r <= runs; r++) {
    int fd[2];
    if (pipe(fd) < 0) die("pipe");
    pid_t pid = fork();
    if (pid < 0) die("fork");
    if (pid == 0) {
      close(fd[0]);
      for (uint64_t left = total; left;) {
        ssize_t n = write(fd[1], buf, left < size ? left : size);
        if (n <= 0) _exit(1);
        left -= (uint64_t)n;
      }
      _exit(0);
    }
    close(fd[1]);
    struct tglb_mark a, b;
    uint64_t got = 0, reads = 0;
    tglb_take(&a);
    for (;;) {
      ssize_t n = read(fd[0], buf, size);
      if (n < 0) die("read");
      if (n == 0) break;
      got += (uint64_t)n;
      reads++;
    }
    tglb_take(&b);
    close(fd[0]);
    waitpid(pid, NULL, 0);
    if (got != total) {
      fprintf(stderr, "tg-lbench: pipe moved %" PRIu64 " of %" PRIu64 " bytes\n", got, total);
      return 1;
    }
    tglb_report("pipe", r, &a, &b, reads, extra);
  }
  return 0;
}

static int t_tmpfs(int argc, char **argv) {
  uint64_t size = argc > 0 ? num(argv[0], "SIZE") : 64 << 10, total = argc > 1 ? num(argv[1], "TOTAL") : 16 << 20;
  const char *path = argc > 2 ? argv[2] : "/tmp/tglb.dat";
  char *buf = map(size);
  touch(buf, size);
  memset(buf, 0x3c, size);
  char extra[64];
  snprintf(extra, sizeof extra, " size=%" PRIu64 " bytes=%" PRIu64, size, total);
  for (int r = 1; r <= runs; r++) {
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) die(path);
    struct tglb_mark a, b, c;
    uint64_t ops = 0;
    tglb_take(&a);
    for (uint64_t left = total; left; ops++) {
      ssize_t n = write(fd, buf, left < size ? left : size);
      if (n <= 0) die("write");
      left -= (uint64_t)n;
    }
    tglb_take(&b);
    tglb_report("tmpfs-write", r, &a, &b, ops, extra);
    if (lseek(fd, 0, SEEK_SET) < 0) die("lseek");
    ops = 0;
    uint64_t got = 0;
    tglb_take(&b);
    for (;; ops++) {
      ssize_t n = read(fd, buf, size);
      if (n < 0) die("read");
      if (n == 0) break;
      got += (uint64_t)n;
    }
    tglb_take(&c);
    close(fd);
    unlink(path);
    if (got != total) {
      fprintf(stderr, "tg-lbench: read back %" PRIu64 " of %" PRIu64 " bytes\n", got, total);
      return 1;
    }
    tglb_report("tmpfs-read", r, &b, &c, ops, extra);
  }
  return 0;
}

static long minflt(void) {
  struct rusage u;
  getrusage(RUSAGE_SELF, &u);
  return u.ru_minflt;
}

static int t_pagefault(int argc, char **argv) {
  uint64_t mib = argc > 0 ? num(argv[0], "MIB") : 64, bytes = mib << 20;
  for (int r = 1; r <= runs; r++) {
    char *p = map(bytes);
    long f0 = minflt();
    struct tglb_mark a, b;
    tglb_take(&a);
    for (uint64_t i = 0; i < bytes; i += 4096) ((volatile char *)p)[i] = 1;
    tglb_take(&b);
    long f1 = minflt();
    munmap(p, bytes);
    char extra[64];
    snprintf(extra, sizeof extra, " mib=%" PRIu64 " faults=%ld", mib, f1 - f0);
    tglb_report("pagefault", r, &a, &b, bytes / 4096, extra);
  }
  return 0;
}

static uint64_t xs = 0x9e3779b97f4a7c15u;  // a fixed seed: the same walk on every board and boot
static uint64_t xorshift(void) {
  xs ^= xs << 13;
  xs ^= xs >> 7;
  xs ^= xs << 17;
  return xs;
}

static int t_tlbwalk(int argc, char **argv) {
  uint64_t mib = argc > 0 ? num(argv[0], "MIB") : 64, steps = argc > 1 ? num(argv[1], "STEPS") : 1000000;
  uint64_t pages = (mib << 20) / 4096;
  char *p = map(mib << 20);
  touch(p, mib << 20);  // the walk times translation, not page faults
  uint64_t *order = malloc(pages * sizeof *order);
  if (!order) die("malloc");
  for (uint64_t i = 0; i < pages; i++) order[i] = i;
  for (uint64_t i = pages - 1; i > 0; i--) {  // Sattolo: one cycle through every page
    uint64_t j = xorshift() % i, t = order[i];
    order[i] = order[j];
    order[j] = t;
  }
  // Each page holds a pointer to the next page of the cycle, at an offset that varies by page so the
  // pointers spread over the cache's sets.
  for (uint64_t i = 0; i < pages; i++) {
    uint64_t here = order[i], next = order[(i + 1) % pages];
    void **slot = (void **)(p + here * 4096 + (here * 64) % 4096);
    *slot = p + next * 4096 + (next * 64) % 4096;
  }
  free(order);
  char extra[64];
  snprintf(extra, sizeof extra, " mib=%" PRIu64 " pages=%" PRIu64, mib, pages);
  void **cur = (void **)p;  // page 0's slot is at offset 0
  for (int r = 1; r <= runs; r++) {
    struct tglb_mark a, b;
    tglb_take(&a);
    for (uint64_t i = 0; i < steps; i++) cur = (void **)*cur;  // each load depends on the last
    tglb_take(&b);
    __asm__ volatile("" : : "r"(cur));
    tglb_report("tlbwalk", r, &a, &b, steps, extra);
  }
  munmap(p, mib << 20);
  return 0;
}

static int t_gen(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "tg-lbench: gen needs FILE and MIB\n");
    return 2;
  }
  uint64_t bytes = num(argv[1], "MIB") << 20;
  FILE *f = fopen(argv[0], "w");
  if (!f) die(argv[0]);
  static const char *words[] = {"tanager", "lockstep", "retire", "commit", "cache", "line", "beat", "store",
                                "load", "branch", "fetch", "decode", "rename", "issue", "queue", "trace"};
  uint64_t n = 0;
  while (n < bytes) {
    const char *w = words[xorshift() % 16];
    int k = fprintf(f, "%s%c", w, (xorshift() % 8) ? ' ' : '\n');
    if (k < 0) die("write");
    n += (uint64_t)k;
  }
  if (fclose(f)) die("close");
  return 0;
}

static int t_exec(int argc, char **argv) {
  const char *label = NULL;
  int i = 0;
  for (; i < argc; i++) {
    if (!strcmp(argv[i], "-l") && i + 1 < argc) label = argv[++i];
    else if (!strcmp(argv[i], "--")) {
      i++;
      break;
    } else break;
  }
  if (i >= argc) {
    fprintf(stderr, "tg-lbench: exec needs a command\n");
    return 2;
  }
  char **cmd = argv + i;
  char test[64];
  snprintf(test, sizeof test, "%s", label ? label : cmd[0]);
  for (int r = 1; r <= runs; r++) {
    struct tglb_mark a, b;
    tglb_take(&a);
    pid_t pid = fork();
    if (pid < 0) die("fork");
    if (pid == 0) {
      int null = open("/dev/null", O_WRONLY);
      if (null >= 0) dup2(null, 1);
      execvp(cmd[0], cmd);
      _exit(127);
    }
    int st;
    if (waitpid(pid, &st, 0) < 0) die("waitpid");
    tglb_take(&b);
    char extra[32];
    snprintf(extra, sizeof extra, " status=%d", WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st));
    tglb_report(test, r, &a, &b, 1, extra);
    if (!WIFEXITED(st) || WEXITSTATUS(st)) return 1;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: tg-lbench info|forkexec|syscall|memcpy|memset|pipe|tmpfs|pagefault|tlbwalk|gen|exec "
                    "[-n RUNS] [args]\n");
    return 2;
  }
  const char *t = argv[1];
  argc -= 2;
  argv += 2;
  if (argc >= 2 && !strcmp(argv[0], "-n")) {
    runs = (int)num(argv[1], "RUNS");
    argc -= 2;
    argv += 2;
  }
  if (!strcmp(t, "info")) return t_info();
  if (!strcmp(t, "forkexec")) return t_forkexec(argc, argv);
  if (!strcmp(t, "syscall")) return t_syscall(argc, argv);
  if (!strcmp(t, "memcpy")) return t_mem(argc, argv, 1);
  if (!strcmp(t, "memset")) return t_mem(argc, argv, 0);
  if (!strcmp(t, "pipe")) return t_pipe(argc, argv);
  if (!strcmp(t, "tmpfs")) return t_tmpfs(argc, argv);
  if (!strcmp(t, "pagefault")) return t_pagefault(argc, argv);
  if (!strcmp(t, "tlbwalk")) return t_tlbwalk(argc, argv);
  if (!strcmp(t, "gen")) return t_gen(argc, argv);
  if (!strcmp(t, "exec")) return t_exec(argc, argv);
  fprintf(stderr, "tg-lbench: unknown test %s\n", t);
  return 2;
}
