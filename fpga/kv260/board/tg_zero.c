/* tg_zero: zero part of the RISC-V DRAM carve-out (0x8_4000_0000-0x8_7FFF_FFFF) through /dev/mem,
 * so that memory nobody wrote reads 0 on the board as it does in Spike (FPGA lockstep). Board track.
 *
 * The carve-out is outside Linux's memory, so /dev/mem's write() cannot reach it on arm64 (EFAULT);
 * the mapping is Device memory, so memset (DC ZVA) would fault: this maps it and stores 8 bytes at a
 * time, as tanager-host's loader does. It refuses any range outside the carve-out.
 *
 *   build:  $(CROSS)gcc -O2 -static -o tg_zero tg_zero.c   (the aarch64 musl toolchain of sw/host)
 *   run:    sudo ./tg_zero [BASE [MIB]]     (default 0x840000000, 768 MiB)
 */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define CO_LO 0x840000000ull
#define CO_HI 0x880000000ull
#define CHUNK (64ull << 20)

int main(int argc, char **argv) {
  uint64_t base = argc > 1 ? strtoull(argv[1], NULL, 0) : CO_LO;
  uint64_t mib = argc > 2 ? strtoull(argv[2], NULL, 0) : 768;
  uint64_t size = mib << 20;
  if (base < CO_LO || base & 0xfff || size == 0 || base + size > CO_HI) {
    fprintf(stderr, "tg_zero: 0x%" PRIx64 " + %" PRIu64 " MiB is not inside the carve-out "
            "0x%llx-0x%llx (4 KiB aligned)\n", base, mib, CO_LO, CO_HI - 1);
    return 2;
  }
  int fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (fd < 0) { fprintf(stderr, "tg_zero: /dev/mem: %s (run as root)\n", strerror(errno)); return 1; }
  struct timespec t0, t1;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (uint64_t off = 0; off < size; off += CHUNK) {
    uint64_t n = size - off < CHUNK ? size - off : CHUNK;
    void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)(base + off));
    if (p == MAP_FAILED) {
      fprintf(stderr, "tg_zero: mmap 0x%" PRIx64 ": %s\n", base + off, strerror(errno));
      return 1;
    }
    volatile uint64_t *q = p;
    for (uint64_t i = 0; i < n / 8; i++) q[i] = 0;
    munmap(p, n);
  }
  clock_gettime(CLOCK_MONOTONIC, &t1);
  double s = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
  printf("tg_zero: zeroed 0x%" PRIx64 " + %" PRIu64 " MiB in %.1f s (%.0f MB/s)\n", base, mib, s,
         size / s / 1e6);
  close(fd);
  return 0;
}
