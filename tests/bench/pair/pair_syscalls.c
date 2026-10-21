/* newlib system calls and the region markers for a pair program (tests/bench/pair; pair.h). The console is
   dropped (both programs would interleave on it); stdin is a string fixed at build time (TG_STDIN); a program's
   end runs it again from the top; the markers time the first region on this hart's own counters. Plain C89
   (Dhrystone builds with -std=gnu89). */
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include <time.h>

#include "pair.h"

#ifndef TG_STDIN
#define TG_STDIN ""
#endif

#define SH ((volatile struct pair_shared *)PAIR_SHARED)
#define UART ((volatile uint8_t *)0x10000000ul)

extern char _end[];
extern char __stack_top[];
extern void _start(void);
static char *heap_ptr;
static const char stdin_text[] = TG_STDIN;
static size_t stdin_pos;

static uint64_t rd_cycle(void) {
  uint64_t v;
  __asm__ volatile(".option push\n.option arch, +zicsr\ncsrr %0, mcycle\n.option pop" : "=r"(v));
  return v;
}
static uint64_t rd_instret(void) {
  uint64_t v;
  __asm__ volatile(".option push\n.option arch, +zicsr\ncsrr %0, minstret\n.option pop" : "=r"(v));
  return v;
}
static int my_slot(void) {
  uint64_t h;
  __asm__ volatile(".option push\n.option arch, +zicsr\ncsrr %0, mhartid\n.option pop" : "=r"(h));
  return (int)SH->slot_of_hart[h & 3];
}

static void putc_(char c) {
  while (!(UART[5] & 0x20)) {
  }
  UART[0] = (uint8_t)c;
}
static void puts_(const char *s) {
  while (*s) putc_(*s++);
}
static void putu(uint64_t v) {
  char b[24];
  int n = 0;
  do b[n++] = (char)('0' + v % 10); while ((v /= 10) != 0);
  while (n) putc_(b[--n]);
}

/* One hart prints at a time: the first to finish prints PAIR-STOP while the last prints the results, and their
   characters would interleave (a same-program pair's two regions end within cycles of each other). */
static void print_lock(void) {
  while (__atomic_exchange_n(&SH->print_lock, 1, __ATOMIC_ACQUIRE)) {
  }
}
static void print_unlock(void) { __atomic_store_n(&SH->print_lock, 0, __ATOMIC_RELEASE); }

/* The end of the measurement: every slot's first region, then tohost (1: pass, or the failure's code). */
static void finish(uint64_t code) {
  int s;
  print_lock();   /* held to the end: nothing prints after */
  for (s = 0; s < 2; s++) {
    volatile struct pair_slot *p = &SH->s[s];
    if (!p->stopped) continue;
    puts_("PAIR slot=");
    putu((uint64_t)s);
    puts_(" cycles=");
    putu(p->c1 - p->c0);
    puts_(" instret=");
    putu(p->i1 - p->i0);
    puts_(" runs=");
    putu(p->runs);
    puts_("\n");
  }
  puts_(code == 1 ? "PAIR-END\n" : "PAIR-FAIL\n");
  *(volatile uint64_t *)PAIR_TOHOST = code;
  for (;;) {
  }
}

void pair_fail(int code) { finish(((uint64_t)(unsigned)code << 1) | 1); }

void tg_pair_mark(unsigned v) {
  int s = my_slot();
  volatile struct pair_slot *p = &SH->s[s];
  if (v == 1 && !p->started) {
    __atomic_fetch_add(&SH->at_start, 1, __ATOMIC_SEQ_CST);   /* the two first regions start together */
    while (__atomic_load_n(&SH->at_start, __ATOMIC_SEQ_CST) < SH->active) {
    }
    p->started = 1;
    p->i0 = rd_instret();
    p->c0 = rd_cycle();
  } else if (v == 2 && p->started && !p->stopped) {
    p->c1 = rd_cycle();
    p->i1 = rd_instret();
    p->stopped = 1;
    if (__atomic_add_fetch(&SH->done, 1, __ATOMIC_SEQ_CST) == SH->active) finish(1);
    print_lock();
    puts_("PAIR-STOP slot=");   /* the first to finish: names the slot left running if the run then hangs */
    putu((uint64_t)s);
    puts_("\n");
    print_unlock();
  }
}

/* The program ended: run it again from the top (pair_crt0.S restores .data and clears .bss) */
void _exit(int code) {
  int s = my_slot();
  (void)code;
  SH->s[s].runs++;
  heap_ptr = 0;
  stdin_pos = 0;
  __asm__ volatile("jr %0" : : "r"(_start));
  for (;;) {
  }
}

int _write(int fd, const void *buf, size_t len) {
  (void)fd;
  (void)buf;
  return (int)len;
}

int _read(int fd, void *buf, size_t len) {
  char *p = (char *)buf;
  size_t n = 0;
  (void)fd;
  while (n < len && stdin_pos < sizeof stdin_text - 1) {
    char c = stdin_text[stdin_pos++];
    p[n++] = c;
    if (c == '\n') break;
  }
  return (int)n;
}

void *_sbrk(ptrdiff_t incr) {
  char *prev;
  if (!heap_ptr) heap_ptr = _end;
  prev = heap_ptr;
  if (heap_ptr + incr > __stack_top - (1 << 20)) {
    errno = ENOMEM;
    return (void *)-1;
  }
  heap_ptr += incr;
  return prev;
}

int _close(int fd) { (void)fd; return -1; }
int _fstat(int fd, struct stat *st) { (void)fd; st->st_mode = S_IFCHR; return 0; }
int _isatty(int fd) { (void)fd; return 1; }
int _lseek(int fd, int off, int whence) { (void)fd; (void)off; (void)whence; return 0; }
int _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }
int _getpid(void) { return 1; }
int _open(const char *name, int flags, int mode) { (void)name; (void)flags; (void)mode; return -1; }

int _gettimeofday(struct timeval *tv, void *tz) {
  (void)tz;
  if (tv) { tv->tv_sec = 0; tv->tv_usec = 0; }
  return 0;
}

clock_t _times(struct tms *buf) {
  if (buf) buf->tms_utime = buf->tms_stime = buf->tms_cutime = buf->tms_cstime = 0;
  return 0;
}
