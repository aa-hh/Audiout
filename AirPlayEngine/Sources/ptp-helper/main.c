// SPDX-License-Identifier: MIT
//
// ptp-helper — the privileged PTP clock daemon (T2, ptp-helper-design.md §0/§1/
// §6.1). This is the ONLY process in the product that ever runs as root, and
// it does exactly two privileged things: bind UDP 319/320
// (airptp_daemon_bind) and run the libairptp PTP master loop on those fds
// (airptp_daemon_start). No RTSP, no ALAC/RTP, no pairing, no PCM, no audio —
// see ptp-helper-design.md §1.2. It links ONLY Clibairptp + libevent (never
// the GPL sender cluster), so it stays small enough to read line-by-line
// (SPEC.md §4.1).
//
// Shape (ptp-helper-design.md §0, §1, §6.1; libairptp/airptp.h):
//   1. AUDIOUTER_PTP_PORTS override (unprivileged CI/test path, §6.2's
//      "interim dev launch" high-port mode) — parsed and applied via
//      airptp_ports_override() BEFORE binding, if set.
//   2. Register airptp_callbacks (logmsg/hexdump/thread_name_set) so the
//      library's own diagnostics reach stderr, which launchd redirects to
//      its configured log files.
//   3. Derive a real per-host clock-id seed from gethostuuid() (§6.1: "feed a
//      real per-host clock-id seed instead of airptpd.c's hardcoded
//      0xdeadbeef") — stable across restarts on the same host, unlike a
//      random seed.
//   4. airptp_daemon_bind(NULL) — binds 319/320 (or the override ports) on
//      all interfaces. This is the one privileged call (§1.1).
//   5. airptp_daemon_start(hdl, seed, is_shared=true) — publishes
//      /airptp_shm and runs the PTP master loop. Needs no privilege itself,
//      but consumes the fds bind() already stored in the handle.
//   6. Block until SIGTERM/SIGINT, then airptp_end(hdl) for a clean shutdown
//      (the library shm_unlinks /airptp_shm). No daemonize() — launchd owns
//      backgrounding and runs this in the foreground (§2.2, §6.1).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdarg.h>
#include <errno.h>
#include <uuid/uuid.h>
#ifdef __APPLE__
#include <pthread.h>
#endif

// Clibairptp's module map exposes airptp.h by its bare name (publicHeadersPath
// "." rooted at libairptp/ itself - see libairptp/module.modulemap), so this
// target reaches it as "airptp.h" rather than shims/ptpd.c's
// "libairptp/airptp.h" (CAirPlayEngine adds a header search path one level up
// from libairptp/, which this target does not need since it depends on
// Clibairptp directly, not CAirPlayEngine).
#include "airptp.h"

// MARK: - Shutdown

static volatile sig_atomic_t ptp_helper_should_run = 1;

static void
ptp_helper_signal_handler(int signum)
{
  (void)signum;
  ptp_helper_should_run = 0;
}

// MARK: - Callbacks (ptp-helper-design.md §1; shape mirrors
// CAirPlayEngine/shims/ptpd.c's logmsg/hexdump, minus the OwnTone logger —
// this daemon has no logger dependency, so it writes straight to stderr,
// which launchd captures per the daemon's launchd plist (StandardErrorPath /
// the default log redirection).

static void
ptp_helper_logmsg(const char *fmt, ...)
{
  va_list ap;

  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
}

static void
ptp_helper_hexdump(const char *msg, uint8_t *data, size_t data_len)
{
  size_t i;

  if (msg)
    fprintf(stderr, "%s\n", msg);

  for (i = 0; i < data_len; i++)
    fprintf(stderr, "%02x%s", data[i], ((i + 1) % 16 == 0) ? "\n" : " ");
  if (data_len % 16 != 0)
    fputc('\n', stderr);
}

static void
ptp_helper_thread_name_set(const char *name)
{
#ifdef __APPLE__
  pthread_setname_np(name);
#endif
}

static struct airptp_callbacks ptp_helper_callbacks = {
  .thread_name_set = ptp_helper_thread_name_set,
  .hexdump = ptp_helper_hexdump,
  .logmsg = ptp_helper_logmsg,
};

// MARK: - AUDIOUTER_PTP_PORTS override (unprivileged CI/test path)

