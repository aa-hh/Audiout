// SPDX-License-Identifier: GPL-2.0-or-later
//
// logger.c — REAL logger shim (T-SHIM-2). FRESH code (not ported from OwnTone;
// OwnTone's logger.c is a file/syslog logger with its own threading — we route
// to Apple's os_log instead so session progress is visible in Console.app /
// `log stream` during bring-up).
//
// Routing: every DPRINTF/DVPRINTF is formatted once and emitted to os_log under
// a per-process subsystem, plus (for E_FATAL/E_LOG/E_WARN, or when
// AIRPLAYENGINE_LOG_STDERR is set) mirrored to stderr so it's visible when
// running the unit binary / a CLI probe outside Console. The severity is gated
// by the env var AIRPLAYENGINE_LOG_LEVEL (0=fatal .. 5=spam; default E_LOG=1),
// so verbose SPAM/DBG output is off unless explicitly requested.
//
// DHEXDUMP prints a classic offset | hex | ascii dump (capped) to the log.

#include "logger.h"

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <ctype.h>
#include <os/log.h>
#include <event2/event.h>
#include <pthread.h>
#include <time.h>

static const char *domain_label(int domain);

/* seam-map §3.2: default to E_LOG. Overridable via env for bring-up. */
static int
log_threshold(void)
{
  static int cached = -1;
  const char *env;

  if (cached >= 0)
    return cached;

  env = getenv("AIRPLAYENGINE_LOG_LEVEL");
  if (env && env[0])
    {
      int v = atoi(env);
      if (v < E_FATAL) v = E_FATAL;
      if (v > E_SPAM)  v = E_SPAM;
      cached = v;
    }
  else
    cached = E_LOG;

  return cached;
}

static bool
mirror_to_stderr(int severity)
{
  static int forced = -1;
  if (forced < 0)
    forced = (getenv("AIRPLAYENGINE_LOG_STDERR") != NULL) ? 1 : 0;
  // Errors/warnings always mirror; everything else only when forced.
  return forced || severity <= E_WARN;
}

/* Append-to-file sink. Unlike stderr (swallowed when the app is launched via
 * `open`/LaunchServices) and os_log (nothing from the notarised app reached
 * `log show` for a whole session on 2026-09-05), a plain file is readable
 * after the fact from any live session — it is what a support bundle carries
 * (docs/plans/PLAN-LIVE-DIAGNOSTICS.md C2).
 *
 * The path comes from ONE of two places, env first: AIRPLAYENGINE_LOG_FILE when
 * set (dev tooling, make-app.sh passes it through), else whatever the host
 * handed engine_logger_set_file(). This shim deliberately has no default path
 * of its own — the package knows no app, so it cannot know ~/Library/Logs/
 * <app>/; the Swift wrapper's setLogFile() is where that decision lives, and a
 * host that never calls it (tests, engine-probe) writes no file.
 *
 * Size-bounded like the host's decision log: when the active file reaches
 * `cap_bytes` it is renamed to "<path>.1" (replacing the previous one) and a
 * fresh file is opened, so the footprint is at most 2 × cap. All file state is
 * behind one mutex: DPRINTF runs on the engine thread AND on ptpd/event
 * threads, and a rotation racing another thread's write would be a use of a
 * closed FILE*. */
static pthread_mutex_t file_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *file_handle = NULL;
static char file_path[1024] = "";
static long file_cap = 5L * 1024 * 1024;
static int  file_resolved = 0; /* env consulted once */

/* Caller holds file_lock. */
static void
file_open_locked(void)
{
  if (file_handle || !file_path[0])
    return;
  file_handle = fopen(file_path, "a");
}

/* Caller holds file_lock. */
static void
file_resolve_locked(void)
{
  const char *env;
  if (file_resolved)
    return;
  file_resolved = 1;
  env = getenv("AIRPLAYENGINE_LOG_FILE");
  if (env && env[0])
    {
      if (file_handle) { fclose(file_handle); file_handle = NULL; }
      snprintf(file_path, sizeof(file_path), "%s", env);
    }
  file_open_locked();
}

