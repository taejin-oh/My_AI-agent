// memhold: allocate N MiB, touch every page, then loop: increment a counter,
// write it to /state/counter, re-dirty a fraction of memory, sleep 1s.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
int main(int argc, char **argv) {
  long mib = argc > 1 ? atol(argv[1]) : 256;
  long dirty_mib = argc > 2 ? atol(argv[2]) : 0;   // re-dirtied each second
  size_t n = (size_t)mib << 20;
  unsigned char *buf = malloc(n);
  if (!buf) { perror("malloc"); return 1; }
  srand(1);
  for (size_t i = 0; i < n; i += 4096) buf[i] = (unsigned char)rand();  // touch pages (compressible)
  if (argc > 3 && argv[3][0] == 'r') { for (size_t i = 0; i < n; i++) buf[i] = (unsigned char)rand(); } // incompressible
  long counter = 0;
  for (;;) {
    counter++;
    FILE *f = fopen("/state/counter", "w");
    if (f) { fprintf(f, "%ld\n", counter); fclose(f); }
    if (dirty_mib > 0) {
      size_t d = (size_t)dirty_mib << 20; if (d > n) d = n;
      size_t off = ((size_t)counter * d) % (n - d + 1);
      for (size_t i = 0; i < d; i += 4096) buf[off + i] = (unsigned char)(counter + i);
    }
    printf("alive counter=%ld mem=%ldMiB\n", counter, mib); fflush(stdout);
    sleep(1);
  }
}