// Parses "EVENT,GENERAL" (e.g. "30319,30320") from AUDIOUTER_PTP_PORTS and
// applies airptp_ports_override() before binding, so the whole
// bind/start/find/peer path can be exercised without root or contending with
// a real PTP responder on 319/320 (ptp-helper-design.md §6.2/§6.4).
static void
ptp_helper_apply_port_override_if_set(void)
{
  const char *env;
  char buf[64];
  char *comma;
  long event_port;
  long general_port;

  env = getenv("AUDIOUTER_PTP_PORTS");
  if (!env || !env[0])
    return;

  strncpy(buf, env, sizeof(buf) - 1);
  buf[sizeof(buf) - 1] = '\0';

  comma = strchr(buf, ',');
  if (!comma)
  {
    fprintf(stderr, "ptp-helper: AUDIOUTER_PTP_PORTS must be \"EVENT,GENERAL\" (got \"%s\") - ignoring\n", env);
    return;
  }

  *comma = '\0';
  event_port = strtol(buf, NULL, 10);
  general_port = strtol(comma + 1, NULL, 10);

  if (event_port <= 0 || event_port > 65535 || general_port <= 0 || general_port > 65535)
  {
    fprintf(stderr, "ptp-helper: AUDIOUTER_PTP_PORTS out of range (\"%s\") - ignoring\n", env);
    return;
  }

  fprintf(stderr, "ptp-helper: AUDIOUTER_PTP_PORTS set - overriding to event=%ld general=%ld (unprivileged test path)\n",
          event_port, general_port);
  airptp_ports_override((unsigned short)event_port, (unsigned short)general_port);
}

// MARK: - Per-host clock-id seed

// Folds gethostuuid()'s 16-byte machine UUID down to a u64 seed that is
// stable across restarts on the same host (ptp-helper-design.md §6.1),
// unlike airptpd.c's hardcoded 0xdeadbeef. A simple 8-byte XOR fold is
// sufficient here - this is a clock-id seed, not a cryptographic key (the
// PTP wire protocol carries the resulting id in the clear regardless).
static uint64_t
ptp_helper_clock_id_seed_get(void)
{
  uuid_t host_uuid;
  struct timespec wait_forever = { 0, 0 };
  uint64_t seed = 0;
  int i;

  if (gethostuuid(host_uuid, &wait_forever) != 0)
  {
    // gethostuuid() failing is unexpected on macOS, but a daemon this small
    // must still start with SOME stable-ish seed rather than aborting -
    // fall back to the hostname's bytes folded the same way.
    char hostname[256];

    fprintf(stderr, "ptp-helper: gethostuuid() failed (errno %d) - falling back to hostname\n", errno);

    if (gethostname(hostname, sizeof(hostname)) != 0)
      return 0x41756469756f7465ULL; // "Audiote"-ish - last-resort constant, never 0xdeadbeef.

    for (i = 0; hostname[i] != '\0'; i++)
      seed = (seed << 8 | (seed >> 56)) ^ (uint64_t)(unsigned char)hostname[i];

    return seed;
  }

  for (i = 0; i < 16; i++)
    ((uint8_t *)&seed)[i % 8] ^= host_uuid[i];

  return seed;
}

// MARK: - main

int
main(void)
{
  struct airptp_handle *hdl;
  uint64_t clock_id_seed;
  int ret;

  ptp_helper_apply_port_override_if_set();

  airptp_callbacks_register(&ptp_helper_callbacks);

  clock_id_seed = ptp_helper_clock_id_seed_get();
  ptp_helper_logmsg("ptp-helper: starting (clock-id seed 0x%016llx)", (unsigned long long)clock_id_seed);

  hdl = airptp_daemon_bind(NULL);
  if (!hdl)
  {
    fprintf(stderr, "ptp-helper: airptp_daemon_bind() failed: %s\n", airptp_errmsg_get());
    return 1;
  }

  ret = airptp_daemon_start(hdl, clock_id_seed, /* is_shared = */ true);
  if (ret < 0)
  {
    fprintf(stderr, "ptp-helper: airptp_daemon_start() failed: %s\n", airptp_errmsg_get());
    airptp_end(hdl);
    return 1;
  }

  ptp_helper_logmsg("ptp-helper: running (shared daemon, /airptp_shm published)");

  signal(SIGTERM, ptp_helper_signal_handler);
  signal(SIGINT, ptp_helper_signal_handler);

  // No daemonize() - launchd (or, in the interim dev path, the foreground
  // osascript-elevated caller) owns backgrounding (§2.2, §6.1). Just block
  // until signaled; the PTP master loop runs on its own thread inside
  // airptp_daemon_start().
  while (ptp_helper_should_run)
    pause();

  ptp_helper_logmsg("ptp-helper: shutting down");
  airptp_end(hdl);

  return 0;
}
