// SO_REUSEPORT coexistence probe for PTP ports 319/320.
//
// Question: does macOS's own AirPlay PTP endpoint set SO_REUSEPORT on its
// 319/320 binds? If it does, a second holder that ALSO sets SO_REUSEPORT can
// coexist, and macOS's AirPlay connect will succeed while we hold the ports —
// which would dissolve the whole exclusivity conflict.
//
// BSD semantics: every socket bound to the same addr:port must have set
// SO_REUSEPORT, otherwise the later bind() fails with EADDRINUSE. So:
//   - macOS connects while this runs  => Apple sets SO_REUSEPORT too. Coexistence
//                                        is possible at the bind layer.
//   - macOS still fails               => Apple binds exclusively. Definitively
//                                        closes the question.
//
// This binds only; it speaks no PTP. Its only job is to occupy the ports the
// way our real helper would, but permissively. Not product code.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <netinet/in.h>
#include <sys/socket.h>

static volatile sig_atomic_t running = 1;
static void on_signal(int s) { (void)s; running = 0; }

// Binds one UDP port on all interfaces, optionally permissively.
static int bind_port(unsigned short port, int reuse, int family)
{
  int fd = socket(family, SOCK_DGRAM, 0);
  int yes = 1;
  if (fd < 0) return -1;

  if (family == AF_INET6 && setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, sizeof(yes)) < 0)
    { close(fd); return -1; }

  if (reuse) {
    // Both, deliberately: SO_REUSEPORT is the one that permits a genuinely
    // concurrent bind on BSD; SO_REUSEADDR is set alongside because some
    // stacks want it present too, and it cannot hurt here.
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes)) < 0)
      fprintf(stderr, "  (SO_REUSEPORT rejected on %hu: %s)\n", port, strerror(errno));
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  }

  if (family == AF_INET) {
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port),
                             .sin_addr.s_addr = INADDR_ANY };
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return -1; }
  } else {
    struct sockaddr_in6 a = { .sin6_family = AF_INET6, .sin6_port = htons(port),
                              .sin6_addr = in6addr_any };
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return -1; }
  }
  return fd;
}

int main(int argc, char **argv)
{
  // Default is the interesting case; pass --exclusive for the control run.
  int reuse = !(argc > 1 && strcmp(argv[1], "--exclusive") == 0);
  unsigned short ports[2] = { 319, 320 };
  int fds[4];
  int n = 0;

  printf("reuseport-probe: binding 319/320 %s\n\n",
         reuse ? "WITH SO_REUSEPORT (permissive - macOS may be able to share)"
               : "EXCLUSIVELY (control run - macOS must fail)");

  for (int i = 0; i < 2; i++) {
    int f4 = bind_port(ports[i], reuse, AF_INET);
    int f6 = bind_port(ports[i], reuse, AF_INET6);
    if (f4 < 0 && f6 < 0) {
      fprintf(stderr, "FAILED to bind %hu: %s\n", ports[i], strerror(errno));
      fprintf(stderr, "(something else already holds it - free it first)\n");
      return 1;
    }
    printf("  bound %hu  ipv4=%s ipv6=%s\n", ports[i],
           f4 >= 0 ? "yes" : "no", f6 >= 0 ? "yes" : "no");
    if (f4 >= 0) fds[n++] = f4;
    if (f6 >= 0) fds[n++] = f6;
  }

  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);

  printf("\nHOLDING. Now pick the Sonos in Control Center.\n");
  printf("Watch for: does it CONNECT, and does audio actually PLAY?\n");
  printf("Ctrl-C when done.\n");
  fflush(stdout);

  while (running) pause();

  printf("\nreuseport-probe: releasing ports\n");
  for (int i = 0; i < n; i++) close(fds[i]);
  return 0;
}