/* Caller holds file_lock. Rotate when the active file has reached the cap. */
static void
file_rotate_if_full_locked(void)
{
  long size;
  char backup[sizeof(file_path) + 2];

  if (!file_handle || file_cap <= 0)
    return;
  size = ftell(file_handle);
  if (size < file_cap)
    return;
  fclose(file_handle);
  file_handle = NULL;
  snprintf(backup, sizeof(backup), "%s.1", file_path);
  rename(file_path, backup); /* replaces the previous backup */
  file_open_locked();
}

void
engine_logger_set_file(const char *path, long cap_bytes)
{
  pthread_mutex_lock(&file_lock);
  if (file_handle) { fclose(file_handle); file_handle = NULL; }
  if (path && path[0])
    snprintf(file_path, sizeof(file_path), "%s", path);
  else
    file_path[0] = '\0';
  if (cap_bytes > 0)
    file_cap = cap_bytes;
  file_resolved = 0; /* env still wins if set; re-checked on next line */
  pthread_mutex_unlock(&file_lock);
}

/* "2026-09-05T21:34:39.539Z " — the same ISO-8601 UTC shape the host's
 * decision log uses, so the two files interleave by eye. */
static void
format_timestamp(char *out, size_t n)
{
  struct timespec ts;
  struct tm tm;
  char date[32];

  clock_gettime(CLOCK_REALTIME, &ts);
  gmtime_r(&ts.tv_sec, &tm);
  strftime(date, sizeof(date), "%Y-%m-%dT%H:%M:%S", &tm);
  snprintf(out, n, "%s.%03ldZ", date, ts.tv_nsec / 1000000L);
}

static void
file_emit(int domain, const char *msg)
{
  char stamp[40];
  size_t n;

  pthread_mutex_lock(&file_lock);
  file_resolve_locked();
  file_open_locked(); /* a directory that appears (or returns) later still gets the file */
  if (file_handle)
    {
      format_timestamp(stamp, sizeof(stamp));
      n = strlen(msg);
      fprintf(file_handle, "%s [%s] %s", stamp, domain_label(domain), msg);
      if (n == 0 || msg[n - 1] != '\n')
        fputc('\n', file_handle);
      fflush(file_handle); /* flush every line: a live capture must not lose the tail */
      file_rotate_if_full_locked();
    }
  pthread_mutex_unlock(&file_lock);
}

static const char *
domain_label(int domain)
{
  switch (domain)
    {
      case L_AIRPLAY:   return "airplay";
      case L_PLAYER:    return "player";
      case L_MISC:      return "misc";
      case L_XCODE:     return "xcode";
      case L_MDNS:      return "mdns";
      case L_MAIN:      return "main";
      case L_EVENT:     return "event";
      case L_RAOP:      return "raop";
      case L_RCP:       return "rcp";
      default:          return "engine";
    }
}

static os_log_type_t
os_type_for(int severity)
{
  switch (severity)
    {
      case E_FATAL: return OS_LOG_TYPE_FAULT;
      case E_LOG:   return OS_LOG_TYPE_DEFAULT;
      case E_WARN:  return OS_LOG_TYPE_ERROR;
      case E_INFO:  return OS_LOG_TYPE_INFO;
      case E_DBG:
      case E_SPAM:  return OS_LOG_TYPE_DEBUG;
      default:      return OS_LOG_TYPE_DEFAULT;
    }
}

static os_log_t
engine_log(void)
{
  static os_log_t log = NULL;
  if (!log)
    log = os_log_create("com.airplayengine", "engine");
  return log;
}

