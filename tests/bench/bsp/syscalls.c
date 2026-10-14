/* newlib system calls for the Tanager simulation platform (verification.md §2.6): the console is
   the 16550 at UART_BASE, exit goes through tohost, stdin is a string fixed at build time. */
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include <time.h>

#include "tg_sim.h"

#ifndef TG_STDIN
#define TG_STDIN ""
#endif

volatile uint64_t tohost __attribute__((section(".tohost"), aligned(64)));
volatile uint64_t fromhost __attribute__((section(".tohost"), aligned(64)));
volatile unsigned long tg_marker __attribute__((aligned(64)));

extern char _end[];
extern char __stack_top[];
static char *heap_ptr;
static const char stdin_text[] = TG_STDIN;
static size_t stdin_pos;

static void uart_putc(char c) {
  volatile uint8_t *uart = (volatile uint8_t *)TG_UART_BASE;
  while (!(uart[5] & 0x20)) {
  }
  uart[0] = (uint8_t)c;
}

/* Plain C89 so the file also builds with Dhrystone's -std=gnu89. */
int _write(int fd, const void *buf, size_t len) {
  const char *p = (const char *)buf;
  size_t i;
  (void)fd;
  for (i = 0; i < len; i++) uart_putc(p[i]);
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

void _exit(int code) {
  tohost = ((uint64_t)(unsigned)code << 1) | 1;
  for (;;) {
  }
}

void *_sbrk(ptrdiff_t incr) {
  char *prev;
  if (!heap_ptr) heap_ptr = _end;
  prev = heap_ptr;
  if (heap_ptr + incr > __stack_top - (8 << 20)) {
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
