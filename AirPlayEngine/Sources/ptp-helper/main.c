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
//   1. AUDIOUTER_PTP_PORTS / AUDIOUTER_PTP_SHM_NAME overrides (unprivileged
//      CI/test path, §6.2's "interim dev launch" high-port mode) — applied
//      via airptp_ports_override()/airptp_shm_name_override() BEFORE binding.
//   2. Register airptp_callbacks (logmsg/hexdump/thread_name_set) so the
//      library's own diagnostics reach stderr, which launchd redirects to
//      its configured log files.
//   3. Check in on the launchd Mach service, if one was handed to us (see
//      "On-demand lifecycle" below).
//   4. Derive a real per-host clock-id seed from gethostuuid() (§6.1: "feed a
//      real per-host clock-id seed instead of airptpd.c's hardcoded
//      0xdeadbeef") — stable across restarts on the same host, unlike a
//      random seed.
//   5. airptp_daemon_bind(NULL), RETRIED — binds 319/320 (or the override
//      ports) on all interfaces. This is the one privileged call (§1.1).
//   6. airptp_daemon_start(hdl, seed, is_shared=true) — publishes the shm
//      clock record and runs the PTP master loop. Needs no privilege itself,
//      but consumes the fds bind() already stored in the handle.
//   7. Poll for idleness until the peer table stays empty (or SIGTERM/SIGINT
//      arrives), then airptp_end(hdl) for a clean shutdown (the library
//      shm_unlinks its segment). No daemonize() — launchd owns backgrounding
//      and runs this in the foreground (§2.2, §6.1).
//
// ON-DEMAND LIFECYCLE (PLAN-AIRPLAY-COEXISTENCE.md T2)
//
// macOS's own AirPlay stack wants UDP 319/320 too, so this daemon must not
// hold them for the whole login session. It is demand-started and self-exits:
//
//   - Mach check-in: when AUDIOUTER_PTP_MACH_SERVICE names a launchd
//     MachServices key, we open an XPC listener on it and hold it for process
//     lifetime. It carries exactly one boolean shutdown trigger (see "Release
//     verb" below) and otherwise answers nothing — shm + loopback UDP stay
//     the only data transport (§4). Its main job is still to give launchd
//     something to demand-start us on. Unset (dev/test) = no check-in at all.
//   - Bind retry: the app switches the default output away from an AirPlay
//     device in parallel, and macOS releases the ports a second or three
//     later, so a single bind attempt would lose the race.
//   - Idle exit: once no PTP peer has been active for a while, exit so
//     launchd tears the ports back down and macOS AirPlay can have them.
//   - Release verb: a peer connection may send a dictionary with
//     {"release": true} to trigger the same clean exit immediately, so a
//     seamless handoff can free 319/320 in ~1s instead of waiting out the
//     idle window. Fire-and-forget, no reply — the idle path above remains
//     the normal, unsolicited case.
//
// EXIT-CODE CONTRACT — load-bearing, because the launchd plist runs
// KeepAlive={SuccessfulExit:false}: a non-zero exit is respawned immediately.
//
//   status 0  = expected outcome. Idle exit, bind gave up (someone else still
//               owns the ports), SIGTERM/SIGINT. launchd must NOT respawn us
//               for any of these — the next connect click demand-starts a
//               fresh attempt through the Mach service.
//   non-zero  = genuine internal failure only (daemon_start failed, the
//               library stopped reporting a running daemon). Respawning is
//               the right response to these.
//
// ENV OVERRIDES (all optional; the AUDIOUTER_PTP_* family)
//
//   AUDIOUTER_PTP_MACH_SERVICE        launchd Mach service name to check in
//                                     on. Unset/empty = skip check-in.
//   AUDIOUTER_PTP_PORTS               "EVENT,GENERAL" high-port override.
//   AUDIOUTER_PTP_SHM_NAME            shm segment name override, so a test
//                                     helper never collides with the real
//                                     root daemon's root-owned /airptp_shm.
//   AUDIOUTER_PTP_BIND_RETRY_SECS     bind retry budget, default 10.
//   AUDIOUTER_PTP_BIND_RETRY_INTERVAL_MS  gap between attempts, default 500.
//   AUDIOUTER_PTP_IDLE_SECS           idle-exit window, default 15.
//   AUDIOUTER_PTP_IDLE_GRACE_SECS     startup grace before idleness is
//                                     measured at all, default 30.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdarg.h>
#include <errno.h>
#include <time.h>
#include <uuid/uuid.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
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

// MARK: - AUDIOUTER_PTP_SHM_NAME override (unprivileged CI/test path)

// The shipped daemon runs as root and owns /airptp_shm; an unprivileged test
// copy cannot shm_unlink() that root-owned segment, so daemon_shm_create()
// would fail whenever the real daemon happens to exist on the box. Naming a
// different segment keeps a test helper hermetic (same reason
// PTPHelperIPCTests.swift overrides it on the library side).
static void
ptp_helper_apply_shm_name_override_if_set(void)
{
  const char *env;

  env = getenv("AUDIOUTER_PTP_SHM_NAME");
  if (!env || !env[0])
    return;

  fprintf(stderr, "ptp-helper: AUDIOUTER_PTP_SHM_NAME set - publishing clock state as \"%s\" (unprivileged test path)\n", env);
  airptp_shm_name_override(env);
}

