/* Two threads share one cache line: each adds 1 to an atomic counter 2,000,000 times and, under a mutex, to a
 * plain counter 200,000 times. With two cores the line moves between their caches on every access. */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
static atomic_ulong a;
static unsigned long b;
static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
static void *run(void *arg) {
  (void)arg;
  for (int i = 0; i < 2000000; i++) {
    atomic_fetch_add_explicit(&a, 1, memory_order_relaxed);
    if (i % 10 == 0) { pthread_mutex_lock(&m); b++; pthread_mutex_unlock(&m); }
  }
  return 0;
}
int main(void) {
  pthread_t t[2];
  for (int i = 0; i < 2; i++) pthread_create(&t[i], 0, run, 0);
  for (int i = 0; i < 2; i++) pthread_join(t[i], 0);
  unsigned long av = atomic_load(&a);
  printf("mt %s %lu %lu\n", av == 4000000 && b == 400000 ? "ok" : "bad", av, b);
  return 0;
}