static void
emit(int severity, int domain, const char *msg)
{
  os_log_with_type(engine_log(), os_type_for(severity), "[%{public}s] %{public}s",
                   domain_label(domain), msg);

  if (mirror_to_stderr(severity))
    {
      fprintf(stderr, "[%s] %s", domain_label(domain), msg);
      // Ensure a trailing newline for readability even if fmt lacked one.
      size_t n = strlen(msg);
      if (n == 0 || msg[n - 1] != '\n')
        fputc('\n', stderr);
    }

  file_emit(domain, msg);
}

void
DPRINTF(int severity, int domain, const char *fmt, ...)
{
  char buf[1024];
  va_list ap;

  if (severity > log_threshold())
    return;

  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);

  emit(severity, domain, buf);
}

void
DVPRINTF(int severity, int domain, const char *fmt, va_list ap)
{
  char buf[1024];

  if (severity > log_threshold())
    return;

  vsnprintf(buf, sizeof(buf), fmt, ap);
  emit(severity, domain, buf);
}

void
DHEXDUMP(int severity, int domain, const unsigned char *data, int data_len, const char *heading)
{
#define HEXDUMP_MAX_BYTES 512
#define HEXDUMP_COLS      16
  char line[128];
  int cap;
  int i, j;

  if (severity > log_threshold())
    return;

  if (heading)
    emit(severity, domain, heading);

  if (!data || data_len <= 0)
    return;

  cap = (data_len > HEXDUMP_MAX_BYTES) ? HEXDUMP_MAX_BYTES : data_len;

  for (i = 0; i < cap; i += HEXDUMP_COLS)
    {
      int pos = 0;
      pos += snprintf(line + pos, sizeof(line) - pos, "%04x  ", i);

      for (j = 0; j < HEXDUMP_COLS; j++)
        {
          if (i + j < cap)
            pos += snprintf(line + pos, sizeof(line) - pos, "%02x ", data[i + j]);
          else
            pos += snprintf(line + pos, sizeof(line) - pos, "   ");
        }

      pos += snprintf(line + pos, sizeof(line) - pos, " ");
      for (j = 0; j < HEXDUMP_COLS && i + j < cap; j++)
        {
          unsigned char c = data[i + j];
          pos += snprintf(line + pos, sizeof(line) - pos, "%c", isprint(c) ? c : '.');
        }

      emit(severity, domain, line);
    }

  if (data_len > cap)
    {
      snprintf(line, sizeof(line), "... (%d of %d bytes shown)", cap, data_len);
      emit(severity, domain, line);
    }
#undef HEXDUMP_MAX_BYTES
#undef HEXDUMP_COLS
}

/* --- libevent log bridge (first-light hardening #5) ------------------------
 *
 * libevent emits its own diagnostics (event base warnings, evrtsp transport
 * errors, kqueue failures) through an internal default callback that writes to
 * stderr with no severity control and no route into Console.app — invisible
 * once the engine runs as an installed helper. OwnTone wires libevent's log
 * output into its own logger; our hosting never did, so a libevent-level
 * failure during a session was silently lost. Route it through the same
 * os_log/stderr path (under the L_EVENT domain, env-gated by
 * AIRPLAYENGINE_LOG_LEVEL) as everything else. */

static int
severity_for_event_log(int event_severity)
{
  switch (event_severity)
    {
      case EVENT_LOG_DEBUG: return E_DBG;
      case EVENT_LOG_MSG:   return E_INFO;
      case EVENT_LOG_WARN:  return E_WARN;
      case EVENT_LOG_ERR:   return E_LOG; /* libevent's hard errors -> visible */
      default:              return E_LOG;
    }
}

static void
libevent_log_adapter(int severity, const char *msg)
{
  int mapped = severity_for_event_log(severity);
  if (mapped > log_threshold())
    return;
  emit(mapped, L_EVENT, msg ? msg : "(libevent: null message)");
}

void
engine_logger_wire_libevent(void)
{
  // Idempotent: event_set_log_callback just stores the pointer, so re-calling
  // with the same adapter is a no-op. Passing NULL would restore libevent's
  // default stderr writer — we always install ours.
  event_set_log_callback(libevent_log_adapter);
}