// MARK: - Numeric env overrides

// Reads a non-negative integer from `name`, falling back (loudly) to
// `fallback` when unset or unparseable. Every AUDIOUTER_PTP_* timing knob
// goes through here so a typo degrades to the shipping default instead of
// silently disabling the retry or the idle exit.
static long
ptp_helper_env_long(const char *name, long fallback)
{
  const char *env;
  char *end;
  long value;

  env = getenv(name);
  if (!env || !env[0])
    return fallback;

  errno = 0;
  value = strtol(env, &end, 10);
  if (errno != 0 || end == env || *end != '\0' || value < 0)
  {
    fprintf(stderr, "ptp-helper: %s=\"%s\" is not a non-negative integer - using %ld\n", name, env, fallback);
    return fallback;
  }

  return value;
}

// MARK: - launchd Mach-service check-in

// Held for process lifetime and deliberately never released: launchd routes
// the demand-start through this service, and the listener must stay
// serviceable for as long as we run.
static xpc_connection_t ptp_helper_mach_listener;

// Opens the XPC listener launchd demand-starts us on. It is a doorbell, not
// a transport: connections are accepted and every message dropped, because
// shm + loopback UDP remain the ONLY data path across the privilege boundary
// (ptp-helper-design.md §4) and a root process must not grow a message
// surface it does not need.
//
// XPC and libdispatch both live in libSystem, so this adds no linked library
// - which matters: this daemon carries no entitlements, so Library
// Validation kills it if it ever loads a non-Apple dylib (§6.1.1, live crash
// 2026-07-21). `otool -L` must keep showing libSystem and nothing else.
static void
ptp_helper_mach_checkin(void)
{
  const char *name;
  dispatch_queue_t queue;

  name = getenv("AUDIOUTER_PTP_MACH_SERVICE");
  if (!name || !name[0])
    return; // Dev/test path: launched directly, no launchd, nothing to check in with.

  queue = dispatch_queue_create("com.audiouter.ptp-helper.machservice", DISPATCH_QUEUE_SERIAL);

  ptp_helper_mach_listener = xpc_connection_create_mach_service(name, queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
  if (!ptp_helper_mach_listener)
  {
    // Not fatal: the clock is still worth running for whoever started us.
    fprintf(stderr, "ptp-helper: could not create a Mach service listener for \"%s\" - continuing without check-in\n", name);
    return;
  }

  xpc_connection_set_event_handler(ptp_helper_mach_listener, ^(xpc_object_t peer) {
    if (xpc_get_type(peer) != XPC_TYPE_CONNECTION)
      return; // Listener-level error object (e.g. XPC_ERROR_TERMINATION_IMMINENT).

    // Resume the peer so the client's connect() completes, then ignore
    // everything it sends except the one recognized shutdown trigger below.
    xpc_connection_set_event_handler((xpc_connection_t)peer, ^(xpc_object_t event) {
      if (xpc_get_type(event) == XPC_TYPE_DICTIONARY &&
          xpc_dictionary_get_bool(event, "release"))
      {
        ptp_helper_logmsg("ptp-helper: release requested - exiting so the PTP ports are freed");
        ptp_helper_should_run = 0;
      }
    });
    xpc_connection_resume((xpc_connection_t)peer);
  });

  xpc_connection_resume(ptp_helper_mach_listener);

  ptp_helper_logmsg("ptp-helper: checked in on Mach service \"%s\"", name);
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

// MARK: - Sleeping

// Sleeps ~`ms`, returning early when a signal (our SIGTERM/SIGINT handler
// included) interrupts it - deliberately NOT restarted on EINTR, so shutdown
// is prompt.
static void
ptp_helper_sleep_ms(long ms)
{
  struct timespec req;

  req.tv_sec = ms / 1000;
  req.tv_nsec = (ms % 1000) * 1000000L;

  nanosleep(&req, NULL);
}

// MARK: - Bind with retry

// The helper is demand-started while macOS may still hold 319/320 for its own
// AirPlay session. The app frees them in parallel (PLAN-AIRPLAY-COEXISTENCE
// T5) and macOS releases them a second or three later - measured - so keep
// asking rather than losing the race on the first attempt. Returns NULL if
// the budget runs out or a signal arrives; both are expected outcomes and the
// caller exits 0.
static struct airptp_handle *
ptp_helper_bind_with_retry(void)
{
  long budget_secs = ptp_helper_env_long("AUDIOUTER_PTP_BIND_RETRY_SECS", 10);
  long interval_ms = ptp_helper_env_long("AUDIOUTER_PTP_BIND_RETRY_INTERVAL_MS", 500);
  struct airptp_handle *hdl;
  long attempts;
  long attempt;

  if (interval_ms < 1)
    interval_ms = 1;

  attempts = (budget_secs * 1000) / interval_ms;
  if (attempts < 1)
    attempts = 1;

  for (attempt = 0; attempt < attempts && ptp_helper_should_run; attempt++)
  {
    hdl = airptp_daemon_bind(NULL);
    if (hdl)
    {
      if (attempt > 0)
        ptp_helper_logmsg("ptp-helper: bound the PTP ports on attempt %ld", attempt + 1);
      return hdl;
    }

    // Sparingly: a 500 ms cadence over 10 s would otherwise be 20 identical
    // lines in the launchd log for every failed takeover.
    if (attempt % 4 == 0)
      fprintf(stderr, "ptp-helper: PTP ports still busy (attempt %ld/%ld): %s\n", attempt + 1, attempts, airptp_errmsg_get());

    ptp_helper_sleep_ms(interval_ms);
  }

  return NULL;
}

// MARK: - Idle exit

// Polls the daemon's active-peer count once a second and returns when the
// table has been empty for the whole idle window - the cue to exit so launchd
// releases 319/320 back to macOS.
//
// The startup grace exists because the helper is demand-started BY a user's
// connect click: it legitimately begins at zero peers while RTSP SETUP is
// still negotiating, and the first peer only arrives once a speaker's SETUP
// reply hands back its timing address (ptp-helper-design.md §5.1). So
// idleness is not measured at all until either a peer has shown up once, or
// the grace window - comfortably longer than a real handshake - expires.
//
// Returns the process exit status (see the EXIT-CODE CONTRACT at the top).
static int
ptp_helper_wait_until_idle_or_signal(struct airptp_handle *hdl)
{
  long idle_secs = ptp_helper_env_long("AUDIOUTER_PTP_IDLE_SECS", 15);
  long grace_secs = ptp_helper_env_long("AUDIOUTER_PTP_IDLE_GRACE_SECS", 30);
  time_t started = time(NULL);
  time_t idle_since = 0;
  bool saw_peer = false;
  int count;

  while (ptp_helper_should_run)
  {
    ptp_helper_sleep_ms(1000);
    if (!ptp_helper_should_run)
      break;

    count = airptp_peer_active_count(hdl);

    if (count < 0)
    {
      // Only reachable if the handle stopped being a running daemon under us
      // - a genuine internal failure, so exit non-zero and let launchd's
      // KeepAlive={SuccessfulExit:false} respawn.
      fprintf(stderr, "ptp-helper: airptp_peer_active_count() no longer reports a running daemon - aborting\n");
      return 1;
    }

    if (count > 0)
    {
      saw_peer = true;
      idle_since = 0;
      continue;
    }

    if (!saw_peer && time(NULL) - started < grace_secs)
      continue;

    if (idle_since == 0)
    {
      idle_since = time(NULL);
      continue;
    }

    if (time(NULL) - idle_since >= idle_secs)
    {
      ptp_helper_logmsg("ptp-helper: no active PTP peers for %lds - exiting so the PTP ports are released", idle_secs);
      return 0;
    }
  }

  return 0; // SIGTERM/SIGINT, or the release verb - all expected outcomes.
}

// MARK: - main

int
main(void)
{
  struct airptp_handle *hdl;
  uint64_t clock_id_seed;
  int ret;

  ptp_helper_apply_port_override_if_set();
  ptp_helper_apply_shm_name_override_if_set();

  airptp_callbacks_register(&ptp_helper_callbacks);

  // Installed before the bind retry loop, so a SIGTERM arriving while the
  // ports are still contended stops us promptly instead of being ignored for
  // the whole retry budget.
  signal(SIGTERM, ptp_helper_signal_handler);
  signal(SIGINT, ptp_helper_signal_handler);

  ptp_helper_mach_checkin();

  clock_id_seed = ptp_helper_clock_id_seed_get();
  ptp_helper_logmsg("ptp-helper: starting (clock-id seed 0x%016llx)", (unsigned long long)clock_id_seed);

  hdl = ptp_helper_bind_with_retry();
  if (!hdl)
  {
    // Expected outcome, not a failure: someone else (macOS's own AirPlay,
    // nqptp, a corporate PTP daemon) still owns the ports. Exit 0 so
    // KeepAlive={SuccessfulExit:false} does not respawn us into a storm - the
    // next connect click demand-starts a fresh attempt.
    ptp_helper_logmsg("ptp-helper: could not bind the PTP ports - exiting (status 0, see the exit-code contract)");
    return 0;
  }

  ret = airptp_daemon_start(hdl, clock_id_seed, /* is_shared = */ true);
  if (ret < 0)
  {
    fprintf(stderr, "ptp-helper: airptp_daemon_start() failed: %s\n", airptp_errmsg_get());
    airptp_end(hdl);
    return 1;
  }

  ptp_helper_logmsg("ptp-helper: running (shared daemon, clock state published)");

  // No daemonize() - launchd (or, in the interim dev path, the foreground
  // osascript-elevated caller) owns backgrounding (§2.2, §6.1). The PTP
  // master loop runs on its own thread inside airptp_daemon_start(); this
  // thread just watches for idleness or a signal.
  ret = ptp_helper_wait_until_idle_or_signal(hdl);

  ptp_helper_logmsg("ptp-helper: shutting down");
  airptp_end(hdl);

  return ret;
}
